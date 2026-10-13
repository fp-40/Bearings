# Loops in depth

## Pending and wake

When `Poll` returns `cpPending`, the connection task stops running and the
loop goes back to its other sockets. Nothing polls the call again until
something wakes the connection. The sources of a wake are:

- body data arriving after a `TryRead` returned `brPending`;
- a `TWakeTimer` the call armed;
- a worker's terminal call, which is how `TOffloadCall` works;
- `Ex.Wake` from any thread holding a `Share` reference.

A call that returns `cpPending` without arranging one of these stays
pending until the connection times out. A build with `-dWD_DEBUG` checks
that a wake source exists at the end of every pending run.

## A timer

This program answers `/delay` one second after the request, without a
worker thread, using `TWakeTimer` (also `examples/delay.pas`):

```pascal
program delay;

{$mode objfpc}{$H+}

uses
  cthreads, SysUtils, bearings.rt.loop, bearings.http.exchange, bearings.server;

type
  { one object per request: it owns the timer that wakes the connection }
  TDelayCall = class(TServiceCall)
  private
    FTimer: TWakeTimer;
  public
    function Poll(Ex: TExchange): TCallPoll; override;
    procedure Drop(Ex: TExchange; Completed: Boolean); override;
  end;

  TNotFoundCall = class(TServiceCall)
  public
    function Poll(Ex: TExchange): TCallPoll; override;
  end;

  TDelayService = class(THttpService)
  private
    FNotFound: TNotFoundCall;
  public
    constructor Create;
    destructor Destroy; override;
    function Call(Ex: TExchange): TServiceCall; override;
  end;

function TDelayCall.Poll(Ex: TExchange): TCallPoll;
begin
  if FTimer.Target = nil then
  begin
    FTimer.Arm(Ex, 1000);             { the loop polls us again in one second }
    Exit(cpPending);
  end;
  if not FTimer.Fired then
    Exit(cpPending);                  { woken for another reason; keep waiting }
  Ex.RespondText(200, 'you waited one second'#10);
  Result := cpReady;
end;

procedure TDelayCall.Drop(Ex: TExchange; Completed: Boolean);
begin
  FTimer.Cancel(Ex);                  { the client may have left before the timer fired }
  Free;
end;

function TNotFoundCall.Poll(Ex: TExchange): TCallPoll;
begin
  Ex.RespondText(404, 'not found'#10);
  Result := cpReady;
end;

constructor TDelayService.Create;
begin
  inherited Create;
  FNotFound := TNotFoundCall.Create;
end;

destructor TDelayService.Destroy;
begin
  FNotFound.Free;
  inherited Destroy;
end;

function TDelayService.Call(Ex: TExchange): TServiceCall;
begin
  if PathIs(Ex, '/delay') then
    Result := TDelayCall.Create       { freed in its Drop }
  else
    Result := FNotFound;
end;

function NewService(Loop: TLoop): THttpService;
begin
  Result := TDelayService.Create;
end;

var
  Cfg: TServerConfig;
  Srv: TServer;
begin
  Cfg := ProductionServerConfig;
  Cfg.Workers := NO_WORKER_POOL;
  Cfg.Listen.Port := StrToIntDef(ParamStr(1), 8080);
  Srv := TServer.CreateWithProc(Cfg, @NewService);
  Srv.RunUntilSignalProc(nil);
  Srv.Free;
end.
```

```sh
$ build/tutorial/delay 8080 &
$ time curl -s http://127.0.0.1:8080/delay
you waited one second

real    0m1.007s
```

`Call` now looks at the request and returns different call objects for
different paths. The delay call has per-request state, the timer, so the
service creates one per request and the call frees itself in `Drop`.

`Drop(Ex, Completed)` is called exactly once at the end of every call, on
the loop thread. `Completed` is True right after `Poll` returned
`cpReady`, and False when the connection abandoned the call: the client
closed, the connection failed, or the shutdown deadline passed. Either way
the timer is cancelled, which is harmless if it already fired, and the
object is freed. A call that is pooled rather than allocated per request
returns itself to its pool here.

The first `Poll` arms the timer and returns `cpPending`. One second later
the timer wakes the connection, `Poll` runs again, sees `Fired` and
answers. The `Fired` check matters: a wake can come from elsewhere, and a
call must treat every poll as a question, not as a notification that its
own event happened.

A `TWakeTimer` is a record that must not move while armed, which is one
reason it lives in a heap object. It checks the exchange's generation when
it fires, so a timer armed for one request never wakes a later request on
the same connection.

## Keep-alive, pipelining and cancellation

Each request on a keep-alive connection is a new call on the same exchange
object; `Ex.RequestNo` counts them and `Ex.ConnId` identifies the
connection. The connection keeps one call in flight at a time: a pipelined
request waits in the read buffer until the current call completed, so a
slow handler delays the later requests of its own connection and no one
else's.

When the client disconnects while a call is in flight, the exchange is
canceled: terminal calls return False and send nothing, `TryRead` returns
`brCanceled`, the blocking reads raise `EClientGone`, stream writes return
`wrCanceled`, and a worker parked in a read or a write is woken. A long
handler that is between body calls checks `Ex.IsCanceled` now and then.
Nothing is ever sent to a client that is gone, so a handler may simply
return.

# Blocking code: the worker pool

So far every request was answered inside `Poll`, on the loop thread, in
microseconds. Real handlers query databases, read files, call other
services. That code blocks, and it cannot run on a loop.

Bearings keeps a pool of worker threads for it. A request is handed to
the pool, a worker runs your handler, and the handler may block as long
as it likes: the loop goes on serving its other connections meanwhile.
When the handler answers, the loop is woken and writes the response.

## The code

`kv3.pas` (also `examples/kv3.pas`) moves the key-value store to the worker pool, and while it is
there, `PUT` now takes the value from the request body, where it belongs:

```pascal
program kv3;

{$mode objfpc}{$H+}

uses
  cthreads, SysUtils, fgl, syncobjs, bearings.rt.loop, bearings.http1.role,
  bearings.http.exchange, bearings.server;

const
  VALUE_LIMIT = 64 * 1024;          { ReadAll refuses a larger body }

type
  TMap = specialize TFPGMap<RawByteString, RawByteString>;

  TStore = class
  private
    FLock: TCriticalSection;
    FMap: TMap;
  public
    constructor Create;
    destructor Destroy; override;
    function Get(const Key: RawByteString; out Value: RawByteString): Boolean;
    procedure Put(const Key, Value: RawByteString);
  end;

  { runs on a worker thread; may block }
  TKvHandler = class(TBlockingHandler)
  private
    FStore: TStore;
  public
    constructor Create(Store: TStore);
    procedure Run(Ex: TExchange); override;
  end;

  TKvService = class(THttpService)
  private
    FCall: TOffloadCall;
  public
    constructor Create(Srv: TServer; H: TBlockingHandler);
    destructor Destroy; override;
    function Call(Ex: TExchange): TServiceCall; override;
  end;

  TApp = class
    Srv: TServer;
    Store: TStore;
    Handler: TKvHandler;
    function NewService(Loop: TLoop): THttpService;
  end;

{ TStore is the same as in kv2.pas }

constructor TKvHandler.Create(Store: TStore);
begin
  inherited Create;
  FStore := Store;
end;

procedure TKvHandler.Run(Ex: TExchange);
var
  Path, Key, Value: RawByteString;
  Body: TBytes;
  N: SizeInt;
begin
  Path := SliceToStr(Ex.Path);
  if Copy(Path, 1, 4) <> '/kv/' then
  begin
    Ex.RespondText(404, 'not found'#10);
    Exit;
  end;
  Key := Copy(Path, 5, MaxInt);
  case Ex.Method of
    hmGet:
      if FStore.Get(Key, Value) then
        Ex.RespondText(200, Value + #10)
      else
        Ex.RespondText(404, 'no such key'#10);
    hmPut:
      begin
        try
          N := Ex.ReadAll(Body, VALUE_LIMIT);     { blocks until the body ended }
        except
          on EBodyTooLarge do
          begin
            Ex.RespondText(413, 'value too large'#10);
            Exit;
          end;
          on E: EBodyError do
          begin
            Ex.RespondText(400, 'bad request body: ' + Ex.BodyErrorMessage + #10);
            Exit;
          end;
          on EClientGone do
            Exit;                                 { nobody to answer }
        end;
        SetString(Value, PAnsiChar(Body), N);
        FStore.Put(Key, Value);
        Ex.RespondText(200, 'stored'#10);
      end;
  else
    Ex.RespondText(405, 'method not allowed'#10);
  end;
end;

constructor TKvService.Create(Srv: TServer; H: TBlockingHandler);
begin
  inherited Create;
  FCall := TOffloadCall.Create;
  FCall.Pool := Srv.Workers;        { the pool exists before the services are created }
  FCall.Handler := H;
end;

destructor TKvService.Destroy;
begin
  FCall.Free;
  inherited Destroy;
end;

function TKvService.Call(Ex: TExchange): TServiceCall;
begin
  Result := FCall;
end;

function TApp.NewService(Loop: TLoop): THttpService;
begin
  Result := TKvService.Create(Srv, Handler);
end;

var
  Cfg: TServerConfig;
  App: TApp;
begin
  Cfg := ProductionServerConfig;    { Workers = 0: a pool of Min(32, cpus + 4) threads }
  Cfg.Listen.Port := StrToIntDef(ParamStr(1), 8080);
  App := TApp.Create;
  App.Store := TStore.Create;
  App.Handler := TKvHandler.Create(App.Store);
  App.Srv := TServer.Create(Cfg, @App.NewService);
  App.Srv.RunUntilSignal(nil);
  App.Srv.Free;                     { after this no worker runs the handler }
  App.Handler.Free;
  App.Store.Free;
  App.Free;
end.
```

```sh
$ ./kv3 8080 &
$ curl -s -X PUT --data-binary 'world from the body' http://127.0.0.1:8080/kv/hello
stored
$ curl -s http://127.0.0.1:8080/kv/hello
world from the body
$ head -c 100000 /dev/zero | curl -si -X PUT --data-binary @- http://127.0.0.1:8080/kv/big | head -1
HTTP/1.1 413 Payload Too Large
```

## Breaking it down

The handler is a `TBlockingHandler`. Its `Run` method runs on a worker
thread and must make exactly one terminal call, the same rule as `Poll`.
The service returns a `TOffloadCall`, a ready-made call object: its first
`Poll` hands the exchange to the pool and returns `cpPending`; the worker
runs `Run`; the worker's terminal call wakes the connection; the next
`Poll` sees the exchange answered and returns `cpReady`.

One `TOffloadCall` serves every request of a loop, and one `TKvHandler`
serves every worker, because neither has per-request state. The handler
reads the store through the same lock as before. A worker may block on
the lock, but a short critical section is still the right design: a loop
thread could also be waiting on it.

`Cfg.Workers` is left at the production default, 0, which means a pool of
`Min(32, cpus + 4)` threads. The pool is created in `Start` before the
services, so the factory can read `Srv.Workers`.

`ReadAll` blocks until the whole body arrived, appends it to a `TBytes`
and returns the byte count. It raises `EBodyTooLarge` when the body is
over the limit, `EBodyError` when the body could not be read (a malformed
chunked encoding, the body timeout, a connection failure), and
`EClientGone` when the client disconnected: nothing can be sent then, and
the handler just returns. [Request bodies](request-bodies.md) has the other ways to read a body.

## When a request should not be offloaded

Each offloaded request costs a thread hand-off, about 2.5 microseconds on
the benchmark machine, plus a few atomic operations. A handler that only
looks at the head and answers from memory is better off inline, as in
the chapters from [Hello Bearings](hello-bearings.md) to [Shared state](shared-state.md). A service can mix the two: `Call` sees the request head
and returns an inline call for some paths and the `TOffloadCall` for
others.

`TOffloadCall.SaturatedStatus` is for a pool that cannot keep up. With
`Cfg.WorkerQueueLimit` set and `SaturatedStatus := 503`, a request that
finds the queue at its limit is answered on the loop thread at once, with
a `Retry-After: 1` header, and the handler never runs for it.

## Your own threads

`Offload` is built on three calls you can use directly. `Ex.Share` (on the
loop thread, for example inside `Poll`) switches the exchange to shared
mode and gives you a reference you may use from any thread. `Ex.Release`
gives it back. `Ex.Wake` runs the connection again so that `Poll` is
called. A producer of server-sent events on a thread of its own works this
way: `Share` and `BeginStream` in `Poll`, return `cpPending`; the thread
writes and finally calls `Finish` and `Release`.

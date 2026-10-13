# Handling requests

We are going to build a key-value store over HTTP. `GET /kv/<key>` returns
the value and `PUT /kv/<key>` sets it. For now the value travels in the
query string, `PUT /kv/hello?world`; reading a request body comes in [Request bodies](request-bodies.md).

## The request head

The exchange gives you the request head as byte slices into the
connection's read buffer: `Method` (an enumeration, `hmGet`, `hmPut` and
so on from unit `bearings.http1.role`), `Path`, `Query`, `Headers`, and
`Header(Name, out V)` for one header. A `TByteSlice` is a pointer and a
length. The bytes are not copied, and they are valid only until the
request is released, which happens at the latest when the call completes.
To keep a value, copy it: `SliceToStr(S)` makes a `RawByteString`.
`SliceEquals(S, Text)` compares without copying, and `PathIs(Ex, Text)`
compares the path.

## The code

Write this to `kv1.pas` (it is also `examples/kv1.pas`):

```pascal
program kv1;

{$mode objfpc}{$H+}

uses
  cthreads, SysUtils, fgl, bearings.rt.loop, bearings.http1.role,
  bearings.http.exchange, bearings.server;

type
  TStore = specialize TFPGMap<RawByteString, RawByteString>;

  TKvCall = class(TServiceCall)
  private
    FStore: TStore;
    FLoopIndex: Integer;
  public
    constructor Create(Loop: TLoop);
    destructor Destroy; override;
    function Poll(Ex: TExchange): TCallPoll; override;
  end;

  TKvService = class(THttpService)
  private
    FCall: TKvCall;
  public
    constructor Create(Loop: TLoop);
    destructor Destroy; override;
    function Call(Ex: TExchange): TServiceCall; override;
  end;

constructor TKvCall.Create(Loop: TLoop);
begin
  inherited Create;
  FStore := TStore.Create;
  FLoopIndex := Loop.Index;
end;

destructor TKvCall.Destroy;
begin
  FStore.Free;
  inherited Destroy;
end;

function TKvCall.Poll(Ex: TExchange): TCallPoll;
var
  Path, Key, Value: RawByteString;
  Q: TByteSlice;
begin
  Result := cpReady;
  Ex.ResponseHeaders.Add('x-loop', IntToStr(FLoopIndex));
  Path := SliceToStr(Ex.Path);
  if Copy(Path, 1, 4) <> '/kv/' then
  begin
    Ex.RespondText(404, 'not found'#10);
    Exit;
  end;
  Key := Copy(Path, 5, MaxInt);
  case Ex.Method of
    hmGet:
      if FStore.TryGetData(Key, Value) then
        Ex.RespondText(200, Value + #10)
      else
        Ex.RespondText(404, 'no such key'#10);
    hmPut:
      begin
        if Ex.Query(Q) then
          Value := SliceToStr(Q)
        else
          Value := '';
        FStore[Key] := Value;
        Ex.RespondText(200, 'stored'#10);
      end;
  else
    Ex.RespondText(405, 'method not allowed'#10);
  end;
end;

constructor TKvService.Create(Loop: TLoop);
begin
  inherited Create;
  FCall := TKvCall.Create(Loop);
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

function NewService(Loop: TLoop): THttpService;
begin
  Result := TKvService.Create(Loop);
end;

var
  Cfg: TServerConfig;
  Srv: TServer;
begin
  Cfg := ProductionServerConfig;
  Cfg.Workers := NO_WORKER_POOL;
  Cfg.Listen.Port := StrToIntDef(ParamStr(1), 8080);
  Cfg.Loops := StrToIntDef(ParamStr(2), 0);
  Srv := TServer.CreateWithProc(Cfg, @NewService);
  Srv.RunUntilSignalProc(nil);
  Srv.Free;
end.
```

New here:

- `RespondText(Status, Text)` sets the status, sets the `Content-Type`
  header (`text/plain; charset=utf-8` by default) and responds with the
  text, in one call. It is the right tool for error answers and for
  handlers that build a string anyway.
- The call object now has state, a map, so there is one per loop, created
  with the service. The factory receives the `TLoop`, and `Loop.Index` is
  the loop's number, which the program reports in an `x-loop` header so we
  can see which loop answered.
- `Cfg.Loops` is the number of event loops; 0 means one per CPU. The
  program takes it from the command line so we can experiment.

## Running it

Start the server with four loops:

```sh
./kv1 8080 4
```

Store a value and read it back a few times:

```sh
$ curl -s -X PUT 'http://127.0.0.1:8080/kv/hello?world'
stored
$ for i in 1 2 3 4 5 6; do curl -si http://127.0.0.1:8080/kv/hello | grep -E 'x-loop|world|no such'; done
x-loop: 2
world
x-loop: 1
no such key
x-loop: 1
no such key
x-loop: 3
no such key
x-loop: 0
no such key
x-loop: 2
world
```

Only one loop has the value. Each `curl` opens a new connection, the
kernel spreads new connections over the four loops, and only the loop that
served the `PUT` has the key. The other three have their own empty map.
Our server has four stores, one per loop, which is what the code asked
for: per-loop state needs no lock, and the library does not share anything
across loops on its own.

Sometimes that is what you want: a cache per loop, a counter per loop
added up at reporting time. For a key-value store it is not. The next
chapter shares the map.

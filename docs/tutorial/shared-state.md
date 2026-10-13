# Shared state

To share the map, we keep one `TStore` for the whole server and protect
it with a lock. Every loop reaches it through the same object.

## The code

`kv2.pas` (also `examples/kv2.pas`) is `kv1.pas` with the store pulled out of the call:

```pascal
program kv2;

{$mode objfpc}{$H+}

uses
  cthreads, SysUtils, fgl, syncobjs, bearings.rt.loop, bearings.http1.role,
  bearings.http.exchange, bearings.server;

type
  TMap = specialize TFPGMap<RawByteString, RawByteString>;

  { one for the whole server; every loop uses it under the lock }
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

  TKvCall = class(TServiceCall)
  private
    FStore: TStore;
  public
    constructor Create(Store: TStore);
    function Poll(Ex: TExchange): TCallPoll; override;
  end;

  TKvService = class(THttpService)
  private
    FCall: TKvCall;
  public
    constructor Create(Store: TStore);
    destructor Destroy; override;
    function Call(Ex: TExchange): TServiceCall; override;
  end;

  TApp = class
    Store: TStore;
    function NewService(Loop: TLoop): THttpService;
  end;

constructor TStore.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FMap := TMap.Create;
end;

destructor TStore.Destroy;
begin
  FMap.Free;
  FLock.Free;
  inherited Destroy;
end;

function TStore.Get(const Key: RawByteString; out Value: RawByteString): Boolean;
begin
  FLock.Enter;
  try
    Result := FMap.TryGetData(Key, Value);
  finally
    FLock.Leave;
  end;
end;

procedure TStore.Put(const Key, Value: RawByteString);
begin
  FLock.Enter;
  try
    FMap[Key] := Value;
  finally
    FLock.Leave;
  end;
end;

constructor TKvCall.Create(Store: TStore);
begin
  inherited Create;
  FStore := Store;
end;

function TKvCall.Poll(Ex: TExchange): TCallPoll;
var
  Path, Key, Value: RawByteString;
  Q: TByteSlice;
begin
  Result := cpReady;
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
        if Ex.Query(Q) then
          Value := SliceToStr(Q)
        else
          Value := '';
        FStore.Put(Key, Value);
        Ex.RespondText(200, 'stored'#10);
      end;
  else
    Ex.RespondText(405, 'method not allowed'#10);
  end;
end;

constructor TKvService.Create(Store: TStore);
begin
  inherited Create;
  FCall := TKvCall.Create(Store);
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
  Result := TKvService.Create(Store);
end;

var
  Cfg: TServerConfig;
  App: TApp;
  Srv: TServer;
begin
  Cfg := ProductionServerConfig;
  Cfg.Workers := NO_WORKER_POOL;
  Cfg.Listen.Port := StrToIntDef(ParamStr(1), 8080);
  App := TApp.Create;
  App.Store := TStore.Create;
  Srv := TServer.Create(Cfg, @App.NewService);
  Srv.RunUntilSignal(nil);
  Srv.Free;
  App.Store.Free;
  App.Free;
end.
```

The factory is now a method, `TApp.NewService`, because it has to reach
the store, so the program uses `TServer.Create` and `RunUntilSignal`
instead of the `Proc` forms. The store is freed after the server, when no
loop can touch it any more.

```sh
$ ./kv2 8080 &
$ curl -s -X PUT 'http://127.0.0.1:8080/kv/hello?world'
stored
$ for i in 1 2 3 4; do curl -s http://127.0.0.1:8080/kv/hello; done
world
world
world
world
```

## Locks on the loop thread

The rule from [Hello Bearings](hello-bearings.md) was that a loop thread must never block. A lock
blocks when another thread holds it. So a lock is acceptable on the loop
thread only when every holder keeps it for a few instructions: a map
lookup, an increment, a copy. Our `TStore` does that: the string copy
happens inside the lock, and nothing else.

What must not happen under the lock: I/O, `Sleep`, a call into code that
may take another lock, or anything that waits on a worker. If the work
under the lock is long, it belongs on a worker thread ([Blocking code: the worker pool](workers.md)), where
blocking is allowed.

With many loops hammering one lock, the lock itself becomes the limit.
Two ways out, both outside the library:

- **Shard.** Keep N stores, each with its own lock, and pick one by a
  hash of the key. Contention drops by N.
- **Keep the state per loop and send messages.** Every loop has an inbox
  (`TLoop.Post`); a thread can post a message that runs a procedure on
  the loop, and the loop handles it between its sockets. The WebSocket
  pub/sub of [WebSocket](websocket.md) is built this way: one publish becomes one message
  per loop, and each loop delivers to its own connections with no lock on
  the connection list.

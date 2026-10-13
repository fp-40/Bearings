{ kv2 - the key-value store of kv1.pas with one store shared by every
  loop under a critical section (docs/tutorial/shared-state.md).

  The store is one object for the server; the loops reach it through the
  factory method TApp.NewService. The lock is held only for the map
  lookup or insert and the string copy: a loop thread may wait on a lock
  that every holder keeps for a few instructions, and on nothing longer.

  Usage: kv2 [port]           (default 8080)
  Try:   curl -X PUT 'http://127.0.0.1:8080/kv/hello?world'
         curl http://127.0.0.1:8080/kv/hello
  Build: see examples/README.md }
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

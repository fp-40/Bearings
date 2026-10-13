{ kv1 - a key-value store over HTTP with one store per event loop
  (docs/tutorial/handling-requests.md).

  GET /kv/<key> answers the value, PUT /kv/<key>?<value> stores the query
  string as the value. The map lives in the call object, and there is one
  call object per loop, so a value stored on one loop is not seen by the
  others: the x-loop response header shows which loop answered. This is
  the starting point of the tutorial's shared-state chapter (kv2.pas).

  Usage: kv1 [port [loops]]   (default 8080; 0 loops = one per CPU)
  Try:   curl -X PUT 'http://127.0.0.1:8080/kv/hello?world'
         curl -i http://127.0.0.1:8080/kv/hello    (repeat: x-loop varies)
  Build: see examples/README.md }
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

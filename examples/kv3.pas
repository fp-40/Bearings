{ kv3 - the key-value store of kv2.pas on the worker pool, with the value
  read from the request body (docs/index.md, chapter 5).

  Every request is handed to a worker thread (TOffloadCall,
  TBlockingHandler). PUT /kv/<key> reads the body with ReadAll (a blocking
  read, allowed on a worker) up to VALUE_LIMIT bytes and handles
  EBodyTooLarge (413), EBodyError (400) and EClientGone (nothing to send).

  Usage: kv3 [port]           (default 8080)
  Try:   curl -X PUT --data-binary 'world' http://127.0.0.1:8080/kv/hello
         curl http://127.0.0.1:8080/kv/hello
  Build: see examples/README.md }
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

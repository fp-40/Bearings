{ hello - the smallest bearings server: one TServer with the production
  configuration and one service that answers "Hello" to every request.

  The request is answered inline, on the loop thread, inside the call's
  Poll: no worker thread is involved. The body is static memory
  (BodyStatic), so nothing is allocated per request. The encoder adds the
  Content-Length and Date headers itself.

  Usage: hello [port]        (default 8080; 0 = a free port, printed on stderr)
  Stop:  SIGTERM or SIGINT (Ctrl-C); RunUntilSignal then stops the server
         gracefully and returns.
  Build: see examples/README.md }
program hello;

{$mode objfpc}{$H+}

uses
  cthreads, SysUtils, bearings.rt.loop, bearings.rt.buf, bearings.http.headers, bearings.http.exchange, bearings.server;

const
  GREETING: array[0..5] of AnsiChar = 'Hello'#10;

type
  { One request. Poll runs on the loop thread each time the connection runs
    while the call is in flight; this call answers at once. }
  THelloCall = class(TServiceCall)
  public
    function Poll(Ex: TExchange): TCallPoll; override;
  end;

  { The application, one instance per loop (TServiceFactory). The call is
    stateless, so one instance serves every request of the loop. }
  THelloService = class(THttpService)
  private
    FCall: THelloCall;
  public
    constructor Create;
    destructor Destroy; override;
    function Call(Ex: TExchange): TServiceCall; override;
  end;

  { Holds the server so the factory and the Started callback can be methods. }
  TApp = class
    Srv: TServer;
    function NewService(Loop: TLoop): THttpService;
    procedure Started(Server: TServer);
  end;

function THelloCall.Poll(Ex: TExchange): TCallPoll;
begin
  Ex.ResponseHeaders.Add('content-type', 'text/plain');
  Ex.Respond(BodyStatic(@GREETING[0], Length(GREETING)));
  Result := cpReady;
end;

constructor THelloService.Create;
begin
  inherited Create;
  FCall := THelloCall.Create;
end;

destructor THelloService.Destroy;
begin
  FCall.Free;
  inherited Destroy;
end;

function THelloService.Call(Ex: TExchange): TServiceCall;
begin
  Result := FCall;
end;

function TApp.NewService(Loop: TLoop): THttpService;
begin
  Result := THelloService.Create;
end;

procedure TApp.Started(Server: TServer);
begin
  WriteLn(StdErr, 'hello: listening on port ', Server.Port, ' with ', Server.LoopCount, ' loops');
end;

var
  Cfg: TServerConfig;
  App: TApp;
  Sig: Integer;
begin
  Cfg := ProductionServerConfig;
  Cfg.Listen.Port := StrToIntDef(ParamStr(1), 8080);
  App := TApp.Create;
  App.Srv := TServer.Create(Cfg, @App.NewService);
  Sig := App.Srv.RunUntilSignal(@App.Started);
  WriteLn(StdErr, 'hello: stopped (signal ', Sig, ')');
  App.Srv.Free;
  App.Free;
end.

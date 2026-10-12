{ plaintext - the bearings side of the M3 performance gate (design
  m3-transport.md 7.6, step S5): TServer with the TFB options of hyper's
  entry (BenchmarkServerConfig: no timer, pipeline_flush on,
  serve_connection without upgrades, one SO_REUSEPORT listener per loop,
  TCP_NODELAY, backlog 4096) and the inline service of design 3.1.

  Routes, as bench/hyper-tfb/src/main.rs:
    /plaintext  200, server, content-type: text/plain, content-length: 13,
                "Hello, world!"
    /ping       200, "pong"
    otherwise   404, server
  The response bytes equal hyper's after date normalization: the header
  "server: hyper" becomes "server: wd-40" (same length); SERVER=hyper keeps
  hyper's value (for a byte-for-byte cmp).

  The call is a stateless singleton: no allocation, no atomic instruction,
  no string per request; the exchange is the connection's reused one and
  the body is static memory (BodyStatic).

  S7: OFFLOAD=1 answers every request from the worker pool instead (the
  same routes and bytes; TOffloadCall + a TBlockingHandler that builds the
  response on a worker, design 3.5), for the offload-cost measurement of
  bench/run_offload.sh. WORKERS=n sets the pool size (default 0:
  Min(32, DefaultLoopCount + 4), the prototype's 8 with 4 loops).

  Usage: plaintext [port]   env: THREADS=n (default DefaultLoopCount),
                                 PIN=1 (pin loop i to the i-th usable CPU),
                                 SERVER=hyper, OFFLOAD=1, WORKERS=n,
                                 WORKER_SPIN_NS=n (TWorkerPool.SpinNs)
  Build: fpc -Mobjfpc -Sh -O3 -CX -XX -Xs -Fusrc/rt -Fusrc/http -Fusrc/http1
           -Fusrc/server bench/plaintext.pas }
program plaintext;

{$mode objfpc}{$H+}

uses
  cthreads, SysUtils, bearings.rt.loop, bearings.rt.buf, bearings.rt.workers, bearings.http.headers, bearings.http.exchange,
  bearings.server;

const
  HELLO: array[0..12] of AnsiChar = 'Hello, world!';
  PONG: array[0..3] of AnsiChar = 'pong';
  HN_SERVER: array[0..5] of AnsiChar = 'server';
  HN_CTYPE: array[0..11] of AnsiChar = 'content-type';
  HV_TEXT: array[0..9] of AnsiChar = 'text/plain';
  HN_CLEN: array[0..13] of AnsiChar = 'content-length';
  HV_13: array[0..1] of AnsiChar = '13';
  PATH_PLAINTEXT: array[0..9] of AnsiChar = '/plaintext';
  PATH_PING: array[0..4] of AnsiChar = '/ping';

var
  ServerName: array[0..4] of AnsiChar = 'wd-40';

type
  TPlaintextCall = class(TServiceCall)
  public
    function Poll(Ex: TExchange): TCallPoll; override;
  end;

  TPlaintextService = class(THttpService)
  private
    FCall: TPlaintextCall;
  public
    constructor Create;
    destructor Destroy; override;
    function Call(Ex: TExchange): TServiceCall; override;
  end;

  { OFFLOAD=1: the same answer, built on a worker }
  TPlaintextHandler = class(TBlockingHandler)
  public
    procedure Run(Ex: TExchange); override;
  end;

  TOffloadService = class(THttpService)
  private
    FCall: TOffloadCall;
  public
    constructor Create(Pool: TWorkerPool; H: TBlockingHandler);
    destructor Destroy; override;
    function Call(Ex: TExchange): TServiceCall; override;
  end;

  TApp = class
    Srv: TServer;
    Offload: Boolean;
    Handler: TPlaintextHandler;
    function NewService(Loop: TLoop): THttpService;
  end;

procedure Answer(Ex: TExchange); inline;
var
  P: TByteSlice;
  H: THttpHeaders;
begin
  P := Ex.Path;
  H := Ex.ResponseHeaders;
  if (P.Len = 10) and (CompareByte(P.P^, PATH_PLAINTEXT[0], 10) = 0) then
  begin
    H.AddTrusted(@HN_SERVER[0], 6, @ServerName[0], 5);
    H.AddTrusted(@HN_CTYPE[0], 12, @HV_TEXT[0], 10);
    H.AddTrusted(@HN_CLEN[0], 14, @HV_13[0], 2);
    Ex.Respond(BodyStatic(@HELLO[0], 13));
  end
  else if (P.Len = 5) and (CompareByte(P.P^, PATH_PING[0], 5) = 0) then
    Ex.Respond(BodyStatic(@PONG[0], 4))
  else
  begin
    Ex.Status := 404;
    H.AddTrusted(@HN_SERVER[0], 6, @ServerName[0], 5);
    Ex.Respond(BodyEmpty);
  end;
end;

function TPlaintextCall.Poll(Ex: TExchange): TCallPoll;
begin
  Answer(Ex);
  Result := cpReady;
end;

procedure TPlaintextHandler.Run(Ex: TExchange);
begin
  Answer(Ex);
end;

constructor TOffloadService.Create(Pool: TWorkerPool; H: TBlockingHandler);
begin
  inherited Create;
  FCall := TOffloadCall.Create;
  FCall.Pool := Pool;
  FCall.Handler := H;
end;

destructor TOffloadService.Destroy;
begin
  FCall.Free;
  inherited Destroy;
end;

function TOffloadService.Call(Ex: TExchange): TServiceCall;
begin
  Result := FCall;
end;

constructor TPlaintextService.Create;
begin
  inherited Create;
  FCall := TPlaintextCall.Create;
end;

destructor TPlaintextService.Destroy;
begin
  FCall.Free;
  inherited Destroy;
end;

function TPlaintextService.Call(Ex: TExchange): TServiceCall;
begin
  Result := FCall;
end;

function TApp.NewService(Loop: TLoop): THttpService;
begin
  if Offload then
    Result := TOffloadService.Create(Srv.Workers, Handler)
  else
    Result := TPlaintextService.Create;
end;

var
  Cfg: TServerConfig;
  Srv: TServer;
  App: TApp;
begin
  if GetEnvironmentVariable('SERVER') = 'hyper' then
    Move(PAnsiChar('hyper')^, ServerName[0], 5);
  Cfg := BenchmarkServerConfig;
  Cfg.Listen.Port := StrToIntDef(ParamStr(1), 8080);
  Cfg.Loops := StrToIntDef(GetEnvironmentVariable('THREADS'), 0);
  Cfg.PinLoops := GetEnvironmentVariable('PIN') = '1';
  App := TApp.Create;
  App.Offload := GetEnvironmentVariable('OFFLOAD') = '1';
  if App.Offload then
  begin
    Cfg.Workers := StrToIntDef(GetEnvironmentVariable('WORKERS'), 0);
    App.Handler := TPlaintextHandler.Create;
  end;
  Srv := TServer.Create(Cfg, @App.NewService);
  App.Srv := Srv;
  Srv.Start;
  if App.Offload and (GetEnvironmentVariable('WORKER_SPIN_NS') <> '') then
    Srv.Workers.SpinNs := StrToInt64Def(GetEnvironmentVariable('WORKER_SPIN_NS'), DEFAULT_SPIN_NS);
  if App.Offload then
    WriteLn(StdErr, 'plaintext: ', Srv.LoopCount, ' loops, port ', Srv.Port, ' pin=', Cfg.PinLoops,
      ' offload to ', Srv.Workers.ThreadCount, ' workers')
  else
    WriteLn(StdErr, 'plaintext: ', Srv.LoopCount, ' loops, port ', Srv.Port, ' pin=', Cfg.PinLoops);
  Srv.Wait;
  Srv.Free;
  App.Handler.Free;
  App.Free;
end.

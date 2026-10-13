{ delay - a request answered one second later on the loop thread, with no
  worker, through TWakeTimer (docs/tutorial/loops-in-depth.md).

  GET /delay gets a call object of its own (the service creates one per
  request, because the timer is per-request state). Its first Poll arms
  the timer and returns cpPending; the timer wakes the connection, the
  next Poll sees Fired and answers. Drop cancels the timer (the client may
  have left first) and frees the object. Every other path is 404 from a
  shared, stateless call.

  Usage: delay [port]         (default 8080)
  Try:   time curl http://127.0.0.1:8080/delay
  Build: see examples/README.md }
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

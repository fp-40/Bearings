{ beconf - the bearings Pascal conformance server (conformance/SPEC.md; docs/design.md
  section 9). Test tooling: a thin wrapper around bearings.server
  and bearings.http1.*; everything on the wire comes from the HTTP layer.

  Usage: beconf [--executor inline|worker] [--loops N] (--config <path> | --config-json <json>)
  The runner appends --config <path>. Without a config the spec is the empty object.

  One loop on the main thread (the reference server's current-thread
  runtime), one listener with mio's TcpListener::bind options (127.0.0.1:0,
  SO_REUSEADDR, backlog 128, no TCP_NODELAY), "LISTENING <port>" with one
  write(2) before the loop runs. --executor worker (docs/design.md section 9): the
  handlers run on the server's worker pool (TServerConfig.Workers = 0:
  Min(32, DefaultLoopCount + 4) threads) through TOffloadCall
  (beconf.service). --loops N (S8, N >= 1): N loops; loop 0 stays on the
  main thread. With N > 1 the one listening socket (same mio options) is
  shared by every loop in amSharedExclusive mode (EPOLLEXCLUSIVE); with
  N = 1 it is the amSingle listener of loop 0. }
program beconf;

{$mode objfpc}{$H+}

uses
  cthreads, SysUtils, Classes, bearings.rt.loop, bearings.rt.net, bearings.http.exchange, bearings.http1.config,
  bearings.server, beconf.spec, beconf.events, beconf.upgrade, beconf.service, beconf.control;

var
  Server: TServer;

type
  TFactory = class
  public
    Spec: TServerSpec;
    Worker: Boolean;
    function Make(Loop: TLoop): THttpService;
  end;

function TFactory.Make(Loop: TLoop): THttpService;
var
  S: TConfService;
begin
  S := TConfService.Create;
  S.Spec := Spec;
  if Worker then
  begin
    { TServer.Start created the pool before the services }
    S.Pool := Server.Workers;
    S.Blocking := TConfBlockingHandler.Create;
  end;
  Result := S;
end;

procedure Usage;
begin
  WriteLn(StdErr, 'usage: beconf [--executor inline|worker] [--loops N] (--config <server-spec.json> | ',
    '--config-json ''<json>'')');
  WriteLn(StdErr, 'Prints "LISTENING <port>" then one JSON event per line. See conformance/SPEC.md.');
  Halt(2);
end;

procedure Die(const Msg: string);
begin
  WriteLn(StdErr, 'beconf: ', Msg);
  Halt(2);
end;

function ReadFileText(const Path: string): RawByteString;
var
  F: TFileStream;
begin
  F := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Result, F.Size);
    if F.Size > 0 then
      F.ReadBuffer(Result[1], F.Size);
  finally
    F.Free;
  end;
end;

var
  I: Integer;
  Text: RawByteString;
  HaveText: Boolean;
  Executor: string;
  Loops: Integer;
  Spec: TServerSpec;
  Cfg: TServerConfig;
  Obs: TConfObserver;
  Fac: TFactory;
begin
  Executor := 'inline';
  Loops := 1;
  HaveText := False;
  Text := '{}';
  I := 1;
  while I <= ParamCount do
  begin
    if (ParamStr(I) = '--config') and (I < ParamCount) then
    begin
      try
        Text := ReadFileText(ParamStr(I + 1));
      except
        on E: Exception do
          Die('cannot read ' + ParamStr(I + 1) + ': ' + E.Message);
      end;
      HaveText := True;
      Inc(I, 2);
    end
    else if (ParamStr(I) = '--config-json') and (I < ParamCount) then
    begin
      Text := ParamStr(I + 1);
      HaveText := True;
      Inc(I, 2);
    end
    else if (ParamStr(I) = '--executor') and (I < ParamCount) then
    begin
      Executor := ParamStr(I + 1);
      Inc(I, 2);
    end
    else if (ParamStr(I) = '--loops') and (I < ParamCount) then
    begin
      Loops := StrToIntDef(ParamStr(I + 1), -1);
      Inc(I, 2);
    end
    else
      Usage;
  end;
  if not HaveText then
    Text := '{}';
  if (Executor <> 'inline') and (Executor <> 'worker') then
    Die('--executor ' + Executor + ': must be inline or worker');
  if (Loops < 1) or (Loops > 256) then
    Die('--loops: must be 1..256');
  try
    Spec := ParseServerSpec(Text);
  except
    on E: EJsonError do
      Die(E.Message);
    on E: ESpecError do
      Die('invalid server spec: ' + E.Message);
  end;

  Cfg := Default(TServerConfig);
  Cfg.Listen.Host := '127.0.0.1';
  Cfg.Listen.Port := 0;
  Cfg.Listen.Backlog := 128;               { mio TcpListener::bind }
  if Loops = 1 then
    Cfg.Listen.Mode := amSingle
  else
    Cfg.Listen.Mode := amSharedExclusive;
  Cfg.Listen.NoDelay := False;
  Cfg.Loops := Loops;
  Cfg.PinLoops := False;
  Cfg.H1 := Spec.Cfg;
  if Executor = 'worker' then
    Cfg.Workers := 0
  else
    Cfg.Workers := -1;
  Cfg.WorkerQueueLimit := 0;
  Cfg.GraceMs := 0;

  Obs := TConfObserver.Create;
  Obs.Spec := Spec;
  Fac := TFactory.Create;
  Fac.Spec := Spec;
  Fac.Worker := Executor = 'worker';
  Server := TServer.Create(Cfg, @Fac.Make, Obs);
  try
    Server.StartCallerRunsLoop0;
  except
    on E: Exception do
      Die('cannot start: ' + E.Message);
  end;
  EmitLine('LISTENING ' + IntToStr(Server.Port));
  StartControl(Server);
  Server.RunLoop0;
  { the loop only stops through exit or end of stdin, which exit at once }
  Halt(0);
end.

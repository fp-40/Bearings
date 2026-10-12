{ ws_echo - a WebSocket echo server: every text or binary message a client
  sends comes back unchanged.

  A request that asks for an upgrade goes through the WebSocket handshake
  check (CheckRequest); a valid one is accepted with AcceptWebSocket, which
  answers 101 and hands the connection to a TWebSocket with an
  TEchoHandler; an invalid one is answered 400 or 426
  (RespondHandshakeError). Any other request gets a short text answer.
  Everything runs on the loop threads; there is no worker pool.

  The handler shows how to deal with backpressure. A send returns wsFull
  when the connection's output queue holds SendHighWater bytes or more
  (the client does not read fast enough). The TWebSocket then stops
  reading new input, but the messages of the read block in progress are
  still delivered, so the handler keeps them in a backlog and sends them
  from OnWritable, which runs when the queue went down.

  The maximum message size is 16 MiB (DefaultWsConfig), the size the
  Autobahn TestSuite uses in its largest cases. The idle timeout is off,
  so a client may stay connected without sending anything.

  With a third argument `worker` the echo runs on the worker pool instead
  (TWorkerEchoHandler, a TWsWorkerHandler; AcceptWebSocket with the
  server's pool): each message is handled on a worker thread, where a
  handler may block (a database call, for example), one message at a time
  per connection and in order; the answer goes back with PostText /
  PostBinary. The same backlog logic applies to a post refused with
  wsFull (OnWritable runs on the worker too). The loop stops reading a
  connection whose unhandled messages reach ReceiveHighWater.

  Usage: ws_echo [port] [loops] [worker]   (default 9001, 1 loop; 0 loops = one per CPU)
  Stop:  SIGTERM or SIGINT.
  Build: see examples/README.md }
program ws_echo;

{$mode objfpc}{$H+}

uses
  cthreads, SysUtils, Classes, bearings.rt.loop, bearings.rt.buf, bearings.http.headers,
  bearings.http.exchange, bearings.server, bearings.ws.frame, bearings.ws.handshake,
  bearings.ws.conn;

type
  TEchoHandler = class(TWebSocketHandler)
  private
    FBacklog: array of record Text: Boolean; Data: RawByteString; end;
    FCount: Integer;
    procedure Echo(WS: TWebSocket; Text: Boolean; P: PByte; Len: SizeInt);
  public
    procedure OnText(WS: TWebSocket; P: PByte; Len: SizeInt); override;
    procedure OnBinary(WS: TWebSocket; P: PByte; Len: SizeInt); override;
    procedure OnWritable(WS: TWebSocket); override;
  end;

  { the same echo on the worker pool: Msg is the handler's own copy }
  TWorkerEchoHandler = class(TWsWorkerHandler)
  private
    FBacklog: array of record Text: Boolean; Data: RawByteString; end;
    FCount: Integer;
    procedure Echo(WS: TWebSocket; Text: Boolean; const Msg: RawByteString);
  public
    procedure OnText(WS: TWebSocket; const Msg: RawByteString); override;
    procedure OnBinary(WS: TWebSocket; const Msg: RawByteString); override;
    procedure OnWritable(WS: TWebSocket); override;
  end;

  TEchoCall = class(TServiceCall)
  public
    function Poll(Ex: TExchange): TCallPoll; override;
  end;

  TEchoService = class(THttpService)
  private
    FCall: TEchoCall;
  public
    constructor Create;
    destructor Destroy; override;
    function Call(Ex: TExchange): TServiceCall; override;
  end;

var
  WsCfg: TWsConfig;
  Srv: TServer;
  WorkerMode: Boolean;

procedure TEchoHandler.Echo(WS: TWebSocket; Text: Boolean; P: PByte; Len: SizeInt);
var
  R: TWsSendResult;
begin
  R := wsFull;
  if FCount = 0 then
    if Text then
      R := WS.SendText(P, Len)
    else
      R := WS.SendBinary(P, Len);
  if R <> wsFull then
    Exit;                            { sent, or the connection is closing }
  { keep the message (P is valid only during the call) and send it later }
  if FCount = Length(FBacklog) then
    SetLength(FBacklog, 4 + 2 * FCount);
  FBacklog[FCount].Text := Text;
  SetString(FBacklog[FCount].Data, PAnsiChar(P), Len);
  Inc(FCount);
end;

procedure TEchoHandler.OnText(WS: TWebSocket; P: PByte; Len: SizeInt);
begin
  Echo(WS, True, P, Len);
end;

procedure TEchoHandler.OnBinary(WS: TWebSocket; P: PByte; Len: SizeInt);
begin
  Echo(WS, False, P, Len);
end;

procedure TEchoHandler.OnWritable(WS: TWebSocket);
var
  I, Sent: Integer;
  R: TWsSendResult;
begin
  Sent := 0;
  while Sent < FCount do
  begin
    if FBacklog[Sent].Text then
      R := WS.SendText(FBacklog[Sent].Data)
    else
      R := WS.SendBinary(FBacklog[Sent].Data);
    if R = wsFull then
      Break;                         { OnWritable comes again }
    Inc(Sent);
  end;
  for I := Sent to FCount - 1 do
    FBacklog[I - Sent] := FBacklog[I];
  for I := FCount - Sent to FCount - 1 do
    FBacklog[I].Data := '';
  Dec(FCount, Sent);
end;

{ ---- the worker-pool echo ---- }

procedure TWorkerEchoHandler.Echo(WS: TWebSocket; Text: Boolean; const Msg: RawByteString);
var
  R: TWsSendResult;
begin
  { a blocking call (a database, a file) would go here }
  R := wsFull;
  if FCount = 0 then
    if Text then
      R := WS.PostText(Msg)
    else
      R := WS.PostBinary(Msg);
  if R <> wsFull then
    Exit;
  if FCount = Length(FBacklog) then
    SetLength(FBacklog, 4 + 2 * FCount);
  FBacklog[FCount].Text := Text;
  FBacklog[FCount].Data := Msg;
  Inc(FCount);
end;

procedure TWorkerEchoHandler.OnText(WS: TWebSocket; const Msg: RawByteString);
begin
  Echo(WS, True, Msg);
end;

procedure TWorkerEchoHandler.OnBinary(WS: TWebSocket; const Msg: RawByteString);
begin
  Echo(WS, False, Msg);
end;

procedure TWorkerEchoHandler.OnWritable(WS: TWebSocket);
var
  I, Sent: Integer;
  R: TWsSendResult;
begin
  Sent := 0;
  while Sent < FCount do
  begin
    if FBacklog[Sent].Text then
      R := WS.PostText(FBacklog[Sent].Data)
    else
      R := WS.PostBinary(FBacklog[Sent].Data);
    if R = wsFull then
      Break;
    Inc(Sent);
  end;
  for I := Sent to FCount - 1 do
    FBacklog[I - Sent] := FBacklog[I];
  for I := FCount - Sent to FCount - 1 do
    FBacklog[I].Data := '';
  Dec(FCount, Sent);
end;

function TEchoCall.Poll(Ex: TExchange): TCallPoll;
var
  R: TWsHandshake;
begin
  if Ex.WantsUpgrade then
  begin
    R := CheckRequest(Ex, []);
    if not R.Ok then
      RespondHandshakeError(Ex, R)
    else if WorkerMode then
      AcceptWebSocket(Ex, R, TWorkerEchoHandler.Create, Srv.Workers, WsCfg)
    else
      AcceptWebSocket(Ex, R, TEchoHandler.Create, WsCfg);
  end
  else
    Ex.RespondText(200, 'ws_echo: connect with a WebSocket client'#10);
  Result := cpReady;
end;

constructor TEchoService.Create;
begin
  inherited Create;
  FCall := TEchoCall.Create;
end;

destructor TEchoService.Destroy;
begin
  FCall.Free;
  inherited Destroy;
end;

function TEchoService.Call(Ex: TExchange): TServiceCall;
begin
  Result := FCall;
end;

function NewService(Loop: TLoop): THttpService;
begin
  Result := TEchoService.Create;
end;

procedure Started(Server: TServer);
begin
  if WorkerMode then
    WriteLn(StdErr, 'ws_echo: listening on port ', Server.Port, ' with ', Server.LoopCount, ' loops, echo on ',
      Server.Workers.ThreadCount, ' workers')
  else
    WriteLn(StdErr, 'ws_echo: listening on port ', Server.Port, ' with ', Server.LoopCount, ' loops');
end;

var
  Cfg: TServerConfig;
  Sig: Integer;
begin
  WsCfg := DefaultWsConfig;
  WsCfg.IdleTimeoutMs := 0;
  WorkerMode := ParamStr(3) = 'worker';
  Cfg := ProductionServerConfig;              { connection mode cmWithUpgrades }
  if not WorkerMode then
    Cfg.Workers := NO_WORKER_POOL;            { else the production pool: Min(32, cpus + 4) threads }
  Cfg.Listen.Port := StrToIntDef(ParamStr(1), 9001);
  Cfg.Loops := StrToIntDef(ParamStr(2), 1);
  Srv := TServer.CreateWithProc(Cfg, @NewService);
  Sig := Srv.RunUntilSignalProc(@Started);
  WriteLn(StdErr, 'ws_echo: stopped (signal ', Sig, ')');
  Srv.Free;
end.

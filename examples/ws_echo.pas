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

  Usage: ws_echo [port] [loops]   (default 9001, 1 loop; 0 loops = one per CPU)
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

function TEchoCall.Poll(Ex: TExchange): TCallPoll;
var
  R: TWsHandshake;
begin
  if Ex.WantsUpgrade then
  begin
    R := CheckRequest(Ex, []);
    if R.Ok then
      AcceptWebSocket(Ex, R, TEchoHandler.Create, WsCfg)
    else
      RespondHandshakeError(Ex, R);
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
  WriteLn(StdErr, 'ws_echo: listening on port ', Server.Port, ' with ', Server.LoopCount, ' loops');
end;

var
  Cfg: TServerConfig;
  Srv: TServer;
  Sig: Integer;
begin
  WsCfg := DefaultWsConfig;
  WsCfg.IdleTimeoutMs := 0;
  Cfg := ProductionServerConfig;              { connection mode cmWithUpgrades }
  Cfg.Workers := NO_WORKER_POOL;
  Cfg.Listen.Port := StrToIntDef(ParamStr(1), 9001);
  Cfg.Loops := StrToIntDef(ParamStr(2), 1);
  Srv := TServer.CreateWithProc(Cfg, @NewService);
  Sig := Srv.RunUntilSignalProc(@Started);
  WriteLn(StdErr, 'ws_echo: stopped (signal ', Sig, ')');
  Srv.Free;
end.

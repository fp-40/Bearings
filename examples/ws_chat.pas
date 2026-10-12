{ ws_chat - a WebSocket chat with rooms, on the pub/sub topics of
  bearings.ws.topics.

  A client joins a room with the path (/room/<name>) or, on the path /,
  with a first message 'join <name>'. Every text message it sends after
  that is published to the room's topic, 'chat/<name>', and reaches every
  member of the room on every loop, except the sender (the Exclude
  parameter of Publish); the sender gets nothing back. A member may also
  send 'leave' to leave the room, and 'join <name>' again to change room.

  The registry (TWsTopics) is one object for the server: the handler
  subscribes the connection in OnOpen (or when the join message arrives)
  and publishes from OnText; the subscriptions go away with the connection
  (OnClose has nothing to do). A member whose output queue is at the mark
  (it does not read) misses the messages published meanwhile; with
  Topics.CloseOnBackpressure := True it would be disconnected instead.

  Try it with two terminals (websocat, or any client):
    websocat ws://127.0.0.1:9002/room/general
    websocat ws://127.0.0.1:9002/room/general

  Usage: ws_chat [port] [loops]   (default 9002, 1 loop; 0 loops = one per CPU)
  Stop:  SIGTERM or SIGINT.
  Build: see examples/README.md }
program ws_chat;

{$mode objfpc}{$H+}

uses
  cthreads, SysUtils, Classes, bearings.rt.loop, bearings.http.headers,
  bearings.http.exchange, bearings.server, bearings.ws.frame, bearings.ws.handshake,
  bearings.ws.conn, bearings.ws.topics;

type
  TChatHandler = class(TWebSocketHandler)
  private
    FRoom: RawByteString;            { '' until the client joined }
    procedure Join(WS: TWebSocket; const Room: RawByteString);
  public
    Room: RawByteString;             { the room of the path, or '' }
    procedure OnOpen(WS: TWebSocket); override;
    procedure OnText(WS: TWebSocket; P: PByte; Len: SizeInt); override;
  end;

  TChatCall = class(TServiceCall)
  public
    function Poll(Ex: TExchange): TCallPoll; override;
  end;

  TChatService = class(THttpService)
  private
    FCall: TChatCall;
  public
    constructor Create;
    destructor Destroy; override;
    function Call(Ex: TExchange): TServiceCall; override;
  end;

var
  Topics: TWsTopics;
  WsCfg: TWsConfig;
  Srv: TServer;

procedure TChatHandler.Join(WS: TWebSocket; const Room: RawByteString);
begin
  if FRoom <> '' then
    Topics.Unsubscribe(WS, 'chat/' + FRoom);
  FRoom := Room;
  if FRoom <> '' then
    Topics.Subscribe(WS, 'chat/' + FRoom);
end;

procedure TChatHandler.OnOpen(WS: TWebSocket);
begin
  if Room <> '' then
    Join(WS, Room);
end;

procedure TChatHandler.OnText(WS: TWebSocket; P: PByte; Len: SizeInt);
var
  Msg: RawByteString;
begin
  SetString(Msg, PAnsiChar(P), Len);
  if Copy(Msg, 1, 5) = 'join ' then
    Join(WS, Copy(Msg, 6, MaxInt))
  else if Msg = 'leave' then
    Join(WS, '')
  else if FRoom = '' then
    WS.SendText('join a room first: join <name>')
  else if not WsTopicValid(FRoom) then
    WS.SendText('not a valid room name')
  else
    Topics.Publish('chat/' + FRoom, Msg, WS);   { everyone in the room but the sender }
end;

function TChatCall.Poll(Ex: TExchange): TCallPoll;
var
  R: TWsHandshake;
  H: TChatHandler;
  Path: RawByteString;
begin
  if Ex.WantsUpgrade then
  begin
    R := CheckRequest(Ex, []);
    if not R.Ok then
      RespondHandshakeError(Ex, R)
    else
    begin
      H := TChatHandler.Create;
      Path := SliceToStr(Ex.Path);
      if Copy(Path, 1, 6) = '/room/' then
        H.Room := Copy(Path, 7, MaxInt);
      AcceptWebSocket(Ex, R, H, WsCfg);
    end;
  end
  else
    Ex.RespondText(200, 'ws_chat: connect with a WebSocket client to /room/<name>, or to / and send "join <name>"'#10);
  Result := cpReady;
end;

constructor TChatService.Create;
begin
  inherited Create;
  FCall := TChatCall.Create;
end;

destructor TChatService.Destroy;
begin
  FCall.Free;
  inherited Destroy;
end;

function TChatService.Call(Ex: TExchange): TServiceCall;
begin
  Result := FCall;
end;

function NewService(Loop: TLoop): THttpService;
begin
  Result := TChatService.Create;
end;

procedure Started(Server: TServer);
begin
  WriteLn(StdErr, 'ws_chat: listening on port ', Server.Port, ' with ', Server.LoopCount, ' loops');
end;

var
  Cfg: TServerConfig;
  Sig: Integer;
begin
  WsCfg := DefaultWsConfig;
  Topics := TWsTopics.Create;
  Cfg := ProductionServerConfig;              { connection mode cmWithUpgrades }
  Cfg.Workers := NO_WORKER_POOL;              { everything runs on the loops }
  Cfg.Listen.Port := StrToIntDef(ParamStr(1), 9002);
  Cfg.Loops := StrToIntDef(ParamStr(2), 1);
  Srv := TServer.CreateWithProc(Cfg, @NewService);
  Sig := Srv.RunUntilSignalProc(@Started);
  WriteLn(StdErr, 'ws_chat: stopped (signal ', Sig, ')');
  Srv.Free;
  Topics.Free;                                { after the server: every connection has ended }
end.

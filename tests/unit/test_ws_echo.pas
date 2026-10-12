{ WebSocket over real sockets: a TServer in this process (connection mode
  cmWithUpgrades) with the echo service of examples/ws_echo.pas, and
  blocking clients written here. Covered: the 101 answer and its headers,
  the first frame sent in the same packet as the handshake (the leftover
  bytes of the hand-off), echo of every length form up to 3 MiB and of a
  fragmented message, the close handshake (echoed code, then end of
  stream), the 400 and 426 refusals and a plain request on the same
  service, the subprotocol header, 16 clients on 2 loops at once, a client
  that floods without reading (backpressure; every echo arrives in order),
  and a client that disconnects in the middle of a frame (the connection
  object is freed).
  Run: test_ws_echo --all --format=plain }
program test_ws_echo;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Classes, SysUtils, StrUtils, BaseUnix, Sockets, ctypes, fpcunit, testregistry, consoletestrunner,
  bearings.rt.loop, bearings.rt.buf, bearings.http.headers, bearings.http.exchange, bearings.http1.config,
  bearings.server,
  bearings.ws.frame, bearings.ws.handshake, bearings.ws.conn, bearings.test.ws;

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

  { a room: every text message a member sends goes to every member, on
    every loop (one prepared frame, one TLoop.Post per loop) }
  TRoomHandler = class(TWebSocketHandler)
  public
    procedure OnOpen(WS: TWebSocket); override;
    procedure OnText(WS: TWebSocket; P: PByte; Len: SizeInt); override;
    procedure OnClose(WS: TWebSocket; Code: Word; const Reason: RawByteString); override;
  end;

  TBroadcast = class
  public
    Msg: TLoopMsg;
    Frame: TWsFrame;
    Index: Integer;
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

  TClient = class
  public
    Fd: cint;
    Buf: RawByteString;
    constructor Connect(Port: Word);
    destructor Destroy; override;
    procedure SendAll(const S: RawByteString);
    function Recv(Wait: Boolean = True): Boolean;     { False: EOF, error or timeout }
    function Head: RawByteString;                      { the HTTP head, removed from Buf }
    function Frame(out F: TServerFrame): Boolean;
    function Handshake(const Extra: RawByteString = ''; const First: RawByteString = '';
      const Path: RawByteString = '/echo'): RawByteString;
    function AtEof: Boolean;
  end;

  TClientThread = class(TThread)
  public
    Port: Word;
    N: Integer;
    Id: Integer;
    Error: string;
    procedure Execute; override;
  end;

  TFloodReader = class(TThread)
  public
    C: TClient;
    N, Size, Got: Integer;
    Error: string;
    procedure Execute; override;
  end;

  TTestWsEcho = class(TTestCase)
  private
    Srv: TServer;
    Live0: LongInt;
    procedure StartServer(Loops: Integer);
    procedure WaitFreed;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure Handshake_echo_and_close;
    procedure Refusals_and_plain_requests;
    procedure Subprotocol_header;
    procedure Many_clients_on_two_loops;
    procedure Flood_without_reading;
    procedure Disconnect_mid_frame_frees_the_connection;
    procedure Server_stop_closes_websockets;
    procedure Server_stop_aborts_at_the_deadline;
    procedure Origin_refused_with_403;
    procedure Broadcast_to_a_room_on_two_loops;
  end;

const
  CRLF = #13#10;
  KEY = 'dGhlIHNhbXBsZSBub25jZQ==';

var
  WsCfg: TWsConfig;
  RoomLoops: array[0..7] of TLoop;   { set by NewService, one per loop }
  Rooms: array[0..7] of TList;       { the members on each loop; that loop's thread only }
  RoomMembers: LongInt;

procedure TRoomHandler.OnOpen(WS: TWebSocket);
begin
  Rooms[WS.Loop.Index].Add(WS);
  InterLockedIncrement(RoomMembers);
end;

procedure TRoomHandler.OnClose(WS: TWebSocket; Code: Word; const Reason: RawByteString);
begin
  Rooms[WS.Loop.Index].Remove(WS);
  InterLockedDecrement(RoomMembers);
end;

procedure BroadcastProc(Loop: TLoop; Arg: Pointer);
var
  B: TBroadcast;
  I: Integer;
begin
  B := TBroadcast(Arg);
  for I := 0 to Rooms[B.Index].Count - 1 do
    TWebSocket(Rooms[B.Index][I]).SendFrame(B.Frame);
  B.Free;
end;

procedure TRoomHandler.OnText(WS: TWebSocket; P: PByte; Len: SizeInt);
var
  F: TWsFrame;
  B: TBroadcast;
  I: Integer;
begin
  F := WsMakeFrame(WS_OP_TEXT, P, Len);   { encoded once for everyone }
  for I := 0 to High(RoomLoops) do
    if RoomLoops[I] <> nil then
    begin
      B := TBroadcast.Create;
      B.Frame := F;
      B.Index := I;
      B.Msg.Kind := lmCall;
      B.Msg.Proc := @BroadcastProc;
      B.Msg.Arg := B;
      RoomLoops[I].Post(@B.Msg);
    end;
end;

{ ---- the echo service (as in examples/ws_echo.pas) ---- }

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
    Exit;
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
    R := CheckRequest(Ex, ['chat'], ['http://localhost']);
    if R.Ok and PathIs(Ex, '/room') then
      AcceptWebSocket(Ex, R, TRoomHandler.Create, WsCfg)
    else if R.Ok then
      AcceptWebSocket(Ex, R, TEchoHandler.Create, WsCfg)
    else
      RespondHandshakeError(Ex, R);
  end
  else
    Ex.RespondText(200, 'plain'#10);
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
  RoomLoops[Loop.Index] := Loop;
  Result := TEchoService.Create;
end;

{ ---- the client ---- }

constructor TClient.Connect(Port: Word);
var
  A: TInetSockAddr;
  TV: TTimeVal;
begin
  inherited Create;
  Fd := fpSocket(AF_INET, SOCK_STREAM, 0);
  A.sin_family := AF_INET;
  A.sin_port := htons(Port);
  A.sin_addr.s_addr := htonl($7F000001);
  if fpConnect(Fd, @A, SizeOf(A)) <> 0 then
    raise Exception.Create('connect failed');
  TV.tv_sec := 10;
  TV.tv_usec := 0;
  fpSetSockOpt(Fd, SOL_SOCKET, SO_RCVTIMEO, @TV, SizeOf(TV));
end;

destructor TClient.Destroy;
begin
  if Fd >= 0 then
    fpClose(Fd);
  inherited Destroy;
end;

procedure TClient.SendAll(const S: RawByteString);
var
  Done, R: SizeInt;
begin
  Done := 0;
  while Done < Length(S) do
  begin
    R := fpSend(Fd, PAnsiChar(S) + Done, Length(S) - Done, MSG_NOSIGNAL);
    if R <= 0 then
      raise Exception.Create('send failed');
    Inc(Done, R);
  end;
end;

function TClient.Recv(Wait: Boolean): Boolean;
var
  B: array[0..65535] of AnsiChar;
  R: ssize_t;
  S: RawByteString;
  Flags: cint;
begin
  Flags := 0;
  if not Wait then
    Flags := MSG_DONTWAIT;
  R := fpRecv(Fd, @B[0], SizeOf(B), Flags);
  if R <= 0 then
    Exit(False);
  SetString(S, PAnsiChar(@B[0]), R);
  Buf := Buf + S;
  Result := True;
end;

function TClient.Head: RawByteString;
var
  P: SizeInt;
begin
  while Pos(CRLF + CRLF, Buf) = 0 do
    if not Recv then
      raise Exception.Create('no HTTP head; got: ' + Buf);
  P := Pos(CRLF + CRLF, Buf);
  Result := Copy(Buf, 1, P + 3);
  Delete(Buf, 1, P + 3);
end;

function TClient.Frame(out F: TServerFrame): Boolean;
begin
  while not TakeServerFrame(Buf, F) do
    if not Recv then
      Exit(False);
  Result := True;
end;

function TClient.Handshake(const Extra, First, Path: RawByteString): RawByteString;
begin
  SendAll('GET ' + Path + ' HTTP/1.1' + CRLF + 'Host: x' + CRLF + 'Upgrade: websocket' + CRLF
    + 'Connection: Upgrade' + CRLF + 'Sec-WebSocket-Key: ' + KEY + CRLF
    + 'Sec-WebSocket-Version: 13' + CRLF + Extra + CRLF + First);
  Result := Head;
end;

function TClient.AtEof: Boolean;
var
  B: array[0..255] of AnsiChar;
begin
  Result := (Buf = '') and (fpRecv(Fd, @B[0], SizeOf(B), 0) = 0);
end;

{ ---- client threads ---- }

procedure TClientThread.Execute;
var
  C: TClient;
  I: Integer;
  F: TServerFrame;
  Msg: RawByteString;
begin
  C := nil;
  try
    try
      C := TClient.Connect(Port);
      if not AnsiStartsStr('HTTP/1.1 101', C.Handshake) then
        raise Exception.Create('no 101');
      for I := 1 to N do
      begin
        Msg := 'client ' + IntToStr(Id) + ' message ' + IntToStr(I) + ' ' + Pattern(I mod 300);
        C.SendAll(CFrame(WS_OP_BINARY, Msg));
        if not C.Frame(F) or (F.Opcode <> WS_OP_BINARY) or (F.Payload <> Msg) then
          raise Exception.Create('bad echo of message ' + IntToStr(I));
      end;
      C.SendAll(CFrame(WS_OP_CLOSE, #3#232));
      if not C.Frame(F) or (F.Opcode <> WS_OP_CLOSE) then
        raise Exception.Create('no close frame');
      if not C.AtEof then
        raise Exception.Create('no end of stream');
    except
      on E: Exception do
        Error := E.Message;
    end;
  finally
    C.Free;
  end;
end;

{ ---- the tests ---- }

procedure TTestWsEcho.SetUp;
begin
  Live0 := WebSocketsLive;
  WsCfg := DefaultWsConfig;
  WsCfg.IdleTimeoutMs := 0;
  WsCfg.SendHighWater := 256 * 1024;
end;

procedure TTestWsEcho.TearDown;
var
  I: Integer;
begin
  if Srv <> nil then
  begin
    Srv.Stop(1000);
    Srv.Wait;
    FreeAndNil(Srv);
  end;
  for I := 0 to High(RoomLoops) do
    RoomLoops[I] := nil;
end;

procedure TTestWsEcho.StartServer(Loops: Integer);
var
  Cfg: TServerConfig;
begin
  Cfg := BenchmarkServerConfig;
  Cfg.Listen.Host := '127.0.0.1';
  Cfg.Listen.Port := 0;
  Cfg.Loops := Loops;
  Cfg.Workers := NO_WORKER_POOL;
  Cfg.H1.Mode := cmWithUpgrades;
  Cfg.GraceMs := 1000;
  Srv := TServer.CreateWithProc(Cfg, @NewService);
  Srv.Start;
end;

procedure TTestWsEcho.WaitFreed;
var
  I: Integer;
begin
  for I := 1 to 400 do
  begin
    if WebSocketsLive = Live0 then
      Break;
    Sleep(5);
  end;
  AssertEquals('every TWebSocket freed', Live0, WebSocketsLive);
end;

function HeadHas(const Head, Line: RawByteString): Boolean;
begin
  Result := Pos(LowerCase(CRLF + Line + CRLF), LowerCase(Head)) > 0;
end;

procedure TTestWsEcho.Handshake_echo_and_close;
var
  C: TClient;
  H, Big: RawByteString;
  F: TServerFrame;
  N: Integer;
const
  Lens: array[0..6] of Integer = (0, 1, 125, 126, 65535, 65536, 3 * 1024 * 1024);
begin
  StartServer(1);
  C := TClient.Connect(Srv.Port);
  try
    { the first frame travels with the handshake }
    H := C.Handshake('', CFrame(WS_OP_TEXT, 'first'));
    AssertTrue(H, AnsiStartsStr('HTTP/1.1 101 Switching Protocols' + CRLF, H));
    AssertTrue(H, HeadHas(H, 'upgrade: websocket'));
    AssertTrue(H, HeadHas(H, 'connection: Upgrade'));
    AssertTrue(H, HeadHas(H, 'sec-websocket-accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo='));
    AssertFalse('no subprotocol header', Pos('sec-websocket-protocol', LowerCase(H)) > 0);
    AssertFalse('no content-length', Pos('content-length', LowerCase(H)) > 0);
    AssertTrue(C.Frame(F));
    AssertEquals('first', F.Payload);
    for N in Lens do
    begin
      Big := Pattern(N);
      C.SendAll(CFrame(WS_OP_BINARY, Big));
      AssertTrue('echo of ' + IntToStr(N), C.Frame(F));
      AssertEquals(WS_OP_BINARY, F.Opcode);
      AssertTrue('payload of ' + IntToStr(N), F.Payload = Big);
    end;
    { a fragmented text message comes back as one frame }
    C.SendAll(CFrame(WS_OP_TEXT, 'frag', False) + CFrame(WS_OP_PING, 'p') + CFrame(WS_OP_CONT, 'mented'));
    AssertTrue(C.Frame(F));
    AssertEquals('pong first', WS_OP_PONG, F.Opcode);
    AssertEquals('p', F.Payload);
    AssertTrue(C.Frame(F));
    AssertEquals(WS_OP_TEXT, F.Opcode);
    AssertEquals('fragmented', F.Payload);
    { the close handshake }
    C.SendAll(CFrame(WS_OP_CLOSE, #3#232'bye'));
    AssertTrue(C.Frame(F));
    AssertEquals(WS_OP_CLOSE, F.Opcode);
    AssertEquals(#3#232, F.Payload);
    AssertTrue('the server ends the stream', C.AtEof);
  finally
    C.Free;
  end;
  WaitFreed;
end;

procedure TTestWsEcho.Refusals_and_plain_requests;
var
  C: TClient;
  H: RawByteString;
begin
  StartServer(1);
  C := TClient.Connect(Srv.Port);
  try
    C.SendAll('GET /echo HTTP/1.1' + CRLF + 'Host: x' + CRLF + 'Upgrade: websocket' + CRLF
      + 'Connection: Upgrade' + CRLF + 'Sec-WebSocket-Key: ' + KEY + CRLF
      + 'Sec-WebSocket-Version: 8' + CRLF + CRLF);
    H := C.Head;
    AssertTrue(H, AnsiStartsStr('HTTP/1.1 426', H));
    AssertTrue(H, HeadHas(H, 'sec-websocket-version: 13'));
  finally
    C.Free;
  end;
  C := TClient.Connect(Srv.Port);
  try
    C.SendAll('GET /echo HTTP/1.1' + CRLF + 'Host: x' + CRLF + 'Upgrade: websocket' + CRLF
      + 'Connection: Upgrade' + CRLF + 'Sec-WebSocket-Version: 13' + CRLF + CRLF);
    H := C.Head;
    AssertTrue('missing key: ' + H, AnsiStartsStr('HTTP/1.1 400', H));
  finally
    C.Free;
  end;
  C := TClient.Connect(Srv.Port);
  try
    C.SendAll('GET / HTTP/1.1' + CRLF + 'Host: x' + CRLF + CRLF);
    H := C.Head;
    AssertTrue('plain request: ' + H, AnsiStartsStr('HTTP/1.1 200', H));
  finally
    C.Free;
  end;
  WaitFreed;
end;

procedure TTestWsEcho.Subprotocol_header;
var
  C: TClient;
  H: RawByteString;
begin
  StartServer(1);
  C := TClient.Connect(Srv.Port);
  try
    H := C.Handshake('Sec-WebSocket-Protocol: mqtt, chat' + CRLF);
    AssertTrue(H, HeadHas(H, 'sec-websocket-protocol: chat'));
    C.SendAll(CFrame(WS_OP_CLOSE, ''));
  finally
    C.Free;
  end;
  WaitFreed;
end;

procedure TTestWsEcho.Many_clients_on_two_loops;
var
  Th: array[0..15] of TClientThread;
  I: Integer;
begin
  StartServer(2);
  for I := 0 to High(Th) do
  begin
    Th[I] := TClientThread.Create(True);
    Th[I].Port := Srv.Port;
    Th[I].N := 300;
    Th[I].Id := I;
    Th[I].Start;
  end;
  for I := 0 to High(Th) do
  begin
    Th[I].WaitFor;
    AssertEquals('client ' + IntToStr(I), '', Th[I].Error);
    Th[I].Free;
  end;
  WaitFreed;
end;

procedure TFloodReader.Execute;
var
  I: Integer;
  F: TServerFrame;
begin
  Sleep(300);                        { meanwhile the server's queue fills and it stops reading }
  try
    for I := 1 to N do
    begin
      if not C.Frame(F) then
        raise Exception.Create('no echo ' + IntToStr(I));
      if not AnsiStartsStr(IntToStr(I) + ':', F.Payload) or (Length(F.Payload) <> Length(IntToStr(I)) + 1 + Size) then
        raise Exception.Create('echo ' + IntToStr(I) + ' out of order or cut');
      Inc(Got);
    end;
  except
    on E: Exception do
      Error := E.Message;
  end;
end;

procedure TTestWsEcho.Flood_without_reading;
var
  C: TClient;
  R: TFloodReader;
  F: TServerFrame;
  I: Integer;
const
  N = 2000;
  Size = 10000;                      { 20 MB in all, far over the 256 KiB high-water mark }
begin
  StartServer(1);
  C := TClient.Connect(Srv.Port);
  try
    C.Handshake;
    R := TFloodReader.Create(True);
    R.C := C;
    R.N := N;
    R.Size := Size;
    R.Start;
    { the sender blocks while nobody reads the echoes (TCP backpressure) }
    for I := 1 to N do
      C.SendAll(CFrame(WS_OP_BINARY, IntToStr(I) + ':' + Pattern(Size)));
    R.WaitFor;
    AssertEquals('reader', '', R.Error);
    AssertEquals(N, R.Got);
    R.Free;
    C.SendAll(CFrame(WS_OP_CLOSE, #3#232));
    AssertTrue(C.Frame(F));
    AssertEquals(WS_OP_CLOSE, F.Opcode);
  finally
    C.Free;
  end;
  WaitFreed;
end;

procedure TTestWsEcho.Disconnect_mid_frame_frees_the_connection;
var
  C: TClient;
  S: RawByteString;
  F: TServerFrame;
begin
  StartServer(1);
  C := TClient.Connect(Srv.Port);
  try
    C.Handshake;
    C.SendAll(CFrame(WS_OP_TEXT, 'one'));
    AssertTrue(C.Frame(F));
    S := CFrame(WS_OP_BINARY, Pattern(100000));
    C.SendAll(Copy(S, 1, 50000));
  finally
    C.Free;                          { closes the socket in the middle of the frame }
  end;
  WaitFreed;
end;

procedure TTestWsEcho.Server_stop_closes_websockets;
var
  C: TClient;
  F: TServerFrame;
  T0: QWord;
begin
  StartServer(1);
  C := TClient.Connect(Srv.Port);
  try
    C.Handshake;
    C.SendAll(CFrame(WS_OP_TEXT, 'hi'));
    AssertTrue(C.Frame(F));
    T0 := GetTickCount64;
    Srv.Stop(5000);
    AssertTrue('a close frame', C.Frame(F));
    AssertEquals(WS_OP_CLOSE, F.Opcode);
    AssertEquals(#3#233'server shutdown', F.Payload);
    C.SendAll(CFrame(WS_OP_CLOSE, #3#233));
    AssertTrue('end of stream', C.AtEof);
    fpClose(C.Fd);                   { as a client does after the end of stream }
    C.Fd := -1;
    Srv.Wait;
    AssertTrue('stopped long before the grace period', GetTickCount64 - T0 < 2000);
  finally
    C.Free;
  end;
  FreeAndNil(Srv);
  AssertEquals('every TWebSocket freed', Live0, WebSocketsLive);
end;

procedure TTestWsEcho.Server_stop_aborts_at_the_deadline;
var
  C: TClient;
  F: TServerFrame;
begin
  StartServer(1);
  C := TClient.Connect(Srv.Port);
  try
    C.Handshake;
    C.SendAll(CFrame(WS_OP_TEXT, 'hi'));
    AssertTrue(C.Frame(F));
    Srv.Stop(300);                   { shorter than the 5 s close timeout }
    AssertTrue(C.Frame(F));
    AssertEquals('a close frame, never answered', WS_OP_CLOSE, F.Opcode);
    Srv.Wait;
    AssertTrue('the socket was closed', C.AtEof);
  finally
    C.Free;
  end;
  FreeAndNil(Srv);
  AssertEquals('every TWebSocket freed', Live0, WebSocketsLive);
end;

procedure TTestWsEcho.Origin_refused_with_403;
var
  C: TClient;
  H: RawByteString;
begin
  StartServer(1);
  C := TClient.Connect(Srv.Port);
  try
    H := C.Handshake('Origin: https://evil.example' + CRLF);
    AssertTrue(H, AnsiStartsStr('HTTP/1.1 403', H));
  finally
    C.Free;
  end;
  C := TClient.Connect(Srv.Port);
  try
    H := C.Handshake('Origin: http://localhost' + CRLF);
    AssertTrue(H, AnsiStartsStr('HTTP/1.1 101', H));
    C.SendAll(CFrame(WS_OP_CLOSE, ''));
  finally
    C.Free;
  end;
  WaitFreed;
end;

procedure TTestWsEcho.Broadcast_to_a_room_on_two_loops;
const
  NC = 20;
  NM = 50;
var
  C: array[0..NC - 1] of TClient;
  F: TServerFrame;
  I, K: Integer;
  Body: RawByteString;
begin
  StartServer(2);
  for I := 0 to NC - 1 do
    C[I] := nil;
  try
    for I := 0 to NC - 1 do
    begin
      C[I] := TClient.Connect(Srv.Port);
      AssertTrue(AnsiStartsStr('HTTP/1.1 101', C[I].Handshake('', '', '/room')));
    end;
    for K := 1 to 400 do
      if RoomMembers = NC then Break else Sleep(5);
    AssertEquals('every member joined', NC, RoomMembers);
    Body := StringOfChar('r', 2000);   { over WS_SHARE_MIN: queued by reference when it has to wait }
    for K := 1 to NM do
      C[K mod NC].SendAll(CFrame(WS_OP_TEXT, 'b' + IntToStr(K) + ' ' + Body));
    for I := 0 to NC - 1 do
      for K := 1 to NM do
      begin
        AssertTrue('client ' + IntToStr(I) + ' message ' + IntToStr(K), C[I].Frame(F));
        AssertEquals(WS_OP_TEXT, F.Opcode);
        AssertTrue('content', AnsiEndsStr(Body, F.Payload));
      end;
    for I := 0 to NC - 1 do
    begin
      C[I].SendAll(CFrame(WS_OP_CLOSE, ''));
      AssertTrue(C[I].Frame(F));
      AssertEquals(WS_OP_CLOSE, F.Opcode);
    end;
  finally
    for I := 0 to NC - 1 do
      C[I].Free;
  end;
  WaitFreed;
  AssertEquals(0, RoomMembers);
end;

var
  RI: Integer;
begin
  for RI := 0 to High(Rooms) do
    Rooms[RI] := TList.Create;
  RegisterTest(TTestWsEcho);
  with TTestRunner.Create(nil) do
  try
    Initialize;
    Run;
  finally
    Free;
  end;
  for RI := 0 to High(Rooms) do
    Rooms[RI].Free;
end.

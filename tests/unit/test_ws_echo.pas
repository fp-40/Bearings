{ WebSocket over real sockets: a TServer in this process (connection mode
  cmWithUpgrades) with the echo service of examples/ws_echo.pas, and
  blocking clients written here. Covered: the 101 answer and its headers,
  the first frame sent in the same packet as the handshake (the leftover
  bytes of the hand-off), echo of every length form up to 3 MiB and of a
  fragmented message, the close handshake (echoed code, then end of
  stream), the 400 and 426 refusals and a plain request on the same
  service, the subprotocol header, 16 clients on 2 loops at once, a client
  that floods without reading (backpressure; every echo arrives in order),
  a producer that sends from OnWritable to a client that only reads,
  and a client that disconnects in the middle of a frame (the connection
  object is freed). TTestWsWorker covers the handler on the worker pool
  (TWsWorkerHandler, path /worker): echo in order from a worker thread,
  the receive mark (reading pauses and resumes), an exception (1011),
  PostClose, 16 clients on 2 loops, and a server stop while a handler is
  busy. TTestWsTopics covers the pub/sub topics (bearings.ws.topics, paths
  /topics and /topics-worker, driven by text commands: sub, unsub, pub,
  pubx, pubbig): fan-out on two loops in order, the wildcards, the
  exclusion of the sender, unsubscribe and the removal at close, subscribe
  and publish from a worker handler, a subscriber that does not read
  (DroppedMessages, CloseOnBackpressure), one on the worker pool that
  catches up, and a publish from a plain thread. tests/unit/run_all.sh
  also runs TTestWsWorker and TTestWsTopics under valgrind drd.
  Run: test_ws_echo --all --format=plain
       test_ws_echo --suite=TTestWsWorker --format=plain }
program test_ws_echo;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  {$IFDEF WD_DRD}cmem,{$ENDIF}            { the C heap: drd sees the blocks (as test_workers) }
  Classes, SysUtils, StrUtils, BaseUnix, Sockets, ctypes, fpcunit, testregistry, consoletestrunner,
  bearings.rt.loop, bearings.rt.sync, bearings.rt.workers, bearings.rt.buf, bearings.http.headers,
  bearings.http.exchange, bearings.http1.config, bearings.server,
  bearings.ws.frame, bearings.ws.handshake, bearings.ws.conn, bearings.ws.topics, bearings.test.ws;

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

  { the echo on the worker pool: every event runs on a worker thread;
    'raise' raises, 'close' closes with PostClose; WorkerDelayMs sleeps
    per message (a handler that blocks) }
  TWorkerEcho = class(TWsWorkerHandler)
  private
    FBacklog: array of record Text: Boolean; Data: RawByteString; end;
    FCount: Integer;
    procedure Echo(WS: TWebSocket; Text: Boolean; const Msg: RawByteString);
  public
    procedure OnOpen(WS: TWebSocket); override;
    procedure OnText(WS: TWebSocket; const Msg: RawByteString); override;
    procedure OnBinary(WS: TWebSocket; const Msg: RawByteString); override;
    procedure OnWritable(WS: TWebSocket); override;
    procedure OnError(WS: TWebSocket; Code: Word; const Msg: string); override;
    procedure OnClose(WS: TWebSocket; Code: Word; const Reason: RawByteString); override;
  end;

  { /topics: the topic registry driven by text commands (TopicCommand);
    the answer, if any, comes back as text. OnClose records the dropped
    messages and the aborts. }
  TTopicHandler = class(TWebSocketHandler)
  public
    procedure OnText(WS: TWebSocket; P: PByte; Len: SizeInt); override;
    procedure OnClose(WS: TWebSocket; Code: Word; const Reason: RawByteString); override;
  end;

  { /topics-worker: the same commands from a worker thread (Subscribe is
    posted to the loop; the answer with PostText) }
  TTopicWorker = class(TWsWorkerHandler)
  public
    procedure OnText(WS: TWebSocket; const Msg: RawByteString); override;
    procedure OnClose(WS: TWebSocket; Code: Word; const Reason: RawByteString); override;
  end;

  { publishes N messages to a topic from a thread that is neither a loop
    nor a worker }
  TPublisherThread = class(TThread)
  public
    Topic: RawByteString;
    N: Integer;
    Size: Integer;                   { > 0: binary 'I:' + Size bytes; else text 'tick I' }
    procedure Execute; override;
  end;

  { /produce: the text 'N:Size' starts N binary messages of Size bytes
    ('I:' and a pattern); each send that returns wsFull resumes in
    OnWritable, the usual producer of a handler on the loop }
  TProducer = class(TWebSocketHandler)
  private
    FN, FSize, FSent: Integer;
    procedure Produce(WS: TWebSocket);
  public
    procedure OnText(WS: TWebSocket; P: PByte; Len: SizeInt); override;
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

  TClient = class
  public
    Fd: cint;
    Buf: RawByteString;
    { RcvBuf > 0: SO_RCVBUF set before the connect (no autotuning: a
      small, fixed receive window for a client that does not read) }
    constructor Connect(Port: Word; RcvBuf: Integer = 0);
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
    Path: RawByteString;
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

  TTestWsBase = class(TTestCase)
  protected
    Srv: TServer;
    Live0: LongInt;
    procedure StartServer(Loops: Integer; Workers: Integer = NO_WORKER_POOL);
    procedure WaitFreed;
    procedure SetUp; override;
    procedure TearDown; override;
  end;

  TTestWsEcho = class(TTestWsBase)
  published
    procedure Handshake_echo_and_close;
    procedure Refusals_and_plain_requests;
    procedure Subprotocol_header;
    procedure Many_clients_on_two_loops;
    procedure Flood_without_reading;
    procedure Sends_from_OnWritable_go_out;
    procedure Disconnect_mid_frame_frees_the_connection;
    procedure Server_stop_closes_websockets;
    procedure Server_stop_aborts_at_the_deadline;
    procedure Origin_refused_with_403;
    procedure Broadcast_to_a_room_on_two_loops;
  end;

  TTestWsWorker = class(TTestWsBase)
  published
    procedure Echo_in_order_from_a_worker_thread;
    procedure Receive_mark_pauses_and_resumes_reading;
    procedure Handler_exception_closes_with_1011;
    procedure PostClose_from_the_worker;
    procedure Many_clients_on_two_loops;
    procedure Server_stop_while_a_handler_is_busy;
    procedure Posts_to_a_client_that_does_not_read_are_bounded;
  end;

  TTestWsTopics = class(TTestWsBase)
  private
    function Join(Port: Word; const Path: RawByteString = '/topics'; RcvBuf: Integer = 0): TClient;
    procedure Sub(C: TClient; const Pattern: RawByteString);
    procedure Expect(C: TClient; const Text, Msg: string);
    procedure NoFrame(C: TClient; const Msg: string);
    procedure CloseAll(const C: array of TClient);
    procedure Slow_subscriber(CloseIt: Boolean);
  published
    procedure Fan_out_on_two_loops_in_order;
    procedure Wildcards;
    procedure Exclude_the_sender;
    procedure Unsubscribe_and_removal_at_close;
    procedure Subscribe_and_publish_from_a_worker_handler;
    procedure Slow_subscriber_drops_messages;
    procedure Slow_subscriber_aborted_with_CloseOnBackpressure;
    procedure Slow_worker_subscriber_catches_up;
    procedure Publish_from_a_plain_thread;
    procedure A_burst_of_publishes_reaches_a_reader;
    procedure First_subscriber_of_a_loop_gets_the_next_publish;
    procedure Invalid_patterns_and_topics;
  end;

const
  CRLF = #13#10;
  KEY = 'dGhlIHNhbXBsZSBub25jZQ==';

var
  WsCfg: TWsConfig;
  RoomLoops: array[0..7] of TLoop;   { set by NewService, one per loop }
  Rooms: array[0..7] of TList;       { the members on each loop; that loop's thread only }
  RoomMembers: LongInt;
  ServerForPool: TServer;            { set before Start: /worker uses its Workers }
  IterPct: Integer;                  { WD_ITER: loop counts in percent (the drd run lowers it) }
  WorkerDelayMs: Integer;            { TWorkerEcho sleeps this long per message }
  WorkerOnLoop: LongInt;             { TWorkerEcho events that ran on their loop's thread (must stay 0) }
  WorkerOpens, WorkerCloses: LongInt;
  WorkerCloseCode, WorkerErrCode: LongInt;
  WorkerCloseThread: TThreadID;
  Topics: TWsTopics;                 { created by SetUp, freed after the server by TearDown }
  TopicCloses: LongInt;              { OnClose of the topic handlers }
  TopicDrops: LongInt;               { DroppedMessages of the last closed connection that had any }
  TopicAborts: LongInt;              { OnClose with 1006 }
  FloodTotal: LongInt;               { bytes the worker's 'flood' got wsOk for; -1 until it ends }

{ ---- the topic handlers ---- }

procedure NoteThread(WS: TWebSocket);
begin
  if GetCurrentThreadId = AtomicLoadThreadId(WS.Loop.ThreadId) then
    AtomicInc(WorkerOnLoop);
end;

{ 'sub P', 'unsub P', 'pub T text', 'pubx T text' (everyone but the
  sender), 'pubbig T N' (N bytes, binary), 'pubframe T text', 'subpub T
  text' (subscribe to T, then publish to it at once), 'block MS' (sleeps
  on the thread of the handler: on the loop, it holds the loop); the
  answer or '' }
function TopicCommand(WS: TWebSocket; const Msg: RawByteString): RawByteString;
var
  Cmd, A, B: RawByteString;
  P: Integer;
begin
  P := Pos(' ', Msg);
  if P = 0 then
    Exit('unknown');
  Cmd := Copy(Msg, 1, P - 1);
  B := Copy(Msg, P + 1, MaxInt);
  P := Pos(' ', B);
  if P = 0 then
    A := B
  else
  begin
    A := Copy(B, 1, P - 1);
    B := Copy(B, P + 1, MaxInt);
  end;
  Result := '';
  if Cmd = 'sub' then
  begin
    Topics.Subscribe(WS, A);
    Result := 'subscribed ' + A;
  end
  else if Cmd = 'unsub' then
  begin
    Topics.Unsubscribe(WS, A);
    Result := 'unsubscribed ' + A;
  end
  else if Cmd = 'pub' then
    Topics.Publish(A, B)
  else if Cmd = 'pubx' then
    Topics.Publish(A, B, WS)
  else if Cmd = 'pubbig' then
    Topics.PublishBinary(A, StringOfChar('x', StrToInt(B)))
  else if Cmd = 'pubframe' then
    Topics.PublishFrame(A, WsTextFrame(B))
  else if Cmd = 'subpub' then
  begin
    Topics.Subscribe(WS, A);
    Topics.Publish(A, B);
  end
  else if Cmd = 'block' then
    Sleep(StrToInt(A))
  else
    Result := 'unknown';
end;

procedure TopicClosed(WS: TWebSocket; Code: Word);
begin
  if WS.DroppedMessages > 0 then
    AtomicStore(TopicDrops, LongInt(WS.DroppedMessages));
  if Code = WS_CLOSE_ABNORMAL then
    AtomicInc(TopicAborts);
  HappensBefore(@TopicCloses);       { the test reads the counters after WaitFreed }
  AtomicInc(TopicCloses);
end;

procedure TTopicHandler.OnText(WS: TWebSocket; P: PByte; Len: SizeInt);
var
  Msg, R: RawByteString;
begin
  SetString(Msg, PAnsiChar(P), Len);
  R := TopicCommand(WS, Msg);
  if R <> '' then
    WS.SendText(R);
end;

procedure TTopicHandler.OnClose(WS: TWebSocket; Code: Word; const Reason: RawByteString);
begin
  TopicClosed(WS, Code);
end;

procedure TTopicWorker.OnText(WS: TWebSocket; const Msg: RawByteString);
var
  R: RawByteString;
begin
  NoteThread(WS);
  R := TopicCommand(WS, Msg);
  if R <> '' then
    WS.PostText(R);
end;

procedure TTopicWorker.OnClose(WS: TWebSocket; Code: Word; const Reason: RawByteString);
begin
  TopicClosed(WS, Code);
end;

procedure TPublisherThread.Execute;
var
  I: Integer;
begin
  for I := 1 to N do
    if Size > 0 then
      Topics.PublishBinary(Topic, IntToStr(I) + ':' + Pattern(Size))
    else
      Topics.Publish(Topic, 'tick ' + IntToStr(I));
end;

{ ---- TWorkerEcho ---- }

procedure TWorkerEcho.OnOpen(WS: TWebSocket);
begin
  NoteThread(WS);
  AtomicInc(WorkerOpens);
end;

procedure TWorkerEcho.Echo(WS: TWebSocket; Text: Boolean; const Msg: RawByteString);
var
  R: TWsSendResult;
begin
  NoteThread(WS);
  if WorkerDelayMs > 0 then
    Sleep(WorkerDelayMs);
  if Msg = 'raise' then
    raise Exception.Create('on purpose');
  if Msg = 'close' then
  begin
    WS.PostClose(WS_CLOSE_NORMAL, 'bye');
    Exit;
  end;
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

{ 'flood': posts 64 KiB binary messages while they are accepted, until
  they have been refused for 500 ms on end (or 64 MiB went); the bytes
  accepted go to FloodTotal }
procedure FloodPosts(WS: TWebSocket);
var
  Chunk: RawByteString;
  Total: Int64;
  T0: QWord;
  Going: Boolean;
begin
  Chunk := Pattern(65536);
  Total := 0;
  T0 := GetTickCount64;
  Going := True;
  while Going and (Total < 64 * 1024 * 1024) do
    case WS.PostBinary(Chunk) of
      wsOk:
        begin
          Inc(Total, Length(Chunk));
          T0 := GetTickCount64;
        end;
      wsFull:
        if GetTickCount64 - T0 > 500 then
          Going := False
        else
          Sleep(5);
    else
      Going := False;
    end;
  HappensBefore(@FloodTotal);
  AtomicStore(FloodTotal, LongInt(Total));
end;

procedure TWorkerEcho.OnText(WS: TWebSocket; const Msg: RawByteString);
begin
  if Msg = 'flood' then
    FloodPosts(WS)
  else
    Echo(WS, True, Msg);
end;

procedure TWorkerEcho.OnBinary(WS: TWebSocket; const Msg: RawByteString);
begin
  Echo(WS, False, Msg);
end;

procedure TWorkerEcho.OnWritable(WS: TWebSocket);
var
  I, Sent: Integer;
  R: TWsSendResult;
begin
  NoteThread(WS);
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

procedure TWorkerEcho.OnError(WS: TWebSocket; Code: Word; const Msg: string);
begin
  NoteThread(WS);
  AtomicStore(WorkerErrCode, Code);
end;

procedure TWorkerEcho.OnClose(WS: TWebSocket; Code: Word; const Reason: RawByteString);
begin
  NoteThread(WS);
  AtomicStoreThreadId(WorkerCloseThread, GetCurrentThreadId);
  AtomicStore(WorkerCloseCode, Code);
  HappensBefore(@WorkerCloses);      { the test reads the counters after WaitFreed }
  AtomicInc(WorkerCloses);
end;

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

procedure TProducer.Produce(WS: TWebSocket);
begin
  while FSent < FN do
  begin
    if WS.SendBinary(IntToStr(FSent + 1) + ':' + Pattern(FSize)) = wsFull then
      Exit;                          { OnWritable goes on }
    Inc(FSent);
  end;
end;

procedure TProducer.OnText(WS: TWebSocket; P: PByte; Len: SizeInt);
var
  S: RawByteString;
begin
  SetString(S, PAnsiChar(P), Len);
  FN := StrToInt(Copy(S, 1, Pos(':', S) - 1));
  FSize := StrToInt(Copy(S, Pos(':', S) + 1, MaxInt));
  FSent := 0;
  Produce(WS);
end;

procedure TProducer.OnWritable(WS: TWebSocket);
begin
  Produce(WS);
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
    else if R.Ok and PathIs(Ex, '/produce') then
      AcceptWebSocket(Ex, R, TProducer.Create, WsCfg)
    else if R.Ok and PathIs(Ex, '/worker') then
      AcceptWebSocket(Ex, R, TWorkerEcho.Create, ServerForPool.Workers, WsCfg)
    else if R.Ok and PathIs(Ex, '/topics') then
      AcceptWebSocket(Ex, R, TTopicHandler.Create, WsCfg)
    else if R.Ok and PathIs(Ex, '/topics-worker') then
      AcceptWebSocket(Ex, R, TTopicWorker.Create, ServerForPool.Workers, WsCfg)
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

constructor TClient.Connect(Port: Word; RcvBuf: Integer);
var
  A: TInetSockAddr;
  TV: TTimeVal;
begin
  inherited Create;
  Fd := fpSocket(AF_INET, SOCK_STREAM, 0);
  if RcvBuf > 0 then
    fpSetSockOpt(Fd, SOL_SOCKET, SO_RCVBUF, @RcvBuf, SizeOf(RcvBuf));
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
      if Path = '' then
        Path := '/echo';
      if not AnsiStartsStr('HTTP/1.1 101', C.Handshake('', '', Path)) then
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

procedure TTestWsBase.SetUp;
begin
  Live0 := AtomicLoad(WebSocketsLive);
  WsCfg := DefaultWsConfig;
  WsCfg.IdleTimeoutMs := 0;
  WsCfg.SendHighWater := 256 * 1024;
  IterPct := StrToIntDef(GetEnvironmentVariable('WD_ITER'), 100);
  WorkerDelayMs := 0;
  WorkerOnLoop := 0;
  WorkerOpens := 0;
  WorkerCloses := 0;
  WorkerCloseCode := 0;
  WorkerErrCode := 0;
  WorkerCloseThread := 0;
  TopicCloses := 0;
  TopicDrops := 0;
  FloodTotal := -1;
  TopicAborts := 0;
  Topics := TWsTopics.Create;
end;

procedure TTestWsBase.TearDown;
var
  I: Integer;
begin
  if Srv <> nil then
  begin
    Srv.Stop(1000);
    Srv.Wait;
    FreeAndNil(Srv);
  end;
  FreeAndNil(Topics);                { after the server: every connection has ended }
  ServerForPool := nil;
  for I := 0 to High(RoomLoops) do
    RoomLoops[I] := nil;
end;

procedure TTestWsBase.StartServer(Loops: Integer; Workers: Integer);
var
  Cfg: TServerConfig;
begin
  Cfg := BenchmarkServerConfig;
  Cfg.Listen.Host := '127.0.0.1';
  Cfg.Listen.Port := 0;
  Cfg.Loops := Loops;
  Cfg.Workers := Workers;
  Cfg.H1.Mode := cmWithUpgrades;
  Cfg.GraceMs := 1000;
  Srv := TServer.CreateWithProc(Cfg, @NewService);
  ServerForPool := Srv;
  Srv.Start;
end;

procedure TTestWsBase.WaitFreed;
var
  I: Integer;
begin
  for I := 1 to 400 do
  begin
    if AtomicLoad(WebSocketsLive) = Live0 then
      Break;
    Sleep(5);
  end;
  AssertEquals('every TWebSocket freed', Live0, AtomicLoad(WebSocketsLive));
  HappensAfter(@WorkerCloses);       { the worker handler's counters are read after this }
  HappensAfter(@TopicCloses);
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

{ The sends OnWritable makes go out with nothing else to wake the
  connection: no pings, a client that only reads. OnWritable runs at the
  end of a write that emptied the queue without EAGAIN, so no EPOLLOUT
  edge follows; what it queued must still be written. }
procedure TTestWsEcho.Sends_from_OnWritable_go_out;
var
  C: TClient;
  F: TServerFrame;
  I: Integer;
const
  N = 200;
  Size = 10000;                      { 2 MB: about eight refills of the 256 KiB mark }
begin
  WsCfg.PingIntervalMs := 0;
  StartServer(1);
  C := TClient.Connect(Srv.Port);
  try
    C.Handshake('', '', '/produce');
    C.SendAll(CFrame(WS_OP_TEXT, IntToStr(N) + ':' + IntToStr(Size)));
    for I := 1 to N do
    begin
      AssertTrue('message ' + IntToStr(I) + ' of ' + IntToStr(N) + ' (10 s receive timeout)', C.Frame(F));
      AssertEquals(WS_OP_BINARY, F.Opcode);
      AssertTrue('message ' + IntToStr(I) + ' in order', AnsiStartsStr(IntToStr(I) + ':', F.Payload));
      AssertEquals(Length(IntToStr(I)) + 1 + Size, Length(F.Payload));
    end;
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

{ ---- the worker handler ---- }

{ a close frame as its code and reason; another frame as its first bytes }
function FrameText(const F: TServerFrame): string;
begin
  if (F.Opcode = WS_OP_CLOSE) and (Length(F.Payload) >= 2) then
    Result := 'close ' + IntToStr(Ord(F.Payload[1]) * 256 + Ord(F.Payload[2])) + ' ' + Copy(F.Payload, 3, 60)
  else
    Result := Copy(F.Payload, 1, 60);
end;

procedure TTestWsWorker.Echo_in_order_from_a_worker_thread;
var
  C: TClient;
  H, Msg: RawByteString;
  F: TServerFrame;
  I: Integer;
begin
  StartServer(1, 2);
  C := TClient.Connect(Srv.Port);
  try
    H := C.Handshake('', CFrame(WS_OP_TEXT, 'first'), '/worker');
    AssertTrue(H, AnsiStartsStr('HTTP/1.1 101', H));
    AssertTrue(C.Frame(F));
    AssertEquals('first', F.Payload);
    for I := 1 to 200 do
    begin
      if Odd(I) then
      begin
        { text must be UTF-8: ASCII here; Pattern has any byte }
        Msg := IntToStr(I) + ':' + StringOfChar(AnsiChar(Ord('a') + I mod 26), I * 37 mod 70000);
        C.SendAll(CFrame(WS_OP_TEXT, Msg));
      end
      else
      begin
        Msg := IntToStr(I) + ':' + Pattern(I * 37 mod 70000);
        C.SendAll(CFrame(WS_OP_BINARY, Msg));
      end;
    end;
    for I := 1 to 200 do
    begin
      AssertTrue('echo ' + IntToStr(I), C.Frame(F));
      if Odd(I) then
        AssertEquals('opcode of ' + IntToStr(I) + ': ' + FrameText(F), WS_OP_TEXT, F.Opcode)
      else
        AssertEquals('opcode of ' + IntToStr(I) + ': ' + FrameText(F), WS_OP_BINARY, F.Opcode);
      AssertTrue('in order: ' + IntToStr(I), AnsiStartsStr(IntToStr(I) + ':', F.Payload));
      AssertEquals(Length(IntToStr(I)) + 1 + I * 37 mod 70000, Length(F.Payload));
    end;
    { a fragmented message arrives whole, after the pong }
    C.SendAll(CFrame(WS_OP_TEXT, 'frag', False) + CFrame(WS_OP_PING, 'p') + CFrame(WS_OP_CONT, 'mented'));
    AssertTrue(C.Frame(F));
    AssertEquals(WS_OP_PONG, F.Opcode);
    AssertTrue(C.Frame(F));
    AssertEquals('fragmented', F.Payload);
    C.SendAll(CFrame(WS_OP_CLOSE, #3#232'bye'));
    AssertTrue(C.Frame(F));
    AssertEquals(WS_OP_CLOSE, F.Opcode);
    AssertEquals(#3#232, F.Payload);
    AssertTrue(C.AtEof);
  finally
    C.Free;
  end;
  WaitFreed;
  AssertEquals('OnOpen ran', 1, WorkerOpens);
  AssertEquals('OnClose ran', 1, WorkerCloses);
  AssertEquals('the client''s close code', 1000, WorkerCloseCode);
  AssertEquals('no event on the loop thread', 0, WorkerOnLoop);
  AssertTrue('OnClose on a worker, not the main thread', AtomicLoadThreadId(WorkerCloseThread) <> GetCurrentThreadId);
end;

procedure TTestWsWorker.Receive_mark_pauses_and_resumes_reading;
var
  C: TClient;
  R: TFloodReader;
  F: TServerFrame;
  I: Integer;
const
  Size = 1000;                       { 600 KiB sent at once; the mark is 16 KiB }
var
  N: Integer;
begin
  N := 600 * IterPct div 100;
  WsCfg.ReceiveHighWater := 16 * 1024;
  WorkerDelayMs := 1;                { the handler is slower than the client }
  StartServer(1, 2);
  C := TClient.Connect(Srv.Port);
  try
    C.Handshake('', '', '/worker');
    R := TFloodReader.Create(True);
    R.C := C;
    R.N := N;
    R.Size := Size;
    R.Start;
    for I := 1 to N do
      C.SendAll(CFrame(WS_OP_BINARY, IntToStr(I) + ':' + Pattern(Size)));
    R.WaitFor;
    AssertEquals('reader', '', R.Error);
    AssertEquals(N, R.Got);
    R.Free;
    C.SendAll(CFrame(WS_OP_CLOSE, #3#232));
    AssertTrue(C.Frame(F));
    AssertEquals(WS_OP_CLOSE, F.Opcode);
    AssertTrue(C.AtEof);
  finally
    C.Free;
  end;
  WaitFreed;
  AssertEquals(0, WorkerOnLoop);
  AssertEquals(1, WorkerCloses);
end;

procedure TTestWsWorker.Handler_exception_closes_with_1011;
var
  C: TClient;
  F: TServerFrame;
begin
  StartServer(1, 2);
  C := TClient.Connect(Srv.Port);
  try
    C.Handshake('', '', '/worker');
    C.SendAll(CFrame(WS_OP_TEXT, 'before'));
    AssertTrue(C.Frame(F));
    AssertEquals('before', F.Payload);
    C.SendAll(CFrame(WS_OP_TEXT, 'raise'));
    AssertTrue('a close frame', C.Frame(F));
    AssertEquals(WS_OP_CLOSE, F.Opcode);
    AssertEquals(#3#243, F.Payload);  { 1011 }
    C.SendAll(CFrame(WS_OP_CLOSE, #3#243));
    AssertTrue(C.AtEof);
  finally
    C.Free;
  end;
  WaitFreed;
  AssertEquals('OnError with 1011', 1011, WorkerErrCode);
  AssertEquals('OnClose ran', 1, WorkerCloses);
  AssertEquals(0, WorkerOnLoop);
end;

procedure TTestWsWorker.PostClose_from_the_worker;
var
  C: TClient;
  F: TServerFrame;
begin
  StartServer(1, 2);
  C := TClient.Connect(Srv.Port);
  try
    C.Handshake('', '', '/worker');
    C.SendAll(CFrame(WS_OP_TEXT, 'one') + CFrame(WS_OP_TEXT, 'close') + CFrame(WS_OP_TEXT, 'dropped'));
    AssertTrue(C.Frame(F));
    AssertEquals('one', F.Payload);
    AssertTrue('the close frame', C.Frame(F));
    AssertEquals(WS_OP_CLOSE, F.Opcode);
    AssertEquals(#3#232'bye', F.Payload);
    C.SendAll(CFrame(WS_OP_CLOSE, #3#232));
    AssertTrue(C.AtEof);
  finally
    C.Free;
  end;
  WaitFreed;
  AssertEquals(1, WorkerCloses);
  AssertEquals('the client''s answer code', 1000, WorkerCloseCode);
end;

procedure TTestWsWorker.Many_clients_on_two_loops;
var
  Th: array[0..15] of TClientThread;
  I: Integer;
begin
  StartServer(2, 3);
  for I := 0 to High(Th) do
  begin
    Th[I] := TClientThread.Create(True);
    Th[I].Port := Srv.Port;
    Th[I].N := 300 * IterPct div 100;
    Th[I].Id := I;
    Th[I].Path := '/worker';
    Th[I].Start;
  end;
  for I := 0 to High(Th) do
  begin
    Th[I].WaitFor;
    AssertEquals('client ' + IntToStr(I), '', Th[I].Error);
    Th[I].Free;
  end;
  WaitFreed;
  AssertEquals(16, WorkerOpens);
  AssertEquals(16, WorkerCloses);
  AssertEquals(0, WorkerOnLoop);
end;

procedure TTestWsWorker.Posts_to_a_client_that_does_not_read_are_bounded;
var
  C: TClient;
  F: TServerFrame;
  Total, Got: Int64;
  I: Integer;
begin
  { The worker posts while it gets wsOk to a client that reads nothing:
    the posts must be refused once the post list and the output queue are
    full (each about SendHighWater, 256 KiB here, plus the socket's
    buffers), not accepted into a queue that grows without end. }
  StartServer(1, 2);
  C := TClient.Connect(Srv.Port, 65536);
  try
    AssertTrue(AnsiStartsStr('HTTP/1.1 101', C.Handshake('', '', '/worker')));
    C.SendAll(CFrame(WS_OP_TEXT, 'flood'));
    for I := 1 to 3000 do
      if AtomicLoad(FloodTotal) >= 0 then
        Break
      else
        Sleep(10);
    Total := AtomicLoad(FloodTotal);
    HappensAfter(@FloodTotal);
    AssertTrue('the worker stopped', Total >= 0);
    AssertTrue('accepted ' + IntToStr(Total) + ' bytes: bounded', Total < 16 * 1024 * 1024);
    { everything accepted arrives }
    Got := 0;
    while Got < Total do
    begin
      AssertTrue('a message after ' + IntToStr(Got) + ' of ' + IntToStr(Total), C.Frame(F));
      AssertEquals(WS_OP_BINARY, F.Opcode);
      Inc(Got, Length(F.Payload));
    end;
    AssertEquals(Total, Got);
    C.SendAll(CFrame(WS_OP_CLOSE, #3#232));
    AssertTrue(C.Frame(F));
    AssertEquals(WS_OP_CLOSE, F.Opcode);
  finally
    C.Free;
  end;
  WaitFreed;
end;

procedure TTestWsWorker.Server_stop_while_a_handler_is_busy;
var
  C: TClient;
  F: TServerFrame;
begin
  WorkerDelayMs := 300;
  StartServer(1, 2);
  C := TClient.Connect(Srv.Port);
  try
    C.Handshake('', '', '/worker');
    C.SendAll(CFrame(WS_OP_TEXT, 'slow'));
    Sleep(50);                       { the handler is inside its Sleep }
    Srv.Stop(5000);
    AssertTrue('the echo, from the busy handler', C.Frame(F));
    AssertEquals('slow', F.Payload);
    AssertTrue('a close frame', C.Frame(F));
    AssertEquals(WS_OP_CLOSE, F.Opcode);
    AssertEquals(#3#233'server shutdown', F.Payload);
    C.SendAll(CFrame(WS_OP_CLOSE, #3#233));
    AssertTrue(C.AtEof);
    fpClose(C.Fd);
    C.Fd := -1;
    Srv.Wait;
  finally
    C.Free;
  end;
  FreeAndNil(Srv);
  AssertEquals('every TWebSocket freed', Live0, AtomicLoad(WebSocketsLive));
  HappensAfter(@WorkerCloses);
  AssertEquals('OnClose ran', 1, WorkerCloses);
  AssertEquals(1001, WorkerCloseCode);
end;

{ ---- the topics ---- }

function TTestWsTopics.Join(Port: Word; const Path: RawByteString; RcvBuf: Integer): TClient;
begin
  Result := TClient.Connect(Port, RcvBuf);
  AssertTrue('101 on ' + Path, AnsiStartsStr('HTTP/1.1 101', Result.Handshake('', '', Path)));
end;

procedure TTestWsTopics.Sub(C: TClient; const Pattern: RawByteString);
begin
  C.SendAll(CFrame(WS_OP_TEXT, 'sub ' + Pattern));
  Expect(C, 'subscribed ' + Pattern, 'sub ' + Pattern);
end;

procedure TTestWsTopics.Expect(C: TClient; const Text, Msg: string);
var
  F: TServerFrame;
begin
  AssertTrue(Msg + ': a frame', C.Frame(F));
  AssertEquals(Msg + ': opcode', WS_OP_TEXT, F.Opcode);
  AssertEquals(Msg, Text, F.Payload);
end;

{ nothing arrives for C within 100 ms }
procedure TTestWsTopics.NoFrame(C: TClient; const Msg: string);
var
  F: TServerFrame;
begin
  Sleep(100);
  while C.Recv(False) do ;
  if TakeServerFrame(C.Buf, F) then
    Fail(Msg + ': got a frame: ' + FrameText(F));
end;

procedure TTestWsTopics.CloseAll(const C: array of TClient);
var
  I: Integer;
  F: TServerFrame;
begin
  for I := 0 to High(C) do
    if C[I] <> nil then
    begin
      C[I].SendAll(CFrame(WS_OP_CLOSE, #3#232));
      AssertTrue('close frame ' + IntToStr(I), C[I].Frame(F));
      AssertEquals(WS_OP_CLOSE, F.Opcode);
      AssertTrue('end of stream ' + IntToStr(I), C[I].AtEof);
    end;
end;

procedure TTestWsTopics.Fan_out_on_two_loops_in_order;
const
  NC = 8;
  NM = 40;
var
  C: array[0..NC - 1] of TClient;
  I, K, M: Integer;
  F: TServerFrame;
  LastOf: array[0..NC - 1] of Integer;
  Seen: array[0..NM] of Boolean;
begin
  FillChar(Seen, SizeOf(Seen), 0);
  StartServer(2);
  for I := 0 to NC - 1 do
    C[I] := nil;
  try
    for I := 0 to NC - 1 do
    begin
      C[I] := Join(Srv.Port);
      Sub(C[I], 'chat/room1');
    end;
    { two publishes from one loop handler: everyone, once, in order }
    C[0].SendAll(CFrame(WS_OP_TEXT, 'pub chat/room1 one') + CFrame(WS_OP_TEXT, 'pub chat/room1 two'));
    for I := 0 to NC - 1 do
    begin
      Expect(C[I], 'one', 'client ' + IntToStr(I) + ' first');
      Expect(C[I], 'two', 'client ' + IntToStr(I) + ' second');
    end;
    { more, from every sender at once: each client gets all of them, and
      the messages of one sender in that sender's order (senders on
      different loops have no order between them) }
    for K := 1 to NM do
      C[K mod NC].SendAll(CFrame(WS_OP_TEXT, 'pub chat/room1 m' + IntToStr(K)));
    for I := 0 to NC - 1 do
    begin
      for K := 0 to NC - 1 do
        LastOf[K] := 0;
      for K := 1 to NM do
      begin
        AssertTrue('client ' + IntToStr(I) + ' message ' + IntToStr(K), C[I].Frame(F));
        AssertEquals(WS_OP_TEXT, F.Opcode);
        M := StrToInt(Copy(F.Payload, 2, MaxInt));
        AssertTrue('m' + IntToStr(M) + ' after m' + IntToStr(LastOf[M mod NC]) + ' of the same sender',
          M > LastOf[M mod NC]);
        LastOf[M mod NC] := M;
        Seen[M] := True;
      end;
      for K := 1 to NM do
        AssertTrue('client ' + IntToStr(I) + ' got m' + IntToStr(K), Seen[K]);
      FillChar(Seen, SizeOf(Seen), 0);
    end;
    { a prepared frame too }
    C[1].SendAll(CFrame(WS_OP_TEXT, 'pubframe chat/room1 prepared'));
    for I := 0 to NC - 1 do
      Expect(C[I], 'prepared', 'client ' + IntToStr(I) + ' prepared');
    for I := 0 to NC - 1 do
      NoFrame(C[I], 'client ' + IntToStr(I) + ' once only');
    CloseAll(C);
  finally
    for I := 0 to NC - 1 do
      C[I].Free;
  end;
  WaitFreed;
  AssertEquals('OnClose for each', NC, TopicCloses);
  AssertEquals('no drops', 0, TopicDrops);
end;

procedure TTestWsTopics.Wildcards;
var
  A, B, C, D: TClient;
begin
  StartServer(2);
  A := nil; B := nil; C := nil; D := nil;
  try
    A := Join(Srv.Port);
    B := Join(Srv.Port);
    C := Join(Srv.Port);
    D := Join(Srv.Port);
    Sub(A, 'chat/#');
    Sub(A, 'chat/room1');            { both match chat/room1: once }
    Sub(B, 'chat/+');
    Sub(C, 'sensors/+/temp');
    Sub(D, '#');
    D.SendAll(CFrame(WS_OP_TEXT, 'pub chat/room1 m1'));
    Expect(A, 'm1', 'A m1');
    Expect(B, 'm1', 'B m1');
    Expect(D, 'm1', 'D m1');
    D.SendAll(CFrame(WS_OP_TEXT, 'pub chat/room1/sub m2'));
    Expect(A, 'm2', 'A m2');         { chat/# : any depth }
    Expect(D, 'm2', 'D m2');
    D.SendAll(CFrame(WS_OP_TEXT, 'pub chat m3'));
    Expect(A, 'm3', 'A m3');         { chat/# matches the parent too }
    Expect(D, 'm3', 'D m3');
    D.SendAll(CFrame(WS_OP_TEXT, 'pub sensors/x/temp m4'));
    Expect(C, 'm4', 'C m4');
    Expect(D, 'm4', 'D m4');
    D.SendAll(CFrame(WS_OP_TEXT, 'pub sensors/x/hum m5'));
    Expect(D, 'm5', 'D m5');
    D.SendAll(CFrame(WS_OP_TEXT, 'pub other m6'));
    Expect(D, 'm6', 'D m6');
    NoFrame(A, 'A');
    NoFrame(B, 'B');
    NoFrame(C, 'C');
    NoFrame(D, 'D');
    CloseAll([A, B, C, D]);
  finally
    A.Free; B.Free; C.Free; D.Free;
  end;
  WaitFreed;
  AssertEquals(4, TopicCloses);
end;

procedure TTestWsTopics.Exclude_the_sender;
var
  A, B: TClient;
begin
  StartServer(1);
  A := nil; B := nil;
  try
    A := Join(Srv.Port);
    B := Join(Srv.Port);
    Sub(A, 't');
    Sub(B, 't');
    A.SendAll(CFrame(WS_OP_TEXT, 'pubx t hi'));
    Expect(B, 'hi', 'B');
    NoFrame(A, 'A, the sender');
    A.SendAll(CFrame(WS_OP_TEXT, 'pub t all'));
    Expect(A, 'all', 'A');
    Expect(B, 'all', 'B');
    CloseAll([A, B]);
  finally
    A.Free; B.Free;
  end;
  WaitFreed;
end;

procedure TTestWsTopics.Unsubscribe_and_removal_at_close;
var
  A, B: TClient;
  F: TServerFrame;
  K: Integer;
begin
  StartServer(1);
  A := nil; B := nil;
  try
    A := Join(Srv.Port);
    B := Join(Srv.Port);
    Sub(A, 't');
    Sub(A, 'u/#');
    Sub(B, 't');
    A.SendAll(CFrame(WS_OP_TEXT, 'unsub t'));
    Expect(A, 'unsubscribed t', 'A');
    B.SendAll(CFrame(WS_OP_TEXT, 'pub t m1') + CFrame(WS_OP_TEXT, 'pub u/x m2'));
    Expect(B, 'm1', 'B m1');
    Expect(A, 'm2', 'A still has u/#');
    NoFrame(A, 'A after unsub');
    { A closes while subscribed to u/#: the registry forgets it }
    A.SendAll(CFrame(WS_OP_CLOSE, #3#232));
    AssertTrue(A.Frame(F));
    AssertEquals(WS_OP_CLOSE, F.Opcode);
    AssertTrue(A.AtEof);
    FreeAndNil(A);
    for K := 1 to 400 do
      if AtomicLoad(WebSocketsLive) = Live0 + 1 then Break else Sleep(5);
    AssertEquals('A freed', Live0 + 1, AtomicLoad(WebSocketsLive));
    B.SendAll(CFrame(WS_OP_TEXT, 'pub u/x m3') + CFrame(WS_OP_TEXT, 'pub t m4'));
    Expect(B, 'm4', 'B m4');
    { B leaves its subscription too, then unsubscribes what it never had }
    B.SendAll(CFrame(WS_OP_TEXT, 'unsub t') + CFrame(WS_OP_TEXT, 'unsub never'));
    Expect(B, 'unsubscribed t', 'B');
    Expect(B, 'unsubscribed never', 'B');
    B.SendAll(CFrame(WS_OP_TEXT, 'pub t m5'));
    NoFrame(B, 'B after unsub');
    Sub(B, 't');
    B.SendAll(CFrame(WS_OP_TEXT, 'pub t m6'));
    Expect(B, 'm6', 'B again');
    CloseAll([B]);
  finally
    A.Free; B.Free;
  end;
  WaitFreed;
  AssertEquals(2, TopicCloses);
end;

procedure TTestWsTopics.Subscribe_and_publish_from_a_worker_handler;
var
  A, B, L: TClient;
  I: Integer;
begin
  StartServer(2, 2);
  A := nil; B := nil; L := nil;
  try
    A := Join(Srv.Port, '/topics-worker');
    B := Join(Srv.Port, '/topics-worker');
    L := Join(Srv.Port);             { a loop handler in the same topic }
    Sub(A, 'w/+');
    Sub(B, 'w/x');
    Sub(L, 'w/#');
    { a publish from the worker, after its own subscribe: both posted to
      the loop in that order }
    for I := 1 to 20 do
      A.SendAll(CFrame(WS_OP_TEXT, 'pub w/x m' + IntToStr(I)));
    for I := 1 to 20 do
    begin
      Expect(A, 'm' + IntToStr(I), 'A');
      Expect(B, 'm' + IntToStr(I), 'B');
      Expect(L, 'm' + IntToStr(I), 'L');
    end;
    B.SendAll(CFrame(WS_OP_TEXT, 'pubx w/x fromB'));
    Expect(A, 'fromB', 'A');
    Expect(L, 'fromB', 'L');
    NoFrame(B, 'B, the sender');
    B.SendAll(CFrame(WS_OP_TEXT, 'unsub w/x'));
    Expect(B, 'unsubscribed w/x', 'B');
    L.SendAll(CFrame(WS_OP_TEXT, 'pub w/x last'));
    Expect(A, 'last', 'A');
    Expect(L, 'last', 'L');
    NoFrame(B, 'B after unsub');
    CloseAll([A, B, L]);
  finally
    A.Free; B.Free; L.Free;
  end;
  WaitFreed;
  AssertEquals(3, TopicCloses);
  AssertEquals('no worker event on the loop thread', 0, WorkerOnLoop);
end;

{ A does not read (a 64 KiB receive window), B reads, C publishes 12 MiB
  in 64 KiB messages: B gets everything; A's queue reaches the mark }
procedure TTestWsTopics.Slow_subscriber(CloseIt: Boolean);
const
  N = 192;
  Size = 65536;
var
  A, B, C: TClient;
  F: TServerFrame;
  I: Integer;
begin
  Topics.CloseOnBackpressure := CloseIt;
  StartServer(1);
  A := nil; B := nil; C := nil;
  try
    A := Join(Srv.Port, '/topics', 65536);
    B := Join(Srv.Port);
    C := Join(Srv.Port);
    Sub(A, 'big');
    Sub(B, 'big');
    for I := 1 to N do
    begin
      C.SendAll(CFrame(WS_OP_TEXT, 'pubbig big ' + IntToStr(Size)));
      AssertTrue('B message ' + IntToStr(I), B.Frame(F));
      AssertEquals(WS_OP_BINARY, F.Opcode);
      AssertEquals(Size, Length(F.Payload));
    end;
    NoFrame(B, 'B');
    if CloseIt then
    begin
      { A was aborted: its socket is closed under the unread bytes }
      while A.Recv do ;
      FreeAndNil(A);
    end;
    CloseAll([B, C]);
  finally
    A.Free; B.Free; C.Free;          { A, if alive: closed under its unread bytes }
  end;
  WaitFreed;
  AssertEquals(3, TopicCloses);
  if CloseIt then
    AssertEquals('A aborted with 1006', 1, TopicAborts)
  else
  begin
    AssertTrue('A dropped messages', TopicDrops > 0);
    AssertTrue('but got some', TopicDrops < N);
  end;
end;

procedure TTestWsTopics.Slow_subscriber_drops_messages;
begin
  Slow_subscriber(False);
end;

procedure TTestWsTopics.Slow_subscriber_aborted_with_CloseOnBackpressure;
begin
  Slow_subscriber(True);
end;

procedure TTestWsTopics.Slow_worker_subscriber_catches_up;
const
  N = 192;
  Size = 65536;
var
  A, B, C: TClient;
  F: TServerFrame;
  TV: TTimeVal;
  I: Integer;
begin
  { A, on the worker pool, falls behind: publishes to it return wsFull
    (dropped). When it reads again its output queue drains: the
    connection goes on (a handler on the worker pool has no OnWritable
    for those sends) and its worker still answers. }
  StartServer(1, 2);
  A := nil; B := nil; C := nil;
  try
    A := Join(Srv.Port, '/topics-worker', 65536);
    B := Join(Srv.Port);
    C := Join(Srv.Port);
    Sub(A, 'big');
    Sub(B, 'big');
    for I := 1 to N do
    begin
      C.SendAll(CFrame(WS_OP_TEXT, 'pubbig big ' + IntToStr(Size)));
      AssertTrue('B message ' + IntToStr(I), B.Frame(F));
    end;
    { A reads what was kept, until 500 ms pass with nothing }
    TV.tv_sec := 0;
    TV.tv_usec := 500000;
    fpSetSockOpt(A.Fd, SOL_SOCKET, SO_RCVTIMEO, @TV, SizeOf(TV));
    while A.Frame(F) do
      AssertEquals('A: ' + FrameText(F), WS_OP_BINARY, F.Opcode);
    TV.tv_sec := 10;
    TV.tv_usec := 0;
    fpSetSockOpt(A.Fd, SOL_SOCKET, SO_RCVTIMEO, @TV, SizeOf(TV));
    Sub(A, 'after');
    CloseAll([A, B, C]);
  finally
    A.Free; B.Free; C.Free;
  end;
  WaitFreed;
  AssertEquals(3, TopicCloses);
  AssertTrue('A dropped messages', TopicDrops > 0);
  AssertEquals('no abort', 0, TopicAborts);
end;

procedure TTestWsTopics.A_burst_of_publishes_reaches_a_reader;
const
  N = 24;
  Size = 16384;                      { 384 KiB in one inbox drain: over the 256 KiB mark }
var
  A, B: TClient;
  T: TPublisherThread;
  F: TServerFrame;
  I: Integer;
begin
  { The publishes of one loop iteration go to a subscriber that reads:
    the queue at the mark is written to the socket, not dropped from. }
  StartServer(1);
  A := nil; B := nil;
  try
    A := Join(Srv.Port);
    B := Join(Srv.Port);
    Sub(A, 'burst');
    { B holds the loop: the publishes wait in its inbox, then run in one drain }
    B.SendAll(CFrame(WS_OP_TEXT, 'block 500'));
    Sleep(50);
    T := TPublisherThread.Create(True);
    T.Topic := 'burst';
    T.N := N;
    T.Size := Size;
    T.Start;
    T.WaitFor;
    T.Free;
    for I := 1 to N do
    begin
      AssertTrue('message ' + IntToStr(I), A.Frame(F));
      AssertEquals(WS_OP_BINARY, F.Opcode);
      AssertTrue('message ' + IntToStr(I) + ' in order', AnsiStartsStr(IntToStr(I) + ':', F.Payload));
    end;
    CloseAll([A, B]);
  finally
    A.Free; B.Free;
  end;
  WaitFreed;
  AssertEquals('none dropped', 0, TopicDrops);
end;

procedure TTestWsTopics.Publish_from_a_plain_thread;
var
  A, B: TClient;
  T: TPublisherThread;
  I, N: Integer;
begin
  N := 500 * IterPct div 100;
  StartServer(2);
  A := nil; B := nil;
  try
    A := Join(Srv.Port);
    B := Join(Srv.Port);
    Sub(A, 'clock');
    Sub(B, 'clock/#');
    T := TPublisherThread.Create(True);
    T.Topic := 'clock';
    T.N := N;
    T.Start;
    for I := 1 to N do
    begin
      Expect(A, 'tick ' + IntToStr(I), 'A');
      Expect(B, 'tick ' + IntToStr(I), 'B');
    end;
    T.WaitFor;
    T.Free;
    NoFrame(A, 'A');
    CloseAll([A, B]);
  finally
    A.Free; B.Free;
  end;
  WaitFreed;
  AssertEquals(0, TopicDrops);
end;

procedure TTestWsTopics.First_subscriber_of_a_loop_gets_the_next_publish;
var
  C: TClient;
  I, N: Integer;
begin
  { From a worker handler the subscribe is posted to the loop, and the
    loop has no table yet (a fresh server and registry each time): the
    publish made right after it must still reach the new subscriber. }
  N := 20 * IterPct div 100;
  if N < 2 then
    N := 2;
  for I := 1 to N do
  begin
    StartServer(2, 2);
    C := Join(Srv.Port, '/topics-worker');
    try
      C.SendAll(CFrame(WS_OP_TEXT, 'subpub fresh hello'));
      Expect(C, 'hello', 'the new subscriber, round ' + IntToStr(I));
      CloseAll([C]);
    finally
      C.Free;
    end;
    WaitFreed;
    Srv.Stop(1000);
    Srv.Wait;
    FreeAndNil(Srv);
    FreeAndNil(Topics);
    Topics := TWsTopics.Create;
  end;
end;

procedure TTestWsTopics.Invalid_patterns_and_topics;
begin
  AssertTrue(WsPatternValid('a/b/c'));
  AssertTrue(WsPatternValid('a/+/c'));
  AssertTrue(WsPatternValid('a/#'));
  AssertTrue(WsPatternValid('#'));
  AssertTrue(WsPatternValid('+'));
  AssertTrue(WsPatternValid(''));
  AssertTrue(WsPatternValid('/a//b'));
  AssertFalse(WsPatternValid('a/#/b'));
  AssertFalse(WsPatternValid('a#'));
  AssertFalse(WsPatternValid('a+/b'));
  AssertFalse(WsPatternValid('a/+b'));
  AssertTrue(WsTopicValid('a/b'));
  AssertTrue(WsTopicValid(''));
  AssertFalse(WsTopicValid('a/+'));
  AssertFalse(WsTopicValid('a#b'));
  try
    Topics.Publish('a/+', 'x');
    Fail('a wildcard in a publish topic');
  except
    on EArgumentException do ;
  end;
end;

var
  RI: Integer;
begin
  for RI := 0 to High(Rooms) do
    Rooms[RI] := TList.Create;
  RegisterTest(TTestWsEcho);
  RegisterTest(TTestWsWorker);
  RegisterTest(TTestWsTopics);
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

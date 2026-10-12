{ bearings.ws.conn - a WebSocket connection on the event loop (RFC 6455).

  After the opening handshake (bearings.ws.handshake) the HTTP layer hands
  the socket over as a TUpgraded (bearings.rt.stream). TWebSocket attaches
  to it as its TRawListener and from then on speaks the WebSocket protocol:
  it reads frames (bearings.ws.frame), joins the frames of a fragmented
  message, answers pings, runs the close handshake and calls the
  application's TWebSocketHandler.

  The application's side:
    TWebSocketHandler  virtual methods, called on the loop thread:
      OnOpen       once, first.
      OnText       a complete text message (valid UTF-8).
      OnBinary     a complete binary message.
      OnPong       a pong frame arrived (the answer to Ping).
      OnWritable   after a send returned wsFull: the output queue went down
                   to half the high-water mark, so sending may go on.
      OnError      the connection failed: the client broke the protocol
                   (with the close code that was sent: 1002, 1007, 1009),
                   a handler method raised (1011), or a socket error
                   (1006). OnClose follows.
      OnClose      once, last. Code is the status code of the client's
                   close frame; 1005 when that frame had none; 1006 when
                   the connection ended without a close frame from the
                   client. Reason is the client's reason text.
    The message bytes given to OnText and OnBinary are valid only during the
    call (they are in the connection's read or reassembly buffer).
    TWebSocket sends with SendText, SendBinary, Ping and CloseWith. The
    handler object belongs to the TWebSocket (freed after OnClose) unless
    it was created with AOwnsHandler = False.

  Reading. Each run reads from the socket into a pooled 64 KiB block
  (bearings.rt.buf), gives the bytes to the frame reader, and delivers what
  it reports. A message that arrives whole in one read is delivered from
  the read block without a copy (the reader unmasks it in place); a
  fragmented message, or one split across reads, is collected in a
  reassembly buffer. MaxMessage limits a message; a larger one fails the
  connection with 1009. Each run reads at most 8 blocks and then yields
  (Wake), so one busy client cannot hold the loop. While the output queue
  holds more than SendHighWater bytes the connection stops reading: a
  client that sends faster than it reads the answers is slowed down by TCP
  instead of filling the server's memory. Reading resumes when a data send
  would be accepted again (fewer than SendHighWater bytes queued).

  Sending. A frame is written to the socket at once when nothing is queued
  (header and payload in one writev); what the socket does not take goes
  to the output queue, which is written when the socket becomes writable.
  The queue is a list of segments: copied bytes (kept together in one
  buffer; consecutive copied frames form one segment) and prepared frames
  (TWsFrame, bearings.ws.frame) held by reference. A flush writes up to
  WS_MAX_IOV segments with one writev. A data send is refused with wsFull when SendHighWater or more
  bytes are queued (the message is not queued; the application waits for
  OnWritable). A single message larger than SendHighWater is accepted when
  the queue is below the mark. Control frames (pong, close) are always
  queued. After the close frame was sent, every send returns wsClosed.

  Prepared frames (broadcast). SendFrame(F) sends a frame built once with
  WsTextFrame or WsBinaryFrame, for example one message for every member
  of a room: no header is encoded and, for frames of WS_SHARE_MIN bytes or
  more, nothing is copied; the queue keeps a reference to the string (an
  atomic reference count) until the bytes are written. Smaller frames are
  copied, which costs less than a segment of their own. The same rules as
  SendText apply (wsFull, wsClosed). PostFrame is the same from another
  thread. A broadcast from another thread is best done with one message per
  loop (TLoop.Post) whose handler calls SendFrame for that loop's
  connections, rather than one PostFrame per connection.

  Sending from another thread. SendText and friends run on the loop thread
  only. Another thread uses PostText / PostBinary: the message is copied
  into a list under a spin lock and a message (TLoop.Post) asks the loop to
  move it into the output queue. The list is bounded by SendHighWater too
  (wsFull). To use a TWebSocket from another thread at all, that thread
  needs a reference: AddRef on the loop thread (for example in OnOpen),
  Release when done, from any thread. The loop holds one reference until
  the connection ends; the object is freed when the last reference goes.

  The close handshake (RFC 6455 section 7):
    - The client sends close: the same status code is sent back (an empty
      close frame when the client's had none), the output is flushed, and
      the connection ends.
    - CloseWith(Code, Reason): the close frame is sent; frames still
      arriving are read and data messages dropped, until the client's close
      frame arrives or CloseTimeoutMs passes.
    - The client breaks the protocol: a close frame with the error code is
      sent and the connection ends without waiting for an answer.
  Ending the connection: once the output is flushed, the write side is
  shut down (the client sees end of stream), and the bytes still arriving
  are read and dropped until the client closes its side or CloseTimeoutMs
  passes; then the socket is closed. Closing a socket with unread bytes
  would make the kernel send a reset, which can make the client lose the
  close frame.

  Timers (bearings.rt.timer, on the loop's wheel): IdleTimeoutMs (no byte
  received for that long: CloseWith(1001)), PingIntervalMs (a ping every
  interval; 0 = off; the client's pongs reset the idle timer, so with the
  defaults, 25 s and 60 s, only a client that is gone hits the idle
  timeout), CloseTimeoutMs (the close handshake and the end of the
  connection may take at most that long).

  Ending a connection from the application: CloseWith runs the close
  handshake; Abort closes the socket without it (for a client that does
  not read: a close frame would wait behind its unsent backlog). Abort
  sends nothing more; OnClose follows with 1006.

  Server shutdown (bearings.server): a graceful stop calls Shutdown on each
  upgraded stream, and TWebSocket answers with CloseWith(1001, 'server
  shutdown'); the server waits for these connections to end like for its
  HTTP connections. At the stop's deadline the stream is aborted: Aborted
  releases everything and OnClose runs with 1006.

  Exceptions. An exception raised by a handler method is reported to
  LoopErrorProc (bearings.rt.loop) and fails the connection with 1011.

  Not supported: extensions (permessage-deflate), a blocking API for worker
  threads.

  Threading: everything runs on the loop thread of the TUpgraded, except
  PostText, PostBinary, AddRef and Release. }
unit bearings.ws.conn;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, ctypes, bearings.rt.sys, bearings.rt.sync, bearings.rt.loop, bearings.rt.timer,
  bearings.rt.buf, bearings.rt.stream, bearings.http.exchange, bearings.ws.frame,
  bearings.ws.handshake;

const
  WS_READ_BLOCK = 65536;
  WS_READS_PER_RUN = 8;
  WS_SHARE_MIN = 1024;               { a prepared frame this large is queued by reference }
  WS_MAX_IOV = 64;                   { segments per writev }

type
  TWebSocket = class;

  TWsConfig = record
    MaxMessage: Int64;               { bytes; 0 = no limit }
    IdleTimeoutMs: Int64;            { 0 = none }
    PingIntervalMs: Int64;           { 0 = no pings }
    CloseTimeoutMs: Int64;           { must be > 0 }
    SendHighWater: SizeInt;
  end;

  TWsSendResult = (wsOk, wsFull, wsClosed);

  TWebSocketHandler = class
  public
    procedure OnOpen(WS: TWebSocket); virtual;
    procedure OnText(WS: TWebSocket; P: PByte; Len: SizeInt); virtual;
    procedure OnBinary(WS: TWebSocket; P: PByte; Len: SizeInt); virtual;
    procedure OnPong(WS: TWebSocket; P: PByte; Len: SizeInt); virtual;
    procedure OnWritable(WS: TWebSocket); virtual;
    procedure OnError(WS: TWebSocket; Code: Word; const Msg: string); virtual;
    procedure OnClose(WS: TWebSocket; Code: Word; const Reason: RawByteString); virtual;
  end;

  TWsPosted = record
    Opcode: Byte;                    { 0: Data is a prepared frame }
    Data: RawByteString;
  end;

  { One piece of the output queue. Ref = nil: Len bytes of the copied-bytes
    buffer (they follow the bytes of the copied segments before it).
    Ref <> nil: a prepared frame, one string reference held in Ref
    (assigned through a typecast, as BodyString does: no managed field);
    P is its next unsent byte. }
  TWsSeg = record
    Len: SizeInt;
    P: PByte;
    Ref: Pointer;
  end;

  TWebSocket = class(TRawListener)
  private
    FU: TUpgraded;
    FLoop: TLoop;
    FHandler: TWebSocketHandler;
    FOwnsHandler: Boolean;
    FCfg: TWsConfig;
    FReader: TWsReader;
    FReadBlk: PBufBlock;             { the read block of the current run }
    FMsg: TByteVec;                  { reassembly buffer }
    FOut: TByteVec;                  { the copied bytes of the queue: FOutPos..Len-1 are unsent }
    FOutPos: SizeInt;
    FSegs: array of TWsSeg;          { the output queue, a ring }
    FSegHead, FSegCount: Integer;
    FQueued: SizeInt;                { unsent bytes in all segments }
    FIdleTimer, FPingTimer, FCloseTimer: TTimer;
    FIdleFired, FPingFired, FCloseFired: Boolean;
    FOpened: Boolean;                { OnOpen ran }
    FCloseSent, FCloseReceived: Boolean;
    FFailed: Boolean;                { the connection failed (protocol, handler, socket) }
    FShutDown: Boolean;              { the write side was shut down }
    FEnded: Boolean;                 { the client closed its side, or the socket failed: finish }
    FFinished: Boolean;
    FWantWritable: Boolean;          { a send returned wsFull }
    FReadPaused: Boolean;            { reading stopped: the output queue is over the mark }
    FInStep: Boolean;
    FPeerCode: Word;                 { the client's close code; 1005 none; 1006 no close frame }
    FPeerReason: RawByteString;
    FUser: TObject;
    FRefs: LongInt;
    { cross-thread sends }
    FPostLock: TSpinLock;
    FPosted: array of TWsPosted;
    FPostedCount: Integer;
    FPostedBytes: SizeInt;
    FPostClosed: Boolean;
    FPostMsg: TLoopMsg;
    FPostQueued: Boolean;            { FPostMsg is in the loop's inbox }
    procedure Step;
    procedure ReadInput;
    procedure HandleBytes(P: PByte; L: SizeInt);
    procedure HandleControl;
    procedure Deliver(Opcode: Byte; P: PByte; Len: SizeInt);
    procedure Flush;
    procedure DrainPosted;
    procedure HandleTimers;
    procedure Fail(Code: Word; const Msg: string);
    procedure IoFailed(const What: string; Errno: cint);
    procedure QueueClose(Code: Word; const Reason: RawByteString);
    function QueueFrame(Opcode: Byte; P: PByte; Len: SizeInt; Control: Boolean): TWsSendResult;
    function QueuePrepared(const F: TWsFrame; Control: Boolean): TWsSendResult;
    function Refused(Opcode: Byte; Control: Boolean): Boolean; inline;
    procedure PushSeg(Len: SizeInt; P: PByte; Ref: Pointer);
    procedure PushCopy(P: PByte; N: SizeInt);
    procedure PushShared(const F: TWsFrame; Off: SizeInt);
    procedure Consume(W: SizeInt);
    procedure ClearQueue;
    function Post(Opcode: Byte; const Data: RawByteString): TWsSendResult;
    procedure ArmClose;
    function Ending: Boolean; inline;
    procedure Finish(CloseStream: Boolean);
  public
    { AHandler belongs to the new object unless AOwnsHandler = False. }
    constructor Create(AHandler: TWebSocketHandler; const ACfg: TWsConfig; AOwnsHandler: Boolean = True);
    destructor Destroy; override;
    { Loop thread: takes over U (attaches to it). OnOpen runs in the first
      run of the connection, right after. }
    procedure Start(U: TUpgraded);
    procedure Readable(U: TUpgraded); override;
    procedure Writable(U: TUpgraded); override;
    { the server stops: CloseWith(1001, 'server shutdown') }
    procedure Shutdown(U: TUpgraded); override;
    { the stream is closed by force: everything is released, OnClose(1006) }
    procedure Aborted(U: TUpgraded); override;

    { ---- loop thread ---- }
    function SendText(P: PByte; Len: SizeInt): TWsSendResult;
    function SendText(const S: RawByteString): TWsSendResult;
    function SendBinary(P: PByte; Len: SizeInt): TWsSendResult;
    function SendBinary(const S: RawByteString): TWsSendResult;
    { a prepared frame (WsTextFrame, WsBinaryFrame, or a ping or pong from
      WsMakeFrame; not a close frame: use CloseWith) }
    function SendFrame(const F: TWsFrame): TWsSendResult;
    { a ping with at most 125 payload bytes; wsClosed also for a longer payload }
    function Ping(const Payload: RawByteString = ''): TWsSendResult;
    { Starts the close handshake. Code: a code WsCloseCodeValid accepts, or
      0 for a close frame without a code. Reason: at most 123 bytes of
      UTF-8 (cut to 123). False when the close frame was already sent or
      the code is not valid. }
    function CloseWith(Code: Word = WS_CLOSE_NORMAL; const Reason: RawByteString = ''): Boolean;
    { Closes the socket without the close handshake, in this run of the
      connection or the next one (nothing queued is sent). OnClose follows
      with 1006, or with the client's code if its close frame had arrived. }
    procedure Abort;
    { bytes in the output queue }
    function Queued: SizeInt; inline;
    { the close frame was sent or the connection ended: sends return wsClosed }
    function Closing: Boolean; inline;
    property Loop: TLoop read FLoop;
    property Handler: TWebSocketHandler read FHandler;
    property Config: TWsConfig read FCfg;
    property User: TObject read FUser write FUser;   { application data; not freed here }

    { ---- any thread ---- }
    function PostText(const S: RawByteString): TWsSendResult;
    function PostBinary(const S: RawByteString): TWsSendResult;
    function PostFrame(const F: TWsFrame): TWsSendResult;
    procedure AddRef;                { loop thread, or a thread that already holds a reference }
    procedure Release;               { the last reference frees the object }
  end;

  { The upgrade handler that creates the TWebSocket. AcceptWebSocket makes
    one; an application with its own TUpgradeHandler can do the same as
    Upgraded does here. }
  TWsUpgradeHandler = class(TUpgradeHandler)
  public
    Handler: TWebSocketHandler;
    Cfg: TWsConfig;
    constructor Create(AHandler: TWebSocketHandler; const ACfg: TWsConfig);
    procedure Upgraded(U: TUpgraded); override;
    procedure UpgradeFailed(const Msg: string); override;
  end;

{ MaxMessage 16 MiB, IdleTimeoutMs 60000, PingIntervalMs 25000,
  CloseTimeoutMs 5000, SendHighWater 1 MiB. The pings make a client that
  is alive answer with pongs, which count as received bytes, so the idle
  timeout closes only clients that are gone; they also keep proxies from
  closing a quiet connection. }
function DefaultWsConfig: TWsConfig;

{ Answers the handshake R (from CheckRequest) with 101 and arranges for a
  TWebSocket with Handler and Cfg to take the connection over. Takes
  ownership of Handler in every case: when the handshake or the upgrade
  fails, Handler is freed without any of its methods being called. False
  when the 101 was not sent. }
function AcceptWebSocket(Ex: TExchange; const R: TWsHandshake; Handler: TWebSocketHandler;
  const Cfg: TWsConfig): Boolean;

var
  { TWebSocket objects alive; tests check that every connection was freed. Atomic. }
  WebSocketsLive: LongInt = 0;

implementation

function DefaultWsConfig: TWsConfig;
begin
  Result.MaxMessage := 16 * 1024 * 1024;
  Result.IdleTimeoutMs := 60000;
  Result.PingIntervalMs := 25000;
  Result.CloseTimeoutMs := 5000;
  Result.SendHighWater := 1024 * 1024;
end;

{ ---- TWebSocketHandler ---- }

procedure TWebSocketHandler.OnOpen(WS: TWebSocket); begin end;
procedure TWebSocketHandler.OnText(WS: TWebSocket; P: PByte; Len: SizeInt); begin end;
procedure TWebSocketHandler.OnBinary(WS: TWebSocket; P: PByte; Len: SizeInt); begin end;
procedure TWebSocketHandler.OnPong(WS: TWebSocket; P: PByte; Len: SizeInt); begin end;
procedure TWebSocketHandler.OnWritable(WS: TWebSocket); begin end;
procedure TWebSocketHandler.OnError(WS: TWebSocket; Code: Word; const Msg: string); begin end;
procedure TWebSocketHandler.OnClose(WS: TWebSocket; Code: Word; const Reason: RawByteString); begin end;

{ ---- timers and inbox messages ---- }

procedure WsTimerProc(T: PTimer);
var
  WS: TWebSocket;
begin
  WS := TWebSocket(T^.Owner);
  if T = @WS.FIdleTimer then
    WS.FIdleFired := True
  else if T = @WS.FPingTimer then
    WS.FPingFired := True
  else
    WS.FCloseFired := True;
  WS.FU.Wake;
end;

procedure WsPostProc(Loop: TLoop; Arg: Pointer);
var
  WS: TWebSocket;
begin
  WS := TWebSocket(Arg);
  WS.FPostLock.Acquire;
  WS.FPostQueued := False;
  WS.FPostLock.Release;
  if not WS.FFinished then
    WS.FU.Wake;
  WS.Release;                        { the reference the post took }
end;

{ ---- TWebSocket ---- }

constructor TWebSocket.Create(AHandler: TWebSocketHandler; const ACfg: TWsConfig; AOwnsHandler: Boolean);
begin
  inherited Create;
  FHandler := AHandler;
  FOwnsHandler := AOwnsHandler;
  FCfg := ACfg;
  if FCfg.CloseTimeoutMs <= 0 then
    FCfg.CloseTimeoutMs := 5000;
  if FCfg.SendHighWater <= 0 then
    FCfg.SendHighWater := 1024 * 1024;
  FReader.Init(FCfg.MaxMessage);
  FPeerCode := WS_CLOSE_ABNORMAL;
  FRefs := 1;
  TimerInit(@FIdleTimer, @WsTimerProc, Self);
  TimerInit(@FPingTimer, @WsTimerProc, Self);
  TimerInit(@FCloseTimer, @WsTimerProc, Self);
  FPostMsg.Kind := lmCall;
  FPostMsg.Proc := @WsPostProc;
  FPostMsg.Arg := Self;
  InterLockedIncrement(WebSocketsLive);
end;

destructor TWebSocket.Destroy;
begin
  { Finish released the loop resources; a TWebSocket that never started
    has none }
  if (not FFinished) and FOwnsHandler then
    FreeAndNil(FHandler);
  InterLockedDecrement(WebSocketsLive);
  inherited Destroy;
end;

procedure TWebSocket.Start(U: TUpgraded);
begin
  FU := U;
  FLoop := U.Loop;
  if FCfg.IdleTimeoutMs > 0 then
    FLoop.Timers.Arm(@FIdleTimer, FLoop.NowMs + FCfg.IdleTimeoutMs);
  if FCfg.PingIntervalMs > 0 then
    FLoop.Timers.Arm(@FPingTimer, FLoop.NowMs + FCfg.PingIntervalMs);
  U.Attach(Self);                    { one run now: OnOpen and the leftover bytes }
end;

procedure TWebSocket.Readable(U: TUpgraded);
begin
  Step;
end;

procedure TWebSocket.Writable(U: TUpgraded);
begin
  { Step did the writing too }
end;

procedure TWebSocket.Shutdown(U: TUpgraded);
begin
  if not Closing then
    CloseWith(WS_CLOSE_GOING_AWAY, 'server shutdown');
end;

procedure TWebSocket.Aborted(U: TUpgraded);
begin
  if FFinished then
    Exit;
  FEnded := True;
  if FReadBlk <> nil then
  begin
    FLoop.Blocks.Give(FReadBlk);
    FReadBlk := nil;
  end;
  Finish(False);                     { U closes itself after this returns }
end;

procedure TWebSocket.Abort;
begin
  if FFinished or FEnded then
    Exit;
  FEnded := True;
  if not FInStep then
    FU.Wake;                         { Step finishes the connection }
end;

procedure TWebSocket.AddRef;
begin
  InterLockedIncrement(FRefs);
end;

procedure TWebSocket.Release;
begin
  if InterLockedDecrement(FRefs) = 0 then
    Free;
end;

function TWebSocket.Queued: SizeInt;
begin
  Result := FQueued;
end;

function TWebSocket.Closing: Boolean;
begin
  Result := FCloseSent or FFailed or FEnded or FFinished;
end;

{ the connection is on its way out: no more frames are parsed }
function TWebSocket.Ending: Boolean;
begin
  Result := FFailed or FCloseReceived or FEnded;
end;

procedure TWebSocket.ArmClose;
begin
  if FCloseTimer.Deadline = 0 then
    FLoop.Timers.Arm(@FCloseTimer, FLoop.NowMs + FCfg.CloseTimeoutMs);
end;

{ One run of the connection: everything happens here, so that the object
  is freed (Finish) only here, after every callback returned. }
procedure TWebSocket.Step;
begin
  if FFinished then
    Exit;
  FInStep := True;
  try
    if not FOpened then
    begin
      FOpened := True;
      FHandler.OnOpen(Self);
    end;
    if FPostedCount > 0 then
      DrainPosted;
    HandleTimers;
    if not FEnded then
      ReadInput;
    Flush;
    if FReadPaused and not FEnded and (Queued < FCfg.SendHighWater) then
    begin
      { the queue drained below the mark in this run: read what waited }
      ReadInput;
      Flush;
    end;
    { the end: output flushed, then the write side shut down, then the
      client's end of stream (or the close timeout) }
    if Ending and not FEnded and (Queued = 0) and not FShutDown then
    begin
      FShutDown := True;
      if FU.Transport <> nil then
        FU.Transport.ShutdownWrite;
      FU.Wake;                       { read to the end of stream }
    end;
  except
    on E: Exception do
    begin
      if Assigned(LoopErrorProc) then
        LoopErrorProc(FLoop, FU, E);
      Fail(WS_CLOSE_INTERNAL_ERROR, E.ClassName + ': ' + E.Message);
      FU.Wake;
    end;
  end;
  FInStep := False;
  if FReadBlk <> nil then
  begin
    FLoop.Blocks.Give(FReadBlk);
    FReadBlk := nil;
  end;
  if FEnded then
    Finish(True);                    { frees Self when no other reference is held }
end;

procedure TWebSocket.HandleTimers;
begin
  if FCloseFired then
  begin
    FCloseFired := False;
    FEnded := True;
    Exit;
  end;
  if FIdleFired then
  begin
    FIdleFired := False;
    if not Closing then
      CloseWith(WS_CLOSE_GOING_AWAY, 'idle timeout');
  end;
  if FPingFired then
  begin
    FPingFired := False;
    if not Closing then
    begin
      QueueFrame(WS_OP_PING, nil, 0, True);
      FLoop.Timers.Arm(@FPingTimer, FLoop.NowMs + FCfg.PingIntervalMs);
    end;
  end;
end;

procedure TWebSocket.ReadInput;
var
  R: SizeInt;
  Reads: Integer;
begin
  Reads := 0;
  while not FEnded do
  begin
    { backpressure: the client does not read what we send }
    FReadPaused := (not Ending) and (Queued >= FCfg.SendHighWater);
    if FReadPaused then
      Exit;
    if FReadBlk = nil then
      FReadBlk := FLoop.Blocks.Take(WS_READ_BLOCK);
    R := FU.TryRead(FReadBlk^.Data, FReadBlk^.Size);
    if R = -ESysEAGAIN then
      Exit;
    if R = 0 then
    begin
      FEnded := True;                { end of stream }
      Exit;
    end;
    if R < 0 then
    begin
      IoFailed('read', -R);
      Exit;
    end;
    if FCfg.IdleTimeoutMs > 0 then
      FLoop.Timers.Arm(@FIdleTimer, FLoop.NowMs + FCfg.IdleTimeoutMs);
    if not Ending then
      HandleBytes(FReadBlk^.Data, R);  { else: bytes after the end are dropped }
    Inc(Reads);
    if Reads >= WS_READS_PER_RUN then
    begin
      FU.Wake;                       { yield: the rest in a later run }
      Exit;
    end;
  end;
end;

procedure TWebSocket.HandleBytes(P: PByte; L: SizeInt);
begin
  while not Ending do
    case FReader.Next(P, L) of
      reNeedMore:
        Exit;
      reData:
        if not FCloseSent then
          Deliver(FReader.MsgOpcode, FReader.Data, FReader.DataLen);
        { after our close frame, data messages are dropped }
      reControl:
        HandleControl;
      reError:
        begin
          Fail(FReader.ErrCode, FReader.ErrText);
          Exit;
        end;
    end;
end;

procedure TWebSocket.Deliver(Opcode: Byte; P: PByte; Len: SizeInt);
begin
  if not (FReader.MsgFirst and FReader.MsgEnd) then
  begin
    { a message in pieces: collect it }
    if Len > 0 then
      FMsg.Append(P, Len, @FLoop.Blocks);
    if not FReader.MsgEnd then
      Exit;
    P := FMsg.Data;
    Len := FMsg.Len;
  end;
  try
    if Opcode = WS_OP_TEXT then
      FHandler.OnText(Self, P, Len)
    else
      FHandler.OnBinary(Self, P, Len);
  finally
    if FMsg.Len > 0 then
    begin
      FMsg.Clear;
      FMsg.ReleaseIdle(@FLoop.Blocks);
    end;
  end;
end;

procedure TWebSocket.HandleControl;
var
  Code: Word;
  Reason: RawByteString;
begin
  case FReader.CtlOpcode of
    WS_OP_PING:
      if not FCloseSent then
        QueueFrame(WS_OP_PONG, @FReader.Ctl[0], FReader.CtlLen, True);
    WS_OP_PONG:
      FHandler.OnPong(Self, @FReader.Ctl[0], FReader.CtlLen);
    WS_OP_CLOSE:
      begin
        FCloseReceived := True;
        if FReader.CtlLen >= 2 then
        begin
          Code := (Word(FReader.Ctl[0]) shl 8) or FReader.Ctl[1];
          SetString(Reason, PAnsiChar(@FReader.Ctl[2]), FReader.CtlLen - 2);
        end
        else
        begin
          Code := WS_CLOSE_NO_STATUS;
          Reason := '';
        end;
        FPeerCode := Code;
        FPeerReason := Reason;
        if not FCloseSent then
        begin
          { the answer carries the same code (none when the client sent none) }
          if Code = WS_CLOSE_NO_STATUS then
            QueueClose(0, '')
          else
            QueueClose(Code, '');
        end;
        ArmClose;
      end;
  end;
end;

procedure TWebSocket.QueueClose(Code: Word; const Reason: RawByteString);
var
  Buf: array[0..WS_MAX_CONTROL - 1] of Byte;
  N: Integer;
begin
  N := 0;
  if Code <> 0 then
  begin
    Buf[0] := Code shr 8;
    Buf[1] := Code and $FF;
    N := Length(Reason);
    if N > WS_MAX_CONTROL - 2 then
      N := WS_MAX_CONTROL - 2;
    if N > 0 then
      Move(Reason[1], Buf[2], N);
    Inc(N, 2);
  end;
  QueueFrame(WS_OP_CLOSE, @Buf[0], N, True);
  FCloseSent := True;
end;

procedure TWebSocket.Fail(Code: Word; const Msg: string);
begin
  if FFailed or FFinished then
    Exit;
  FFailed := True;
  if not FCloseSent and not FEnded then
    QueueClose(Code, '');
  ArmClose;
  try
    FHandler.OnError(Self, Code, Msg);
  except
    on E: Exception do
      if Assigned(LoopErrorProc) then
        LoopErrorProc(FLoop, FU, E);
  end;
end;

procedure TWebSocket.IoFailed(const What: string; Errno: cint);
begin
  { the socket is unusable: nothing more can be sent (FEnded first, so
    Fail does not try to send a close frame) }
  FEnded := True;
  if not FCloseReceived then
    Fail(WS_CLOSE_ABNORMAL, What + ': ' + SysErrorMessage(Errno));
end;

{ ---- the output queue ---- }

procedure TWebSocket.PushSeg(Len: SizeInt; P: PByte; Ref: Pointer);
var
  N: array of TWsSeg;
  I: Integer;
begin
  if FSegCount = Length(FSegs) then
  begin
    { a ring twice as large, in queue order }
    SetLength(N, 8 + 2 * Length(FSegs));
    for I := 0 to FSegCount - 1 do
      N[I] := FSegs[(FSegHead + I) mod Length(FSegs)];
    FSegs := N;
    FSegHead := 0;
  end;
  I := (FSegHead + FSegCount) mod Length(FSegs);
  FSegs[I].Len := Len;
  FSegs[I].P := P;
  FSegs[I].Ref := Ref;
  Inc(FSegCount);
  Inc(FQueued, Len);
end;

procedure TWebSocket.PushCopy(P: PByte; N: SizeInt);
var
  T: Integer;
begin
  if N <= 0 then
    Exit;
  FOut.Append(P, N, @FLoop.Blocks);
  if FSegCount > 0 then
  begin
    T := (FSegHead + FSegCount - 1) mod Length(FSegs);
    if FSegs[T].Ref = nil then
    begin
      { the last segment holds copied bytes too: it grows }
      Inc(FSegs[T].Len, N);
      Inc(FQueued, N);
      Exit;
    end;
  end;
  PushSeg(N, nil, nil);
end;

procedure TWebSocket.PushShared(const F: TWsFrame; Off: SizeInt);
var
  Ref: Pointer;
begin
  Ref := nil;
  RawByteString(Ref) := F;           { one reference, held by the segment }
  PushSeg(Length(F) - Off, PByte(F) + Off, Ref);
end;

{ W bytes of the queue were written: they leave it from the front }
procedure TWebSocket.Consume(W: SizeInt);
var
  N: SizeInt;
begin
  while W > 0 do
  begin
    N := FSegs[FSegHead].Len;
    if N > W then
      N := W;
    if FSegs[FSegHead].Ref = nil then
      Inc(FOutPos, N)
    else
      Inc(FSegs[FSegHead].P, N);
    Dec(FSegs[FSegHead].Len, N);
    Dec(FQueued, N);
    Dec(W, N);
    if FSegs[FSegHead].Len = 0 then
    begin
      if FSegs[FSegHead].Ref <> nil then
        RawByteString(FSegs[FSegHead].Ref) := '';   { drops the reference }
      FSegHead := (FSegHead + 1) mod Length(FSegs);
      Dec(FSegCount);
    end;
  end;
end;

procedure TWebSocket.ClearQueue;
var
  I: Integer;
begin
  for I := 0 to FSegCount - 1 do
    with FSegs[(FSegHead + I) mod Length(FSegs)] do
      if Ref <> nil then
        RawByteString(Ref) := '';
  FSegs := nil;
  FSegHead := 0;
  FSegCount := 0;
  FQueued := 0;
  FOut.Clear;
  FOutPos := 0;
  FOut.ReleaseIdle(@FLoop.Blocks);
end;

{ after a failure only the close frame (Fail's) may go out; a data send
  is refused while the queue is at the mark }
function TWebSocket.Refused(Opcode: Byte; Control: Boolean): Boolean;
begin
  Result := FCloseSent or FEnded or FFinished or (FFailed and (Opcode <> WS_OP_CLOSE));
end;

function TWebSocket.QueueFrame(Opcode: Byte; P: PByte; Len: SizeInt; Control: Boolean): TWsSendResult;
var
  Hdr: array[0..WS_MAX_HEADER - 1] of Byte;
  H: Integer;
  Iov: array[0..1] of TSysIoVec;
  W, Total, Skip: SizeInt;
begin
  if Refused(Opcode, Control) then
    Exit(wsClosed);
  if (not Control) and (FQueued >= FCfg.SendHighWater) then
  begin
    FWantWritable := True;
    Exit(wsFull);
  end;
  H := WsEncodeHeader(@Hdr[0], True, Opcode, Len);
  Total := H + Len;
  W := 0;
  if (FQueued = 0) and (FU.Transport <> nil) then
  begin
    { nothing queued: straight to the socket }
    Iov[0].Base := @Hdr[0];
    Iov[0].Len := H;
    Iov[1].Base := P;
    Iov[1].Len := Len;
    if Len > 0 then
      W := FU.Transport.WriteV(@Iov[0], 2)
    else
      W := FU.Transport.Write(@Hdr[0], H);
    if W = -ESysEAGAIN then
      W := 0
    else if W < 0 then
    begin
      if not FInStep then
        FU.Wake;
      IoFailed('write', -W);
      Exit(wsClosed);
    end;
  end;
  if W < Total then
  begin
    { the rest is copied to the queue }
    if W < H then
    begin
      PushCopy(@Hdr[W], H - W);
      Skip := 0;
    end
    else
      Skip := W - H;
    PushCopy(P + Skip, Len - Skip);
    if not FInStep then
      FU.Wake;                       { flushed by Step when the socket is writable }
  end;
  Result := wsOk;
end;

function TWebSocket.QueuePrepared(const F: TWsFrame; Control: Boolean): TWsSendResult;
var
  W, N: SizeInt;
begin
  if Refused(0, Control) then
    Exit(wsClosed);
  if (not Control) and (FQueued >= FCfg.SendHighWater) then
  begin
    FWantWritable := True;
    Exit(wsFull);
  end;
  N := Length(F);
  W := 0;
  if (FQueued = 0) and (FU.Transport <> nil) then
  begin
    W := FU.Transport.Write(PByte(F), N);
    if W = -ESysEAGAIN then
      W := 0
    else if W < 0 then
    begin
      if not FInStep then
        FU.Wake;
      IoFailed('write', -W);
      Exit(wsClosed);
    end;
  end;
  if W < N then
  begin
    if N - W < WS_SHARE_MIN then
      PushCopy(PByte(F) + W, N - W)
    else
      PushShared(F, W);
    if not FInStep then
      FU.Wake;
  end;
  Result := wsOk;
end;

function TWebSocket.SendFrame(const F: TWsFrame): TWsSendResult;
var
  Op: Byte;
begin
  Assert(GetCurrentThreadId = FLoop.ThreadId, 'TWebSocket.SendFrame: not on the loop thread');
  if not WsFrameValid(F, Op) or (Op = WS_OP_CLOSE) then
    raise EArgumentException.Create('TWebSocket.SendFrame: not a prepared data, ping or pong frame');
  Result := QueuePrepared(F, Op >= 8);
end;

procedure TWebSocket.Flush;
var
  Iov: array[0..WS_MAX_IOV - 1] of TSysIoVec;
  N, I, K: Integer;
  C: SizeInt;
  W: SizeInt;
begin
  while (FQueued > 0) and not FEnded and (FU.Transport <> nil) do
  begin
    { the first segments, as one writev; copied bytes follow each other in FOut }
    N := FSegCount;
    if N > WS_MAX_IOV then
      N := WS_MAX_IOV;
    C := FOutPos;
    for I := 0 to N - 1 do
    begin
      K := (FSegHead + I) mod Length(FSegs);
      if FSegs[K].Ref = nil then
      begin
        Iov[I].Base := FOut.Data + C;
        Inc(C, FSegs[K].Len);
      end
      else
        Iov[I].Base := FSegs[K].P;
      Iov[I].Len := FSegs[K].Len;
    end;
    if N = 1 then
      W := FU.Transport.Write(Iov[0].Base, Iov[0].Len)
    else
      W := FU.Transport.WriteV(@Iov[0], N);
    if W = -ESysEAGAIN then
      Break;
    if W < 0 then
    begin
      IoFailed('write', -W);
      Break;
    end;
    Consume(W);
  end;
  if FQueued = 0 then
  begin
    if FOut.Len > 0 then
    begin
      FOut.Clear;
      FOutPos := 0;
      FOut.ReleaseIdle(@FLoop.Blocks);
    end;
  end
  else if (FOutPos > 0) and (FOutPos >= FOut.Len div 2) then
  begin
    FOut.DrainFront(FOutPos);        { keep the copied bytes from growing at the front }
    FOutPos := 0;
  end;
  if FWantWritable and not Closing and (FQueued <= FCfg.SendHighWater div 2) then
  begin
    FWantWritable := False;
    FHandler.OnWritable(Self);
  end;
end;

procedure TWebSocket.DrainPosted;
var
  Items: array of TWsPosted;
  N, I: Integer;
begin
  FPostLock.Acquire;
  Items := FPosted;
  N := FPostedCount;
  FPosted := nil;
  FPostedCount := 0;
  FPostedBytes := 0;
  FPostLock.Release;
  for I := 0 to N - 1 do
    if Items[I].Opcode = 0 then
      QueuePrepared(Items[I].Data, True)
    else
      QueueFrame(Items[I].Opcode, PByte(Items[I].Data), Length(Items[I].Data), True);
end;

function TWebSocket.Post(Opcode: Byte; const Data: RawByteString): TWsSendResult;
var
  NeedPost: Boolean;
begin
  FPostLock.Acquire;
  if FPostClosed then
  begin
    FPostLock.Release;
    Exit(wsClosed);
  end;
  if FPostedBytes >= FCfg.SendHighWater then
  begin
    FPostLock.Release;
    Exit(wsFull);
  end;
  if FPostedCount = Length(FPosted) then
    SetLength(FPosted, 4 + 2 * Length(FPosted));
  FPosted[FPostedCount].Opcode := Opcode;
  FPosted[FPostedCount].Data := Data;
  Inc(FPostedCount);
  Inc(FPostedBytes, Length(Data));
  NeedPost := not FPostQueued;
  FPostQueued := True;
  if NeedPost then
    InterLockedIncrement(FRefs);     { the inbox message holds a reference }
  FPostLock.Release;
  if NeedPost then
    FLoop.Post(@FPostMsg);
  Result := wsOk;
end;

function TWebSocket.PostText(const S: RawByteString): TWsSendResult;
begin
  Result := Post(WS_OP_TEXT, S);
end;

function TWebSocket.PostBinary(const S: RawByteString): TWsSendResult;
begin
  Result := Post(WS_OP_BINARY, S);
end;

function TWebSocket.PostFrame(const F: TWsFrame): TWsSendResult;
var
  Op: Byte;
begin
  if not WsFrameValid(F, Op) or (Op = WS_OP_CLOSE) then
    raise EArgumentException.Create('TWebSocket.PostFrame: not a prepared data, ping or pong frame');
  Result := Post(0, F);
end;

function TWebSocket.SendText(P: PByte; Len: SizeInt): TWsSendResult;
begin
  Assert(GetCurrentThreadId = FLoop.ThreadId, 'TWebSocket.SendText: not on the loop thread');
  Result := QueueFrame(WS_OP_TEXT, P, Len, False);
end;

function TWebSocket.SendText(const S: RawByteString): TWsSendResult;
begin
  Result := SendText(PByte(S), Length(S));
end;

function TWebSocket.SendBinary(P: PByte; Len: SizeInt): TWsSendResult;
begin
  Assert(GetCurrentThreadId = FLoop.ThreadId, 'TWebSocket.SendBinary: not on the loop thread');
  Result := QueueFrame(WS_OP_BINARY, P, Len, False);
end;

function TWebSocket.SendBinary(const S: RawByteString): TWsSendResult;
begin
  Result := SendBinary(PByte(S), Length(S));
end;

function TWebSocket.Ping(const Payload: RawByteString): TWsSendResult;
begin
  if Length(Payload) > WS_MAX_CONTROL then
    Exit(wsClosed);
  Result := QueueFrame(WS_OP_PING, PByte(Payload), Length(Payload), True);
end;

function TWebSocket.CloseWith(Code: Word; const Reason: RawByteString): Boolean;
begin
  if Closing or FEnded or ((Code <> 0) and not WsCloseCodeValid(Code)) then
    Exit(False);
  QueueClose(Code, Reason);
  ArmClose;
  if not FInStep then
    FU.Wake;
  Result := True;
end;

procedure TWebSocket.Finish(CloseStream: Boolean);
var
  H: TWebSocketHandler;
begin
  FFinished := True;
  FLoop.Timers.Remove(@FIdleTimer);
  FLoop.Timers.Remove(@FPingTimer);
  FLoop.Timers.Remove(@FCloseTimer);
  FMsg.Clear;
  FMsg.ReleaseIdle(@FLoop.Blocks);
  ClearQueue;
  FPostLock.Acquire;
  FPostClosed := True;
  FPosted := nil;
  FPostedCount := 0;
  FPostLock.Release;
  if CloseStream then
    FU.Close;                        { the TUpgraded is freed by the loop after this batch }
  H := FHandler;
  try
    H.OnClose(Self, FPeerCode, FPeerReason);
  except
    on E: Exception do
      if Assigned(LoopErrorProc) then
        LoopErrorProc(FLoop, FU, E);
  end;
  if FOwnsHandler then
  begin
    FHandler := nil;
    H.Free;
  end;
  Release;                           { the loop's reference }
end;

{ ---- TWsUpgradeHandler ---- }

constructor TWsUpgradeHandler.Create(AHandler: TWebSocketHandler; const ACfg: TWsConfig);
begin
  inherited Create;
  Handler := AHandler;
  Cfg := ACfg;
end;

procedure TWsUpgradeHandler.Upgraded(U: TUpgraded);
var
  WS: TWebSocket;
begin
  WS := TWebSocket.Create(Handler, Cfg);
  Handler := nil;
  Free;
  WS.Start(U);
end;

procedure TWsUpgradeHandler.UpgradeFailed(const Msg: string);
begin
  Handler.Free;
  Free;
end;

function AcceptWebSocket(Ex: TExchange; const R: TWsHandshake; Handler: TWebSocketHandler;
  const Cfg: TWsConfig): Boolean;
begin
  Result := Respond101(Ex, R, TWsUpgradeHandler.Create(Handler, Cfg));
end;

end.

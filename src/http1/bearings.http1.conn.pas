{ bearings.http1.conn - the HTTP/1.1 state machine of one server connection.

  TH1Conn holds the buffered transport (TH1Io, bearings.http1.io) and the
  connection state (TConnState). It reads request heads and bodies, writes
  response heads and bodies, and decides after each exchange whether the
  connection stays open for another request. The dispatcher
  (bearings.http1.dispatch) drives it: it calls the Poll* routines when the
  connection's task runs, and passes requests to the application and
  responses back.

  State. Reading and writing each have their own state:
    Reading  rdInit       waiting for, or parsing, a request head
             rdContinue   head read with "Expect: 100-continue"; the body
                          has not been asked for yet (see below)
             rdBody       reading the body through ReadDecoder
             rdKeepAlive  the request was read completely; wait until the
                          response is done before reading the next head
             rdClosed     nothing more is read
    Writing  wrInit       no response head written yet
             wrBody       head written; the body goes through WriteEncoder
             wrKeepAlive  the response was written completely
             wrClosed     nothing more is written
  KeepAlive (TKA) says whether the connection may serve another request:
  kaBusy while a request is in progress, kaIdle between requests, and
  kaDisabled once it must close after the current response. When both
  sides reach their KeepAlive state, TryKeepAlive resets both to Init (the
  next request) or, if keep-alive is disabled, closes both.

  Requests are handled one at a time: the next head is parsed only after
  the response to the previous request is complete, so with pipelining
  (several requests sent without waiting) the responses leave in request
  order. The bytes of later requests wait in the read buffer.

  Keep-alive. In HTTP/1.1 a connection stays open after a response unless
  the request or the response says "Connection: close"; in HTTP/1.0 it
  closes unless "Connection: keep-alive" is sent. PollReadHead records the
  request's choice; EnforceVersion and FixKeepAlive adjust the response
  head to match (a 1.0 client gets a 1.0 response, and "connection: close"
  is added when the server will close). A response body without a known
  length on a 1.0 connection can only end by closing the connection.

  Expect: 100-continue. A client may send the head with this field and wait
  before sending a large body, so the server can reject the request without
  receiving it. The connection writes "HTTP/1.1 100 Continue" only when the
  application first reads the body (PollReadBody in rdContinue) and no
  response head was written yet; a handler that answers without reading
  the body never asks for it.

  Bad requests. When the head cannot be parsed, OnParseError writes an
  automatic response (400 Bad Request; 414 URI Too Long; 431 Request Header
  Fields Too Large for a head over the size limit) if no response was
  started, and the connection then closes. A client that sends the HTTP/2
  connection preface (H2_PREFACE) gets no response, only the error.

  Draining. When the application finished its response without reading the
  whole request body, the unread body bytes are still in front of the next
  request. PollDrainOrCloseRead reads once more and discards what arrives;
  if the body has not ended then, reading is closed, so the connection is
  not reused.

  Timeouts. The header read timeout (HeaderReadTimer) limits the time
  between the start of a head read and a complete head; it protects against
  clients that open connections and send the head very slowly. The body
  rate rule: with State.BodyTimeoutMs > 0, the time the server waits for
  request body bytes is measured. A wait starts when PollReadBody finds no
  byte (the dispatcher reads only while the receiver has room, so the
  server is ready for the bytes) and ends with the next frame. The body
  fails with NewBodyIo(ETIMEDOUT) (Reading closed, the handler sees a body
  error) when one wait lasts BodyTimeoutMs, or, with BodyMinRate > 0, when
  the waits of this body since its first byte add up to T >= BodyTimeoutMs
  and fewer than BodyMinRate * T / 1000 body bytes came. The wait before
  the first byte counts only for the first rule. BodyTimer (wakes the
  owner) is armed at the earlier of the two deadlines. Time the handler
  does not read is not counted.

  Graceful shutdown of the connection: PollShutdown writes what is
  buffered and then shuts down the socket's write side, so the client reads
  the whole last response followed by EOF.

  Results. A Pending result means the transport returned EAGAIN (the task
  runs again on the next readiness event) or a timer is armed (its Proc
  wakes Owner). Errors are THyperError values (bearings.http.error).

  File bodies: WriteBody and WriteBodyAndEnd encode a bkFile chunk as for
  memory and queue its framing around a qkFile entry (BufferFileFrame):
  chunk-size line, the file range (sent with sendfile(2)), suffix. The
  bytes on the wire are the same as for a memory chunk with the file's
  content.

  Threading: a TH1Conn belongs to the loop thread of its connection.

  No managed types: no routine of this unit gets an implicit exception frame
  (tools/check-hot-asm.sh checks TH1Conn.*). The EH1Panic for a response
  with an unusable HTTP version is raised by a separate routine. }
unit bearings.http1.conn;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

uses
  ctypes, bearings.rt.buf, bearings.rt.timer, bearings.rt.loop, bearings.rt.net, bearings.http1.io, bearings.http1.parser,
  bearings.http1.role, bearings.http1.encode, bearings.http1.decode, bearings.http.headers, bearings.http.error,
  bearings.http.exchange, bearings.rt.sys;

type
  { the states are described in the unit header }
  TReading = (rdInit, rdContinue, rdBody, rdKeepAlive, rdClosed);
  TWriting = (wrInit, wrBody, wrKeepAlive, wrClosed);
  TKA = (kaIdle, kaBusy, kaDisabled);                               { a new connection starts kaBusy }
  { What a parsed request asks for besides the normal exchange: an upgrade
    to another protocol (Upgrade header or CONNECT), or a 100 Continue. }
  TWant = (wantUpgrade, wantExpect);
  TWants = set of TWant;

  { The response body length given to WriteHead: blkNone = no body
    (status or method forbids one, or an empty body), blkKnown = Len bytes
    (Content-Length), blkUnknown = length not known in advance (chunked
    for HTTP/1.1, close-delimited for HTTP/1.0). }
  TBodyLength = record
    Kind: TBodyLengthKind;
    Len: QWord;                      { blkKnown }
  end;

  TInFrameKind = (ifData, ifTrailers);
  TInFrame = record
    Kind: TInFrameKind;
    Data: TBytesView;                { ifData: pinned view of the read buffer }
  end;                               { ifTrailers: the decoder filled the Trailers list }

  { Result of DecodeFrame. }
  TDecodeFrame = (dfData, dfTrailers, dfDecodeError, dfIoError, dfPending);

  { Per-connection scratch memory for the codec's rare paths, kept here so
    the encoder and decoder records stay small: the trailer names a
    response declared in its Trailer header (TEncoder.FTrailers), and the
    decoder's buffer for request trailer bytes (TDecoder.FTrailerScratch). }
  TConnScratch = record
    TrailerNames: TTrailerFieldSet;
    TrailerBytes: TByteVec;
    { The header list of an automatic 400/414/431 head and of a response
      head given without a list (EnforceVersion may add "connection:
      close" to it); nil until first use. }
    ErrHeaders: THttpHeaders;
  end;

  TConnState = record
    { Keep serving after the client shut down its write side (a half-closed
      TCP connection); off by default: an EOF while a request is in
      progress is then an error. }
    AllowHalfClose: Boolean;
    HasError: Boolean;               { Error holds an error for TakeError }
    Error: THyperError;
    KeepAlive: TKA;
    Method: THttpMethod;             { the current request's method (the encoder needs it for HEAD and CONNECT); hmNone = none }
    ParseCtx: TH1ParseContext;
    HeaderReadTimeoutMs: Int64;      { -1 = no header read timeout }
    { Armed when a head read starts; a fired timer fails the head read with
      NewHeaderTimeout. }
    HeaderReadTimer: TTimer;
    HeaderReadTimeoutRunning: Boolean;
    { The PROXY protocol header (bearings.rt.proxyproto) is expected before
      the first request (SetProxyProtocol). ProxyPeerSet: ProxyPeer holds
      the address it carried, for the dispatcher (TakeProxyPeer). }
    ProxyPending: Boolean;
    ProxyPeerSet: Boolean;
    ProxyPeer: TSockAddrStorage;
    DateHeader: Boolean;             { add a Date header to responses }
    TitleCaseHeaders: Boolean;       { write header names Title-Cased instead of as given }
    { The dispatcher should try to read again (WantsReadAgain): set when the
      connection became idle and a next request may already be buffered, or
      the header read timer must be started. }
    NotifyRead: Boolean;
    Reading: TReading;
    ReadDecoder: TDecoder;           { valid in rdContinue and rdBody (no managed fields) }
    Writing: TWriting;
    WriteEncoder: TEncoder;          { valid in wrBody (no managed fields) }
    { The pending protocol upgrade of the current request (101 Switching
      Protocols or CONNECT): the slot through which the connection is
      handed to the upgrade handler. }
    Upgrade: TUpgradePending;
    Version: THttpVersion;           { the client's HTTP version; starts hv11 }
    { The request had "TE: trailers": the client accepts trailer fields in
      a chunked response; WriteTrailers drops trailers otherwise. }
    AllowTrailerFields: Boolean;
    { the body rate rule (0 = off; see the unit header) }
    BodyTimeoutMs: Int64;
    BodyMinRate: Int64;              { bytes per second; 0 = only the wait limit }
    BodyTimer: TTimer;               { wakes the owner at the rule's deadline (lazy cancel, see bearings.rt.timer) }
    BodyWaiting: Boolean;            { a read of the body found no byte; BodyWaitStartMs set }
    BodyWaitStartMs: Int64;
    BodyWaitedMs: Int64;             { this body's earlier waits since its first byte }
    BodyReceived: Int64;             { this body's data bytes so far }
    { each Close* also disables keep-alive }
    procedure Close;  procedure CloseRead;  procedure CloseWrite;
    function WantsKeepAlive: Boolean;
    { both sides done: start the next request (Idle) or close }
    procedure TryKeepAlive;
    procedure DisableKeepAlive;  procedure Busy;
    { between requests: Reading and Writing back to Init; sets NotifyRead
      when a header read timeout is configured }
    procedure Idle;
    function IsIdle: Boolean;  function IsReadClosed: Boolean;  function IsWriteClosed: Boolean;
    { creates the upgrade slot for the current request and links it to the
      exchange Ex (a TExchange; nil in tests) }
    procedure PrepareUpgrade(Ex: TObject);
  end;

  TH1Conn = record
    Io: TH1Io;
    State: TConnState;
    Owner: TObject;                  { the TH1Dispatcher (the timers wake it) }
    Loop: TLoop;                     { Owner's loop when Owner is a TLoopTask, else nil }
    Scratch: TConnScratch;           { trailer names, decoder trailer bytes, error head list }
    { True while OnParseError writes its head: that head may be written
      while entries are queued (TH1Io.BufferAfterQueue), which EncodeHead
      otherwise does not allow }
    ErrorHeadPending: Boolean;
    procedure Init(AIo: TTransport; APool: PBlockPool; AOwner: TObject);
    { Removes the timers, cancels a pending upgrade, frees the buffers and
      the scratch. Does not close the transport. }
    procedure Done;
    { An idle connection gives the trailer scratch back (the declared
      trailer names and the decoder's trailer bytes); both are needed only
      during one request. }
    procedure ReleaseIdleScratch; inline;
    { setters used by ApplyH1Config (bearings.http1.config) }
    procedure SetFlushPipeline(Enabled: Boolean);
    procedure SetMaxBufSize(Max: SizeInt);  procedure SetParserConfig(const C: TParserConfig);
    procedure SetTitleCaseHeaders;  procedure SetMaxHeaders(N: Integer);
    procedure SetMaxHeaderSize(N: SizeInt);  procedure SetHeaderReadTimeout(Ms: Int64);
    procedure SetAllowHalfClose;  procedure DisableDateHeader;
    { the connection starts with a PROXY protocol header (TH1Config.ProxyProtocol) }
    procedure SetProxyProtocol;
    { True once, after the header was read with an address: Peer is the
      client's address and port as the proxy saw them }
    function TakeProxyPeer(out Peer: TSockAddrStorage): Boolean;
    { the body rate rule; TimeoutMs > 0 needs Loop (the timer) }
    procedure SetBodyReadTimeout(TimeoutMs, MinRate: Int64);

    function IsReadClosed: Boolean;  function IsWriteClosed: Boolean;
    function CanReadHead: Boolean;
    function CanReadBody: Boolean;
    { nothing read or written yet: no request was started }
    function HasInitialReadWriteState: Boolean;
    { the read buffer starts with the HTTP/2 connection preface }
    function HasH2Prefix: Boolean;

    { Reads the next request head. poSome: Msg filled, Head = pinned head
      view, Headers filled, Wants set, and the read state set for the body
      (rdKeepAlive when there is none). poNone: the client closed the
      connection between requests. poPending: wait for more bytes, or an
      automatic error response was buffered (the error follows through
      TakeError). poErr: Err set. }
    function PollReadHead(Headers: THttpHeaders; out Msg: TParsedRequestHead;
      out Head: TBytesView; out Wants: TWants; var Err: THyperError): TPollOpt;
    function OnReadHeadError(var Err: THyperError): TPollOpt;
    function PollReadProxy(var Err: THyperError): TPollOpt;
    { Runs the body decoder over the read buffer, reading from the socket
      when the decoder needs more and the buffer is empty. }
    function DecodeFrame(Trailers: THttpHeaders; out View: TBytesView; out DErr: TDecodeError;
      out Errno: cint): TDecodeFrame;
    { Reads the next piece of the request body. poSome: Frame is data (a
      pinned view) or trailers; poNone: the body ended; poPending: wait.
      Trailers: where a trailer frame goes (nil: validated and dropped).
      poErr: Err set, and stored for TakeError too. }
    function PollReadBody(Trailers: THttpHeaders; out Frame: TInFrame; var Err: THyperError): TPollOpt;
    { returns NotifyRead and clears it }
    function WantsReadAgain: Boolean;
    { Called while neither a head nor a body can be read (the request was
      read, its response is in progress): detects a client that closed the
      connection in the middle of the exchange. }
    function PollReadKeepAlive(var Err: THyperError): TPollResult;
    function IsMidMessage: Boolean;
    function MidMessageDetectEof(var Err: THyperError): TPollResult;
    function ForceIoRead(out N: SizeInt; out Errno: cint): TIoPoll;
    { After a response: if the connection is ready for a new head, reads
      from the socket when the buffer is empty and sets NotifyRead, so the
      dispatcher parses the next (possibly pipelined) request without
      waiting for another readiness event. }
    procedure MaybeNotify;
    procedure TryKeepAlive;                                          { State.TryKeepAlive, then MaybeNotify }
    { the body rate rule: a body read found no byte; True when the rule is broken (else
      the timer is armed at the deadline) }
    function BodyWaitExpired: Boolean;
    procedure BodyProgress(Len: SizeInt);   { a frame came: the wait ends, Len data bytes }
    procedure StartBodyClock; inline;       { a new request body }

    function CanWriteHead: Boolean;  function CanWriteBody: Boolean;
    { room in the write buffer for another body piece (TH1Io.CanBuffer) }
    function CanBufferBody: Boolean;  function HasBufferedWrite: Boolean;
    { Encodes the response head into the write buffer and sets the write
      state: wrBody when a body follows, else wrKeepAlive or wrClosed. On
      an encoding error the error is stored and writing is closed. }
    procedure WriteHead(var Head: TResponseHead; const Body: TBodyLength);
    { False on an encoding error (stored in State.Error). Raises EH1Panic
      for a response version that cannot be written. }
    function EncodeHead(var Head: TResponseHead; const Body: TBodyLength;
      out Enc: TEncoder): Boolean;
    { HTTP/1.0 client: keeps the connection open only when the response
      says "Connection: keep-alive". }
    procedure FixKeepAlive(var Head: TResponseHead);
    { Adapts the response head to the client's version and the keep-alive
      decision (see the unit header). }
    procedure EnforceVersion(var Head: TResponseHead);
    procedure WriteBody(const Chunk: TBodyData);
    { Writes the trailer section of a chunked response; does nothing when
      the client did not send "TE: trailers". }
    procedure WriteTrailers(Trailers: THttpHeaders);
    { Writes the last body piece and ends the body in one step. }
    procedure WriteBodyAndEnd(const Chunk: TBodyData);
    { Ends the response body: writes the final "0" CRLF CRLF of a chunked
      body. False (Err set, writing closed) when a Content-Length body got
      fewer bytes than declared: the connection cannot be reused. }
    function EndBody(var Err: THyperError): Boolean;
    { True: an automatic error response was buffered (Err stored for
      TakeError); False: Err must be returned to the caller. }
    function OnParseError(var Err: THyperError): Boolean;
    function PollFlush(out Errno: cint): TIoPoll;                    { TH1Io.PollFlush, then TryKeepAlive }
    function PollShutdown(out Errno: cint): TIoPoll;
    procedure PollDrainOrCloseRead;
    procedure CloseRead;  procedure CloseWrite;
    { closes at once when idle; otherwise closes after the current response }
    procedure DisableKeepAlive;
    { True when an error was stored: Err gets it and the store is cleared }
    function TakeError(var Err: THyperError): Boolean;
    { cold helpers }
    function ErrorHeaders: THttpHeaders;
  public
    LastHeadBytes: SizeInt;          { the encoded size of the last response head (metrics) }
  end;
  PH1Conn = ^TH1Conn;

const
  { the first bytes an HTTP/2 client sends }
  H2_PREFACE: array[0..23] of AnsiChar = 'PRI * HTTP/2.0'#13#10#13#10'SM'#13#10#13#10;
  { the interim response sent for "Expect: 100-continue" }
  CONTINUE_100: array[0..24] of AnsiChar = 'HTTP/1.1 100 Continue'#13#10#13#10;

{ The Proc of the header read timer and of the body timer: wakes the owner
  task, which then checks the timer. }
procedure HeaderReadTimerProc(T: PTimer);

implementation

uses
  bearings.http.date, bearings.rt.proxyproto;

const
  S_CONNECTION: array[0..9] of AnsiChar = 'connection';
  S_CLOSE: array[0..4] of AnsiChar = 'close';
  S_KEEP_ALIVE: array[0..9] of AnsiChar = 'keep-alive';

{ The automatic 100 Continue while entries are queued: behind them. }
procedure ContinueAfterQueue(var Io: TH1Io);
var
  V: TByteVec;
begin
  V := Default(TByteVec);
  V.Append(@CONTINUE_100[0], SizeOf(CONTINUE_100), Io.Pool);
  Io.BufferAfterQueue(V);
end;

{ A file frame (bkFile): Enc is the frame the encoder made for
  Chunk.Len bytes; its framing goes around a qkFile entry for the bytes the
  encoder accepted. The entry owns Chunk (CloseAfter closes the fd after the
  last byte, or when the connection drops the queue). }
procedure BufferFileFrame(var Io: TH1Io; const Enc: TEncodedBuf; const Chunk: TBodyData);
var
  Head, Tail: TEncodedBuf;
  N: SizeInt;
  B: TBodyData;
begin
  Enc.SplitData(Head, N, Tail);
  if Head.Remaining > 0 then
    Io.Buffer(QueuedEncoded(Head, BodyEmpty));
  if N > 0 then
    Io.Buffer(QueuedFile(Chunk.Fd, Chunk.Offset, N, Chunk))
  else
  begin
    B := Chunk;
    ReleaseBody(B);
  end;
  if Tail.Remaining > 0 then
    Io.Buffer(QueuedEncoded(Tail, BodyEmpty));
end;

procedure HeaderReadTimerProc(T: PTimer);
begin
  if T^.Owner <> nil then
    TLoopTask(T^.Owner).Wake;
end;

{ A response version that cannot be written (HTTP/0.9 or HTTP/3) is a bug
  in the application: EH1Panic, raised before ServerEncode. Separate
  routine, so the exception object and its message stay out of EncodeHead
  (no implicit exception frame there). }
procedure RaiseVersionPanic(V: THttpVersion);
begin
  if V = hv09 then
    raise EH1Panic.Create('unexpected response version: HTTP/0.9')
  else
    raise EH1Panic.Create('unexpected response version: HTTP/3.0');
end;

{ ---- TConnState ---- }

procedure TConnState.Close;
begin
  Reading := rdClosed;
  Writing := wrClosed;
  KeepAlive := kaDisabled;
end;

procedure TConnState.CloseRead;
begin
  Reading := rdClosed;
  KeepAlive := kaDisabled;
end;

procedure TConnState.CloseWrite;
begin
  Writing := wrClosed;
  KeepAlive := kaDisabled;
end;

function TConnState.WantsKeepAlive: Boolean;
begin
  Result := KeepAlive <> kaDisabled;
end;

procedure TConnState.TryKeepAlive;
begin
  if (Reading = rdKeepAlive) and (Writing = wrKeepAlive) then
  begin
    if KeepAlive = kaBusy then
      Idle
    else
      { both sides are done but keep-alive is disabled }
      Close;
  end
  else if ((Reading = rdClosed) and (Writing = wrKeepAlive))
    or ((Reading = rdKeepAlive) and (Writing = wrClosed)) then
    Close;
end;

procedure TConnState.DisableKeepAlive;
begin
  KeepAlive := kaDisabled;
end;

procedure TConnState.Busy;
begin
  if KeepAlive = kaDisabled then
    Exit;
  KeepAlive := kaBusy;
end;

procedure TConnState.Idle;
begin
  Assert(not IsIdle, 'TConnState.Idle called while idle');
  Method := hmNone;
  KeepAlive := kaIdle;
  Reading := rdInit;
  Writing := wrInit;
  if HeaderReadTimeoutMs >= 0 then
    { read again now: the next head read starts the header read timer, so
      the connection is closed if no new head arrives in time }
    NotifyRead := True;
end;

function TConnState.IsIdle: Boolean;
begin
  Result := KeepAlive = kaIdle;
end;

function TConnState.IsReadClosed: Boolean;
begin
  Result := Reading = rdClosed;
end;

function TConnState.IsWriteClosed: Boolean;
begin
  Result := Writing = wrClosed;
end;

procedure TConnState.PrepareUpgrade(Ex: TObject);
var
  S: TUpgradeSlot;
begin
  { An older pending upgrade, if any, is cancelled: its receiver sees
    Canceled. }
  if Upgrade.Active and (Upgrade.Slot <> nil) then
  begin
    Upgrade.Slot.Cancel;
    Upgrade.Slot.Release;
  end;
  { the slot is reference counted: this is the connection's reference;
    LinkUpgrade adds the exchange's }
  S := TUpgradeSlot.Create;
  S.State := usPending;
  S.RxAlive := True;
  Upgrade.Slot := S;
  Upgrade.Active := True;
  if Ex <> nil then
    TExchange(Ex).LinkUpgrade(S);
end;

{ ---- TH1Conn ---- }

procedure TH1Conn.Init(AIo: TTransport; APool: PBlockPool; AOwner: TObject);
begin
  Io.Init(AIo, APool);
  State.AllowHalfClose := False;
  State.HasError := False;
  State.Error := Default(THyperError);
  State.KeepAlive := kaBusy;
  State.Method := hmNone;
  State.ParseCtx := DefaultParseContext;
  State.HeaderReadTimeoutMs := -1;
  TimerInit(@State.HeaderReadTimer, @HeaderReadTimerProc, Pointer(AOwner));
  State.HeaderReadTimeoutRunning := False;
  State.DateHeader := True;
  State.TitleCaseHeaders := False;
  State.NotifyRead := False;
  State.Reading := rdInit;
  State.ReadDecoder.InitLength(0);
  State.Writing := wrInit;
  State.WriteEncoder := TEncoder.Length(0);
  State.Upgrade.Active := False;
  State.Upgrade.Slot := nil;
  { assume an HTTP/1.1 client until a request head says otherwise
    (PollReadHead) }
  State.Version := hv11;
  State.AllowTrailerFields := False;
  State.BodyTimeoutMs := 0;
  State.BodyMinRate := 0;
  TimerInit(@State.BodyTimer, @HeaderReadTimerProc, Pointer(AOwner));
  State.BodyWaiting := False;
  State.BodyWaitStartMs := 0;
  State.BodyWaitedMs := 0;
  State.BodyReceived := 0;
  Owner := AOwner;
  if (AOwner <> nil) and (AOwner is TLoopTask) then
    Loop := TLoopTask(AOwner).Loop
  else
    Loop := nil;
  Scratch.TrailerNames := Default(TTrailerFieldSet);
  Scratch.TrailerBytes := Default(TByteVec);
  Scratch.ErrHeaders := nil;
  ErrorHeadPending := False;
end;

procedure TH1Conn.Done;
begin
  { the transport is not closed here: the dispatcher closes it or hands it
    on (upgrade) }
  if Loop <> nil then
  begin
    Loop.Timers.Remove(@State.HeaderReadTimer);
    Loop.Timers.Remove(@State.BodyTimer);
  end;
  State.HeaderReadTimeoutRunning := False;
  State.BodyWaiting := False;
  if State.Upgrade.Active and (State.Upgrade.Slot <> nil) then
  begin
    { the upgrade was expected but not completed: cancel it; the exchange
      may still hold its own reference }
    State.Upgrade.Slot.Cancel;
    State.Upgrade.Slot.Release;
  end;
  State.Upgrade.Active := False;
  State.Upgrade.Slot := nil;
  Io.Done;
  Scratch.TrailerNames.Done;
  if Scratch.TrailerBytes.Block <> nil then
    BlockFree(Scratch.TrailerBytes.Block);
  Scratch.TrailerBytes := Default(TByteVec);
  Scratch.ErrHeaders.Free;
  Scratch.ErrHeaders := nil;
end;

procedure TH1Conn.ReleaseIdleScratch;
begin
  if (Scratch.TrailerNames.Bytes <> nil) or (Scratch.TrailerNames.Names <> nil) then
    Scratch.TrailerNames.Done;
  if Scratch.TrailerBytes.Block <> nil then
  begin
    BlockFree(Scratch.TrailerBytes.Block);
    Scratch.TrailerBytes := Default(TByteVec);
  end;
end;

procedure TH1Conn.SetFlushPipeline(Enabled: Boolean);
begin
  Io.SetFlushPipeline(Enabled);
end;

procedure TH1Conn.SetMaxBufSize(Max: SizeInt);
begin
  Io.SetMaxBufSize(Max);
end;

procedure TH1Conn.SetParserConfig(const C: TParserConfig);
begin
  State.ParseCtx.ParserConfig := C;
end;

procedure TH1Conn.SetTitleCaseHeaders;
begin
  State.TitleCaseHeaders := True;
end;

procedure TH1Conn.SetMaxHeaders(N: Integer);
begin
  State.ParseCtx.MaxHeaders := N;
end;

procedure TH1Conn.SetMaxHeaderSize(N: SizeInt);
begin
  State.ParseCtx.MaxHeaderSize := N;
end;

procedure TH1Conn.SetBodyReadTimeout(TimeoutMs, MinRate: Int64);
begin
  Assert((TimeoutMs <= 0) or (Loop <> nil), 'body read timeout without a loop');
  State.BodyTimeoutMs := TimeoutMs;
  State.BodyMinRate := MinRate;
end;

procedure TH1Conn.SetHeaderReadTimeout(Ms: Int64);
begin
  State.HeaderReadTimeoutMs := Ms;
end;

procedure TH1Conn.SetAllowHalfClose;
begin
  State.AllowHalfClose := True;
end;

procedure TH1Conn.DisableDateHeader;
begin
  State.DateHeader := False;
end;

function TH1Conn.IsReadClosed: Boolean;
begin
  Result := State.Reading = rdClosed;
end;

function TH1Conn.IsWriteClosed: Boolean;
begin
  Result := State.Writing = wrClosed;
end;

function TH1Conn.CanReadHead: Boolean;
begin
  Result := State.Reading = rdInit;
end;

function TH1Conn.CanReadBody: Boolean;
begin
  Result := (State.Reading = rdBody) or (State.Reading = rdContinue);
end;

function TH1Conn.HasInitialReadWriteState: Boolean;
begin
  Result := (State.Reading = rdInit) and (State.Writing = wrInit) and (Io.ReadBuf.Len = 0);
end;

function TH1Conn.HasH2Prefix: Boolean;
begin
  Result := (Io.ReadBuf.Len >= 24) and (CompareByte(Io.ReadBuf.Ptr^, H2_PREFACE[0], 24) = 0);
end;

procedure TH1Conn.SetProxyProtocol;
begin
  State.ProxyPending := True;
end;

function TH1Conn.TakeProxyPeer(out Peer: TSockAddrStorage): Boolean;
begin
  Result := State.ProxyPeerSet;
  if Result then
  begin
    Peer := State.ProxyPeer;
    State.ProxyPeerSet := False;
  end;
end;

{ Reads the PROXY protocol header that opens the connection (the header
  read timer is running). poSome: read and consumed; the request head
  follows in the buffer. poNone: EOF before any byte (a proxy's connect
  check): the connection ends like one closed between requests. poErr:
  not a valid header (h1peProxyProtocol), EOF inside it, or a socket
  error; no response is written, since the sender is not an HTTP client. }
function TH1Conn.PollReadProxy(var Err: THyperError): TPollOpt;
var
  PP: TProxyParse;
  Used, N: SizeInt;
  HasPeer: Boolean;
  Errno: cint;
  IoR: TIoPoll;
begin
  while True do
  begin
    PP := ParseProxyHeader(Io.ReadBuf.Ptr, Io.ReadBuf.Len, Used, HasPeer, State.ProxyPeer);
    if PP = ppOk then
    begin
      Io.ReadBuf.Advance(Used);
      State.ProxyPending := False;
      State.ProxyPeerSet := HasPeer;
      Exit(poSome);
    end;
    if (PP = ppError) or (Io.ReadBuf.Len >= PROXY_MAX) then
    begin
      Err := NewParse(h1peProxyProtocol);
      CloseRead;
      CloseWrite;
      Exit(poErr);
    end;
    IoR := Io.PollReadFromIo(N, Errno);
    if IoR = ipPending then
      Exit(poPending);
    if IoR = ipError then
    begin
      Err := NewIo(Errno);
      CloseRead;
      CloseWrite;
      Exit(poErr);
    end;
    if N = 0 then
    begin
      CloseRead;
      CloseWrite;
      if Io.ReadBuf.Len = 0 then
        Exit(poNone);                { EOF before the header }
      Err := NewIncomplete;          { EOF inside it }
      Exit(poErr);
    end;
  end;
end;

function TH1Conn.PollReadHead(Headers: THttpHeaders; out Msg: TParsedRequestHead;
  out Head: TBytesView; out Wants: TWants; var Err: THyperError): TPollOpt;
var
  R: TPollResult;
  PR: TPollOpt;
begin
  Assert(CanReadHead, 'poll_read_head: cannot read head');
  Wants := [];
  { start the header read timer once per head (it stays armed across the
    Pending returns of one head read) }
  if not State.HeaderReadTimeoutRunning then
    if State.HeaderReadTimeoutMs >= 0 then
    begin
      Assert(Loop <> nil, 'header read timeout without a loop');
      State.HeaderReadTimeoutRunning := True;
      Loop.Timers.Arm(@State.HeaderReadTimer, Loop.NowMs + State.HeaderReadTimeoutMs);
    end;

  if State.ProxyPending then
  begin
    { the PROXY protocol header comes first; the timer above covers it }
    PR := PollReadProxy(Err);
    if PR = poPending then
    begin
      if State.HeaderReadTimeoutRunning and State.HeaderReadTimer.Fired then
      begin
        State.HeaderReadTimeoutRunning := False;
        Err := NewHeaderTimeout;
        Exit(poErr);
      end;
      Exit(poPending);
    end;
    if PR <> poSome then
      Exit(PR);
  end;

  R := Io.Parse(State.ParseCtx, Headers, Msg, Head, Err);
  if R = prErr then
    Exit(OnReadHeadError(Err));
  if R = prPending then
  begin
    if State.HeaderReadTimeoutRunning then
      if State.HeaderReadTimer.Fired then
      begin
        State.HeaderReadTimeoutRunning := False;
        { the client did not send a complete head in time }
        Err := NewHeaderTimeout;
        Exit(poErr);
      end;
    Exit(poPending);
  end;

  { the head is complete: stop the header read timer }
  if (Loop <> nil) and (State.HeaderReadTimeoutRunning or (State.HeaderReadTimer.Deadline <> 0)) then
  begin
    State.HeaderReadTimeoutRunning := False;
    Loop.Timers.Cancel(@State.HeaderReadTimer);
  end;
  { the response encoder needs the request method (HEAD, CONNECT) }
  State.Method := Msg.Method;

  State.Busy;
  if not Msg.KeepAlive then
    { the request asked to close (Connection: close, or HTTP/1.0 without
      keep-alive) }
    State.KeepAlive := kaDisabled;
  State.Version := Msg.Version;

  if Msg.WantsUpgrade then
    Include(Wants, wantUpgrade);

  if Msg.Decode = DECODED_LENGTH_ZERO then
  begin
    { no body: Expect: 100-continue is ignored }
    State.Reading := rdKeepAlive;
  end
  else if Msg.ExpectContinue and (Msg.Version > hv10) then
    { 100-continue exists only in HTTP/1.1 }
  begin
    InitDecoderFor(State.ReadDecoder, Msg.Decode, State.ParseCtx.MaxHeaders,
      State.ParseCtx.MaxHeaderSize);
    State.ReadDecoder.SetTrailerScratch(@Scratch.TrailerBytes);
    State.Reading := rdContinue;
    StartBodyClock;
    Include(Wants, wantExpect);
  end
  else
  begin
    InitDecoderFor(State.ReadDecoder, Msg.Decode, State.ParseCtx.MaxHeaders,
      State.ParseCtx.MaxHeaderSize);
    State.ReadDecoder.SetTrailerScratch(@Scratch.TrailerBytes);
    State.Reading := rdBody;
    StartBodyClock;
  end;

  State.AllowTrailerFields := TeIsTrailers(Headers);
  Result := poSome;
end;

function TH1Conn.OnReadHeadError(var Err: THyperError): TPollOpt;
var
  WasMidParse: Boolean;
begin
  { A failed head read. If some bytes of a head had arrived (after the
    empty lines a client may send between requests), it is a bad request:
    try the automatic error response. Otherwise the client closed the
    connection between requests, which is the normal way to end it. }
  CloseRead;
  Io.ConsumeLeadingLines;
  WasMidParse := Err.IsParse or (Io.ReadBuf.Len <> 0);
  if WasMidParse then
  begin
    if OnParseError(Err) then
      { the error response was buffered and the error stored: Pending lets
        the dispatcher write the response; it then gets the error from
        TakeError }
      Result := poPending
    else
      Result := poErr;
  end
  else
  begin
    { EOF between requests }
    CloseWrite;
    Result := poNone;
  end;
end;

function TH1Conn.DecodeFrame(Trailers: THttpHeaders; out View: TBytesView;
  out DErr: TDecodeError; out Errno: cint): TDecodeFrame;
var
  R: TDecodeResult;
  St: TDecodeStatus;
  AtEof: Boolean;
  N: SizeInt;
  IoR: TIoPoll;
begin
  { The decoder runs on the buffered bytes first; only when it needs more
    and the buffer is empty is the socket read. A 0-byte read is EOF for the
    decoder. Framing bytes (chunk-size lines, CRLFs) are consumed with
    Advance; data is split off as a pinned view, so it can be handed to the
    application without a copy. }
  View.P := nil;
  View.Len := 0;
  View.Block := nil;
  DErr := deNone;
  Errno := 0;
  AtEof := False;
  while True do
  begin
    St := State.ReadDecoder.Decode(Io.ReadBuf.Ptr, Io.ReadBuf.Len, AtEof, Trailers, R);
    case St of
      dsData:
        begin
          if R.DataOfs > 0 then
            Io.ReadBuf.Advance(R.DataOfs);
          View := Io.ReadBuf.SplitTo(R.DataLen);
          if R.Consumed > R.DataOfs + R.DataLen then
            Io.ReadBuf.Advance(R.Consumed - R.DataOfs - R.DataLen);
          Exit(dfData);
        end;
      dsEnd:
        begin
          if R.Consumed > 0 then
            Io.ReadBuf.Advance(R.Consumed);
          Exit(dfData);                         { an empty data frame: the body ended }
        end;
      dsTrailers:
        begin
          if R.Consumed > 0 then
            Io.ReadBuf.Advance(R.Consumed);
          Exit(dfTrailers);
        end;
      dsError:
        begin
          if (R.Consumed > 0) and (R.Consumed <= Io.ReadBuf.Len) then
            Io.ReadBuf.Advance(R.Consumed);
          DErr := R.Error;
          Exit(dfDecodeError);
        end;
    else
      { dsNeedMore: every buffered byte was consumed }
      if R.Consumed > 0 then
        Io.ReadBuf.Advance(R.Consumed);
      Assert(Io.ReadBuf.Len = 0, 'DecodeFrame: NeedMore with bytes left');
      if AtEof then
      begin
        { the decoder turns AtEof into an error; this is a safety net }
        DErr := deIncompleteBody;
        Exit(dfDecodeError);
      end;
      IoR := Io.PollReadFromIo(N, Errno);
      if IoR = ipPending then
        Exit(dfPending);
      if IoR = ipError then
        Exit(dfIoError);
      if N = 0 then
        AtEof := True;
    end;
  end;
end;

function TH1Conn.PollReadBody(Trailers: THttpHeaders; out Frame: TInFrame;
  var Err: THyperError): TPollOpt;
var
  D: TDecodeFrame;
  V: TBytesView;
  DE: TDecodeError;
  Errno: cint;
  Ret: TPollOpt;
begin
  Assert(CanReadBody, 'poll_read_body: cannot read body');
  Frame.Kind := ifData;
  Frame.Data.P := nil;
  Frame.Data.Len := 0;
  Frame.Data.Block := nil;
  case State.Reading of
    rdBody:
      begin
        D := DecodeFrame(Trailers, V, DE, Errno);
        if (State.BodyTimeoutMs > 0) and (D <> dfPending) then
          BodyProgress(V.Len);           { the body rate rule }
        case D of
          dfPending:
            begin
              if (State.BodyTimeoutMs = 0) or not BodyWaitExpired then
                Exit(poPending);
              { the body rate rule is broken: the read fails }
              State.Reading := rdClosed;
              Err := NewBodyIo(ESysETIMEDOUT);
              Ret := poErr;
            end;
          dfData:
            if State.ReadDecoder.IsEof then
            begin
              { the body ended }
              State.Reading := rdKeepAlive;
              if V.Len <> 0 then
              begin
                Frame.Data := V;
                Ret := poSome;
              end
              else
                Ret := poNone;
            end
            else if V.Len = 0 then
            begin
              { an empty frame before the end (unreachable: every decoder
                reaches its end or fails on an empty read) }
              State.Reading := rdClosed;
              Ret := poNone;
            end
            else
            begin
              Frame.Data := V;
              Exit(poSome);
            end;
          dfTrailers:
            begin
              { the body ended with trailers }
              State.Reading := rdKeepAlive;
              Frame.Kind := ifTrailers;
              Ret := poSome;
            end;
          dfDecodeError:
            begin
              { malformed body framing }
              State.Reading := rdClosed;
              Err := NewBodyDecode(DE);
              Ret := poErr;
            end;
        else
          begin
            { dfIoError: the socket read failed }
            State.Reading := rdClosed;
            Err := NewBodyIo(Errno);
            Ret := poErr;
          end;
        end;
      end;
    rdContinue:
      begin
        { The application asks for the body: send 100 Continue, unless a
          response head was already written }
        if State.Writing = wrInit then
          if Io.CanHeadersBuf then
            Io.HeadersBuf^.Append(@CONTINUE_100[0], SizeOf(CONTINUE_100), Io.Pool)
          else
            { behind the queued entries (the cursor is written first) }
            ContinueAfterQueue(Io);
        { then read the body (one recursion, in rdBody) }
        State.Reading := rdBody;
        Exit(PollReadBody(Trailers, Frame, Err));
      end;
  else
    begin
      Assert(False, 'poll_read_body invalid state');
      Exit(poNone);
    end;
  end;
  if Ret = poErr then
  begin
    { the body failed (rate rule, framing, socket): the receiver gets Err,
      and the connection keeps it too (TakeError after the response and
      the shutdown), so the outcome is io. hyper gives a body error to the
      receiver only and ends the connection with Ok (docs/design.md
      section 10) }
    State.Error := Err;
    State.HasError := True;
  end;
  { the body may have ended: start the next request if the response is
    done too }
  TryKeepAlive;
  Result := Ret;
end;

procedure TH1Conn.StartBodyClock;
begin
  State.BodyWaiting := False;
  State.BodyWaitedMs := 0;
  State.BodyReceived := 0;
end;

function TH1Conn.BodyWaitExpired: Boolean;
var
  NowMs, Deadline, Need: Int64;
begin
  Assert(Loop <> nil, 'body read timeout without a loop');
  NowMs := Loop.NowMs;
  if not State.BodyWaiting then
  begin
    State.BodyWaiting := True;
    State.BodyWaitStartMs := NowMs;
  end;
  { one wait of BodyTimeoutMs }
  Deadline := State.BodyWaitStartMs + State.BodyTimeoutMs;
  if (State.BodyMinRate > 0) and (State.BodyReceived > 0) then
  begin
    { all waits since the first byte together T: T >= BodyTimeoutMs and
      T >= the time the bytes received allow at BodyMinRate }
    Need := State.BodyReceived * 1000 div State.BodyMinRate;
    if Need < State.BodyTimeoutMs then
      Need := State.BodyTimeoutMs;
    Need := State.BodyWaitStartMs + Need - State.BodyWaitedMs;
    if Need < Deadline then
      Deadline := Need;
  end;
  if NowMs >= Deadline then
  begin
    State.BodyWaiting := False;
    Loop.Timers.Cancel(@State.BodyTimer);
    Exit(True);
  end;
  Loop.Timers.Arm(@State.BodyTimer, Deadline);
  Result := False;
end;

procedure TH1Conn.BodyProgress(Len: SizeInt);
begin
  if State.BodyWaiting then
  begin
    State.BodyWaiting := False;
    if State.BodyReceived > 0 then       { the rate's clock starts at the first byte }
      Inc(State.BodyWaitedMs, Loop.NowMs - State.BodyWaitStartMs);
    Loop.Timers.Cancel(@State.BodyTimer);
  end;
  Inc(State.BodyReceived, Len);
end;

function TH1Conn.WantsReadAgain: Boolean;
begin
  Result := State.NotifyRead;
  State.NotifyRead := False;
end;

function TH1Conn.PollReadKeepAlive(var Err: THyperError): TPollResult;
begin
  Assert(not CanReadHead and not CanReadBody, 'poll_read_keep_alive: can read');
  if IsReadClosed then
    Result := prPending
  else if IsMidMessage then
    Result := MidMessageDetectEof(Err)
  else
    Result := prPending;
end;

function TH1Conn.IsMidMessage: Boolean;
begin
  Result := not ((State.Reading = rdInit) and (State.Writing = wrInit));
end;

function TH1Conn.MidMessageDetectEof(var Err: THyperError): TPollResult;
var
  N: SizeInt;
  Errno: cint;
  R: TIoPoll;
begin
  { a request is in progress and nothing is to be read: read anyway to
    see whether the client closed the connection. Bytes in the buffer
    (a pipelined request) mean it has not. }
  if State.AllowHalfClose or (Io.ReadBuf.Len <> 0) then
    Exit(prPending);
  R := ForceIoRead(N, Errno);
  if R = ipPending then
    Exit(prPending);
  if R = ipError then
  begin
    Err := NewIo(Errno);
    Exit(prErr);
  end;
  if N = 0 then
  begin
    { EOF while a request is in progress }
    State.CloseRead;
    Err := NewIncomplete;
    Result := prErr;
  end
  else
    Result := prOk;
end;

function TH1Conn.ForceIoRead(out N: SizeInt; out Errno: cint): TIoPoll;
begin
  Assert(not State.IsReadClosed, 'force_io_read: read closed');
  Result := Io.PollReadFromIo(N, Errno);
  if Result = ipError then
    State.Close;
end;

procedure TH1Conn.MaybeNotify;
var
  N: SizeInt;
  Errno: cint;
  R: TIoPoll;
begin
  { The connection may have stopped reading before the socket returned
    EAGAIN (it waits for the response before reading the next head). The
    socket is edge-triggered (see bearings.rt.loop), so no new readiness event
    comes for bytes that are already there: read now and set NotifyRead. }
  if State.Reading <> rdInit then
    Exit;
  if State.Writing = wrBody then
    Exit;
  if not Io.IsReadBlocked then
  begin
    if Io.ReadBuf.Len = 0 then
    begin
      R := Io.PollReadFromIo(N, Errno);
      if R = ipReady then
      begin
        if N = 0 then
        begin
          { EOF }
          if State.IsIdle then
            State.Close
          else
            CloseRead;
          Exit;
        end;
      end
      else if R = ipPending then
        { nothing to read: the next readiness event wakes the task }
        Exit
      else
      begin
        { read error: stored for TakeError }
        State.Close;
        State.Error := NewIo(Errno);
        State.HasError := True;
      end;
    end;
    State.NotifyRead := True;
  end;
end;

procedure TH1Conn.TryKeepAlive;
begin
  State.TryKeepAlive;
  MaybeNotify;
end;

function TH1Conn.CanWriteHead: Boolean;
begin
  Result := (State.Writing = wrInit) and Io.CanHeadersBuf;
end;

function TH1Conn.CanWriteBody: Boolean;
begin
  Result := State.Writing = wrBody;
end;

function TH1Conn.CanBufferBody: Boolean;
begin
  Result := Io.CanBuffer;
end;

function TH1Conn.HasBufferedWrite: Boolean;
begin
  Result := Io.HasBufferedWrite;
end;

procedure TH1Conn.WriteHead(var Head: TResponseHead; const Body: TBodyLength);
var
  Enc: TEncoder;
begin
  if EncodeHead(Head, Body, Enc) then
  begin
    if not Enc.IsEof then
    begin
      State.WriteEncoder := Enc;
      State.Writing := wrBody;
    end
    else if Enc.IsLast then
      State.Writing := wrClosed
    else
      State.Writing := wrKeepAlive;
  end;
end;

function TH1Conn.EncodeHead(var Head: TResponseHead; const Body: TBodyLength;
  out Enc: TEncoder): Boolean;
var
  P: TServerEncodeParams;
  Ctx: TEncodeContext;
  R: TServerEncodeResult;
  V: TByteVec;
begin
  { OnParseError may write while entries are queued (ErrorHeadPending) }
  Assert(CanWriteHead or ((State.Writing = wrInit) and ErrorHeadPending),
    'encode_head: cannot write head');
  EnforceVersion(Head);
  { checked here, so ServerEncode never meets such a version }
  if ResponseVersionPanics(Head.Status, Head.Version) then
    RaiseVersionPanic(Head.Version);

  P.Body := Body.Kind;
  P.BodyLen := Body.Len;
  P.KeepAlive := State.WantsKeepAlive;
  P.ReqMethod := State.Method;
  P.TitleCaseHeaders := State.TitleCaseHeaders;
  P.DateHeader := State.DateHeader;
  P.Date := nil;
  if Loop <> nil then
    Ctx.Date := LoopDate(Loop)
  else
    Ctx.Date := nil;
  Ctx.Trailers := @Scratch.TrailerNames;
  if Io.CanHeadersBuf then
  begin
    LastHeadBytes := Io.HeadersBuf^.Len;
    R := ServerEncode(Head, P, Ctx, Io.HeadersBuf^, Io.Pool, Enc);
    LastHeadBytes := Io.HeadersBuf^.Len - LastHeadBytes;
  end
  else
  begin
    { entries are queued: the head goes behind them (the cursor is written
      before the queue, so it would land inside the queued response) }
    V := Default(TByteVec);
    R := ServerEncode(Head, P, Ctx, V, Io.Pool, Enc);
    LastHeadBytes := V.Len;
    if R = serOk then
      Io.BufferAfterQueue(V)
    else if V.Block <> nil then
      BlockFree(V.Block);
  end;
  if R = serOk then
    Exit(True);
  { encoding failed: store the error and stop writing }
  if R = serUserHeader then
    State.Error := NewUserHeader
  else
    State.Error := NewUserUnsupportedStatusCode;
  State.HasError := True;
  State.Writing := wrClosed;
  Result := False;
end;

procedure TH1Conn.FixKeepAlive(var Head: TResponseHead);
var
  H: THttpHeaders;
  I: SizeInt;
  OutgoingIsKeepAlive: Boolean;
begin
  { Looks for "Connection: keep-alive" in the response head. }
  H := Head.Headers;
  OutgoingIsKeepAlive := False;
  if H <> nil then
  begin
    I := H.IndexOf(@S_CONNECTION[0], SizeOf(S_CONNECTION));
    while I >= 0 do
    begin
      if ConnectionKeepAlive(H.ValuePtr(I), H.ValueLen(I)) then
      begin
        OutgoingIsKeepAlive := True;
        Break;
      end;
      I := H.IndexOf(@S_CONNECTION[0], SizeOf(S_CONNECTION), I + 1);
    end;
  end;
  if not OutgoingIsKeepAlive then
    case Head.Version of
      hv10:
        { a 1.0 response without keep-alive: the connection closes after it }
        State.DisableKeepAlive;
      hv11:
        { a 1.1 response going to a 1.0 client that wants keep-alive (the
          version is set to 1.0 afterwards by EnforceVersion): add
          "Connection: keep-alive", which a 1.0 client needs to keep the
          connection open }
        if State.WantsKeepAlive then
        begin
          if H = nil then
          begin
            H := ErrorHeaders;
            H.Clear;
            Head.Headers := H;
          end;
          H.AddTrusted(@S_CONNECTION[0], SizeOf(S_CONNECTION), @S_KEEP_ALIVE[0], SizeOf(S_KEEP_ALIVE));
        end;
    else
    end;
end;

procedure TH1Conn.EnforceVersion(var Head: TResponseHead);
var
  H: THttpHeaders;
  I: SizeInt;
  AnyClose: Boolean;
begin
  { Called for every response head. }
  case State.Version of
    hv10:
      begin
        { an HTTP/1.0 client: keep-alive only with an explicit header }
        FixKeepAlive(Head);
        { answer a 1.0 client with a 1.0 response }
        Head.Version := hv10;
      end;
    hv11:
      if State.KeepAlive = kaDisabled then
        { the connection closes after this response: tell the client with
          "connection: close" unless the head already says so }
      begin
        H := Head.Headers;
        AnyClose := False;
        if H <> nil then
        begin
          I := H.IndexOf(@S_CONNECTION[0], SizeOf(S_CONNECTION));
          while I >= 0 do
          begin
            if ConnectionClose(H.ValuePtr(I), H.ValueLen(I)) then
            begin
              AnyClose := True;
              Break;
            end;
            I := H.IndexOf(@S_CONNECTION[0], SizeOf(S_CONNECTION), I + 1);
          end;
        end
        else
        begin
          H := ErrorHeaders;
          H.Clear;
          Head.Headers := H;
        end;
        if not AnyClose then
          H.AddTrusted(@S_CONNECTION[0], SizeOf(S_CONNECTION), @S_CLOSE[0], SizeOf(S_CLOSE));
      end;
  else
  end;
  { otherwise the application's headers are left as they are }
end;

procedure TH1Conn.WriteBody(const Chunk: TBodyData);
var
  Enc: TEncodedBuf;
begin
  Assert(CanWriteBody and CanBufferBody, 'write_body: cannot write body');
  { the dispatcher drops empty chunks (an empty chunk would end a chunked body) }
  Assert(Chunk.Len <> 0, 'write_body: empty chunk');
  if State.Writing <> wrBody then
  begin
    Assert(False, 'write_body invalid state');
    Exit;
  end;
  State.WriteEncoder.Encode(Chunk.P, Chunk.Len, Enc);
  if Chunk.Kind = bkFile then
    BufferFileFrame(Io, Enc, Chunk)
  else
    Io.Buffer(QueuedEncoded(Enc, Chunk));
  if not State.WriteEncoder.IsEof then
    Exit;
  if State.WriteEncoder.IsLast then
    State.Writing := wrClosed
  else
    State.Writing := wrKeepAlive;
end;

procedure TH1Conn.WriteTrailers(Trailers: THttpHeaders);
var
  V: TByteVec;
begin
  if not State.AllowTrailerFields then
    { the client did not send "TE: trailers": the trailers are dropped }
    Exit;
  Assert(CanWriteBody and CanBufferBody, 'write_trailers: cannot write body');
  if State.Writing <> wrBody then
  begin
    Assert(False, 'write_trailers invalid state');
    Exit;
  end;
  V := Default(TByteVec);
  if State.WriteEncoder.EncodeTrailers(Trailers, State.TitleCaseHeaders, V, Io.Pool) then
  begin
    Io.Buffer(QueuedTrailers(V));
    if State.WriteEncoder.IsLast or State.WriteEncoder.IsCloseDelimited then
      State.Writing := wrClosed
    else
      State.Writing := wrKeepAlive;
  end;
  { EncodeTrailers False (not chunked, no Trailer header, or no field
    kept): nothing written, the state stays wrBody and EndBody ends the body }
end;

procedure TH1Conn.WriteBodyAndEnd(const Chunk: TBodyData);
var
  Enc: TEncodedBuf;
  CanKeepAlive: Boolean;
begin
  Assert(CanWriteBody and CanBufferBody, 'write_body_and_end: cannot write body');
  { the dispatcher drops empty chunks }
  Assert(Chunk.Len <> 0, 'write_body_and_end: empty chunk');
  if State.Writing <> wrBody then
  begin
    Assert(False, 'write_body invalid state');
    Exit;
  end;
  { the frame for the chunk plus the end of the body; False when the
    connection must close after this response (for example the response
    is the last one, or a Content-Length body got fewer bytes than
    declared) }
  CanKeepAlive := State.WriteEncoder.EncodeAndEnd(Chunk.P, Chunk.Len, Enc);
  if Chunk.Kind = bkFile then
    BufferFileFrame(Io, Enc, Chunk)
  else
    Io.Buffer(QueuedEncoded(Enc, Chunk));
  if CanKeepAlive then
    State.Writing := wrKeepAlive
  else
    State.Writing := wrClosed;
end;

function TH1Conn.EndBody(var Err: THyperError): Boolean;
var
  Buf: TEncodedBuf;
  NotEof: QWord;
begin
  Assert(CanWriteBody, 'end_body: cannot write body');
  if State.Writing <> wrBody then
    Exit(True);
  { eeBuf: the closing bytes (the last chunk of a chunked body); eeNone:
    nothing to write; otherwise a Content-Length body is short }
  case State.WriteEncoder.Finish(Buf, NotEof) of
    eeNone: ;
    eeBuf: Io.Buffer(QueuedEncoded(Buf, BodyEmpty));
  else
    begin
      { NotEof bytes of the declared length were never written }
      State.Writing := wrClosed;
      Err := NewBodyWriteAborted(NotEof);
      Exit(False);
    end;
  end;
  if State.WriteEncoder.IsLast or State.WriteEncoder.IsCloseDelimited then
    State.Writing := wrClosed
  else
    State.Writing := wrKeepAlive;
  Result := True;
end;

function TH1Conn.ErrorHeaders: THttpHeaders;
begin
  if Scratch.ErrHeaders = nil then
    Scratch.ErrHeaders := THttpHeaders.Create(4, 64);
  Result := Scratch.ErrHeaders;
end;

function TH1Conn.OnParseError(var Err: THyperError): Boolean;
var
  Status: Word;
  Head: TResponseHead;
  BL: TBodyLength;
begin
  { A bad request head: if no response was started, write the matching
    4xx response before the connection closes. }
  if State.Writing = wrInit then
  begin
    if HasH2Prefix then
    begin
      Err := NewVersionH2;
      Exit(False);
    end;
    { only parse errors have an automatic response (400, 414 or 431) }
    if Err.Kind = hekParse then
      Status := ServerErrorStatus(Err.Parse)
    else
      Status := 0;
    if Status <> 0 then
    begin
      { an empty response with this status }
      Head := DefaultResponseHead;
      Head.Status := Status;
      Head.Headers := ErrorHeaders;
      Head.Headers.Clear;
      BL.Kind := blkNone;
      BL.Len := 0;
      ErrorHeadPending := True;
      WriteHead(Head, BL);
      ErrorHeadPending := False;
      State.Error := Err;
      State.HasError := True;
      Exit(True);
    end;
  end;
  { no response possible: the caller returns the error }
  Result := False;
end;

function TH1Conn.PollFlush(out Errno: cint): TIoPoll;
begin
  Result := Io.PollFlush(Errno);
  if Result <> ipReady then
    Exit;
  TryKeepAlive;
  Result := ipReady;
end;

function TH1Conn.PollShutdown(out Errno: cint): TIoPoll;
begin
  Result := Io.PollShutdown(Errno);
end;

procedure TH1Conn.PollDrainOrCloseRead;
var
  Frame: TInFrame;
  Err: THyperError;
begin
  { The application is done but did not read the whole request body. Read
    once and discard what arrives; if the body did not end, close the read
    side (the connection is not reused). }
  if State.Reading = rdContinue then
    { do not send 100 Continue: read whatever the client already sent, in
      case the body is small }
    State.Reading := rdBody;
  Err := Default(THyperError);
  { the frame is discarded; an error (malformed framing, a socket error)
    stays with the connection for TakeError }
  PollReadBody(nil, Frame, Err);
  if Frame.Data.Block <> nil then
    Frame.Data.Release;
  { the body did not end within this read: give up }
  if (State.Reading <> rdInit) and (State.Reading <> rdKeepAlive) then
    CloseRead;
end;

procedure TH1Conn.CloseRead;
begin
  State.CloseRead;
end;

procedure TH1Conn.CloseWrite;
begin
  State.CloseWrite;
end;

procedure TH1Conn.DisableKeepAlive;
begin
  if State.IsIdle then
    { idle connection: close now }
    State.Close
  else
    { a request is in progress: close after its response }
    State.DisableKeepAlive;
end;

function TH1Conn.TakeError(var Err: THyperError): Boolean;
begin
  if not State.HasError then
    Exit(False);
  Err := State.Error;
  State.HasError := False;
  State.Error := Default(THyperError);
  Result := True;
end;

end.

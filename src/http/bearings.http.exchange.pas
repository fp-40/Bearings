{ bearings.http.exchange - one HTTP request and its response, as the application
  sees them: the request head, the request body channel, the response,
  streaming response bodies, connection upgrades, and handing a request to
  a worker thread.

  An HTTP/1.1 request is a head (the request line and the header fields)
  followed by an optional body; a response is likewise a head (the status
  line and the header fields) and an optional body. The connection task
  (TH1Dispatcher, bearings.http1.dispatch) parses a request head, takes a
  TExchange from its loop's pool, fills in the head (FillHead) and asks the
  application's THttpService for a TServiceCall. It then polls that call
  each time the connection runs, until the application has answered with
  exactly one terminal call: Respond, RespondStream, BeginStream or Fail.
  The dispatcher writes the response and, on a keep-alive connection (one
  that stays open for further requests), starts the next request on the
  same exchange object.

  Main types:
    THttpService     the application. One instance per loop, made by a
                     TServiceFactory, so it may keep per-loop state without
                     locks. Call creates the TServiceCall of one request.
    TServiceCall     the handling of one request as the dispatcher sees it:
                     Poll until cpReady, then Drop.
    TExchange        the request (Head, the body channel Chan) and the
                     response (Resp). Pooled per loop (TExchangePool).
    TBodyChan        the request body channel (see below).
    TBodySource      a response body produced piece by piece. TChannelBody
                     is the bounded queue behind BeginStream and Write.
    TUpgradeSlot, TUpgradeHandler   connection upgrades (see below).
    TBlockingHandler, TOffloadCall  running a handler on a worker thread.
    TConnObserver, TConnParts       hooks for tests and the conformance
                     server.

  Request body. A body has either a Content-Length (that many bytes follow
  the head) or "Transfer-Encoding: chunked" (a series of chunks, each
  preceded by its size, ended by a chunk of size 0 that may carry
  trailers: header fields sent after the body). The dispatcher decodes the
  body and passes it to the handler through TBodyChan, a channel that holds
  at most one chunk. The dispatcher reads the next chunk from the socket
  only after the handler took the previous one and asked for more, so a
  slow handler slows the client down (backpressure) instead of making the
  server buffer the whole body. A chunk is a view into the connection's
  read buffer (TBytesView, bearings.rt.buf), not a copy; it stays valid until the
  next body call.

  100-continue. A client that sent "Expect: 100-continue" waits for an
  interim "100 Continue" response before it sends the body. For such a
  request the channel starts without a request for data (Open(True)), so
  the server sends "100 Continue" only when the handler first reads the
  body; a handler that answers without reading spares the client the
  upload.

  Response body. Respond takes a body of known length (memory or a file
  range, TBodyData), sent with a Content-Length. RespondStream takes a
  TBodySource that the dispatcher polls for frames while the socket can
  take more; a body of unknown length is sent with the chunked encoding,
  which also allows trailers at the end. BeginStream is RespondStream with
  the exchange's own TChannelBody: the application then pushes frames with
  Write, TryWrite or WriteString and ends the body with Finish (optionally
  with trailers) or AbortStream. The queue holds about HighWater bytes; a
  writer on a worker thread waits while it is full, so a slow client slows
  the producer down (backpressure). AbortStream ends the body with an
  error: the chunked encoding is left without its last chunk, so the
  client sees an incomplete body.

  Unshared and shared exchanges. An exchange starts unshared: it belongs
  to its connection's loop thread, and every method runs on that thread
  without locks (builds with assertions check this). Code that must use
  the exchange from another thread first calls Share on the loop thread.
  Offload does that and queues the exchange on a TWorkerPool, where a
  worker runs a TBlockingHandler (TExchange is itself the TWorkItem). Once
  shared, the body channel works under its lock, the state changes by
  compare-and-swap, a Wake from another thread is a message posted to the
  loop's inbox (see bearings.rt.loop), and a worker's blocking body read parks
  the worker until the loop changes the channel. Views into the read
  buffer are pinned and unpinned only on the loop thread (the pin counts
  are plain integers), so a worker hands the views it is done with back to
  the loop (TBodyChan.ToRelease).

  Two counters keep a shared exchange alive:
    FRefCount  the transport's reference plus one per Share. Release
               decrements it; at 0 the exchange is recycled into its pool,
               on its loop thread.
    FHolders   the call in flight plus one per Share. At 0 the request is
               released (head unpinned, body receiver closed) and a
               response stream still open is finished.
  The connection does not reuse a shared exchange for its next request: it
  lets it go (ReleaseTransport) and takes another one from the pool.

  States (TExchangeState): xsIdle in the pool; xsCalled the call is in
  flight and has not answered; xsAnswered a terminal call was made; xsDone
  the call completed (CompleteCall); xsCanceled the connection gave up the
  call before it answered.

  Cancellation. When the client disconnects, the connection fails or the
  server's shutdown deadline passes while a call is in flight, the
  dispatcher calls Cancel and then TServiceCall.Drop(Ex, False). A canceled
  exchange refuses terminal calls (they return False); TryRead returns
  brCanceled and the blocking reads raise EClientGone; stream writes return
  wrCanceled. A worker parked in a body read or in a write to a full queue
  is woken. A long-running handler can check IsCanceled.

  Upgrades. A client may ask to switch the connection to another protocol
  (the Upgrade header, for example for WebSocket). The handler calls
  OnUpgrade with a TUpgradeHandler and answers "101 Switching Protocols".
  When the HTTP part of the connection has ended, the socket and the bytes
  already read after the request are handed to the handler on the loop
  thread (TUpgradeHandler.Upgraded, a TUpgraded from bearings.rt.stream). If the
  upgrade does not happen, UpgradeFailed is called instead.

  Debug checks. Builds with assertions (-Sa; every test build) check the
  threading rules: an unshared exchange is used only on its loop thread;
  the response head is written only by the thread that makes the terminal
  call; THttpService.Call neither answers nor reads the body; a recycled
  exchange is never woken. They also overwrite a released request head
  with $DD bytes, so code that reads it after the release sees that
  pattern instead of the next request's bytes. Release builds contain none
  of these checks.

  TConnParts and TConnObserver are declared here and not in bearings.server: the
  dispatcher uses them and bearings.server uses the dispatcher, so declaring them
  in bearings.server would make the unit references circular. bearings.server
  re-exports both names. They do not depend on HTTP/1. }
unit bearings.http.exchange;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

uses
  SysUtils, ctypes, bearings.rt.sys, bearings.rt.sync, bearings.rt.loop, bearings.rt.timer, bearings.rt.buf, bearings.rt.net,
  bearings.rt.stream, bearings.rt.workers, bearings.http.error, bearings.http.headers, bearings.http.uri, bearings.http1.parser,
  bearings.http1.role, bearings.http1.decode;

type
  TExchange = class;              { forward declarations: all in this unit }
  TExchangePool = class;
  TChannelBody = class;
  TBodySource = class;
  TUpgradeHandler = class;
  TUpgradeSlot = class;
  TBlockingHandler = class;
  TCallPoll = (cpPending, cpReady);

  { Per-request state a service keeps with the exchange (for example the request body buffered
    on the loop). The transport calls Detach on the loop thread when the exchange is recycled
    (after the last reference went, so a worker that read the state is done with it) or begins
    its next request; Attachment is already nil when Detach runs. }
  TExchangeAttachment = class
  public
    procedure Detach(Ex: TExchange); virtual; abstract;
  end;

  { The handling of one request, as the dispatcher sees it. }
  TServiceCall = class
  public
    { Called by the dispatcher on the loop thread every time the connection runs while the call is
      in flight; this is where the handler's code runs. cpReady only after a terminal call on Ex
      (Respond, RespondStream, BeginStream, Fail). cpPending: something must call Ex.Wake later. }
    function Poll(Ex: TExchange): TCallPoll; virtual; abstract;
    { Called exactly once at the end: Completed = True right after Poll returned cpReady; False
      when the connection abandons the call (the client closed the connection, a connection error,
      the shutdown deadline), including a call that was never polled. A pooled call returns itself
      to its pool here. }
    procedure Drop(Ex: TExchange; Completed: Boolean); virtual;
  end;

  { The application. One instance per loop (TServiceFactory), so it may keep per-loop pools
    without locks. }
  THttpService = class
  public
    { Called on the loop thread right after the request head was parsed. Creates the call; must
      not answer or read the body (builds with assertions check this). May write a log line (the
      conformance server reports the request here). }
    function Call(Ex: TExchange): TServiceCall; virtual; abstract;
  end;
  TServiceFactory = function(Loop: TLoop): THttpService of object;

  TByteSlice = record P: PByte; Len: SizeInt; end;

  { The request head. Written by the dispatcher before Call; read-only afterwards. Valid until
    ReleaseRequest, which runs at the latest at call completion (unshared exchange) or at the
    Release of the last holder (shared exchange). The method, target and header bytes are not
    copied: they point into the connection's read buffer, whose block View pins. }
  TRequestHead = record
    View: TBytesView;                 { pinned head bytes in the read buffer }
    Method: THttpMethod;
    MethodSlice, Target: TSlice;      { offsets relative to View.P }
    Uri: TUriParts;
    Version: THttpVersion;
    Headers: THttpHeaders;            { entries point into View (ExternalBase = View.P); list reused }
    ContentLength: Int64;             { 0 no body; -1 chunked or until the connection closes }
    ExpectContinue, WantsUpgrade: Boolean;
    Peer, Local: TSockAddrStorage;
    ConnId: QWord;
    RequestNo: LongWord;              { 1, 2, ... per connection }
    Released: Boolean;                { ReleaseRequest ran }
  end;

  { The request body channel: one slot between the dispatcher (the sender, on the loop thread)
    and the handler (the receiver). The sender may put a data chunk in the slot only when it is
    empty and the receiver asked for data (Want); the receiver takes it with PollNext. After the
    last chunk the sender may announce trailers (they are stored in Ex.ReqTrailers) and closes
    its side (CloseSender), which the receiver sees as the end of the body. A receiver that
    closes early (the handler does not want the body) makes the dispatcher stop delivering it:
    the rest is read and discarded, or the connection is closed. A sender that fails puts an
    error in the channel (SendError) and the receiver gets brError.

    Wakes: a side that has to wait registers (SenderWaker, ReceiverWaker), and the other side
    wakes it once, only when it registered. On the loop both sides belong to the connection
    task, so a wake is Ex.Wake. A worker that waits in a blocking read registers ReceiverParks
    instead and is woken through Parker.

    Unshared exchange: loop thread only, no lock. Shared exchange: every call holds Lock; the
    wakes found under the lock are collected (DeferWake, DeferUnpark) and run after it is
    released (TakeDeferred, RunDeferred). }
  TChanItemKind = (ciNone, ciData, ciError);
  TChanPoll = (cnData, cnError, cnEnd, cnPending);   { PollNext result }
  TBodyChan = record
    Lock: TSpinLock;                 { taken only when the exchange is shared }
    ItemKind: TChanItemKind;         { what the slot holds }
    Item: TBytesView;                { the chunk in the slot: a pinned read-buffer view }
    { ItemErr: the error in the slot; PendingErr: an error sent while the slot held data,
      delivered after it }
    ItemErr, PendingErr: THyperError;
    HasPendingErr: Boolean;
    HasTrailers, TrailersSent: Boolean;   { trailers are in Ex.ReqTrailers (exchange-owned list) }
    { Want: the receiver asked for data; Terminated: the receiver has seen the end }
    SenderOpen, ReceiverOpen, Want, Terminated: Boolean;
    Held: TBytesView;                { the view the receiver is using (TryRead/ReadChunk result) }
    ToRelease: TBytesView;           { shared mode: a view a worker dropped; the loop unpins it }
    ToRelease2: TBytesView;          { a second one (at most two views are handed back between
                                       two loop-side releases) }
    Parker: TParker;                 { a worker waiting in Read / ReadChunk }
    Ex: TExchange;                   { the exchange; Ex.Wake runs its connection task }
    SenderWaker, ReceiverWaker: Boolean;   { that side waits for a wake }
    Active: Boolean;                 { False: the request has no body }
    { shared mode: the receiver is a worker that parks on Parker (PollNext then registers
      ReceiverParks instead of ReceiverWaker) }
    ParkingReceiver, ReceiverParks: Boolean;
    DeferWake, DeferUnpark: Boolean;  { wakes found under Lock, run after its release }
    { sender side: the dispatcher, loop thread }
    { Wanter: the request expects 100-continue, so Want starts False }
    procedure Open(Wanter: Boolean);
    { True: the sender may send now (the receiver wants data, the slot is empty, no error is
      pending). Closed: the receiver is gone. Releases ToRelease first. }
    function PollReady(out Closed: Boolean): Boolean;
    function TrySendData(const V: TBytesView): Boolean; { False: not sent, V stays with the caller }
    function TrySendTrailers: Boolean;
    procedure SendError(const E: THyperError);
    procedure CloseSender;                         { no more data: the receiver sees the end }
    { receiver side: the exchange, for the handler }
    function PollNext(out V: TBytesView; out E: THyperError): TChanPoll;
    function TakeTrailers: Boolean;                { True once, when trailers were sent }
    { the handler does not want the rest of the body: releases Held (and Item, once the sender is
      closed too) and unparks a reader parked in a body read (shared exchange: another holder
      released the request) }
    procedure CloseReceiver;
    procedure WakeSender; inline;
    procedure WakeReceiver; inline;
    procedure ReleaseItemIfUnowned;                { both sides closed: the item's pin goes }
    { ---- shared mode (the exchange is shared: every call above runs under Lock) ---- }
    function Shared: Boolean; inline;              { Ex <> nil and Ex.Shared }
    function OnLoop: Boolean;                      { the calling thread is the exchange's loop }
    { drops a view: unpins it on the loop thread; on another thread it goes to ToRelease
      (pin counts are loop-thread counters) }
    procedure DropView(var V: TBytesView);
    procedure ReleaseToRelease;                    { loop thread }
    { the loop closes the receiver for the handler after a cancel won (not at call completion):
      Held stays with the handler (it may still read it) until it hands it back or the exchange
      is recycled; a parked reader is unparked }
    procedure CloseReceiverFromLoop;
    procedure TakeDeferred(out W, U: Boolean); inline;   { under Lock }
    procedure RunDeferred(W, U: Boolean);                { after Lock.Release }
    function PollReadyImpl(out Closed: Boolean): Boolean;
    function TrySendDataImpl(const V: TBytesView): Boolean;
    function TrySendTrailersImpl: Boolean;
    procedure SendErrorImpl(const E: THyperError);
    procedure CloseSenderImpl;
  end;

  { The response. Written by the handler until the terminal call; read by the dispatcher after. }
  TResponseSlot = record
    Head: TResponseHead;              { status, version, reason phrase, header fields (bearings.http1.role) }
    Body: TBodyData;                  { set by Respond }
    Source: TBodySource;              { set by RespondStream / BeginStream }
    Failed: Boolean;
    FailText: RawByteString;          { cold; Fail(Msg) }
    BodyErrorText: RawByteString;     { cold; set by a source before returning fpError }
  end;

  TBodyReadStatus = (brData, brTrailers, brEnd, brPending, brError, brCanceled);
  TWriteResult = (wrOk, wrWouldBlock, wrCanceled);
  { classes of body errors (conformance/SPEC.md 7.1) }
  TBodyErrorKind = (bekUnexpectedEof, bekInvalidData, bekInvalidInput, bekIo, bekOther);
  EClientGone = class(Exception);         { a blocking body read after a cancel or a release }
  EBodyError = class(Exception) public Kind: TBodyErrorKind; end;   { the body could not be read }
  EBodyTooLarge = class(Exception);       { ReadAll: the body is over the limit }

  TExchangeState = (xsIdle, xsCalled, xsAnswered, xsCanceled, xsDone);   { see the unit header }

  TExchange = class(TWorkItem)     { its own work item: Offload queues it without allocating }
  private
    FState: LongInt;                { TExchangeState; changed by CAS when shared }
    FShared: Boolean;
    FRefCount: LongInt;             { the transport + one per Share (see the unit header) }
    FOwner: TLoopTask;              { the connection task; nil after a cancel or ReleaseTransport }
    FLoop: TLoop;
    WakeMsg, FreeMsg: TLoopMsg;     { inbox messages kept in the object: posting allocates nothing }
    FWakeQueued: LongInt;           { 1 while WakeMsg is in the loop's inbox }
    FUser: TObject; FTag: PtrInt;
    FGen: LongWord;                 { bumped per request and at recycle (TWakeTimer check) }
    FUpgrade: TUpgradeSlot;         { the request's upgrade slot; nil without an upgrade request }
    FBodyErr: THyperError;          { the last body error TryRead returned }
    FReasonBuf: TByteVec;           { SetReason's copy (heap) }
    FNextFree: TExchange;           { TExchangePool link }
    FHandler: TBlockingHandler;     { Offload's handler; nil = not offloaded in this request }
    FHomePool: TExchangePool;       { the pool it came from (recycled there, on its loop) }
    FFreePending: Boolean;          { the last reference went while WakeMsg was queued }
    FChannel: TChannelBody;         { BeginStream's channel, owned, reused per request }
    FHeldPos: SizeInt;              { Read: bytes of Chan.Held already copied out }
    FAnswerClaim: LongInt;          { shared: 1 once a terminal call owns the response slot }
    { the call in flight plus the references Share gave out and Release has not taken back
      (FRefCount also counts the transport). The decrement that takes it to 0 releases the
      request (ReleaseRequest) and ends a stream left open. }
    FHolders: LongInt;
    { used by builds with assertions only; the fields exist in every build so the class layout
      does not depend on -Sa }
    FHeadWriter: Pointer;           { shared: the thread that wrote the response head }
    FWakeGen: LongWord;             { FGen when WakeMsg was posted; checked when it is dispatched }
    FInServiceCall: Boolean;        { THttpService.Call is running }
    FAttachment: TExchangeAttachment;   { detached at Recycle / BeginRequest }
    procedure DetachAttachment;     { cold }
    procedure NoResponse;           { cold: CompleteCall without a terminal call }
    function OnOwnLoop: Boolean;    { the calling thread is FLoop's thread (or no loop) }
    procedure SyncShared;           { loop: hand-backs (ToRelease, released head) are unpinned }
    procedure CloseBodyFromLoop;    { loop, shared: the receiver is closed for the handler }
    procedure FinalRelease;         { loop: the last reference went }
    procedure ReleaseRequestShared;
    procedure DropHolder;           { FHolders - 1; at 0 the request is released and the stream
                                      ended }
    procedure CompleteShared;
    procedure CancelShared;
    function TryReadShared(out Chunk: TByteSlice): TBodyReadStatus;
    function RespondShared(const Body: TBodyData): Boolean;
    function RespondStreamShared(Source: TBodySource): Boolean;
    { CheckHead False: the worker job's own error answer (RunHandler, HandlerRaised), which does
      not use the response head (a Failed answer writes no response) }
    function FailShared(const Msg: RawByteString; CheckHead: Boolean): Boolean;
    { shared: the first terminal call takes the response slot. Builds with assertions, CheckHead:
      when the claimer is not the thread that built the head, the claim is undone and False
      returned; the caller cleans up and calls DbgClaimRefused, which raises }
    function ClaimAnswer(CheckHead: Boolean): Boolean;
    function PublishStream(Source: TBodySource): Boolean;
    procedure BlockOnBody;          { worker: park until the channel changes }
    procedure RaiseBodyError;
    procedure RunHandler;           { worker: Handler.Run in try/except }
    procedure HandlerRaised(E: Exception);
    function StreamWriter: TChannelBody;
    procedure DropUpgrade;          { releases the exchange's reference to FUpgrade }
    {$ifopt C+}
    procedure DbgLoopOnly;          { unshared: the caller is the loop thread }
    procedure DbgHeadWrite;         { a response head write: one writer thread }
    function DbgHeadClaimOk: Boolean;  { the claiming terminal call built the head, or nobody did }
    procedure DbgClaimRefused;      { raises the head-writer assertion when ClaimAnswer refused }
    {$endif}
    function GetStatus: Word;  procedure SetStatus(V: Word);
    function GetRespVersion: THttpVersion;  procedure SetRespVersion(V: THttpVersion);
    function GetOffloaded: Boolean;
    function GetRefCount: LongInt;
  public
    Head: TRequestHead;
    Chan: TBodyChan;
    Resp: TResponseSlot;
    ReqTrailers: THttpHeaders;      { request trailers (decoder output, copied into the list's arena) }

    constructor Create;
    destructor Destroy; override;

    { ---- request head (any thread holding the exchange; valid until ReleaseRequest) ---- }
    { Threading rule for the accessors below: an unshared exchange belongs to
      its loop thread and may be read only there (builds with assertions
      check it, DbgLoopOnly); a shared exchange (after Share) may be read
      by any thread that holds a reference. "Any thread" in the comments
      of this unit means that. }
    function Method: THttpMethod; inline;
    function MethodBytes: TByteSlice;
    function Target: TByteSlice;                         { request-target as received }
    function Path: TByteSlice;                           { the path part of the target (bearings.http.uri) }
    function Query(out Q: TByteSlice): Boolean;
    function Version: THttpVersion; inline;
    function Headers: THttpHeaders; inline;              { read-only by contract }
    function Header(const Name: RawByteString; out V: TByteSlice): Boolean;
    function ContentLength: Int64; inline;
    function ExpectsContinue: Boolean; inline;
    function WantsUpgrade: Boolean; inline;
    function ConnId: QWord; inline;
    function RequestNo: LongWord; inline;
    { the client's address (Head.Peer, copied from the accepted socket's address by the
      dispatcher for every request; a zeroed record, family 0, when the connection was not
      accepted from a listener). SockAddrToStr (bearings.rt.net) gives its text. }
    function PeerAddr: PSockAddrStorage; inline;
    { The application is done with the request: closes the body receiver (an unread body is
      then read and discarded, or the connection is closed; no 100 Continue is sent) and unpins
      the head. Automatic at call completion (unshared exchange) or at the Release of the last
      holder (shared exchange). The head accessors are invalid afterwards. }
    procedure ReleaseRequest;

    { ---- request body ---- }
    { never blocks; brPending asks for more, and the call is polled again when it arrives }
    function TryRead(out Chunk: TByteSlice): TBodyReadStatus;
    function Read(Buf: PByte; Max: SizeInt): SizeInt;              { worker only; blocks; 0 = end }
    function ReadChunk(out Chunk: TByteSlice): Boolean;            { worker only; blocks; zero-copy }
    function ReadAll(var Dst: TBytes; Limit: SizeInt): SizeInt;    { worker only; EBodyTooLarge }
    { TryRead that blocks instead of returning brPending (worker only): brData, brTrailers,
      brEnd, brError or brCanceled; for a handler that must see the trailers }
    function ReadFrame(out Chunk: TByteSlice): TBodyReadStatus;
    procedure DiscardBody;                                         { close the receiver only }
    function RequestTrailers: THttpHeaders;                        { after brTrailers / brEnd }
    function BodyErrorKind: TBodyErrorKind;
    function BodyErrorMessage: string;                             { conformance/SPEC.md 7.1 text }
    { the body error is the transport's body read timeout (TH1Config.BodyReadTimeoutMs: the
      client sent no body byte for too long, or sent too slowly) }
    function BodyErrorIsTimeout: Boolean;

    { ---- response head (before the terminal call; shared exchange: only the thread that makes
         the terminal call writes it; asserted in builds with assertions) ---- }
    property Status: Word read GetStatus write SetStatus;                        { default 200 }
    property ResponseVersion: THttpVersion read GetRespVersion write SetRespVersion;  { default hv11 }
    { a custom reason phrase; False if it holds an invalid byte; the bytes are copied }
    function SetReason(P: PByte; Len: SizeInt): Boolean;
    function ResponseHeaders: THttpHeaders;                        { mutators validate their input }

    { ---- terminal calls: exactly one; any thread holding the exchange; False if the exchange was
         canceled or already answered ---- }
    function Respond(const Body: TBodyData): Boolean;             { known length or empty }
    function RespondStream(Source: TBodySource): Boolean;          { unknown length }
    function BeginStream(HighWater: SizeInt = 65536): Boolean;     { RespondStream(TChannelBody) }
    { the handler failed: no response is written, the connection closes with a user error (Msg) }
    function Fail(const Msg: RawByteString): Boolean;

    { ---- stream writer after BeginStream (any holder of a shared exchange;
         the loop thread otherwise) ---- }
    { On a worker thread Write parks while HighWater bytes are queued. On
      the loop thread it cannot park (the loop itself drains the queue), so
      there it behaves like TryWrite and returns wrWouldBlock when full. }
    function Write(P: PByte; Len: SizeInt): TWriteResult;
    function TryWrite(P: PByte; Len: SizeInt): TWriteResult;       { never blocks: wrWouldBlock }
    function WriteString(const S: RawByteString): TWriteResult;    { keeps one reference, no copy }
    { Ends the stream. Trailers are copied; they are sent only when the
      response is chunked, the request carried "TE: trailers", and the
      names were announced in the response's Trailer header; otherwise
      they are dropped. }
    function Finish(Trailers: THttpHeaders = nil): Boolean;
    { Ends the stream with a body error: no last chunk is written, so the
      client sees a truncated body. Msg becomes the connection's error
      text, reported to the observer when the connection closes. }
    procedure AbortStream(const Msg: RawByteString);

    { ---- upgrades ---- }
    procedure OnUpgrade(H: TUpgradeHandler);                       { loop thread, before answering }

    { ---- execution and lifetime ---- }
    function OnLoopThread: Boolean; inline;                        { not shared (a query; not asserted) }
    { loop thread, from Poll: Share, then queue the exchange on Pool; a worker runs H.Run(Self) }
    procedure Offload(Pool: TWorkerPool; H: TBlockingHandler);
    function Share: TExchange;      { loop thread: switch to shared mode, +1 reference (atomic) }
    procedure Release;              { any thread, after Share; last release posts the recycle }
    procedure Wake;                 { re-run the owning connection: local Wake, or Post if shared }
    function IsCanceled: Boolean;   { any holder of a shared exchange; the loop thread otherwise }
    function Answered: Boolean;     { any holder of a shared exchange; the loop thread otherwise }
    procedure SetBodyErrorText(const Msg: RawByteString);          { cold; for TBodySource }
    function Loop: TLoop; inline;
    property User: TObject read FUser write FUser;                 { per-request application state }
    { set on the loop thread (before Offload when a worker reads it); detached by the transport
      (TExchangeAttachment) }
    property Attachment: TExchangeAttachment read FAttachment write FAttachment;
    property Tag: PtrInt read FTag write FTag;
    { internal, used by the dispatcher }
    { Starts a request on this exchange: state xsCalled, a new generation, the response head
      HTTP/1.1 200 with no headers, no body, no upgrade slot, no user data. }
    procedure BeginRequest(AOwner: TLoopTask);
    { Copies the head fields from the parse result. View is the pinned head (owned by the
      exchange from now on); Head.Headers was filled by the parser. }
    procedure FillHead(const Msg: TParsedRequestHead; const View: TBytesView; ARequestNo: LongWord);
    procedure LinkUpgrade(S: TUpgradeSlot);      { from TConnState.PrepareUpgrade; takes a reference }
    procedure CompleteCall;         { the call returned cpReady: releases the request }
    procedure Cancel;               { the connection abandons the call }
    procedure Recycle;              { every pin released, lists cleared, no owner }
    { The transport's reference goes: unshared, back to the pool at once; shared, the owner is
      cleared, an answered body nobody took is dropped, and the last reference recycles it.
      Loop thread (the dispatcher). }
    procedure ReleaseTransport;
    { the worker job (TWorkItem): Handler.Run(Self), Fail if it gave no answer, Release }
    procedure Execute; override;
    property Shared: Boolean read FShared;
    property RefCount: LongInt read GetRefCount;      { an atomic load (any thread) }
    property Offloaded: Boolean read GetOffloaded;
    property Owner: TLoopTask read FOwner;
    property Generation: LongWord read FGen;
    property UpgradeSlot: TUpgradeSlot read FUpgrade;
    {$ifopt C+}
    { builds with assertions: the dispatcher marks the exchange while THttpService.Call runs;
      the terminal calls and TryRead assert the mark is off }
    procedure DbgServiceCall(Inside: Boolean);
    {$endif}
  end;

  { An application timer that wakes the exchange's connection when it fires. Loop thread. }
  PWakeTimer = ^TWakeTimer;
  TWakeTimer = record                { zeroed = not armed; must not move while armed }
    T: TTimer;
    Target: TExchange;               { the exchange Arm was given }
    Gen: LongWord;                   { Ex.Generation at Arm: a later request is not woken }
    procedure Arm(Ex: TExchange; DelayMs: Int64);    { Loop.NowMs + DelayMs }
    function Fired: Boolean; inline;
    procedure Cancel(Ex: TExchange);                 { removes it (owner may be recycled) }
  end;

  TFramePoll = (fpData, fpTrailers, fpEnd, fpError, fpPending);

  { A response body produced piece by piece (RespondStream). The dispatcher polls it on the loop
    thread, and only while the write buffer has room, so a slow client is not sent more than it
    reads. }
  TBodySource = class
  public
    function SizeHint(out Exact: QWord): Boolean; virtual;    { default False (unknown) }
    function IsEndStream: Boolean; virtual;                   { default False }
    { fpPending: the source must arrange Ex.Wake. fpError: set Ex.SetBodyErrorText first (cold).
      fpTrailers: ownership of Trailers stays with the source until the next call. }
    function PollFrame(Ex: TExchange; out Data: TBodyData;
      out Trailers: THttpHeaders): TFramePoll; virtual; abstract;
    procedure Done(Ex: TExchange); virtual;                   { the transport is done with it }
  end;

  { The queue behind BeginStream: a bounded FIFO of frames under a spin lock. Producer: any
    thread (after BeginStream); consumer: the dispatcher. Bounded by HighWater bytes (a frame
    larger than HighWater is still accepted when the queue is empty); frame boundaries kept (one
    Write = one chunk on the wire). Any number of producers may wait for room (FSpace wakes
    them all).
    BeginStream uses the exchange's own instance (created on first use, reused per request,
    freed with the exchange); one created by the application and given to RespondStream is the
    application's to free once its producers are done. }
  TChannelBody = class(TBodySource)
  private
    FLock: TSpinLock;
    FHighWater: SizeInt;
    FRing: array of TBodyData;       { queued frames (FIFO ring) }
    FHead, FCount: Integer;
    FQueued: SizeInt;                { bytes queued }
    FActive, FFinished, FAborted, FClosed: Boolean;
    FFinishing: Boolean;             { a Finish claimed the end and copies its trailers }
    FAbortMsg: RawByteString;
    FTrailers: THttpHeaders;         { Finish's copy; written only by the Finish that claimed the end }
    FHasTrailers, FTrailersSent: Boolean;
    FConsumerWaiting, FProducerWaiting: Boolean;
    FSpace: TEventCount;             { producers waiting for room (any number of them) }
    FEx: TExchange;                  { woken when a frame arrives and the dispatcher waits }
    procedure Enqueue(const B: TBodyData);
    procedure Grow;                  { under FLock: a ring twice as large (cold) }
    function Ended: Boolean; inline; { under FLock: no frame is accepted any more }
    procedure DropQueued;            { under FLock }
  public
    constructor Create(HighWater: SizeInt);
    destructor Destroy; override;
    { Starts a stream for Ex: empty, open, HighWater bytes (<= 0: 65536). }
    procedure Reset(Ex: TExchange; HighWater: SizeInt);
    { Queues B (consumed in every case). Block: park while full (the caller is not the loop). }
    function Push(var B: TBodyData; Block: Boolean): TWriteResult;
    function FinishStream(Trailers: THttpHeaders): Boolean;
    function AbortWith(const Msg: RawByteString): Boolean;
    { the last producer is gone without Finish: the stream ends normally. Called by
      TExchange.DropHolder when the holder count reaches 0 (shared exchange; the caller still
      holds its reference), and by CompleteCall (unshared exchange). }
    procedure AutoFinish;
    procedure WakeProducer;          { the parked producers re-check (cancel) }
    procedure Deactivate;            { exchange recycle }
    function PollFrame(Ex: TExchange; out Data: TBodyData;
      out Trailers: THttpHeaders): TFramePoll; override;
    procedure Done(Ex: TExchange); override;                  { marks closed: producers get wrCanceled }
    function Queued: SizeInt;                                 { bytes queued (under the lock) }
    { a write of no bytes: wrOk while this request's stream is active, else wrCanceled (read
      under the lock) }
    function EmptyWrite: TWriteResult;
    property Closed: Boolean read FClosed;
  end;

  TUpgradeState = (usNone, usPending, usFulfilled, usManual, usCanceled);
  { One per request that asks for an upgrade (not pooled: upgrades are rare). Held by the
    connection side (TConnState.Upgrade, then the dispatcher's pending upgrade or the task that
    delivers the upgrade) and by the exchange (for OnUpgrade). An atomic reference count, one
    reference per holder: Create gives the first one, AddRef one more, the last Release frees
    the slot. State and the handler calls: loop thread only. }
  TUpgradeSlot = class
  private
    FRefs: LongInt;
  public
    State: TUpgradeState;
    Handler: TUpgradeHandler;        { set by Ex.OnUpgrade; nil = nobody took the upgrade }
    RxAlive: Boolean;                { Handler <> nil, or the request is not yet released }
    Upgraded: TUpgraded;             { usFulfilled: waiting for Deliver }
    { Stores U (state usFulfilled); the delivery task calls Deliver after the HTTP connection
      ended. }
    procedure Fulfill(U: TUpgraded);
    procedure Deliver;               { Handler.Upgraded(U) if the receiver lives, else U.Close }
    procedure Manual;                { Handler.UpgradeFailed('upgrade expected but low level API in use') }
    procedure Cancel;                { Handler.UpgradeFailed('upgrade expected but not completed') }
    constructor Create;              { one reference }
    destructor Destroy; override;
    procedure AddRef;
    procedure Release;               { the last reference frees the slot }
    property RefCount: LongInt read FRefs;
  end;
  TUpgradePending = record Active: Boolean; Slot: TUpgradeSlot; end;   { conn side }

  TUpgradeHandler = class
  public
    procedure Upgraded(U: TUpgraded); virtual; abstract;      { loop thread }
    procedure UpgradeFailed(const Msg: string); virtual;      { loop thread }
  end;

  TBlockingHandler = class
  public
    procedure Run(Ex: TExchange); virtual; abstract;   { worker thread; may block }
  end;

  { Shared, stateless call that offloads: one per (pool, handler). }
  TOffloadCall = class(TServiceCall)
  public
    Pool: TWorkerPool;
    Handler: TBlockingHandler;
    { First poll: Ex.Offload(Pool, Handler), Pending. Later polls: cpReady once Ex.Answered. }
    function Poll(Ex: TExchange): TCallPoll; override;
  end;

  TExchangePool = class              { one per loop; loop thread only }
  private
    FFree: TExchange;
    FCount: Integer;
    FOut: Integer;                   { taken and not given back }
  public
    destructor Destroy; override;
    property FreeCount: Integer read FCount;
    { exchanges taken from this pool and not yet given back: held by a connection or by a
      reference Share gave out (TServer.Destroy waits for these) }
    property Outstanding: Integer read FOut;
    function Take(Loop: TLoop): TExchange;          { cleared exchange, FRefCount = 1 }
    procedure Give(Ex: TExchange);                  { recycle: lists cleared, capacity kept }
  end;

  { What the dispatcher hands back in cmWithoutShutdown mode when the HTTP connection ends: the
    transport and the bytes read but not parsed (the fields Transport and Rest). }
  TConnParts = record
    Transport: TTransport;           { owned by the receiver }
    Rest: TBytesView;                { unread bytes; pinned, loop thread }
    { The connection task's readiness source (fd, readiness bits). The task is freed after
      the event batch: a receiver that keeps the socket open moves the source before OnParts
      returns, with TUpgraded.CreateFrom(Loop, Transport, Rest, Src, True). }
    Src: PIoSource;
  end;

  { Hooks for tests and the conformance server. nil in production: zero cost. Loop thread. }
  TConnObserver = class
  public
    { Returns per-connection data passed to the other hooks (e.g. the conformance req counter). }
    function OnAccept(Loop: TLoop; ConnId: QWord; const Peer: TSockAddrStorage): Pointer; virtual;
    { May wrap the transport (TCountingTransport for bytes_read). Default: T. }
    function WrapTransport(T: TTcpTransport; Data: Pointer): TTransport; virtual;
    { The connection task is set up and registered; it has not run yet (the conformance server
      may start the connection's graceful shutdown here). Default: nothing. }
    procedure OnStart(ConnId: QWord; Data: Pointer; Task: TLoopTask); virtual;
    procedure OnConnClose(ConnId: QWord; Data: Pointer; Outcome: TConnOutcome;
      const Detail: string); virtual;
    procedure OnParts(ConnId: QWord; Data: Pointer; var Parts: TConnParts); virtual;   { default: close }
  end;

{ A block from the loop's pool (heap without a loop) holding a copy of P^; the block is owned
  by the returned TBodyData and goes back in ReleaseBody. }
function BodyCopy(Ex: TExchange; P: Pointer; Len: SizeInt): TBodyData;

var
  { TUpgradeSlot objects alive (created and not yet freed); tests check the slot's reference
    counting with it. Atomic. }
  UpgradeSlotsLive: LongInt = 0;
  { TExchange objects alive (created and not yet freed); tests check that every exchange a
    worker released reached its pool and was freed with it. Atomic. }
  ExchangesLive: LongInt = 0;

{$ifopt C+}
type
  { Builds with assertions only (tests): called by TExchange.Release right after its decrement,
    with the count it left. It must not touch Ex (the exchange may already be recycled); a test
    sleeps in it to widen the window in which a stale releaser could still act on the exchange. }
  TReleaseTestHook = procedure(Ex: TExchange; NewCount: LongInt);
  { Builds with assertions only (tests): TryReadTestHook is called by a body read on a shared
    exchange right before it takes Chan.Lock; AnswerTestHook by Fail on a shared exchange right
    after it claimed the response slot. A test sleeps in them to widen the race windows between
    a terminal call, a cancel and a body read. }
  TExchangeTestHook = procedure(Ex: TExchange);
var
  ReleaseTestHook: TReleaseTestHook = nil;
  { called by TExchange.Release on the releasing thread after the holder count
    went down (and, at 0, the request and the stream were ended) and right before the reference
    count goes down. A test stops a thread there (a preemption in that window) }
  ReleaseBeforeDecrementHook: TExchangeTestHook = nil;
  TryReadTestHook: TExchangeTestHook = nil;
  AnswerTestHook: TExchangeTestHook = nil;
{$endif}

implementation

uses
  bearings.http1.reason;

const
  NO_UPGRADE_MSG = 'no upgrade available';
  MANUAL_UPGRADE_MSG = 'upgrade expected but low level API in use';
  CANCELED_UPGRADE_MSG = 'upgrade expected but not completed';

{ Builds with assertions (-Sa: every test build and the conformance
  server's debug profile) overwrite the bytes of a released head view with
  $DD before it is unpinned, so a stale reader sees $DD instead of the next
  request's bytes. Pool memory only (a view of static memory, Block = nil,
  is left alone). }
procedure PoisonAndRelease(var V: TBytesView); inline;
begin
  {$ifopt C+}
  if (V.Block <> nil) and (V.P <> nil) and (V.Len > 0) then
    FillChar(V.P^, V.Len, $DD);
  {$endif}
  V.Release;
end;

procedure ClearView(var V: TBytesView); inline;
begin
  V.P := nil;
  V.Len := 0;
  V.Block := nil;
end;

{ TServiceCall }

procedure TServiceCall.Drop(Ex: TExchange; Completed: Boolean);
begin
end;

{ ---- TBodyChan ----
  Unshared exchange: loop thread only, no lock. Shared exchange: every call
  holds Lock; the wakes a call finds (Ex.Wake of the other side, the parked
  worker's Unpark) are collected under the lock (DeferWake, DeferUnpark)
  and run after it is released. Pin counts are loop-thread counters: a
  view the worker drops goes to ToRelease / ToRelease2, which the loop
  unpins before it fills the slot again (PollReady) or when a wake from
  another thread reaches it (SyncShared). }

function TBodyChan.Shared: Boolean;
begin
  Result := (Ex <> nil) and Ex.FShared;
end;

function TBodyChan.OnLoop: Boolean;
begin
  Result := (Ex = nil) or Ex.OnOwnLoop;
end;

procedure TBodyChan.WakeSender;
begin
  { wakes the sender only if it registered; the wake uses up the
    registration }
  if SenderWaker then
  begin
    SenderWaker := False;
    if Ex <> nil then
      if Ex.FShared then
        DeferWake := True
      else
        Ex.Wake;
  end;
end;

procedure TBodyChan.WakeReceiver;
begin
  { the same for the receiver; a parked worker is unparked }
  if ReceiverWaker then
  begin
    ReceiverWaker := False;
    if Ex <> nil then
      if Ex.FShared then
        DeferWake := True
      else
        Ex.Wake;
  end;
  if ReceiverParks then
  begin
    ReceiverParks := False;
    DeferUnpark := True;
  end;
end;

procedure TBodyChan.TakeDeferred(out W, U: Boolean);
begin
  W := DeferWake;
  U := DeferUnpark;
  DeferWake := False;
  DeferUnpark := False;
end;

procedure TBodyChan.RunDeferred(W, U: Boolean);
begin
  if W and (Ex <> nil) then
    Ex.Wake;
  if U then
    Parker.Unpark;
end;

procedure TBodyChan.DropView(var V: TBytesView);
begin
  if V.Block = nil then
  begin
    ClearView(V);
    Exit;
  end;
  if (not Shared) or OnLoop then
  begin
    V.Release;
    Exit;
  end;
  { a worker: the loop unpins it (ReleaseToRelease) }
  if ToRelease.Block = nil then
    ToRelease := V
  else if ToRelease2.Block = nil then
    ToRelease2 := V
  else
    { unreachable: between two loop-side releases at most two views come back
      (the one held when the slot was filled and the one taken from it); the
      pin would stay until the block is reused, never freed under a reader }
    Assert(False, 'TBodyChan.DropView: ToRelease slots full');
  ClearView(V);
end;

procedure TBodyChan.ReleaseToRelease;
begin
  if ToRelease.Block <> nil then
    ToRelease.Release;
  if ToRelease2.Block <> nil then
    ToRelease2.Release;
end;

procedure TBodyChan.Open(Wanter: Boolean);
begin
  { Wanter (Expect: 100-continue): Want starts False, so the dispatcher
    reads no body, and sends no 100 Continue, until the receiver first
    polls }
  ItemKind := ciNone;
  ClearView(Item);
  HasPendingErr := False;
  HasTrailers := False;
  TrailersSent := False;
  SenderOpen := True;
  ReceiverOpen := True;
  Want := not Wanter;
  Terminated := False;
  ClearView(Held);
  ClearView(ToRelease);
  ClearView(ToRelease2);
  SenderWaker := False;
  ReceiverWaker := False;
  ParkingReceiver := False;
  ReceiverParks := False;
  DeferWake := False;
  DeferUnpark := False;
  Active := True;
end;

function TBodyChan.PollReady(out Closed: Boolean): Boolean;
var
  W, U: Boolean;
begin
  if not Shared then
    Exit(PollReadyImpl(Closed));
  Lock.Acquire;
  Result := PollReadyImpl(Closed);
  TakeDeferred(W, U);
  Lock.Release;
  RunDeferred(W, U);
end;

function TBodyChan.TrySendData(const V: TBytesView): Boolean;
var
  W, U: Boolean;
begin
  if not Shared then
    Exit(TrySendDataImpl(V));
  Lock.Acquire;
  Result := TrySendDataImpl(V);
  TakeDeferred(W, U);
  Lock.Release;
  RunDeferred(W, U);
end;

function TBodyChan.TrySendTrailers: Boolean;
var
  W, U: Boolean;
begin
  if not Shared then
    Exit(TrySendTrailersImpl);
  Lock.Acquire;
  Result := TrySendTrailersImpl;
  TakeDeferred(W, U);
  Lock.Release;
  RunDeferred(W, U);
end;

procedure TBodyChan.SendError(const E: THyperError);
var
  W, U: Boolean;
begin
  if not Shared then
  begin
    SendErrorImpl(E);
    Exit;
  end;
  Lock.Acquire;
  SendErrorImpl(E);
  TakeDeferred(W, U);
  Lock.Release;
  RunDeferred(W, U);
end;

procedure TBodyChan.CloseSender;
var
  W, U: Boolean;
begin
  if not Shared then
  begin
    CloseSenderImpl;
    Exit;
  end;
  Lock.Acquire;
  CloseSenderImpl;
  TakeDeferred(W, U);
  Lock.Release;
  RunDeferred(W, U);
end;

function TBodyChan.PollReadyImpl(out Closed: Boolean): Boolean;
begin
  ReleaseToRelease;
  SenderWaker := True;                                   { wake me when the slot frees or Want is set }
  if not ReceiverOpen then
  begin
    Closed := True;                                      { the receiver is gone }
    Exit(True);
  end;
  Closed := False;
  Result := Want and (ItemKind = ciNone) and not HasPendingErr;
end;

function TBodyChan.TrySendDataImpl(const V: TBytesView): Boolean;
begin
  if (not ReceiverOpen) or (not Want) or (ItemKind <> ciNone) or HasPendingErr then
    Exit(False);
  ItemKind := ciData;
  Item := V;
  WakeReceiver;
  Result := True;
end;

function TBodyChan.TrySendTrailersImpl: Boolean;
begin
  { trailers can be announced once }
  if TrailersSent then
    Exit(False);
  TrailersSent := True;
  if not ReceiverOpen then
    Exit(False);
  HasTrailers := True;
  WakeReceiver;
  Result := True;
end;

procedure TBodyChan.SendErrorImpl(const E: THyperError);
begin
  { an error must not displace data already in the slot: it waits in
    PendingErr and is delivered after the data }
  if not ReceiverOpen then
    Exit;
  if ItemKind = ciNone then
  begin
    ItemKind := ciError;
    ItemErr := E;
  end
  else if not HasPendingErr then
  begin
    PendingErr := E;
    HasPendingErr := True;
  end;
  WakeReceiver;
end;

procedure TBodyChan.ReleaseItemIfUnowned;
begin
  { a chunk nobody took stays in the slot while either side is open; it is
    released when both are closed }
  if (not SenderOpen) and (not ReceiverOpen) and (ItemKind = ciData) then
  begin
    DropView(Item);
    ItemKind := ciNone;
  end;
end;

procedure TBodyChan.CloseSenderImpl;
begin
  if not SenderOpen then
    Exit;
  SenderOpen := False;
  if ReceiverOpen then
    WakeReceiver;
  ReleaseItemIfUnowned;
end;

function TBodyChan.PollNext(out V: TBytesView; out E: THyperError): TChanPoll;
var
  WakeS: Boolean;
begin
  { asking for the next item sets Want, which wakes a sender waiting for
    it }
  ClearView(V);
  if Terminated then
    Exit(cnEnd);
  if ParkingReceiver then
    ReceiverParks := True                                { a worker: woken through Parker }
  else
    ReceiverWaker := True;                               { the loop: woken through Ex.Wake }
  WakeS := not Want;
  if WakeS then
    Want := True;
  if ItemKind <> ciNone then
  begin
    if ItemKind = ciData then
    begin
      V := Item;
      ClearView(Item);
      Result := cnData;
    end
    else
    begin
      E := ItemErr;
      Result := cnError;
    end;
    ItemKind := ciNone;
    WakeSender;
    Exit;
  end;
  if HasPendingErr then
  begin
    E := PendingErr;
    HasPendingErr := False;
    if WakeS then
      WakeSender;
    Exit(cnError);
  end;
  if WakeS then
    WakeSender;
  if SenderOpen then
    Exit(cnPending);
  Terminated := True;
  Result := cnEnd;
end;

function TBodyChan.TakeTrailers: Boolean;
begin
  Result := HasTrailers;
  HasTrailers := False;
end;

procedure TBodyChan.CloseReceiver;
begin
  { the receiver is closed and the sender woken. The chunk the receiver was
    using (Held) is released. An item it never took stays in the slot until
    the sender closes too (ReleaseItemIfUnowned): it keeps its read-buffer
    block pinned, so the reads in between cannot compact that block
    (TReadBuf.Reserve). }
  if not ReceiverOpen then
    Exit;
  ReceiverOpen := False;
  DropView(Held);
  { a reader parked in a body read is unparked (only a shared exchange has
    one: another holder released the request); its read then reports
    brCanceled, never the end of a body that did not end
    (TExchange.TryReadShared) }
  if ReceiverParks then
  begin
    ReceiverParks := False;
    DeferUnpark := True;
  end;
  if SenderOpen then
    WakeSender;
  ReleaseItemIfUnowned;
end;

procedure TBodyChan.CloseReceiverFromLoop;
begin
  { the loop closes the receiver for the handler (shared exchange, after a
    cancel won: the connection abandoned the call before the handler
    answered). The chunk the handler holds stays pinned until it hands it
    back (its next body call) or the exchange is recycled, so its bytes stay
    valid. A reader parked in a body read is unparked (every close by the
    loop unparks) and its read reports brCanceled (the state is
    xsCanceled), never the end of the body }
  if not ReceiverOpen then
    Exit;
  ReceiverOpen := False;
  if ReceiverParks then
  begin
    ReceiverParks := False;
    DeferUnpark := True;
  end;
  if SenderOpen then
    WakeSender;
  ReleaseItemIfUnowned;
end;

{ TExchange }

constructor TExchange.Create;
begin
  inherited Create;
  FState := Ord(xsIdle);
  FRefCount := 1;
  Head.Headers := THttpHeaders.Create(16, 0);
  Resp.Head := DefaultResponseHead;
  Resp.Head.Headers := THttpHeaders.Create(16, 1024);
  Resp.Body := BodyEmpty;
  ReqTrailers := THttpHeaders.Create(4, 256);
  Chan.Ex := Self;
  WakeMsg.Kind := lmWakeExchange;
  WakeMsg.Arg := Self;
  FreeMsg.Kind := lmFreeExchange;
  FreeMsg.Arg := Self;
  InterLockedIncrement(ExchangesLive);
end;

destructor TExchange.Destroy;
begin
  Recycle;
  if FReasonBuf.Block <> nil then
    BlockFree(FReasonBuf.Block);
  Head.Headers.Free;
  Resp.Head.Headers.Free;
  ReqTrailers.Free;
  FChannel.Free;
  InterLockedDecrement(ExchangesLive);
  inherited Destroy;
end;

function TExchange.GetRefCount: LongInt;
begin
  Result := AtomicLoad(FRefCount);
end;

function TExchange.GetOffloaded: Boolean;
begin
  Result := FHandler <> nil;
end;

function TExchange.OnOwnLoop: Boolean;
begin
  Result := (FLoop = nil) or (GetCurrentThreadId = AtomicLoadThreadId(FLoop.ThreadId));
end;

{ ---- debug checks (builds with assertions, -Sa: every test build and the
  conformance server's debug profile). Release builds do not contain these
  routines or their calls (tools/check-hot-asm.sh --s7 checks the
  production listing). ---- }

{$ifopt C+}
procedure TExchange.DbgLoopOnly;
begin
  { an unshared exchange is the loop thread's alone: every method of it is
    loop-only }
  if not FShared then
    Assert(OnOwnLoop, 'TExchange: a loop-only method of an unshared exchange called off its loop thread');
end;

procedure TExchange.DbgHeadWrite;
var
  Me, Old: Pointer;
begin
  { the response head is built by one thread, the one that makes the
    terminal call, before that call. Unshared: the loop thread.
    Shared: the first head write after Share names the thread; a write from
    another thread, or after a terminal call claimed the response, fails }
  if not FShared then
  begin
    DbgLoopOnly;
    Exit;
  end;
  { the claim, not the state: the loop's Cancel changes the state at any
    time, and a head write before this thread's own (losing) terminal call
    is legal }
  Assert(AtomicLoad(FAnswerClaim) = 0,
    'TExchange: the response head is written after the terminal call');
  Me := Pointer(PtrUInt(GetCurrentThreadId));
  Old := InterlockedCompareExchange(FHeadWriter, Me, nil);
  Assert((Old = nil) or (Old = Me),
    'TExchange: the response head is written by two threads');
end;

threadvar
  { set by ClaimAnswer when it refused a claim for the head-writer check;
    DbgClaimRefused reads and clears it }
  DbgClaimRefusedFlag: Boolean;

function TExchange.DbgHeadClaimOk: Boolean;
var
  W: Pointer;
begin
  { the claiming terminal call (shared exchange) is made by the thread that
    built the head, if one did }
  W := InterlockedCompareExchange(FHeadWriter, nil, nil);
  Result := (W = nil) or (W = Pointer(PtrUInt(GetCurrentThreadId)));
end;

procedure TExchange.DbgClaimRefused;
begin
  { called after the caller released what the refused call carried (its
    body, its source), so the program error is reported and nothing leaks.
    The claim was already given back: raising with the claim taken would
    leave the job's error answer unable to claim, the client without a
    response and the body never released. }
  if DbgClaimRefusedFlag then
  begin
    DbgClaimRefusedFlag := False;
    Assert(False,
      'TExchange: the terminal call is made by another thread than the one that built the response head');
  end;
end;
{$endif}

function TExchange.GetStatus: Word;
begin
  {$ifopt C+}
  DbgLoopOnly;
  {$endif}
  Result := Resp.Head.Status;
end;

procedure TExchange.SetStatus(V: Word);
begin
  {$ifopt C+}
  DbgHeadWrite;
  {$endif}
  Resp.Head.Status := V;
end;

function TExchange.GetRespVersion: THttpVersion;
begin
  {$ifopt C+}
  DbgLoopOnly;
  {$endif}
  Result := Resp.Head.Version;
end;

procedure TExchange.SetRespVersion(V: THttpVersion);
begin
  {$ifopt C+}
  DbgHeadWrite;
  {$endif}
  Resp.Head.Version := V;
end;

{ ---- request head ---- }

function TExchange.Method: THttpMethod;
begin
  {$ifopt C+}
  DbgLoopOnly;
  {$endif}
  Result := Head.Method;
end;

function TExchange.MethodBytes: TByteSlice;
begin
  {$ifopt C+}
  DbgLoopOnly;
  {$endif}
  Result.P := Head.View.P + Head.MethodSlice.Off;
  Result.Len := Head.MethodSlice.Len;
end;

function TExchange.Target: TByteSlice;
begin
  {$ifopt C+}
  DbgLoopOnly;
  {$endif}
  Result.P := Head.View.P + Head.Target.Off;
  Result.Len := Head.Target.Len;
end;

function TExchange.Path: TByteSlice;
begin
  {$ifopt C+}
  DbgLoopOnly;
  {$endif}
  Head.Uri.GetPath(Head.View.P, Result.P, Result.Len);
end;

function TExchange.Query(out Q: TByteSlice): Boolean;
begin
  {$ifopt C+}
  DbgLoopOnly;
  {$endif}
  Result := Head.Uri.GetQuery(Head.View.P, Q.P, Q.Len);
  if not Result then
  begin
    Q.P := nil;
    Q.Len := 0;
  end;
end;

function TExchange.Version: THttpVersion;
begin
  {$ifopt C+}
  DbgLoopOnly;
  {$endif}
  Result := Head.Version;
end;

function TExchange.Headers: THttpHeaders;
begin
  {$ifopt C+}
  DbgLoopOnly;
  {$endif}
  Result := Head.Headers;
end;

function TExchange.Header(const Name: RawByteString; out V: TByteSlice): Boolean;
begin
  {$ifopt C+}
  DbgLoopOnly;
  {$endif}
  Result := Head.Headers.Get(Name, V.P, V.Len);
  if not Result then
  begin
    V.P := nil;
    V.Len := 0;
  end;
end;

function TExchange.ContentLength: Int64;
begin
  {$ifopt C+}
  DbgLoopOnly;
  {$endif}
  Result := Head.ContentLength;
end;

function TExchange.ExpectsContinue: Boolean;
begin
  {$ifopt C+}
  DbgLoopOnly;
  {$endif}
  Result := Head.ExpectContinue;
end;

function TExchange.WantsUpgrade: Boolean;
begin
  {$ifopt C+}
  DbgLoopOnly;
  {$endif}
  Result := Head.WantsUpgrade;
end;

function TExchange.ConnId: QWord;
begin
  {$ifopt C+}
  DbgLoopOnly;
  {$endif}
  Result := Head.ConnId;
end;

function TExchange.RequestNo: LongWord;
begin
  {$ifopt C+}
  DbgLoopOnly;
  {$endif}
  Result := Head.RequestNo;
end;

function TExchange.PeerAddr: PSockAddrStorage;
begin
  {$ifopt C+}
  DbgLoopOnly;
  {$endif}
  Result := @Head.Peer;
end;

procedure TExchange.ReleaseRequest;
begin
  { the body receiver closes and the head is unpinned; an upgrade slot
    nobody called OnUpgrade for is marked as unwanted (RxAlive False) }
  if FShared then
  begin
    ReleaseRequestShared;
    Exit;
  end;
  Assert(OnOwnLoop, 'TExchange.ReleaseRequest: an unshared exchange off its loop thread');
  if Head.Released then
    Exit;
  Head.Released := True;
  if Chan.Active then
    Chan.CloseReceiver;
  if Head.View.Block <> nil then
    PoisonAndRelease(Head.View)
  else
    ClearView(Head.View);
  if (FUpgrade <> nil) and (FUpgrade.Handler = nil) then
    FUpgrade.RxAlive := False;
end;

{ ---- request body ---- }

function TExchange.TryRead(out Chunk: TByteSlice): TBodyReadStatus;
var
  V: TBytesView;
  E: THyperError;
begin
  Assert(not FInServiceCall, 'TExchange.TryRead called inside THttpService.Call: Call must not answer or read the body');
  if FShared then
    Exit(TryReadShared(Chunk));
  Assert(OnOwnLoop, 'TExchange.TryRead: an unshared exchange off its loop thread');
  Chunk.P := nil;
  Chunk.Len := 0;
  if FState = Ord(xsCanceled) then
    Exit(brCanceled);
  if not Chan.Active then
    Exit(brEnd);                         { a request without a body: its end is real }
  if not Chan.ReceiverOpen then
  begin
    { a receiver closed before the reader saw the end (the request was
      released: call completion, ReleaseRequest, DiscardBody) is not the end
      of the body. A response source on the loop that reads the body after
      the completion gets brCanceled, not a clean end with bytes missing; to
      read the body there, the call must hold the request with Share in its
      Poll }
    if Chan.Terminated then
      Exit(brEnd);
    Exit(brCanceled);
  end;
  { the previous chunk is released by the next body call }
  if Chan.Held.Block <> nil then
    Chan.Held.Release;
  case Chan.PollNext(V, E) of
    cnData:
      begin
        Chan.Held := V;
        Chunk.P := V.P;
        Chunk.Len := V.Len;
        Result := brData;
      end;
    cnError:
      begin
        FBodyErr := E;
        Result := brError;
      end;
    cnPending:
      Result := brPending;
  else
    { the end: the trailers first, if there are any }
    if Chan.TakeTrailers then
      Result := brTrailers
    else
      Result := brEnd;
  end;
end;

function TExchange.TryReadShared(out Chunk: TByteSlice): TBodyReadStatus;
var
  V: TBytesView;
  E: THyperError;
  W, U, Loop_: Boolean;
begin
  { TryRead on a shared exchange: the same steps under Chan.Lock; the
    previous chunk goes back through ToRelease when a worker calls }
  Chunk.P := nil;
  Chunk.Len := 0;
  Loop_ := OnOwnLoop;
  {$ifopt C+}
  if Assigned(TryReadTestHook) then
    TryReadTestHook(Self);
  {$endif}
  Chan.Lock.Acquire;
  { the state is read under the lock: CancelShared's CAS
    comes before its CloseBodyFromLoop takes the lock, so a reader that
    finds the receiver closed by a cancel also finds xsCanceled here and
    raises EClientGone instead of taking the close for the body's end }
  if AtomicLoad(FState) = Ord(xsCanceled) then
  begin
    Chan.Lock.Release;
    HappensAfter(@FState);
    Exit(brCanceled);
  end;
  if not Chan.Active then
  begin
    { a request without a body: its end is real }
    Chan.Lock.Release;
    Exit(brEnd);
  end;
  if not Chan.ReceiverOpen then
  begin
    { a receiver that was closed before this reader saw the end
      (Terminated) is not the end of the body. That is a cancel (the state
      check above), or a holder's ReleaseRequest, DiscardBody or last
      Release while the body was still open: the read reports brCanceled
      (EClientGone), never brEnd. The check uses the channel's own state for
      this request (Open resets Terminated), so it cannot outlive the
      request the way a flag kept across the recycle could }
    if Chan.Terminated then
      Result := brEnd
    else
      Result := brCanceled;
    Chan.Lock.Release;
    Exit;
  end;
  Chan.DropView(Chan.Held);
  FHeldPos := 0;
  Chan.ParkingReceiver := not Loop_;
  case Chan.PollNext(V, E) of
    cnData:
      begin
        Chan.Held := V;
        Chunk.P := V.P;
        Chunk.Len := V.Len;
        Result := brData;
      end;
    cnError:
      begin
        FBodyErr := E;
        Result := brError;
      end;
    cnPending:
      Result := brPending;
  else
    if Chan.TakeTrailers then
      Result := brTrailers
    else
      Result := brEnd;
  end;
  Chan.TakeDeferred(W, U);
  Chan.Lock.Release;
  Chan.RunDeferred(W, U);
end;

procedure TExchange.BlockOnBody;
begin
  { a blocking read parks only a thread that is not the loop: the loop
    would wait for itself }
  if (not FShared) or OnOwnLoop then
    raise Exception.Create('TExchange: a blocking body read on the loop thread (use TryRead)');
  Chan.Parker.Park;
end;

procedure TExchange.RaiseBodyError;
var
  E: EBodyError;
begin
  E := EBodyError.Create(BodyErrorMessage);
  E.Kind := BodyErrorKind;
  raise E;
end;

function TExchange.ReadChunk(out Chunk: TByteSlice): Boolean;
begin
  { what Read left of the held chunk comes first }
  if (FHeldPos > 0) and (FHeldPos < Chan.Held.Len) then
  begin
    Chunk.P := Chan.Held.P + FHeldPos;
    Chunk.Len := Chan.Held.Len - FHeldPos;
    FHeldPos := Chan.Held.Len;
    Exit(True);
  end;
  while True do
    case ReadFrame(Chunk) of
      brData:
        Exit(True);
      brTrailers:
        ;                                 { RequestTrailers holds them; the end follows }
      brEnd:
        Exit(False);
      brError:
        RaiseBodyError;
    else
      if IsCanceled then
        raise EClientGone.Create('client gone')
      else
        { shared exchange: a holder released the request before its body
          ended }
        raise EClientGone.Create('the request was released before its body ended');
    end;
end;

function TExchange.ReadFrame(out Chunk: TByteSlice): TBodyReadStatus;
begin
  while True do
  begin
    Result := TryRead(Chunk);
    if Result <> brPending then
      Break;
    BlockOnBody;                          { the loop unparks: slot filled, closed, error, cancel }
  end;
  if Result = brData then
    FHeldPos := Chunk.Len;
end;

function TExchange.Read(Buf: PByte; Max: SizeInt): SizeInt;
var
  C: TByteSlice;
begin
  if Max <= 0 then
    Exit(0);
  if FHeldPos >= Chan.Held.Len then
  begin
    if not ReadChunk(C) then
      Exit(0);
    FHeldPos := Chan.Held.Len - C.Len;
  end;
  Result := Chan.Held.Len - FHeldPos;
  if Result > Max then
    Result := Max;
  Move((Chan.Held.P + FHeldPos)^, Buf^, Result);
  Inc(FHeldPos, Result);
end;

function TExchange.ReadAll(var Dst: TBytes; Limit: SizeInt): SizeInt;
var
  C: TByteSlice;
  Start: SizeInt;
begin
  { appends the whole body to Dst; Limit > 0: EBodyTooLarge above Limit bytes }
  if (Limit > 0) and (Head.ContentLength > Limit) then
    raise EBodyTooLarge.CreateFmt('request body of %d bytes is over the limit of %d',
      [Head.ContentLength, Limit]);
  Start := Length(Dst);
  Result := 0;
  while ReadChunk(C) do
  begin
    if (Limit > 0) and (Result + C.Len > Limit) then
      raise EBodyTooLarge.CreateFmt('request body is over the limit of %d bytes', [Limit]);
    SetLength(Dst, Start + Result + C.Len);
    Move(C.P^, Dst[Start + Result], C.Len);
    Inc(Result, C.Len);
  end;
end;

procedure TExchange.DiscardBody;
var
  W, U: Boolean;
begin
  { closes the receiver only (the head stays). The loop-thread check comes
    first, so it covers a request without a body too }
  {$ifopt C+}
  DbgLoopOnly;
  {$endif}
  if not Chan.Active then
    Exit;
  if not FShared then
  begin
    Chan.CloseReceiver;
    Exit;
  end;
  Chan.Lock.Acquire;
  Chan.CloseReceiver;
  Chan.TakeDeferred(W, U);
  Chan.Lock.Release;
  Chan.RunDeferred(W, U);
end;

function TExchange.RequestTrailers: THttpHeaders;
begin
  {$ifopt C+}
  DbgLoopOnly;
  {$endif}
  Result := ReqTrailers;
end;

function TExchange.BodyErrorKind: TBodyErrorKind;
begin
  {$ifopt C+}
  DbgLoopOnly;
  {$endif}
  { the classes of conformance/SPEC.md 7.1 }
  case FBodyErr.Cause of
    ecDecode:
      case DecodeErrorKind(FBodyErr.Decode) of
        iekUnexpectedEof: Result := bekUnexpectedEof;
        iekInvalidData: Result := bekInvalidData;
        iekInvalidInput: Result := bekInvalidInput;
      else
        Result := bekIo;
      end;
    ecErrno: Result := bekIo;
  else
    Result := bekOther;
  end;
end;

function TExchange.BodyErrorIsTimeout: Boolean;
begin
  Result := (FBodyErr.Kind = hekBody) and (FBodyErr.Cause = ecErrno) and (FBodyErr.Errno = ESysETIMEDOUT);
end;

function TExchange.BodyErrorMessage: string;
begin
  {$ifopt C+}
  DbgLoopOnly;
  {$endif}
  { the decoder's text, the errno's text, or the error's description }
  case FBodyErr.Cause of
    ecDecode: Result := DecodeErrorMessage(FBodyErr.Decode);
    ecErrno: Result := SysErrorMessage(FBodyErr.Errno) + ' (os error ' + IntToStr(FBodyErr.Errno) + ')';
  else
    Result := ErrorDescription(FBodyErr, '');
  end;
end;

{ ---- response head ---- }

function TExchange.SetReason(P: PByte; Len: SizeInt): Boolean;
var
  Bad: Byte;
begin
  { the bytes are checked, then copied }
  {$ifopt C+}
  DbgHeadWrite;
  {$endif}
  if FindInvalidReasonByte(P, Len, Bad) then
    Exit(False);
  FReasonBuf.Clear;
  if Len > 0 then
    FReasonBuf.Append(P, Len, nil);
  Resp.Head.HasReason := True;
  Resp.Head.ReasonP := FReasonBuf.Data;
  Resp.Head.ReasonLen := Len;
  Result := True;
end;

function TExchange.ResponseHeaders: THttpHeaders;
begin
  { the list is read and written through this accessor: on a shared
    exchange the check applies while the response is not claimed (the
    loop reads the head after the answer) }
  {$ifopt C+}
  if (not FShared) or (AtomicLoad(FAnswerClaim) = 0) then
    DbgHeadWrite;
  {$endif}
  Result := Resp.Head.Headers;
end;

{ ---- terminal calls (unshared exchange: plain stores) ---- }

function TExchange.Respond(const Body: TBodyData): Boolean;
var
  B: TBodyData;
begin
  Assert(not FInServiceCall, 'TExchange.Respond called inside THttpService.Call: Call must not answer or read the body');
  if FShared then
    Exit(RespondShared(Body));
  Assert(OnOwnLoop, 'TExchange.Respond: an unshared exchange off its loop thread');
  if FState <> Ord(xsCalled) then
  begin
    { the response is dropped: so is its body }
    B := Body;
    ReleaseBody(B);
    Exit(False);
  end;
  Resp.Body := Body;
  Resp.Source := nil;
  FState := Ord(xsAnswered);
  Result := True;
end;

function TExchange.RespondStream(Source: TBodySource): Boolean;
begin
  Assert(not FInServiceCall, 'TExchange.RespondStream called inside THttpService.Call: Call must not answer or read the body');
  if FShared then
    Exit(RespondStreamShared(Source));
  Assert(OnOwnLoop, 'TExchange.RespondStream: an unshared exchange off its loop thread');
  if FState <> Ord(xsCalled) then
  begin
    if Source <> nil then
      Source.Done(Self);
    Exit(False);
  end;
  Resp.Body := BodyEmpty;
  Resp.Source := Source;
  FState := Ord(xsAnswered);
  Result := True;
end;

function TExchange.BeginStream(HighWater: SizeInt): Boolean;
var
  C: TChannelBody;
begin
  { RespondStream(TChannelBody): the exchange's own channel. It is created by
    the thread of the first stream (a worker, on a shared exchange) and read
    by the loop thread (CancelShared, ReleaseTransport) and other producers:
    published with an atomic store after its construction }
  Assert(not FInServiceCall, 'TExchange.BeginStream called inside THttpService.Call: Call must not answer or read the body');
  if FShared then
  begin
    { the claim comes before the channel is touched: a losing call must
      not reset the winner's channel }
    if not ClaimAnswer(True) then
    begin
      {$ifopt C+}
      DbgClaimRefused;
      {$endif}
      Exit(False);
    end;
  end
  else
  begin
    {$ifopt C+}
    DbgLoopOnly;
    {$endif}
    if FState <> Ord(xsCalled) then
      Exit(False);
  end;
  C := TChannelBody(AtomicLoadPtr(Pointer(FChannel)));
  if C = nil then
  begin
    C := TChannelBody.Create(HighWater);
    HappensBefore(@FChannel);
    AtomicStorePtr(Pointer(FChannel), C);
  end;
  C.Reset(Self, HighWater);
  if FShared then
    Result := PublishStream(C)
  else
    Result := RespondStream(C);
end;

function TExchange.Fail(const Msg: RawByteString): Boolean;
begin
  { the handler failed: Msg becomes the connection's error text }
  Assert(not FInServiceCall, 'TExchange.Fail called inside THttpService.Call: Call must not answer or read the body');
  if FShared then
    Exit(FailShared(Msg, True));
  Assert(OnOwnLoop, 'TExchange.Fail: an unshared exchange off its loop thread');
  if FState <> Ord(xsCalled) then
    Exit(False);
  Resp.Failed := True;
  Resp.FailText := Msg;
  FState := Ord(xsAnswered);
  Result := True;
end;

{ ---- terminal calls on a shared exchange: the first call claims the
  response slot (FAnswerClaim, a CAS), so a second terminal call from
  another thread leaves the slot alone and returns False; the claimer
  writes the response fields, then one CAS on FState
  publishes them (a full barrier). Cancel's CAS on the loop is the other
  contender for FState. A call that loses either CAS writes nothing the loop
  may read. ---- }

function TExchange.ClaimAnswer(CheckHead: Boolean): Boolean;
begin
  Result := (AtomicLoad(FState) = Ord(xsCalled))
    and (InterlockedCompareExchange(FAnswerClaim, 1, 0) = 0);
  {$ifopt C+}
  if Result and CheckHead and not DbgHeadClaimOk then
  begin
    { the head was built by another thread: the claim is given back, so
      the job's error
      answer (HandlerRaised) can still claim; the caller releases what it
      carried and then raises (DbgClaimRefused) }
    InterLockedExchange(FAnswerClaim, 0);
    DbgClaimRefusedFlag := True;
    Result := False;
  end;
  {$endif}
end;

function TExchange.RespondShared(const Body: TBodyData): Boolean;
var
  B: TBodyData;
begin
  if not ClaimAnswer(True) then
  begin
    B := Body;
    ReleaseBody(B);
    {$ifopt C+}
    DbgClaimRefused;
    {$endif}
    Exit(False);
  end;
  {$ifopt C+}
  if Assigned(AnswerTestHook) then
    AnswerTestHook(Self);
  {$endif}
  Resp.Body := Body;
  Resp.Source := nil;
  HappensBefore(@FState);
  if InterlockedCompareExchange(FState, Ord(xsAnswered), Ord(xsCalled)) <> Ord(xsCalled) then
  begin
    B := Resp.Body;
    Resp.Body := BodyEmpty;
    ReleaseBody(B);
    Exit(False);
  end;
  Wake;
  Result := True;
end;

function TExchange.RespondStreamShared(Source: TBodySource): Boolean;
begin
  if not ClaimAnswer(True) then
  begin
    if Source <> nil then
      Source.Done(Self);
    {$ifopt C+}
    DbgClaimRefused;
    {$endif}
    Exit(False);
  end;
  Result := PublishStream(Source);
end;

function TExchange.PublishStream(Source: TBodySource): Boolean;
begin
  { the slot is claimed (ClaimAnswer) }
  {$ifopt C+}
  if Assigned(AnswerTestHook) then
    AnswerTestHook(Self);
  {$endif}
  Resp.Body := BodyEmpty;
  Resp.Source := Source;
  HappensBefore(@FState);
  if InterlockedCompareExchange(FState, Ord(xsAnswered), Ord(xsCalled)) <> Ord(xsCalled) then
  begin
    Resp.Source := nil;
    if Source <> nil then
      Source.Done(Self);
    Exit(False);
  end;
  Wake;
  Result := True;
end;

function TExchange.FailShared(const Msg: RawByteString; CheckHead: Boolean): Boolean;
begin
  if not ClaimAnswer(CheckHead) then
  begin
    {$ifopt C+}
    DbgClaimRefused;
    {$endif}
    Exit(False);
  end;
  {$ifopt C+}
  if Assigned(AnswerTestHook) then
    AnswerTestHook(Self);
  {$endif}
  Resp.Failed := True;
  Resp.FailText := Msg;
  HappensBefore(@FState);
  if InterlockedCompareExchange(FState, Ord(xsAnswered), Ord(xsCalled)) <> Ord(xsCalled) then
    Exit(False);                        { canceled: nobody reads the slot before the recycle }
  Wake;
  Result := True;
end;

{ ---- the stream writer (after BeginStream; any thread holding the exchange) ---- }

function TExchange.StreamWriter: TChannelBody;
begin
  { the exchange's channel, whether or not this request began a stream on
    it: Push, FinishStream and AbortWith check under the channel's lock that
    it is active (Ended), so an inactive channel refuses the call there
    (reading FActive here, without the lock, would race with Reset and
    Deactivate) }
  Result := TChannelBody(AtomicLoadPtr(Pointer(FChannel)));
  if Result <> nil then
    HappensAfter(@FChannel);
end;

function CopyFrame(P: PByte; Len: SizeInt): TBodyData;
var
  M: Pointer;
begin
  GetMem(M, Len);
  Move(P^, M^, Len);
  Result := BodyHeap(M, Len);
end;

function TExchange.Write(P: PByte; Len: SizeInt): TWriteResult;
var
  C: TChannelBody;
  B: TBodyData;
begin
  { parks while HighWater bytes are queued; on the loop thread it cannot
    park (the loop drains the channel): TryWrite }
  {$ifopt C+}
  DbgLoopOnly;
  {$endif}
  C := StreamWriter;
  if C = nil then
    Exit(wrCanceled);
  if Len <= 0 then
    Exit(C.EmptyWrite);
  B := CopyFrame(P, Len);
  Result := C.Push(B, not OnOwnLoop);
end;

function TExchange.TryWrite(P: PByte; Len: SizeInt): TWriteResult;
var
  C: TChannelBody;
  B: TBodyData;
begin
  {$ifopt C+}
  DbgLoopOnly;
  {$endif}
  C := StreamWriter;
  if C = nil then
    Exit(wrCanceled);
  if Len <= 0 then
    Exit(C.EmptyWrite);
  B := CopyFrame(P, Len);
  Result := C.Push(B, False);
end;

function TExchange.WriteString(const S: RawByteString): TWriteResult;
var
  C: TChannelBody;
  B: TBodyData;
begin
  {$ifopt C+}
  DbgLoopOnly;
  {$endif}
  C := StreamWriter;
  if C = nil then
    Exit(wrCanceled);
  if Length(S) = 0 then
    Exit(C.EmptyWrite);
  B := BodyString(S);
  Result := C.Push(B, not OnOwnLoop);
end;

function TExchange.Finish(Trailers: THttpHeaders): Boolean;
var
  C: TChannelBody;
begin
  {$ifopt C+}
  DbgLoopOnly;
  {$endif}
  C := StreamWriter;
  if C = nil then
    Exit(False);
  Result := C.FinishStream(Trailers);
end;

procedure TExchange.AbortStream(const Msg: RawByteString);
var
  C: TChannelBody;
begin
  {$ifopt C+}
  DbgLoopOnly;
  {$endif}
  C := StreamWriter;
  if C <> nil then
    C.AbortWith(Msg);
end;

{ ---- upgrades ---- }

procedure TExchange.OnUpgrade(H: TUpgradeHandler);
begin
  { a request that did not ask for an upgrade has no slot: the handler is
    told at once ('no upgrade available') }
  Assert(OnOwnLoop, 'TExchange.OnUpgrade: not on the loop thread');
  if FUpgrade = nil then
  begin
    if H <> nil then
      H.UpgradeFailed(NO_UPGRADE_MSG);
    Exit;
  end;
  FUpgrade.Handler := H;
  FUpgrade.RxAlive := True;
end;

{ ---- execution and lifetime ---- }

function TExchange.OnLoopThread: Boolean;
begin
  Result := not FShared;
end;

procedure RaisePoolStopped;
begin
  raise EWorkerPoolStopped.Create('TExchange.Offload: the worker pool is shut down');
end;

procedure TExchange.Offload(Pool: TWorkerPool; H: TBlockingHandler);
begin
  { loop thread, from the call's Poll: the worker gets its own reference
    (Share) and the exchange is queued as the work item }
  Assert(OnOwnLoop, 'TExchange.Offload: not on the loop thread');
  if H = nil then
    raise Exception.Create('TExchange.Offload: no handler');
  { one Offload per request: a second one would replace the handler of the
    job already submitted and submit the exchange, which is itself the
    queue node, again (a self-link in the pool's queue while the first
    submission is queued). Raised in every build: it costs one compare on
    the offload path, and the exception aborts the connection task (see
    bearings.rt.loop) }
  if FHandler <> nil then
    raise Exception.Create('TExchange.Offload: the request was already offloaded');
  FHandler := H;
  Share;
  if not Pool.TrySubmit(Self) then
  begin
    { the pool is shut down: the reference goes back, the call stays
      unanswered; the exception aborts the connection task }
    FHandler := nil;
    InterLockedDecrement(FHolders);      { the call still holds the request: never 0 here }
    InterLockedDecrement(FRefCount);
    RaisePoolStopped;
  end;
end;

function TExchange.Share: TExchange;
var
  N: LongInt;
begin
  { loop thread, before the reference is published. A shared
    exchange is recycled into its pool on its loop by the last Release, so
    it must come from the loop's pool (Loop.Exchanges), which outlives the
    connection. }
  Assert(OnOwnLoop, 'TExchange.Share: not on the loop thread');
  if (FHomePool <> nil) and ((FLoop = nil) or (Pointer(FHomePool) <> FLoop.Exchanges)) then
    raise Exception.Create('TExchange.Share: the exchange is not from its loop''s pool');
  if not FShared then
  begin
    { the first Share: the call in flight is the request's first holder,
      released by CompleteShared or CancelShared. No other thread holds the
      exchange yet: plain stores }
    if (FState <> Ord(xsCalled)) and (FState <> Ord(xsAnswered)) then
      raise Exception.Create('TExchange.Share: no call in flight');
    FHolders := 2;                       { the call and the reference returned here }
    FShared := True;                     { a second Share (another producer) leaves it: workers read it }
  end
  else
    { another holder: only a holder (or the call in flight) may share, so
      the count is at least 1 and the request is not released. A count of
      0 means the request is gone: the new holder would read a released
      head }
    repeat
      N := AtomicLoad(FHolders);
      if N <= 0 then
        raise Exception.Create('TExchange.Share: the request was released by its last holder');
    until InterlockedCompareExchange(FHolders, N + 1, N) = N;
  InterLockedIncrement(FRefCount);
  Result := Self;
end;

procedure TExchange.Release;
var
  N: LongInt;
begin
  { The producers of the exchange's response stream are its holders: the
    references Share handed out and the call in flight. The holder
    decrement that reaches 0 (DropHolder) releases the request and ends a
    stream left open. That decrement is the one place this is decided, and
    a count of 0 is final (Share refuses to raise it), so no later Share
    can bring a producer back. Deciding instead on a reference count loaded
    earlier and decremented later with a CAS would be wrong, because a CAS
    compares values only: the count may go 2 -> 3 -> 2 in between (an
    Offload whose worker began a stream, wrote and released), the CAS
    succeeds after a decision made on a stale value, and nobody ends the
    stream. Both steps run BEFORE this reference goes: once the reference
    count is decremented, the transport may recycle the exchange and a new
    request may begin a new stream on the same object, so after the
    decrement this routine touches the exchange only when it took the
    count to 0. }
  Assert(FShared, 'TExchange.Release: the exchange was not shared');
  DropHolder;
  { the happens-before edge (for valgrind drd) is announced after
    everything this reference did, the end of the stream (and the wake it
    may post) included }
  HappensBefore(@FRefCount);
  {$ifopt C+}
  if Assigned(ReleaseBeforeDecrementHook) then
    ReleaseBeforeDecrementHook(Self);
  {$endif}
  N := InterLockedDecrement(FRefCount);
  {$ifopt C+}
  if Assigned(ReleaseTestHook) then
    ReleaseTestHook(Self, N);            { tests: the window after the decrement }
  {$endif}
  if N = 0 then
  begin
    HappensAfter(@FRefCount);
    if OnOwnLoop then
      FinalRelease
    else
      FLoop.Post(@FreeMsg);              { FIFO after a WakeMsg this thread posted }
  end;
end;

procedure TExchange.DropHolder;
var
  C: TChannelBody;
begin
  { the holder count (the call in flight and the references Share gave
    out) goes down by one; the decrement that takes it to 0 releases the
    request and ends the exchange's stream if it is still open. A stream
    already finished, aborted or dropped by the transport, or a
    channel of an earlier request (inactive), is left alone (AutoFinish
    checks it under the channel's lock). The caller still holds a reference
    (or is the loop with the transport's), so the exchange is not recycled
    meanwhile. }
  HappensBefore(@FHolders);
  if InterLockedDecrement(FHolders) = 0 then
  begin
    HappensAfter(@FHolders);
    ReleaseRequestShared;
    C := TChannelBody(AtomicLoadPtr(Pointer(FChannel)));
    if C <> nil then
    begin
      HappensAfter(@FChannel);
      C.AutoFinish;
    end;
  end;
end;

procedure TExchange.FinalRelease;
begin
  { loop thread, the last reference went. A queued WakeMsg still points
    here: the recycle waits until it is handled (ExchangeWakeMsg) }
  if AtomicLoad(FWakeQueued) <> 0 then
  begin
    FFreePending := True;
    Exit;
  end;
  if FHomePool <> nil then
    FHomePool.Give(Self)
  else
    Recycle;
end;

procedure TExchange.ReleaseTransport;
var
  S: LongInt;
  C: TChannelBody;
begin
  if not FShared then
  begin
    if FHomePool <> nil then
      FHomePool.Give(Self)
    else
      Recycle;
    Exit;
  end;
  FOwner := nil;
  { an answer the dispatcher never took (the connection ended between the
    worker's CAS and the next poll): its stream producer must stop. Resp.Source
    is read only after the answer was seen (the acquire on FState first) }
  S := AtomicLoad(FState);
  if (S = Ord(xsAnswered)) or (S = Ord(xsDone)) then
  begin
    HappensAfter(@FState);
    if Resp.Source <> nil then
    begin
      Resp.Source.Done(Self);
      Resp.Source := nil;
    end;
  end;
  C := TChannelBody(AtomicLoadPtr(Pointer(FChannel)));
  if C <> nil then
    HappensAfter(@FChannel);
  HappensBefore(@FRefCount);
  if InterLockedDecrement(FRefCount) = 0 then
  begin
    HappensAfter(@FRefCount);
    FinalRelease;
  end
  else if C <> nil then
    { the stream of this request ended or was dropped; a producer still
      parked must see it }
    C.WakeProducer;
end;

procedure TExchange.Wake;
begin
  { unshared, or a call on the loop thread: the owner task's local wake.
    Another thread: WakeMsg through the loop's inbox, at most one queued
    (FWakeQueued) }
  { debug check: a recycled exchange (state xsIdle until the next
    BeginRequest) is never woken, and an unshared one only on its loop (a
    stale off-loop caller of a reused exchange fails here) }
  Assert(FState <> Ord(xsIdle), 'TExchange.Wake: the exchange was recycled');
  if (not FShared) or OnOwnLoop then
  begin
    Assert(OnOwnLoop, 'TExchange.Wake: an unshared exchange off its loop thread');
    if FOwner <> nil then
      FOwner.Wake;
    Exit;
  end;
  if InterlockedCompareExchange(FWakeQueued, 1, 0) = 0 then
  begin
    { the loop reset FWakeQueued after it took WakeMsg off the inbox: the
      node may be pushed again }
    HappensAfter(@FWakeQueued);
    {$ifopt C+}
    { the message carries the generation it was posted for;
      ExchangeWakeMsg checks it (the exchange is not recycled while its
      WakeMsg is queued) }
    FWakeGen := FGen;
    {$endif}
    FLoop.Post(@WakeMsg);
  end;
end;

function TExchange.IsCanceled: Boolean;
begin
  {$ifopt C+}
  DbgLoopOnly;
  {$endif}
  Result := AtomicLoad(FState) = Ord(xsCanceled);
  if Result then
    HappensAfter(@FState);
end;

function TExchange.Answered: Boolean;
var
  S: LongInt;
begin
  {$ifopt C+}
  DbgLoopOnly;
  {$endif}
  S := AtomicLoad(FState);
  Result := (S = Ord(xsAnswered)) or (S = Ord(xsDone));
  if Result and FShared then
  begin
    ReadBarrier;
    HappensAfter(@FState);
  end;
end;

{ ---- shared exchange: loop-side housekeeping ---- }

procedure TExchange.SyncShared;
var
  V: TBytesView;
  Rel: Boolean;
begin
  { loop thread: unpin what the handler handed back (ToRelease) and a head it
    released (Head.Released), then mark an untaken upgrade slot unwanted }
  ClearView(V);
  Chan.Lock.Acquire;
  Chan.ReleaseToRelease;
  Rel := Head.Released;
  if Rel and (Head.View.Block <> nil) then
  begin
    V := Head.View;
    ClearView(Head.View);
  end;
  Chan.Lock.Release;
  if V.Block <> nil then
    PoisonAndRelease(V);
  if Rel and (FUpgrade <> nil) and (FUpgrade.Handler = nil) then
    FUpgrade.RxAlive := False;
end;

procedure TExchange.CloseBodyFromLoop;
var
  W, U: Boolean;
begin
  if not Chan.Active then
    Exit;
  Chan.Lock.Acquire;
  Chan.CloseReceiverFromLoop;
  Chan.TakeDeferred(W, U);
  Chan.Lock.Release;
  Chan.RunDeferred(W, U);
end;

procedure TExchange.ReleaseRequestShared;
var
  W, U: Boolean;
begin
  { ReleaseRequest on a shared exchange: the receiver closes now; the head's
    pin goes on the loop (SyncShared), which is woken for it }
  Chan.Lock.Acquire;
  if Head.Released then
  begin
    Chan.Lock.Release;
    Exit;
  end;
  Head.Released := True;
  if Chan.Active then
    Chan.CloseReceiver;
  Chan.TakeDeferred(W, U);
  Chan.Lock.Release;
  Chan.RunDeferred(W, U);
  if OnOwnLoop then
    SyncShared
  else
    Wake;
end;

procedure TExchange.CompleteShared;
begin
  { the call completed on a shared exchange: it gives up its holder of the
    request. The request is released here only when no reference Share
    gave out still holds it; otherwise the body receiver stays open and the
    dispatcher keeps feeding it (a worker may read the body after its
    answer, for example BeginStream, then ReadChunk and Write) until the
    handler's ReleaseRequest or the last holder's Release. The head stays
    pinned while a holder may still read it }
  SyncShared;
  if (FUpgrade <> nil) and (FUpgrade.Handler = nil) then
    FUpgrade.RxAlive := False;
  if InterlockedCompareExchange(FState, Ord(xsDone), Ord(xsCalled)) = Ord(xsCalled) then
    NoResponse
  else if AtomicLoad(FState) = Ord(xsAnswered) then
    InterlockedExchange(FState, Ord(xsDone));
  DropHolder;
end;

procedure TExchange.CancelShared;
var
  C: TChannelBody;
begin
  { Cancel on a shared exchange: a CAS against the handler's terminal
    call. When the cancel wins, the receiver closes for the handler and a
    worker parked in a body read or a stream write is woken (it sees
    EClientGone / wrCanceled). When the handler's answer won (the
    connection ended between the answer and the dispatcher's poll), the
    request stays with its holders as after a completion: right after this
    the dispatcher closes the body's sender with an incomplete-message
    error, so a reader gets the chunks that arrived and then EBodyError,
    or the end the body really had; the same as when the connection ends
    after the completion. Either way the call gives up its holder
    (DropHolder). The head stays pinned while a holder may read it. }
  HappensBefore(@FState);
  if InterlockedCompareExchange(FState, Ord(xsCanceled), Ord(xsCalled)) = Ord(xsCalled) then
    CloseBodyFromLoop;                   { unparks a reader parked in a body read }
  FOwner := nil;
  SyncShared;
  if (FUpgrade <> nil) and (FUpgrade.Handler = nil) then
    FUpgrade.RxAlive := False;
  C := TChannelBody(AtomicLoadPtr(Pointer(FChannel)));
  if C <> nil then
  begin
    HappensAfter(@FChannel);
    C.WakeProducer;
  end;
  DropHolder;
end;

{ ---- the worker job ---- }

procedure TExchange.HandlerRaised(E: Exception);
var
  Msg: RawByteString;
begin
  Msg := 'handler raised ' + E.ClassName + ': ' + E.Message;
  { the job's own error answer: no head check (it does not use the head;
    the program error, if that is what raised, is in Msg) }
  if not FailShared(Msg, False) then
    { answered with a stream: the body fails (chunked left open) }
    AbortStream(Msg);
end;

procedure TExchange.RunHandler;
begin
  try
    FHandler.Run(Self);
  except
    on E: Exception do
      HandlerRaised(E);
  end;
  if AtomicLoad(FState) = Ord(xsCalled) then
    FailShared('handler returned no response', False);
end;

{$ifopt C+}
procedure TExchange.DbgServiceCall(Inside: Boolean);
begin
  FInServiceCall := Inside;
end;
{$endif}

procedure TExchange.Execute;
begin
  { the worker's reference goes back also when the job's own error path
    raises; a skipped Release would leak the reference, and TServer.Destroy
    would wait WorkerWaitMs and then leak the loops }
  try
    RunHandler;
  finally
    Release;
  end;
end;

procedure TExchange.SetBodyErrorText(const Msg: RawByteString);
begin
  {$ifopt C+}
  DbgLoopOnly;
  {$endif}
  Resp.BodyErrorText := Msg;
end;

function TExchange.Loop: TLoop;
begin
  Result := FLoop;
end;

procedure TExchange.BeginRequest(AOwner: TLoopTask);
begin
  Assert(not FShared, 'TExchange.BeginRequest: a shared exchange cannot be reused for a new request');
  Assert((AOwner = nil) or (AOwner.Loop = nil) or (GetCurrentThreadId = AtomicLoadThreadId(AOwner.Loop.ThreadId)),
    'TExchange.BeginRequest: not on the loop thread');
  FHandler := nil;
  FHeldPos := 0;
  FOwner := AOwner;
  if AOwner <> nil then
    FLoop := AOwner.Loop;
  FState := Ord(xsCalled);
  FAnswerClaim := 0;
  Inc(FGen);
  {$ifopt C+}
  FHeadWriter := nil;
  FInServiceCall := False;               { a Call that raised left it set }
  {$endif}
  FUser := nil;
  FTag := 0;
  if FAttachment <> nil then
    DetachAttachment;
  if FUpgrade <> nil then
    DropUpgrade;
  { no Default(): the FillChar of the whole record was measurable per
    request in profiles; Kind and Cause are what BodyErrorKind / Message read }
  FBodyErr.Kind := hekNone;
  FBodyErr.Cause := ecNone;
  Head.Released := False;
  Head.RequestNo := 0;
  Chan.Active := False;
  Chan.ReceiverOpen := False;
  Chan.SenderOpen := False;
  if Chan.ItemKind = ciData then
  begin
    { both sides of the previous request's channel were closed, which
      released an untaken item (ReleaseItemIfUnowned): unreachable }
    Assert(False, 'BeginRequest: the previous body item is still pinned');
    if Chan.Item.Block <> nil then
      Chan.Item.Release;
  end;
  Chan.ItemKind := ciNone;
  Resp.Head.Version := hv11;
  Resp.Head.Status := 200;
  Resp.Head.HasReason := False;
  Resp.Head.ReasonP := nil;
  Resp.Head.ReasonLen := 0;
  Resp.Head.CaseMap := nil;
  Resp.Head.Headers.Clear;
  Resp.Body := BodyEmpty;
  Resp.Source := nil;
  Resp.Failed := False;
  if Pointer(Resp.FailText) <> nil then
    Resp.FailText := '';
  if Pointer(Resp.BodyErrorText) <> nil then
    Resp.BodyErrorText := '';
  ReqTrailers.Clear;
end;

procedure TExchange.FillHead(const Msg: TParsedRequestHead; const View: TBytesView;
  ARequestNo: LongWord);
begin
  {$ifopt C+}
  DbgLoopOnly;
  {$endif}
  Head.View := View;
  Head.Method := Msg.Method;
  Head.MethodSlice := Msg.MethodSlice;
  Head.Target := Msg.Target;
  Head.Uri := Msg.Uri;
  Head.Version := Msg.Version;
  if Msg.Decode = DECODED_LENGTH_ZERO then
    Head.ContentLength := 0
  else if (Msg.Decode = DECODED_LENGTH_CHUNKED) or (Msg.Decode = DECODED_LENGTH_CLOSE_DELIMITED) then
    Head.ContentLength := -1
  else
    Head.ContentLength := Int64(Msg.Decode);
  Head.ExpectContinue := Msg.ExpectContinue;
  Head.WantsUpgrade := Msg.WantsUpgrade;
  Head.RequestNo := ARequestNo;
  Head.Released := False;
end;

procedure TExchange.LinkUpgrade(S: TUpgradeSlot);
begin
  {$ifopt C+}
  DbgLoopOnly;
  {$endif}
  { the exchange takes its own reference to the slot }
  DropUpgrade;
  if S <> nil then
    S.AddRef;
  FUpgrade := S;
end;

procedure TExchange.DropUpgrade;
var
  S: TUpgradeSlot;
begin
  S := FUpgrade;
  FUpgrade := nil;
  if S <> nil then
    S.Release;
end;

procedure TExchange.DetachAttachment;
var
  A: TExchangeAttachment;
begin
  A := FAttachment;
  FAttachment := nil;
  A.Detach(Self);
end;

procedure TExchange.NoResponse;
begin
  { a call that returned cpReady without a terminal call (a program error
    in the call): treated as the handler failing }
  Resp.Failed := True;
  Resp.FailText := 'handler returned no response';
end;

procedure TExchange.CompleteCall;
begin
  { the call completed: the request it held is released }
  Assert(OnOwnLoop, 'TExchange.CompleteCall: not on the loop thread');
  if FShared then
  begin
    CompleteShared;
    Exit;
  end;
  if not Head.Released then
    ReleaseRequest;
  if FState = Ord(xsCalled) then
    NoResponse;
  FState := Ord(xsDone);
  { the call was the stream's only producer (nobody may write to an
    unshared exchange after its completion): a stream it began and did not
    finish ends here. FChannel is nil on an exchange that never streamed;
    AutoFinish leaves a finished, aborted or inactive channel alone }
  if FChannel <> nil then
    FChannel.AutoFinish;
end;

procedure TExchange.Cancel;
begin
  { the connection abandons the call (client gone, connection error,
    shutdown deadline), and with it the request. The dispatcher calls
    TServiceCall.Drop(Ex, False) itself, right after this, so it runs
    once. }
  Assert(OnOwnLoop, 'TExchange.Cancel: not on the loop thread');
  if FShared then
  begin
    CancelShared;
    Exit;
  end;
  if FState = Ord(xsCalled) then
    FState := Ord(xsCanceled);
  FOwner := nil;
  if not Head.Released then
    ReleaseRequest;
end;

procedure TExchange.Recycle;
begin
  { every pin back, so the read buffer's blocks can be reused. Loop thread;
    a shared exchange gets here only when no other reference is left, so it
    is handled as an unshared one. }
  FShared := False;
  if not Head.Released then
    ReleaseRequest
  else if Head.View.Block <> nil then
    PoisonAndRelease(Head.View);           { released by a worker, not yet unpinned }
  if Chan.Held.Block <> nil then
    Chan.Held.Release;
  if (Chan.ItemKind = ciData) and (Chan.Item.Block <> nil) then
    Chan.Item.Release;
  Chan.ReleaseToRelease;
  FHandler := nil;
  FHeldPos := 0;
  FFreePending := False;
  AtomicStore(FWakeQueued, 0);
  if FChannel <> nil then
    FChannel.Deactivate;
  Chan.ItemKind := ciNone;
  Chan.Active := False;
  ReleaseBody(Resp.Body);
  if Resp.Source <> nil then
  begin
    Resp.Source.Done(Self);
    Resp.Source := nil;
  end;
  Head.Headers.Clear;
  Resp.Head.Headers.Clear;
  ReqTrailers.Clear;
  FOwner := nil;
  DropUpgrade;
  FUser := nil;
  if FAttachment <> nil then
    DetachAttachment;
  FHolders := 0;
  {$ifopt C+}
  FHeadWriter := nil;                    { written only by builds with assertions }
  {$endif}
  FState := Ord(xsIdle);
  Inc(FGen);
end;

{ TWakeTimer }

procedure WakeTimerProc(T: PTimer);
var
  W: PWakeTimer;
begin
  W := PWakeTimer(T^.Owner);
  { a timer armed for an earlier request (or a recycled exchange) wakes nobody }
  if (W^.Target <> nil) and (W^.Target.FGen = W^.Gen) then
    W^.Target.Wake;
end;

procedure TWakeTimer.Arm(Ex: TExchange; DelayMs: Int64);
begin
  if T.Proc = nil then
    TimerInit(@T, @WakeTimerProc, @Self);
  T.Owner := @Self;
  Target := Ex;
  Gen := Ex.FGen;
  Ex.FLoop.Timers.Arm(@T, Ex.FLoop.NowMs + DelayMs);
end;

function TWakeTimer.Fired: Boolean;
begin
  Result := T.Fired;
end;

procedure TWakeTimer.Cancel(Ex: TExchange);
begin
  if T.Proc = nil then
    Exit;
  if (Ex <> nil) and (Ex.FLoop <> nil) then
    Ex.FLoop.Timers.Remove(@T)
  else if (Target <> nil) and (Target.FLoop <> nil) then
    Target.FLoop.Timers.Remove(@T);
  T.Fired := False;
  Target := nil;
end;

{ TBodySource }

function TBodySource.SizeHint(out Exact: QWord): Boolean; begin Exact := 0; Result := False; end;
function TBodySource.IsEndStream: Boolean; begin Result := False; end;
procedure TBodySource.Done(Ex: TExchange); begin end;

{ TChannelBody: a bounded queue of frames under a spin lock. The
  producer (any thread) pushes and parks on FSpace while HighWater bytes are
  queued; the consumer (the dispatcher, loop thread) pops one frame per
  PollFrame. Each side wakes the other only when it registered as waiting
  (FConsumerWaiting: Ex.Wake; FProducerWaiting: FSpace.NotifyAll). The frames
  queued before Finish / AbortStream are delivered first. }

constructor TChannelBody.Create(HighWater: SizeInt);
begin
  inherited Create;
  if HighWater <= 0 then
    HighWater := 65536;
  FHighWater := HighWater;
end;

destructor TChannelBody.Destroy;
begin
  FLock.Acquire;
  DropQueued;
  FLock.Release;
  FTrailers.Free;
  inherited Destroy;
end;

procedure TChannelBody.DropQueued;
var
  B: TBodyData;
begin
  while FCount > 0 do
  begin
    B := FRing[FHead];
    FRing[FHead] := BodyEmpty;
    FHead := (FHead + 1) mod Length(FRing);
    Dec(FCount);
    ReleaseBody(B);
  end;
  FHead := 0;
  FQueued := 0;
end;

procedure TChannelBody.Reset(Ex: TExchange; HighWater: SizeInt);
begin
  if HighWater <= 0 then
    HighWater := 65536;
  FLock.Acquire;
  DropQueued;
  FHighWater := HighWater;
  FEx := Ex;
  FActive := True;
  FFinished := False;
  FFinishing := False;
  FAborted := False;
  FClosed := False;
  FHasTrailers := False;
  FTrailersSent := False;
  FConsumerWaiting := False;
  FProducerWaiting := False;
  { under the lock: AbortWith writes it under the lock from any holder's
    thread (cleared after the release, the two string assignments would
    race and lose or double-release references) }
  if Pointer(FAbortMsg) <> nil then
    FAbortMsg := '';
  FLock.Release;
end;

procedure TChannelBody.Deactivate;
begin
  FLock.Acquire;
  DropQueued;
  FActive := False;
  FClosed := True;
  FEx := nil;
  FLock.Release;
end;

procedure TChannelBody.Grow;
var
  N, I, J: Integer;
  NewRing: array of TBodyData;
begin
  { its own routine: the dynamic-array local's implicit exception frame is
    paid only when the ring grows, not per frame }
  N := Length(FRing) * 2;
  if N < 8 then
    N := 8;
  SetLength(NewRing, N);
  J := FHead;
  for I := 0 to FCount - 1 do
  begin
    NewRing[I] := FRing[J];
    J := (J + 1) mod Length(FRing);
  end;
  FRing := NewRing;
  FHead := 0;
end;

procedure TChannelBody.Enqueue(const B: TBodyData);
begin
  if FCount = Length(FRing) then
    Grow;
  FRing[(FHead + FCount) mod Length(FRing)] := B;
  Inc(FCount);
end;

function TChannelBody.Ended: Boolean;
begin
  Result := FClosed or (not FActive) or FFinished or FFinishing or FAborted;
end;

function TChannelBody.Push(var B: TBodyData; Block: Boolean): TWriteResult;
var
  W: Boolean;
  Ex: TExchange;
  K: LongInt;
begin
  while True do
  begin
    FLock.Acquire;
    if Ended then
    begin
      FLock.Release;
      ReleaseBody(B);
      Exit(wrCanceled);
    end;
    if (FQueued = 0) or (FQueued + B.Len <= FHighWater) then
    begin
      Enqueue(B);
      Inc(FQueued, B.Len);
      B := BodyEmpty;
      W := FConsumerWaiting;
      FConsumerWaiting := False;
      Ex := FEx;
      FLock.Release;
      if W and (Ex <> nil) then
        Ex.Wake;
      Exit(wrOk);
    end;
    if not Block then
    begin
      FLock.Release;
      ReleaseBody(B);
      Exit(wrWouldBlock);
    end;
    { the key is read under the lock: a consumer that frees room (or a
      Done) takes the lock after this, so its NotifyAll changes the key }
    FProducerWaiting := True;
    K := FSpace.Key;
    FLock.Release;
    FSpace.Wait(K);
  end;
end;

function TChannelBody.FinishStream(Trailers: THttpHeaders): Boolean;
var
  W, Has: Boolean;
  Ex: TExchange;
  I: SizeInt;
begin
  { two steps: the first Finish claims the end under the lock (FFinishing:
    other producers' frames, Finish and AbortStream are refused from then
    on), copies the trailers without the lock (the consumer reads FTrailers
    only after it saw FFinished, and no other producer touches it), then
    publishes FFinished under the lock. A Finish that finds the stream
    ended or claimed returns False and touches nothing. }
  FLock.Acquire;
  if Ended then
  begin
    FLock.Release;
    Exit(False);
  end;
  FFinishing := True;
  FLock.Release;
  Has := (Trailers <> nil) and (Trailers.Count > 0);
  if Has then
  begin
    if FTrailers = nil then
      FTrailers := THttpHeaders.Create(4, 256)
    else
      FTrailers.Clear;
    for I := 0 to Trailers.Count - 1 do
      FTrailers.AddTrusted(Trailers.NamePtr(I), Trailers.NameLen(I), Trailers.ValuePtr(I),
        Trailers.ValueLen(I));
  end;
  FLock.Acquire;
  FFinishing := False;
  if FClosed or (not FActive) then
  begin
    { the transport dropped the body meanwhile }
    FLock.Release;
    Exit(False);
  end;
  FFinished := True;
  FHasTrailers := Has;
  W := FConsumerWaiting;
  FConsumerWaiting := False;
  Ex := FEx;
  FLock.Release;
  if W and (Ex <> nil) then
    Ex.Wake;
  Result := True;
end;

function TChannelBody.AbortWith(const Msg: RawByteString): Boolean;
var
  W: Boolean;
  Ex: TExchange;
begin
  FLock.Acquire;
  if Ended then
  begin
    FLock.Release;
    Exit(False);
  end;
  FAborted := True;
  FAbortMsg := Msg;
  W := FConsumerWaiting;
  FConsumerWaiting := False;
  Ex := FEx;
  FLock.Release;
  if W and (Ex <> nil) then
    Ex.Wake;
  Result := True;
end;

procedure TChannelBody.AutoFinish;
var
  W: Boolean;
  Ex: TExchange;
begin
  FLock.Acquire;
  if Ended then
  begin
    FLock.Release;
    Exit;
  end;
  FFinished := True;
  FHasTrailers := False;
  W := FConsumerWaiting;
  FConsumerWaiting := False;
  Ex := FEx;
  FLock.Release;
  if W and (Ex <> nil) then
    Ex.Wake;
end;

function TChannelBody.EmptyWrite: TWriteResult;
begin
  { the answer a frame would get, without the frame: wrCanceled once the
    stream ended (finished, aborted, dropped by the transport, or not this
    request's), as Push gives }
  FLock.Acquire;
  if Ended then
    Result := wrCanceled
  else
    Result := wrOk;
  FLock.Release;
end;

function TChannelBody.Queued: SizeInt;
begin
  FLock.Acquire;
  Result := FQueued;
  FLock.Release;
end;

procedure TChannelBody.WakeProducer;
begin
  FSpace.NotifyAll;
end;

function TChannelBody.PollFrame(Ex: TExchange; out Data: TBodyData;
  out Trailers: THttpHeaders): TFramePoll;
var
  P: Boolean;
begin
  Data := BodyEmpty;
  Trailers := nil;
  FLock.Acquire;
  if FCount > 0 then
  begin
    Data := FRing[FHead];
    FRing[FHead] := BodyEmpty;
    FHead := (FHead + 1) mod Length(FRing);
    Dec(FCount);
    Dec(FQueued, Data.Len);
    P := FProducerWaiting;
    FProducerWaiting := False;
    FLock.Release;
    if P then
      FSpace.NotifyAll;
    Exit(fpData);
  end;
  if FAborted then
  begin
    { FAbortMsg does not change once FAborted is set (until Reset) }
    FLock.Release;
    Ex.SetBodyErrorText(FAbortMsg);
    Exit(fpError);
  end;
  if FFinished then
  begin
    if FHasTrailers and not FTrailersSent then
    begin
      FTrailersSent := True;
      FLock.Release;
      Trailers := FTrailers;
      Exit(fpTrailers);
    end;
    FLock.Release;
    Exit(fpEnd);
  end;
  FConsumerWaiting := True;
  FLock.Release;
  Result := fpPending;
end;

procedure TChannelBody.Done(Ex: TExchange);
var
  P: Boolean;
begin
  { the transport dropped the body: queued frames go, producers get
    wrCanceled. The object stays (the exchange or the application owns it). }
  FLock.Acquire;
  FClosed := True;
  DropQueued;
  P := FProducerWaiting;
  FProducerWaiting := False;
  FLock.Release;
  if P then
    FSpace.NotifyAll;
end;

{ TUpgradeSlot }

procedure TUpgradeSlot.Fulfill(U: TUpgraded);
begin
  { delivered (Deliver) after the HTTP connection ended }
  State := usFulfilled;
  Upgraded := U;
end;

{ The slot is a oneshot: its handler gets one result. The handler is
  cleared before it is called, so a handler may free itself in its callback
  and a later Cancel (connection dropped) reaches nobody. }

{ The ownership rule of the upgraded stream: the handler owns U
  from the call of Upgraded on. If Upgraded raises before it attached,
  detached or closed U (U.Taken), the stream is closed here (its socket and
  epoll entry would leak otherwise) and the exception goes on to the loop,
  which logs it and aborts the delivery task (see bearings.rt.loop). A cold path: one
  exception frame per upgrade. }

procedure DeliverUpgraded(H: TUpgradeHandler; U: TUpgraded);
begin
  try
    H.Upgraded(U);
  except
    if (U <> nil) and not U.Taken then
      U.Close;
    raise;
  end;
end;

procedure TUpgradeSlot.Deliver;
var
  U: TUpgraded;
  H: TUpgradeHandler;
begin
  U := Upgraded;
  Upgraded := nil;
  H := Handler;
  if (H <> nil) and RxAlive then
  begin
    Handler := nil;
    DeliverUpgraded(H, U);
  end
  else if U <> nil then
    { nobody wants the upgraded connection (no handler, or the request was
      released without OnUpgrade): it is closed }
    U.Close;
end;

procedure TUpgradeSlot.Manual;
var
  H: TUpgradeHandler;
begin
  { the connection mode does not hand upgrades over (cmPlain,
    cmWithoutShutdown): the handler is told the upgrade failed }
  State := usManual;
  H := Handler;
  Handler := nil;
  if H <> nil then
    H.UpgradeFailed(MANUAL_UPGRADE_MSG);
end;

procedure TUpgradeSlot.Cancel;
var
  H: TUpgradeHandler;
begin
  { the connection ended without completing the upgrade }
  State := usCanceled;
  H := Handler;
  Handler := nil;
  if H <> nil then
    H.UpgradeFailed(CANCELED_UPGRADE_MSG);
end;

constructor TUpgradeSlot.Create;
begin
  inherited Create;
  FRefs := 1;
  InterLockedIncrement(UpgradeSlotsLive);
end;

destructor TUpgradeSlot.Destroy;
begin
  InterLockedDecrement(UpgradeSlotsLive);
  inherited Destroy;
end;

procedure TUpgradeSlot.AddRef;
begin
  InterLockedIncrement(FRefs);
end;

procedure TUpgradeSlot.Release;
begin
  if InterLockedDecrement(FRefs) = 0 then
    Free;
end;

{ TUpgradeHandler }

procedure TUpgradeHandler.UpgradeFailed(const Msg: string); begin end;

{ TOffloadCall }

function TOffloadCall.Poll(Ex: TExchange): TCallPoll;
begin
  { first poll: hand the exchange to the pool (the worker answers and wakes
    the connection through the loop's inbox); later polls: ready once the
    worker's terminal call won }
  if Ex.FHandler = nil then
  begin
    Ex.Offload(Pool, Handler);
    Exit(cpPending);
  end;
  if Ex.Answered then
    Result := cpReady
  else
    Result := cpPending;
end;

{ TExchangePool }

function TExchangePool.Take(Loop: TLoop): TExchange;
begin
  if FFree <> nil then
  begin
    Result := FFree;
    FFree := Result.FNextFree;
    Result.FNextFree := nil;
    Dec(FCount);
  end
  else
    Result := TExchange.Create;
  Inc(FOut);
  Result.FLoop := Loop;
  AtomicStore(Result.FRefCount, 1);
  Result.FHolders := 0;
  Result.FShared := False;
  Result.FHomePool := Self;
end;

procedure TExchangePool.Give(Ex: TExchange);
begin
  Ex.Recycle;
  Ex.FNextFree := FFree;
  FFree := Ex;
  Inc(FCount);
  Dec(FOut);
end;

destructor TExchangePool.Destroy;
var
  Ex: TExchange;
begin
  while FFree <> nil do
  begin
    Ex := FFree;
    FFree := Ex.FNextFree;
    Ex.Free;
  end;
  FCount := 0;
  inherited Destroy;
end;

{ TConnObserver }

function TConnObserver.OnAccept(Loop: TLoop; ConnId: QWord; const Peer: TSockAddrStorage): Pointer;
begin Result := nil; end;
function TConnObserver.WrapTransport(T: TTcpTransport; Data: Pointer): TTransport;
begin Result := T; end;
procedure TConnObserver.OnStart(ConnId: QWord; Data: Pointer; Task: TLoopTask);
begin end;
procedure TConnObserver.OnConnClose(ConnId: QWord; Data: Pointer; Outcome: TConnOutcome;
  const Detail: string); begin end;
procedure TConnObserver.OnParts(ConnId: QWord; Data: Pointer; var Parts: TConnParts);
begin
  { default: drop the parts (close(2), no shutdown) }
  if Parts.Rest.Block <> nil then
    Parts.Rest.Release;
  Parts.Rest := Default(TBytesView);
  if Parts.Transport <> nil then
  begin
    Parts.Transport.Close;
    Parts.Transport.Free;
    Parts.Transport := nil;
  end;
end;

{ BodyCopy: the bytes in a block of the loop's pool, given back by ReleaseBody }

procedure ReleaseCopyBlock(Ctx: Pointer; Data: PByte);
begin
  BlockFree(PBufBlock(Ctx));
end;

function BodyCopy(Ex: TExchange; P: Pointer; Len: SizeInt): TBodyData;
var
  B: PBufBlock;
  Pool: PBlockPool;
begin
  if Len <= 0 then
    Exit(BodyEmpty);
  Pool := nil;
  { the loop's pool is a loop-thread structure: other threads copy to the heap }
  if (Ex <> nil) and (Ex.FLoop <> nil) and ((not Ex.FShared) or Ex.OnOwnLoop) then
    Pool := @Ex.FLoop.Blocks;
  B := BlockAlloc(Pool, Len);
  Move(P^, B^.Data^, Len);
  Result := BodyEmpty;
  Result.Kind := bkMem;
  Result.P := B^.Data;
  Result.Len := Len;
  Result.Own := boCustom;
  Result.Ctx := B;
  Result.ReleaseProc := @ReleaseCopyBlock;
end;

{ ---- loop messages of a shared exchange ---- }

procedure ExchangeWakeMsg(Loop: TLoop; Arg: Pointer);
var
  Ex: TExchange;
begin
  Ex := TExchange(Arg);
  { the node is in the inbox at most once (Wake's CAS on FWakeQueued); a
    second dispatch of the same node would mean it was pushed twice }
  { the generation the message was posted for is the
    exchange's generation now (no recycle while the message was queued) }
  Assert(Ex.FWakeGen = Ex.FGen, 'ExchangeWakeMsg: the exchange was recycled while its WakeMsg was queued');
  Assert(AtomicLoad(Ex.FWakeQueued) = 1, 'ExchangeWakeMsg: a WakeMsg that was not queued');
  HappensBefore(@Ex.FWakeQueued);
  InterlockedExchange(Ex.FWakeQueued, 0);
  if Ex.FFreePending then
  begin
    { the last reference went while this message was queued }
    Ex.FFreePending := False;
    Ex.FinalRelease;
    Exit;
  end;
  if Ex.FShared then
    Ex.SyncShared;
  if Ex.FOwner <> nil then
    Ex.FOwner.Wake;
end;

procedure ExchangeFreeMsg(Loop: TLoop; Arg: Pointer);
begin
  TExchange(Arg).FinalRelease;
end;

initialization
  LoopMsgHandlers[lmWakeExchange] := @ExchangeWakeMsg;
  LoopMsgHandlers[lmFreeExchange] := @ExchangeFreeMsg;
end.

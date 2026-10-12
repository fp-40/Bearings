{ bearings.http1.dispatch - the task that serves one HTTP/1.1 connection.

  TH1Dispatcher is the loop task (TIoTask, see bearings.rt.loop) of one accepted
  connection. It owns the connection state machine (TH1Conn, bearings.http1.conn)
  and moves requests between it and the application (THttpService,
  bearings.http.exchange): it reads a request head, calls the service, feeds the
  request body to the service, writes the response head and body, and then
  either waits for the next request on the same connection (keep-alive) or
  closes the connection.

  Main types:
    TH1Dispatcher     the connection task. bearings.server creates one per accepted
                      socket (Create, Setup, LinkInto) and the loop calls Run
                      whenever the socket is ready or the task was woken.
    TOutBody          the response body being written: either one block of
                      data (memory or a file range) written as a single
                      frame, or a TBodySource that produces frames one by one
                      (streaming).
    TConnList         the list of the connections of one loop, used by
                      bearings.server for graceful shutdown and stop.
    TUpgradeDelivery  a task that hands an upgraded connection to its
                      handler after the connection-close event was reported.
    TConnHooks        the server layer's per-connection hooks (connection
                      limit, metrics): ConnDone when the connection has
                      released everything; nil when none.

  One Run. Run calls PollCatch -> PollInner -> PollLoop. PollLoop repeats
  "read (PollRead), write (PollWrite), flush (PollFlush)" until neither side
  can make progress, at most 16 times per Run (see PollLoop). Every poll
  routine returns prOk (done for now / finished), prPending (waiting for
  something; the task will be run again later) or prErr (the connection
  fails). When the connection is finished (IsDone), PollInner flushes the
  last bytes and either shuts the socket down or prepares the upgrade, and
  Run calls Finish, which releases everything and reports the outcome.

  One request at a time. HTTP/1.1 lets a client send several requests
  without waiting for the responses (pipelining); the responses must be sent
  in the order of the requests, because nothing on the wire says which
  request a response answers. The dispatcher keeps at most one service call
  in flight (InFlight): while a call is in flight PollReadHead returns
  Pending and the next pipelined request stays unparsed in the read buffer.
  So responses are written in request order without any reordering queue.

  Wake sources. The task returns Pending only when something will run it
  again: the task woke itself (a yield, or a wake from the body channel or
  the exchange), a socket read or write returned EAGAIN in this Run (the
  next readiness event runs the task), the header read timer is running,
  the service call or the response body source returned Pending in this Run
  (they must call Ex.Wake later), or the request body channel waits for the
  receiver (its next read wakes the sender). Builds with -dWD_DEBUG check
  this at the end of every Run that returns Pending (AssertWakeArmed); a
  failure increments WakeAssertFailures and raises EAssertionFailed (with
  -Sa). A Pending without a wake source would leave the connection stuck
  until a timeout.

  Ownership. The dispatcher owns the transport (OwnsTransport, default True)
  until it closes it or hands it on (an upgrade, or cmWithoutShutdown, which
  hands the transport and the unread bytes to the observer). It holds one
  exchange (TExchange: the request head, the request body channel and the
  response) at a time, taken from the loop's TExchangePool (Loop.Exchanges;
  a private pool when the loop has none) before a head is parsed, because
  the head is parsed into the exchange's header list. The exchange is given
  back when the connection is idle (ReleaseIfIdle) or done. Giving it back
  is TExchange.ReleaseTransport, which drops the connection's reference. An
  exchange handed to a worker thread (Shared) is not reused for the next
  request; only an exchange from Loop.Exchanges can be shared.

  The routines that run for every request (Run, PollLoop, PollRead,
  PollReadHead, PollWrite, PollFlush, PollInner, PollCatch, PollMsg,
  RecvMsg) use no managed types, so the compiler generates no implicit
  exception frames for them (tools/check-hot-asm.sh checks this). Code that
  needs strings (Finish, which builds the observer's text, and the error
  text setters) is in separate routines.

  Threading: everything here runs on the thread of the loop that owns the
  connection. }
unit bearings.http1.dispatch;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

{$ifdef WD_STALL}
  {$ifndef WD_DEBUG}
    {$error WD_STALL needs WD_DEBUG (the stall detector reads the wake-source flags)}
  {$endif}
{$endif}

uses
  ctypes, bearings.rt.sys, bearings.rt.loop, bearings.rt.buf, bearings.rt.net, bearings.rt.stream, bearings.http1.io, bearings.http1.conn,
  bearings.http1.role, bearings.http.error, bearings.http.headers, bearings.http.exchange, bearings.http1.config;

type
  { How PollCatch ended a connection that finished without an error:
    dsShutdown (the socket was shut down, or is handed on as parts) or
    dsUpgrade (the connection switches to another protocol). }
  TDispatched = (dsShutdown, dsUpgrade);

  { The response body being written. obNone: no body is being written.
    obData: the whole body (memory or a file range) is in Data and is
    written as one frame. obSource: a TBodySource produces the frames. }
  TOutBodyKind = (obNone, obData, obSource);
  TOutBody = record
    Kind: TOutBodyKind;
    Data: TBodyData;                 { obData: the body, handed out once }
    Taken: Boolean;                  { obData: the frame was handed out }
    Source: TBodySource;             { obSource }
    function IsEndStream: Boolean;   { True when nothing remains to write }
    function SizeHint(out Exact: QWord): Boolean;
  end;

  TH1Dispatcher = class;

  { Hooks of the server layer, per connection: the connection limit and the
    metrics (bearings.server). nil, the default, means none: the dispatcher
    then tests the pointer once per event and does nothing else. Loop
    thread of the connection. }
  TConnHooks = class
  public
    { The connection task has released everything (Finish, Abort or
      Destroy). Outcome: how the connection ended (coOther for an abort).
      Upgraded: the transport went to an upgrade handler (TUpgraded), and
      the hooks get UpgradedClosed when that stream is closed or detached.
      D is still allocated (it is freed after the event batch). }
    procedure ConnDone(D: TH1Dispatcher; Outcome: TConnOutcome; Upgraded: Boolean); virtual; abstract;
    { An upgraded connection announced in ConnDone is closed or detached. }
    procedure UpgradedClosed; virtual; abstract;
  end;

  { The connections of one loop, a doubly linked list through
    FPrevConn/FNextConn (bearings.server uses it for graceful shutdown and stop).
    Loop thread only. }
  PConnList = ^TConnList;
  TConnList = record
    Head: TH1Dispatcher;
    Count: Integer;
    OnEmpty: procedure(List: PConnList) of object;   { called when Count drops to 0 }
  end;

  TH1Dispatcher = class(TIoTask)
  private
    FPendingUpgrade: TUpgradePending;
    FRequestNo: LongWord;
    FPool: TExchangePool;            { Loop.Exchanges, or FOwnPool }
    FOwnPool: TExchangePool;
    FList: PConnList;
    FPrevConn, FNextConn: TH1Dispatcher;
    FDone: Boolean;                  { DropAll ran (from Finish, Abort or Destroy) }
    {$ifdef WD_DEBUG}
    FDbgReads, FDbgWrites: QWord;
    FDbgCallPending, FDbgSourcePending, FDbgChanPending: Boolean;
    {$endif}
    procedure TakePendingUpgrade;
    procedure TakeResponseBody(var B: TOutBody);                { moves the body out of Ex.Resp }
    function PollOutFrame(var B: TOutBody; out Data: TBodyData;
      out Trailers: THttpHeaders): TFramePoll;
    procedure SetErrorText(const S: RawByteString);             { cold }
    procedure SetBodyError(var Err: THyperError);               { cold: the response body source failed }
    procedure AcquireExchange; inline;
    procedure ReleaseExchange;
    procedure ReleaseIfIdle;
    procedure DropAll;                                           { releases everything the connection holds }
    procedure Unlink;
    {$ifdef WD_DEBUG}
    procedure AssertWakeArmed;
    {$endif}
  public
    {$ifdef WD_STALL}
    { Stall detector (debug builds). It finds connections that are in the
      middle of a message and have not run for a long time although the
      server, not the client, owes the next step.
      LastRunMs: loop clock (ms) of the last Run; set by Setup and Run.
      StallReported: the stall was reported (once per connection).
      StallClientWait: the last Run that returned Pending waited only on the
      client: a read or a write returned EAGAIN and the server owed nothing
      (no call in flight except one waiting for body bytes, no body chunk
      waiting for the receiver, no response source pending, not woken).
      StallReadWait / StallWriteWait: which side it waited on.
      StallBodyRead: in this Run the request body read found no byte. }
    LastRunMs: Int64;
    StallReported: Boolean;
    StallClientWait, StallReadWait, StallWriteWait, StallBodyRead: Boolean;
    { True when the connection is mid-message (a request head partly read,
      a request in progress, or response bytes not flushed), has not run for
      StallMs ms, and the server owes progress: the last Run did not wait on
      the client, or the task is queued, or a readiness event for the side
      it waited on arrived and the task did not run. }
    function StallCandidate(NowMs, StallMs: Int64): Boolean;
    function StallReason: string;
  public
    {$endif}
    Conn: TH1Conn;                   { embedded: one allocation per connection }
    Service: THttpService;
    Mode: TH1ConnMode;
    InFlight: TServiceCall;          { the service call of the current request; nil = none }
    Ex: TExchange;                   { the current exchange: request in flight, body fed or written }
    { True while this side of the request body channel (Ex.Chan) is open:
      the dispatcher still has body bytes to read and pass to the service.
      Every place that sets it to False also closes the sender. }
    BodyTx: Boolean;
    BodyRx: TOutBody;                { the response body being written }
    IsClosing: Boolean;              { Close_ ran: no more reads or writes }
    FUpgraded: Boolean;              { the transport was handed to an upgrade }
    Observer: TConnObserver;         { nil in production }
    ObsData: Pointer;                { what Observer.OnAccept returned }
    Hooks: TConnHooks;               { nil = none (the server sets it when a feature needs it) }
    Outcome: TConnOutcome;           { set by Finish before the release; coOther until then (an abort) }
    ConnId: QWord;
    Peer: TSockAddrStorage;
    OwnsTransport: Boolean;          { Finish / Abort free the transport object (default True) }
    FErrorText: RawByteString;       { cold: text for ecConnText errors }

    { TIoTask.Create (AFd = -1 for a transport without a socket of its own); call Setup next. }
    constructor Create(ALoop: TLoop; AFd: cint);
    destructor Destroy; override;
    { Initializes the connection state with the transport, applies the configuration
      (ApplyH1Config) and takes the exchange pool. }
    procedure Setup(ATransport: TTransport; AService: THttpService; const Cfg: TH1Config;
      AObserver: TConnObserver; AConnId: QWord; AObsData: Pointer);
    procedure LinkInto(List: PConnList);

    procedure Run; override;                       { one step of the connection; never blocks }
    procedure Abort; override;                     { release everything without a completion event }
    { Finish the request in progress, if any, and then close: keep-alive is
      disabled, and an idle connection is closed at once. }
    procedure GracefulShutdown;
    { The poll routines (see the unit header). Err is set when prErr / poErr is returned. }
    function PollCatch(ShouldShutdown: Boolean; out D: TDispatched; var Err: THyperError): TPollResult;
    function PollInner(ShouldShutdown: Boolean; out D: TDispatched; var Err: THyperError): TPollResult;
    function PollLoop(var Err: THyperError): TPollResult;
    function PollRead(var Err: THyperError): TPollResult;
    function PollReadHead(var Err: THyperError): TPollResult;
    function PollWrite(var Err: THyperError): TPollResult;
    function PollFlush(var Err: THyperError): TPollResult;
    function PollMsg(var Err: THyperError): TPollOpt;           { polls the service call }
    function RecvMsg(const Msg: TParsedRequestHead; const Head: TBytesView;
      Wants: TWants): Boolean;                                  { starts the service call }
    procedure Close_;                                           { stop reading and writing }
    function CanWriteAgain: Boolean;
    function IsDone: Boolean;
    procedure ClearBodyRx;                                      { releases BodyRx }
    { After PollCatch returned prOk or prErr: hand the connection on (upgrade or
      parts), release everything, report the outcome to the observer, free the task. }
    procedure Finish(R: TPollResult; D: TDispatched; var Err: THyperError);
    property PendingUpgrade: TUpgradePending read FPendingUpgrade;
    property RequestCount: LongWord read FRequestNo;
    property NextConn: TH1Dispatcher read FNextConn;      { the loop's connection list }
  end;

  { Delivers a fulfilled upgrade (the connection switched to another protocol) to the
    upgrade handler. Finish queues it, so it runs after the connection's completion was
    reported: an observer sees the connection close before the upgraded connection starts. }
  TUpgradeDelivery = class(TLoopTask)
  public
    Slot: TUpgradeSlot;
    procedure Run; override;
    procedure Abort; override;
  end;

var
  { WD_DEBUG builds: how often Run returned Pending with no wake source armed. }
  WakeAssertFailures: Integer = 0;

implementation

uses
  SysUtils;

{ TOutBody }

function TOutBody.IsEndStream: Boolean;
begin
  case Kind of
    obData:
      { a one-frame body has ended once its frame was taken; an empty body
        has nothing to write }
      Result := Taken or (Data.Kind = bkEmpty) or (Data.Len = 0);
    obSource:
      Result := Source.IsEndStream;
  else
    Result := True;
  end;
end;

function TOutBody.SizeHint(out Exact: QWord): Boolean;
begin
  case Kind of
    obData:
      begin
        { the exact length of what is still to be written }
        if Taken or (Data.Kind = bkEmpty) then
          Exact := 0
        else
          Exact := QWord(Data.Len);
        Result := True;
      end;
    obSource:
      Result := Source.SizeHint(Exact);
  else
    begin
      Exact := 0;
      Result := True;
    end;
  end;
end;

{ TUpgradeDelivery }

procedure TUpgradeDelivery.Run;
var
  S: TUpgradeSlot;
begin
  { Slot stays set and the task stays open while the handler runs: when
    Deliver raises, the loop calls Abort (it does so only for a task not yet
    closed), and Abort releases the reference. Deliver has already moved the
    TUpgraded to the handler (Slot.Upgraded is nil then), so Abort does not
    close it; when the handler raised before taking it, Deliver closed it. }
  S := Slot;
  if S <> nil then
  begin
    S.Deliver;
    Slot := nil;
    S.Release;                 { the connection side's reference }
  end;
  Close;
end;

procedure TUpgradeDelivery.Abort;
begin
  if Slot <> nil then
  begin
    if Slot.Upgraded <> nil then
      Slot.Upgraded.Close;
    Slot.Upgraded := nil;
    Slot.Release;
    Slot := nil;
  end;
end;

{ TUpgraded.CloseProc: the stream of an upgraded connection closed or was detached }
procedure UpgradedCloseProc(Arg: Pointer);
begin
  TConnHooks(Arg).UpgradedClosed;
end;

{ TH1Dispatcher }

constructor TH1Dispatcher.Create(ALoop: TLoop; AFd: cint);
begin
  inherited Create(ALoop, AFd);
  OwnsTransport := True;
end;

destructor TH1Dispatcher.Destroy;
begin
  if not FDone then
    DropAll;
  FOwnPool.Free;
  inherited Destroy;
end;

procedure TH1Dispatcher.Setup(ATransport: TTransport; AService: THttpService;
  const Cfg: TH1Config; AObserver: TConnObserver; AConnId: QWord; AObsData: Pointer);
begin
  Conn.Init(ATransport, @Loop.Blocks, Self);
  ApplyH1Config(Cfg, Conn);
  {$ifdef WD_STALL}
  LastRunMs := Loop.NowMs;
  StallReported := False;
  StallClientWait := False;
  StallReadWait := False;
  StallWriteWait := False;
  StallBodyRead := False;
  {$endif}
  Mode := Cfg.Mode;
  Service := AService;
  Observer := AObserver;
  ObsData := AObsData;
  Outcome := coOther;              { Hooks is left as set: the server sets it before Setup }
  ConnId := AConnId;
  InFlight := nil;
  Ex := nil;
  BodyTx := False;
  BodyRx := Default(TOutBody);
  IsClosing := False;
  FUpgraded := False;
  FPendingUpgrade.Active := False;
  FPendingUpgrade.Slot := nil;
  FRequestNo := 0;
  if (Loop <> nil) and (Loop.Exchanges <> nil) then
    FPool := TExchangePool(Loop.Exchanges)
  else
  begin
    FOwnPool := TExchangePool.Create;
    FPool := FOwnPool;
  end;
end;

procedure TH1Dispatcher.LinkInto(List: PConnList);
begin
  FList := List;
  FPrevConn := nil;
  FNextConn := List^.Head;
  if FNextConn <> nil then
    FNextConn.FPrevConn := Self;
  List^.Head := Self;
  Inc(List^.Count);
end;

procedure TH1Dispatcher.Unlink;
var
  L: PConnList;
begin
  L := FList;
  if L = nil then
    Exit;
  FList := nil;
  if FPrevConn <> nil then
    FPrevConn.FNextConn := FNextConn
  else
    L^.Head := FNextConn;
  if FNextConn <> nil then
    FNextConn.FPrevConn := FPrevConn;
  FPrevConn := nil;
  FNextConn := nil;
  Dec(L^.Count);
  if (L^.Count = 0) and Assigned(L^.OnEmpty) then
    L^.OnEmpty(L);
end;

procedure TH1Dispatcher.AcquireExchange;
begin
  { the next request reuses the exchange only while nobody else holds it; a
    shared one (handed to a worker thread) is let go and a fresh one taken }
  if (Ex <> nil) and Ex.Shared then
    ReleaseExchange;
  if Ex = nil then
  begin
    Ex := FPool.Take(Loop);
    Ex.Head.Peer := Peer;
    Ex.Head.ConnId := ConnId;
  end;
end;

procedure TH1Dispatcher.ReleaseExchange;
var
  E: TExchange;
begin
  E := Ex;
  if E = nil then
    Exit;
  Ex := nil;
  { drops the connection's reference: an unshared exchange goes back to
    FPool at once; a shared one is recycled on this loop when its last
    reference is dropped }
  E.ReleaseTransport;
end;

procedure TH1Dispatcher.ReleaseIfIdle;
begin
  { A keep-alive connection waiting for its next request may wait a long
    time. Between requests (nothing read, nothing to write, no call, no body
    in either direction) it gives its exchange and its buffer blocks back,
    so idle connections hold little memory. }
  if (Conn.State.Reading = rdInit) and (Conn.State.Writing = wrInit)
    and (Conn.Io.ReadBuf.Len = 0) and (InFlight = nil) and (BodyRx.Kind = obNone)
    and not BodyTx and not Conn.Io.HasBufferedWrite and (Conn.Io.WriteBuf.Headers.Pos = 0) then
  begin
    if Ex <> nil then
      ReleaseExchange;
    Conn.Io.ReleaseIdle;
    Conn.ReleaseIdleScratch;
  end;
end;

procedure TH1Dispatcher.SetErrorText(const S: RawByteString);
begin
  FErrorText := S;
end;

procedure TH1Dispatcher.SetBodyError(var Err: THyperError);
begin
  { the error text is the source's own text, when it gave one }
  Err := NewUserBody;
  if (Ex <> nil) and (Ex.Resp.BodyErrorText <> '') then
    FErrorText := Ex.Resp.BodyErrorText
  else
    FErrorText := 'body error';
end;

{$ifdef WD_DEBUG}
procedure TH1Dispatcher.AssertWakeArmed;
begin
  { a Pending is correct only when something runs the task again (see the
    unit header); the checks below are the wake sources }
  if Notified or Queued then
    Exit;                                          { yield / self-wake }
  if Conn.Io.PendingReads <> FDbgReads then
    Exit;                                          { read edge }
  if Conn.Io.PendingWrites <> FDbgWrites then
    Exit;                                          { write edge }
  if Conn.State.HeaderReadTimeoutRunning then
    Exit;                                          { the timer's Proc }
  if FDbgCallPending or FDbgSourcePending then
    Exit;                                          { the call / source arranged Ex.Wake }
  if FDbgChanPending and BodyTx then
    Exit;                                          { the receiver's next body call }
  Inc(WakeAssertFailures);
  Assert(False, 'TH1Dispatcher.Run: Pending with no wake source armed');
end;
{$endif}

{$ifdef WD_STALL}
function TH1Dispatcher.StallCandidate(NowMs, StallMs: Int64): Boolean;
begin
  Result := (not Closed) and (not FDone) and (NowMs - LastRunMs >= StallMs)
    and ((not Conn.State.IsIdle) or (Conn.Io.ReadBuf.Len > 0) or Conn.HasBufferedWrite)
    and (Queued or not StallClientWait
      or (StallReadWait and (Src.Ready * [rdRead, rdReadClosed, rdError] <> []))
      or (StallWriteWait and (Src.Ready * [rdWrite, rdWriteClosed, rdError] <> [])));
end;

function TH1Dispatcher.StallReason: string;
begin
  if Queued then
    Result := 'woken, not run'
  else if StallClientWait then
    Result := 'a readiness event not acted on'
  else if InFlight <> nil then
    Result := 'the service call is pending'
  else if FDbgChanPending then
    Result := 'a body chunk waits for the receiver'
  else if FDbgSourcePending then
    Result := 'the response body source is pending'
  else
    Result := 'no wait on the client';
end;

{ True when the Pending of this Run waited on the client only (a slow
  client, not a stall of the server). Also sets StallReadWait/StallWriteWait. }
function StallWaitsOnClient(D: TH1Dispatcher): Boolean;
begin
  D.StallReadWait := D.Conn.Io.PendingReads <> D.FDbgReads;
  D.StallWriteWait := D.Conn.Io.PendingWrites <> D.FDbgWrites;
  if D.Notified or D.Queued or D.FDbgChanPending or D.FDbgSourcePending then
    Exit(False);
  { a call in flight waits on the client only while its body read does }
  if (D.InFlight <> nil) and not D.StallBodyRead then
    Exit(False);
  Result := D.StallReadWait or D.StallWriteWait;
end;
{$endif}

procedure TH1Dispatcher.Run;
var
  R: TPollResult;
  D: TDispatched;
  Err: THyperError;
begin
  {$ifdef WD_DEBUG}
  FDbgReads := Conn.Io.PendingReads;
  FDbgWrites := Conn.Io.PendingWrites;
  FDbgCallPending := False;
  FDbgSourcePending := False;
  FDbgChanPending := False;
  {$endif}
  {$ifdef WD_STALL}
  LastRunMs := Loop.NowMs;
  StallBodyRead := False;
  {$endif}
  Err.Kind := hekNone;
  { the socket is shut down at the end, except in cmWithoutShutdown, which
    hands it to the observer instead }
  R := PollCatch(Mode <> cmWithoutShutdown, D, Err);
  if R = prPending then
  begin
    {$ifdef WD_DEBUG}
    AssertWakeArmed;
    {$endif}
    {$ifdef WD_STALL}
    StallClientWait := StallWaitsOnClient(Self);
    {$endif}
    ReleaseIfIdle;
    Exit;
  end;
  Finish(R, D, Err);
end;

function TH1Dispatcher.PollCatch(ShouldShutdown: Boolean; out D: TDispatched;
  var Err: THyperError): TPollResult;
begin
  { PollInner, plus: on an error, a request body still being received gets
    the error, so the service's body read fails instead of seeing a normal end }
  D := dsShutdown;
  Result := PollInner(ShouldShutdown, D, Err);
  if Result <> prErr then
    Exit;
  if BodyTx then
  begin
    BodyTx := False;
    Ex.Chan.SendError(NewBodyStatic('connection error'));
    Ex.Chan.CloseSender;
  end;
end;

function TH1Dispatcher.PollInner(ShouldShutdown: Boolean; out D: TDispatched;
  var Err: THyperError): TPollResult;
var
  Errno: cint;
begin
  { Runs the read/write loop; once the connection is done, flushes and then
    shuts the socket down or prepares the upgrade. (The cached Date header
    is updated once per loop iteration by the loop, not here.) }
  D := dsShutdown;
  Result := PollLoop(Err);
  if Result <> prOk then
    Exit;                    { Pending, or an error: no flush, no shutdown }
  if not IsDone then
    Exit(prPending);
  { With pipeline flush enabled, PollFlush does not write while the read
    buffer holds more pipelined request bytes: the responses to those
    requests can then go out in the same write. The connection is done, so
    no later response can join: write the held bytes now, before the
    transport is shut down or handed on. Without pipeline flush the
    condition is never true. }
  if Conn.Io.HoldsPipelinedWrite then
    case Conn.Io.PollFlushHeld(Errno) of
      ipPending: Exit(prPending);
      ipError:
        begin
          Err := NewBodyWrite(Errno);       { as in PollFlush }
          Exit(prErr);
        end;
    end;
  if Conn.State.Upgrade.Active then
  begin
    { the response accepted an upgrade (101 Switching Protocols or a
      successful CONNECT): Finish hands the transport on }
    TakePendingUpgrade;
    if Conn.TakeError(Err) then
      Exit(prErr);
    D := dsUpgrade;
    Exit(prOk);
  end
  else if ShouldShutdown then
    case Conn.PollShutdown(Errno) of
      ipPending: Exit(prPending);
      ipError:
        begin
          Err := NewShutdown(Errno);
          Exit(prErr);
        end;
    end;
  if Conn.TakeError(Err) then
    Exit(prErr);
  D := dsShutdown;
  Result := prOk;
end;

function TH1Dispatcher.PollLoop(var Err: THyperError): TPollResult;
var
  I: Integer;
  R: TPollResult;
  WriteReady, FlushReady, WantsWriteAgain, WantsReadAgain: Boolean;
begin
  { Limit the work done for this connection in one Run, so a client that
    keeps the connection ready all the time (for example a long pipeline)
    does not starve the other connections of the loop. 16 is the number of
    pipelined requests that benchmarks often use. }
  for I := 1 to 16 do
  begin
    { PollRead's Pending is not a reason to stop: writing may still progress }
    if PollRead(Err) = prErr then
      Exit(prErr);
    R := PollWrite(Err);
    if R = prErr then
      Exit(prErr);
    WriteReady := R = prOk;
    R := PollFlush(Err);
    if R = prErr then
      Exit(prErr);
    FlushReady := R = prOk;

    { If more body can be written and the last write or flush completed,
      write again: returning now would leave the task without a wake from
      the write side (no write returned EAGAIN). }
    WantsWriteAgain := CanWriteAgain and (WriteReady or FlushReady);

    { Reading may have stopped without a read returning EAGAIN (for
      example at the end of a request body); finishing the response then
      set the read state back to Init, ready for the next request head. }
    WantsReadAgain := Conn.WantsReadAgain;

    { Neither side can go on: return and rely on the wake sources. }
    if not (WantsWriteAgain or WantsReadAgain) then
      Exit(prOk);

    { Continuing only to write: check that a second write makes progress
      before looping. }
    if (not WantsReadAgain) and WantsWriteAgain then
    begin
      R := PollWrite(Err);
      if R = prErr then
        Exit(prErr);
      if R = prPending then
      begin
        { Flush what was just buffered before yielding. }
        if Conn.HasBufferedWrite then
          if PollFlush(Err) = prErr then
            Exit(prErr);
        Exit(prOk);
      end;
    end;
  end;
  { budget used up: yield (queue the task again and return Pending) }
  Wake;
  Result := prPending;
end;

function TH1Dispatcher.PollRead(var Err: THyperError): TPollResult;
var
  ChanClosed: Boolean;
  Frame: TInFrame;
  BErr: THyperError;
begin
  { Reads the next request head, or passes request body data to the
    service, or (neither) checks the idle connection for EOF. }
  while True do
  begin
    if IsClosing then
      Exit(prOk)
    else if Conn.CanReadHead then
    begin
      Result := PollReadHead(Err);
      if Result <> prOk then
        Exit;
    end
    else if BodyTx then
    begin
      if Conn.CanReadBody then
      begin
        if not Ex.Chan.PollReady(ChanClosed) then
        begin
          { the receiver has not taken the previous chunk yet }
          {$ifdef WD_DEBUG}
          FDbgChanPending := True;
          {$endif}
          Exit(prPending);
        end;
        if ChanClosed then
        begin
          { the service dropped the body without reading all of it: try
            once to read and discard the rest (PollDrainOrCloseRead); if the
            body does not end there, stop reading, so the connection is not
            kept alive. The sender is closed after the drain, so a chunk the
            receiver never took stays pinned during the drain's read. }
          Conn.PollDrainOrCloseRead;
          BodyTx := False;
          Ex.Chan.CloseSender;
          Continue;
        end;
        BErr.Kind := hekNone;
        case Conn.PollReadBody(Ex.ReqTrailers, Frame, BErr) of
          poSome:
            if Frame.Kind = ifData then
            begin
              if not Ex.Chan.TrySendData(Frame.Data) then
              begin
                { the receiver is gone: drop the chunk and the sender }
                if Frame.Data.Block <> nil then
                  Frame.Data.Release;
                BodyTx := False;
                Ex.Chan.CloseSender;
                if Conn.CanReadBody then
                  { the rest of the body will not be read: stop reading }
                  Conn.CloseRead;
              end;
            end
            else
            begin
              { the trailers were stored in Ex.ReqTrailers; tell the receiver }
              if not Ex.Chan.TrySendTrailers then
              begin
                BodyTx := False;
                Ex.Chan.CloseSender;
                if Conn.CanReadBody then
                  Conn.CloseRead;
              end;
            end;
          poNone:
            begin
              { end of the body: closing the sender tells the receiver }
              BodyTx := False;
              Ex.Chan.CloseSender;
            end;
          poPending:
            begin
              {$ifdef WD_STALL}
              StallBodyRead := True;
              {$endif}
              Exit(prPending);
            end;
        else
          begin
            { a framing error in the body: the receiver gets the error }
            Ex.Chan.SendError(BErr);
            BodyTx := False;
            Ex.Chan.CloseSender;
          end;
        end;
      end
      else
      begin
        { no body left to read: close the sender }
        BodyTx := False;
        Ex.Chan.CloseSender;
      end;
    end
    else
      { no head expected and no body to read: an idle or busy connection
        between messages (detects a client EOF in the middle of a message) }
      Exit(Conn.PollReadKeepAlive(Err));
  end;
end;

function TH1Dispatcher.PollReadHead(var Err: THyperError): TPollResult;
var
  Msg: TParsedRequestHead;
  Head: TBytesView;
  Wants: TWants;
begin
  { A new request head may be read. }
  if BodyTx then
  begin
    { The previous request's body has ended (reading went back to Init
      after its last data frame) while its receiver is still alive. Only a
      shared exchange allows this: a worker thread answered before it read
      the body. Close the sender now, so the reader sees the end of the
      body, and the shared exchange is released with its sender closed.
      This cannot happen for an unshared exchange: its receiver is closed
      when the call completes, before the response can end. }
    BodyTx := False;
    Ex.Chan.CloseSender;
  end;
  { One request at a time: the next pipelined head waits in the read buffer
    until the current call has completed (responses stay in order). }
  if InFlight <> nil then
    Exit(prPending);


  AcquireExchange;
  case Conn.PollReadHead(Ex.Head.Headers, Msg, Head, Wants, Err) of
    poPending:
      Exit(prPending);
    poSome:
      begin
        Ex.BeginRequest(Self);
        if Msg.Decode = DECODED_LENGTH_ZERO then
          { no body (no Content-Length / chunked, or Content-Length: 0):
            no channel, Chan.Active stays False }
        else
        begin
          { a body: open the channel. With "Expect: 100-continue" the
            interim 100 response is sent only when the service first asks
            for body data }
          Ex.Chan.Open(wantExpect in Wants);
          BodyTx := True;
        end;
        if wantUpgrade in Wants then
          { an upgrade request (Upgrade header or CONNECT): the service may
            accept it through the exchange }
          Conn.State.PrepareUpgrade(Ex);
        RecvMsg(Msg, Head, Wants);
        Result := prOk;
      end;
    poErr:
      { a read error, or a bad head for which no error response can be
        written: the connection fails. (When bearings.http1.conn can answer a bad
        head with 400, 414 or 431 it returns poPending instead, and the
        error is reported after that response was written.) }
      Result := prErr;
  else
    begin
      { poNone: the client closed the connection (EOF) before sending a
        new head. bearings.http1.conn closes the write side as well in that case;
        when it has, stop the connection. }
      if Conn.IsWriteClosed then
        Close_;
      Result := prOk;
    end;
  end;
end;

function TH1Dispatcher.PollWrite(var Err: THyperError): TPollResult;
var
  F: TFramePoll;
  Data: TBodyData;
  Trailers: THttpHeaders;
  BL: TBodyLength;
  N: QWord;
  Ok: Boolean;
begin
  { Writes the response: waits for the service call (PollMsg), writes the
    head with the body length, then the body frames, then ends the body. }
  while True do
  begin
    if IsClosing then
      Exit(prOk)
    else if (BodyRx.Kind = obNone) and Conn.CanWriteHead and (InFlight <> nil) then
    begin
      case PollMsg(Err) of
        poPending:
          Exit(prPending);
        poErr:
          { the service failed the call }
          Exit(prErr);
        poNone:
          begin
            Close_;
            Exit(prOk);
          end;
      end;
      TakeResponseBody(BodyRx);
      if BodyRx.IsEndStream then
      begin
        ClearBodyRx;
        BL.Kind := blkNone;
        BL.Len := 0;
      end
      else if BodyRx.SizeHint(N) then
      begin
        BL.Kind := blkKnown;
        BL.Len := N;
      end
      else
      begin
        BL.Kind := blkUnknown;
        BL.Len := 0;
      end;
      { the body length decides the framing: Content-Length for a known
        length, chunked (HTTP/1.1) or close-delimited (HTTP/1.0) for an
        unknown one }
      Conn.WriteHead(Ex.Resp.Head, BL);
    end
    else if not Conn.CanBufferBody then
    begin
      { the write buffer is full: flush before producing more body }
      Result := PollFlush(Err);
      if Result <> prOk then
        Exit;
    end
    else if BodyRx.Kind <> obNone then
    begin
      { the response needs no more body (e.g. HEAD, 204, 304, or the
        Content-Length was reached): drop the rest }
      if not Conn.CanWriteBody then
      begin
        ClearBodyRx;
        Continue;
      end;
      F := PollOutFrame(BodyRx, Data, Trailers);
      case F of
        fpPending:
          begin
            {$ifdef WD_DEBUG}
            FDbgSourcePending := True;
            {$endif}
            Exit(prPending);
          end;
        fpError:
          begin
            { the body source failed: the connection fails (the client sees
              a truncated body, which it can detect from the framing) }
            SetBodyError(Err);
            ClearBodyRx;
            Exit(prErr);
          end;
        fpData:
          if BodyRx.IsEndStream then
          begin
            if Data.Len = 0 then
            begin
              { discarding empty chunk }
              ReleaseBody(Data);
              Ok := Conn.EndBody(Err);
              ClearBodyRx;
              if not Ok then
                Exit(prErr);
            end
            else
            begin
              Conn.WriteBodyAndEnd(Data);
              ClearBodyRx;
            end;
          end
          else if Data.Len = 0 then
            { discarding empty chunk }
            ReleaseBody(Data)
          else
            Conn.WriteBody(Data);
        fpTrailers:
          begin
            Conn.WriteTrailers(Trailers);
            ClearBodyRx;
          end;
      else
        begin
          { fpEnd: the body source has no more frames }
          Ok := Conn.EndBody(Err);
          ClearBodyRx;
          if not Ok then
            Exit(prErr);
        end;
      end;
    end
    else
    begin
      { no body being written: end the body if the response is still
        writing one, else wait for the next response }
      if Conn.CanWriteBody then
      begin
        if not Conn.EndBody(Err) then
          Exit(prErr);
      end
      else
        Exit(prPending);
    end;
  end;
end;

function TH1Dispatcher.PollFlush(var Err: THyperError): TPollResult;
var
  Errno: cint;
begin
  case Conn.PollFlush(Errno) of
    ipReady: Result := prOk;
    ipPending: Result := prPending;
  else
    begin
      Err := NewBodyWrite(Errno);
      Result := prErr;
    end;
  end;
end;

procedure TH1Dispatcher.Close_;
begin
  IsClosing := True;
  Conn.CloseRead;
  Conn.CloseWrite;
end;

function TH1Dispatcher.CanWriteAgain: Boolean;
begin
  Result := (not IsClosing) and (BodyRx.Kind <> obNone) and Conn.CanWriteBody;
end;

function TH1Dispatcher.IsDone: Boolean;
var
  ReadDone, WriteDone: Boolean;
begin
  { the connection is finished when reading has ended and nothing is left
    to write }
  if IsClosing then
    Exit(True);
  ReadDone := Conn.IsReadClosed;
  WriteDone := Conn.IsWriteClosed or ((InFlight = nil) and (BodyRx.Kind = obNone));
  Result := ReadDone and WriteDone;
end;

function TH1Dispatcher.PollMsg(var Err: THyperError): TPollOpt;
begin
  { Polling the call is where the application's handler code runs (on the
    loop thread); Call itself only creates the call. }
  if InFlight.Poll(Ex) = cpPending then
  begin
    {$ifdef WD_DEBUG}
    FDbgCallPending := True;
    {$endif}
    Exit(poPending);
  end;
  { the call has completed: drop it, and with it its hold on the request }
  InFlight.Drop(Ex, True);
  InFlight := nil;
  Ex.CompleteCall;
  if Ex.Resp.Failed then
  begin
    Err := NewUserService;
    SetErrorText(Ex.Resp.FailText);
    Exit(poErr);
  end;
  Result := poSome;
end;

function TH1Dispatcher.RecvMsg(const Msg: TParsedRequestHead; const Head: TBytesView;
  Wants: TWants): Boolean;
begin
  { fills the exchange's request head from the parsed head and creates
    the service call }
  Inc(FRequestNo);
  Ex.FillHead(Msg, Head, FRequestNo);
  { Call only creates the call; it must not answer or read the body.
    Builds with assertions mark the exchange during Call to check this. }
  {$ifopt C+}
  Ex.DbgServiceCall(True);
  {$endif}
  InFlight := Service.Call(Ex);
  {$ifopt C+}
  Ex.DbgServiceCall(False);
  {$endif}
  Result := True;
end;

procedure TH1Dispatcher.TakePendingUpgrade;
begin
  { moves the pending upgrade from the connection state to the dispatcher }
  FPendingUpgrade := Conn.State.Upgrade;
  Conn.State.Upgrade.Active := False;
  Conn.State.Upgrade.Slot := nil;
end;

procedure TH1Dispatcher.TakeResponseBody(var B: TOutBody);
begin
  { the body moves out of the exchange; Ex.Resp keeps an empty body }
  if Ex.Resp.Source <> nil then
  begin
    B.Kind := obSource;
    B.Source := Ex.Resp.Source;
    Ex.Resp.Source := nil;
  end
  else
  begin
    B.Kind := obData;
    B.Data := Ex.Resp.Body;
    B.Taken := False;
    Ex.Resp.Body := BodyEmpty;
  end;
end;

function TH1Dispatcher.PollOutFrame(var B: TOutBody; out Data: TBodyData;
  out Trailers: THttpHeaders): TFramePoll;
begin
  Trailers := nil;
  if B.Kind = obSource then
    Exit(B.Source.PollFrame(Ex, Data, Trailers));
  { a one-frame body: the data once, then fpEnd }
  if B.Taken or (B.Data.Kind = bkEmpty) or (B.Data.Len = 0) then
  begin
    Data := BodyEmpty;
    B.Taken := True;
    Exit(fpEnd);
  end;
  Data := B.Data;
  B.Data := BodyEmpty;
  B.Taken := True;
  Result := fpData;
end;

procedure TH1Dispatcher.ClearBodyRx;
var
  S: TBodySource;
begin
  case BodyRx.Kind of
    obData:
      ReleaseBody(BodyRx.Data);
    obSource:
      begin
        S := BodyRx.Source;
        BodyRx.Source := nil;
        BodyRx.Kind := obNone;
        S.Done(Ex);
      end;
  else
  end;
  BodyRx.Kind := obNone;
  BodyRx.Taken := False;
end;

procedure TH1Dispatcher.GracefulShutdown;
begin
  { No new request will be read after the current one, which still gets
    its response. The wake makes an idle connection (waiting for a read
    that may never come) run now and close. }
  if FUpgraded or FDone then
    Exit;
  Conn.DisableKeepAlive;
  { nothing read or written yet (or writing already closed): close now
    instead of waiting for a request }
  if Conn.IsWriteClosed or Conn.HasInitialReadWriteState then
    Close_;
  Wake;
end;

procedure TH1Dispatcher.DropAll;
var
  T: TTransport;
  C: TServiceCall;
begin
  { Releases everything, in this order: the transport, a pending upgrade,
    the service call, the request body channel, the response body, the
    exchange, the connection state; then leaves the connection list. }
  FDone := True;
  { the transport: close(2), no shutdown; then an upgrade still pending
    (its handler gets "upgrade expected but not completed") }
  T := Conn.Io.Io;
  if T <> nil then
  begin
    Conn.Io.Io := nil;
    T.Close;
    if OwnsTransport then
      T.Free;
  end;
  if Conn.State.Upgrade.Active and (Conn.State.Upgrade.Slot <> nil) then
  begin
    Conn.State.Upgrade.Slot.Cancel;
    Conn.State.Upgrade.Slot.Release;
  end;
  Conn.State.Upgrade.Active := False;
  Conn.State.Upgrade.Slot := nil;
  { the call in flight: canceled and dropped (Completed = False) }
  if InFlight <> nil then
  begin
    C := InFlight;
    InFlight := nil;
    Ex.Cancel;
    C.Drop(Ex, False);
  end;
  { a request body still being received: the receiver gets an
    "incomplete" error }
  if BodyTx then
  begin
    BodyTx := False;
    Ex.Chan.SendError(NewIncomplete);
    Ex.Chan.CloseSender;
  end;
  ClearBodyRx;
  { a pending upgrade taken by PollInner and not handed on }
  if FPendingUpgrade.Active and (FPendingUpgrade.Slot <> nil) then
  begin
    if FPendingUpgrade.Slot.State = usPending then
      FPendingUpgrade.Slot.Cancel;
    FPendingUpgrade.Slot.Release;
  end;
  FPendingUpgrade.Active := False;
  FPendingUpgrade.Slot := nil;
  ReleaseExchange;
  Conn.Done;
  Unlink;
  if Hooks <> nil then
    Hooks.ConnDone(Self, Outcome, FUpgraded);
end;

procedure TH1Dispatcher.Abort;
begin
  { An exception escaped Run, or the server's shutdown deadline passed:
    release everything; no completion event is reported. }
  if not FDone then
    DropAll;
end;

procedure TH1Dispatcher.Finish(R: TPollResult; D: TDispatched; var Err: THyperError);
var
  T: TTransport;
  Rest: TBytesView;
  Parts: TConnParts;
  HaveParts: Boolean;
  U: TUpgraded;
  Delivery: TUpgradeDelivery;
  Slot: TUpgradeSlot;
  Detail: string;
begin
  { The connection has finished (R = prOk) or failed (R = prErr). }
  HaveParts := False;
  Delivery := nil;
  { 1. hand-off }
  if (R = prOk) and (D = dsUpgrade) and FPendingUpgrade.Active then
  begin
    Slot := FPendingUpgrade.Slot;
    if Mode = cmWithUpgrades then
    begin
      { take the transport and the bytes already read after the request
        (they belong to the new protocol) and fulfill the upgrade }
      Conn.Io.IntoInner(T, Rest);
      U := TUpgraded.CreateFrom(Loop, T, Rest, @Src, OwnsTransport);
      if Hooks <> nil then
      begin
        { the connection counts until the upgraded stream closes }
        U.CloseProc := @UpgradedCloseProc;
        U.CloseArg := Hooks;
      end;
      FUpgraded := True;
      Slot.Fulfill(U);
      FPendingUpgrade.Active := False;
      FPendingUpgrade.Slot := nil;
      Delivery := TUpgradeDelivery.Create;
      Delivery.Loop := Loop;
      Delivery.Slot := Slot;
    end
    else
    begin
      { this mode does not hand upgrades on: the handler gets "upgrade
        expected but low level API in use" }
      Slot.Manual;
      Slot.Release;
      FPendingUpgrade.Active := False;
      FPendingUpgrade.Slot := nil;
    end;
  end;
  if (Mode = cmWithoutShutdown) and (R = prOk) and (Conn.Io.Io <> nil) then
  begin
    { cmWithoutShutdown: the transport and the unread bytes go to the observer }
    Conn.Io.IntoInner(Parts.Transport, Parts.Rest);
    Parts.Src := @Src;
    HaveParts := True;
  end;
  { 2. release everything (the hooks get the outcome from DropAll) }
  Outcome := OutcomeOf(R, Err);
  DropAll;
  { 3. report the outcome }
  if Observer <> nil then
  begin
    if R = prOk then
      Detail := ''
    else
      Detail := ErrorDescription(Err, FErrorText);
    Observer.OnConnClose(ConnId, ObsData, Outcome, Detail);
  end;
  { 4. hand the connection on (the delivery task is queued; it runs after this Run returns) }
  if Delivery <> nil then
    Delivery.Wake;
  if HaveParts then
  begin
    if Observer <> nil then
      Observer.OnParts(ConnId, ObsData, Parts)
    else
    begin
      if Parts.Rest.Block <> nil then
        Parts.Rest.Release;
      Parts.Transport.Close;
      if OwnsTransport then
        Parts.Transport.Free;
    end;
  end;
  { 5. the task is freed at the end of the loop iteration (see bearings.rt.loop) }
  Close;
end;

end.

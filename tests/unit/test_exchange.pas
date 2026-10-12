{ M3 step S4 tests for the inline parts of bearings.http.exchange (design
  m3-transport.md 3.1-3.4, 3.7, 4.2, 4.5, 7.3 "Exchange", inline only):
  the call model driven the way the dispatcher drives it (Call in recv_msg,
  Poll in poll_msg, Drop exactly once, CompleteCall), an answer in the
  first poll, an answer from a TWakeTimer, cancel before the first poll,
  while waiting on the timer and after answering, a wake after recycle (or
  for an earlier request) is ignored, the request head and its pins,
  ReleaseRequest, TryRead, the terminal calls, SetReason, BodyCopy, the
  exchange pool, upgrades from the application's side.

  Not here (S7): an answer from a worker, Share / Release balance under 16
  threads, cross-thread wakes.
  Run: test_exchange --all --format=plain }
program test_exchange;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Classes, SysUtils, fpcunit, testregistry, consoletestrunner,
  bearings.rt.buf, bearings.rt.timer, bearings.rt.loop, bearings.rt.stream, bearings.http.headers, bearings.http1.parser,
  bearings.http1.role, bearings.http1.decode, bearings.http.error, bearings.http.exchange;

const
  CRLF = #13#10;
  HELLO: array[0..12] of AnsiChar = 'Hello, World!';
  HN_SERVER: array[0..5] of AnsiChar = 'server';
  HV_WD40: array[0..4] of AnsiChar = 'wd-40';

type
  TOwnerTask = class(TLoopTask)
  public
    Runs: Integer;
    procedure Run; override;
    procedure Abort; override;
  end;

  { 3.1's inline fast path: a stateless singleton call that answers in its first poll }
  TPlaintextCall = class(TServiceCall)
  public
    Drops, DropsCompleted: Integer;
    function Poll(Ex: TExchange): TCallPoll; override;
    procedure Drop(Ex: TExchange; Completed: Boolean); override;
  end;
  TPlaintextService = class(THttpService)
  public
    FCall: TPlaintextCall;
    Calls: Integer;
    constructor Create;
    destructor Destroy; override;
    function Call(Ex: TExchange): TServiceCall; override;
  end;

  { answers after a timer (loop-side state machine, 3.5) }
  TDelayCall = class(TServiceCall)
  public
    Timer: TWakeTimer;
    DelayMs: Int64;
    Polls, Drops: Integer;
    LastCompleted: Boolean;
    function Poll(Ex: TExchange): TCallPoll; override;
    procedure Drop(Ex: TExchange; Completed: Boolean); override;
  end;

  TRecUpgrade = class(TUpgradeHandler)
  public
    Failed: string;
    procedure Upgraded(U: TUpgraded); override;
    procedure UpgradeFailed(const Msg: string); override;
  end;

  TCountSource = class(TBodySource)
  public
    DoneCalls: Integer;
    function PollFrame(Ex: TExchange; out Data: TBodyData;
      out Trailers: THttpHeaders): TFramePoll; override;
    procedure Done(Ex: TExchange); override;
  end;

  TExCase = class(TTestCase)
  protected
    FLoop: TLoop;
    FTask: TOwnerTask;
    FPool: TExchangePool;
    FEx: TExchange;
    FBuf: TReadBuf;
    FLastRuns: Integer;
    procedure SetUp; override;
    procedure TearDown; override;
    { recv_msg: parse Req into a pinned head view, BeginRequest, FillHead }
    procedure StartRequest(const Req: RawByteString; RequestNo: LongWord = 1);
    function Wakes: Integer;
    function SliceStr(const S: TByteSlice): RawByteString;
  end;

  TTestExchangeLifetime = class(TExCase)
  published
    procedure Answer_in_first_poll;
    procedure Answer_from_timer;
    procedure Cancel_before_first_poll;
    procedure Cancel_while_waiting_on_timer;
    procedure Cancel_after_answer;
    procedure Wake_after_recycle_is_ignored;
    procedure Timer_of_earlier_request_does_not_wake;
    procedure Complete_without_answer_fails;
    procedure Complete_without_answer_asserts;
    procedure Pool_reuses_exchanges;
  end;

  TTestExchangeRequest = class(TExCase)
  published
    procedure Head_accessors;
    procedure Release_request_unpins_and_closes_receiver;
    procedure Try_read_frames;
    procedure Try_read_error_kinds;
    procedure Try_read_canceled;
    procedure Slice_helpers;
  end;

  TTestExchangeResponse = class(TExCase)
  published
    procedure Respond_once;
    procedure Respond_text;
    procedure Respond_stream_and_fail;
    procedure Set_reason;
    procedure Body_copy_uses_loop_pool;
    procedure Upgrade_handlers;
  end;

var
  ReleasedBodies: Integer = 0;

procedure CountRelease(Ctx: Pointer; Data: PByte);
begin
  Inc(ReleasedBodies);
end;

function CountedBody: TBodyData;
begin
  Result := BodyStatic(@HELLO[0], SizeOf(HELLO));
  Result.Own := boCustom;
  Result.ReleaseProc := @CountRelease;
end;

{ ---- doubles ---- }

procedure TOwnerTask.Run;
begin
  Inc(Runs);
end;

procedure TOwnerTask.Abort;
begin
end;

function TPlaintextCall.Poll(Ex: TExchange): TCallPoll;
begin
  Ex.ResponseHeaders.AddTrusted(@HN_SERVER[0], 6, @HV_WD40[0], 5);
  Ex.Respond(BodyStatic(@HELLO[0], SizeOf(HELLO)));
  Result := cpReady;
end;

procedure TPlaintextCall.Drop(Ex: TExchange; Completed: Boolean);
begin
  Inc(Drops);
  if Completed then
    Inc(DropsCompleted);
end;

constructor TPlaintextService.Create;
begin
  inherited Create;
  FCall := TPlaintextCall.Create;
end;

destructor TPlaintextService.Destroy;
begin
  FCall.Free;
  inherited Destroy;
end;

function TPlaintextService.Call(Ex: TExchange): TServiceCall;
begin
  Inc(Calls);
  Result := FCall;
end;

function TDelayCall.Poll(Ex: TExchange): TCallPoll;
begin
  Inc(Polls);
  if Polls = 1 then
  begin
    Timer.Arm(Ex, DelayMs);
    Exit(cpPending);
  end;
  if not Timer.Fired then
    Exit(cpPending);
  Ex.Status := 202;
  Ex.Respond(BodyEmpty);
  Result := cpReady;
end;

procedure TDelayCall.Drop(Ex: TExchange; Completed: Boolean);
begin
  Inc(Drops);
  LastCompleted := Completed;
  Timer.Cancel(Ex);
end;

procedure TRecUpgrade.Upgraded(U: TUpgraded);
begin
end;

procedure TRecUpgrade.UpgradeFailed(const Msg: string);
begin
  Failed := Msg;
end;

function TCountSource.PollFrame(Ex: TExchange; out Data: TBodyData;
  out Trailers: THttpHeaders): TFramePoll;
begin
  Data := BodyEmpty;
  Trailers := nil;
  Result := fpEnd;
end;

procedure TCountSource.Done(Ex: TExchange);
begin
  Inc(DoneCalls);
end;

{ ---- fixture ---- }

procedure TExCase.SetUp;
begin
  FLoop := TLoop.Create(0);
  FTask := TOwnerTask.Create;
  FTask.Loop := FLoop;
  FPool := TExchangePool.Create;
  FEx := FPool.Take(FLoop);
  FBuf := Default(TReadBuf);
  FLastRuns := 0;
  ReleasedBodies := 0;
end;

procedure TExCase.TearDown;
begin
  if FEx <> nil then
    FPool.Give(FEx);
  FPool.Free;
  FBuf.Done;
  FLoop.Free;                        { unlinks the task if it is still queued }
  FTask.Free;
end;

procedure TExCase.StartRequest(const Req: RawByteString; RequestNo: LongWord);
var
  Msg: TParsedRequestHead;
  View: TBytesView;
begin
  FEx.ReleaseRequest;                { the previous request, if a test left it }
  FBuf.Reserve(Length(Req), @FLoop.Blocks);
  Move(Req[1], FBuf.SpareData^, Length(Req));
  FBuf.AdvanceMut(Length(Req));
  AssertTrue('parse', ServerParse(FBuf.Ptr, FBuf.Len, DefaultParseContext, FEx.Head.Headers, Msg)
    = spsComplete);
  View := FBuf.SplitTo(Msg.HeadLen);
  FEx.BeginRequest(FTask);
  FEx.FillHead(Msg, View, RequestNo);
  if Msg.Decode <> DECODED_LENGTH_ZERO then
    FEx.Chan.Open(Msg.ExpectContinue);
end;

function TExCase.Wakes: Integer;
begin
  if FTask.Queued then
    FLoop.RunIteration;
  Result := FTask.Runs - FLastRuns;
  FLastRuns := FTask.Runs;
end;

function TExCase.SliceStr(const S: TByteSlice): RawByteString;
begin
  SetString(Result, PAnsiChar(S.P), S.Len);
end;

{ ================= lifetime ================= }

procedure TTestExchangeLifetime.Answer_in_first_poll;
var
  Svc: TPlaintextService;
  C: TServiceCall;
  B: PBufBlock;
begin
  Svc := TPlaintextService.Create;
  try
    StartRequest('GET /plaintext HTTP/1.1' + CRLF + 'Host: x' + CRLF + CRLF);
    B := FEx.Head.View.Block;
    AssertEquals('head pinned', 1, B^.Pins);
    { recv_msg: Call creates the call, the handler body has not run }
    C := Svc.Call(FEx);
    AssertFalse('nothing answered in Call', FEx.Answered);
    { poll_msg }
    AssertTrue('ready in the first poll', C.Poll(FEx) = cpReady);
    C.Drop(FEx, True);
    FEx.CompleteCall;
    AssertEquals('one Drop, completed', 1, Svc.FCall.DropsCompleted);
    AssertTrue('answered', FEx.Answered);
    AssertFalse(FEx.Resp.Failed);
    AssertEquals(200, FEx.Status);
    AssertEquals('body', 13, FEx.Resp.Body.Len);
    AssertTrue('static, no copy', FEx.Resp.Body.P = @HELLO[0]);
    AssertEquals('wd-40', FEx.ResponseHeaders.GetValue('server'));
    AssertTrue('completion drops the request', FEx.Head.Released);
    AssertEquals('head unpinned', 0, B^.Pins);
    AssertEquals('no wake needed', 0, Wakes);
    { the next request on the same exchange (count is 1): reused }
    StartRequest('GET /2 HTTP/1.1' + CRLF + CRLF, 2);
    AssertEquals('new response head', 0, FEx.ResponseHeaders.Count);
    AssertFalse(FEx.Answered);
    AssertEquals(2, Integer(FEx.RequestNo));
    C := Svc.Call(FEx);
    AssertTrue(C.Poll(FEx) = cpReady);
    C.Drop(FEx, True);
    FEx.CompleteCall;
    AssertEquals(2, Svc.FCall.DropsCompleted);
  finally
    Svc.Free;
  end;
end;

procedure TTestExchangeLifetime.Answer_from_timer;
var
  C: TDelayCall;
begin
  C := TDelayCall.Create;
  try
    C.DelayMs := 10;
    StartRequest('GET / HTTP/1.1' + CRLF + CRLF);
    AssertTrue('pending', C.Poll(FEx) = cpPending);
    AssertTrue('timer armed', C.Timer.T.Deadline > 0);
    AssertTrue('not yet', C.Poll(FEx) = cpPending);
    FLoop.Timers.Advance(FLoop.NowMs + 5);
    AssertEquals('not yet fired', 0, Wakes);
    FLoop.Timers.Advance(FLoop.NowMs + 11);
    AssertEquals('the timer woke the connection', 1, Wakes);
    AssertTrue('ready', C.Poll(FEx) = cpReady);
    C.Drop(FEx, True);
    FEx.CompleteCall;
    AssertEquals(202, FEx.Status);
    AssertTrue(C.LastCompleted);
    AssertEquals(1, C.Drops);
  finally
    C.Free;
  end;
end;

procedure TTestExchangeLifetime.Cancel_before_first_poll;
var
  Svc: TPlaintextService;
  C: TServiceCall;
begin
  { mid_message_detect_eof saw EOF before poll_write polled the call: the
    future is dropped without a poll (handler_dropped, 3.1) }
  Svc := TPlaintextService.Create;
  try
    StartRequest('GET / HTTP/1.1' + CRLF + CRLF);
    C := Svc.Call(FEx);
    FEx.Cancel;
    C.Drop(FEx, False);
    AssertTrue('canceled', FEx.IsCanceled);
    AssertEquals('dropped once, not completed', 1, Svc.FCall.Drops);
    AssertEquals(0, Svc.FCall.DropsCompleted);
    AssertTrue('request dropped with the future', FEx.Head.Released);
    AssertTrue('no owner', FEx.Owner = nil);
    AssertFalse('a late answer is refused', FEx.Respond(CountedBody));
    AssertEquals('and its body released', 1, ReleasedBodies);
    AssertFalse('Fail refused', FEx.Fail('late'));
    FEx.Wake;
    AssertEquals('no owner, no wake', 0, Wakes);
  finally
    Svc.Free;
  end;
end;

procedure TTestExchangeLifetime.Cancel_while_waiting_on_timer;
var
  C: TDelayCall;
begin
  C := TDelayCall.Create;
  try
    C.DelayMs := 10;
    StartRequest('GET / HTTP/1.1' + CRLF + CRLF);
    AssertTrue(C.Poll(FEx) = cpPending);
    FEx.Cancel;
    C.Drop(FEx, False);
    AssertFalse('not completed', C.LastCompleted);
    AssertEquals('Drop removed the timer', 0, C.Timer.T.Deadline);
    FLoop.Timers.Advance(FLoop.NowMs + 50);
    AssertEquals('nothing woken', 0, Wakes);
    AssertTrue(FEx.IsCanceled);
  finally
    C.Free;
  end;
end;

procedure TTestExchangeLifetime.Cancel_after_answer;
begin
  { answered but not yet collected by poll_msg: the CAS of 3.2.3 rule 5 fails,
    the state stays answered }
  StartRequest('GET / HTTP/1.1' + CRLF + CRLF);
  AssertTrue(FEx.Respond(BodyEmpty));
  FEx.Cancel;
  AssertFalse('not canceled', FEx.IsCanceled);
  AssertTrue('answered', FEx.Answered);
end;

procedure TTestExchangeLifetime.Wake_after_recycle_is_ignored;
var
  C: TDelayCall;
begin
  C := TDelayCall.Create;
  try
    C.DelayMs := 10;
    StartRequest('GET / HTTP/1.1' + CRLF + CRLF);
    AssertTrue(C.Poll(FEx) = cpPending);
    { the connection ends; the exchange goes back to the pool while the
      call (a buggy one: no Cancel in its Drop) leaves the timer armed }
    FPool.Give(FEx);
    FEx.BeginRequest(FTask);       { taken again by some connection: a new generation }
    FLoop.Timers.Advance(FLoop.NowMs + 50);
    AssertTrue('fired', C.Timer.Fired);
    AssertEquals('the generation check drops the wake', 0, Wakes);
    FEx := FPool.Take(FLoop);
  finally
    C.Free;
  end;
end;

procedure TTestExchangeLifetime.Timer_of_earlier_request_does_not_wake;
var
  C: TDelayCall;
begin
  C := TDelayCall.Create;
  try
    C.DelayMs := 10;
    StartRequest('GET / HTTP/1.1' + CRLF + CRLF);
    AssertTrue(C.Poll(FEx) = cpPending);
    FEx.Respond(BodyEmpty);
    FEx.CompleteCall;
    StartRequest('GET /2 HTTP/1.1' + CRLF + CRLF, 2);
    FLoop.Timers.Advance(FLoop.NowMs + 50);
    AssertEquals('request 2 is not woken by request 1''s timer', 0, Wakes);
    C.Timer.Cancel(FEx);
  finally
    C.Free;
  end;
end;

procedure TTestExchangeLifetime.Complete_without_answer_fails;
var
  N0: LongInt;
begin
  { the production behaviour: the completion counts and fails the exchange;
    NoResponseIsExpected keeps this -Sa build from raising }
  N0 := NoResponseFailures;
  StartRequest('GET / HTTP/1.1' + CRLF + CRLF);
  FEx.NoResponseIsExpected;
  FEx.CompleteCall;
  AssertTrue('failed', FEx.Resp.Failed);
  AssertEquals('handler returned no response', FEx.Resp.FailText);
  AssertEquals('counted once', 1, NoResponseFailures - N0);
end;

procedure TTestExchangeLifetime.Complete_without_answer_asserts;
var
  N0: LongInt;
  Msg: string;
begin
  { user decision 2026-10-11 (option B): a build with assertions raises for a
    completion without a terminal call, after the exchange was left
    consistent (done, failed, request released) }
  N0 := NoResponseFailures;
  StartRequest('GET /no-answer?x=1 HTTP/1.1' + CRLF + CRLF);
  Msg := '';
  try
    FEx.CompleteCall;
  except
    on E: EAssertionFailed do
      Msg := E.Message;
  end;
  AssertTrue('raised (got "' + Msg + '")', Pos('without a terminal call', Msg) > 0);
  AssertTrue('names the request', Pos('GET /no-answer', Msg) > 0);
  AssertEquals('counted once', 1, NoResponseFailures - N0);
  AssertTrue('failed', FEx.Resp.Failed);
  AssertEquals('handler returned no response', FEx.Resp.FailText);
  AssertTrue('request released', FEx.Head.Released);
  { the opt-out is per request: cleared by BeginRequest }
  StartRequest('GET /2 HTTP/1.1' + CRLF + CRLF, 2);
  FEx.NoResponseIsExpected;
  FEx.CompleteCall;
  StartRequest('GET /3 HTTP/1.1' + CRLF + CRLF, 3);
  Msg := '';
  try
    FEx.CompleteCall;
  except
    on E: EAssertionFailed do
      Msg := E.Message;
  end;
  AssertTrue('raises again for the next request', Pos('GET /3', Msg) > 0);
  AssertEquals('counted three times', 3, NoResponseFailures - N0);
end;

procedure TTestExchangeLifetime.Pool_reuses_exchanges;
var
  A, B: TExchange;
  G: LongWord;
begin
  A := FEx;
  G := A.Generation;
  FPool.Give(A);
  AssertEquals(1, FPool.FreeCount);
  AssertTrue('recycle bumps the generation', A.Generation <> G);
  B := FPool.Take(FLoop);
  AssertTrue('LIFO reuse', A = B);
  AssertEquals(0, FPool.FreeCount);
  AssertTrue(B.Loop = FLoop);
  FEx := B;
end;

{ ================= request ================= }

procedure TTestExchangeRequest.Head_accessors;
var
  S: TByteSlice;
begin
  StartRequest('POST /a/b?x=1 HTTP/1.1' + CRLF + 'Host: h' + CRLF + 'Content-Length: 4' + CRLF +
    'Expect: 100-continue' + CRLF + CRLF, 7);
  AssertTrue(FEx.Method = hmPost);
  AssertEquals('POST', SliceStr(FEx.MethodBytes));
  AssertEquals('/a/b?x=1', SliceStr(FEx.Target));
  AssertEquals('/a/b', SliceStr(FEx.Path));
  AssertTrue(FEx.Query(S));
  AssertEquals('x=1', SliceStr(S));
  AssertTrue(FEx.Version = hv11);
  AssertTrue(FEx.Header('host', S));
  AssertEquals('h', SliceStr(S));
  AssertFalse(FEx.Header('missing', S));
  AssertEquals(4, FEx.ContentLength);
  AssertTrue(FEx.ExpectsContinue);
  AssertFalse(FEx.WantsUpgrade);
  AssertEquals(7, Integer(FEx.RequestNo));
  AssertFalse('want = !wanter', FEx.Chan.Want);
end;

procedure TTestExchangeRequest.Release_request_unpins_and_closes_receiver;
var
  B: PBufBlock;
  Closed: Boolean;
  Slot: TUpgradeSlot;
begin
  StartRequest('POST / HTTP/1.1' + CRLF + 'Content-Length: 4' + CRLF + CRLF);
  B := FEx.Head.View.Block;
  Slot := TUpgradeSlot.Create;
  try
    Slot.RxAlive := True;
    FEx.LinkUpgrade(Slot);
    FEx.ReleaseRequest;
    AssertTrue(FEx.Head.Released);
    AssertEquals('head unpinned', 0, B^.Pins);
    AssertTrue('receiver closed: sender sees Err(closed)', FEx.Chan.PollReady(Closed) and Closed);
    AssertFalse('an OnUpgrade nobody took is dropped with the request', Slot.RxAlive);
    FEx.ReleaseRequest;
    AssertEquals('idempotent', 0, B^.Pins);
  finally
    Slot.Release;
  end;
end;

procedure TTestExchangeRequest.Try_read_frames;
var
  Ch: TByteSlice;
  V: TBytesView;
begin
  StartRequest('POST / HTTP/1.1' + CRLF + 'Transfer-Encoding: chunked' + CRLF + CRLF + 'abc');
  V := FBuf.SplitTo(3);
  AssertTrue('nothing yet', FEx.TryRead(Ch) = brPending);
  AssertTrue(FEx.Chan.TrySendData(V));
  AssertEquals('send wakes the receiver', 1, Wakes);
  AssertTrue(FEx.TryRead(Ch) = brData);
  AssertEquals('abc', SliceStr(Ch));
  FEx.ReqTrailers.AddTrusted('x-t', 'v');
  AssertTrue(FEx.Chan.TrySendTrailers);
  FEx.Chan.CloseSender;
  AssertTrue('trailers after data', FEx.TryRead(Ch) = brTrailers);
  AssertEquals('v', FEx.RequestTrailers.GetValue('x-t'));
  AssertTrue(FEx.TryRead(Ch) = brEnd);
  AssertTrue('the last chunk was released', FEx.Chan.Held.Block = nil);
end;

procedure TTestExchangeRequest.Try_read_error_kinds;
var
  Ch: TByteSlice;
begin
  StartRequest('POST / HTTP/1.1' + CRLF + 'Content-Length: 4' + CRLF + CRLF);
  FEx.Chan.SendError(NewBodyDecode(deIncompleteBody));
  AssertTrue(FEx.TryRead(Ch) = brError);
  AssertTrue(FEx.BodyErrorKind = bekUnexpectedEof);
  AssertEquals('end of file before message length reached', FEx.BodyErrorMessage);
  FEx.Chan.SendError(NewBodyDecode(deSizeOverflow));
  AssertTrue(FEx.TryRead(Ch) = brError);
  AssertTrue(FEx.BodyErrorKind = bekInvalidData);
  AssertEquals('invalid chunk size: overflow', FEx.BodyErrorMessage);
  FEx.Chan.SendError(NewBodyDecode(deInvalidSizeLf));
  AssertTrue(FEx.TryRead(Ch) = brError);
  AssertTrue(FEx.BodyErrorKind = bekInvalidInput);
  FEx.Chan.SendError(NewBodyIo(104));
  AssertTrue(FEx.TryRead(Ch) = brError);
  AssertTrue(FEx.BodyErrorKind = bekIo);
  AssertTrue(Pos('(os error 104)', FEx.BodyErrorMessage) > 0);
  FEx.Chan.SendError(NewBodyStatic('connection error'));
  AssertTrue(FEx.TryRead(Ch) = brError);
  AssertTrue(FEx.BodyErrorKind = bekOther);
  AssertEquals('error reading a body from connection: connection error', FEx.BodyErrorMessage);
end;

procedure TTestExchangeRequest.Try_read_canceled;
var
  Ch: TByteSlice;
begin
  StartRequest('POST / HTTP/1.1' + CRLF + 'Content-Length: 4' + CRLF + CRLF);
  FEx.Cancel;
  AssertTrue(FEx.TryRead(Ch) = brCanceled);
end;

procedure TTestExchangeRequest.Slice_helpers;
var
  S, E: TByteSlice;
begin
  StartRequest('GET /items?x=1 HTTP/1.1' + CRLF + 'Host: h' + CRLF + CRLF);
  AssertEquals('/items', SliceToStr(FEx.Path));
  AssertTrue('the path', PathIs(FEx, '/items'));
  AssertFalse('a prefix', PathIs(FEx, '/item'));
  AssertFalse('a longer text', PathIs(FEx, '/items/'));
  AssertFalse('byte-exact: no case folding', PathIs(FEx, '/Items'));
  AssertFalse('the query is not part of the path', PathIs(FEx, '/items?x=1'));
  AssertTrue(FEx.Header('host', S));
  AssertTrue('a header value', SliceEquals(S, 'h'));
  AssertFalse(SliceEquals(S, 'H'));
  AssertFalse(SliceEquals(S, ''));
  E.P := nil;
  E.Len := 0;
  AssertTrue('an empty slice equals the empty string', SliceEquals(E, ''));
  AssertFalse(SliceEquals(E, 'a'));
  AssertEquals('', SliceToStr(E));
end;

{ ================= response ================= }

procedure TTestExchangeResponse.Respond_text;
var
  S: RawByteString;
  Raised: Boolean;
begin
  StartRequest('GET / HTTP/1.1' + CRLF + CRLF);
  AssertTrue(FEx.RespondText(404, 'not found'#10));
  AssertEquals(404, FEx.Status);
  AssertEquals('text/plain; charset=utf-8', FEx.ResponseHeaders.GetValue('content-type'));
  AssertEquals('one content-type', 1, FEx.ResponseHeaders.Count);
  SetString(S, PAnsiChar(FEx.Resp.Body.P), FEx.Resp.Body.Len);
  AssertEquals('not found'#10, S);
  AssertFalse('second terminal call refused', FEx.RespondText(500, 'x', 'text/html'));
  AssertEquals('the first answer''s status stands', 404, FEx.Status);
  AssertEquals('and its content-type', 'text/plain; charset=utf-8', FEx.ResponseHeaders.GetValue('content-type'));
  AssertEquals('and its body', 10, FEx.Resp.Body.Len);
  FEx.CompleteCall;

  { a content-type set earlier is replaced, not duplicated; the given type is kept }
  StartRequest('GET /2 HTTP/1.1' + CRLF + CRLF, 2);
  FEx.ResponseHeaders.Add('content-type', 'text/plain');
  AssertTrue(FEx.RespondText(200, '<p>hi</p>', 'text/html; charset=utf-8'));
  AssertEquals(1, FEx.ResponseHeaders.CountOf('content-type'));
  AssertEquals('text/html; charset=utf-8', FEx.ResponseHeaders.GetValue('content-type'));
  FEx.CompleteCall;

  { an invalid content-type raises (the validating mutator) and leaves the exchange unanswered }
  StartRequest('GET /3 HTTP/1.1' + CRLF + CRLF, 3);
  Raised := False;
  try
    FEx.RespondText(200, 'x', 'text/plain'#13#10'x-injected: 1');
  except
    on EInvalidHeader do
      Raised := True;
  end;
  AssertTrue('EInvalidHeader', Raised);
  AssertFalse('not answered', FEx.Answered);
  AssertTrue(FEx.RespondText(204, ''));
  AssertEquals(0, FEx.Resp.Body.Len);
  FEx.CompleteCall;

  { canceled: refused }
  StartRequest('GET /4 HTTP/1.1' + CRLF + CRLF, 4);
  FEx.Cancel;
  AssertFalse('canceled', FEx.RespondText(200, 'late'));
  AssertEquals('the head was not touched', 200, FEx.Status);
  AssertEquals(0, FEx.ResponseHeaders.Count);
end;

procedure TTestExchangeResponse.Respond_once;
begin
  StartRequest('GET / HTTP/1.1' + CRLF + CRLF);
  AssertTrue(FEx.Respond(BodyStatic(@HELLO[0], 5)));
  AssertFalse('second terminal call refused', FEx.Respond(CountedBody));
  AssertEquals('refused body released', 1, ReleasedBodies);
  AssertEquals('first body kept', 5, FEx.Resp.Body.Len);
end;

procedure TTestExchangeResponse.Respond_stream_and_fail;
var
  Src: TCountSource;
begin
  Src := TCountSource.Create;
  try
    StartRequest('GET / HTTP/1.1' + CRLF + CRLF);
    AssertTrue(FEx.RespondStream(Src));
    AssertTrue(FEx.Resp.Source = Src);
    AssertFalse('refused: Done called', FEx.RespondStream(Src));
    AssertEquals(1, Src.DoneCalls);
    FEx.Resp.Source := nil;

    StartRequest('GET /2 HTTP/1.1' + CRLF + CRLF, 2);
    AssertTrue(FEx.Fail('boom'));
    AssertTrue(FEx.Resp.Failed);
    AssertEquals('boom', FEx.Resp.FailText);
    AssertFalse(FEx.Respond(BodyEmpty));
    FEx.CompleteCall;
    AssertEquals('boom', FEx.Resp.FailText);
  finally
    Src.Free;
  end;
end;

procedure TTestExchangeResponse.Set_reason;
var
  S: RawByteString;
const
  Good: RawByteString = 'Very Good';
  Bad: RawByteString = 'Bad'#10'Reason';
begin
  StartRequest('GET / HTTP/1.1' + CRLF + CRLF);
  AssertFalse('LF refused', FEx.SetReason(PByte(Bad), Length(Bad)));
  AssertFalse(FEx.Resp.Head.HasReason);
  AssertTrue(FEx.SetReason(PByte(Good), Length(Good)));
  AssertTrue(FEx.Resp.Head.HasReason);
  SetString(S, PAnsiChar(FEx.Resp.Head.ReasonP), FEx.Resp.Head.ReasonLen);
  AssertEquals('copied', 'Very Good', S);
  AssertTrue('a copy, not the caller''s bytes', FEx.Resp.Head.ReasonP <> PByte(Good));
  StartRequest('GET /2 HTTP/1.1' + CRLF + CRLF, 2);
  AssertFalse('reset per request', FEx.Resp.Head.HasReason);
end;

procedure TTestExchangeResponse.Body_copy_uses_loop_pool;
var
  B: TBodyData;
  Before: SizeInt;
  S: RawByteString;
begin
  StartRequest('GET / HTTP/1.1' + CRLF + CRLF);
  S := 'dynamic body';
  B := BodyCopy(FEx, Pointer(S), Length(S));
  S[1] := 'X';
  SetString(S, PAnsiChar(B.P), B.Len);
  AssertEquals('copied', 'dynamic body', S);
  Before := FLoop.Blocks.PooledBytes;
  ReleaseBody(B);
  AssertTrue('the block went back to the loop pool', FLoop.Blocks.PooledBytes > Before);
  B := BodyCopy(FEx, nil, 0);
  AssertTrue('empty', B.Kind = bkEmpty);
end;

procedure TTestExchangeResponse.Upgrade_handlers;
var
  H: TRecUpgrade;
  Slot, Slot2: TUpgradeSlot;
begin
  H := TRecUpgrade.Create;
  Slot := TUpgradeSlot.Create;
  Slot2 := nil;
  try
    StartRequest('GET / HTTP/1.1' + CRLF + CRLF);
    FEx.OnUpgrade(H);
    AssertEquals('OnUpgrade::none()', 'no upgrade available', H.Failed);
    H.Failed := '';
    StartRequest('GET / HTTP/1.1' + CRLF + 'Upgrade: x' + CRLF + 'Connection: upgrade' + CRLF + CRLF, 2);
    AssertTrue(FEx.WantsUpgrade);
    Slot.State := usPending;
    Slot.RxAlive := True;
    FEx.LinkUpgrade(Slot);
    FEx.OnUpgrade(H);
    AssertTrue(Slot.Handler = H);
    FEx.ReleaseRequest;
    AssertTrue('taken: still alive after the request is dropped', Slot.RxAlive);
    Slot.Manual;
    AssertEquals('upgrade expected but low level API in use', H.Failed);
    { a oneshot (S6-5, hyper Pending::manual consumes the sender): a later
      Cancel reaches nobody }
    H.Failed := '';
    Slot.Cancel;
    AssertEquals('oneshot: no second result', '', H.Failed);
    AssertTrue('no handler after the result', Slot.Handler = nil);
    Slot.Fulfill(nil);
    AssertTrue(Slot.State = usFulfilled);
    { drop(Pending) on a slot whose handler got nothing yet }
    Slot2 := TUpgradeSlot.Create;
    StartRequest('GET / HTTP/1.1' + CRLF + 'Upgrade: x' + CRLF + 'Connection: upgrade' + CRLF + CRLF, 3);
    Slot2.State := usPending;
    FEx.LinkUpgrade(Slot2);
    FEx.OnUpgrade(H);
    Slot2.Cancel;
    AssertEquals('upgrade expected but not completed', H.Failed);
  finally
    Slot.Release;
    if Slot2 <> nil then
      Slot2.Release;
    H.Free;
  end;
end;

begin
  RegisterTest(TTestExchangeLifetime);
  RegisterTest(TTestExchangeRequest);
  RegisterTest(TTestExchangeResponse);
  with TTestRunner.Create(nil) do
  try
    Initialize;
    Run;
  finally
    Free;
  end;
end.

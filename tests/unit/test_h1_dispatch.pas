{ M3 step S5 tests for bearings.http1.dispatch (port of hyper dispatch.rs) and
  bearings.server (docs/design.md sections 5, 7.3 and 9).

  Built with -dWD_DEBUG (run_all.sh): the wake-source assertion of 2.4.5 runs
  at the end of every Run that returns Pending, in every test; TearDown
  fails the test when it fired (WakeAssertFailures).

  TTestDispatchHyper: hyper's dispatcher regression tests in server form,
  over a scripted transport: tests/h1_flush_before_yield.rs,
  tests/h1_shutdown_while_buffered.rs, tests/unbuffered_stream.rs,
  tests/ready_on_poll_stream.rs, and dispatch.rs body_empty_chunks_ignored
  (server form: an empty data frame never reaches write_body).
  TTestDispatchPipeline: 16 requests in one read -> one write with
  pipeline_flush; 32 -> a yield after 16 poll_loop iterations and the second
  half in the same loop iteration (run-queue budget); without pipeline_flush
  one write per response.
  TTestDispatchBehavior: wire bytes, keep-alive, request bodies (prefetch,
  across reads, expect/continue), client EOF before the call was polled,
  service failure, parse errors, graceful shutdown, the 0.9/3.0 panic,
  upgrades in the three modes, idle release (4.3), the header read timeout,
  response body errors.
  Step H: the parse-error-after-a-blocked-body tests (Parse_error_behind_*), the
  decision 10 test (Cancelled_call_dropped_once: the dispatcher drops an
  abandoned call exactly once, for every way of abandoning it), the 4.3
  trailer scratch release (decision 13), and Unbuffered_stream's hot-polling
  check through TScriptIo.WritesWhileBlocked.
  TTestDispatchServer: TServer over real sockets (accept, keep-alive,
  pipelining, graceful shutdown of connections, stop).
  TTestDispatchStall (built with -dWD_STALL as well, step UB): the stall
  detector reports only where the server owes progress (2.4.5): not a head
  or a body that waits on the client, but a pending call, a readiness event
  the task did not act on, a queued task; only after 60 s.
  Run: test_h1_dispatch --all --format=plain }
program test_h1_dispatch;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Classes, SysUtils, StrUtils, fpcunit, testregistry, consoletestrunner, Sockets, BaseUnix,
  ctypes, bearings.rt.sys, bearings.rt.buf, bearings.rt.timer, bearings.rt.loop, bearings.rt.net, bearings.rt.stream, bearings.http.headers,
  bearings.http1.role, bearings.http.error, bearings.http.exchange, bearings.http1.io, bearings.http1.conn, bearings.http1.config,
  bearings.http1.dispatch, bearings.server, bearings.http1.encode, bearings.test.scriptio;

const
  CRLF = #13#10;
  GET_REQ = 'GET / HTTP/1.1' + CRLF + 'Host: x' + CRLF + CRLF;

type
  { ---- services ---- }
  TTestService = class;

  { One configurable call per service (stateful: tests serve one request at a time, or
    the same answer for every request). }
  TTestCall = class(TServiceCall)
  public
    Svc: TTestService;
    Polls: Integer;
    Body: RawByteString;             { request body read so far }
    BodyEnded: Boolean;
    function Poll(Ex: TExchange): TCallPoll; override;
    procedure Drop(Ex: TExchange; Completed: Boolean); override;
  end;

  TTestService = class(THttpService)
  public
    Call_: TTestCall;
    Calls, DropsDone, DropsAbandoned: Integer;
    { behavior }
    PendPolls: Integer;              { Pending (with Ex.Wake) this many times first }
    PendForever: Boolean;            { Pending, no wake, every time (a call waiting on something else) }
    DropCanceled: Integer;           { Drop(Ex, False) calls that saw Ex.IsCanceled }
    ReadBody: Boolean;               { read the whole request body before answering }
    Status: Word;
    RespBody: RawByteString;
    RespVersion: THttpVersion;
    Stream: TBodySource;             { RespondStream when set }
    FailMsg: RawByteString;          { Fail when set }
    { cpReady without a terminal call (a program error in the call); NoAnswerExpected: Call
      opts the exchange out of the -Sa raise (NoResponseIsExpected) }
    NoAnswer, NoAnswerExpected: Boolean;
    Upgrade: TUpgradeHandler;        { Ex.OnUpgrade in the first poll }
    Headers: TStringList;            { name=value }
    FirstTryRead: TBodyReadStatus;   { result of the first TryRead (prefetch check) }
    FirstTryReadSet: Boolean;
    LastPath, LastBody: RawByteString;
    { S7 fix round 7: what Call itself does (docs/design.md 5.3: it must not answer or read the body;
      builds with assertions assert it): 0 nothing, 1 Respond, 2 TryRead, 3 Fail, 4 BeginStream }
    InCall: Integer;
    constructor Create;
    destructor Destroy; override;
    function Call(Ex: TExchange): TServiceCall; override;
  end;

  { a response body from a script: 'd:<data>', 'p' (Pending, no wake), 'w' (Pending with
    Ex.Wake), 'e' (error), 't' (trailers x-t: 1), end when the script runs out }
  TScriptSource = class(TBodySource)
  public
    Frames: TStringList;
    Pos: Integer;
    Exact: Int64;                    { >= 0: SizeHint exact }
    DoneCalls: Integer;
    Trl: THttpHeaders;
    constructor Create(const Script: array of string);
    destructor Destroy; override;
    function SizeHint(out AExact: QWord): Boolean; override;
    function PollFrame(Ex: TExchange; out Data: TBodyData;
      out Trailers: THttpHeaders): TFramePoll; override;
    procedure Done(Ex: TExchange); override;
  end;

  TRecUpgrade = class(TUpgradeHandler)
  public
    Failed: string;
    Got: TUpgraded;
    Leftover: RawByteString;
    procedure Upgraded(U: TUpgraded); override;
    procedure UpgradeFailed(const Msg: string); override;
  end;

  TRecObserver = class(TConnObserver)
  public
    Closes: Integer;
    Outcome: TConnOutcome;
    Detail: string;
    PartsRest: RawByteString;
    PartsCount: Integer;
    Log: TStrings;
    procedure OnConnClose(ConnId: QWord; Data: Pointer; Outcome_: TConnOutcome;
      const Detail_: string); override;
    procedure OnParts(ConnId: QWord; Data: Pointer; var Parts: TConnParts); override;
  end;

  { ---- fixture ---- }
  { the fixture's dispatcher: records that the loop freed it (a task that
    closes inside a run-queue iteration is freed at the end of that
    iteration, 1.6 step 7) }
  TFixtureDispatcher = class(TH1Dispatcher)
  public
    Freed: PBoolean;
    destructor Destroy; override;
  end;

  TDispCase = class(TTestCase)
  protected
    FLoop: TLoop;
    FPool: TExchangePool;
    FIo: TScriptIo;
    { nil once the loop freed it (FDFreed); tests that can close inside a
      run-queue iteration check Done, not FD.Closed }
    FD: TH1Dispatcher;
    FDFreed: Boolean;
    FSvc: TTestService;
    FObs: TRecObserver;
    FCfg: TH1Config;
    FLog: TStringList;
    FWakeFailures0: Integer;
    FNoResponse0: LongInt;
    { how many completions without a terminal call the test drives on purpose
      (TearDown checks NoResponseFailures against it; default 0) }
    ExpectedNoResponses: Integer;
    FRuns: Integer;
    procedure SetUp; override;
    procedure TearDown; override;
    procedure Start;
    { runs the connection as the loop would: queued -> one loop iteration; a blocked transport
      with more script -> the readiness edge (Run); otherwise stops (stall or done) }
    procedure Drive(MaxSteps: Integer = 10000);
    function Done: Boolean;
  end;

  TTestDispatchHyper = class(TDispCase)
  published
    procedure H1_flush_before_yield;
    procedure H1_shutdown_while_buffered;
    procedure Unbuffered_stream;
    procedure Ready_on_poll_stream;
    procedure Body_empty_chunks_ignored;
  end;

  TTestDispatchPipeline = class(TDispCase)
  published
    procedure Pipelining_16_one_write;
    procedure Pipelining_32_yield_same_iteration;
    procedure Pipelining_without_flush_one_write_each;
  end;

  TTestDispatchBehavior = class(TDispCase)
  published
    procedure Get_response_bytes;
    procedure Keep_alive_two_requests;
    procedure Request_body_prefetched_before_first_poll;
    procedure Request_body_across_reads;
    procedure Expect_continue_sent_on_first_read;
    procedure Expect_continue_not_sent_when_unread;
    procedure Disconnect_before_call_polled;
    procedure Service_fail_no_response;
    procedure Parse_error_400_then_shutdown;
    procedure Eof_when_idle_is_ok;
    procedure Graceful_shutdown_idle;
    procedure Graceful_shutdown_in_flight;
    procedure Response_version_panic_aborts;
    procedure Upgrade_plain_mode_manual;
    procedure Upgrades_ignored_no_shutdown;
    procedure With_upgrades_delivers_after_close;
    procedure Without_shutdown_parts;
    procedure Idle_releases_exchange_and_blocks;
    procedure Header_read_timeout;
    procedure Body_rate_rule_outcome_io;
    procedure Body_framing_error_outcome_io;
    procedure Body_socket_error_outcome_io;
    procedure Stream_body_error_is_user;
    procedure Http10_closes;
    procedure Write_error_ends_connection;
    procedure Pending_call_woken_by_timer;
    { step H }
    procedure Parse_error_behind_queued_body;
    procedure Cancelled_call_dropped_once;
    procedure Idle_releases_trailer_scratch;
    { step H fixes after the H verifier }
    procedure Parse_error_behind_16_queued_entries;
    procedure Abort_releases_upgrade_slot;
    procedure Error_releases_taken_upgrade_slot;
    { S6 fixes: deviation S6-15 (decision 14). With pipeline_flush the
      response held while the read buffer has bytes is flushed once the
      connection is done (hyper 1.12.0 drops it in into_inner / skips it in
      poll_shutdown) }
    procedure Pipeline_flush_upgrade_101_before_hand_off;
    procedure Pipeline_flush_upgrade_101_write_pending;
    { the PROXY protocol header (TH1Config.ProxyProtocol) and the
      connection's lifetime caps (MaxRequests, MaxConnectionMs) }
    procedure Proxy_header_v1_sets_the_peer;
    procedure Proxy_header_v2_split_across_reads;
    procedure Proxy_header_missing_closes_without_response;
    procedure Proxy_header_eof_before_it_is_ok;
    procedure Max_requests_closes_after_the_last_one;
    procedure Pipeline_flush_keep_alive_off_pipelined;
    procedure Pipeline_flush_parts_response_written;
    procedure No_pipeline_flush_unchanged_at_end;
    { S7 fix round 7: the docs/design.md 5.3 rule for THttpService.Call, asserted }
    procedure Call_that_answers_asserts;
    procedure Call_that_reads_asserts;
    { user decision 2026-10-11 (option B): a call that completes without a terminal call }
    procedure Call_without_answer_closes_with_user_error;
    procedure Call_without_answer_asserts;
  end;

  TTestDispatchServer = class(TTestCase)
  published
    procedure Server_keep_alive_and_pipelining;
    procedure Server_graceful_shutdown_connections;
    procedure Server_stop_with_idle_connections;
    procedure Server_setup_failure_closes_connection_and_continues;
    { S6: the upgrade hand-off through an observer's wrapping transport (the
      conformance server's TCountingTransport) moves the socket to the
      upgraded stream; the loop side of TUpgraded (Attach, TryRead with the
      leftover first, TryWrite) runs on it }
    procedure Server_upgrade_through_wrapping_observer;
    { S6: without_shutdown parts: the observer moves the readiness source
      (TConnParts.Src) with TUpgraded.CreateFrom and keeps the socket }
    procedure Server_without_shutdown_parts_keep_socket;
    { S6: TConnObserver.OnStart runs before the first Run (graceful
      shutdown on accept: closed, nothing written) }
    procedure Server_observer_on_start;
    { S6 fixes: an exception from the upgrade handler (the queued delivery
      task) still releases the connection's slot reference (decision 9) }
    procedure Server_upgrade_handler_raises_releases_slot;
    { S6 fixes: a raw write that meets EAGAIN resumes from Writable on the
      next writable edge (the listener writes only in Writable) }
    procedure Server_upgraded_write_resumes_on_writable;
    { S6 fixes: the hand-off with pipeline_flush on and a leftover keeps the
      101 (deviation S6-15) }
    procedure Server_upgrade_pipeline_flush_keeps_101;
  end;

{ ---- services ---- }

constructor TTestService.Create;
begin
  inherited Create;
  Call_ := TTestCall.Create;
  Call_.Svc := Self;
  Status := 200;
  RespBody := 'hello';
  RespVersion := hv11;
  Headers := TStringList.Create;
end;

destructor TTestService.Destroy;
begin
  Call_.Free;
  Headers.Free;
  inherited Destroy;
end;

function TTestService.Call(Ex: TExchange): TServiceCall;
var
  C: TByteSlice;
begin
  case InCall of
    1: Ex.Respond(BodyEmpty);
    2: Ex.TryRead(C);
    3: Ex.Fail('in call');
    4: Ex.BeginStream(1024);
  end;
  if NoAnswerExpected then
    Ex.NoResponseIsExpected;
  Inc(Calls);
  Call_.Polls := 0;
  Call_.Body := '';
  Call_.BodyEnded := False;
  FirstTryReadSet := False;
  Result := Call_;
end;

function TTestCall.Poll(Ex: TExchange): TCallPoll;
var
  Ch: TByteSlice;
  St: TBodyReadStatus;
  I: Integer;
  S: RawByteString;
  P: TByteSlice;
begin
  Inc(Polls);
  if Polls = 1 then
  begin
    P := Ex.Path;
    SetString(S, PAnsiChar(P.P), P.Len);
    Svc.LastPath := S;
    if Svc.Upgrade <> nil then
      Ex.OnUpgrade(Svc.Upgrade);
  end;
  if Svc.PendForever then
    Exit(cpPending);
  if Polls <= Svc.PendPolls then
  begin
    Ex.Wake;
    Exit(cpPending);
  end;
  if Svc.ReadBody and not BodyEnded then
    while True do
    begin
      St := Ex.TryRead(Ch);
      if not Svc.FirstTryReadSet then
      begin
        Svc.FirstTryRead := St;
        Svc.FirstTryReadSet := True;
      end;
      case St of
        brData:
          begin
            SetString(S, PAnsiChar(Ch.P), Ch.Len);
            Body := Body + S;
          end;
        brTrailers: ;
        brPending: Exit(cpPending);
      else
        begin
          BodyEnded := True;
          Break;
        end;
      end;
    end;
  Svc.LastBody := Body;
  if Svc.NoAnswer then
    Exit(cpReady);
  if Svc.FailMsg <> '' then
  begin
    Ex.Fail(Svc.FailMsg);
    Exit(cpReady);
  end;
  Ex.Status := Svc.Status;
  Ex.ResponseVersion := Svc.RespVersion;
  for I := 0 to Svc.Headers.Count - 1 do
    Ex.ResponseHeaders.Add(Svc.Headers.Names[I], Svc.Headers.ValueFromIndex[I]);
  if Svc.Stream <> nil then
    Ex.RespondStream(Svc.Stream)
  else if Svc.RespBody = '' then
    Ex.Respond(BodyEmpty)
  else
    Ex.Respond(BodyCopy(Ex, PAnsiChar(Svc.RespBody), Length(Svc.RespBody)));
  Result := cpReady;
end;

procedure TTestCall.Drop(Ex: TExchange; Completed: Boolean);
begin
  if Completed then
    Inc(Svc.DropsDone)
  else
  begin
    Inc(Svc.DropsAbandoned);
    if (Ex <> nil) and Ex.IsCanceled then
      Inc(Svc.DropCanceled);
  end;
end;

constructor TScriptSource.Create(const Script: array of string);
var
  I: Integer;
begin
  inherited Create;
  Frames := TStringList.Create;
  for I := 0 to High(Script) do
    Frames.Add(Script[I]);
  Exact := -1;
  Trl := THttpHeaders.Create;
  Trl.Add('x-t', '1');
end;

destructor TScriptSource.Destroy;
begin
  Frames.Free;
  Trl.Free;
  inherited Destroy;
end;

function TScriptSource.SizeHint(out AExact: QWord): Boolean;
begin
  Result := Exact >= 0;
  if Result then
    AExact := QWord(Exact)
  else
    AExact := 0;
end;

function TScriptSource.PollFrame(Ex: TExchange; out Data: TBodyData;
  out Trailers: THttpHeaders): TFramePoll;
var
  F: string;
begin
  Data := BodyEmpty;
  Trailers := nil;
  if Pos >= Frames.Count then
    Exit(fpEnd);
  F := Frames[Pos];
  Inc(Pos);
  case F[1] of
    'd':
      begin
        F := Copy(F, 3, MaxInt);
        if F = '' then
          Data := BodyEmpty
        else
          Data := BodyCopy(Ex, PAnsiChar(F), Length(F));
        Result := fpData;
      end;
    'p': Result := fpPending;
    'w':
      begin
        Ex.Wake;
        Result := fpPending;
      end;
    'e':
      begin
        Ex.SetBodyErrorText('script error');
        Result := fpError;
      end;
  else
    begin
      Trailers := Trl;
      Result := fpTrailers;
    end;
  end;
end;

procedure TScriptSource.Done(Ex: TExchange);
begin
  Inc(DoneCalls);
end;

procedure TRecUpgrade.Upgraded(U: TUpgraded);
var
  P: PByte;
  L: SizeInt;
begin
  Got := U;
  U.Leftover(P, L);
  SetString(Leftover, PAnsiChar(P), L);
  U.Close;
end;

procedure TRecUpgrade.UpgradeFailed(const Msg: string);
begin
  Failed := Msg;
end;

procedure TRecObserver.OnConnClose(ConnId: QWord; Data: Pointer; Outcome_: TConnOutcome;
  const Detail_: string);
var
  S: string;
begin
  Inc(Closes);
  Outcome := Outcome_;
  Detail := Detail_;
  if Log <> nil then
  begin
    WriteStr(S, Outcome_);
    Log.Add('conn_close ' + S);
  end;
end;

procedure TRecObserver.OnParts(ConnId: QWord; Data: Pointer; var Parts: TConnParts);
begin
  Inc(PartsCount);
  SetString(PartsRest, PAnsiChar(Parts.Rest.P), Parts.Rest.Len);
  if Parts.Rest.Block <> nil then
    Parts.Rest.Release;
  Parts.Rest := Default(TBytesView);
  Parts.Transport.Close;           { the test owns the transport object }
  if Log <> nil then
    Log.Add('parts');
end;

{ ---- fixture ---- }

destructor TFixtureDispatcher.Destroy;
begin
  if Freed <> nil then
    Freed^ := True;
  inherited Destroy;
end;

{$ifdef WD_STALL}
type
  TTestDispatchStall = class(TDispCase)
  published
    procedure Head_wait_is_the_clients;
    procedure Body_wait_with_a_call_pending_is_the_clients;
    procedure Pending_call_is_reported_after_60_s;
    procedure Readiness_not_acted_on_is_reported;
    procedure Queued_task_is_reported;
    procedure Chunk_waiting_for_its_receiver_is_reported;
  end;

  { answers at once and keeps a shared reference without reading the body }
  THoldCall = class(TServiceCall)
  public
    Held: TExchange;
    function Poll(Ex: TExchange): TCallPoll; override;
  end;
  THoldService = class(THttpService)
  public
    C: THoldCall;
    function Call(Ex: TExchange): TServiceCall; override;
  end;
{$endif}

procedure TDispCase.SetUp;
begin
  FLoop := TLoop.Create(0);
  FPool := TExchangePool.Create;
  FLoop.Exchanges := FPool;
  FIo := TScriptIo.Create;
  FLog := TStringList.Create;
  FIo.Log := FLog;
  FSvc := TTestService.Create;
  FObs := TRecObserver.Create;
  FObs.Log := FLog;
  FCfg := ConformanceH1Config;
  FCfg.AutoDateHeader := False;
  FD := nil;
  FRuns := 0;
  FWakeFailures0 := WakeAssertFailures;
  FNoResponse0 := NoResponseFailures;
  ExpectedNoResponses := 0;
end;

procedure TDispCase.TearDown;
var
  WF: Integer;
begin
  if (FD <> nil) and not FDFreed and not FD.Closed then
  begin
    FD.Abort;
    FD.Close;
  end;
  FLoop.Free;                        { frees FD (deferred) }
  FPool.Free;
  FIo.Free;
  FSvc.Free;
  FObs.Free;
  FLog.Free;
  WF := WakeAssertFailures - FWakeFailures0;
  AssertEquals('wake-source assertion failures (2.4.5)', 0, WF);
  AssertEquals('completions without a terminal call', ExpectedNoResponses,
    NoResponseFailures - FNoResponse0);
end;

procedure TDispCase.Start;
begin
  FDFreed := False;
  FD := TFixtureDispatcher.Create(FLoop, -1);
  TFixtureDispatcher(FD).Freed := @FDFreed;
  FD.OwnsTransport := False;
  FD.Setup(FIo, FSvc, FCfg, FObs, 1, nil);
end;

function TDispCase.Done: Boolean;
begin
  Result := (FD = nil) or FD.Closed;
end;

procedure TDispCase.Drive(MaxSteps: Integer);
var
  I: Integer;
begin
  if FD = nil then
    Start;
  for I := 1 to MaxSteps do
  begin
    if Done then
      Exit;
    if FD.Queued then
    begin
      FLoop.RunIteration;
      if FDFreed then
      begin
        FD := nil;
        Exit;
      end;
    end
    else
    begin
      if (I > 1) and not FIo.Wakeable then
        Exit;                        { stall: nothing will run the task }
      FIo.ClearBlocked;
      Inc(FRuns);
      FD.Run;
    end;
  end;
end;

function Count(const Sub, S: RawByteString): Integer;
var
  P: SizeInt;
begin
  Result := 0;
  P := Pos(Sub, S);
  while P > 0 do
  begin
    Inc(Result);
    P := PosEx(Sub, S, P + Length(Sub));
  end;
end;

function LogCount(L: TStrings; const Prefix: string): Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to L.Count - 1 do
    if Copy(L[I], 1, Length(Prefix)) = Prefix then
      Inc(Result);
end;

function LogIndex(L: TStrings; const Prefix: string): Integer;
var
  I: Integer;
begin
  for I := 0 to L.Count - 1 do
    if Copy(L[I], 1, Length(Prefix)) = Prefix then
      Exit(I);
  Result := -1;
end;

{ ---- hyper regression tests ---- }

procedure TTestDispatchHyper.H1_flush_before_yield;
var
  Src: TScriptSource;
begin
  { tests/h1_flush_before_yield.rs: one data frame, Pending (no wake), then
    end of stream, inside one poll_loop iteration; the terminating chunk
    must be flushed before the task returns Pending }
  Src := TScriptSource.Create(['d:hello', 'p']);
  try
    FSvc.Stream := Src;
    FIo.AddRead('GET / HTTP/1.1' + CRLF + 'Host: localhost' + CRLF + CRLF);
    Start;
    FD.Run;
    AssertFalse('connection still open', FD.Closed);
    AssertTrue('ends with the terminating chunk: ' + EscapeStr(FIo.Written),
      Copy(FIo.Written, Length(FIo.Written) - 6, 7) = CRLF + '0' + CRLF + CRLF);
    AssertTrue('contains the data', Pos('5' + CRLF + 'hello' + CRLF, FIo.Written) > 0);
    AssertEquals('body dropped once', 1, Src.DoneCalls);
  finally
    if (FD <> nil) and not FD.Closed then
    begin
      FD.Abort;
      FD.Close;
    end;
    Src.Free;
  end;
end;

procedure TTestDispatchHyper.H1_shutdown_while_buffered;
var
  Big: RawByteString;
begin
  { tests/h1_shutdown_while_buffered.rs: the transport accepts 212 992
    bytes, then every write pends; a 500 000-byte Full body; shutdown must
    never be called while bytes are buffered. The transport is vectored
    (the large body is queued and goes out with the head in one writev). }
  SetLength(Big, 500000);
  FillChar(Big[1], 500000, Ord('X'));
  FSvc.RespBody := Big;
  FIo.AddRead('POST / HTTP/1.1' + CRLF + 'Host: localhost' + CRLF +
    'Transfer-Encoding: chunked' + CRLF + CRLF + 'A' + CRLF + 'Hello World' + CRLF + '0' + CRLF + CRLF);
  FIo.Vectored(True);
  FIo.AddWriteLimit(212992);
  FIo.BlockWritesWhenDone := True;   { "Block all further writes": Pending, never woken }
  Start;
  Drive;
  AssertEquals('no shutdown with buffered bytes', 0, FIo.ShutdownCalls);
  AssertEquals('only the first chunk went out', 212992, Length(FIo.Written));
  AssertFalse('connection still waiting for the socket', FD.Closed);
end;

procedure TTestDispatchHyper.Unbuffered_stream;
var
  Src: TScriptSource;
  Script: array of string;
  Chunk: RawByteString;
  I, BodyStart: Integer;
begin
  { tests/unbuffered_stream.rs (fixture.rs): max_buf_size 64 KiB, a
    StreamBody of 16 x 64 KiB with content-length; every write is followed
    by one Pending write (the 100 ms sleep, delivered by the driver as the
    readiness edge); more than 4 write polls while pending would be hot
    polling. Connection: close; the whole body arrives and the connection
    ends Ok. }
  SetLength(Chunk, 65536);
  FillChar(Chunk[1], 65536, 0);
  SetLength(Script, 16);
  for I := 0 to 15 do
    Script[I] := 'd:' + Chunk;
  Src := TScriptSource.Create(Script);
  try
    Src.Exact := 16 * 65536;
    FSvc.Stream := Src;
    FSvc.Headers.Add('content-type=application/octet-stream');
    FSvc.Headers.Add('content-length=1048576');
    FCfg.MaxBufSize := 65536;
    FIo.StrictWriteBlock := True;
    FIo.AddRead('GET / HTTP/1.1' + CRLF + 'Host: localhost' + CRLF + 'Connection: close' + CRLF + CRLF);
    for I := 1 to 400 do
    begin
      FIo.AddWriteLimit(High(SizeInt) div 2);
      FIo.AddWritePending;
    end;
    Start;
    Drive;
    { decision 13: hyper's UnbufferedStream fails with "We are being hot
      polled!" when its poll_cnt passes 4 while the sleep is pending.
      poll_cnt is reset to 0 when the sleep has completed, before the write
      is accepted, except for the stream's first write (poll_cnt = 1). So
      hyper allows the Pending ("wp") call plus 2 more before the readiness
      edge after the first write and plus 3 after later writes; this check
      allows 2 throughout (equal for the first write, stricter after, H-6).
      StrictWriteBlock makes those calls Pending without consuming the
      script, so a re-poll without the edge cannot succeed by accident. }
    AssertTrue(Format('at most 2 writes while blocked per wait, max %d (total %d)',
      [FIo.MaxBlockedRun, FIo.WritesWhileBlocked]), FIo.MaxBlockedRun <= 2);
    AssertTrue('connection done', Done);
    AssertEquals('closes once', 1, FObs.Closes);
    AssertTrue('outcome ok', FObs.Outcome = coOk);
    BodyStart := Pos(CRLF + CRLF, FIo.Written) + 3;
    AssertEquals('body bytes', 16 * 65536, Length(FIo.Written) - BodyStart);
    { each Pending write is followed by exactly one more write call (no hot polling) }
    AssertEquals('write pendings never repeated back to back', 0,
      Count('write pending' + LineEnding + 'write pending', FLog.Text));
  finally
    { the dispatcher holds Src: drop it first }
    if (FD <> nil) and not FD.Closed then
    begin
      FD.Abort;
      FD.Close;
    end;
    Src.Free;
  end;
end;

procedure TTestDispatchHyper.Ready_on_poll_stream;
var
  Src: TScriptSource;
  Script: array of string;
  Chunk: RawByteString;
  I, BodyStart: Integer;
begin
  { tests/ready_on_poll_stream.rs: every write first pends (arming a timer)
    and is accepted on the next poll. Its poll_flush half does not apply:
    TTransport has no flush (a TCP stream has nothing to flush, docs/design.md
    5.4). Same fixture as unbuffered_stream. }
  SetLength(Chunk, 65536);
  FillChar(Chunk[1], 65536, 7);
  SetLength(Script, 16);
  for I := 0 to 15 do
    Script[I] := 'd:' + Chunk;
  Src := TScriptSource.Create(Script);
  try
    Src.Exact := 16 * 65536;
    FSvc.Stream := Src;
    FSvc.Headers.Add('content-length=1048576');
    FCfg.MaxBufSize := 65536;
    FIo.AddRead('GET / HTTP/1.1' + CRLF + 'Host: localhost' + CRLF + 'Connection: close' + CRLF + CRLF);
    for I := 1 to 400 do
    begin
      FIo.AddWritePending;
      FIo.AddWriteLimit(High(SizeInt) div 2);
    end;
    Start;
    Drive;
    AssertTrue('connection done', Done);
    AssertTrue('outcome ok', FObs.Outcome = coOk);
    BodyStart := Pos(CRLF + CRLF, FIo.Written) + 3;
    AssertEquals('body bytes', 16 * 65536, Length(FIo.Written) - BodyStart);
  finally
    Src.Free;
  end;
end;

procedure TTestDispatchHyper.Body_empty_chunks_ignored;
var
  Src: TScriptSource;
begin
  { dispatch.rs body_empty_chunks_ignored, server form: empty data frames
    are discarded by the dispatcher, they never reach write_body (whose
    debug assertion would fire) and never end the chunked body early }
  Src := TScriptSource.Create(['d:', 'd:x', 'd:', 'd:yz', 'd:']);
  try
    FSvc.Stream := Src;
    FIo.AddRead(GET_REQ);
    Start;
    Drive;
    AssertEquals('wire', 'HTTP/1.1 200 OK' + CRLF + 'transfer-encoding: chunked' + CRLF + CRLF +
      '1' + CRLF + 'x' + CRLF + '2' + CRLF + 'yz' + CRLF + '0' + CRLF + CRLF, FIo.Written);
  finally
    if (FD <> nil) and not FD.Closed then
    begin
      FD.Abort;
      FD.Close;
    end;
    Src.Free;
  end;
end;

{ ---- pipelining ---- }

procedure TTestDispatchPipeline.Pipelining_16_one_write;
var
  Reqs: RawByteString;
  I: Integer;
begin
  FCfg.PipelineFlush := True;
  Reqs := '';
  for I := 1 to 16 do
    Reqs := Reqs + GET_REQ;
  FIo.AddRead(Reqs);
  Start;
  Drive;
  AssertEquals('responses', 16, Count('HTTP/1.1 200 OK', FIo.Written));
  AssertEquals('one write call', 1, LogCount(FLog, 'write'));
  AssertEquals('calls', 16, FSvc.Calls);
end;

type
  TCountingDispatcher = class(TH1Dispatcher)
  public
    Runs: Integer;
    procedure Run; override;
  end;

procedure TCountingDispatcher.Run;
begin
  Inc(Runs);
  inherited Run;
end;

procedure TTestDispatchPipeline.Pipelining_32_yield_same_iteration;
var
  Reqs: RawByteString;
  I, Iters0: Integer;
  CD: TCountingDispatcher;
begin
  { 32 requests in one read: poll_loop yields after 16 iterations (wake_by_ref,
    back of the run queue); the loop runs the task again in the same
    iteration (61-poll budget), so all 32 responses leave in one write
    before the next epoll_wait }
  FCfg.PipelineFlush := True;
  Reqs := '';
  for I := 1 to 32 do
    Reqs := Reqs + GET_REQ;
  FIo.AddRead(Reqs);
  CD := TCountingDispatcher.Create(FLoop, -1);
  CD.OwnsTransport := False;
  CD.Setup(FIo, FSvc, FCfg, FObs, 1, nil);
  FD := CD;
  FD.Wake;                           { the task is queued, as after an accept }
  Iters0 := FLoop.Waits;
  FLoop.RunIteration;
  AssertEquals('one loop iteration', 1, Integer(FLoop.Waits) - Iters0);
  AssertEquals('responses', 32, Count('HTTP/1.1 200 OK', FIo.Written));
  AssertEquals('one write call', 1, LogCount(FLog, 'write'));
  AssertEquals('two polls (16 + yield + 16)', 2, CD.Runs);
  AssertEquals('calls', 32, FSvc.Calls);
end;

procedure TTestDispatchPipeline.Pipelining_without_flush_one_write_each;
var
  Reqs: RawByteString;
  I: Integer;
begin
  FCfg.PipelineFlush := False;
  Reqs := '';
  for I := 1 to 16 do
    Reqs := Reqs + GET_REQ;
  FIo.AddRead(Reqs);
  FIo.Vectored(True);
  Start;
  Drive;
  AssertEquals('responses', 16, Count('HTTP/1.1 200 OK', FIo.Written));
  AssertEquals('one write per response', 16, LogCount(FLog, 'write ') + LogCount(FLog, 'writev '));
end;

{ ---- behaviors ---- }

procedure TTestDispatchBehavior.Get_response_bytes;
begin
  { a Pending between the request and the EOF: with the EOF right after the
    head, mid_message_detect_eof would end the connection before the call
    is polled (Disconnect_before_call_polled) }
  FIo.AddRead(GET_REQ).AddReadPending.AddReadEof;
  Start;
  Drive;
  AssertEquals('wire', 'HTTP/1.1 200 OK' + CRLF + 'content-length: 5' + CRLF + CRLF + 'hello',
    FIo.Written);
  AssertTrue('done', Done);
  AssertTrue('outcome ok', FObs.Outcome = coOk);
  AssertEquals('shutdown once', 1, FIo.ShutdownCalls);
  AssertTrue('closed', FIo.Closed);
  AssertEquals('call dropped as completed', 1, FSvc.DropsDone);
  AssertEquals('path', '/', FSvc.LastPath);
  { shutdown before close, completion reported after both }
  AssertTrue('order', (LogIndex(FLog, 'shutdown') < LogIndex(FLog, 'close'))
    and (LogIndex(FLog, 'close') < LogIndex(FLog, 'conn_close')));
end;

procedure TTestDispatchBehavior.Keep_alive_two_requests;
begin
  FIo.AddRead(GET_REQ).AddReadPending.AddRead('GET /b HTTP/1.1' + CRLF + 'Host: x' + CRLF + CRLF)
    .AddReadPending.AddReadEof;
  Start;
  Drive;
  AssertEquals('two responses', 2, Count('HTTP/1.1 200 OK', FIo.Written));
  AssertEquals('second path', '/b', FSvc.LastPath);
  AssertTrue('outcome ok', FObs.Outcome = coOk);
  AssertEquals('requests', 2, Integer(FD.RequestCount));
end;

procedure TTestDispatchBehavior.Request_body_prefetched_before_first_poll;
begin
  { want = True: poll_read fills the slot with the first chunk before the
    handler's first poll (chan.rs; docs/design.md 6.2, the prefetch) }
  FSvc.ReadBody := True;
  FIo.AddRead('POST / HTTP/1.1' + CRLF + 'Host: x' + CRLF + 'Content-Length: 5' + CRLF + CRLF + 'abcde')
    .AddReadPending.AddReadEof;
  Start;
  Drive;
  AssertTrue('first TryRead got data', FSvc.FirstTryReadSet and (FSvc.FirstTryRead = brData));
  AssertEquals('body', 'abcde', FSvc.LastBody);
  AssertTrue('outcome ok', FObs.Outcome = coOk);
end;

procedure TTestDispatchBehavior.Request_body_across_reads;
begin
  FSvc.ReadBody := True;
  FIo.AddRead('POST / HTTP/1.1' + CRLF + 'Host: x' + CRLF + 'Transfer-Encoding: chunked' + CRLF + CRLF)
    .AddReadPending.AddRead('3' + CRLF + 'abc' + CRLF).AddReadPending
    .AddRead('2' + CRLF + 'de' + CRLF + '0' + CRLF + CRLF).AddReadPending.AddReadEof;
  Start;
  Drive;
  AssertEquals('body', 'abcde', FSvc.LastBody);
  AssertEquals('response', 1, Count('HTTP/1.1 200 OK', FIo.Written));
  AssertTrue('outcome ok', FObs.Outcome = coOk);
end;

procedure TTestDispatchBehavior.Expect_continue_sent_on_first_read;
begin
  FSvc.ReadBody := True;
  FIo.AddRead('POST / HTTP/1.1' + CRLF + 'Host: x' + CRLF + 'Expect: 100-continue' + CRLF +
    'Content-Length: 3' + CRLF + CRLF).AddReadPending.AddRead('abc').AddReadPending.AddReadEof;
  Start;
  Drive;
  AssertEquals('one 100', 1, Count('HTTP/1.1 100 Continue', FIo.Written));
  AssertTrue('100 first', Pos('HTTP/1.1 100 Continue' + CRLF + CRLF, FIo.Written) = 1);
  AssertEquals('body', 'abc', FSvc.LastBody);
end;

procedure TTestDispatchBehavior.Expect_continue_not_sent_when_unread;
begin
  FIo.AddRead('POST / HTTP/1.1' + CRLF + 'Host: x' + CRLF + 'Expect: 100-continue' + CRLF +
    'Content-Length: 3' + CRLF + CRLF).AddReadPending.AddReadEof;
  Start;
  Drive;
  AssertEquals('no 100', 0, Count('100 Continue', FIo.Written));
  AssertEquals('response', 1, Count('HTTP/1.1 200 OK', FIo.Written));
  AssertTrue('done', Done);
end;

procedure TTestDispatchBehavior.Disconnect_before_call_polled;
begin
  { disconnect_after_reading_request_before_responding: the client sends a
    request and closes; poll_read detects EOF (mid_message_detect_eof) in
    the same poll_loop iteration, before poll_write polls the call: the
    call is dropped without having run (handler_dropped), nothing is
    written, the outcome is incomplete }
  FIo.AddRead(GET_REQ).AddReadEof;
  FSvc.PendPolls := 1;
  Start;
  Drive;
  AssertTrue('done', Done);
  AssertEquals('never polled', 0, FSvc.Call_.Polls);
  AssertEquals('dropped, not completed', 1, FSvc.DropsAbandoned);
  AssertEquals('nothing written', '', FIo.Written);
  AssertTrue('outcome incomplete', FObs.Outcome = coIncomplete);
  AssertEquals('no shutdown', 0, FIo.ShutdownCalls);
end;

procedure TTestDispatchBehavior.Service_fail_no_response;
begin
  FSvc.FailMsg := 'boom';
  FIo.AddRead(GET_REQ);
  Start;
  Drive;
  AssertTrue('done', Done);
  AssertTrue('outcome user', FObs.Outcome = coUser);
  AssertTrue('detail has the text: ' + FObs.Detail, Pos('boom', FObs.Detail) > 0);
  AssertEquals('nothing written', '', FIo.Written);
  AssertEquals('no shutdown (propagated error)', 0, FIo.ShutdownCalls);
  AssertTrue('closed', FIo.Closed);
end;

procedure TTestDispatchBehavior.Parse_error_400_then_shutdown;
begin
  FIo.AddRead('GET / HTTP/1.1' + CRLF + 'Bad Header' + CRLF + CRLF);
  Start;
  Drive;
  AssertTrue('done', Done);
  AssertEquals('wire', 'HTTP/1.1 400 Bad Request' + CRLF + 'connection: close' + CRLF +
    'content-length: 0' + CRLF + CRLF, FIo.Written);
  AssertEquals('shutdown', 1, FIo.ShutdownCalls);
  AssertTrue('outcome parse', FObs.Outcome = coParse);
  AssertEquals('no call', 0, FSvc.Calls);
end;

procedure TTestDispatchBehavior.Eof_when_idle_is_ok;
begin
  FIo.AddReadEof;
  Start;
  Drive;
  AssertTrue('done', Done);
  AssertTrue('outcome ok', FObs.Outcome = coOk);
  AssertEquals('nothing written', '', FIo.Written);
end;

procedure TTestDispatchBehavior.Graceful_shutdown_idle;
begin
  Start;
  Drive;                             { waits for a head (idle client) }
  AssertFalse('open', FD.Closed);
  FD.GracefulShutdown;
  Drive;
  AssertTrue('done', Done);
  AssertTrue('outcome ok', FObs.Outcome = coOk);
  AssertEquals('shutdown', 1, FIo.ShutdownCalls);
end;

procedure TTestDispatchBehavior.Graceful_shutdown_in_flight;
begin
  { the call is pending; graceful shutdown disables keep-alive: the response
    gets "connection: close" and the connection ends after it }
  FSvc.PendPolls := 3;
  FIo.AddRead(GET_REQ);
  Start;
  FD.Run;                            { head read, call polled once (pending, self-wake) }
  FD.GracefulShutdown;
  Drive;
  AssertTrue('done', Done);
  AssertEquals('wire', 'HTTP/1.1 200 OK' + CRLF + 'connection: close' + CRLF +
    'content-length: 5' + CRLF + CRLF + 'hello', FIo.Written);
  AssertTrue('outcome ok', FObs.Outcome = coOk);
end;

procedure TTestDispatchBehavior.Response_version_panic_aborts;
var
  Raised: Boolean;
begin
  { 2.8: role.rs panics on an HTTP/0.9 response version; the loop aborts
    the task (1.10): fd closed, no completion event }
  FSvc.RespVersion := hv09;
  FIo.AddRead(GET_REQ);
  Start;
  Raised := False;
  try
    FD.Run;
  except
    on E: EH1Panic do
      Raised := True;
  end;
  AssertTrue('EH1Panic', Raised);
  FD.Abort;
  FD.Close;
  AssertEquals('no conn_close', 0, FObs.Closes);
  AssertTrue('closed', FIo.Closed);
  AssertEquals('nothing written', '', FIo.Written);
end;

procedure TTestDispatchBehavior.Upgrade_plain_mode_manual;
var
  U: TRecUpgrade;
begin
  U := TRecUpgrade.Create;
  try
    FSvc.Upgrade := U;
    FSvc.Status := 101;
    FSvc.RespBody := '';
    FSvc.Headers.Add('upgrade=foo');
    FSvc.Headers.Add('connection=upgrade');
    FIo.AddRead('GET / HTTP/1.1' + CRLF + 'Host: x' + CRLF + 'Upgrade: foo' + CRLF +
      'Connection: upgrade' + CRLF + CRLF + 'leftover');
    Start;
    Drive;
    AssertTrue('done', Done);
    AssertEquals('manual', 'upgrade expected but low level API in use', U.Failed);
    AssertTrue('outcome ok', FObs.Outcome = coOk);
    AssertEquals('no shutdown on upgrade', 0, FIo.ShutdownCalls);
    AssertTrue('101 written', Pos('HTTP/1.1 101 Switching Protocols', FIo.Written) = 1);
  finally
    U.Free;
  end;
end;

procedure TTestDispatchBehavior.Upgrades_ignored_no_shutdown;
var
  U: TRecUpgrade;
begin
  { upgrades_ignored: the request asked for an upgrade, the response is a
    200; the pending upgrade stays in State.upgrade (hyper keeps it, risk
    R5); when the connection finishes, poll_inner returns Upgrade without
    shutdown and Connection::poll calls manual() }
  U := TRecUpgrade.Create;
  try
    FSvc.Upgrade := U;
    FIo.AddRead('GET / HTTP/1.1' + CRLF + 'Host: x' + CRLF + 'Upgrade: foo' + CRLF +
      'Connection: upgrade' + CRLF + CRLF).AddReadPending.AddReadEof;
    Start;
    Drive;
    AssertTrue('done', Done);
    AssertEquals('200', 1, Count('HTTP/1.1 200 OK', FIo.Written));
    AssertEquals('no shutdown', 0, FIo.ShutdownCalls);
    AssertEquals('manual', 'upgrade expected but low level API in use', U.Failed);
    AssertTrue('outcome ok', FObs.Outcome = coOk);
  finally
    U.Free;
  end;
end;

procedure TTestDispatchBehavior.With_upgrades_delivers_after_close;
var
  U: TRecUpgrade;
begin
  U := TRecUpgrade.Create;
  try
    FCfg.Mode := cmWithUpgrades;
    FSvc.Upgrade := U;
    FSvc.Status := 101;
    FSvc.RespBody := '';
    FSvc.Headers.Add('upgrade=foo');
    FSvc.Headers.Add('connection=upgrade');
    FIo.AddRead('GET / HTTP/1.1' + CRLF + 'Host: x' + CRLF + 'Upgrade: foo' + CRLF +
      'Connection: upgrade' + CRLF + CRLF + 'leftover');
    Start;
    Drive;
    AssertTrue('done', Done);
    AssertTrue('outcome ok', FObs.Outcome = coOk);
    AssertTrue('not delivered before conn_close', U.Got = nil);
    FLoop.RunIteration;              { the queued delivery task }
    AssertTrue('delivered', U.Got <> nil);
    AssertEquals('leftover', 'leftover', U.Leftover);
    AssertEquals('no failure', '', U.Failed);
    AssertTrue('the upgraded stream closed the transport', FIo.Closed);
    AssertEquals('no shutdown', 0, FIo.ShutdownCalls);
  finally
    U.Free;
  end;
end;

procedure TTestDispatchBehavior.Without_shutdown_parts;
begin
  FCfg.Mode := cmWithoutShutdown;
  FCfg.KeepAlive := False;
  FIo.AddRead(GET_REQ + 'rest');
  Start;
  Drive;
  AssertTrue('done', Done);
  AssertEquals('parts', 1, FObs.PartsCount);
  AssertEquals('rest', 'rest', FObs.PartsRest);
  AssertEquals('no shutdown', 0, FIo.ShutdownCalls);
  AssertTrue('conn_close before parts', LogIndex(FLog, 'conn_close') < LogIndex(FLog, 'parts'));
end;

procedure TTestDispatchBehavior.Idle_releases_exchange_and_blocks;
var
  Free0: Integer;
begin
  { 4.3: an idle keep-alive connection gives its exchange and its blocks
    back }
  FIo.AddRead(GET_REQ).AddReadPending;
  Start;
  Free0 := FPool.FreeCount;
  Drive;
  AssertFalse('open', FD.Closed);
  AssertTrue('no exchange held', FD.Ex = nil);
  AssertEquals('exchange back in the pool', Free0 + 1, FPool.FreeCount);
  AssertTrue('read block given back', FD.Conn.Io.ReadBuf.Block = nil);
  AssertEquals('read buffer empty', 0, FD.Conn.Io.ReadBuf.Cap);
  AssertTrue('write block given back', FD.Conn.Io.WriteBuf.Headers.Bytes.Block = nil);
end;

procedure TTestDispatchBehavior.Header_read_timeout;
begin
  FCfg.Timer := True;
  FCfg.HeaderReadTimeout := tsMs;
  FCfg.HeaderReadTimeoutMs := 50;
  FIo.AddRead('GET / HTTP/1.1' + CRLF);
  Start;
  Drive;
  AssertFalse('waiting', FD.Closed);
  FLoop.NowMs := FLoop.NowMs + 100;
  FLoop.Timers.Advance(FLoop.NowMs);  { the timer's Proc wakes the task }
  AssertTrue('woken', FD.Queued);
  Drive;
  AssertTrue('done', Done);
  AssertTrue('outcome timeout', FObs.Outcome = coTimeout);
  AssertEquals('nothing written', '', FIo.Written);
end;

procedure TTestDispatchBehavior.Body_rate_rule_outcome_io;
begin
  { docs/design.md 5.7: the body rate rule fails the body; the handler sees
    the error and answers, the response is written and the socket shut
    down, and the connection ends with the stored error: outcome io }
  FCfg.Timer := True;
  FCfg.BodyReadTimeoutMs := 20;
  FSvc.ReadBody := True;
  FSvc.Status := 408;
  FIo.AddRead('POST / HTTP/1.1' + CRLF + 'Host: x' + CRLF + 'Content-Length: 6' + CRLF + CRLF + 'ab');
  Start;
  Drive;
  AssertFalse('waiting for the body', FD.Closed);
  { real time: RunIteration samples the clock, and the rule compares it }
  Sleep(30);
  FLoop.Timers.Advance(FLoop.NowMs + 100);  { the body timer wakes the task }
  AssertTrue('woken', FD.Queued);
  Drive;
  AssertTrue('done', Done);
  AssertEquals('body read before the error', 'ab', FSvc.LastBody);
  AssertTrue('408 written: ' + FIo.Written, Pos('HTTP/1.1 408', FIo.Written) = 1);
  AssertEquals('shutdown after the response', 1, FIo.ShutdownCalls);
  AssertTrue('outcome io', FObs.Outcome = coIo);
end;

procedure TTestDispatchBehavior.Body_framing_error_outcome_io;
begin
  { a malformed chunk size: the handler sees the body error and answers,
    and the connection ends with the stored error (hyper: Ok) }
  FSvc.ReadBody := True;
  FSvc.Status := 400;
  FIo.AddRead('POST / HTTP/1.1' + CRLF + 'Host: x' + CRLF + 'Transfer-Encoding: chunked' + CRLF + CRLF +
    '2' + CRLF + 'ab' + CRLF + 'zz' + CRLF);
  Start;
  Drive;
  AssertTrue('done', Done);
  AssertEquals('body read before the error', 'ab', FSvc.LastBody);
  AssertTrue('400 written: ' + FIo.Written, Pos('HTTP/1.1 400', FIo.Written) = 1);
  AssertEquals('shutdown after the response', 1, FIo.ShutdownCalls);
  AssertTrue('outcome io', FObs.Outcome = coIo);
end;

procedure TTestDispatchBehavior.Body_socket_error_outcome_io;
begin
  { a socket error in the middle of the body: as above }
  FSvc.ReadBody := True;
  FSvc.Status := 400;
  FIo.AddRead('POST / HTTP/1.1' + CRLF + 'Host: x' + CRLF + 'Content-Length: 6' + CRLF + CRLF + 'ab');
  FIo.AddReadError(ESysECONNRESET);
  Start;
  Drive;
  AssertTrue('done', Done);
  AssertEquals('body read before the error', 'ab', FSvc.LastBody);
  AssertTrue('outcome io', FObs.Outcome = coIo);
end;

procedure TTestDispatchBehavior.Stream_body_error_is_user;
var
  Src: TScriptSource;
begin
  { 'w': a Pending with a wake between the data and the error, so the head
    and the chunk are flushed first (an error propagated by poll_write
    skips the flush: data buffered in the same poll is never sent) }
  Src := TScriptSource.Create(['d:abc', 'w', 'e']);
  try
    FSvc.Stream := Src;
    FIo.AddRead(GET_REQ);
    Start;
    Drive;
    AssertTrue('done', Done);
    AssertTrue('outcome user', FObs.Outcome = coUser);
    AssertTrue('chunked left open', Copy(FIo.Written, Length(FIo.Written) - 4, 5) <> '0' + CRLF + CRLF);
    AssertTrue('data sent', Pos('3' + CRLF + 'abc' + CRLF, FIo.Written) > 0);
    AssertEquals('no shutdown', 0, FIo.ShutdownCalls);
    AssertEquals('source dropped once', 1, Src.DoneCalls);
  finally
    Src.Free;
  end;
end;

procedure TTestDispatchBehavior.Proxy_header_v1_sets_the_peer;
begin
  FCfg.ProxyProtocol := True;
  FIo.AddRead('PROXY TCP4 10.1.2.3 10.0.0.1 5555 80' + CRLF + GET_REQ).AddReadPending
    .AddRead('GET /b HTTP/1.1' + CRLF + 'Host: x' + CRLF + CRLF).AddReadPending.AddReadEof;
  Start;
  Drive;
  AssertEquals('two responses', 2, Count('HTTP/1.1 200 OK', FIo.Written));
  AssertEquals('the peer from the header', '10.1.2.3', SockAddrToStr(FD.Peer));
  AssertEquals(5555, Integer(SockAddrPort(FD.Peer)));
  AssertTrue('outcome ok', FObs.Outcome = coOk);
end;

procedure TTestDispatchBehavior.Proxy_header_v2_split_across_reads;
const
  V2 = #13#10#13#10#0#13#10'QUIT'#10 + #$21#$11#0#12 + #10#1#2#3 + #10#0#0#1 + #$15#$B3 + #0#80;
begin
  FCfg.ProxyProtocol := True;
  FIo.AddRead(Copy(V2, 1, 5)).AddReadPending.AddRead(Copy(V2, 6, 15)).AddReadPending
    .AddRead(Copy(V2, 21, MaxInt) + GET_REQ).AddReadPending.AddReadEof;
  Start;
  Drive;
  AssertEquals('one response', 1, Count('HTTP/1.1 200 OK', FIo.Written));
  AssertEquals('10.1.2.3', SockAddrToStr(FD.Peer));
  AssertEquals(5555, Integer(SockAddrPort(FD.Peer)));
  AssertTrue('outcome ok', FObs.Outcome = coOk);
end;

procedure TTestDispatchBehavior.Proxy_header_missing_closes_without_response;
begin
  FCfg.ProxyProtocol := True;
  FIo.AddRead(GET_REQ).AddReadPending.AddReadEof;
  Start;
  Drive;
  AssertTrue('done', Done);
  AssertEquals('nothing written', '', FIo.Written);
  AssertEquals('no call', 0, FSvc.Calls);
  AssertTrue('outcome parse', FObs.Outcome = coParse);
  AssertEquals('invalid PROXY protocol header', FObs.Detail);
end;

procedure TTestDispatchBehavior.Proxy_header_eof_before_it_is_ok;
begin
  { a proxy's connect check: it opens and closes without a byte }
  FCfg.ProxyProtocol := True;
  FIo.AddReadEof;
  Start;
  Drive;
  AssertTrue('done', Done);
  AssertEquals('nothing written', '', FIo.Written);
  AssertTrue('outcome ok', FObs.Outcome = coOk);
end;

procedure TTestDispatchBehavior.Max_requests_closes_after_the_last_one;
begin
  FCfg.MaxRequests := 2;
  FIo.AddRead(GET_REQ + GET_REQ + GET_REQ).AddReadPending.AddReadEof;
  Start;
  Drive;
  AssertTrue('done', Done);
  AssertEquals('two responses, the third request is not served', 2, Count('HTTP/1.1 200 OK', FIo.Written));
  AssertEquals('the last one closes', 1, Count('connection: close', FIo.Written));
  AssertTrue('the close is on the second response', Pos('connection: close', FIo.Written) > Pos('hello', FIo.Written));
  AssertEquals('shutdown', 1, FIo.ShutdownCalls);
  AssertTrue('outcome ok', FObs.Outcome = coOk);
  AssertEquals('requests', 2, Integer(FD.RequestCount));
end;

procedure TTestDispatchBehavior.Http10_closes;
begin
  FIo.AddRead('GET / HTTP/1.0' + CRLF + CRLF);
  Start;
  Drive;
  AssertTrue('done', Done);
  AssertEquals('wire', 'HTTP/1.0 200 OK' + CRLF + 'content-length: 5' + CRLF + CRLF + 'hello',
    FIo.Written);
  AssertTrue('outcome ok', FObs.Outcome = coOk);
end;

procedure TTestDispatchBehavior.Write_error_ends_connection;
begin
  FIo.AddRead(GET_REQ);
  FIo.AddWriteError(ESysEPIPE);
  Start;
  Drive;
  AssertTrue('done', Done);
  AssertTrue('outcome is an error', FObs.Outcome <> coOk);
  AssertTrue('closed', FIo.Closed);
  AssertEquals('no shutdown', 0, FIo.ShutdownCalls);
end;


{ ---- step H ---- }

procedure TTestDispatchBehavior.Parse_error_behind_queued_body;
const
  HEAD = 'HTTP/1.1 200 OK' + CRLF + 'content-length: 5' + CRLF + CRLF;
  ERR400 = 'HTTP/1.1 400 Bad Request' + CRLF + 'connection: close' + CRLF +
    'content-length: 0' + CRLF + CRLF;
begin
  { the response's body waits behind a blocked write; the request body is
    drained after it, which makes the connection idle, and the next head is
    a parse error: the 400 follows the body on the wire (hyper 1.12.0's
    Queue strategy writes it between the head and the body, S5-3). The
    queued-body form is test_h1_conn's Error_head_queued_behind_body. }
  FIo.Vectored(True);
  FIo.AddRead('POST / HTTP/1.1' + CRLF + 'Host: x' + CRLF + 'Content-Length: 5' + CRLF + CRLF)
    .AddReadPending
    .AddRead('abcde' + 'GET / HTTP/1.1' + CRLF + 'Bad Header' + CRLF + CRLF)
    .AddReadPending.AddReadEof;
  FIo.AddWriteLimit(Length(HEAD)).AddWritePending;
  Start;
  Drive;
  AssertTrue('done', Done);
  AssertEquals('wire: the 400 after the queued body', HEAD + 'hello' + ERR400, FIo.Written);
  AssertTrue('outcome parse', FObs.Outcome = coParse);
  AssertEquals('shutdown', 1, FIo.ShutdownCalls);
end;

procedure TTestDispatchBehavior.Parse_error_behind_16_queued_entries;
const
  ERR400 = 'HTTP/1.1 400 Bad Request' + CRLF + 'connection: close' + CRLF +
    'content-length: 0' + CRLF + CRLF;
var
  Src: TScriptSource;
  Frames: array[0..14] of string;
  Body: RawByteString;
  I: Integer;
begin
  { as Parse_error_behind_queued_body, with a chunked response of 15 data
    frames and its terminator waiting behind the blocked write (the H
    verifier's q16b: with all 16 queued, a 17th entry once raised EH1Panic;
    test_h1_io's Head_behind_16_queued_entries covers the queue form) }
  Body := '';
  for I := 0 to 14 do
  begin
    Frames[I] := 'd:x' + IntToStr(I + 1);
    Body := Body + IntToHex(Length(Frames[I]) - 2, 1) + CRLF + Copy(Frames[I], 3, MaxInt) + CRLF;
  end;
  Body := LowerCase(Body);
  Src := TScriptSource.Create(Frames);
  try
    FSvc.Stream := Src;
    FIo.Vectored(True);
    FIo.AddRead('POST / HTTP/1.1' + CRLF + 'Host: x' + CRLF + 'Content-Length: 5' + CRLF + CRLF)
      .AddReadPending
      .AddRead('abcde' + 'GET / HTTP/1.1' + CRLF + 'Bad Header' + CRLF + CRLF)
      .AddReadPending.AddReadEof;
    FIo.AddWritePending.AddWritePending.AddWritePending.AddWritePending;
    Start;
    Drive;
    { the connection closes inside a run-queue iteration (the request body's
      channel woke the task), so the loop has freed it: Done, not FD.Closed }
    AssertTrue('done', Done);
    AssertEquals('wire: the 400 after the 16 queued entries',
      'HTTP/1.1 200 OK' + CRLF + 'transfer-encoding: chunked' + CRLF + CRLF + Body +
      '0' + CRLF + CRLF + ERR400, FIo.Written);
    AssertTrue('outcome parse', FObs.Outcome = coParse);
    AssertEquals('conn_close', 1, FObs.Closes);
    AssertEquals('shutdown', 1, FIo.ShutdownCalls);
  finally
    Src.Free;
  end;
end;

procedure TTestDispatchBehavior.Abort_releases_upgrade_slot;
var
  U: TRecUpgrade;
  L0: LongInt;
begin
  { decision 9: the connection's reference to the upgrade slot (State.Upgrade,
    taken when the upgrade request's head was parsed) is released by
    DropAll when the connection is aborted with the call still pending;
    the exchange's reference goes with the exchange. The handler hears
    that the upgrade did not happen. }
  L0 := UpgradeSlotsLive;
  U := TRecUpgrade.Create;
  try
    FSvc.Upgrade := U;
    FSvc.PendForever := True;
    FIo.AddRead('GET / HTTP/1.1' + CRLF + 'Host: x' + CRLF + 'Upgrade: foo' + CRLF +
      'Connection: upgrade' + CRLF + CRLF);
    Start;
    Drive;
    AssertFalse('waiting on the call', FD.Closed);
    AssertEquals('one slot alive', L0 + 1, UpgradeSlotsLive);
    FD.Abort;
    FD.Close;
    AssertTrue('done', Done);
    AssertEquals('slot freed', L0, UpgradeSlotsLive);
    AssertTrue('handler told', U.Failed <> '');
    AssertTrue('not upgraded', U.Got = nil);
  finally
    U.Free;
  end;
end;

procedure TTestDispatchBehavior.Error_releases_taken_upgrade_slot;
var
  U: TRecUpgrade;
  L0: LongInt;
begin
  { decision 9: poll_inner takes the pending upgrade (dispatch.rs:151-153)
    and then returns the stored error (take_error()?), so Finish does not
    hand it on and DropAll releases the dispatcher's reference. Here the
    upgrade request gets a 200 (the upgrade stays pending in the state, as
    in hyper) and the next head is a parse error. }
  L0 := UpgradeSlotsLive;
  U := TRecUpgrade.Create;
  try
    FSvc.Upgrade := U;
    FIo.AddRead('GET / HTTP/1.1' + CRLF + 'Host: x' + CRLF + 'Upgrade: foo' + CRLF +
      'Connection: upgrade' + CRLF + CRLF).AddReadPending
      .AddRead('GET / HTTP/1.1' + CRLF + 'Bad Header' + CRLF + CRLF).AddReadPending.AddReadEof;
    Start;
    Drive;
    AssertTrue('done', Done);
    AssertEquals('200 then 400', 1, Count('HTTP/1.1 400 Bad Request', FIo.Written));
    AssertTrue('outcome parse', FObs.Outcome = coParse);
    AssertEquals('slot freed', L0, UpgradeSlotsLive);
    AssertTrue('handler told', U.Failed <> '');
    AssertTrue('not upgraded', U.Got = nil);
  finally
    U.Free;
  end;
end;

procedure TTestDispatchBehavior.Pipeline_flush_upgrade_101_before_hand_off;
var
  U: TRecUpgrade;
begin
  U := TRecUpgrade.Create;
  try
    FCfg.Mode := cmWithUpgrades;
    FCfg.PipelineFlush := True;
    FSvc.Upgrade := U;
    FSvc.Status := 101;
    FSvc.RespBody := '';
    FSvc.Headers.Add('upgrade=foo');
    FSvc.Headers.Add('connection=upgrade');
    FIo.AddRead('GET / HTTP/1.1' + CRLF + 'Host: x' + CRLF + 'Upgrade: foo' + CRLF +
      'Connection: upgrade' + CRLF + CRLF + 'leftover');
    Start;
    Drive;
    AssertTrue('done', Done);
    AssertTrue('101 written before the hand-off: ' + FIo.Written,
      AnsiStartsStr('HTTP/1.1 101 Switching Protocols' + CRLF, FIo.Written)
      and AnsiEndsStr(CRLF + CRLF, FIo.Written));
    AssertTrue('outcome ok', FObs.Outcome = coOk);
    FLoop.RunIteration;              { the queued delivery task }
    AssertTrue('delivered', U.Got <> nil);
    AssertEquals('leftover', 'leftover', U.Leftover);
    AssertEquals('no shutdown', 0, FIo.ShutdownCalls);
  finally
    U.Free;
  end;
end;

procedure TTestDispatchBehavior.Pipeline_flush_upgrade_101_write_pending;
var
  U: TRecUpgrade;
begin
  { the held flush meets EAGAIN: the task waits for the writable edge and
    hands off only after the 101 left }
  U := TRecUpgrade.Create;
  try
    FCfg.Mode := cmWithUpgrades;
    FCfg.PipelineFlush := True;
    FSvc.Upgrade := U;
    FSvc.Status := 101;
    FSvc.RespBody := '';
    FSvc.Headers.Add('upgrade=foo');
    FSvc.Headers.Add('connection=upgrade');
    FIo.AddRead('GET / HTTP/1.1' + CRLF + 'Host: x' + CRLF + 'Upgrade: foo' + CRLF +
      'Connection: upgrade' + CRLF + CRLF + 'leftover');
    FIo.AddWritePending.AddWriteLimit(10);
    Start;
    Drive;
    AssertTrue('done', Done);
    AssertTrue('101 written: ' + FIo.Written,
      AnsiStartsStr('HTTP/1.1 101 Switching Protocols' + CRLF, FIo.Written)
      and AnsiEndsStr(CRLF + CRLF, FIo.Written));
    AssertTrue('the pending write was seen', LogCount(FLog, 'write pending') >= 1);
    AssertTrue('outcome ok', FObs.Outcome = coOk);
    FLoop.RunIteration;
    AssertTrue('delivered', U.Got <> nil);
    AssertEquals('leftover', 'leftover', U.Leftover);
  finally
    U.Free;
  end;
end;

procedure TTestDispatchBehavior.Pipeline_flush_keep_alive_off_pipelined;
begin
  { keep-alive off, a second request in the same read: the first response
    is flushed before the shutdown (hyper's poll_shutdown skips it) }
  FCfg.PipelineFlush := True;
  FCfg.KeepAlive := False;
  FIo.AddRead(GET_REQ + GET_REQ);
  Start;
  Drive;
  AssertTrue('done', Done);
  AssertEquals('one response', 1, Count('HTTP/1.1 200 OK', FIo.Written));
  AssertTrue('the response body', AnsiEndsStr(CRLF + CRLF + FSvc.RespBody, FIo.Written));
  AssertEquals('calls', 1, FSvc.Calls);
  AssertEquals('shutdown', 1, FIo.ShutdownCalls);
  AssertTrue('written before the shutdown',
    LogIndex(FLog, 'write') < LogIndex(FLog, 'shutdown'));
  AssertTrue('outcome ok', FObs.Outcome = coOk);
end;

procedure TTestDispatchBehavior.Pipeline_flush_parts_response_written;
begin
  FCfg.Mode := cmWithoutShutdown;
  FCfg.KeepAlive := False;
  FCfg.PipelineFlush := True;
  FIo.AddRead(GET_REQ + 'rest');
  Start;
  Drive;
  AssertTrue('done', Done);
  AssertEquals('one response', 1, Count('HTTP/1.1 200 OK', FIo.Written));
  AssertEquals('parts', 1, FObs.PartsCount);
  AssertEquals('rest', 'rest', FObs.PartsRest);
  AssertEquals('no shutdown', 0, FIo.ShutdownCalls);
end;

procedure TTestDispatchBehavior.No_pipeline_flush_unchanged_at_end;
begin
  { hyper's defaults: the end-of-connection flush is not taken (the normal
    poll_flush already wrote); the write and shutdown sequence is hyper's }
  FCfg.PipelineFlush := False;
  FCfg.KeepAlive := False;
  FIo.AddRead(GET_REQ + GET_REQ);
  Start;
  Drive;
  AssertTrue('done', Done);
  AssertEquals('one response', 1, Count('HTTP/1.1 200 OK', FIo.Written));
  AssertEquals('one write call', 1, LogCount(FLog, 'write'));
  AssertEquals('shutdown', 1, FIo.ShutdownCalls);
end;

procedure CallInCallCase(T: TDispCase; Mode: Integer; const What: string);
var
  Msg: string;
begin
  { the sixth S7 verifiers (contract lens, minor; K_call_answers_in_call):
    docs/design.md 5.3 says THttpService.Call must not answer or read the body and
    that debug builds assert it, but nothing asserted it: the answer made in
    Call was sent. S7 fix round 7 (deviation S7-46): the dispatcher marks
    the exchange while Call runs, and the terminal calls and TryRead assert
    that mark in builds with assertions }
  T.FSvc.InCall := Mode;
  T.FIo.AddRead('POST / HTTP/1.1' + CRLF + 'Host: x' + CRLF + 'Content-Length: 2' + CRLF + CRLF + 'ab');
  T.Start;
  Msg := '';
  try
    T.Drive;
  except
    on E: EAssertionFailed do
      Msg := E.Message;
  end;
  T.AssertTrue(What + ' in Call raises an assertion (got "' + Msg + '")',
    Pos('THttpService.Call', Msg) > 0);
  T.AssertEquals(What + ' in Call: nothing written', '', T.FIo.Written);
end;

procedure TTestDispatchBehavior.Call_that_answers_asserts;
begin
  CallInCallCase(Self, 1, 'Respond');
end;

procedure TTestDispatchBehavior.Call_that_reads_asserts;
begin
  CallInCallCase(Self, 2, 'TryRead');
end;

procedure TTestDispatchBehavior.Call_without_answer_closes_with_user_error;
begin
  { the production behaviour (every build): the exchange is failed, nothing
    is written and the connection closes with a user error. The service
    opts the exchange out of the -Sa raise with NoResponseIsExpected }
  FSvc.NoAnswer := True;
  FSvc.NoAnswerExpected := True;
  ExpectedNoResponses := 1;
  FIo.AddRead('GET /unanswered HTTP/1.1' + CRLF + 'Host: x' + CRLF + CRLF);
  Start;
  Drive;
  AssertTrue('done', Done);
  AssertEquals('nothing written', '', FIo.Written);
  AssertTrue('outcome user', FObs.Outcome = coUser);
  AssertTrue('detail (got "' + FObs.Detail + '")', Pos('handler returned no response', FObs.Detail) > 0);
  AssertEquals('the call was dropped as completed', 1, FSvc.DropsDone);
  AssertEquals('exchange back in the pool', 1, FPool.FreeCount);
end;

procedure TTestDispatchBehavior.Call_without_answer_asserts;
var
  Msg: string;
begin
  { without the opt-out the -Sa build raises from CompleteCall, inside the
    dispatcher's PollMsg (after Drop and after the exchange was left done
    and failed). The fixture runs the task directly, so the exception
    arrives here; under TLoop.Run it is AbortCurrent that catches it and
    calls Abort and Close on the task, done below by hand: the connection
    closes without a response and nothing leaks (the heaptrc run) }
  FSvc.NoAnswer := True;
  ExpectedNoResponses := 1;
  FIo.AddRead('POST /unanswered?q=1 HTTP/1.1' + CRLF + 'Host: x' + CRLF + 'Content-Length: 2'
    + CRLF + CRLF + 'ab');
  Start;
  Msg := '';
  try
    Drive;
  except
    on E: EAssertionFailed do
      Msg := E.Message;
  end;
  AssertTrue('raised (got "' + Msg + '")', Pos('without a terminal call', Msg) > 0);
  AssertTrue('names the request (got "' + Msg + '")', Pos('POST /unanswered', Msg) > 0);
  AssertEquals('nothing written', '', FIo.Written);
  AssertEquals('the call was dropped once, as completed, before the raise', 1, FSvc.DropsDone);
  AssertEquals('and not dropped again', 0, FSvc.DropsAbandoned);
  AssertFalse('the task is still open when the loop takes over', FD.Closed);
  FD.Abort;                            { as TLoop.AbortCurrent does }
  FD.Close;
  AssertTrue('closed', FD.Closed);
  AssertEquals('no close event: an aborted task reports none', 0, FObs.Closes);
  AssertEquals('exchange back in the pool', 1, FPool.FreeCount);
  AssertTrue('the transport was closed', FIo.Closed);
end;

procedure TTestDispatchBehavior.Cancelled_call_dropped_once;
var
  Step: Integer;
  What: string;
begin
  { decision 10: the dispatcher owns the call and calls Drop exactly once:
    Drop(Ex, False) for a call the connection abandons, with the exchange
    already canceled; TExchange.Cancel does not call it. Each way of
    abandoning a call that was polled and is Pending: client EOF, a read
    error, an abort (exception or shutdown deadline), and graceful shutdown
    of a server that then aborts the rest. }
  for Step := 1 to 3 do
  begin
    if Step > 1 then
    begin
      TearDown;
      SetUp;
    end;
    FSvc.PendForever := True;
    case Step of
      1:
        begin
          What := 'client EOF';
          FIo.AddRead(GET_REQ).AddReadPending.AddReadEof;
        end;
      2:
        begin
          What := 'read error';
          FIo.AddRead(GET_REQ).AddReadPending.AddReadError(ESysECONNRESET);
        end;
    else
      begin
        What := 'abort';
        FIo.AddRead(GET_REQ);
      end;
    end;
    Start;
    Drive;
    if Step = 3 then
    begin
      AssertFalse(What + ': waiting on the call', FD.Closed);
      FD.Abort;
      FD.Close;
    end;
    AssertTrue(What + ': done', Done);
    AssertEquals(What + ': the call was polled', 1, FSvc.Call_.Polls);
    AssertEquals(What + ': one Drop(abandoned)', 1, FSvc.DropsAbandoned);
    AssertEquals(What + ': no Drop(completed)', 0, FSvc.DropsDone);
    AssertEquals(What + ': the exchange was canceled before Drop', 1, FSvc.DropCanceled);
  end;
end;

procedure TTestDispatchBehavior.Idle_releases_trailer_scratch;
var
  Src: TScriptSource;
begin
  { decision 13 / 4.3: a request with trailers (decoder trailer bytes) and a
    response with a declared trailer (encoder trailer names) allocate the
    connection's trailer scratch; the idle connection gives both back }
  Src := TScriptSource.Create(['d:abc', 't']);
  try
    FSvc.Stream := Src;
    FSvc.ReadBody := True;
    FSvc.Headers.Add('trailer=x-t');
    FIo.AddRead('POST / HTTP/1.1' + CRLF + 'Host: x' + CRLF + 'TE: trailers' + CRLF +
      'Transfer-Encoding: chunked' + CRLF + CRLF + '3' + CRLF + 'abc' + CRLF + '0' + CRLF +
      'X-R: 1' + CRLF + CRLF).AddReadPending;
    Start;
    Drive;
    AssertFalse('open (keep-alive)', FD.Closed);
    AssertEquals('body read', 'abc', FSvc.LastBody);
    AssertTrue('trailers on the wire', Pos('x-t: 1', FIo.Written) > 0);
    AssertTrue('idle: exchange released', FD.Ex = nil);
    AssertTrue('decoder trailer bytes released', FD.Conn.Scratch.TrailerBytes.Block = nil);
    AssertTrue('declared trailer names released', (FD.Conn.Scratch.TrailerNames.Bytes = nil)
      and (FD.Conn.Scratch.TrailerNames.Names = nil));
  finally
    Src.Free;
  end;
end;

type
  TTimerCall = class(TServiceCall)
  public
    Timer: TWakeTimer;
    Polls: Integer;
    function Poll(Ex: TExchange): TCallPoll; override;
  end;
  TTimerService = class(THttpService)
  public
    C: TTimerCall;
    function Call(Ex: TExchange): TServiceCall; override;
  end;

function TTimerCall.Poll(Ex: TExchange): TCallPoll;
begin
  Inc(Polls);
  if not Timer.Fired then
  begin
    if Polls = 1 then
      Timer.Arm(Ex, 10);
    Exit(cpPending);                 { the timer wakes the connection }
  end;
  Ex.Respond(BodyEmpty);
  Result := cpReady;
end;

function TTimerService.Call(Ex: TExchange): TServiceCall;
begin
  Result := C;
end;

procedure TTestDispatchBehavior.Pending_call_woken_by_timer;
var
  S: TTimerService;
begin
  S := TTimerService.Create;
  S.C := TTimerCall.Create;
  try
    FIo.AddRead(GET_REQ);
    FD := TH1Dispatcher.Create(FLoop, -1);
    FD.OwnsTransport := False;
    FD.Setup(FIo, S, FCfg, FObs, 1, nil);
    Drive;
    AssertEquals('one poll', 1, S.C.Polls);
    AssertFalse('queued only by the timer', FD.Queued);
    FLoop.NowMs := FLoop.NowMs + 20;
    FLoop.Timers.Advance(FLoop.NowMs);
    AssertTrue('woken by the timer', FD.Queued);
    Drive;
    AssertEquals('answered', 1, Count('HTTP/1.1 200 OK', FIo.Written));
  finally
    if not FD.Closed then
    begin
      FD.Abort;
      FD.Close;
    end;
    if not S.C.Timer.Fired then
      S.C.Timer.Cancel(nil);
    S.C.Free;
    S.Free;
  end;
end;

{ ---- TServer over real sockets ---- }

type
  TSrvApp = class
    function NewService(Loop: TLoop): THttpService;
  end;

function TSrvApp.NewService(Loop: TLoop): THttpService;
var
  S: TTestService;
begin
  S := TTestService.Create;
  S.RespBody := 'ok';
  Result := S;
end;

function Connect(Port: Word): cint;
var
  A: TInetSockAddr;
begin
  Result := fpSocket(AF_INET, SOCK_STREAM, 0);
  A.sin_family := AF_INET;
  A.sin_port := htons(Port);
  A.sin_addr.s_addr := htonl($7F000001);
  if fpConnect(Result, @A, SizeOf(A)) <> 0 then
    raise Exception.Create('connect failed');
end;

procedure SendAll(Fd: cint; const S: RawByteString);
begin
  if fpSend(Fd, PAnsiChar(S), Length(S), 0) <> Length(S) then
    raise Exception.Create('send failed');
end;

{ reads until Count occurrences of Marker were seen, or EOF / 5 s }
function RecvUntil(Fd: cint; const Marker: RawByteString; N: Integer; out Eof: Boolean): RawByteString;
var
  Buf: array[0..65535] of AnsiChar;
  R: ssize_t;
  TV: TTimeVal;
  S: RawByteString;
begin
  Result := '';
  Eof := False;
  TV.tv_sec := 5;
  TV.tv_usec := 0;
  fpSetSockOpt(Fd, SOL_SOCKET, SO_RCVTIMEO, @TV, SizeOf(TV));
  while (N < 0) or (Count(Marker, Result) < N) do
  begin
    R := fpRecv(Fd, @Buf[0], SizeOf(Buf), 0);
    if R <= 0 then
    begin
      Eof := R = 0;
      Exit;
    end;
    SetString(S, PAnsiChar(@Buf[0]), R);
    Result := Result + S;
  end;
end;

function TestServerConfig: TServerConfig;
begin
  Result := BenchmarkServerConfig;
  Result.Listen.Host := '127.0.0.1';
  Result.Listen.Port := 0;
  Result.Loops := 2;
  Result.H1.AutoDateHeader := False;
end;

procedure TTestDispatchServer.Server_keep_alive_and_pipelining;
var
  App: TSrvApp;
  Srv: TServer;
  Fd: cint;
  Got, Reqs: RawByteString;
  Eof: Boolean;
  I: Integer;
begin
  App := TSrvApp.Create;
  Srv := TServer.Create(TestServerConfig, @App.NewService);
  try
    Srv.Start;
    AssertTrue('port', Srv.Port <> 0);
    Fd := Connect(Srv.Port);
    try
      SendAll(Fd, GET_REQ);
      Got := RecvUntil(Fd, 'ok', 1, Eof);
      AssertEquals('first', 'HTTP/1.1 200 OK' + CRLF + 'content-length: 2' + CRLF + CRLF + 'ok', Got);
      Reqs := '';
      for I := 1 to 16 do
        Reqs := Reqs + GET_REQ;
      SendAll(Fd, Reqs);
      Got := RecvUntil(Fd, 'HTTP/1.1 200 OK', 16, Eof);
      AssertEquals('pipelined responses', 16, Count('HTTP/1.1 200 OK', Got));
      SendAll(Fd, 'GET / HTTP/1.1' + CRLF + 'Host: x' + CRLF + 'Connection: close' + CRLF + CRLF);
      Got := RecvUntil(Fd, '', -1, Eof);
      AssertTrue('closed by the server', Eof);
      AssertTrue('connection: close', Pos('connection: close', Got) > 0);
    finally
      fpClose(Fd);
    end;
  finally
    Srv.Stop(1000);
    Srv.Wait;
    Srv.Free;
    App.Free;
  end;
end;

{ decision 11 (H-11): an exception from the observer during connection
  setup closes that connection only; the transport not yet given to the
  dispatcher is freed (the heaptrc build of this suite checks it), the
  listener counts the error and keeps accepting }
type
  TFailObserver = class(TConnObserver)
  public
    N: LongInt;
    function OnAccept(Loop: TLoop; ConnId: QWord; const Peer: TSockAddrStorage): Pointer; override;
    function WrapTransport(T: TTcpTransport; Data: Pointer): TTransport; override;
  end;

function TFailObserver.OnAccept(Loop: TLoop; ConnId: QWord; const Peer: TSockAddrStorage): Pointer;
begin
  if InterLockedIncrement(N) = 1 then
    raise Exception.Create('test: OnAccept fails');
  Result := nil;
end;

function TFailObserver.WrapTransport(T: TTcpTransport; Data: Pointer): TTransport;
begin
  if N = 2 then
    raise Exception.Create('test: WrapTransport fails');
  Result := T;
end;

procedure TTestDispatchServer.Server_setup_failure_closes_connection_and_continues;
var
  App: TSrvApp;
  Obs: TFailObserver;
  Cfg: TServerConfig;
  Srv: TServer;
  Fd: cint;
  Got: RawByteString;
  Eof: Boolean;
  I: Integer;
begin
  App := TSrvApp.Create;
  Obs := TFailObserver.Create;
  Cfg := TestServerConfig;
  Cfg.Loops := 1;
  Srv := TServer.Create(Cfg, @App.NewService, Obs);
  try
    Srv.Start;
    for I := 1 to 4 do
    begin
      Fd := Connect(Srv.Port);
      try
        SendAll(Fd, 'GET / HTTP/1.1' + CRLF + 'Host: x' + CRLF + 'Connection: close' + CRLF + CRLF);
        Got := RecvUntil(Fd, '', -1, Eof);
        if I <= 2 then
          AssertEquals('connection ' + IntToStr(I) + ': closed without a response', '', Got)
        else
          AssertTrue('connection ' + IntToStr(I) + ': served',
            Pos('HTTP/1.1 200 OK', Got) = 1);
      finally
        fpClose(Fd);
      end;
    end;
    AssertEquals('accepted', 4, Srv.Loops[0].Listener.Accepted);
    AssertEquals('setup errors counted', 2, Srv.Loops[0].Listener.SetupErrors);
  finally
    Srv.Stop(1000);
    Srv.Wait;
    Srv.Free;
    Obs.Free;
    App.Free;
  end;
end;

procedure TTestDispatchServer.Server_graceful_shutdown_connections;
var
  App: TSrvApp;
  Srv: TServer;
  Fd, Fd2: cint;
  Got: RawByteString;
  Eof: Boolean;
begin
  App := TSrvApp.Create;
  Srv := TServer.Create(TestServerConfig, @App.NewService);
  try
    Srv.Start;
    Fd := Connect(Srv.Port);
    try
      SendAll(Fd, GET_REQ);
      RecvUntil(Fd, 'ok', 1, Eof);
      Srv.GracefulShutdownConnections;
      Got := RecvUntil(Fd, '', -1, Eof);
      AssertTrue('idle connection closed', Eof);
      AssertEquals('nothing more', '', Got);
      { listeners keep accepting }
      Fd2 := Connect(Srv.Port);
      SendAll(Fd2, GET_REQ);
      Got := RecvUntil(Fd2, 'ok', 1, Eof);
      AssertTrue('new connection served', Pos('200 OK', Got) > 0);
      fpClose(Fd2);
    finally
      fpClose(Fd);
    end;
  finally
    Srv.Stop(1000);
    Srv.Wait;
    Srv.Free;
    App.Free;
  end;
end;

procedure TTestDispatchServer.Server_stop_with_idle_connections;
var
  App: TSrvApp;
  Srv: TServer;
  Fds: array[0..9] of cint;
  I: Integer;
  Eof: Boolean;
  T0: QWord;
begin
  App := TSrvApp.Create;
  Srv := TServer.Create(TestServerConfig, @App.NewService);
  try
    Srv.Start;
    for I := 0 to High(Fds) do
    begin
      Fds[I] := Connect(Srv.Port);
      SendAll(Fds[I], GET_REQ);
      RecvUntil(Fds[I], 'ok', 1, Eof);
    end;
    T0 := GetTickCount64;
    Srv.Stop(5000);
    Srv.Wait;
    AssertTrue('stopped before the deadline', GetTickCount64 - T0 < 2000);
    for I := 0 to High(Fds) do
    begin
      RecvUntil(Fds[I], '', -1, Eof);
      AssertTrue('closed', Eof);
      fpClose(Fds[I]);
    end;
  finally
    Srv.Free;
    App.Free;
  end;
end;

{ ---- S6: upgrades and parts over real sockets ---- }

var
  WrapLive: LongInt = 0;
  WrapFreedTotal: PtrInt = -1;      { Total of the last TWrapT freed }

type
  { an owned wrapping transport, like the conformance server's TCountingTransport }
  TWrapT = class(TTransport)
  public
    Inner: TTransport;
    OwnsInner: Boolean;
    Total: PtrInt;
    constructor Create(AInner: TTransport);
    destructor Destroy; override;
    function Read(Buf: PByte; Len: SizeInt): SizeInt; override;
    function Write(Buf: PByte; Len: SizeInt): SizeInt; override;
    function WriteV(Iov: PIoSlice; Count: Integer): SizeInt; override;
    function IsWriteVectored: Boolean; override;
    function ShutdownWrite: SizeInt; override;
    procedure Close; override;
    function Wrapped: TTransport; override;
    procedure DisownWrapped; override;
  end;

  { the raw side after the hand-off: writes Greeting, then reads to EOF }
  TRawEcho = class(TRawListener)
  public
    Greeting: RawByteString;
    WPos: Integer;
    Data: RawByteString;
    Finished: Boolean;
    ReadError: SizeInt;
    procedure Step(U: TUpgraded);
    procedure Readable(U: TUpgraded); override;
    procedure Writable(U: TUpgraded); override;
  end;

  TUpHandler = class(TUpgradeHandler)
  public
    Echo: TRawEcho;
    Failed: string;
    procedure Upgraded(U: TUpgraded); override;
    procedure UpgradeFailed(const Msg: string); override;
  end;

  TUpCall = class(TServiceCall)
  public
    Handler: TUpHandler;             { nil: no upgrade::on (without_shutdown) }
    function Poll(Ex: TExchange): TCallPoll; override;
  end;

  TUpService = class(THttpService)
  public
    C: TUpCall;
    destructor Destroy; override;
    function Call(Ex: TExchange): TServiceCall; override;
  end;

  TUpApp = class
  public
    Handler: TUpHandler;
    function NewService(Loop: TLoop): THttpService;
  end;

  TWrapObserver = class(TConnObserver)
  public
    Loop: TLoop;
    Wrap: TWrapT;
    WrapTotal: PtrInt;
    Echo: TRawEcho;                  { OnParts: keep the socket and run Echo on it }
    GsOnStart: Boolean;
    Starts: Integer;
    function OnAccept(ALoop: TLoop; ConnId: QWord; const Peer: TSockAddrStorage): Pointer; override;
    function WrapTransport(T: TTcpTransport; Data: Pointer): TTransport; override;
    procedure OnStart(ConnId: QWord; Data: Pointer; Task: TLoopTask); override;
    procedure OnParts(ConnId: QWord; Data: Pointer; var Parts: TConnParts); override;
  end;

constructor TWrapT.Create(AInner: TTransport);
begin
  inherited Create;
  Inner := AInner;
  OwnsInner := True;
  InterLockedIncrement(WrapLive);
end;

destructor TWrapT.Destroy;
begin
  if OwnsInner then
    Inner.Free;
  WrapFreedTotal := Total;
  InterLockedDecrement(WrapLive);
  inherited Destroy;
end;

function TWrapT.Read(Buf: PByte; Len: SizeInt): SizeInt;
begin
  Result := Inner.Read(Buf, Len);
  if Result > 0 then
    Inc(Total, Result);
end;

function TWrapT.Write(Buf: PByte; Len: SizeInt): SizeInt;
begin Result := Inner.Write(Buf, Len); end;
function TWrapT.WriteV(Iov: PIoSlice; Count: Integer): SizeInt;
begin Result := Inner.WriteV(Iov, Count); end;
function TWrapT.IsWriteVectored: Boolean;
begin Result := Inner.IsWriteVectored; end;
function TWrapT.ShutdownWrite: SizeInt;
begin Result := Inner.ShutdownWrite; end;
procedure TWrapT.Close;
begin Inner.Close; end;
function TWrapT.Wrapped: TTransport;
begin Result := Inner; end;
procedure TWrapT.DisownWrapped;
begin OwnsInner := False; end;

procedure TRawEcho.Step(U: TUpgraded);
var
  Buf: array[0..4095] of Byte;
  R: SizeInt;
  S: RawByteString;
begin
  if Finished then
    Exit;
  while WPos < Length(Greeting) do
  begin
    R := U.TryWrite(@Greeting[WPos + 1], Length(Greeting) - WPos);
    if R = -ESysEAGAIN then
      Exit;
    if R <= 0 then
    begin
      ReadError := R;
      Finished := True;
      U.Close;
      Exit;
    end;
    Inc(WPos, R);
  end;
  while True do
  begin
    R := U.TryRead(@Buf[0], SizeOf(Buf));
    if R = -ESysEAGAIN then
      Exit;
    if R > 0 then
    begin
      SetString(S, PAnsiChar(@Buf[0]), R);
      Data := Data + S;
      Continue;
    end;
    ReadError := R;
    Finished := True;
    U.Close;
    Exit;
  end;
end;

procedure TRawEcho.Readable(U: TUpgraded);
begin
  Step(U);
end;

procedure TRawEcho.Writable(U: TUpgraded);
begin
  Step(U);
end;

procedure TUpHandler.Upgraded(U: TUpgraded);
begin
  U.Attach(Echo);
end;

procedure TUpHandler.UpgradeFailed(const Msg: string);
begin
  Failed := Msg;
end;

function TUpCall.Poll(Ex: TExchange): TCallPoll;
begin
  if Handler <> nil then
    Ex.OnUpgrade(Handler);
  Ex.Status := 101;
  Ex.ResponseHeaders.Insert('upgrade', 'foo');
  Ex.ResponseHeaders.Insert('connection', 'upgrade');
  Ex.Respond(BodyEmpty);
  Result := cpReady;
end;

destructor TUpService.Destroy;
begin
  C.Free;
  inherited Destroy;
end;

function TUpService.Call(Ex: TExchange): TServiceCall;
begin
  Result := C;
end;

function TUpApp.NewService(Loop: TLoop): THttpService;
var
  S: TUpService;
begin
  S := TUpService.Create;
  S.C := TUpCall.Create;
  S.C.Handler := Handler;
  Result := S;
end;

function TWrapObserver.OnAccept(ALoop: TLoop; ConnId: QWord; const Peer: TSockAddrStorage): Pointer;
begin
  Loop := ALoop;
  Result := nil;
end;

function TWrapObserver.WrapTransport(T: TTcpTransport; Data: Pointer): TTransport;
begin
  Wrap := TWrapT.Create(T);
  Result := Wrap;
end;

procedure TWrapObserver.OnStart(ConnId: QWord; Data: Pointer; Task: TLoopTask);
begin
  Inc(Starts);
  if GsOnStart then
    TH1Dispatcher(Task).GracefulShutdown;
end;

procedure TWrapObserver.OnParts(ConnId: QWord; Data: Pointer; var Parts: TConnParts);
var
  U: TUpgraded;
begin
  if Echo = nil then
  begin
    inherited OnParts(ConnId, Data, Parts);
    Exit;
  end;
  { the bytes the wrapper counted before the hand-off }
  WrapTotal := Wrap.Total;
  U := TUpgraded.CreateFrom(Loop, Parts.Transport, Parts.Rest, Parts.Src, True);
  Parts.Transport := nil;
  Parts.Rest := Default(TBytesView);
  U.Attach(Echo);
end;

const
  UPGRADE_REQ = 'GET / HTTP/1.1' + #13#10 + 'Host: x' + #13#10 + 'Upgrade: foo' + #13#10 +
    'Connection: upgrade' + #13#10#13#10;

procedure RunUpgradeClient(Port: Word; out Head: RawByteString; out Closed: Boolean);
var
  Fd: cint;
  Eof: Boolean;
begin
  Fd := Connect(Port);
  try
    SendAll(Fd, UPGRADE_REQ + 'left');
    Head := RecvUntil(Fd, 'hello-raw', 1, Eof);
    SendAll(Fd, 'more');
    fpShutdown(Fd, SHUT_WR);
    RecvUntil(Fd, '', -1, Closed);
  finally
    fpClose(Fd);
  end;
end;

procedure TTestDispatchServer.Server_upgrade_through_wrapping_observer;
var
  App: TUpApp;
  Obs: TWrapObserver;
  Cfg: TServerConfig;
  Srv: TServer;
  Head: RawByteString;
  Closed: Boolean;
  Live0: LongInt;
begin
  Live0 := WrapLive;
  WrapFreedTotal := -1;
  App := TUpApp.Create;
  App.Handler := TUpHandler.Create;
  App.Handler.Echo := TRawEcho.Create;
  App.Handler.Echo.Greeting := 'hello-raw';
  Obs := TWrapObserver.Create;
  Cfg := TestServerConfig;
  Cfg.Loops := 1;
  Cfg.H1.Mode := cmWithUpgrades;
  { hyper's defaults: with pipeline_flush the 101 stays in the write buffer
    when the read buffer holds the leftover, and into_inner drops it }
  Cfg.H1.PipelineFlush := False;
  Srv := TServer.Create(Cfg, @App.NewService, Obs);
  try
    Srv.Start;
    RunUpgradeClient(Srv.Port, Head, Closed);
    Srv.Stop(1000);
    Srv.Wait;
    AssertTrue('101 then the raw greeting: ' + Head,
      AnsiStartsStr('HTTP/1.1 101 Switching Protocols', Head)
      and AnsiEndsStr(#13#10#13#10 + 'hello-raw', Head));
    AssertEquals('handler not failed', '', App.Handler.Failed);
    AssertTrue('the raw side read to EOF', App.Handler.Echo.Finished);
    AssertEquals('EOF, not an error', 0, App.Handler.Echo.ReadError);
    AssertEquals('leftover first, then the socket', 'leftmore', App.Handler.Echo.Data);
    AssertTrue('the server closed the upgraded socket', Closed);
    AssertEquals('the wrapper counted only what the HTTP layer read',
      Length(UPGRADE_REQ + 'left'), WrapFreedTotal);
  finally
    Srv.Free;
  end;
  { the wrapper was freed at the hand-off (Obs.Wrap is dangling) }
  AssertEquals('wrapper freed', Live0, WrapLive);
  Obs.Free;
  App.Handler.Echo.Free;
  App.Handler.Free;
  App.Free;
end;

procedure TTestDispatchServer.Server_without_shutdown_parts_keep_socket;
var
  App: TUpApp;
  Obs: TWrapObserver;
  Cfg: TServerConfig;
  Srv: TServer;
  Head: RawByteString;
  Closed: Boolean;
  Live0: LongInt;
begin
  Live0 := WrapLive;
  App := TUpApp.Create;
  Obs := TWrapObserver.Create;
  Obs.Echo := TRawEcho.Create;
  Obs.Echo.Greeting := 'hello-raw';
  Cfg := TestServerConfig;
  Cfg.Loops := 1;
  Cfg.H1.Mode := cmWithoutShutdown;
  { hyper's defaults: with pipeline_flush the 101 stays in the write buffer
    when the read buffer holds the leftover, and into_inner drops it }
  Cfg.H1.PipelineFlush := False;
  Srv := TServer.Create(Cfg, @App.NewService, Obs);
  try
    Srv.Start;
    RunUpgradeClient(Srv.Port, Head, Closed);
    Srv.Stop(1000);
    Srv.Wait;
    AssertTrue('101 then the raw greeting: ' + Head,
      AnsiStartsStr('HTTP/1.1 101 Switching Protocols', Head)
      and AnsiEndsStr(#13#10#13#10 + 'hello-raw', Head));
    AssertTrue('the raw side read to EOF', Obs.Echo.Finished);
    AssertEquals('EOF, not an error', 0, Obs.Echo.ReadError);
    AssertEquals('parts rest first, then the socket', 'leftmore', Obs.Echo.Data);
    AssertTrue('closed after the raw side', Closed);
    AssertEquals('the wrapper counted only what the HTTP layer read',
      Length(UPGRADE_REQ + 'left'), Obs.WrapTotal);
  finally
    Srv.Free;
  end;
  AssertEquals('wrapper freed', Live0, WrapLive);
  Obs.Echo.Free;
  Obs.Free;
  App.Free;
end;

procedure TTestDispatchServer.Server_observer_on_start;
var
  App: TSrvApp;
  Obs: TWrapObserver;
  Cfg: TServerConfig;
  Srv: TServer;
  Fd: cint;
  Got: RawByteString;
  Eof: Boolean;
begin
  App := TSrvApp.Create;
  Obs := TWrapObserver.Create;
  Obs.GsOnStart := True;
  Cfg := TestServerConfig;
  Cfg.Loops := 1;
  Srv := TServer.Create(Cfg, @App.NewService, Obs);
  try
    Srv.Start;
    Fd := Connect(Srv.Port);
    try
      SendAll(Fd, GET_REQ);
      Got := RecvUntil(Fd, '', -1, Eof);
      AssertEquals('closed without a response', '', Got);
    finally
      fpClose(Fd);
    end;
    Srv.Stop(1000);
    Srv.Wait;
    AssertEquals('OnStart once', 1, Obs.Starts);
  finally
    Srv.Free;
    Obs.Free;
    App.Free;
  end;
end;

type
  { raises from the delivery task, after closing the stream it owns }
  TRaiseUpHandler = class(TUpHandler)
  public
    procedure Upgraded(U: TUpgraded); override;
  end;

  { writes Payload only from Writable, reads only from Readable (to EOF,
    then closes); counts the writes that met EAGAIN }
  TRawBlast = class(TRawListener)
  public
    Payload: RawByteString;
    WPos: SizeInt;
    Blocked: Integer;
    Finished: Boolean;
    ReadError: SizeInt;
    procedure Readable(U: TUpgraded); override;
    procedure Writable(U: TUpgraded); override;
  end;

  TBlastHandler = class(TUpHandler)
  public
    Blast: TRawBlast;
    procedure Upgraded(U: TUpgraded); override;
  end;

procedure TRaiseUpHandler.Upgraded(U: TUpgraded);
begin
  U.Close;
  raise Exception.Create('handler failure (test)');
end;

procedure TRawBlast.Readable(U: TUpgraded);
var
  Buf: array[0..4095] of Byte;
  R: SizeInt;
begin
  if Finished then
    Exit;
  repeat
    R := U.TryRead(@Buf[0], SizeOf(Buf));
  until R <= 0;
  if R = -ESysEAGAIN then
    Exit;
  ReadError := R;
  Finished := True;
  U.Close;
end;

procedure TRawBlast.Writable(U: TUpgraded);
var
  R: SizeInt;
begin
  while WPos < Length(Payload) do
  begin
    R := U.TryWrite(@Payload[WPos + 1], Length(Payload) - WPos);
    if R = -ESysEAGAIN then
    begin
      Inc(Blocked);
      Exit;
    end;
    if R <= 0 then
    begin
      ReadError := R;
      Finished := True;
      U.Close;
      Exit;
    end;
    Inc(WPos, R);
  end;
end;

procedure TBlastHandler.Upgraded(U: TUpgraded);
begin
  U.Attach(Blast);
end;

procedure TTestDispatchServer.Server_upgrade_handler_raises_releases_slot;
var
  App: TUpApp;
  Cfg: TServerConfig;
  Srv: TServer;
  Fd: cint;
  Got: RawByteString;
  Eof: Boolean;
  L0: LongInt;
begin
  L0 := UpgradeSlotsLive;
  App := TUpApp.Create;
  App.Handler := TRaiseUpHandler.Create;
  Cfg := TestServerConfig;
  Cfg.Loops := 1;
  Cfg.H1.Mode := cmWithUpgrades;
  Srv := TServer.Create(Cfg, @App.NewService);
  try
    Srv.Start;
    Fd := Connect(Srv.Port);
    try
      SendAll(Fd, UPGRADE_REQ);
      Got := RecvUntil(Fd, '', -1, Eof);
    finally
      fpClose(Fd);
    end;
    Srv.Stop(1000);
    Srv.Wait;
    AssertTrue('101: ' + Got, AnsiStartsStr('HTTP/1.1 101 Switching Protocols', Got));
    AssertTrue('the handler closed the stream', Eof);
    AssertEquals('slot freed after the handler raised', L0, UpgradeSlotsLive);
  finally
    Srv.Free;
  end;
  App.Handler.Free;
  App.Free;
end;

procedure TTestDispatchServer.Server_upgraded_write_resumes_on_writable;
const
  PAYLOAD_LEN = 32 * 1024 * 1024;   { more than the loopback socket buffers hold }
var
  App: TUpApp;
  H: TBlastHandler;
  Cfg: TServerConfig;
  Srv: TServer;
  Fd: cint;
  Buf: array[0..65535] of AnsiChar;
  Head: RawByteString;
  S: RawByteString;
  P: SizeInt;
  R: ssize_t;
  TV: TTimeVal;
  Body: QWord;
  BadByte, Eof: Boolean;
  I: Integer;
begin
  App := TUpApp.Create;
  H := TBlastHandler.Create;
  H.Blast := TRawBlast.Create;
  SetLength(H.Blast.Payload, PAYLOAD_LEN);
  FillChar(H.Blast.Payload[1], PAYLOAD_LEN, Ord('x'));
  App.Handler := H;
  Cfg := TestServerConfig;
  Cfg.Loops := 1;
  Cfg.H1.Mode := cmWithUpgrades;
  Srv := TServer.Create(Cfg, @App.NewService);
  try
    Srv.Start;
    Fd := Connect(Srv.Port);
    try
      SendAll(Fd, UPGRADE_REQ);
      { the server fills the socket buffers and meets EAGAIN }
      Sleep(300);
      TV.tv_sec := 5;
      TV.tv_usec := 0;
      fpSetSockOpt(Fd, SOL_SOCKET, SO_RCVTIMEO, @TV, SizeOf(TV));
      Head := '';
      Body := 0;
      BadByte := False;
      while Body < PAYLOAD_LEN do
      begin
        R := fpRecv(Fd, @Buf[0], SizeOf(Buf), 0);
        if R <= 0 then
          Break;
        if Pos(CRLF + CRLF, Head) = 0 then
        begin
          SetString(S, PAnsiChar(@Buf[0]), R);
          Head := Head + S;
          P := Pos(CRLF + CRLF, Head);
          if P > 0 then
          begin
            S := Copy(Head, P + 4, MaxInt);
            SetLength(Head, P + 3);
            for I := 1 to Length(S) do
              if S[I] <> 'x' then
                BadByte := True;
            Inc(Body, Length(S));
          end;
        end
        else
        begin
          for I := 0 to R - 1 do
            if Buf[I] <> 'x' then
              BadByte := True;
          Inc(Body, R);
        end;
      end;
      fpShutdown(Fd, SHUT_WR);
      S := RecvUntil(Fd, '', -1, Eof);
    finally
      fpClose(Fd);
    end;
    Srv.Stop(1000);
    Srv.Wait;
    AssertTrue('101: ' + Head, AnsiStartsStr('HTTP/1.1 101 Switching Protocols', Head));
    AssertEquals('every payload byte arrived', QWord(PAYLOAD_LEN), Body);
    AssertFalse('payload bytes', BadByte);
    AssertTrue('a raw write met EAGAIN and resumed', H.Blast.Blocked > 0);
    AssertTrue('the raw side read to EOF', H.Blast.Finished);
    AssertEquals('EOF, not an error', 0, H.Blast.ReadError);
    AssertEquals('nothing after the payload', '', S);
    AssertTrue('closed by the server', Eof);
  finally
    Srv.Free;
  end;
  H.Blast.Free;
  H.Free;
  App.Free;
end;

procedure TTestDispatchServer.Server_upgrade_pipeline_flush_keeps_101;
var
  App: TUpApp;
  Cfg: TServerConfig;
  Srv: TServer;
  Head: RawByteString;
  Closed: Boolean;
begin
  App := TUpApp.Create;
  App.Handler := TUpHandler.Create;
  App.Handler.Echo := TRawEcho.Create;
  App.Handler.Echo.Greeting := 'hello-raw';
  Cfg := TestServerConfig;
  Cfg.Loops := 1;
  Cfg.H1.Mode := cmWithUpgrades;
  Cfg.H1.PipelineFlush := True;
  Srv := TServer.Create(Cfg, @App.NewService);
  try
    Srv.Start;
    RunUpgradeClient(Srv.Port, Head, Closed);
    Srv.Stop(1000);
    Srv.Wait;
    AssertTrue('101 then the raw greeting: ' + Head,
      AnsiStartsStr('HTTP/1.1 101 Switching Protocols', Head)
      and AnsiEndsStr(#13#10#13#10 + 'hello-raw', Head));
    AssertEquals('leftover first, then the socket', 'leftmore', App.Handler.Echo.Data);
    AssertTrue('the server closed the upgraded socket', Closed);
  finally
    Srv.Free;
  end;
  App.Handler.Echo.Free;
  App.Handler.Free;
  App.Free;
end;

{$ifdef WD_STALL}
{ ---- TTestDispatchStall (step UB) ---- }

procedure TTestDispatchStall.Head_wait_is_the_clients;
begin
  FIo.AddRead('GET / HTTP/1.1' + CRLF + 'Host: x');
  Start;
  Drive;
  AssertFalse('open', Done);
  AssertTrue('the last run waited on the client', FD.StallClientWait and FD.StallReadWait);
  FD.Src.Ready := [];
  FLoop.NowMs := FLoop.NowMs + 120000;
  AssertFalse('a head that waits on the client is no stall', FD.StallCandidate(FLoop.NowMs, 60000));
end;

procedure TTestDispatchStall.Body_wait_with_a_call_pending_is_the_clients;
begin
  FSvc.ReadBody := True;
  FIo.AddRead('POST / HTTP/1.1' + CRLF + 'Host: x' + CRLF + 'Content-Length: 10' + CRLF + CRLF + 'abc');
  Start;
  Drive;
  AssertFalse('open', Done);
  AssertTrue('a call in flight', FD.InFlight <> nil);
  AssertTrue('its body read found no byte', FD.StallBodyRead);
  AssertTrue('the client''s wait', FD.StallClientWait);
  FD.Src.Ready := [];
  FLoop.NowMs := FLoop.NowMs + 120000;
  AssertFalse('no stall', FD.StallCandidate(FLoop.NowMs, 60000));
end;

procedure TTestDispatchStall.Pending_call_is_reported_after_60_s;
var T0: Int64;
begin
  FSvc.PendForever := True;
  FIo.AddRead('GET / HTTP/1.1' + CRLF + 'Host: x' + CRLF + CRLF);
  Start;
  Drive;
  AssertFalse('open', Done);
  AssertFalse('the server owes the answer', FD.StallClientWait);
  FD.Src.Ready := [];
  T0 := FLoop.NowMs;
  AssertFalse('not before 60 s', FD.StallCandidate(T0 + 59999, 60000));
  AssertTrue('at 60 s', FD.StallCandidate(T0 + 60000, 60000));
  AssertEquals('the service call is pending', FD.StallReason);
end;

procedure TTestDispatchStall.Readiness_not_acted_on_is_reported;
begin
  FIo.AddRead('GET / HTTP/1.1' + CRLF + 'Host: x');
  Start;
  Drive;
  FD.Src.Ready := [rdRead];             { an edge came and the task did not run }
  FLoop.NowMs := FLoop.NowMs + 120000;
  AssertTrue('reported', FD.StallCandidate(FLoop.NowMs, 60000));
  AssertEquals('a readiness event not acted on', FD.StallReason);
  FD.Src.Ready := [rdWrite];             { the other side: not what it waited on }
  AssertFalse('a write edge does not matter for a read wait', FD.StallCandidate(FLoop.NowMs, 60000));
end;

function THoldCall.Poll(Ex: TExchange): TCallPoll;
begin
  Held := Ex.Share;
  Ex.Status := 200;
  Ex.Respond(BodyString(StringOfChar('x', 100000)));
  Result := cpReady;
end;

function THoldService.Call(Ex: TExchange): TServiceCall;
begin
  Result := C;
end;

procedure TTestDispatchStall.Chunk_waiting_for_its_receiver_is_reported;
var Svc: THoldService;
begin
  { the call answered and holds the request (shared) without reading the
    body: the body chunk waits for its receiver (the server owes it) while
    the client does not read the response (a write EAGAIN) }
  Svc := THoldService.Create;
  Svc.C := THoldCall.Create;
  try
    FIo.AddRead('POST / HTTP/1.1' + CRLF + 'Host: x' + CRLF + 'Content-Length: 20' + CRLF + CRLF +
      '0123456789');
    FIo.AddWriteLimit(1000);
    FIo.BlockWritesWhenDone := True;
    FDFreed := False;
    FD := TFixtureDispatcher.Create(FLoop, -1);
    TFixtureDispatcher(FD).Freed := @FDFreed;
    FD.OwnsTransport := False;
    FD.Setup(FIo, Svc, FCfg, FObs, 1, nil);
    Drive;
    AssertFalse('open', Done);
    AssertTrue('answered', FD.InFlight = nil);
    AssertTrue('the write waits on the client', FD.StallWriteWait);
    AssertFalse('but a chunk waits for the receiver', FD.StallClientWait);
    FD.Src.Ready := [];
    FLoop.NowMs := FLoop.NowMs + 120000;
    AssertTrue('reported', FD.StallCandidate(FLoop.NowMs, 60000));
    AssertEquals('a body chunk waits for the receiver', FD.StallReason);
    Svc.C.Held.Release;
    FD.Abort;
    FD.Close;
  finally
    Svc.C.Free;
    Svc.Free;
  end;
end;

procedure TTestDispatchStall.Queued_task_is_reported;
begin
  FIo.AddRead('GET / HTTP/1.1' + CRLF + 'Host: x');
  Start;
  Drive;
  FD.Src.Ready := [];
  FD.Wake;                               { queued, and the loop never runs it }
  FLoop.NowMs := FLoop.NowMs + 120000;
  AssertTrue('reported', FD.StallCandidate(FLoop.NowMs, 60000));
  AssertEquals('woken, not run', FD.StallReason);
  FLoop.RunIteration;                    { runs it: no longer a candidate }
  AssertFalse('ran', FD.StallCandidate(FLoop.NowMs, 60000));
end;
{$endif}

begin
  RegisterTest(TTestDispatchHyper);
  RegisterTest(TTestDispatchPipeline);
  RegisterTest(TTestDispatchBehavior);
  RegisterTest(TTestDispatchServer);
  {$ifdef WD_STALL}
  RegisterTest(TTestDispatchStall);
  {$endif}
  with TTestRunner.Create(nil) do
  try
    Initialize;
    Run;
  finally
    Free;
  end;
end.

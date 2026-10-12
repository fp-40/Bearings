{ M3 step S4 tests for bearings.http1.conn (port of hyper conn.rs), bearings.http1.config
  and bearings.http.error (docs/design.md sections 5 and 9).

  TTestConnRs: the server tests of hyper v1.12.0 src/proto/h1/conn.rs
  (conn_reads_request_head .. conn_writes_chunked_body; the client tests
  and the nightly bench are not ported).
  TTestConnState: the state tables: State::try_keep_alive over every
  (Reading, Writing, KA) triple, written from conn.rs:1100-1119, and the
  conn-level events (request head, body chunk, body end, response head,
  body frame, flush, EOF, graceful shutdown, timer) from the reachable
  states, each expected value taken from conn.rs.
  TTestConnBehavior: expect/continue, trailers (every write_trailers
  branch, T1 order), error-to-response mapping (2.8), keep-alive fixes for
  HTTP/1.0, maybe_notify, mid_message_detect_eof, pipelining, body decode
  errors, the header read timeout, upgrades (prepare_upgrade).
  Step H (decisions 7, 9, 13): the four S4 mutation survivors (leading CRLF
  then EOF while idle; try_keep_alive after a body that ends once the
  response is in KeepAlive; a chunked terminator in its own read; see also
  test_body_chan), the upgrade slot's reference count, and an error head or
  a 100 Continue written while body bytes are queued (it goes behind them).
  TTestH1Config: bearings.http1.config. TTestHyperError: bearings.http.error.
  TTestConnBodyRate (step UB): the body rate rule (docs/design.md 5.7): off by
  default, one wait of BodyTimeoutMs fails the body (ETIMEDOUT, Reading
  closed, the owner woken by the timer, the error kept for TakeError), a
  frame restarts the wait, time the server does not read is not counted,
  the average-rate part, the config fields, defaults and validation.
  Run: test_h1_conn --all --format=plain }
program test_h1_conn;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Classes, SysUtils, fpcunit, testregistry, consoletestrunner,
  ctypes, bearings.rt.sys, bearings.rt.buf, bearings.rt.timer, bearings.rt.loop, bearings.rt.net, bearings.rt.stream, bearings.http.headers,
  bearings.http.date, bearings.http1.parser, bearings.http1.encode, bearings.http1.decode, bearings.http1.role,
  bearings.http.error, bearings.http.exchange, bearings.http1.io, bearings.http1.conn, bearings.http1.config,
  bearings.test.mocktransport;

const
  CRLF = #13#10;

type
  { The connection's owner task: counts runs, never runs on its own. }
  TOwnerTask = class(TLoopTask)
  public
    Runs: Integer;
    procedure Run; override;
    procedure Abort; override;
  end;

  { A fixture: loop, owner task, mock transport and the connection (a
    field of a class, so the pointers into it stay valid). }
  TConnCase = class(TTestCase)
  protected
    FLoop: TLoop;
    FTask: TOwnerTask;
    FMock: TMockTransport;
    FHeaders: THttpHeaders;
    FTrailers: THttpHeaders;
    FConn: TH1Conn;
    FInited: Boolean;
    FHead: TBytesView;
    FMsg: TParsedRequestHead;
    FWants: TWants;
    FErr: THyperError;
    procedure SetUp; override;
    procedure TearDown; override;
    procedure InitConn; virtual;
    function ReadHead: TPollOpt;
    function ReadBody(out Frame: TInFrame): TPollOpt;
    function ReadBodyStr(out S: RawByteString): TPollOpt;
    function Flush: TIoPoll;
    function DateStr: RawByteString;
    procedure ReleaseHead;
    procedure WriteHeadStatus(Status: Word; Kind: TBodyLengthKind; Len: QWord;
      Hdrs: THttpHeaders = nil);
  end;

  TTestConnRs = class(TConnCase)
  published
    procedure Conn_reads_request_head;
    procedure Conn_reads_partial_request_head;
    procedure Conn_accepts_eof_when_idle;
    procedure Conn_rejects_eof_during_partial_head;
    procedure Server_accepts_eof_while_busy;
    procedure Conn_reads_body_and_reports_end;
    procedure Closed_conn_cannot_read_or_write;
    procedure Conn_writes_chunked_body;
  end;

  TTestConnState = class(TConnCase)
  published
    procedure Try_keep_alive_table;
    procedure Idle_busy_disable;
    procedure Disable_keep_alive_idle_vs_busy;
    procedure Event_request_head;
    procedure Event_body_chunk_and_end;
    procedure Event_response_head;
    procedure Event_body_frames_and_end;
    procedure Event_flush_goes_idle;
    procedure Event_eof_idle_and_busy;
    procedure Event_graceful_shutdown;
    procedure Event_timer;
    procedure Can_read_write_predicates;
    procedure State_event_table;
    procedure Eof_event_table;
    procedure Flush_event_table;
  end;

  TTestConnBehavior = class(TConnCase)
  published
    procedure Expect_continue_on_first_body_read;
    procedure Expect_continue_none_after_response_head;
    procedure Expect_continue_none_for_http10;
    procedure Expect_continue_none_for_empty_body;
    procedure Expect_continue_drain_skips_100;
    procedure Drain_closes_when_body_not_buffered;
    procedure Trailers_not_allowed_without_te;
    procedure Trailers_written_grouped;
    procedure Trailers_none_keeps_body_state;
    procedure Trailers_is_last_closes;
    procedure Parse_error_writes_400;
    procedure Too_large_writes_431;
    procedure Uri_too_long_writes_414;
    procedure H2_preface_writes_nothing;
    procedure Informational_status_writes_500;
    procedure User_header_error_writes_nothing;
    procedure Response_version_panics;
    procedure End_body_not_eof_is_aborted;
    procedure Http10_keep_alive_fix;
    procedure Http11_close_when_keep_alive_disabled;
    procedure Maybe_notify_branches;
    procedure Mid_message_detect_eof;
    procedure Pipelined_head_needs_no_read;
    procedure Chunked_body_across_reads_with_trailers;
    procedure Body_decode_error;
    procedure Body_io_error;
    procedure Body_eof_is_incomplete_body;
    procedure Header_read_timeout_fires;
    procedure Header_read_timeout_cancelled_by_head;
    procedure Header_timeout_rearmed_after_idle;
    procedure Prepare_upgrade_replaces_older_slot;
    procedure Upgrade_response_closes;
    procedure Write_body_states;
    { step H }
    procedure Leading_crlf_then_eof_when_idle;
    procedure Body_end_after_response_goes_idle;
    procedure Chunked_terminator_in_own_read_is_end;
    procedure Upgrade_slot_freed_by_last_holder;
    procedure Error_head_queued_behind_body;
    procedure Continue_queued_behind_body;
  end;

  TTestH1Config = class(TConnCase)
  protected
    procedure InitConn; override;
  published
    procedure Hyper_defaults;
    procedure Production_defaults;
    procedure Validate;
    procedure Apply_order_and_effects;
    procedure Apply_default_timeout_needs_timer;
  end;

  TTestConnBodyRate = class(TConnCase)
  private
    procedure Tick(Ms: Int64);           { the loop clock moves; due timers fire }
    procedure PostHead(Len: Integer; const First: RawByteString);
  published
    procedure Off_by_default;
    procedure One_wait_fails_the_body;
    procedure A_frame_restarts_the_wait;
    procedure Time_not_reading_is_not_counted;
    procedure Rate_below_the_minimum_fails;
    procedure Rate_above_the_minimum_passes;
    procedure Body_end_cancels_the_timer;
    procedure A_new_body_starts_a_new_clock;
    procedure Rate_clock_starts_at_the_first_byte;
    procedure Silence_before_the_first_byte_hits_the_wait_limit;
    procedure Config_fields;
  end;

  TTestHyperError = class(TTestCase)
  published
    procedure Predicates;
    procedure Outcome_order;
    procedure Descriptions;
  end;

{ ---- fixture ---- }

procedure TOwnerTask.Run;
begin
  Inc(Runs);
end;

procedure TOwnerTask.Abort;
begin
end;

procedure TConnCase.SetUp;
begin
  FLoop := TLoop.Create(0);
  FTask := TOwnerTask.Create;
  FTask.Loop := FLoop;
  FMock := TMockTransport.Create;
  FHeaders := THttpHeaders.Create;
  FTrailers := THttpHeaders.Create;
  FInited := False;
  FHead := Default(TBytesView);
  FErr := Default(THyperError);
end;

procedure TConnCase.TearDown;
begin
  ReleaseHead;
  if FInited then
    FConn.Done;
  FInited := False;
  FTrailers.Free;
  FHeaders.Free;
  FMock.Free;
  FLoop.Free;                        { unlinks the task if it is still queued }
  FTask.Free;
end;

procedure TConnCase.InitConn;
begin
  FConn.Init(FMock, @FLoop.Blocks, FTask);
  FInited := True;
end;

procedure TConnCase.ReleaseHead;
begin
  if FHead.Block <> nil then
    FHead.Release;
  FHead := Default(TBytesView);
end;

function TConnCase.ReadHead: TPollOpt;
begin
  ReleaseHead;
  Result := FConn.PollReadHead(FHeaders, FMsg, FHead, FWants, FErr);
end;

function TConnCase.ReadBody(out Frame: TInFrame): TPollOpt;
begin
  Result := FConn.PollReadBody(FTrailers, Frame, FErr);
end;

function TConnCase.ReadBodyStr(out S: RawByteString): TPollOpt;
var
  F: TInFrame;
begin
  S := '';
  Result := ReadBody(F);
  if (Result = poSome) and (F.Kind = ifData) then
  begin
    SetString(S, PAnsiChar(F.Data.P), F.Data.Len);
    F.Data.Release;
  end
  else if (Result = poSome) and (F.Kind = ifTrailers) then
    S := '<trailers>';
end;

function TConnCase.Flush: TIoPoll;
var
  E: cint;
begin
  Result := FConn.PollFlush(E);
end;

function TConnCase.DateStr: RawByteString;
begin
  SetString(Result, PAnsiChar(LoopDate(FLoop)), DATE_VALUE_LENGTH);
end;

procedure TConnCase.WriteHeadStatus(Status: Word; Kind: TBodyLengthKind; Len: QWord;
  Hdrs: THttpHeaders);
var
  H: TResponseHead;
  BL: TBodyLength;
begin
  H := DefaultResponseHead;
  H.Status := Status;
  H.Headers := Hdrs;
  BL.Kind := Kind;
  BL.Len := Len;
  FConn.WriteHead(H, BL);
end;

function ViewStr(P: PByte; Len: SizeInt): RawByteString;
begin
  SetString(Result, PAnsiChar(P), Len);
end;

{ ================= conn.rs tests ================= }

procedure TTestConnRs.Conn_reads_request_head;
begin
  { conn.rs:1342-1355 }
  FMock.Read('GET / HTTP/1.1' + CRLF + CRLF);
  InitConn;
  AssertTrue('ready some', ReadHead = poSome);
  AssertTrue('GET', FMsg.Method = hmGet);
  AssertEquals('target', '/', ViewStr(FHead.P + FMsg.Target.Off, FMsg.Target.Len));
  AssertEquals('DecodedLength::ZERO', Int64(DECODED_LENGTH_ZERO), Int64(FMsg.Decode));
end;

procedure TTestConnRs.Conn_reads_partial_request_head;
begin
  { conn.rs:1357-1367: handle.read("GET / HTTP") then pending, then the rest }
  FMock.Read('GET / HTTP').ReadPending.Read('/1.1' + CRLF + 'Host: foo.bar' + CRLF + CRLF);
  InitConn;
  AssertTrue('pending', ReadHead = poPending);
  AssertTrue('ready', ReadHead = poSome);
  AssertEquals('host', 'foo.bar', FHeaders.GetValue('host'));
end;

procedure TTestConnRs.Conn_accepts_eof_when_idle;
begin
  { conn.rs:1369-1376 }
  InitConn;
  FConn.State.Idle;
  AssertTrue('Ready(None)', ReadHead = poNone);
end;

procedure TTestConnRs.Conn_rejects_eof_during_partial_head;
begin
  { conn.rs:1378-1390 }
  FMock.Read('GET / HTTP/1.1');
  InitConn;
  FConn.State.Idle;
  AssertTrue('error result', ReadHead = poErr);
  AssertTrue('incomplete message', FErr.IsIncompleteMessage);
end;

procedure TTestConnRs.Server_accepts_eof_while_busy;
begin
  { conn.rs:1405-1412 }
  InitConn;
  FConn.State.Busy;
  AssertTrue('Ready(None)', ReadHead = poNone);
end;

procedure TTestConnRs.Conn_reads_body_and_reports_end;
var
  S: RawByteString;
begin
  { conn.rs:1428-1452; .wait(1s) is the pending read after the bytes }
  FMock.Read('POST / HTTP/1.1' + CRLF + 'Content-Length: 5' + CRLF + CRLF + '12345').ReadPending;
  InitConn;
  AssertTrue('request', ReadHead = poSome);
  AssertEquals('DecodedLength::new(5)', 5, Int64(FMsg.Decode));
  AssertTrue('body frame', ReadBodyStr(S) = poSome);
  AssertEquals('data', '12345', S);
  AssertFalse('the complete body must return to head-reading state', FConn.CanReadBody);
end;

procedure TTestConnRs.Closed_conn_cannot_read_or_write;
begin
  { conn.rs:1454-1464 }
  InitConn;
  FConn.State.Close;
  AssertTrue(FConn.IsReadClosed);
  AssertTrue(FConn.IsWriteClosed);
  AssertFalse(FConn.CanReadHead);
  AssertFalse(FConn.CanWriteHead);
end;

procedure TTestConnRs.Conn_writes_chunked_body;
const
  S: RawByteString = 'headers';
begin
  { conn.rs:1466-1479 }
  FMock.Write('7' + CRLF + 'headers' + CRLF + '0' + CRLF + CRLF);
  InitConn;
  FConn.State.Writing := wrBody;
  FConn.State.WriteEncoder := TEncoder.Chunked;
  FConn.WriteBody(BodyStatic(Pointer(S), Length(S)));
  AssertTrue('end_body ok', FConn.EndBody(FErr));
  AssertTrue('flush ready', Flush = ipReady);
  FMock.AssertDone;
end;

{ ================= state tables ================= }

type
  TKATriple = record
    R: TReading;
    W: TWriting;
    K: TKA;
  end;

const
  RN: array[TReading] of string = ('Init', 'Continue', 'Body', 'KeepAlive', 'Closed');
  WN: array[TWriting] of string = ('Init', 'Body', 'KeepAlive', 'Closed');
  KN: array[TKA] of string = ('Idle', 'Busy', 'Disabled');

function TripleStr(R: TReading; W: TWriting; K: TKA): string;
begin
  Result := '(' + RN[R] + ', ' + WN[W] + ', ' + KN[K] + ')';
end;

{ conn.rs:1100-1119 State::try_keep_alive, written as a table:
  (KeepAlive, KeepAlive, Busy)         -> idle(): (Init, Init, Idle)
  (KeepAlive, KeepAlive, Idle|Disabled) -> close(): (Closed, Closed, Disabled)
  (Closed, KeepAlive, *) and (KeepAlive, Closed, *) -> close()
  everything else unchanged. idle() itself asserts !is_idle(), so the
  (KeepAlive, KeepAlive, Idle) row goes through close() without idle(). }
function ExpectedTryKeepAlive(R: TReading; W: TWriting; K: TKA): TKATriple;
begin
  Result.R := R;
  Result.W := W;
  Result.K := K;
  if (R = rdKeepAlive) and (W = wrKeepAlive) then
  begin
    if K = kaBusy then
    begin
      Result.R := rdInit;
      Result.W := wrInit;
      Result.K := kaIdle;
    end
    else
    begin
      Result.R := rdClosed;
      Result.W := wrClosed;
      Result.K := kaDisabled;
    end;
  end
  else if ((R = rdClosed) and (W = wrKeepAlive)) or ((R = rdKeepAlive) and (W = wrClosed)) then
  begin
    Result.R := rdClosed;
    Result.W := wrClosed;
    Result.K := kaDisabled;
  end;
end;

procedure TTestConnState.Try_keep_alive_table;
var
  R: TReading;
  W: TWriting;
  K: TKA;
  E: TKATriple;
  N: Integer;
begin
  InitConn;
  N := 0;
  for R := Low(TReading) to High(TReading) do
    for W := Low(TWriting) to High(TWriting) do
      for K := Low(TKA) to High(TKA) do
      begin
        FConn.State.Reading := R;
        FConn.State.Writing := W;
        FConn.State.KeepAlive := K;
        FConn.State.NotifyRead := False;
        FConn.State.TryKeepAlive;
        E := ExpectedTryKeepAlive(R, W, K);
        AssertEquals('reading after ' + TripleStr(R, W, K), RN[E.R], RN[FConn.State.Reading]);
        AssertEquals('writing after ' + TripleStr(R, W, K), WN[E.W], WN[FConn.State.Writing]);
        AssertEquals('keep_alive after ' + TripleStr(R, W, K), KN[E.K], KN[FConn.State.KeepAlive]);
        AssertFalse('no notify_read without a header timeout ' + TripleStr(R, W, K),
          FConn.State.NotifyRead);
        Inc(N);
      end;
  AssertEquals('every triple', 60, N);
  { with a header read timeout, idle() also sets notify_read (conn.rs:1154-1161) }
  FConn.State.HeaderReadTimeoutMs := 1000;
  FConn.State.Reading := rdKeepAlive;
  FConn.State.Writing := wrKeepAlive;
  FConn.State.KeepAlive := kaBusy;
  FConn.State.Method := hmPost;
  FConn.State.TryKeepAlive;
  AssertTrue('idle', FConn.State.IsIdle);
  AssertTrue('notify_read', FConn.State.NotifyRead);
  AssertTrue('method = None', FConn.State.Method = hmNone);
end;

procedure CheckTriple(T: TTestCase; const Msg: string; const E: TKATriple; const S: TConnState);
begin
  T.AssertEquals('reading: ' + Msg, RN[E.R], RN[S.Reading]);
  T.AssertEquals('writing: ' + Msg, WN[E.W], WN[S.Writing]);
  T.AssertEquals('keep_alive: ' + Msg, KN[E.K], KN[S.KeepAlive]);
end;

function Triple(R: TReading; W: TWriting; K: TKA): TKATriple;
begin
  Result.R := R;
  Result.W := W;
  Result.K := K;
end;

procedure SetTriple(var S: TConnState; R: TReading; W: TWriting; K: TKA);
begin
  S.Reading := R;
  S.Writing := W;
  S.KeepAlive := K;
  S.NotifyRead := False;
end;

procedure TTestConnState.State_event_table;
var
  R: TReading;
  W: TWriting;
  K: TKA;
  Tag: string;
begin
  { conn.rs:1077-1130 and 894-911, every triple:
    close()              -> (Closed, Closed, Disabled)
    close_read()         -> (Closed, W, Disabled)
    close_write()        -> (R, Closed, Disabled)
    busy()               -> K = Disabled stays, else Busy
    Conn::disable_keep_alive() -> Idle: close(); else K := Disabled }
  InitConn;
  for R := Low(TReading) to High(TReading) do
    for W := Low(TWriting) to High(TWriting) do
      for K := Low(TKA) to High(TKA) do
      begin
        Tag := TripleStr(R, W, K);
        SetTriple(FConn.State, R, W, K);
        FConn.State.Close;
        CheckTriple(Self, 'close ' + Tag, Triple(rdClosed, wrClosed, kaDisabled), FConn.State);
        SetTriple(FConn.State, R, W, K);
        FConn.CloseRead;
        CheckTriple(Self, 'close_read ' + Tag, Triple(rdClosed, W, kaDisabled), FConn.State);
        SetTriple(FConn.State, R, W, K);
        FConn.CloseWrite;
        CheckTriple(Self, 'close_write ' + Tag, Triple(R, wrClosed, kaDisabled), FConn.State);
        SetTriple(FConn.State, R, W, K);
        FConn.State.Busy;
        if K = kaDisabled then
          CheckTriple(Self, 'busy ' + Tag, Triple(R, W, kaDisabled), FConn.State)
        else
          CheckTriple(Self, 'busy ' + Tag, Triple(R, W, kaBusy), FConn.State);
        SetTriple(FConn.State, R, W, K);
        FConn.DisableKeepAlive;
        if K = kaIdle then
          CheckTriple(Self, 'disable_keep_alive ' + Tag, Triple(rdClosed, wrClosed, kaDisabled), FConn.State)
        else
          CheckTriple(Self, 'disable_keep_alive ' + Tag, Triple(R, W, kaDisabled), FConn.State);
      end;
end;

procedure TTestConnState.Eof_event_table;
var
  W: TWriting;
  K: TKA;
  R: TReading;
  Tag: string;
  Res: TPollResult;
begin
  { client EOF seen by poll_read_keep_alive (conn.rs:437-510), the only
    reads in the states where neither a head nor a body can be read:
    Closed -> Pending, nothing read; KeepAlive (mid-message, no half-close,
    empty buffer) -> one read, EOF: close_read, Err(IncompleteMessage) }
  for R in [rdKeepAlive, rdClosed] do
    for W := Low(TWriting) to High(TWriting) do
      for K := Low(TKA) to High(TKA) do
      begin
        Tag := TripleStr(R, W, K);
        FMock.Free;
        FMock := TMockTransport.Create;
        FMock.ReadEof;
        InitConn;
        SetTriple(FConn.State, R, W, K);
        FErr := Default(THyperError);
        Res := FConn.PollReadKeepAlive(FErr);
        if R = rdClosed then
        begin
          AssertTrue('pending ' + Tag, Res = prPending);
          AssertEquals('no read ' + Tag, 0, FMock.ReadCalls);
          CheckTriple(Self, 'unchanged ' + Tag, Triple(R, W, K), FConn.State);
        end
        else
        begin
          AssertTrue('err ' + Tag, Res = prErr);
          AssertTrue('incomplete ' + Tag, FErr.IsIncompleteMessage);
          CheckTriple(Self, 'close_read ' + Tag, Triple(rdClosed, W, kaDisabled), FConn.State);
        end;
        FConn.Done;
        FInited := False;
      end;
end;

procedure TTestConnState.Flush_event_table;
var
  R: TReading;
  W: TWriting;
  K: TKA;
  E: TKATriple;
  Tag: string;
  Eof: Boolean;
begin
  { Conn::poll_flush with nothing buffered (conn.rs:855-860): try_keep_alive
    (the table above), then maybe_notify (conn.rs:523-568), which reads only
    when Reading = Init and Writing <> Body. With a pending read nothing
    else changes and notify_read stays false; with EOF the connection
    closes if idle, else the read side closes. }
  for Eof in [False, True] do
    for R := Low(TReading) to High(TReading) do
      for W := Low(TWriting) to High(TWriting) do
        for K := Low(TKA) to High(TKA) do
        begin
          if (R = rdKeepAlive) and (W = wrKeepAlive) and (K = kaIdle) then
            Continue;               { idle() would assert: not reachable }
          Tag := TripleStr(R, W, K) + BoolToStr(Eof, ' eof', ' pending');
          FMock.Free;
          FMock := TMockTransport.Create;
          if Eof then
            FMock.ReadEof
          else
            FMock.ReadPending;
          InitConn;
          SetTriple(FConn.State, R, W, K);
          AssertTrue('ready ' + Tag, Flush = ipReady);
          E := ExpectedTryKeepAlive(R, W, K);
          if (E.R = rdInit) and (E.W <> wrBody) then
          begin
            AssertEquals('one read ' + Tag, 1, FMock.ReadCalls);
            if Eof then
            begin
              if E.K = kaIdle then
                E := Triple(rdClosed, wrClosed, kaDisabled)
              else
                E := Triple(rdClosed, E.W, kaDisabled);
            end;
          end
          else
            AssertEquals('no read ' + Tag, 0, FMock.ReadCalls);
          CheckTriple(Self, Tag, E, FConn.State);
          AssertFalse('notify_read ' + Tag, FConn.State.NotifyRead);
          FConn.Done;
          FInited := False;
        end;
end;

procedure TTestConnState.Idle_busy_disable;
begin
  InitConn;
  AssertTrue('Conn::new: KA::Busy', FConn.State.KeepAlive = kaBusy);
  FConn.State.KeepAlive := kaIdle;
  FConn.State.Busy;
  AssertTrue('busy from idle', FConn.State.KeepAlive = kaBusy);
  FConn.State.DisableKeepAlive;
  FConn.State.Busy;
  AssertTrue('busy() keeps Disabled (conn.rs:1125-1130)', FConn.State.KeepAlive = kaDisabled);
  AssertFalse('wants_keep_alive', FConn.State.WantsKeepAlive);
  FConn.State.CloseRead;
  AssertTrue(FConn.State.IsReadClosed);
  AssertFalse(FConn.State.IsWriteClosed);
  FConn.State.CloseWrite;
  AssertTrue(FConn.State.IsWriteClosed);
end;

procedure TTestConnState.Disable_keep_alive_idle_vs_busy;
begin
  { conn.rs:903-911 }
  InitConn;
  FConn.State.Idle;
  FConn.DisableKeepAlive;
  AssertTrue('idle: close()', FConn.IsReadClosed and FConn.IsWriteClosed);
  FConn.State.Reading := rdBody;
  FConn.State.Writing := wrInit;
  FConn.State.KeepAlive := kaBusy;
  FConn.DisableKeepAlive;
  AssertTrue('busy: disabled only', FConn.State.KeepAlive = kaDisabled);
  AssertTrue('busy: still reading', FConn.State.Reading = rdBody);
end;

procedure TTestConnState.Event_request_head;
begin
  { conn.rs:299-334 from (Init, Init, Busy) }
  FMock.Read('GET / HTTP/1.1' + CRLF + CRLF);
  InitConn;
  AssertTrue(ReadHead = poSome);
  AssertTrue('no body: KeepAlive', FConn.State.Reading = rdKeepAlive);
  AssertTrue('writing Init', FConn.State.Writing = wrInit);
  AssertTrue('busy', FConn.State.KeepAlive = kaBusy);
  AssertTrue('method recorded', FConn.State.Method = hmGet);
  AssertTrue('version 1.1', FConn.State.Version = hv11);
  AssertTrue('no wants', FWants = []);
  FConn.Done;

  FMock.Free;
  FMock := TMockTransport.Create;
  FMock.Read('POST / HTTP/1.1' + CRLF + 'Content-Length: 3' + CRLF + 'Connection: close' + CRLF + CRLF);
  InitConn;
  AssertTrue(ReadHead = poSome);
  AssertTrue('body', FConn.State.Reading = rdBody);
  AssertTrue('keep_alive &= false', FConn.State.KeepAlive = kaDisabled);
  ReleaseHead;
  FConn.Done;

  FMock.Free;
  FMock := TMockTransport.Create;
  FMock.Read('GET / HTTP/1.0' + CRLF + CRLF);
  InitConn;
  AssertTrue(ReadHead = poSome);
  AssertTrue('1.0 without keep-alive: disabled', FConn.State.KeepAlive = kaDisabled);
  AssertTrue('version 1.0', FConn.State.Version = hv10);
  ReleaseHead;
  FConn.Done;

  FMock.Free;
  FMock := TMockTransport.Create;
  FMock.Read('GET / HTTP/1.1' + CRLF + 'Upgrade: websocket' + CRLF + 'TE: trailers' + CRLF + CRLF);
  InitConn;
  AssertTrue(ReadHead = poSome);
  AssertTrue('Wants::UPGRADE', FWants = [wantUpgrade]);
  AssertTrue('te: trailers allows trailer fields', FConn.State.AllowTrailerFields);
end;

procedure TTestConnState.Event_body_chunk_and_end;
var
  S: RawByteString;
begin
  FMock.Read('POST / HTTP/1.1' + CRLF + 'Content-Length: 6' + CRLF + CRLF + 'abc').ReadPending.Read('def');
  InitConn;
  AssertTrue(ReadHead = poSome);
  AssertTrue('chunk', ReadBodyStr(S) = poSome);
  AssertEquals('abc', S);
  AssertTrue('still Body', FConn.State.Reading = rdBody);
  AssertTrue('pending', ReadBodyStr(S) = poPending);
  AssertTrue('last chunk', ReadBodyStr(S) = poSome);
  AssertEquals('def', S);
  AssertTrue('body end: KeepAlive', FConn.State.Reading = rdKeepAlive);
  AssertTrue('writing Init: no idle yet', FConn.State.KeepAlive = kaBusy);
end;

procedure TTestConnState.Event_response_head;
begin
  { conn.rs:602-612: Body(enc) unless eof; eof: Closed if is_last else KeepAlive }
  FMock.Read('GET / HTTP/1.1' + CRLF + CRLF);
  InitConn;
  AssertTrue(ReadHead = poSome);
  WriteHeadStatus(200, blkKnown, 5);
  AssertTrue('known length: Body', FConn.State.Writing = wrBody);
  AssertEquals('Length(5)', 5, Int64(FConn.State.WriteEncoder.Remaining));
  FConn.Done;
  FInited := False;

  FMock.Free;
  FMock := TMockTransport.Create;
  FMock.Read('GET / HTTP/1.1' + CRLF + CRLF);
  InitConn;
  AssertTrue(ReadHead = poSome);
  WriteHeadStatus(204, blkNone, 0);
  AssertTrue('no body, keep-alive: KeepAlive', FConn.State.Writing = wrKeepAlive);
  ReleaseHead;
  FConn.Done;

  FMock.Free;
  FMock := TMockTransport.Create;
  FMock.Read('GET / HTTP/1.1' + CRLF + 'Connection: close' + CRLF + CRLF);
  InitConn;
  AssertTrue(ReadHead = poSome);
  WriteHeadStatus(200, blkNone, 0);
  AssertTrue('no body, keep-alive off: is_last -> Closed', FConn.State.Writing = wrClosed);
  ReleaseHead;
  FConn.Done;

  FMock.Free;
  FMock := TMockTransport.Create;
  FMock.Read('GET / HTTP/1.1' + CRLF + CRLF);
  InitConn;
  AssertTrue(ReadHead = poSome);
  WriteHeadStatus(200, blkUnknown, 0);
  AssertTrue('unknown length: chunked Body', FConn.State.Writing = wrBody);
  AssertTrue('chunked', FConn.State.WriteEncoder.IsChunked);
end;

procedure TTestConnState.Event_body_frames_and_end;
const
  A: RawByteString = 'hello';
begin
  FMock.Read('GET / HTTP/1.1' + CRLF + CRLF);
  InitConn;
  AssertTrue(ReadHead = poSome);
  WriteHeadStatus(200, blkKnown, 10);
  FConn.WriteBody(BodyStatic(Pointer(A), 5));
  AssertTrue('5 of 10: Body', FConn.State.Writing = wrBody);
  FConn.WriteBody(BodyStatic(Pointer(A), 5));
  AssertTrue('Length(0): KeepAlive', FConn.State.Writing = wrKeepAlive);
  AssertFalse('can_write_body is False: the dispatcher calls no end_body', FConn.CanWriteBody);
end;

procedure TTestConnState.Event_flush_goes_idle;
var
  D: RawByteString;
begin
  { (KeepAlive, KeepAlive, Busy) --flush--> try_keep_alive -> idle -> (Init, Init, Idle);
    maybe_notify then reads (empty buffer, not blocked): Pending -> no notify }
  FMock.Read('GET / HTTP/1.1' + CRLF + CRLF);
  InitConn;
  AssertTrue(ReadHead = poSome);
  D := DateStr;
  FMock.Write('HTTP/1.1 200 OK' + CRLF + 'content-length: 0' + CRLF + 'date: ' + D + CRLF + CRLF)
    .ReadPending;
  WriteHeadStatus(200, blkNone, 0);
  AssertTrue('flush', Flush = ipReady);
  AssertTrue('idle', FConn.State.IsIdle);
  AssertTrue('Init', FConn.State.Reading = rdInit);
  AssertTrue('Init', FConn.State.Writing = wrInit);
  AssertFalse('read pending: no notify_read', FConn.State.NotifyRead);
  AssertTrue('can read the next head', FConn.CanReadHead);
end;

procedure TTestConnState.Event_eof_idle_and_busy;
begin
  { EOF found by maybe_notify while idle: close(); found by the head read
    while busy: Ready(None) (server_accepts_eof_while_busy) }
  FMock.Read('GET / HTTP/1.1' + CRLF + CRLF).ReadEof;
  InitConn;
  AssertTrue(ReadHead = poSome);
  FConn.State.Writing := wrKeepAlive;
  FConn.TryKeepAlive;
  AssertTrue('read eof while idle: closed', FConn.IsReadClosed and FConn.IsWriteClosed);
  AssertTrue('disabled', FConn.State.KeepAlive = kaDisabled);
end;

procedure TTestConnState.Event_graceful_shutdown;
begin
  { GracefulShutdown = disable_keep_alive (1.11): an idle connection closes,
    a busy one finishes its exchange and then closes (try_keep_alive with
    KA Disabled -> close) }
  FMock.Read('GET / HTTP/1.1' + CRLF + CRLF);
  InitConn;
  AssertTrue(ReadHead = poSome);
  FConn.DisableKeepAlive;
  AssertTrue('busy: disabled', FConn.State.KeepAlive = kaDisabled);
  WriteHeadStatus(200, blkNone, 0);
  AssertTrue('response is_last: Closed', FConn.State.Writing = wrClosed);
  FConn.TryKeepAlive;
  AssertTrue('(KeepAlive, Closed) -> close()', FConn.IsReadClosed);
end;

procedure TTestConnState.Event_timer;
begin
  { the header read timer fires while the head is pending: Err(HeaderTimeout),
    running reset; state otherwise unchanged }
  FMock.ReadPending.ReadPending;
  InitConn;
  FConn.SetHeaderReadTimeout(50);
  AssertTrue('pending', ReadHead = poPending);
  AssertTrue('running', FConn.State.HeaderReadTimeoutRunning);
  FLoop.Timers.Advance(FLoop.NowMs + 60);
  AssertTrue('fired', FConn.State.HeaderReadTimer.Fired);
  AssertTrue('timeout', ReadHead = poErr);
  AssertTrue('is_timeout', FErr.IsTimeout);
  AssertFalse('not running', FConn.State.HeaderReadTimeoutRunning);
  AssertTrue('reading Init', FConn.State.Reading = rdInit);
end;

procedure TTestConnState.Can_read_write_predicates;
var
  R: TReading;
  W: TWriting;
begin
  InitConn;
  for R := Low(TReading) to High(TReading) do
    for W := Low(TWriting) to High(TWriting) do
    begin
      FConn.State.Reading := R;
      FConn.State.Writing := W;
      AssertEquals('can_read_head ' + RN[R], R = rdInit, FConn.CanReadHead);
      AssertEquals('can_read_body ' + RN[R], (R = rdBody) or (R = rdContinue), FConn.CanReadBody);
      AssertEquals('can_write_head ' + WN[W], W = wrInit, FConn.CanWriteHead);
      AssertEquals('can_write_body ' + WN[W], W = wrBody, FConn.CanWriteBody);
      AssertEquals('is_mid_message', not ((R = rdInit) and (W = wrInit)), FConn.IsMidMessage);
      AssertEquals('has_initial_read_write_state', (R = rdInit) and (W = wrInit),
        FConn.HasInitialReadWriteState);
    end;
end;

{ ================= behaviors ================= }

procedure TTestConnBehavior.Expect_continue_on_first_body_read;
var
  S: RawByteString;
begin
  { conn.rs:313-322 and 400-412 }
  FMock.Read('POST / HTTP/1.1' + CRLF + 'Expect: 100-continue' + CRLF + 'Content-Length: 5' + CRLF + CRLF)
    .Write('HTTP/1.1 100 Continue' + CRLF + CRLF).Read('hello');
  InitConn;
  AssertTrue(ReadHead = poSome);
  AssertTrue('Continue', FConn.State.Reading = rdContinue);
  AssertTrue('Wants::EXPECT', wantExpect in FWants);
  AssertFalse('nothing buffered yet', FConn.HasBufferedWrite);
  AssertTrue('body read: pending (100 queued first)', ReadBodyStr(S) = poPending);
  AssertTrue('Body', FConn.State.Reading = rdBody);
  AssertTrue('100 buffered', FConn.HasBufferedWrite);
  AssertTrue('flush sends the 100', Flush = ipReady);
  AssertTrue('data', ReadBodyStr(S) = poSome);
  AssertEquals('hello', S);
  AssertFalse('no second 100', FConn.HasBufferedWrite);
  FMock.AssertDone;
end;

procedure TTestConnBehavior.Expect_continue_none_after_response_head;
var
  S: RawByteString;
  D: RawByteString;
begin
  { "Write the 100 Continue if not already responded" }
  FMock.Read('POST / HTTP/1.1' + CRLF + 'Expect: 100-continue' + CRLF + 'Content-Length: 2' + CRLF + CRLF + 'ok');
  InitConn;
  AssertTrue(ReadHead = poSome);
  D := DateStr;
  WriteHeadStatus(200, blkKnown, 2);
  AssertTrue('body', ReadBodyStr(S) = poSome);
  AssertEquals('ok', S);
  FMock.Write('HTTP/1.1 200 OK' + CRLF + 'content-length: 2' + CRLF + 'date: ' + D + CRLF + CRLF);
  FConn.State.Writing := wrKeepAlive;   { skip the body: only the head is checked }
  AssertTrue(Flush = ipReady);
  FMock.AssertDone;
end;

procedure TTestConnBehavior.Expect_continue_none_for_http10;
begin
  FMock.Read('POST / HTTP/1.0' + CRLF + 'Expect: 100-continue' + CRLF + 'Content-Length: 5' + CRLF + CRLF);
  InitConn;
  AssertTrue(ReadHead = poSome);
  AssertTrue('version <= 1.0: Body', FConn.State.Reading = rdBody);
  AssertFalse('no EXPECT', wantExpect in FWants);
end;

procedure TTestConnBehavior.Expect_continue_none_for_empty_body;
begin
  FMock.Read('POST / HTTP/1.1' + CRLF + 'Expect: 100-continue' + CRLF + 'Content-Length: 0' + CRLF + CRLF);
  InitConn;
  AssertTrue(ReadHead = poSome);
  AssertTrue('ignoring expect-continue since body is empty', FConn.State.Reading = rdKeepAlive);
  AssertFalse('no EXPECT', wantExpect in FWants);
end;

procedure TTestConnBehavior.Expect_continue_drain_skips_100;
begin
  { conn.rs:876-892: Continue -> Body without the 100, one read attempt;
    a tiny body that is already there drains (expect_continue_waits_for_body_poll) }
  FMock.Read('POST / HTTP/1.1' + CRLF + 'Expect: 100-continue' + CRLF + 'Content-Length: 2' + CRLF + CRLF + 'hi');
  InitConn;
  AssertTrue(ReadHead = poSome);
  FConn.PollDrainOrCloseRead;
  AssertFalse('no 100 buffered', FConn.HasBufferedWrite);
  AssertTrue('body drained', FConn.State.Reading = rdKeepAlive);
end;

procedure TTestConnBehavior.Drain_closes_when_body_not_buffered;
begin
  FMock.Read('POST / HTTP/1.1' + CRLF + 'Content-Length: 10' + CRLF + CRLF + 'abc').ReadPending;
  InitConn;
  AssertTrue(ReadHead = poSome);
  FConn.PollDrainOrCloseRead;
  AssertTrue('still Body after one read: close_read', FConn.State.Reading = rdClosed);
  AssertTrue('keep-alive off', FConn.State.KeepAlive = kaDisabled);
end;

procedure TTestConnBehavior.Trailers_not_allowed_without_te;
var
  H, T: THttpHeaders;
begin
  { conn.rs:757-760: no TE: trailers -> nothing written, still Body }
  FMock.Read('GET / HTTP/1.1' + CRLF + CRLF);
  InitConn;
  AssertTrue(ReadHead = poSome);
  H := THttpHeaders.Create;
  T := THttpHeaders.Create;
  try
    H.Add('trailer', 'x-t');
    WriteHeadStatus(200, blkUnknown, 0, H);
    T.Add('x-t', '1');
    FConn.WriteTrailers(T);
    AssertTrue('still Body', FConn.State.Writing = wrBody);
  finally
    T.Free;
    H.Free;
  end;
end;

procedure TTestConnBehavior.Trailers_written_grouped;
const
  Data: RawByteString = 'abc';
var
  H, T: THttpHeaders;
  D: RawByteString;
begin
  { allowed + declared: "0\r\n" + fields grouped by name (T1) + "\r\n", KeepAlive }
  FMock.Read('GET / HTTP/1.1' + CRLF + 'TE: trailers' + CRLF + CRLF);
  InitConn;
  AssertTrue(ReadHead = poSome);
  H := THttpHeaders.Create;
  T := THttpHeaders.Create;
  try
    H.Add('trailer', 'a, b');
    D := DateStr;
    WriteHeadStatus(200, blkUnknown, 0, H);
    FConn.WriteBody(BodyStatic(Pointer(Data), 3));
    T.Add('a', '1');
    T.Add('b', '2');
    T.Add('a', '3');
    T.Add('c', 'undeclared');
    FConn.WriteTrailers(T);
    AssertTrue('KeepAlive', FConn.State.Writing = wrKeepAlive);
    FMock.Write('HTTP/1.1 200 OK' + CRLF + 'trailer: a, b' + CRLF + 'transfer-encoding: chunked' + CRLF +
      'date: ' + D + CRLF + CRLF + '3' + CRLF + 'abc' + CRLF + '0' + CRLF + 'a: 1' + CRLF + 'a: 3' + CRLF +
      'b: 2' + CRLF + CRLF);
    AssertTrue(Flush = ipReady);
    FMock.AssertDone;
  finally
    T.Free;
    H.Free;
  end;
end;

procedure TTestConnBehavior.Trailers_none_keeps_body_state;
var
  H, T: THttpHeaders;
begin
  { allowed but nothing declared (Chunked(None)): encode_trailers -> None,
    the state stays Body, end_body then writes 0\r\n\r\n (5.2 T3) }
  FMock.Read('GET / HTTP/1.1' + CRLF + 'TE: trailers' + CRLF + CRLF);
  InitConn;
  AssertTrue(ReadHead = poSome);
  H := THttpHeaders.Create;
  T := THttpHeaders.Create;
  try
    WriteHeadStatus(200, blkUnknown, 0, H);
    T.Add('a', '1');
    FConn.WriteTrailers(T);
    AssertTrue('still Body', FConn.State.Writing = wrBody);
    AssertTrue(FConn.EndBody(FErr));
    AssertTrue('end_body: KeepAlive', FConn.State.Writing = wrKeepAlive);
  finally
    T.Free;
    H.Free;
  end;
end;

procedure TTestConnBehavior.Trailers_is_last_closes;
var
  H, T: THttpHeaders;
begin
  { allowed + declared + keep-alive off (is_last): Closed }
  FMock.Read('GET / HTTP/1.1' + CRLF + 'TE: trailers' + CRLF + 'Connection: close' + CRLF + CRLF);
  InitConn;
  AssertTrue(ReadHead = poSome);
  H := THttpHeaders.Create;
  T := THttpHeaders.Create;
  try
    H.Add('trailer', 'a');
    WriteHeadStatus(200, blkUnknown, 0, H);
    T.Add('a', '1');
    FConn.WriteTrailers(T);
    AssertTrue('Closed', FConn.State.Writing = wrClosed);
  finally
    T.Free;
    H.Free;
  end;
end;

procedure TTestConnBehavior.Parse_error_writes_400;
var
  E: cint;
  D: RawByteString;
begin
  { 2.8: close_read, 400 head (connection: close, content-length: 0, date),
    error stored, Pending; then the shutdown; take_error gives the parse error }
  FMock.Read('GET / HTTP/1.1' + CRLF + 'Bad Header' + CRLF + CRLF);
  InitConn;
  FConn.SetHeaderReadTimeout(-1);
  D := DateStr;
  FMock.Write('HTTP/1.1 400 Bad Request' + CRLF + 'connection: close' + CRLF + 'content-length: 0' + CRLF +
    'date: ' + D + CRLF + CRLF);
  AssertTrue('XXX: wat? Pending', ReadHead = poPending);
  AssertTrue('read closed', FConn.IsReadClosed);
  AssertTrue('write closed (is_last)', FConn.IsWriteClosed);
  AssertTrue('shutdown flushes first', FConn.PollShutdown(E) = ipReady);
  AssertEquals('shutdown(SHUT_WR)', 1, FMock.ShutdownCalls);
  AssertTrue('take_error', FConn.TakeError(FErr));
  AssertTrue('parse', FErr.IsParse);
  AssertTrue('outcome parse', OutcomeOf(prErr, FErr) = coParse);
  AssertFalse('taken', FConn.TakeError(FErr));
  FMock.AssertDone;
end;

procedure TTestConnBehavior.Too_large_writes_431;
var
  D: RawByteString;
begin
  FMock.Read('GET / HTTP/1.1' + CRLF + 'Host: x' + CRLF);
  InitConn;
  FConn.SetMaxHeaderSize(10);
  D := DateStr;
  FMock.Write('HTTP/1.1 431 Request Header Fields Too Large' + CRLF + 'connection: close' + CRLF +
    'content-length: 0' + CRLF + 'date: ' + D + CRLF + CRLF);
  AssertTrue(ReadHead = poPending);
  AssertTrue(Flush = ipReady);
  AssertTrue(FConn.TakeError(FErr));
  AssertTrue('outcome parse_too_large', OutcomeOf(prErr, FErr) = coParseTooLarge);
  FMock.AssertDone;
end;

procedure TTestConnBehavior.Uri_too_long_writes_414;
var
  D, U: RawByteString;
begin
  U := '/' + StringOfChar('a', 65535);
  FMock.Read('GET ' + U + ' HTTP/1.1' + CRLF + CRLF);
  InitConn;
  D := DateStr;
  FMock.Write('HTTP/1.1 414 URI Too Long' + CRLF + 'connection: close' + CRLF +
    'content-length: 0' + CRLF + 'date: ' + D + CRLF + CRLF);
  AssertTrue(ReadHead = poPending);
  AssertTrue(Flush = ipReady);
  AssertTrue(FConn.TakeError(FErr));
  AssertTrue('outcome parse_too_large', OutcomeOf(prErr, FErr) = coParseTooLarge);
  FMock.AssertDone;
end;

procedure TTestConnBehavior.H2_preface_writes_nothing;
begin
  FMock.Read('PRI * HTTP/2.0' + CRLF + CRLF + 'SM' + CRLF + CRLF);
  InitConn;
  AssertTrue('error', ReadHead = poErr);
  AssertTrue('version h2', FErr.IsParseVersionH2);
  AssertTrue('outcome', OutcomeOf(prErr, FErr) = coParseVersionH2);
  AssertFalse('nothing written', FConn.HasBufferedWrite);
end;

procedure TTestConnBehavior.Informational_status_writes_500;
var
  D: RawByteString;
begin
  FMock.Read('GET / HTTP/1.1' + CRLF + CRLF);
  InitConn;
  AssertTrue(ReadHead = poSome);
  D := DateStr;
  WriteHeadStatus(102, blkNone, 0);
  AssertTrue('Closed', FConn.State.Writing = wrClosed);
  AssertTrue(FConn.TakeError(FErr));
  AssertTrue('user', FErr.IsUser);
  AssertTrue('outcome user', OutcomeOf(prErr, FErr) = coUser);
  FMock.Write('HTTP/1.1 500 Internal Server Error' + CRLF + 'content-length: 0' + CRLF +
    'date: ' + D + CRLF + CRLF);
  AssertTrue(Flush = ipReady);
  FMock.AssertDone;
end;

procedure TTestConnBehavior.User_header_error_writes_nothing;
var
  H: THttpHeaders;
begin
  { role.rs: an invalid content-length from the service: new_user_header,
    nothing written, Closed }
  FMock.Read('GET / HTTP/1.1' + CRLF + CRLF);
  InitConn;
  AssertTrue(ReadHead = poSome);
  H := THttpHeaders.Create;
  try
    H.AddTrusted('content-length', 'abc');
    { Some(BodyLength::Unknown) with an invalid user content-length (role.rs) }
    WriteHeadStatus(200, blkUnknown, 0, H);
    AssertTrue('Closed', FConn.State.Writing = wrClosed);
    AssertFalse('nothing written', FConn.HasBufferedWrite);
    AssertTrue(FConn.TakeError(FErr));
    AssertTrue('user header', FErr.IsUser and (FErr.User = hukHeader));
  finally
    H.Free;
  end;
end;

procedure TTestConnBehavior.Response_version_panics;
var
  H: TResponseHead;
  BL: TBodyLength;
  Raised: Boolean;
  V: THttpVersion;
begin
  FMock.Read('GET / HTTP/1.1' + CRLF + CRLF);
  InitConn;
  AssertTrue(ReadHead = poSome);
  for V in [hv09, hv3] do
  begin
    H := DefaultResponseHead;
    H.Version := V;
    BL.Kind := blkNone;
    BL.Len := 0;
    Raised := False;
    try
      FConn.WriteHead(H, BL);
    except
      on E: EH1Panic do
        Raised := True;
    end;
    AssertTrue('EH1Panic', Raised);
    AssertFalse('nothing written', FConn.HasBufferedWrite);
    AssertTrue('state unchanged', FConn.State.Writing = wrInit);
  end;
  { a 1xx (not 101) becomes a 500 HTTP/1.1 head first: no panic }
  H := DefaultResponseHead;
  H.Version := hv09;
  H.Status := 103;
  FConn.WriteHead(H, BL);
  AssertTrue('500 written', FConn.HasBufferedWrite);
end;

procedure TTestConnBehavior.End_body_not_eof_is_aborted;
const
  A: RawByteString = 'abc';
begin
  FMock.Read('GET / HTTP/1.1' + CRLF + CRLF);
  InitConn;
  AssertTrue(ReadHead = poSome);
  WriteHeadStatus(200, blkKnown, 10);
  FConn.WriteBody(BodyStatic(Pointer(A), 3));
  AssertFalse('Err(not_eof)', FConn.EndBody(FErr));
  AssertTrue('Closed', FConn.State.Writing = wrClosed);
  AssertTrue('body write aborted', FErr.IsBodyWriteAborted);
  AssertEquals('7 more bytes', 7, Int64(FErr.NotEofRemaining));
  AssertTrue('outcome user (is_user before is_body_write_aborted)', OutcomeOf(prErr, FErr) = coUser);
end;

procedure TTestConnBehavior.Http10_keep_alive_fix;
var
  D: RawByteString;
  H: TResponseHead;
  BL: TBodyLength;
  {$IFOPT C+}
  N0: QWord;
  {$ENDIF}
begin
  { conn.rs:671-698: an HTTP/1.0 client with keep-alive gets
    "connection: keep-alive" and an HTTP/1.0 status line }
  FMock.Read('GET / HTTP/1.0' + CRLF + 'Connection: keep-alive' + CRLF + CRLF);
  InitConn;
  AssertTrue(ReadHead = poSome);
  AssertTrue('keep-alive kept', FConn.State.WantsKeepAlive);
  D := DateStr;
  FMock.Write('HTTP/1.0 200 OK' + CRLF + 'connection: keep-alive' + CRLF + 'content-length: 0' + CRLF +
    'date: ' + D + CRLF + CRLF);
  {$IFOPT C+}
  N0 := ValidatingMutatorCalls;
  {$ENDIF}
  WriteHeadStatus(200, blkNone, 0);
  {$IFOPT C+}
  { decision 13 (Library_callers_use_trusted_paths, conn callers):
    FixKeepAlive adds its constant with AddTrusted }
  AssertEquals('no validating mutator call', N0, ValidatingMutatorCalls);
  {$ENDIF}
  AssertTrue('KeepAlive', FConn.State.Writing = wrKeepAlive);
  AssertTrue(Flush = ipReady);
  FMock.AssertDone;
  ReleaseHead;
  FConn.Done;

  { without keep-alive: no header, closed after the response }
  FMock.Free;
  FMock := TMockTransport.Create;
  FMock.Read('GET / HTTP/1.0' + CRLF + CRLF);
  InitConn;
  AssertTrue(ReadHead = poSome);
  FMock.Write('HTTP/1.0 200 OK' + CRLF + 'content-length: 0' + CRLF + 'date: ' + D + CRLF + CRLF);
  WriteHeadStatus(200, blkNone, 0);
  AssertTrue('Closed', FConn.State.Writing = wrClosed);
  AssertTrue(Flush = ipReady);
  FMock.AssertDone;
  ReleaseHead;
  FConn.Done;

  { a 1.0 client with keep-alive and an HTTP/1.0 response head without
    keep-alive: Version::HTTP_10 => disable_keep_alive, is_last -> Closed }
  FMock.Free;
  FMock := TMockTransport.Create;
  FMock.Read('GET / HTTP/1.0' + CRLF + 'Connection: keep-alive' + CRLF + CRLF);
  InitConn;
  AssertTrue(ReadHead = poSome);
  FMock.Write('HTTP/1.0 200 OK' + CRLF + 'content-length: 0' + CRLF + 'date: ' + D + CRLF + CRLF);
  H := DefaultResponseHead;
  H.Version := hv10;
  BL.Kind := blkNone;
  BL.Len := 0;
  FConn.WriteHead(H, BL);
  AssertTrue('keep-alive disabled', FConn.State.KeepAlive = kaDisabled);
  AssertTrue('Closed', FConn.State.Writing = wrClosed);
  AssertTrue(Flush = ipReady);
  FMock.AssertDone;
end;

procedure TTestConnBehavior.Http11_close_when_keep_alive_disabled;
var
  H: THttpHeaders;
  D: RawByteString;
  {$IFOPT C+}
  N0: QWord;
  {$ENDIF}
begin
  { conn.rs:713-724: an existing Connection header without close gets
    "close" appended (grouped on the wire) }
  FMock.Read('GET / HTTP/1.1' + CRLF + 'Connection: close' + CRLF + CRLF);
  InitConn;
  AssertTrue(ReadHead = poSome);
  H := THttpHeaders.Create;
  try
    H.Add('connection', 'upgrade');
    H.Add('x-a', 'b');
    D := DateStr;
    FMock.Write('HTTP/1.1 200 OK' + CRLF + 'connection: upgrade, close' + CRLF +
      'x-a: b' + CRLF + 'content-length: 0' + CRLF + 'date: ' + D + CRLF + CRLF);
    {$IFOPT C+}
    N0 := ValidatingMutatorCalls;
    {$ENDIF}
    WriteHeadStatus(200, blkNone, 0, H);
    {$IFOPT C+}
    { decision 13: EnforceVersion adds "close" with AddTrusted }
    AssertEquals('no validating mutator call', N0, ValidatingMutatorCalls);
    {$ENDIF}
    AssertTrue(Flush = ipReady);
    FMock.AssertDone;
    ReleaseHead;
    FConn.Done;

    { a close value already present: nothing appended }
    FMock.Free;
    FMock := TMockTransport.Create;
    FMock.Read('GET / HTTP/1.1' + CRLF + 'Connection: close' + CRLF + CRLF);
    InitConn;
    AssertTrue(ReadHead = poSome);
    H.Clear;
    H.Add('connection', 'Close');
    FMock.Write('HTTP/1.1 200 OK' + CRLF + 'connection: Close' + CRLF + 'content-length: 0' + CRLF +
      'date: ' + D + CRLF + CRLF);
    WriteHeadStatus(200, blkNone, 0, H);
    AssertEquals('one connection entry', 1, H.CountOf('connection'));
    AssertTrue(Flush = ipReady);
    FMock.AssertDone;
  finally
    H.Free;
  end;
end;

procedure TTestConnBehavior.Maybe_notify_branches;
begin
  { conn.rs:523-568 }
  { 1. Pending: return without notify_read }
  FMock.ReadPending;
  InitConn;
  FConn.State.Reading := rdKeepAlive;
  FConn.State.Writing := wrKeepAlive;
  FConn.TryKeepAlive;
  AssertTrue('idle', FConn.State.IsIdle);
  AssertFalse('pending: no notify', FConn.State.NotifyRead);
  AssertTrue('read blocked', FConn.Io.IsReadBlocked);
  { 2. blocked: no read, no notify }
  FConn.MaybeNotify;
  AssertEquals('no second read while blocked', 1, FMock.ReadCalls);
  FConn.Done;

  { 3. EOF while not idle: close_read }
  FMock.Free;
  FMock := TMockTransport.Create;
  FMock.ReadEof;
  InitConn;
  FConn.State.Reading := rdInit;
  FConn.State.Writing := wrKeepAlive;
  FConn.State.KeepAlive := kaBusy;
  FConn.MaybeNotify;
  AssertTrue('close_read', FConn.IsReadClosed);
  AssertFalse('write not closed', FConn.IsWriteClosed);
  AssertFalse('no notify', FConn.State.NotifyRead);
  FConn.Done;

  { 4. error: close(), error stored, notify_read }
  FMock.Free;
  FMock := TMockTransport.Create;
  FMock.ReadError(104);
  InitConn;
  FConn.State.Idle;
  FConn.MaybeNotify;
  AssertTrue('closed', FConn.IsReadClosed and FConn.IsWriteClosed);
  AssertTrue('notify_read', FConn.State.NotifyRead);
  AssertTrue('error stored', FConn.TakeError(FErr));
  AssertTrue('io', FErr.Kind = hekIo);
  AssertEquals('errno', 104, FErr.Errno);
  FConn.Done;

  { 5. data: notify_read; 6. bytes already buffered: notify without a read }
  FMock.Free;
  FMock := TMockTransport.Create;
  FMock.Read('GET / HTTP/1.1' + CRLF + CRLF);
  InitConn;
  FConn.State.Idle;
  FConn.MaybeNotify;
  AssertTrue('data: notify', FConn.WantsReadAgain);
  AssertFalse('wants_read_again clears it', FConn.WantsReadAgain);
  FConn.MaybeNotify;
  AssertEquals('no read with buffered bytes', 1, FMock.ReadCalls);
  AssertTrue('notify', FConn.WantsReadAgain);
  { 7. not Init or writing Body: nothing }
  FConn.State.Reading := rdBody;
  FConn.MaybeNotify;
  AssertFalse(FConn.State.NotifyRead);
  FConn.State.Reading := rdInit;
  FConn.State.Writing := wrBody;
  FConn.MaybeNotify;
  AssertFalse(FConn.State.NotifyRead);
end;

procedure TTestConnBehavior.Mid_message_detect_eof;
begin
  { conn.rs:493-510 }
  FMock.Read('GET / HTTP/1.1' + CRLF + CRLF).ReadEof;
  InitConn;
  AssertTrue(ReadHead = poSome);
  AssertTrue('mid message', FConn.IsMidMessage);
  FConn.State.AllowHalfClose := True;
  AssertTrue('half close: Pending', FConn.PollReadKeepAlive(FErr) = prPending);
  AssertEquals('no read', 1, FMock.ReadCalls);
  FConn.State.AllowHalfClose := False;
  AssertTrue('EOF: Err', FConn.PollReadKeepAlive(FErr) = prErr);
  AssertTrue('incomplete', FErr.IsIncompleteMessage);
  AssertTrue('close_read', FConn.IsReadClosed);
  AssertTrue('read closed: Pending', FConn.PollReadKeepAlive(FErr) = prPending);
  ReleaseHead;
  FConn.Done;

  FMock.Free;
  FMock := TMockTransport.Create;
  FMock.Read('GET / HTTP/1.1' + CRLF + CRLF).ReadPending.Read('GET /2 HTTP/1.1' + CRLF + CRLF).ReadError(32);
  InitConn;
  AssertTrue(ReadHead = poSome);
  AssertTrue('pending', FConn.MidMessageDetectEof(FErr) = prPending);
  AssertTrue('data: Ok', FConn.MidMessageDetectEof(FErr) = prOk);
  AssertTrue('buffered bytes: Pending', FConn.MidMessageDetectEof(FErr) = prPending);
  FConn.Io.ReadBuf.Advance(FConn.Io.ReadBuf.Len);
  AssertTrue('io error', FConn.MidMessageDetectEof(FErr) = prErr);
  AssertTrue('new_io', FErr.Kind = hekIo);
  AssertTrue('force_io_read error: close()', FConn.IsReadClosed and FConn.IsWriteClosed);
end;

procedure TTestConnBehavior.Pipelined_head_needs_no_read;
var
  D: RawByteString;
begin
  FMock.Read('GET /1 HTTP/1.1' + CRLF + CRLF + 'GET /2 HTTP/1.1' + CRLF + CRLF);
  InitConn;
  AssertTrue(ReadHead = poSome);
  D := DateStr;
  FMock.Write('HTTP/1.1 200 OK' + CRLF + 'content-length: 0' + CRLF + 'date: ' + D + CRLF + CRLF);
  WriteHeadStatus(200, blkNone, 0);
  AssertTrue(Flush = ipReady);
  AssertTrue('idle', FConn.State.IsIdle);
  AssertTrue('buffered bytes: notify_read', FConn.WantsReadAgain);
  AssertEquals('one read so far', 1, FMock.ReadCalls);
  AssertTrue('second head', ReadHead = poSome);
  AssertEquals('/2', ViewStr(FHead.P + FMsg.Target.Off, FMsg.Target.Len));
  AssertEquals('no read for the second head', 1, FMock.ReadCalls);
  FMock.AssertDone;
end;

procedure TTestConnBehavior.Chunked_body_across_reads_with_trailers;
var
  S: RawByteString;
begin
  FMock.Read('POST / HTTP/1.1' + CRLF + 'Transfer-Encoding: chunked' + CRLF + CRLF + '5' + CRLF + 'hel')
    .ReadPending.Read('lo' + CRLF + '0' + CRLF + 'x-t: 1' + CRLF + CRLF);
  InitConn;
  AssertTrue(ReadHead = poSome);
  AssertTrue('hel', ReadBodyStr(S) = poSome);
  AssertEquals('hel', S);
  AssertTrue('pending', ReadBodyStr(S) = poPending);
  AssertTrue('lo', ReadBodyStr(S) = poSome);
  AssertEquals('lo', S);
  AssertTrue('trailers', ReadBodyStr(S) = poSome);
  AssertEquals('<trailers>', S);
  AssertEquals('x-t', '1', FTrailers.GetValue('x-t'));
  AssertTrue('KeepAlive', FConn.State.Reading = rdKeepAlive);
end;

procedure TTestConnBehavior.Body_decode_error;
var
  S: RawByteString;
begin
  FMock.Read('POST / HTTP/1.1' + CRLF + 'Transfer-Encoding: chunked' + CRLF + CRLF + 'zz' + CRLF);
  InitConn;
  AssertTrue(ReadHead = poSome);
  AssertTrue('error', ReadBodyStr(S) = poErr);
  AssertTrue('Closed', FConn.State.Reading = rdClosed);
  AssertTrue('body kind', FErr.Kind = hekBody);
  AssertTrue('decode cause', FErr.Cause = ecDecode);
  AssertTrue('missing size digit (read_start)', FErr.Decode = deMissingSizeDigit);
  AssertTrue('io source', FErr.HasIoSource);
end;

procedure TTestConnBehavior.Body_io_error;
var
  S: RawByteString;
begin
  FMock.Read('POST / HTTP/1.1' + CRLF + 'Content-Length: 5' + CRLF + CRLF).ReadError(104);
  InitConn;
  AssertTrue(ReadHead = poSome);
  AssertTrue('error', ReadBodyStr(S) = poErr);
  AssertTrue('Closed', FConn.State.Reading = rdClosed);
  AssertTrue('body io', (FErr.Kind = hekBody) and (FErr.Cause = ecErrno) and (FErr.Errno = 104));
end;

procedure TTestConnBehavior.Body_eof_is_incomplete_body;
var
  S: RawByteString;
begin
  FMock.Read('POST / HTTP/1.1' + CRLF + 'Content-Length: 5' + CRLF + CRLF + 'ab').ReadEof;
  InitConn;
  AssertTrue(ReadHead = poSome);
  AssertTrue('ab', ReadBodyStr(S) = poSome);
  AssertTrue('eof', ReadBodyStr(S) = poErr);
  AssertTrue('IncompleteBody', FErr.Decode = deIncompleteBody);
  AssertEquals('end of file before message length reached', DecodeErrorMessage(FErr.Decode));
end;

procedure TTestConnBehavior.Header_read_timeout_fires;
begin
  FMock.Read('GET / HT').ReadPending.ReadPending;
  InitConn;
  FConn.SetHeaderReadTimeout(100);
  AssertTrue('pending', ReadHead = poPending);
  AssertTrue('armed', FConn.State.HeaderReadTimer.Deadline > 0);
  FLoop.Timers.Advance(FLoop.NowMs + 50);
  AssertFalse('not yet', FConn.State.HeaderReadTimer.Fired);
  AssertFalse('owner not woken', FTask.Queued);
  FLoop.Timers.Advance(FLoop.NowMs + 101);
  AssertTrue('fired', FConn.State.HeaderReadTimer.Fired);
  AssertTrue('owner woken by the timer Proc', FTask.Queued);
  AssertTrue('Err(HeaderTimeout)', ReadHead = poErr);
  AssertTrue('outcome timeout', OutcomeOf(prErr, FErr) = coTimeout);
  AssertFalse('nothing written', FConn.HasBufferedWrite);
end;

procedure TTestConnBehavior.Header_read_timeout_cancelled_by_head;
begin
  FMock.Read('GET / HTTP/1.1' + CRLF + CRLF);
  InitConn;
  FConn.SetHeaderReadTimeout(100);
  AssertTrue(ReadHead = poSome);
  AssertFalse('not running', FConn.State.HeaderReadTimeoutRunning);
  AssertEquals('lazy cancel', 0, FConn.State.HeaderReadTimer.Deadline);
  FLoop.Timers.Advance(FLoop.NowMs + 500);
  AssertFalse('did not fire', FConn.State.HeaderReadTimer.Fired);
  AssertFalse('owner not woken', FTask.Queued);
end;

procedure TTestConnBehavior.Header_timeout_rearmed_after_idle;
var
  D: RawByteString;
begin
  { State::idle sets notify_read when a timeout is configured, so the
    dispatcher re-enters poll_read_head and arms the timer again: the header
    timeout is also the keep-alive idle timeout (2.3) }
  FMock.Read('GET / HTTP/1.1' + CRLF + CRLF);
  InitConn;
  FConn.SetHeaderReadTimeout(100);
  AssertTrue(ReadHead = poSome);
  D := DateStr;
  FMock.Write('HTTP/1.1 200 OK' + CRLF + 'content-length: 0' + CRLF + 'date: ' + D + CRLF + CRLF)
    .ReadPending.ReadPending;
  WriteHeadStatus(200, blkNone, 0);
  AssertTrue(Flush = ipReady);
  AssertTrue('notify_read', FConn.WantsReadAgain);
  AssertTrue('pending', ReadHead = poPending);
  AssertTrue('running again', FConn.State.HeaderReadTimeoutRunning);
  AssertTrue('armed', FConn.State.HeaderReadTimer.Deadline > 0);
end;

type
  TRecUpgrade = class(TUpgradeHandler)
  public
    Failed: string;
    procedure Upgraded(U: TUpgraded); override;
    procedure UpgradeFailed(const Msg: string); override;
  end;

procedure TRecUpgrade.Upgraded(U: TUpgraded);
begin
end;

procedure TRecUpgrade.UpgradeFailed(const Msg: string);
begin
  Failed := Msg;
end;

procedure TTestConnBehavior.Prepare_upgrade_replaces_older_slot;
var
  Ex: TExchange;
  H1, H2: TRecUpgrade;
  S1: TUpgradeSlot;
begin
  InitConn;
  H2 := nil;
  Ex := TExchange.Create;
  H1 := TRecUpgrade.Create;
  try
    Ex.BeginRequest(FTask);
    FConn.State.PrepareUpgrade(Ex);
    S1 := FConn.State.Upgrade.Slot;
    AssertTrue('linked', Ex.UpgradeSlot = S1);
    AssertTrue('pending', S1.State = usPending);
    Ex.OnUpgrade(H1);
    { the next upgrade request replaces it: the older one is canceled }
    Ex.BeginRequest(FTask);
    FConn.State.PrepareUpgrade(Ex);
    AssertEquals('older canceled', 'upgrade expected but not completed', H1.Failed);
    AssertTrue('new slot', Ex.UpgradeSlot = FConn.State.Upgrade.Slot);
    H2 := TRecUpgrade.Create;
    Ex.OnUpgrade(H2);
    AssertEquals('the new handler is not failed', '', H2.Failed);
    { drop(Conn) with a pending slot: "upgrade expected but not completed" }
    FConn.Done;
    FInited := False;
    AssertEquals('drop(Pending) on Done', 'upgrade expected but not completed', H2.Failed);
  finally
    Ex.Free;
    H1.Free;
    H2.Free;
  end;
end;

procedure TTestConnBehavior.Upgrade_response_closes;
begin
  { a 101 is is_last: Closed; the read side closes with try_keep_alive
    (KeepAlive, Closed) -> close() }
  FMock.Read('GET / HTTP/1.1' + CRLF + 'Upgrade: x' + CRLF + 'Connection: upgrade' + CRLF + CRLF);
  InitConn;
  AssertTrue(ReadHead = poSome);
  AssertTrue(wantUpgrade in FWants);
  WriteHeadStatus(101, blkNone, 0);
  AssertTrue('Closed', FConn.State.Writing = wrClosed);
  FConn.TryKeepAlive;
  AssertTrue('read closed', FConn.IsReadClosed);
end;

procedure TTestConnBehavior.Write_body_states;
const
  A: RawByteString = 'abcdef';
var
  D: RawByteString;
begin
  { write_body_and_end: Length exact -> KeepAlive; chunked -> data + end in one entry }
  FMock.Read('GET / HTTP/1.1' + CRLF + CRLF);
  InitConn;
  AssertTrue(ReadHead = poSome);
  D := DateStr;
  WriteHeadStatus(200, blkKnown, 6);
  FConn.WriteBodyAndEnd(BodyStatic(Pointer(A), 6));
  AssertTrue('KeepAlive', FConn.State.Writing = wrKeepAlive);
  FMock.Write('HTTP/1.1 200 OK' + CRLF + 'content-length: 6' + CRLF + 'date: ' + D + CRLF + CRLF + 'abcdef')
    .ReadPending;
  AssertTrue(Flush = ipReady);
  AssertTrue('idle after flush', FConn.State.IsIdle);
  FMock.AssertDone;
end;


{ ================= step H ================= }

const
  HELLO: RawByteString = 'hello';
  HEAD_200_5 = 'HTTP/1.1 200 OK' + CRLF + 'content-length: 5' + CRLF + CRLF;

procedure TTestConnBehavior.Leading_crlf_then_eof_when_idle;
begin
  { decision 13 (S4 survivor 1): conn.rs:339-363 on_read_head_error consumes
    leading empty lines first, so CRLFs then EOF while idle is a graceful
    close (Ready(None)), not Err(Incomplete) }
  FMock.Read(CRLF + CRLF + CRLF);
  InitConn;
  FConn.State.Idle;
  AssertTrue('Ready(None), not Err(Incomplete)', ReadHead = poNone);
  AssertTrue('read closed', FConn.IsReadClosed);
  AssertTrue('write closed', FConn.IsWriteClosed);
end;

procedure TTestConnBehavior.Body_end_after_response_goes_idle;
var
  S: RawByteString;
begin
  { decision 13 (S4 survivor 2): conn.rs:426-428, poll_read_body ends with
    try_keep_alive: when the response already reached KeepAlive, the end of
    the request body makes the connection idle at once }
  { the last ReadPending: maybe_notify's read after going idle (an EOF there
    would close the connection) }
  FMock.Read('POST / HTTP/1.1' + CRLF + 'Content-Length: 3' + CRLF + CRLF).ReadPending.Read('abc')
    .ReadPending;
  InitConn;
  FConn.DisableDateHeader;
  AssertTrue(ReadHead = poSome);
  WriteHeadStatus(204, blkNone, 0);
  AssertTrue('response done: KeepAlive', FConn.State.Writing = wrKeepAlive);
  AssertTrue('pending', ReadBodyStr(S) = poPending);
  AssertTrue('body', ReadBodyStr(S) = poSome);
  AssertEquals('abc', S);
  AssertTrue('idle: reading Init', FConn.State.Reading = rdInit);
  AssertTrue('idle: writing Init', FConn.State.Writing = wrInit);
  AssertTrue('idle', FConn.State.IsIdle);
end;

procedure TTestConnBehavior.Chunked_terminator_in_own_read_is_end;
var
  S: RawByteString;
begin
  { decision 13 (S4 survivor 3): the last-chunk arrives in its own read; the
    decoder returns an empty eof frame, which conn.rs:381-386 turns into
    Ready(None), not an empty data frame }
  FMock.Read('POST / HTTP/1.1' + CRLF + 'Transfer-Encoding: chunked' + CRLF + CRLF +
    '3' + CRLF + 'abc' + CRLF).ReadPending.Read('0' + CRLF + CRLF);
  InitConn;
  AssertTrue(ReadHead = poSome);
  AssertTrue('data', ReadBodyStr(S) = poSome);
  AssertEquals('abc', S);
  AssertTrue('pending', ReadBodyStr(S) = poPending);
  AssertTrue('terminator alone: Ready(None)', ReadBodyStr(S) = poNone);
  AssertEquals('no data', '', S);
  AssertTrue('body done: KeepAlive', FConn.State.Reading = rdKeepAlive);
end;

procedure TTestConnBehavior.Upgrade_slot_freed_by_last_holder;
var
  Ex: TExchange;
  L0: LongInt;
  S: TUpgradeSlot;
begin
  { decision 9: one reference per holder (the connection's Pending, the
    exchange's OnUpgrade); the last Release frees the slot. Conn.Done
    first, then the exchange (S4 verifier probe: the exchange used to keep
    a freed slot) }
  InitConn;
  L0 := UpgradeSlotsLive;
  Ex := TExchange.Create;
  try
    Ex.BeginRequest(FTask);
    FConn.State.PrepareUpgrade(Ex);
    S := Ex.UpgradeSlot;
    AssertEquals('one slot alive', L0 + 1, UpgradeSlotsLive);
    AssertEquals('two holders', 2, S.RefCount);
    FConn.Done;
    FInited := False;
    AssertEquals('the exchange still holds it', L0 + 1, UpgradeSlotsLive);
    AssertEquals('one holder left', 1, Ex.UpgradeSlot.RefCount);
    AssertTrue('canceled by drop(Pending)', Ex.UpgradeSlot.State = usCanceled);
    Ex.Recycle;                      { ReleaseRequest reads the slot: alive }
    AssertTrue('the exchange let go', Ex.UpgradeSlot = nil);
    AssertEquals('freed by the last holder', L0, UpgradeSlotsLive);
    { the other order: the exchange first, then the connection }
    InitConn;
    Ex.BeginRequest(FTask);
    FConn.State.PrepareUpgrade(Ex);
    Ex.Recycle;
    AssertEquals('the connection still holds it', L0 + 1, UpgradeSlotsLive);
    AssertEquals(1, FConn.State.Upgrade.Slot.RefCount);
    FConn.Done;
    FInited := False;
    AssertEquals('freed', L0, UpgradeSlotsLive);
    { a newer upgrade request replaces the slot: the older one is freed once
      both holders moved on }
    InitConn;
    Ex.BeginRequest(FTask);
    FConn.State.PrepareUpgrade(Ex);
    Ex.BeginRequest(FTask);
    FConn.State.PrepareUpgrade(Ex);
    AssertEquals('only the newer slot', L0 + 1, UpgradeSlotsLive);
  finally
    Ex.Free;
  end;
  if FInited then
  begin
    FConn.Done;
    FInited := False;
  end;
  AssertEquals('nothing left', L0, UpgradeSlotsLive);
end;

procedure TTestConnBehavior.Error_head_queued_behind_body;
const
  HEAD_200_BIG = 'HTTP/1.1 200 OK' + #13#10 + 'content-length: 5000' + #13#10#13#10;
var
  S, Big: RawByteString;
begin
  { a large response body (queued, not copied) waits behind a blocked
    write; the request body ends after it (try_keep_alive -> idle) and the
    next head is a parse error. The 400 head goes behind the queued body
    (TH1Io.BufferAfterQueue): written into the cursor it would land between
    the 200 head and its body. }
  Big := StringOfChar('h', 5000);
  FMock.Vectored(True)
    .Read('POST / HTTP/1.1' + CRLF + 'Content-Length: 5' + CRLF + CRLF)
    .Write(HEAD_200_BIG).WritePending
    .Read('abcde' + 'GET / HTTP/1.1' + CRLF + 'Bad Header' + CRLF + CRLF)
    .Write(Big + 'HTTP/1.1 400 Bad Request' + CRLF + 'connection: close' + CRLF +
      'content-length: 0' + CRLF + CRLF);
  InitConn;
  FConn.DisableDateHeader;
  AssertTrue(ReadHead = poSome);
  WriteHeadStatus(200, blkKnown, 5000);
  FConn.WriteBodyAndEnd(BodyStatic(Pointer(Big), 5000));
  AssertTrue('flush blocked after the head', Flush = ipPending);
  AssertEquals('body queued', 1, FConn.Io.WriteBuf.Queue.Count);
  AssertTrue('body', ReadBodyStr(S) = poSome);
  AssertEquals('abcde', S);
  AssertTrue('idle with the body still queued', FConn.State.IsIdle);
  AssertFalse('no head can be buffered', FConn.CanWriteHead);
  AssertTrue('parse error: the 400 is written, Pending', ReadHead = poPending);
  AssertEquals('the 400 head is queued behind the body', 2, FConn.Io.WriteBuf.Queue.Count);
  AssertTrue('flush', Flush = ipReady);
  AssertEquals('wire: the 400 after the body', HEAD_200_BIG + Big +
    'HTTP/1.1 400 Bad Request' + CRLF + 'connection: close' + CRLF + 'content-length: 0' + CRLF + CRLF,
    FMock.Written);
  AssertTrue('error stored', FConn.State.HasError);
  FMock.AssertDone;
end;

procedure TTestConnBehavior.Continue_queued_behind_body;
const
  HEAD_200_BIG = 'HTTP/1.1 200 OK' + #13#10 + 'content-length: 5000' + #13#10#13#10;
var
  S, Big: RawByteString;
  F: TInFrame;
begin
  { the automatic 100 Continue in the same situation as
    Error_head_queued_behind_body, with an expect-continue request next:
    the 100 goes behind the queued body (deviation H-3: not reachable
    through the dispatcher) }
  Big := StringOfChar('h', 5000);
  FMock.Vectored(True)
    .Read('POST / HTTP/1.1' + CRLF + 'Content-Length: 5' + CRLF + CRLF)
    .Write(HEAD_200_BIG).WritePending
    .Read('abcde' + 'POST /2 HTTP/1.1' + CRLF + 'Expect: 100-continue' + CRLF +
      'Content-Length: 3' + CRLF + CRLF)
    .ReadPending
    .Write(Big + 'HTTP/1.1 100 Continue' + CRLF + CRLF);
  InitConn;
  FConn.DisableDateHeader;
  AssertTrue(ReadHead = poSome);
  WriteHeadStatus(200, blkKnown, 5000);
  FConn.WriteBodyAndEnd(BodyStatic(Pointer(Big), 5000));
  AssertTrue(Flush = ipPending);
  AssertTrue(ReadBodyStr(S) = poSome);
  AssertTrue('idle', FConn.State.IsIdle);
  AssertTrue('second request', ReadHead = poSome);
  AssertTrue('Continue', FConn.State.Reading = rdContinue);
  AssertTrue('the body read sends the 100 (then waits for data)', ReadBody(F) = poPending);
  AssertEquals('the 100 is queued behind the body', 2, FConn.Io.WriteBuf.Queue.Count);
  AssertTrue('flush', Flush = ipReady);
  AssertEquals('wire: the 100 after the queued body', HEAD_200_BIG + Big +
    'HTTP/1.1 100 Continue' + CRLF + CRLF, FMock.Written);
  FMock.AssertDone;
end;

{ ================= config ================= }

procedure TTestH1Config.InitConn;
begin
  inherited InitConn;
end;

procedure TTestH1Config.Hyper_defaults;
var
  C: TH1Config;
begin
  C := ConformanceH1Config;
  AssertTrue(C.KeepAlive);
  AssertFalse(C.HalfClose);
  AssertFalse(C.TitleCaseHeaders);
  AssertEquals(-1, C.MaxHeaders);
  AssertEquals(-1, Int64(C.MaxHeaderSize));
  AssertEquals(-1, Int64(C.MaxBufSize));
  AssertFalse(C.Timer);
  AssertTrue(C.HeaderReadTimeout = tsDefault);
  AssertEquals(30000, C.HeaderReadTimeoutMs);
  AssertFalse(C.PipelineFlush);
  AssertTrue(C.AutoDateHeader);
  AssertTrue(C.Mode = cmPlain);
end;

procedure TTestH1Config.Production_defaults;
var
  C: TH1Config;
begin
  C := ProductionH1Config;
  AssertTrue(C.Timer);
  AssertTrue(C.HeaderReadTimeout = tsDefault);
  AssertTrue(C.PipelineFlush);
  AssertTrue(C.Mode = cmWithUpgrades);
  AssertTrue(C.KeepAlive);
end;

procedure TTestH1Config.Validate;
var
  C: TH1Config;
  M: string;
begin
  C := ConformanceH1Config;
  AssertTrue('defaults valid', ValidateH1Config(C, M));
  C.MaxBufSize := 8191;
  AssertFalse('MaxBufSize < 8192', ValidateH1Config(C, M));
  AssertEquals('TH1Config.MaxBufSize (8191) is below the minimum (8192)', M);
  C.MaxBufSize := 8192;
  AssertTrue(ValidateH1Config(C, M));
  C.HeaderReadTimeout := tsMs;
  C.HeaderReadTimeoutMs := 100;
  AssertFalse('configured timeout without timer', ValidateH1Config(C, M));
  AssertEquals('TH1Config.HeaderReadTimeout is tsMs, which needs TH1Config.Timer, and Timer is False', M);
  C.Timer := True;
  AssertTrue(ValidateH1Config(C, M));
  C.Timer := False;
  C.HeaderReadTimeout := tsDisabled;
  AssertTrue('null without timer is fine', ValidateH1Config(C, M));
end;

procedure TTestH1Config.Apply_order_and_effects;
var
  C: TH1Config;
begin
  FMock.Vectored(True);
  InitConn;
  C := ConformanceH1Config;
  C.KeepAlive := False;
  C.HalfClose := True;
  C.TitleCaseHeaders := True;
  C.MaxHeaders := 7;
  C.MaxHeaderSize := 900;
  C.Timer := True;
  C.HeaderReadTimeout := tsMs;
  C.HeaderReadTimeoutMs := 1234;
  C.PipelineFlush := True;
  C.MaxBufSize := 9000;
  C.AutoDateHeader := False;
  C.Parser.AllowMultipleSpacesInRequestLineDelimiters := True;
  ApplyH1Config(C, FConn);
  AssertTrue('keep_alive(false): disabled', FConn.State.KeepAlive = kaDisabled);
  AssertTrue(FConn.State.AllowHalfClose);
  AssertTrue(FConn.State.TitleCaseHeaders);
  AssertEquals(7, FConn.State.ParseCtx.MaxHeaders);
  AssertEquals(900, Int64(FConn.State.ParseCtx.MaxHeaderSize));
  AssertEquals(1234, FConn.State.HeaderReadTimeoutMs);
  AssertTrue(FConn.Io.FlushPipeline);
  AssertEquals(9000, Int64(FConn.Io.ReadBufStrategy.Max));
  AssertEquals(9000, Int64(FConn.Io.WriteBuf.MaxBufSize));
  AssertFalse(FConn.State.DateHeader);
  AssertTrue(FConn.State.ParseCtx.ParserConfig.AllowMultipleSpacesInRequestLineDelimiters);
end;

procedure TTestH1Config.Apply_default_timeout_needs_timer;
var
  C: TH1Config;
begin
  InitConn;
  C := ConformanceH1Config;
  ApplyH1Config(C, FConn);
  AssertEquals('default without timer: None', -1, FConn.State.HeaderReadTimeoutMs);
  FConn.Done;
  InitConn;
  C.Timer := True;
  ApplyH1Config(C, FConn);
  AssertEquals('default with timer: 30 s', 30000, FConn.State.HeaderReadTimeoutMs);
  FConn.Done;
  InitConn;
  C.HeaderReadTimeout := tsDisabled;
  ApplyH1Config(C, FConn);
  AssertEquals('null: None', -1, FConn.State.HeaderReadTimeoutMs);
end;

{ ================= bearings.http.error ================= }

procedure TTestHyperError.Predicates;
var
  E: THyperError;
begin
  E := NewParse(h1peUriTooLong);
  AssertTrue(E.IsParse and E.IsParseTooLarge and not E.IsParseVersionH2);
  E := NewTooLarge;
  AssertTrue(E.IsParseTooLarge);
  E := NewVersionH2;
  AssertTrue(E.IsParse and E.IsParseVersionH2 and not E.IsParseTooLarge);
  E := NewIncomplete;
  AssertTrue(E.IsIncompleteMessage and not E.HasIoSource);
  E := NewHeaderTimeout;
  AssertTrue(E.IsTimeout);
  E := NewIo(110);
  AssertFalse('ETIMEDOUT is not is_timeout()', E.IsTimeout);
  AssertTrue(E.HasIoSource);
  E := NewBodyDecode(deInvalidSize);
  AssertTrue('decode errors are io::Error', E.HasIoSource);
  E := NewBodyStatic('connection error');
  AssertFalse(E.HasIoSource);
  E := NewBodyWriteAborted(3);
  AssertTrue('User::BodyWriteAborted is_user', E.IsUser and E.IsBodyWriteAborted);
  E := NewShutdown(32);
  AssertTrue(E.IsShutdown and E.HasIoSource);
  E := NewClosed;
  AssertTrue(E.IsClosed);
  E := NewUserService;
  AssertTrue(E.IsUser and not E.HasIoSource);
  E := NewUserManualUpgrade;
  AssertTrue(E.IsUser);
end;

procedure TTestHyperError.Outcome_order;
var
  E: THyperError;
begin
  E := Default(THyperError);
  AssertTrue(OutcomeOf(prOk, E) = coOk);
  AssertTrue(OutcomeOf(prErr, NewHeaderTimeout) = coTimeout);
  AssertTrue(OutcomeOf(prErr, NewTooLarge) = coParseTooLarge);
  AssertTrue(OutcomeOf(prErr, NewParse(h1peUriTooLong)) = coParseTooLarge);
  AssertTrue(OutcomeOf(prErr, NewVersionH2) = coParseVersionH2);
  AssertTrue(OutcomeOf(prErr, NewParse(h1peHeaderToken)) = coParse);
  AssertTrue(OutcomeOf(prErr, NewIncomplete) = coIncomplete);
  AssertTrue(OutcomeOf(prErr, NewUserService) = coUser);
  AssertTrue(OutcomeOf(prErr, NewUserBody) = coUser);
  AssertTrue(OutcomeOf(prErr, NewBodyWriteAborted(1)) = coUser);
  AssertTrue(OutcomeOf(prErr, NewClosed) = coClosed);
  AssertTrue(OutcomeOf(prErr, NewShutdown(32)) = coShutdown);
  AssertTrue(OutcomeOf(prErr, NewIo(104)) = coIo);
  AssertTrue(OutcomeOf(prErr, NewBodyIo(104)) = coIo);
  AssertTrue(OutcomeOf(prErr, NewBodyStatic('connection error')) = coOther);
  E := Default(THyperError);
  E.Kind := hekCanceled;
  AssertTrue(OutcomeOf(prErr, E) = coCanceled);
end;

procedure TTestHyperError.Descriptions;
begin
  AssertEquals('connection closed before message completed', ErrorDescription(NewIncomplete, ''));
  AssertEquals('message head is too large', ErrorDescription(NewTooLarge, ''));
  AssertEquals('invalid HTTP version parsed (found HTTP2 preface)', ErrorDescription(NewVersionH2, ''));
  AssertEquals('read header from client timeout', ErrorDescription(NewHeaderTimeout, ''));
  AssertEquals('error reading a body from connection: Invalid chunk size line: Invalid Size',
    ErrorDescription(NewBodyDecode(deInvalidSize), ''));
  AssertEquals('error reading a body from connection: connection error',
    ErrorDescription(NewBodyStatic('connection error'), ''));
  AssertEquals('error from user''s Service: boom', ErrorDescription(NewUserService, 'boom'));
  AssertEquals('user body write aborted: early end, expected 7 more bytes',
    ErrorDescription(NewBodyWriteAborted(7), ''));
  AssertEquals('response has 1xx status code, not supported by server',
    ErrorDescription(NewUserUnsupportedStatusCode, ''));
  AssertEquals('user sent unexpected header', ErrorDescription(NewUserHeader, ''));
  AssertEquals('channel closed', ErrorDescription(NewClosed, ''));
  AssertTrue('io: os error text', Pos('(os error 104)', ErrorDescription(NewIo(104), '')) > 0);
  AssertEquals('connection error: ', Copy(ErrorDescription(NewIo(104), ''), 1, 18));
end;

{ ---- TTestConnBodyRate (step UB) ---- }

procedure TTestConnBodyRate.Tick(Ms: Int64);
begin
  FLoop.NowMs := FLoop.NowMs + Ms;
  FLoop.Timers.Advance(FLoop.NowMs);
end;

procedure TTestConnBodyRate.PostHead(Len: Integer; const First: RawByteString);
begin
  FMock.Read('POST / HTTP/1.1' + CRLF + 'Content-Length: ' + IntToStr(Len) + CRLF + CRLF + First);
end;

procedure TTestConnBodyRate.Off_by_default;
var S: RawByteString;
begin
  PostHead(5, 'ab');
  FMock.ReadPending.ReadPending;
  InitConn;
  AssertEquals('off', 0, FConn.State.BodyTimeoutMs);
  AssertTrue(ReadHead = poSome);
  AssertTrue('ab', ReadBodyStr(S) = poSome);
  AssertTrue('pending', ReadBodyStr(S) = poPending);
  AssertEquals('no timer', 0, FConn.State.BodyTimer.Deadline);
  Tick(3600000);
  AssertTrue('still pending after an hour', ReadBodyStr(S) = poPending);
  AssertTrue('Body', FConn.State.Reading = rdBody);
end;

procedure TTestConnBodyRate.One_wait_fails_the_body;
var
  S: RawByteString;
  E2: THyperError;
begin
  PostHead(5, 'ab');
  FMock.ReadPending.ReadPending.ReadPending;
  InitConn;
  FConn.SetBodyReadTimeout(1000, 0);
  AssertTrue(ReadHead = poSome);
  AssertTrue('ab', ReadBodyStr(S) = poSome);
  AssertTrue('pending', ReadBodyStr(S) = poPending);
  AssertEquals('armed at the wait limit', FLoop.NowMs + 1000, FConn.State.BodyTimer.Deadline);
  Tick(999);
  AssertFalse('not yet', FConn.State.BodyTimer.Fired);
  AssertTrue('pending at 999 ms', ReadBodyStr(S) = poPending);
  AssertFalse('owner not woken', FTask.Queued);
  Tick(1);
  AssertTrue('fired', FConn.State.BodyTimer.Fired);
  AssertTrue('owner woken by the timer', FTask.Queued);
  AssertTrue('the body fails', ReadBodyStr(S) = poErr);
  AssertTrue('body io ETIMEDOUT', (FErr.Kind = hekBody) and (FErr.Cause = ecErrno)
    and (FErr.Errno = ESysETIMEDOUT));
  AssertTrue('reading closed', FConn.State.Reading = rdClosed);
  AssertTrue('outcome io (not a header timeout)', OutcomeOf(prErr, FErr) = coIo);
  AssertTrue('kept for TakeError', FConn.TakeError(E2) and (E2.Errno = ESysETIMEDOUT));
  AssertFalse('nothing written', FConn.HasBufferedWrite);
end;

procedure TTestConnBodyRate.A_frame_restarts_the_wait;
var S: RawByteString;
begin
  PostHead(6, 'ab');
  FMock.ReadPending.Read('cd').ReadPending.ReadPending;
  InitConn;
  FConn.SetBodyReadTimeout(1000, 0);
  AssertTrue(ReadHead = poSome);
  AssertTrue('ab', ReadBodyStr(S) = poSome);
  AssertTrue('pending', ReadBodyStr(S) = poPending);
  Tick(900);
  AssertTrue('cd', ReadBodyStr(S) = poSome);
  AssertEquals('cd', S);
  AssertFalse('the wait ended', FConn.State.BodyWaiting);
  AssertEquals('lazy cancel', 0, FConn.State.BodyTimer.Deadline);
  AssertEquals('waited', 900, FConn.State.BodyWaitedMs);
  AssertTrue('pending again', ReadBodyStr(S) = poPending);
  AssertEquals('a new wait of 1000 ms', FLoop.NowMs + 1000, FConn.State.BodyTimer.Deadline);
  Tick(900);
  AssertTrue('1800 ms of waiting, no wait of 1000 ms: still pending', ReadBodyStr(S) = poPending);
end;

procedure TTestConnBodyRate.Time_not_reading_is_not_counted;
var S: RawByteString;
begin
  PostHead(6, 'ab');
  FMock.Read('cd').ReadPending;
  InitConn;
  FConn.SetBodyReadTimeout(1000, 1000);
  AssertTrue(ReadHead = poSome);
  AssertTrue('ab', ReadBodyStr(S) = poSome);
  { the receiver does not take the next chunk for 10 s: no body read }
  Tick(10000);
  AssertTrue('cd', ReadBodyStr(S) = poSome);
  AssertEquals('nothing waited', 0, FConn.State.BodyWaitedMs);
  AssertTrue('pending', ReadBodyStr(S) = poPending);
  AssertEquals('a full wait', FLoop.NowMs + 1000, FConn.State.BodyTimer.Deadline);
end;

procedure TTestConnBodyRate.Rate_below_the_minimum_fails;
var S: RawByteString;
begin
  { 1000 ms wait limit, 1000 bytes/s: after 900 ms of waiting for 100
    bytes, the next wait may last only 100 ms (1000 ms in all) }
  PostHead(1000, StringOfChar('x', 100));
  FMock.ReadPending.Read(StringOfChar('y', 100)).ReadPending.ReadPending;
  InitConn;
  FConn.SetBodyReadTimeout(1000, 1000);
  AssertTrue(ReadHead = poSome);
  AssertTrue('100', ReadBodyStr(S) = poSome);
  AssertTrue('pending', ReadBodyStr(S) = poPending);
  Tick(900);
  AssertTrue('100 more', ReadBodyStr(S) = poSome);
  AssertTrue('pending', ReadBodyStr(S) = poPending);
  AssertEquals('900 + 100 ms of waiting', FLoop.NowMs + 100, FConn.State.BodyTimer.Deadline);
  Tick(100);
  AssertTrue('fired', FConn.State.BodyTimer.Fired);
  AssertTrue('the body fails: 200 bytes in 1 s of waiting', ReadBodyStr(S) = poErr);
  AssertTrue('ETIMEDOUT', FErr.Errno = ESysETIMEDOUT);
end;

procedure TTestConnBodyRate.Rate_above_the_minimum_passes;
var S: RawByteString;
begin
  { 2000 bytes after 900 ms of waiting allow 2000 ms of waiting in all:
    the next wait ends at the wait limit (1000 ms), not before }
  PostHead(5000, StringOfChar('x', 1000));
  FMock.ReadPending.Read(StringOfChar('y', 1000)).ReadPending.ReadPending;
  InitConn;
  FConn.SetBodyReadTimeout(1000, 1000);
  AssertTrue(ReadHead = poSome);
  AssertTrue('1000', ReadBodyStr(S) = poSome);
  AssertTrue('pending', ReadBodyStr(S) = poPending);
  Tick(900);
  AssertTrue('1000 more', ReadBodyStr(S) = poSome);
  AssertTrue('pending', ReadBodyStr(S) = poPending);
  AssertEquals('the wait limit comes first', FLoop.NowMs + 1000, FConn.State.BodyTimer.Deadline);
  Tick(999);
  AssertTrue('still pending', ReadBodyStr(S) = poPending);
end;

procedure TTestConnBodyRate.Body_end_cancels_the_timer;
var S: RawByteString;
begin
  PostHead(4, 'ab');
  FMock.ReadPending.Read('cd');
  InitConn;
  FConn.SetBodyReadTimeout(1000, 1024);
  AssertTrue(ReadHead = poSome);
  AssertTrue('ab', ReadBodyStr(S) = poSome);
  AssertTrue('pending', ReadBodyStr(S) = poPending);
  Tick(500);
  AssertTrue('cd, the end', ReadBodyStr(S) = poSome);
  AssertTrue('KeepAlive', FConn.State.Reading = rdKeepAlive);
  AssertFalse('no wait', FConn.State.BodyWaiting);
  Tick(5000);
  AssertFalse('the timer did not fire', FConn.State.BodyTimer.Fired);
  AssertFalse('owner not woken', FTask.Queued);
end;

procedure TTestConnBodyRate.A_new_body_starts_a_new_clock;
var S, D: RawByteString;
begin
  PostHead(4, 'ab');
  FMock.ReadPending.Read('cd');
  InitConn;
  FConn.SetBodyReadTimeout(1000, 1000);
  AssertTrue(ReadHead = poSome);
  AssertTrue('ab', ReadBodyStr(S) = poSome);
  AssertTrue('pending', ReadBodyStr(S) = poPending);
  Tick(900);
  AssertTrue('cd, the end', ReadBodyStr(S) = poSome);
  AssertEquals('the first body waited', 900, FConn.State.BodyWaitedMs);
  D := DateStr;
  FMock.Write('HTTP/1.1 200 OK' + CRLF + 'content-length: 0' + CRLF + 'date: ' + D + CRLF + CRLF);
  PostHead(4, 'ef');
  FMock.ReadPending;
  WriteHeadStatus(200, blkNone, 0);
  AssertTrue(Flush = ipReady);
  AssertTrue('the second head', ReadHead = poSome);
  AssertEquals('a new clock', 0, FConn.State.BodyWaitedMs);
  AssertEquals('no bytes yet', 0, FConn.State.BodyReceived);
  AssertTrue('ef', ReadBodyStr(S) = poSome);
  AssertTrue('pending', ReadBodyStr(S) = poPending);
  AssertEquals('a full wait, not what the first body left', FLoop.NowMs + 1000,
    FConn.State.BodyTimer.Deadline);
end;

procedure TTestConnBodyRate.Rate_clock_starts_at_the_first_byte;
var S: RawByteString; I: Integer;
begin
  { 900 ms of silence, then 1.1 x the minimum: the rate part counts from
    the first byte, so the body is not failed (counting the silence it
    would be after the first 100 ms wait: 210 bytes in 1 000 ms) }
  PostHead(100000, '');
  FMock.ReadPending.Read(StringOfChar('x', 100));
  for I := 1 to 5 do
    FMock.ReadPending.Read(StringOfChar('y', 110));
  FMock.ReadPending;
  InitConn;
  FConn.SetBodyReadTimeout(1000, 1000);
  AssertTrue(ReadHead = poSome);
  AssertTrue('pending', ReadBodyStr(S) = poPending);
  Tick(900);
  AssertTrue('the first bytes', ReadBodyStr(S) = poSome);
  AssertEquals('the silence is not in the rate', 0, FConn.State.BodyWaitedMs);
  for I := 1 to 5 do
  begin
    AssertTrue('pending ' + IntToStr(I), ReadBodyStr(S) = poPending);
    Tick(100);
    AssertTrue('110 bytes ' + IntToStr(I), ReadBodyStr(S) = poSome);
  end;
  AssertTrue('still reading', ReadBodyStr(S) = poPending);
  AssertTrue('Body', FConn.State.Reading = rdBody);
end;

procedure TTestConnBodyRate.Silence_before_the_first_byte_hits_the_wait_limit;
var S: RawByteString;
begin
  PostHead(100, '');
  FMock.ReadPending.ReadPending;
  InitConn;
  FConn.SetBodyReadTimeout(1000, 1000);
  AssertTrue(ReadHead = poSome);
  AssertTrue('pending', ReadBodyStr(S) = poPending);
  AssertEquals('the wait limit', FLoop.NowMs + 1000, FConn.State.BodyTimer.Deadline);
  Tick(1000);
  AssertTrue('no byte for the wait limit: fails', ReadBodyStr(S) = poErr);
  AssertTrue('ETIMEDOUT', FErr.Errno = ESysETIMEDOUT);
end;

procedure TTestConnBodyRate.Config_fields;
var C: TH1Config; M: string;
begin
  C := ConformanceH1Config;
  AssertEquals('hyper: off', 0, C.BodyReadTimeoutMs);
  AssertEquals('hyper: no rate', 0, C.BodyMinRate);
  C := ProductionH1Config;
  AssertEquals('production: 30 s', 30000, C.BodyReadTimeoutMs);
  AssertEquals('production: 1 KiB/s', 1024, C.BodyMinRate);
  AssertTrue('production valid', ValidateH1Config(C, M));
  C.Timer := False;
  AssertFalse('needs the timer', ValidateH1Config(C, M));
  C := ProductionH1Config;
  C.BodyReadTimeoutMs := 0;
  AssertFalse('a rate needs the wait limit', ValidateH1Config(C, M));
  C := ProductionH1Config;
  C.BodyMinRate := -1;
  AssertFalse('negative', ValidateH1Config(C, M));
  C := ProductionH1Config;
  InitConn;
  ApplyH1Config(C, FConn);
  AssertEquals('applied', 30000, FConn.State.BodyTimeoutMs);
  AssertEquals('applied rate', 1024, FConn.State.BodyMinRate);
  C.Timer := False;
  C.BodyReadTimeoutMs := 5;
  FConn.SetBodyReadTimeout(0, 0);
  ApplyH1Config(C, FConn);
  AssertEquals('not without the timer', 0, FConn.State.BodyTimeoutMs);
end;

begin
  RegisterTest(TTestConnRs);
  RegisterTest(TTestConnState);
  RegisterTest(TTestConnBehavior);
  RegisterTest(TTestH1Config);
  RegisterTest(TTestHyperError);
  RegisterTest(TTestConnBodyRate);
  with TTestRunner.Create(nil) do
  try
    Initialize;
    Run;
  finally
    Free;
  end;
end.

{ test_split_fuzz - the in-process split fuzz of M3 step S9 (design
  m3-transport.md 7.5).

  Each input is the byte stream a client writes on one connection: the
  conformance cases (tests/unit/test_split_fuzz_cases.py: every case of
  conformance/cases/h1 and pascal-server/extra/extra-cases.json without an
  upgrade reply, one input per named connection, with the case's server
  spec) and the M2 parser corpus (tests/unit/test_parser_corpus.py, served
  with the spec {}). The connection is served in-process by the real
  TH1Dispatcher and the conformance server's own handlers
  (beconf.service.TConfService, inline executor; its events are collected
  through beconf.events.EventHook) over a TScriptIo transport
  (tests/support/bearings.test.scriptio: it records what is written and scripts
  only the transport's answers; TMockTransport asserts the exact bytes of
  every write, which a fuzzer does not know in advance).

  A reference run delivers the input in one read and accepts every write.
  A split run (seeded) delivers it in random pieces (1 byte to 4 KiB) with
  a random EAGAIN (a readiness edge follows) before about half of them, a
  random vectored or non-vectored transport, and the first 1-40 writes
  limited to 1-64 bytes or answered with EAGAIN. In both runs the driver
  acts as the loop (a queued task runs in a loop iteration, a blocked
  transport with more script gets its readiness edge) until the connection
  is done or has nothing to do; then the client's EOF follows and the
  connection is driven to its end.

  Compared, split against reference: every byte written, the event lines
  (request, request_body, request_body_error, handler_done,
  handler_dropped) and the connection's end (conn_close outcome and detail,
  or 'not done'). Invariants of every run: no exception reaches the driver,
  no task aborted by an exception (TLoop.Aborts), no wake-source assertion
  failure (built with -dWD_DEBUG), the loop's block pool holds every block
  it allocated once the connection is gone (no block pinned or lost), no
  exchange left alive; heaptrc (-gh) reports no leak at exit
  (tests/unit/run_all.sh checks the log).

  Each input runs in two profiles: the case's own spec config, and
  ProductionH1Config (timer, 30 s header read timeout, pipeline_flush,
  with_upgrades). auto_date_header is off in both (the date would differ
  between runs).

  Env: FUZZ_SEEDS (default 2000): seeds; each seed runs every case input in
  both profiles and FUZZ_CORPUS_PER_SEED (default 20) corpus entries drawn
  by the seed; FUZZ_CORPUS_ALL=1 (default 1) also runs every corpus entry
  once (seed = its index); FUZZ_DATA: the directory with cases.bin and
  corpus.bin (default build/m3/S9/fuzz); FUZZ_SEED0 (default 1).
  A difference is reported with its input name, profile and seed, and the
  input and both outputs are written to $FUZZ_DATA/fail-<n>.txt. }
program test_split_fuzz;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Classes, SysUtils, StrUtils, fpcunit, testregistry, consoletestrunner, ctypes, bearings.rt.sys, bearings.rt.buf,
  bearings.rt.loop, bearings.rt.net, bearings.http.error, bearings.http.exchange, bearings.http1.config, bearings.http1.dispatch,
  bearings.test.scriptio, beconf.spec, beconf.events, beconf.service;

type
  TInput = record
    Name, Spec, Data: RawByteString;
  end;

  TRunResult = record
    Written: RawByteString;
    Events: RawByteString;
    Ending: RawByteString;
    Trace: RawByteString;            { the transport's log (traced runs only) }
  end;

  TFuzzObserver = class(TConnObserver)
  public
    Ending: RawByteString;
    procedure OnConnClose(ConnId: QWord; Data: Pointer; Outcome: TConnOutcome;
      const Detail: string); override;
    procedure OnParts(ConnId: QWord; Data: Pointer; var Parts: TConnParts); override;
  end;

  TFreeFlagDispatcher = class(TH1Dispatcher)
  public
    Freed: PBoolean;
    destructor Destroy; override;
  end;

  TNopTask = class(TLoopTask)
  public
    procedure Run; override;
    procedure Abort; override;
  end;

  TSplitFuzz = class(TTestCase)
  published
    procedure Cases_and_corpus_samples;
    procedure Corpus_every_entry_once;
  end;

var
  Events: RawByteString;
  Cases, Corpus: array of TInput;
  DataDir: string;
  Runs, Fails, LateErrors, H2Splits: Int64;
  SplitPieces, SplitPendings: Int64;

procedure CollectEvent(const Line: RawByteString);
begin
  { bytes_read is not emitted (no TCountingTransport); conn_open is the observer's }
  Events := Events + Line + #10;
end;

procedure TFuzzObserver.OnConnClose(ConnId: QWord; Data: Pointer; Outcome: TConnOutcome;
  const Detail: string);
var
  S: string;
begin
  WriteStr(S, Outcome);
  Ending := Ending + 'conn_close ' + S + ' ' + Detail + #10;
end;

procedure TFuzzObserver.OnParts(ConnId: QWord; Data: Pointer; var Parts: TConnParts);
begin
  Ending := Ending + 'parts ' + IntToStr(Parts.Rest.Len) + #10;
  if Parts.Rest.Block <> nil then
    Parts.Rest.Release;
  Parts.Rest := Default(TBytesView);
  { the test owns the transport object (OwnsTransport False) }
end;

destructor TFreeFlagDispatcher.Destroy;
begin
  if Freed <> nil then
    Freed^ := True;
  inherited Destroy;
end;

procedure TNopTask.Run;
begin
end;

procedure TNopTask.Abort;
begin
end;

{ ---- inputs ---- }

function ReadU32(S: TStream; out V: LongWord): Boolean;
begin
  Result := S.Read(V, 4) = 4;
  V := LEtoN(V);
end;

function ReadField(S: TStream; out B: RawByteString): Boolean;
var
  N: LongWord;
begin
  B := '';
  if not ReadU32(S, N) then
    Exit(False);
  SetLength(B, N);
  if N > 0 then
    S.ReadBuffer(B[1], N);
  Result := True;
end;

procedure LoadCases(const Path: string);
var
  F: TFileStream;
  I: TInput;
  N: Integer;
begin
  F := TFileStream.Create(Path, fmOpenRead);
  try
    N := 0;
    while ReadField(F, I.Name) do
    begin
      ReadField(F, I.Spec);
      ReadField(F, I.Data);
      SetLength(Cases, N + 1);
      Cases[N] := I;
      Inc(N);
    end;
  finally
    F.Free;
  end;
end;

procedure LoadCorpus(const Path: string);
var
  F: TFileStream;
  B: RawByteString;
  N: Integer;
begin
  F := TFileStream.Create(Path, fmOpenRead);
  try
    N := 0;
    SetLength(Corpus, 4096);
    while ReadField(F, B) do
    begin
      if N = Length(Corpus) then
        SetLength(Corpus, 2 * N);
      Corpus[N].Name := 'corpus#' + IntToStr(N);
      Corpus[N].Spec := '{}';
      Corpus[N].Data := B;
      Inc(N);
    end;
    SetLength(Corpus, N);
  finally
    F.Free;
  end;
end;

{ ---- one run ---- }

type
  TRng = record
    S: QWord;
    function Next: QWord;
    function Below(N: QWord): QWord;
  end;

{$push}{$Q-}{$R-}
function TRng.Next: QWord;
begin
  { splitmix64 }
  S := S + QWord($9E3779B97F4A7C15);
  Result := S;
  Result := (Result xor (Result shr 30)) * QWord($BF58476D1CE4E5B9);
  Result := (Result xor (Result shr 27)) * QWord($94D049BB133111EB);
  Result := Result xor (Result shr 31);
end;

function TRng.Below(N: QWord): QWord;
begin
  Result := Next mod N;
end;
{$pop}

function PieceLen(var R: TRng): SizeInt;
begin
  case R.Below(4) of
    0: Result := 1;
    1: Result := 1 + R.Below(8);
    2: Result := 1 + R.Below(64);
  else
    Result := 1 + R.Below(4096);
  end;
end;

procedure Fail_(const Msg: string);
begin
  raise EAssertionFailed.Create(Msg);
end;

function PoolHoldsAll(const P: TBlockPool): Boolean;
var
  I: Integer;
  N: SizeInt;
begin
  N := 0;
  for I := 0 to POOL_CLASSES - 1 do
    Inc(N, P.Counts[I]);
  Result := P.Allocated - P.Released = N;
end;

{ Serves Input once. Split = False: the reference run. }
function RunOne(const Input: TInput; Production, Split: Boolean; Seed: QWord;
  Trace: Boolean = False): TRunResult;
var
  Loop: TLoop;
  Pool: TExchangePool;
  Io: TScriptIo;
  Spec: TServerSpec;
  Svc: TConfService;
  Obs: TFuzzObserver;
  Data: TConnData;
  D: TH1Dispatcher;
  Freed: Boolean;
  Cfg: TH1Config;
  R: TRng;
  P, N: SizeInt;
  I, Steps, WF0: Integer;
  Nop: TNopTask;
  Ex0: LongInt;
  EofSent, Panicked: Boolean;
  Panic: RawByteString;

  function Done: Boolean;
  begin
    Result := Freed or D.Closed;
  end;

  { one poll (Iter: a loop iteration, else the readiness edge's direct
    Run). An exception is what TLoop.Run would catch (1.10: the task is
    aborted); only EH1Panic (hyper's panics, design 2.8) is documented }
  procedure Poll(Iter: Boolean);
  begin
    try
      if Iter then
        Loop.RunIteration
      else
        D.Run;
    except
      on E: EH1Panic do
      begin
        Panicked := True;
        Panic := 'panic ' + E.Message + #10;
        if not D.Closed then
        begin
          D.Abort;
          D.Close;
        end;
      end;
    end;
  end;

  { drives until done or nothing can make progress }
  procedure Drive;
  begin
    while Steps < 200000 do
    begin
      Inc(Steps);
      if Done then
        Exit;
      if D.Queued then
        Poll(True)
      else if Io.Wakeable then
      begin
        Io.ClearBlocked;
        Poll(False);
      end
      else
        Exit;
    end;
    Fail_('no end after 200000 steps');
  end;

begin
  Result := Default(TRunResult);
  Events := '';
  Ex0 := ExchangesLive;
  WF0 := WakeAssertFailures;
  Loop := TLoop.Create(0);
  Pool := TExchangePool.Create;
  Loop.Exchanges := Pool;
  Io := TScriptIo.Create;
  if Trace then
    Io.Log := TStringList.Create;
  Obs := TFuzzObserver.Create;
  Data := TConnData.Create;
  Data.Conn := 1;
  Data.Loop := Loop;
  Spec := ParseServerSpec(Input.Spec);
  Svc := TConfService.Create;
  Svc.Spec := Spec;
  Nop := TNopTask.Create;
  Nop.Loop := Loop;
  D := nil;
  try
    Cfg := Spec.Cfg;
    if Production then
      Cfg := ProductionH1Config;
    Cfg.AutoDateHeader := False;
    R.S := Seed;
    if Split then
    begin
      Io.Vectored(R.Below(2) = 0);
      P := 1;
      while P <= Length(Input.Data) do
      begin
        if R.Below(2) = 0 then
        begin
          Io.AddReadPending;
          Inc(SplitPendings);
        end;
        N := PieceLen(R);
        Io.AddRead(Copy(Input.Data, P, N));
        Inc(SplitPieces);
        Inc(P, N);
      end;
      for I := 1 to 1 + R.Below(40) do
        if R.Below(3) = 0 then
          Io.AddWritePending
        else
          Io.AddWriteLimit(1 + R.Below(64));
    end
    else if Input.Data <> '' then
      Io.AddRead(Input.Data);
    Freed := False;
    D := TFreeFlagDispatcher.Create(Loop, -1);
    TFreeFlagDispatcher(D).Freed := @Freed;
    D.OwnsTransport := False;
    D.Setup(Io, Svc, Cfg, Obs, 1, Data);
    if Spec.GracefulShutdownOnAccept then
      D.GracefulShutdown;
    Steps := 0;
    Panicked := False;
    Panic := '';
    Poll(False);                     { the first poll (TServer runs a new connection at once) }
    Drive;
    EofSent := False;
    if not Done then
    begin
      Io.AddReadEof;
      EofSent := True;
      Io.ClearBlocked;
      Poll(False);                   { the readiness edge of the FIN }
      Drive;
    end;
    Result.Written := Io.Written;
    if Trace then
      Result.Trace := Io.Log.Text;
    Result.Events := Events;
    Result.Ending := Obs.Ending + Panic;
    if not Done then
    begin
      Result.Ending := Result.Ending + 'not done' + #10;
      D.Abort;
      if not D.Closed then
        D.Close;
    end;
    if not EofSent then
      Result.Ending := Result.Ending + 'ended before EOF' + #10;
    { free the dispatcher (deferred free) with one more iteration that cannot block }
    Nop.Wake;
    Loop.RunIteration;
    if not Freed then
      Fail_('the dispatcher was not freed');
    if Loop.Aborts <> 0 then
      Fail_('a task was aborted by an exception');
    if WakeAssertFailures <> WF0 then
      Fail_('wake-source assertion failure');
    if not PoolHoldsAll(Loop.Blocks) then
      Fail_(Format('blocks not back in the pool: allocated %d released %d',
        [Loop.Blocks.Allocated, Loop.Blocks.Released]));
  finally
    Nop.Close;
    Loop.Free;
    Pool.Free;
    Io.Log.Free;
    Io.Free;
    Obs.Free;
    Data.Free;
    Svc.Free;
    Spec.Free;
  end;
  if ExchangesLive <> Ex0 then
    Fail_(Format('exchanges alive: %d before, %d after', [Ex0, ExchangesLive]));
  Inc(Runs);
end;

{ ---- the fuzz ---- }

procedure WriteFailure(const Input: TInput; const What: string; const A, B: TRunResult;
  Production: Boolean; Seed: QWord);
var
  F: TextFile;
  TA, TB: TRunResult;
begin
  TA := Default(TRunResult);
  TB := Default(TRunResult);
  try
    TA := RunOne(Input, Production, False, 0, True);
    TB := RunOne(Input, Production, True, Seed, True);
  except
  end;
  Inc(Fails);
  if Fails > 50 then
    Exit;
  AssignFile(F, DataDir + '/fail-' + IntToStr(Fails) + '.txt');
  Rewrite(F);
  WriteLn(F, What);
  WriteLn(F, '--- input');
  WriteLn(F, EscapeStr(Input.Data));
  WriteLn(F, '--- spec');
  WriteLn(F, Input.Spec);
  WriteLn(F, '--- reference: written');
  WriteLn(F, EscapeStr(A.Written));
  WriteLn(F, '--- reference: events');
  Write(F, A.Events, A.Ending);
  WriteLn(F, '--- split: written');
  WriteLn(F, EscapeStr(B.Written));
  WriteLn(F, '--- split: events');
  Write(F, B.Events, B.Ending);
  WriteLn(F, '--- reference: transport log');
  Write(F, TA.Trace);
  WriteLn(F, '--- split: transport log');
  Write(F, TB.Trace);
  CloseFile(F);
end;

{ Deviation S9-1 (hyper's is_complete_fast, role.rs parse_headers): after a
  partial read, a head is parsed again only once its bytes hold an end of
  head (CRLF CRLF or LF LF). An invalid head that the reference run (one
  read) answers with 400 is, when it arrives in pieces and has no end of
  head, never parsed again: the client's EOF ends the connection as
  incomplete, with nothing written for it; when what is left of it is only
  CR and LF bytes, hyper's EOF handling drops them as leading empty lines
  (io.rs consume_leading_lines) and the connection ends ok. Equivalent when the split run
  wrote and reported a prefix of the reference run's output (the responses
  to the requests before the invalid head) and ended incomplete where the
  reference run ended with a parse error (incomplete, or ok when the input
  ends with CR or LF), and the input holds no more ends of head (CRLF CRLF,
  LF LF, after leading empty lines) than the split run parsed requests. }
{ End-of-head markers (CRLF CRLF or LF LF, without overlap) after the
  leading CR/LF bytes; body bytes may add some, which only makes the check
  stricter }
function EndOfHeadMarkers(const S: RawByteString): Integer;
var
  I, N: SizeInt;
begin
  Result := 0;
  N := Length(S);
  I := 1;
  while (I <= N) and (S[I] in [#13, #10]) do
    Inc(I);
  while I <= N do
    if Copy(S, I, 4) = #13#10#13#10 then
    begin
      Inc(Result);
      Inc(I, 4);
    end
    else if Copy(S, I, 2) = #10#10 then
    begin
      Inc(Result);
      Inc(I, 2);
    end
    else
      Inc(I);
end;

function CountOf(const Sub, S: RawByteString): Integer;
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

function LateErrorEquivalent(const Input: TInput; const A, B: TRunResult): Boolean;
var
  Last: AnsiChar;
begin
  { the head that was never parsed again cannot have had an end of head:
    no more markers in the input than requests the split run parsed }
  if EndOfHeadMarkers(Input.Data) > CountOf('{"event":"request",', B.Events) then
    Exit(False);
  if Input.Data <> '' then
    Last := Input.Data[Length(Input.Data)]
  else
    Last := #0;
  Result := (Copy(A.Ending, 1, 19) = 'conn_close coParse ')
    and ((Copy(B.Ending, 1, 24) = 'conn_close coIncomplete ')
      or ((Copy(B.Ending, 1, 16) = 'conn_close coOk ') and (Last in [#13, #10])))
    and (Length(B.Written) < Length(A.Written)) and (Copy(A.Written, 1, Length(B.Written)) = B.Written)
    and (Copy(A.Events, 1, Length(B.Events)) = B.Events);
end;

{ Deviation S9-2 (hyper conn.rs on_parse_error / has_h2_prefix): the HTTP/2
  preface is recognized when the version error is found with at least its
  24 bytes buffered. Split so that the parser sees 'PRI * HTTP/2' before
  the 24th byte arrived, the head is an invalid HTTP/1 version: 400, outcome
  parse. Equivalent when the input starts with the preface, the reference
  run ended with parse_version_h2 and nothing written, and the split run
  wrote one 400 and ended with a parse error. }
const
  H2_PREFACE = 'PRI * HTTP/2.0'#13#10#13#10'SM'#13#10#13#10;
  BAD_REQUEST_400 = 'HTTP/1.1 400 Bad Request'#13#10;

function H2PrefaceEquivalent(const Input: TInput; const A, B: TRunResult): Boolean;
begin
  Result := (Copy(Input.Data, 1, Length(H2_PREFACE)) = H2_PREFACE)
    and (Copy(A.Ending, 1, 28) = 'conn_close coParseVersionH2 ') and (A.Written = '')
    and (Copy(B.Ending, 1, 19) = 'conn_close coParse ')
    and (Copy(B.Written, 1, Length(BAD_REQUEST_400)) = BAD_REQUEST_400)
    and (A.Events = B.Events);
end;

function EnvInt(const Name: string; Default: Int64): Int64;
begin
  Result := StrToInt64Def(GetEnvironmentVariable(Name), Default);
end;

procedure CheckOne(const Input: TInput; Production: Boolean; Seed: QWord; var Msgs: TStringList;
  var Refs: array of TRunResult; RefIndex: Integer; var HaveRef: array of Boolean);
var
  A, B: TRunResult;
  What: string;
begin
  What := Format('%s profile=%s seed=%d', [Input.Name, BoolToStr(Production, 'production', 'spec'), Seed]);
  try
    if (RefIndex >= 0) and HaveRef[RefIndex] then
      A := Refs[RefIndex]
    else
    begin
      A := RunOne(Input, Production, False, 0);
      if RefIndex >= 0 then
      begin
        Refs[RefIndex] := A;
        HaveRef[RefIndex] := True;
      end;
    end;
    B := RunOne(Input, Production, True, Seed);
  except
    on E: Exception do
    begin
      Inc(Fails);
      if Msgs.Count < 20 then
        Msgs.Add(What + ': ' + E.ClassName + ': ' + E.Message);
      Exit;
    end;
  end;
  if (A.Written <> B.Written) or (A.Events <> B.Events) or (A.Ending <> B.Ending) then
  begin
    if LateErrorEquivalent(Input, A, B) then
    begin
      Inc(LateErrors);
      Exit;
    end;
    if H2PrefaceEquivalent(Input, A, B) then
    begin
      Inc(H2Splits);
      Exit;
    end;
    if Msgs.Count < 20 then
      Msgs.Add(What + ': output differs (fail-' + IntToStr(Fails + 1) + '.txt)');
    WriteFailure(Input, What, A, B, Production, Seed);
  end;
end;

procedure TSplitFuzz.Cases_and_corpus_samples;
var
  Seeds, Seed0, PerSeed, S, I, Prof, K: Int64;
  Msgs: TStringList;
  Refs: array of TRunResult;
  HaveRef: array of Boolean;
  R: TRng;
  Dummy: array of TRunResult;
  DummyHave: array of Boolean;
  Runs0, Fails0, Late0, H20: Int64;
  T0: QWord;
begin
  Seeds := EnvInt('FUZZ_SEEDS', 2000);
  Seed0 := EnvInt('FUZZ_SEED0', 1);
  PerSeed := EnvInt('FUZZ_CORPUS_PER_SEED', 20);
  SetLength(Refs, 2 * Length(Cases));
  SetLength(HaveRef, 2 * Length(Cases));
  SetLength(Dummy, 0);
  SetLength(DummyHave, 0);
  Msgs := TStringList.Create;
  Runs0 := Runs;
  Fails0 := Fails;
  Late0 := LateErrors;
  H20 := H2Splits;
  T0 := GetTickCount64;
  try
    for S := Seed0 to Seed0 + Seeds - 1 do
    begin
      for I := 0 to High(Cases) do
        for Prof := 0 to 1 do
          CheckOne(Cases[I], Prof = 1, QWord(S) * 1000003 + QWord(I), Msgs, Refs, 2 * I + Prof, HaveRef);
      R.S := QWord(S) * 7919;
      for K := 1 to PerSeed do
        if Length(Corpus) > 0 then
        begin
          I := R.Below(Length(Corpus));
          CheckOne(Corpus[I], R.Below(2) = 1, R.Next, Msgs, Dummy, -1, DummyHave);
        end;
    end;
    Flush(Output);
    WriteLn(StdErr, Format('split fuzz: %d seeds (%d..%d), %d case inputs x 2 profiles + %d corpus entries per seed: %d runs, %d pieces, %d EAGAIN reads, %d late-error equivalents (S9-1), %d split h2 prefaces (S9-2), %d differences or failures, %.1f s',
      [Seeds, Seed0, Seed0 + Seeds - 1, Length(Cases), PerSeed, Runs - Runs0, SplitPieces, SplitPendings,
       LateErrors - Late0, H2Splits - H20, Fails - Fails0, (GetTickCount64 - T0) / 1000]));
    Flush(StdErr);
    if Fails <> Fails0 then
      Fail(IntToStr(Fails - Fails0) + ' differences or failures; first: ' + LineEnding + Msgs.Text);
  finally
    Msgs.Free;
  end;
end;

procedure TSplitFuzz.Corpus_every_entry_once;
var
  I: Integer;
  Msgs: TStringList;
  Dummy: array of TRunResult;
  DummyHave: array of Boolean;
  Runs0, Fails0, Late0, H20: Int64;
  T0: QWord;
begin
  if EnvInt('FUZZ_CORPUS_ALL', 1) = 0 then
    Exit;
  SetLength(Dummy, 0);
  SetLength(DummyHave, 0);
  Msgs := TStringList.Create;
  Runs0 := Runs;
  Fails0 := Fails;
  Late0 := LateErrors;
  H20 := H2Splits;
  T0 := GetTickCount64;
  try
    for I := 0 to High(Corpus) do
      CheckOne(Corpus[I], I mod 2 = 1, QWord(I) + 1, Msgs, Dummy, -1, DummyHave);
    Flush(Output);
    WriteLn(StdErr, Format('split fuzz: every corpus entry once (%d entries, profiles alternating): %d runs, %d late-error equivalents (S9-1), %d split h2 prefaces (S9-2), %d differences or failures, %.1f s',
      [Length(Corpus), Runs - Runs0, LateErrors - Late0, H2Splits - H20, Fails - Fails0, (GetTickCount64 - T0) / 1000]));
    Flush(StdErr);
    if Fails <> Fails0 then
      Fail(IntToStr(Fails - Fails0) + ' differences or failures; first: ' + LineEnding + Msgs.Text);
  finally
    Msgs.Free;
  end;
end;

begin
  DataDir := GetEnvironmentVariable('FUZZ_DATA');
  if DataDir = '' then
    DataDir := 'build/m3/S9/fuzz';
  LoadCases(DataDir + '/cases.bin');
  LoadCorpus(DataDir + '/corpus.bin');
  WriteLn(StdErr, Format('split fuzz: %d case inputs, %d corpus entries', [Length(Cases), Length(Corpus)]));
  EventHook := @CollectEvent;
  RegisterTest(TSplitFuzz);
  with TTestRunner.Create(nil) do
  try
    Initialize;
    Run;
  finally
    Free;
  end;
  Cases := nil;
  Corpus := nil;
  Events := '';
end.

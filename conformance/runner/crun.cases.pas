{ crun.cases - one conformance case: validation (the allowed fields of a
  case and of each step, SPEC.md sections 8 and 9) and execution: start the
  server (and the proxy for via_proxy), run the steps in order and stop at
  the first failure, then wait for expect_events (in order, within
  events_timeout_ms) and check forbid_events (after events_settle_ms).

  Test tooling only. }
unit crun.cases;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, crun.bytes, crun.json, crun.conn, crun.response, crun.server, crun.proxy,
  crun.assert;

type
  TCaseResult = record
    Failures: array of RawByteString;
    Events: array of RawByteString;  { JSON text of every server event }
    Stderr: RawByteString;
    ElapsedMs: Int64;
  end;

{ raises ECase with the reason the case is invalid }
procedure ValidateCase(C: TJValue);
function RunCase(C: TJValue; const ServerCmd: RawByteString; Verbose: Boolean): TCaseResult;

implementation

const
  CASE_KEYS: array[0..11] of RawByteString = ('name', 'source', 'pending', 'notes', 'comment', 'server',
    'via_proxy', 'steps', 'expect_events', 'forbid_events', 'events_timeout_ms', 'events_settle_ms');
  READ_COMMON: array[0..8] of RawByteString = ('op', 'conn', 'comment', 'mark', 'expect', 'timing',
    'timeout_ms', 'allow_reset', 'diff_capture');

procedure AddAll(var L: TStringArray; const A: array of RawByteString);
var
  K: Integer;
begin
  for K := 0 to High(A) do
  begin
    SetLength(L, Length(L) + 1);
    L[High(L)] := A[K];
  end;
end;

procedure ValidateStep(S: TJValue);
var
  Op, Cmd: RawByteString;
  Allowed: TStringArray;
  Ar: array of RawByteString;
  U, T, X: TJValue;
  N: QWord;
  K: Integer;
begin
  if S.Kind <> jkObj then
    raise ECase.Create('step must be an object');
  X := S.Get('op');
  if (X = nil) or (X.Kind <> jkStr) then
    raise ECase.Create('step needs a string "op"');
  Op := X.S;
  Allowed := nil;
  if Op = 'connect' then AddAll(Allowed, ['nodelay'])
  else if Op = 'write' then AddAll(Allowed, ['data', 'may_fail', 'expect_fail', 'timeout_ms'])
  else if Op = 'sleep' then AddAll(Allowed, ['ms'])
  else if (Op = 'shutdown_write') or (Op = 'close') then
  else if Op = 'read_once' then AddAll(Allowed, ['max', 'allow_timeout'])
  else if Op = 'read_exact' then AddAll(Allowed, ['len'])
  else if Op = 'read_until' then AddAll(Allowed, ['until', 'max'])
  else if Op = 'read_to_eof' then AddAll(Allowed, ['max', 'deadline_ms'])
  else if Op = 'read_response' then AddAll(Allowed, ['method'])
  else if Op = 'expect_open' then AddAll(Allowed, ['for_ms', 'expect', 'timing', 'diff_capture'])
  else if Op = 'control' then AddAll(Allowed, ['command', 'name'])
  else if Op = 'await_event' then AddAll(Allowed, ['match', 'timeout_ms'])
  else
    raise ECase.CreateFmt('unknown op %s', [JsonStr(Op)]);
  if StartsWith(Op, 'read_') then
    AddAll(Allowed, READ_COMMON);
  AddAll(Allowed, ['op', 'conn', 'comment', 'mark']);
  Ar := nil;
  SetLength(Ar, Length(Allowed));
  for K := 0 to High(Allowed) do
    Ar[K] := Allowed[K];
  CheckKeys(S, Ar);
  if Op = 'write' then
  begin
    if not S.Has('data') then
      raise ECase.Create('write needs "data"');
  end
  else if Op = 'sleep' then
  begin
    if not GetU64(S, 'ms', N) then
      raise ECase.Create('sleep needs integer "ms"');
  end
  else if Op = 'read_exact' then
  begin
    if not GetU64(S, 'len', N) then
      raise ECase.Create('read_exact needs integer "len"');
  end
  else if Op = 'read_until' then
  begin
    U := S.Get('until');
    if (U = nil) or (U.Kind <> jkObj) then
      raise ECase.Create('read_until needs an "until" object');
    CheckKeys(U, ['ends_with', 'contains', 'starts_with', 'min_len']);
    if U.Count <> 1 then
      raise ECase.Create('until: exactly one of ends_with, contains, starts_with, min_len');
  end
  else if Op = 'expect_open' then
  begin
    if not GetU64(S, 'for_ms', N) then
      raise ECase.Create('expect_open needs integer "for_ms"');
  end
  else if Op = 'control' then
  begin
    Cmd := GetStr(S, 'command', #0);
    if Cmd = 'signal' then
    begin
      X := S.Get('name');
      if (X = nil) or (X.Kind <> jkStr) then
        raise ECase.Create('signal needs a "name"');
    end
    else if Cmd <> 'graceful_shutdown' then
      raise ECase.Create('control: command must be "graceful_shutdown" or "signal"');
  end
  else if Op = 'await_event' then
  begin
    if not S.Has('match') then
      raise ECase.Create('await_event needs "match"');
  end;
  X := S.Get('expect');
  if (X <> nil) and (X.Kind <> jkArr) then
    raise ECase.Create('expect: expected an array of assertions');
  T := S.Get('timing');
  if T <> nil then
  begin
    if T.Kind <> jkObj then
      raise ECase.Create('timing: expected an object');
    CheckKeys(T, ['since', 'min_ms', 'max_ms']);
  end;
end;

procedure ValidateCase(C: TJValue);
var
  X, Steps: TJValue;
  K: Integer;
begin
  if C.Kind <> jkObj then
    raise ECase.Create('case must be an object');
  CheckKeys(C, CASE_KEYS);
  X := C.Get('name');
  if (X = nil) or (X.Kind <> jkStr) then
    raise ECase.Create('case needs a string "name"');
  X := C.Get('via_proxy');
  if (X <> nil) and (X.Kind <> jkNull) and not ((X.Kind = jkStr) and (X.S = 'h1')) then
    raise ECase.CreateFmt('via_proxy: only "h1" is supported, found %s', [JsonText(X)]);
  Steps := C.Get('steps');
  if (Steps = nil) or (Steps.Kind <> jkArr) then
    raise ECase.Create('case needs a "steps" array');
  for K := 0 to High(Steps.Items) do
    try
      ValidateStep(Steps.Items[K]);
    except
      on E: ECase do
        raise ECase.CreateFmt('step %d: %s', [K, E.Message]);
    end;
  X := C.Get('expect_events');
  if (X <> nil) and (X.Kind <> jkArr) then
    raise ECase.Create('expect_events: expected an array');
  X := C.Get('forbid_events');
  if (X <> nil) and (X.Kind <> jkArr) then
    raise ECase.Create('forbid_events: expected an array');
end;

{ ---- execution ---- }

type
  TMark = record
    Name: RawByteString;
    At: Int64;
  end;

  TExec = class
  public
    Server: TServerProc;
    Proxy: TProxy;
    TargetPort: Word;
    ConnNames: array of RawByteString;
    Conns: array of TConn;
    Marks: array of TMark;
    Vars: TVars;
    Cursor: Integer;
    Verbose: Boolean;
    CaseName: RawByteString;
    function Conn(const Name: RawByteString): TConn;
    procedure SetMark(const Name: RawByteString; At: Int64);
    function FindMark(const Name: RawByteString; out At: Int64): Boolean;
    procedure RunStep(I: Integer; S: TJValue);
    procedure ExecRead(const Op, CName: RawByteString; S: TJValue; TimeoutMs: Int64; AllowReset: Boolean;
      out Cap: TCapture; out DoneAt: Int64);
    procedure CheckTiming(T: TJValue; const CName: RawByteString; Started, DoneAt: Int64);
    procedure CloseConns;
  end;

function TExec.Conn(const Name: RawByteString): TConn;
var
  K: Integer;
begin
  for K := 0 to High(ConnNames) do
    if ConnNames[K] = Name then
      Exit(Conns[K]);
  raise ECase.CreateFmt('connection %s is not connected (add a connect step)', [JsonStr(Name)]);
end;

procedure TExec.SetMark(const Name: RawByteString; At: Int64);
var
  K: Integer;
begin
  for K := 0 to High(Marks) do
    if Marks[K].Name = Name then
    begin
      Marks[K].At := At;
      Exit;
    end;
  SetLength(Marks, Length(Marks) + 1);
  Marks[High(Marks)].Name := Name;
  Marks[High(Marks)].At := At;
end;

function TExec.FindMark(const Name: RawByteString; out At: Int64): Boolean;
var
  K: Integer;
begin
  for K := 0 to High(Marks) do
    if Marks[K].Name = Name then
    begin
      At := Marks[K].At;
      Exit(True);
    end;
  At := 0;
  Result := False;
end;

procedure TExec.CloseConns;
var
  K: Integer;
begin
  for K := 0 to High(Conns) do
    Conns[K].Free;
  Conns := nil;
  ConnNames := nil;
end;

function MsOf(S: TJValue; const Key: RawByteString; Default: Int64): Int64;
var
  V: QWord;
begin
  if GetU64(S, Key, V) then
    Result := Int64(V)
  else
    Result := Default;
end;

procedure TExec.CheckTiming(T: TJValue; const CName: RawByteString; Started, DoneAt: Int64);
var
  Since: RawByteString;
  Base, Elapsed: Int64;
  Mn, Mx: QWord;
begin
  Since := GetStr(T, 'since', 'step');
  if Since = 'step' then
    Base := Started
  else if Since = 'connect' then
  begin
    if not FindMark('connect:' + CName, Base) then
      raise ECase.Create('timing: connection has no connect time');
  end
  else if not FindMark(Since, Base) then
    raise ECase.CreateFmt('timing: unknown mark %s', [JsonStr(Since)]);
  Elapsed := (DoneAt - Base) div 1000;
  if Elapsed < 0 then
    Elapsed := 0;
  if GetU64(T, 'min_ms', Mn) and (QWord(Elapsed) < Mn) then
    raise ECase.CreateFmt('timing: completed %d ms after %s, expected >= %d ms', [Elapsed, Since, Mn]);
  if GetU64(T, 'max_ms', Mx) and (QWord(Elapsed) > Mx) then
    raise ECase.CreateFmt('timing: completed %d ms after %s, expected <= %d ms', [Elapsed, Since, Mx]);
end;

procedure TExec.ExecRead(const Op, CName: RawByteString; S: TJValue; TimeoutMs: Int64; AllowReset: Boolean;
  out Cap: TCapture; out DoneAt: Int64);
var
  C: TConn;
  Max, Len, Room: SizeInt;
  M: QWord;
  AllowTimeout, TimedOut: Boolean;
  R: TReadOutcome;
  U, Val_: TJValue;
  Kind, Needle, CapB, N: RawByteString;
  MinLen: SizeInt;
  Deadline, Wait, Now_, Until_: Int64;
  HasDeadline, Ok: Boolean;
  Method: RawByteString;
  E: TEnd;

  function ResetErr(const What: RawByteString): RawByteString;
  begin
    Result := Format('connection reset by peer during %s (set allow_reset to accept)', [What]);
  end;

  function TimeoutErr(const What: RawByteString; Have: SizeInt): RawByteString;
  begin
    Result := Format('timed out after %d ms during %s (%d bytes received in this step)', [TimeoutMs, What, Have]);
  end;

  procedure Done(const Raw: RawByteString; AEnd: TEnd);
  begin
    Cap.Raw := Raw;
    Cap.End_ := AEnd;
    DoneAt := NowUs;
  end;

begin
  Cap := Default(TCapture);
  DoneAt := NowUs;
  C := Conn(CName);
  if C.IsClosedLocally then
    raise ECase.CreateFmt('connection %s was closed by a close step', [JsonStr(CName)]);
  if Op = 'read_once' then
  begin
    if GetU64(S, 'max', M) then Max := M else Max := 4096;
    AllowTimeout := GetBool(S, 'allow_timeout');
    TimedOut := False;
    if C.Buf = '' then
    begin
      R := C.ReadSome(TimeoutMs);
      case R of
        roData, roEof: ;
        roReset: if not AllowReset then raise ECase.Create(ResetErr('read_once'));
        roTimeout: if AllowTimeout then TimedOut := True else raise ECase.Create(TimeoutErr('read_once', 0));
      end;
    end;
    Done(C.Take(Max), C.End_);
    if Cap.Raw <> '' then Cap.ReadResult := 'data'
    else if TimedOut then Cap.ReadResult := 'timeout'
    else if C.End_ = endReset then Cap.ReadResult := 'reset'
    else Cap.ReadResult := 'eof';
    Exit;
  end;
  if Op = 'read_exact' then
  begin
    GetU64(S, 'len', M);
    Len := M;
    while True do
    begin
      if Length(C.Buf) >= Len then
      begin
        Done(C.Take(Len), C.End_);
        Exit;
      end;
      case C.ReadSome(TimeoutMs) of
        roData: ;
        roEof: raise ECase.CreateFmt('EOF after %d of %d bytes: %s', [Length(C.Buf), Len, Show(C.Buf, 300)]);
        roReset: raise ECase.Create(ResetErr('read_exact'));
        roTimeout: raise ECase.Create(TimeoutErr('read_exact', Length(C.Buf)));
      end;
    end;
  end;
  if Op = 'read_until' then
  begin
    if GetU64(S, 'max', M) then Max := M else Max := 8192;
    U := S.Get('until');
    Kind := U.Keys[0];
    Val_ := U.Items[0];
    if Kind = 'min_len' then
      Needle := ''
    else
      Needle := DecodeBytes(Val_, Vars);
    if Val_.AsU64(M) then MinLen := M else MinLen := 0;
    CapB := '';
    while True do
    begin
      Room := Max - Length(CapB);
      CapB := CapB + C.Take(Room);
      N := Normalize(CapB);
      if Kind = 'ends_with' then Ok := EndsWith(N, Needle)
      else if Kind = 'starts_with' then Ok := StartsWith(N, Needle)
      else if Kind = 'contains' then Ok := FindBytes(N, Needle) >= 0
      else Ok := Length(CapB) >= MinLen;
      if Ok then
      begin
        Done(CapB, C.End_);
        Exit;
      end;
      if Length(CapB) >= Max then
        raise ECase.CreateFmt('read_until: %d bytes received without a match (buffer filled): %s', [Max, Show(N, 600)]);
      case C.ReadSome(TimeoutMs) of
        roData: ;
        roEof: raise ECase.CreateFmt('read_until: EOF before match; received %s', [Show(N, 600)]);
        roReset: raise ECase.CreateFmt('%s; received %s', [ResetErr('read_until'), Show(N, 600)]);
        roTimeout: raise ECase.CreateFmt('%s; received %s', [TimeoutErr('read_until', Length(CapB)), Show(N, 600)]);
      end;
    end;
  end;
  if Op = 'read_to_eof' then
  begin
    if GetU64(S, 'max', M) then Max := M else Max := 64 shl 20;
    HasDeadline := S.Has('deadline_ms');
    Deadline := NowUs + MsOf(S, 'deadline_ms', 0) * 1000;
    CapB := '';
    while True do
    begin
      CapB := CapB + C.Take(High(SizeInt));
      if Length(CapB) > Max then
        raise ECase.CreateFmt('read_to_eof: more than %d bytes received', [Max]);
      case C.End_ of
        endEof:
          begin
            Done(CapB, endEof);
            Exit;
          end;
        endReset:
          if AllowReset then
          begin
            Done(CapB, endReset);
            Exit;
          end
          else
            raise ECase.CreateFmt('%s; received %s', [ResetErr('read_to_eof'), Show(Normalize(CapB), 600)]);
      end;
      Wait := TimeoutMs;
      if HasDeadline then
      begin
        Now_ := NowUs;
        if Now_ >= Deadline then
          raise ECase.CreateFmt('read_to_eof: deadline passed without EOF; received %s', [Show(Normalize(CapB), 600)]);
        if (Deadline - Now_) div 1000 < Wait then
          Wait := (Deadline - Now_ + 999) div 1000;
      end;
      if C.ReadSome(Wait) = roTimeout then
        if (not HasDeadline) or (NowUs < Deadline) then
          raise ECase.CreateFmt('%s; received %s', [TimeoutErr('read_to_eof', Length(CapB)), Show(Normalize(CapB), 600)]);
    end;
  end;
  if Op = 'read_response' then
  begin
    Method := GetStr(S, 'method');
    ReadResponse(C, LowerAscii(Method) = 'head', TimeoutMs, AllowReset, Cap.Resp, E, DoneAt);
    Cap.HasResp := True;
    Cap.Raw := Cap.Resp.Raw;
    Cap.End_ := E;
    Exit;
  end;
  if Op = 'expect_open' then
  begin
    Until_ := NowUs + MsOf(S, 'for_ms', 0) * 1000;
    CapB := '';
    while True do
    begin
      CapB := CapB + C.Take(High(SizeInt));
      if C.End_ <> endOpen then
      begin
        if C.End_ = endEof then Kind := 'reached EOF' else Kind := 'was reset';
        raise ECase.CreateFmt('expect_open: connection %s before %d ms; received %s',
          [Kind, MsOf(S, 'for_ms', 0), Show(Normalize(CapB), 600)]);
      end;
      Now_ := NowUs;
      if Now_ >= Until_ then
      begin
        Cap.Raw := CapB;
        Cap.End_ := endOpen;
        DoneAt := Now_;
        Exit;
      end;
      C.ReadSome((Until_ - Now_ + 999) div 1000);
    end;
  end;
  raise ECase.CreateFmt('unknown op %s', [Op]);
end;

procedure TExec.RunStep(I: Integer; S: TJValue);
var
  Op, CName, Line, Cmd, Name, Err: RawByteString;
  Started, TimeoutMs, Deadline, DoneAt: Int64;
  AllowReset, Found, Failed, Ok: Boolean;
  Data: RawByteString;
  WriteErr: RawByteString;
  From, K: Integer;
  Evs: TJArrayList;
  Pat, X: TJValue;
  Cap: TCapture;
  C: TConn;
begin
  Op := GetStr(S, 'op');
  CName := GetStr(S, 'conn', 'main');
  Started := NowUs;
  TimeoutMs := MsOf(S, 'timeout_ms', DEFAULT_TIMEOUT_MS);
  AllowReset := GetBool(S, 'allow_reset');
  Err := '';
  try
    try
      if Op = 'connect' then
      begin
        for K := 0 to High(ConnNames) do
          if ConnNames[K] = CName then
            raise ECase.CreateFmt('connection %s already exists', [JsonStr(CName)]);
        C := TConn.Connect(TargetPort, GetBool(S, 'nodelay'));
        SetMark('connect:' + CName, C.ConnectedAt);
        SetLength(ConnNames, Length(ConnNames) + 1);
        SetLength(Conns, Length(Conns) + 1);
        ConnNames[High(ConnNames)] := CName;
        Conns[High(Conns)] := C;
      end
      else if Op = 'write' then
      begin
        Data := DecodeBytes(S.Get('data'), Vars);
        WriteErr := '';
        C := Conn(CName);
        try
          C.WriteAll(Data, TimeoutMs);
        except
          on E: ECase do
            WriteErr := E.Message;
        end;
        if GetBool(S, 'expect_fail') then
        begin
          if WriteErr = '' then
            raise ECase.Create('write succeeded but expect_fail is set');
        end
        else if (WriteErr <> '') and not GetBool(S, 'may_fail') then
          raise ECase.Create(WriteErr);
      end
      else if Op = 'sleep' then
        SleepMs(MsOf(S, 'ms', 0))
      else if Op = 'shutdown_write' then
        Conn(CName).ShutdownWrite
      else if Op = 'close' then
        Conn(CName).Close
      else if Op = 'control' then
      begin
        Cmd := GetStr(S, 'command');
        if Cmd = 'signal' then
        begin
          Name := GetStr(S, 'name');
          Line := 'signal ' + Name;
        end
        else
        begin
          Name := '';
          Line := Cmd;
        end;
        From := Server.Events.Count;
        Server.SendLine(Line);
        Deadline := NowUs + 2000000;
        Found := False;
        while True do
        begin
          Evs := Server.Events.LockEvents;
          try
            for K := From to High(Evs) do
              if (GetStr(Evs[K], 'event') = 'control_ack') and (GetStr(Evs[K], 'command') = Cmd)
                and ((Cmd <> 'signal') or (GetStr(Evs[K], 'name') = Name)) then
              begin
                Found := True;
                Break;
              end;
          finally
            Server.Events.UnlockEvents;
          end;
          if Found or (NowUs >= Deadline) then
            Break;
          Server.Events.WaitChange((Deadline - NowUs) div 1000 + 1);
        end;
        if not Found then
          raise ECase.CreateFmt('no control_ack for %s within 2 s', [JsonStr(Line)]);
      end
      else if Op = 'await_event' then
      begin
        Pat := S.Get('match');
        Deadline := NowUs + MsOf(S, 'timeout_ms', DEFAULT_TIMEOUT_MS) * 1000;
        Found := False;
        while True do
        begin
          Evs := Server.Events.LockEvents;
          try
            for K := Cursor to High(Evs) do
              if Matches(Pat, Evs[K], Vars) then
              begin
                Cursor := K + 1;
                Found := True;
                Break;
              end;
          finally
            Server.Events.UnlockEvents;
          end;
          if Found or (NowUs >= Deadline) then
            Break;
          Server.Events.WaitChange((Deadline - NowUs) div 1000 + 1);
        end;
        if not Found then
          raise ECase.CreateFmt('no event matching %s within the timeout', [JsonText(Pat)]);
      end
      else
      begin
        ExecRead(Op, CName, S, TimeoutMs, AllowReset, Cap, DoneAt);
        Cap.Norm := Normalize(Cap.Raw);
        X := S.Get('timing');
        if (X <> nil) and (X.Kind = jkObj) then
          CheckTiming(X, CName, Started, DoneAt);
        X := S.Get('expect');
        if (X <> nil) and (X.Kind = jkArr) then
          for K := 0 to High(X.Items) do
            try
              Check(X.Items[K], Cap, Vars);
            except
              on E: ECase do
                raise ECase.CreateFmt('expect[%d]: %s', [K, E.Message]);
            end;
      end;
    except
      on E: ECase do
        Err := E.Message;
    end;
  finally
    X := S.Get('mark');
    if (X <> nil) and (X.Kind = jkStr) then
      SetMark(X.S, NowUs);
  end;
  if Verbose then
    if Err = '' then
      WriteLn(StdErr, Format('  [%s] step %d %s: ok', [CaseName, I, Op]))
    else
      WriteLn(StdErr, Format('  [%s] step %d %s: %s', [CaseName, I, Op, Err]));
  if Err <> '' then
    raise ECase.Create(Err);
end;

procedure AddFailure(var R: TCaseResult; const S: RawByteString);
begin
  SetLength(R.Failures, Length(R.Failures) + 1);
  R.Failures[High(R.Failures)] := S;
end;

function RunCase(C: TJValue; const ServerCmd: RawByteString; Verbose: Boolean): TCaseResult;
var
  Start, Deadline: Int64;
  Ex: TExec;
  Spec, EmptySpec, Steps, Pats, P, X: TJValue;
  K, Pi_, Cur, LastUnmatched: Integer;
  Evs: TJArrayList;
  Hit, AllMatched: Boolean;
  PErr, St: RawByteString;
  WaitMs, Settle: Int64;
begin
  Result := Default(TCaseResult);
  Start := NowUs;
  EmptySpec := TJValue.CreateKind(jkObj);
  Ex := TExec.Create;
  try
    Ex.Verbose := Verbose;
    Ex.CaseName := GetStr(C, 'name');
    Ex.SetMark('case', Start);
    Spec := C.Get('server');
    if Spec = nil then
      Spec := EmptySpec;
    try
      Ex.Server := TServerProc.Spawn(ServerCmd, Spec);
    except
      on E: ECase do
      begin
        AddFailure(Result, 'server start failed: ' + E.Message);
        Result.ElapsedMs := (NowUs - Start) div 1000;
        Exit;
      end;
    end;
    Ex.TargetPort := Ex.Server.Port;
    if GetStr(C, 'via_proxy') = 'h1' then
    begin
      try
        Ex.Proxy := TProxy.Start(Ex.Server.Port);
      except
        on E: ECase do
        begin
          AddFailure(Result, 'proxy start failed: ' + E.Message);
          Result.Stderr := Ex.Server.StderrText;
          Result.ElapsedMs := (NowUs - Start) div 1000;
          Exit;
        end;
      end;
      Ex.TargetPort := Ex.Proxy.Port;
    end;
    SetVar(Ex.Vars, 'port', IntToStr(Ex.TargetPort));
    SetVar(Ex.Vars, 'server_port', IntToStr(Ex.Server.Port));
    if Ex.Proxy <> nil then
      SetVar(Ex.Vars, 'proxy_port', IntToStr(Ex.Proxy.Port));

    Steps := C.Get('steps');
    for K := 0 to High(Steps.Items) do
      try
        Ex.RunStep(K, Steps.Items[K]);
      except
        on E: ECase do
        begin
          AddFailure(Result, Format('step %d (%s): %s', [K, GetStr(Steps.Items[K], 'op'), E.Message]));
          Break;
        end;
      end;

    if Length(Result.Failures) = 0 then
    begin
      WaitMs := MsOf(C, 'events_timeout_ms', 1000);
      Pats := C.Get('expect_events');
      if (Pats <> nil) and (Pats.Kind = jkArr) then
      begin
        Deadline := NowUs + WaitMs * 1000;
        PErr := '';
        LastUnmatched := 0;
        while True do
        begin
          AllMatched := True;
          Evs := Ex.Server.Events.LockEvents;
          try
            try
              Cur := 0;
              for Pi_ := 0 to High(Pats.Items) do
              begin
                Hit := False;
                for K := Cur to High(Evs) do
                  if Matches(Pats.Items[Pi_], Evs[K], Ex.Vars) then
                  begin
                    Hit := True;
                    Cur := K + 1;
                    Break;
                  end;
                if not Hit then
                begin
                  LastUnmatched := Pi_;
                  AllMatched := False;
                  Break;
                end;
              end;
            except
              on E: ECase do
                PErr := E.Message;
            end;
          finally
            Ex.Server.Events.UnlockEvents;
          end;
          if AllMatched or (PErr <> '') or (NowUs >= Deadline) then
            Break;
          Ex.Server.Events.WaitChange((Deadline - NowUs) div 1000 + 1);
        end;
        if PErr <> '' then
          AddFailure(Result, 'expect_events: ' + PErr)
        else if not AllMatched then
          AddFailure(Result, Format('expect_events[%d] %s not matched (in order) within %d ms',
            [LastUnmatched, JsonText(Pats.Items[LastUnmatched]), WaitMs]));
      end;
      Pats := C.Get('forbid_events');
      if (Pats <> nil) and (Pats.Kind = jkArr) then
      begin
        Settle := MsOf(C, 'events_settle_ms', 200);
        SleepMs(Settle);
        Evs := Ex.Server.Events.Snapshot;
        try
          for K := 0 to High(Evs) do
            for Pi_ := 0 to High(Pats.Items) do
            begin
              P := Pats.Items[Pi_];
              try
                if Matches(P, Evs[K], Ex.Vars) then
                  AddFailure(Result, Format('forbid_events[%d] %s matched event %s', [Pi_, JsonText(P), JsonText(Evs[K])]));
              except
                on E: ECase do
                  AddFailure(Result, Format('forbid_events[%d]: %s', [Pi_, E.Message]));
              end;
            end;
        finally
          FreeEvents(Evs);
        end;
      end;
    end;

    St := Ex.Server.Exited;
    if St <> '' then
      AddFailure(Result, Format('server process exited during the case (%s)', [St]));
    Ex.CloseConns;
    Ex.Server.Stop;
    Evs := Ex.Server.Events.Snapshot;
    try
      SetLength(Result.Events, Length(Evs));
      for K := 0 to High(Evs) do
        Result.Events[K] := JsonText(Evs[K]);
    finally
      FreeEvents(Evs);
    end;
    Result.Stderr := Ex.Server.StderrText;
  finally
    Ex.CloseConns;
    FreeAndNil(Ex.Proxy);
    FreeAndNil(Ex.Server);
    Ex.Free;
    EmptySpec.Free;
  end;
  Result.ElapsedMs := (NowUs - Start) div 1000;
end;

end.

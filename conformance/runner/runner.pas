{ runner - the conformance case runner (conformance/SPEC.md).

    runner run --server CMD [--filter S]... [--jobs N] [-v] PATH...
    runner list [--filter S]... PATH...
    runner selftest

  run: every case of the case files (a PATH is a file or a directory
  searched recursively for *.json, in sorted order) against a server
  started as `CMD --config <file>` for each case; prints PASS, FAIL or PEND
  per case, in case order, then "SUMMARY passed=.. failed=.. pending=..
  total=..". Exit status 1 when a case failed. --jobs N runs N cases at a
  time. --filter keeps the cases whose "<file>::<name>" contains S.
  list: the cases, with INVALID, PEND or CASE.
  selftest: the runner's own checks (JSON, byte strings, the date
  normalization, the UTF-8 check, the assertion errors); exit status 1 on
  a failure.

  Test tooling only: nothing here ships with Bearings, and none of the
  Bearings units is used, so the runner shares no code with the server it
  checks. }
program runner;

{$mode objfpc}{$H+}

uses
  cthreads, SysUtils, Classes, BaseUnix, crun.json, crun.bytes, crun.conn,
  crun.response, crun.server, crun.proxy, crun.assert, crun.cases;

type
  TLoaded = record
    Id: RawByteString;
    Doc: TJValue;                    { the file's document (owner) or nil }
    Case_: TJValue;
    Invalid: RawByteString;
  end;

var
  Cmd: RawByteString;
  Server: RawByteString = '';
  Filters: array of RawByteString;
  Jobs: Integer = 1;
  Verbose: Boolean = False;
  Paths: array of RawByteString;
  Cases: array of TLoaded;
  Docs: array of TJValue;

procedure Usage;
begin
  WriteLn(StdErr, 'usage:');
  WriteLn(StdErr, '  runner run  --server CMD [--filter S]... [--jobs N] [-v] PATH...');
  WriteLn(StdErr, '  runner list [--filter S]... PATH...');
  WriteLn(StdErr, '  runner selftest');
  WriteLn(StdErr, 'PATH is a case file or a directory searched recursively for *.json.');
  WriteLn(StdErr, 'CMD is a shell command line; the runner appends `--config <file>`.');
  WriteLn(StdErr, '--jobs N runs N cases at a time (default 1); the output keeps the case order.');
  WriteLn(StdErr, 'run needs --server.');
  Halt(2);
end;

procedure ParseArgs;
var
  K: Integer;
  A: RawByteString;

  function Next: RawByteString;
  begin
    Inc(K);
    if K > ParamCount then
      Usage;
    Result := ParamStr(K);
  end;

begin
  if ParamCount < 1 then
    Usage;
  Cmd := ParamStr(1);
  K := 1;
  while K < ParamCount do
  begin
    Inc(K);
    A := ParamStr(K);
    if A = '--server' then
      Server := Next
    else if A = '--filter' then
    begin
      SetLength(Filters, Length(Filters) + 1);
      Filters[High(Filters)] := Next;
    end
    else if A = '--jobs' then
    begin
      Jobs := StrToIntDef(Next, 0);
      if Jobs < 1 then
      begin
        WriteLn(StdErr, '--jobs needs a number >= 1');
        Usage;
      end;
    end
    else if (A = '-v') or (A = '--verbose') then
      Verbose := True
    else if (A = '-h') or (A = '--help') then
      Usage
    else if (A <> '') and (A[1] = '-') then
    begin
      WriteLn(StdErr, 'unknown option ', A);
      Usage;
    end
    else
    begin
      SetLength(Paths, Length(Paths) + 1);
      Paths[High(Paths)] := A;
    end;
  end;
  if (Cmd <> 'selftest') and (Length(Paths) = 0) then
    Usage;
end;

procedure CollectFiles(const P: RawByteString; Out_: TStringList);
var
  Sr: TSearchRec;
  Entries: TStringList;
  K: Integer;
  E: RawByteString;
begin
  if DirectoryExists(P) then
  begin
    Entries := TStringList.Create;
    try
      if FindFirst(IncludeTrailingPathDelimiter(P) + '*', faAnyFile, Sr) = 0 then
      begin
        repeat
          if (Sr.Name <> '.') and (Sr.Name <> '..') then
            Entries.Add(IncludeTrailingPathDelimiter(P) + Sr.Name);
        until FindNext(Sr) <> 0;
        FindClose(Sr);
      end;
      Entries.UseLocale := False;
      Entries.CaseSensitive := True;
      Entries.Sort;
      for K := 0 to Entries.Count - 1 do
      begin
        E := Entries[K];
        if DirectoryExists(E) or (ExtractFileExt(E) = '.json') then
          CollectFiles(E, Out_);
      end;
    finally
      Entries.Free;
    end;
  end
  else
    Out_.Add(P);
end;

function ReadFileBytes(const Path: RawByteString): RawByteString;
var
  F: TFileStream;
begin
  F := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Result, F.Size);
    if F.Size > 0 then
      F.ReadBuffer(Result[1], F.Size);
  finally
    F.Free;
  end;
end;

procedure LoadCases;
var
  Files: TStringList;
  K, I, J: Integer;
  F, Stem, Name, Full: RawByteString;
  Doc, Arr, C: TJValue;
  Seen: TStringList;
  Keep: Boolean;
  L: TLoaded;
begin
  Files := TStringList.Create;
  try
    for K := 0 to High(Paths) do
      CollectFiles(Paths[K], Files);
    for K := 0 to Files.Count - 1 do
    begin
      F := Files[K];
      Stem := ChangeFileExt(ExtractFileName(F), '');
      try
        Doc := ParseJson(ReadFileBytes(F));
      except
        on E: EJsonError do
        begin
          WriteLn(StdErr, F, ': invalid JSON: ', E.Message);
          Halt(2);
        end;
        on E: Exception do
        begin
          WriteLn(StdErr, 'cannot read ', F, ': ', E.Message);
          Halt(2);
        end;
      end;
      SetLength(Docs, Length(Docs) + 1);
      Docs[High(Docs)] := Doc;
      Arr := Doc.Get('cases');
      if (Arr = nil) or (Arr.Kind <> jkArr) then
      begin
        WriteLn(StdErr, F, ': expected an object with a "cases" array');
        Halt(2);
      end;
      Seen := TStringList.Create;
      try
        for I := 0 to High(Arr.Items) do
        begin
          C := Arr.Items[I];
          Name := GetStr(C, 'name', '#' + IntToStr(I));
          Full := F + '::' + Name;
          Keep := Length(Filters) = 0;
          for J := 0 to High(Filters) do
            if Pos(Filters[J], Full) > 0 then
              Keep := True;
          if not Keep then
            Continue;
          L := Default(TLoaded);
          L.Id := Stem + '::' + Name;
          L.Case_ := C;
          try
            ValidateCase(C);
          except
            on E: ECase do
              L.Invalid := E.Message;
          end;
          if Seen.IndexOf(Name) >= 0 then
            L.Invalid := Format('duplicate case name %s in %s', [JsonStr(Name), F])
          else
            Seen.Add(Name);
          SetLength(Cases, Length(Cases) + 1);
          Cases[High(Cases)] := L;
        end;
      finally
        Seen.Free;
      end;
    end;
  finally
    Files.Free;
  end;
end;

function PendingReason(C: TJValue; out Reason: RawByteString): Boolean;
var
  P: TJValue;
begin
  P := C.Get('pending');
  Reason := '';
  if (P = nil) or (P.Kind = jkNull) or ((P.Kind = jkBool) and not P.B) then
    Exit(False);
  if P.Kind = jkStr then
    Reason := P.S
  else
    Reason := JsonText(P);
  Result := True;
end;

{ ---- run ---- }

type
  TOutcome = (ocPassed, ocFailed, ocPending);

  TResult = record
    Outcome: TOutcome;
    Text: RawByteString;
    Done: Boolean;
  end;

var
  Results: array of TResult;
  NextIndex: LongInt = 0;
  DoneEvent: PRTLEvent;

function RunOne(I: Integer): TResult;
var
  L: TLoaded;
  Reason, Err, Tail: RawByteString;
  R: TCaseResult;
  K: Integer;
  Lines: TStringList;
begin
  L := Cases[I];
  Result := Default(TResult);
  if L.Invalid <> '' then
  begin
    Result.Outcome := ocFailed;
    Result.Text := Format('FAIL %s (invalid case)'#10'    %s'#10, [L.Id, L.Invalid]);
    Exit;
  end;
  if PendingReason(L.Case_, Reason) then
  begin
    Result.Outcome := ocPending;
    Result.Text := Format('PEND %s: %s'#10, [L.Id, Reason]);
    Exit;
  end;
  R := RunCase(L.Case_, Server, Verbose);
  if Length(R.Failures) = 0 then
  begin
    Result.Outcome := ocPassed;
    Result.Text := Format('PASS %s (%d ms)'#10, [L.Id, R.ElapsedMs]);
    if Verbose then
      for K := 0 to High(R.Events) do
        Result.Text := Result.Text + '      ' + R.Events[K] + #10;
    Exit;
  end;
  Result.Outcome := ocFailed;
  Result.Text := Format('FAIL %s (%d ms)'#10, [L.Id, R.ElapsedMs]);
  for K := 0 to High(R.Failures) do
    Result.Text := Result.Text + '    ' + R.Failures[K] + #10;
  Result.Text := Result.Text + '    server events:'#10;
  for K := 0 to High(R.Events) do
    Result.Text := Result.Text + '      ' + R.Events[K] + #10;
  Err := Trim(R.Stderr);
  if Err <> '' then
  begin
    Result.Text := Result.Text + '    server stderr (last 2000 bytes):'#10;
    if Length(Err) > 2000 then
      Tail := Copy(Err, Length(Err) - 1999, 2000)
    else
      Tail := Err;
    Lines := TStringList.Create;
    try
      Lines.Text := Tail;
      for K := 0 to Lines.Count - 1 do
        Result.Text := Result.Text + '      ' + Lines[K] + #10;
    finally
      Lines.Free;
    end;
  end;
end;

type
  TWorker = class(TThread)
  protected
    procedure Execute; override;
  end;

procedure TWorker.Execute;
var
  I: LongInt;
  R: TResult;
begin
  while True do
  begin
    I := InterLockedIncrement(NextIndex) - 1;
    if I >= Length(Cases) then
      Break;
    try
      R := RunOne(I);
    except
      on E: Exception do
      begin
        R := Default(TResult);
        R.Outcome := ocFailed;
        R.Text := Format('FAIL %s (runner error)'#10'    %s: %s'#10, [Cases[I].Id, E.ClassName, E.Message]);
      end;
    end;
    Results[I].Outcome := R.Outcome;
    Results[I].Text := R.Text;
    WriteBarrier;
    Results[I].Done := True;
    RTLEventSetEvent(DoneEvent);
  end;
end;

function CmdRun: Integer;
var
  Workers: array of TWorker;
  K, Want, N: Integer;
  Passed, Failed, Pending: Integer;
begin
  if Server = '' then
  begin
    WriteLn(StdErr, 'run needs --server CMD');
    Usage;
  end;
  LoadCases;
  N := Length(Cases);
  SetLength(Results, N);
  DoneEvent := RTLEventCreate;
  if Jobs > N then
    Jobs := N;
  SetLength(Workers, Jobs);
  for K := 0 to Jobs - 1 do
    Workers[K] := TWorker.Create(False);
  Passed := 0;
  Failed := 0;
  Pending := 0;
  for Want := 0 to N - 1 do
  begin
    while not Results[Want].Done do
      RTLEventWaitFor(DoneEvent, 100);
    ReadBarrier;
    case Results[Want].Outcome of
      ocPassed: Inc(Passed);
      ocFailed: Inc(Failed);
      ocPending: Inc(Pending);
    end;
    Write(Results[Want].Text);
    Flush(Output);
  end;
  for K := 0 to High(Workers) do
  begin
    Workers[K].WaitFor;
    Workers[K].Free;
  end;
  RTLEventDestroy(DoneEvent);
  WriteLn(Format('SUMMARY passed=%d failed=%d pending=%d total=%d', [Passed, Failed, Pending, N]));
  if Failed > 0 then
    Result := 1
  else
    Result := 0;
end;

function CmdList: Integer;
var
  K: Integer;
  Tag, Reason: RawByteString;
begin
  LoadCases;
  for K := 0 to High(Cases) do
  begin
    if Cases[K].Invalid <> '' then
      Tag := 'INVALID'
    else if PendingReason(Cases[K].Case_, Reason) then
      Tag := 'PEND'
    else
      Tag := 'CASE';
    WriteLn(Tag, ' ', Cases[K].Id, ' ', GetStr(Cases[K].Case_, 'source'));
    if Cases[K].Invalid <> '' then
      WriteLn('    ', Cases[K].Invalid);
  end;
  Result := 0;
end;

{ ---- selftest ---- }

var
  SelfFailures: Integer = 0;

procedure Expect(Ok: Boolean; const What: string);
begin
  if not Ok then
  begin
    Inc(SelfFailures);
    WriteLn('selftest FAIL: ', What);
  end;
end;

function CheckFails(const Assertion, Subject: RawByteString): Boolean;
var
  A: TJValue;
  Cap: TCapture;
begin
  A := ParseJson(Assertion);
  Cap := Default(TCapture);
  Cap.Raw := Subject;
  Cap.Norm := Subject;
  try
    try
      Check(A, Cap, nil);
      Result := False;
    except
      on ECase do
        Result := True;
    end;
  finally
    A.Free;
  end;
end;

function CmdSelftest: Integer;
var
  V: TJValue;
  Vars: TVars;
  S: RawByteString;
const
  DATE = 'Wed, 04 Nov 2026 19:22:45 GMT';
begin
  { JSON (fpjson): \u escapes and raw UTF-8 as UTF-8 bytes, control
    characters kept, key order, number classes; \u0000 refused }
  V := ParseJson('{"z":1,"a":"x\u00ff\u0001/y\ud83d\ude00'#$C3#$A9'","n":-2,"f":1.0,"b":[true,null]}');
  try
    Expect(V.Keys[0] = 'z', 'json key order');
    Expect(GetStr(V, 'a') = 'x'#$C3#$BF#1'/y'#$F0#$9F#$98#$80#$C3#$A9, 'json string bytes');
    Expect(not JsonEqual(V.Get('z'), V.Get('f')), 'json 1 <> 1.0');
    Expect(V.Get('n').NumClass = ncNegInt, 'json negative integer');
    Expect(JsonStr(GetStr(V, 'a')) = '"x'#$C3#$BF'\u0001/y'#$F0#$9F#$98#$80#$C3#$A9'"', 'json text');
  finally
    V.Free;
  end;
  try
    ParseJson('{"a":"x\u0000"}').Free;
    Expect(False, 'NUL escape must be refused');
  except
    on EJsonError do ;
  end;
  V := ParseJson('"a\\u0000"');     { an escaped backslash, then u0000: no NUL }
  try
    Expect(V.S = 'a\u0000', 'escaped backslash before u0000');
  finally
    V.Free;
  end;
  { byte strings }
  Vars := nil;
  SetVar(Vars, 'port', '8080');
  V := ParseJson('["h:${port} $${port} $x", {"repeat": "ab", "count": 2}, {"hex": "00 ff"}, "é"]');
  try
    Expect(DecodeBytes(V, Vars) = 'h:8080 ${port} $x' + 'abab' + #0#$FF + #$E9, 'decode bytes');
  finally
    V.Free;
  end;
  V := ParseJson('"Ā"');
  try
    try
      DecodeBytes(V, Vars);
      Expect(False, 'code point above U+00FF must fail');
    except
      on ECase do ;
    end;
  finally
    V.Free;
  end;
  Expect(Latin1(#$E9#$FF'a') = #$C3#$A9#$C3#$BF'a', 'latin1');
  { date normalization }
  S := 'HTTP/1.1 200 OK'#13#10'Date: ' + DATE + #13#10'date:'#9 + LowerCase(DATE) + #13#10'x-date: ' + DATE + #13#10;
  Expect(Normalize(S) = 'HTTP/1.1 200 OK'#13#10'Date: ' + CANONICAL_DATE + #13#10'date:'#9 + CANONICAL_DATE +
    #13#10'x-date: ' + DATE + #13#10, 'normalize date');
  Expect(Normalize(#13#10'date: Wed, 4 Nov 2026 19:22:45 GMT') = #13#10'date: Wed, 4 Nov 2026 19:22:45 GMT', 'normalize keeps a non-fixdate');
  { utf8 }
  Expect(IsValidUtf8('ok'#$C3#$A9#10'x'#$F0#$9F#$98#$80), 'utf8: valid');
  Expect(not IsValidUtf8('ok'#$FF), 'utf8: invalid byte');
  Expect(not IsValidUtf8(#$ED#$A0#$80), 'utf8: surrogate');
  Expect(not IsValidUtf8(#$C0#$80), 'utf8: overlong');
  Expect(not IsValidUtf8(#$E2#$82), 'utf8: truncated');
  Expect(not IsValidUtf8(#$F4#$90#$80#$80), 'utf8: above U+10FFFF');
  Expect(not CheckFails('{"utf8": true}', 'a'#$C3#$A9) and CheckFails('{"utf8": true}', 'a'#$E9), 'utf8 assertion');
  Expect(not CheckFails('{"utf8": false}', #$E9) and CheckFails('{"utf8": false}', 'a'), 'utf8 false');
  { assertions }
  Expect(CheckFails('{"regex": "a"}', 'a') and CheckFails('{"not_regex": "a"}', 'b'), 'regex is refused');
  Expect(not CheckFails('{"equals": "b\r\nfoo", "ci": true}', 'B'#13#10'foo') and
    CheckFails('{"equals": "b\r\nfoo"}', 'B'#13#10'foo'), 'equals, ci');
  Expect(not CheckFails('{"equals": [{"repeat": "x", "count": 3}]}', 'xxx') and
    CheckFails('{"equals": [{"repeat": "x", "count": 3}]}', 'xxy'), 'equals repeat');
  Expect(CheckFails('{"len": 0}', 'a') and not CheckFails('{"len": 0}', ''), 'len');
  Expect(CheckFails('{"starts_with": "ab"}', 'a') and CheckFails('{"ends_with": "b", "x": 1}', 'b'), 'starts_with, unknown key');
  if SelfFailures = 0 then
  begin
    WriteLn('selftest: passed');
    Result := 0;
  end
  else
  begin
    WriteLn('selftest: ', SelfFailures, ' failed');
    Result := 1;
  end;
end;

var
  Code, K: Integer;
begin
  DefaultSystemCodePage := CP_UTF8;
  { a write to a server that already exited must fail, not kill the runner }
  fpSignal(SIGPIPE, SignalHandler(SIG_IGN));
  ParseArgs;
  if Cmd = 'run' then
    Code := CmdRun
  else if Cmd = 'list' then
    Code := CmdList
  else if Cmd = 'selftest' then
    Code := CmdSelftest
  else
  begin
    Usage;
    Code := 2;
  end;
  for K := 0 to High(Docs) do
    Docs[K].Free;
  Halt(Code);
end.

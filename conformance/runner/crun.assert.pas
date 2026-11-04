{ crun.assert - capture normalization, step assertions and event patterns
  (SPEC.md sections 10, 11 and 12).

  Normalize replaces the value of every date field that is an IMF-fixdate
  (CRLF "date:" [SP/HTAB]* "Sun, 06 Nov 1994 08:49:37 GMT", the field name,
  the day and month names and GMT in any case) with CANONICAL_DATE, which
  has the same length.

  Test tooling only. }
unit crun.assert;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, crun.bytes, crun.json, crun.conn, crun.response;

const
  CANONICAL_DATE = 'Sun, 06 Nov 1994 08:49:37 GMT';

type
  TCapture = record
    Raw, Norm: RawByteString;
    End_: TEnd;
    HasResp: Boolean;
    Resp: TParsed;
    ReadResult: RawByteString;       { read_once only; '' otherwise }
  end;

function Normalize(const B: RawByteString): RawByteString;
{ one assertion of a step; raises ECase with the failure }
procedure Check(A: TJValue; const Cap: TCapture; const Vars: TVars);
{ an event (or any value; Act = nil: absent) against a pattern; raises
  ECase on a bad pattern }
function Matches(Pat, Act: TJValue; const Vars: TVars): Boolean;

implementation

const
  BYTE_KINDS: array[0..8] of RawByteString = ('equals', 'starts_with', 'ends_with', 'contains',
    'not_contains', 'len', 'min_len', 'max_len', 'utf8');
  OTHER_KINDS: array[0..8] of RawByteString = ('end', 'read_result', 'status', 'reason', 'version',
    'framing', 'header', 'trailer', 'body');
  READ_RESULTS: array[0..3] of RawByteString = ('data', 'eof', 'reset', 'timeout');
  DAYS: array[0..6] of RawByteString = ('mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun');
  MONTHS: array[0..11] of RawByteString = ('jan', 'feb', 'mar', 'apr', 'may', 'jun', 'jul', 'aug',
    'sep', 'oct', 'nov', 'dec');

{ ---- normalization ---- }

function IsDigitAt(const S: RawByteString; P: SizeInt): Boolean;
begin
  Result := (P <= Length(S)) and (S[P] in ['0'..'9']);
end;

{ the length of an IMF-fixdate at S[P] (29), or 0 }
function FixdateAt(const S: RawByteString; P: SizeInt): SizeInt;
var
  L: RawByteString;
begin
  Result := 0;
  if P + 28 > Length(S) then
    Exit;
  L := LowerAscii(Copy(S, P, 29));
  if not InList(Copy(L, 1, 3), DAYS) or (Copy(L, 4, 2) <> ', ') then Exit;
  if not (IsDigitAt(L, 6) and IsDigitAt(L, 7)) or (L[8] <> ' ') then Exit;
  if not InList(Copy(L, 9, 3), MONTHS) or (L[12] <> ' ') then Exit;
  if not (IsDigitAt(L, 13) and IsDigitAt(L, 14) and IsDigitAt(L, 15) and IsDigitAt(L, 16)) then Exit;
  if L[17] <> ' ' then Exit;
  if not (IsDigitAt(L, 18) and IsDigitAt(L, 19)) or (L[20] <> ':') then Exit;
  if not (IsDigitAt(L, 21) and IsDigitAt(L, 22)) or (L[23] <> ':') then Exit;
  if not (IsDigitAt(L, 24) and IsDigitAt(L, 25)) or (Copy(L, 26, 4) <> ' gmt') then Exit;
  Result := 29;
end;

function Normalize(const B: RawByteString): RawByteString;
var
  K, V, N: SizeInt;
begin
  Result := '';
  K := 1;
  N := Length(B);
  while K <= N do
  begin
    if (B[K] = #13) and (K + 6 <= N) and (B[K + 1] = #10) and (LowerAscii(Copy(B, K + 2, 5)) = 'date:') then
    begin
      V := K + 7;
      while (V <= N) and (B[V] in [' ', #9]) do
        Inc(V);
      if FixdateAt(B, V) > 0 then
      begin
        Result := Result + Copy(B, K, V - K) + CANONICAL_DATE;
        K := V + 29;
        Continue;
      end;
    end;
    Result := Result + B[K];
    Inc(K);
  end;
end;

{ ---- step assertions ---- }

procedure NeedResp(const Cap: TCapture; const Kind: RawByteString);
begin
  if not Cap.HasResp then
    raise ECase.CreateFmt('assertion %s is only valid on a read_response step', [JsonStr(Kind)]);
end;

function StrList(const L: array of RawByteString): RawByteString;
var
  K: Integer;
begin
  Result := '[';
  for K := 0 to High(L) do
  begin
    if K > 0 then
      Result := Result + ', ';
    Result := Result + JsonStr(L[K]);
  end;
  Result := Result + ']';
end;

procedure CheckSimple(const Kind: RawByteString; V, M: TJValue; const Cap: TCapture; const Vars: TVars);
var
  Want, Base, Subject, Where, S, W: RawByteString;
  Wants: array of RawByteString;
  K: Integer;
  N: QWord;
  Ok, Ci: Boolean;
  P: SizeInt;
  Scope: RawByteString;
begin
  if Kind = 'end' then
  begin
    if V.Kind <> jkStr then
      raise ECase.Create('end: expected a string');
    Want := V.S;
    if Want = 'eof' then Ok := Cap.End_ = endEof
    else if Want = 'reset' then Ok := Cap.End_ = endReset
    else if Want = 'open' then Ok := Cap.End_ = endOpen
    else if Want = 'closed' then Ok := Cap.End_ <> endOpen
    else
      raise ECase.CreateFmt('end: unknown value %s', [JsonStr(Want)]);
    if not Ok then
      raise ECase.CreateFmt('expected end %s, connection state is %s', [JsonStr(Want), JsonStr(EndName(Cap.End_))]);
    Exit;
  end;
  if Kind = 'read_result' then
  begin
    if Cap.ReadResult = '' then
      raise ECase.Create('assertion "read_result" is only valid on a read_once step');
    Wants := nil;
    if V.Kind = jkStr then
    begin
      SetLength(Wants, 1);
      Wants[0] := V.S;
    end
    else if V.Kind = jkArr then
      for K := 0 to High(V.Items) do
      begin
        if V.Items[K].Kind <> jkStr then
          raise ECase.Create('read_result: expected a string or an array of strings');
        SetLength(Wants, Length(Wants) + 1);
        Wants[High(Wants)] := V.Items[K].S;
      end
    else
      raise ECase.Create('read_result: expected a string or an array of strings');
    if Length(Wants) = 0 then
      raise ECase.Create('read_result: the array must not be empty');
    for K := 0 to High(Wants) do
      if not InList(Wants[K], READ_RESULTS) then
        raise ECase.CreateFmt('read_result: unknown value %s (expected one of %s)',
          [JsonStr(Wants[K]), StrList(READ_RESULTS)]);
    if not InList(Cap.ReadResult, Wants) then
      raise ECase.CreateFmt('expected read_result in %s, got %s', [StrList(Wants), JsonStr(Cap.ReadResult)]);
    Exit;
  end;
  if Kind = 'status' then
  begin
    NeedResp(Cap, Kind);
    if not V.AsU64(N) then
      raise ECase.Create('status: expected an integer');
    if QWord(Cap.Resp.Status) <> N then
      raise ECase.CreateFmt('expected status %d, got %d', [N, Cap.Resp.Status]);
    Exit;
  end;
  if Kind = 'reason' then
  begin
    NeedResp(Cap, Kind);
    Want := DecodeBytes(V, Vars);
    if Cap.Resp.Reason <> Want then
      raise ECase.CreateFmt('expected reason %s, got %s', [Show(Want, 200), Show(Cap.Resp.Reason, 200)]);
    Exit;
  end;
  if Kind = 'version' then
  begin
    NeedResp(Cap, Kind);
    if V.Kind <> jkStr then
      raise ECase.Create('version: expected a string');
    if Cap.Resp.Version <> V.S then
      raise ECase.CreateFmt('expected version %s, got %s', [JsonStr(V.S), JsonStr(Cap.Resp.Version)]);
    Exit;
  end;
  if Kind = 'framing' then
  begin
    NeedResp(Cap, Kind);
    if V.Kind <> jkStr then
      raise ECase.Create('framing: expected a string');
    if Cap.Resp.Framing <> V.S then
      raise ECase.CreateFmt('expected framing %s, got %s', [JsonStr(V.S), JsonStr(Cap.Resp.Framing)]);
    Exit;
  end;
  if Kind = 'body' then
  begin
    NeedResp(Cap, Kind);
    Want := DecodeBytes(V, Vars);
    if Cap.Resp.Body <> Want then
      raise ECase.CreateFmt('expected decoded body %s, got %s', [Show(Want, 400), Show(Cap.Resp.Body, 400)]);
    Exit;
  end;

  { the byte kinds, on the selected scope }
  if GetBool(M, 'raw') then
    Base := Cap.Raw
  else
    Base := Cap.Norm;
  Scope := GetStr(M, 'scope', 'all');
  if Scope = 'all' then
    Subject := Base
  else if Scope = 'head' then
  begin
    P := FindBytes(Base, #13#10#13#10);
    if P >= 0 then
      Subject := Copy(Base, 1, P)
    else
      Subject := Base;
  end
  else if Scope = 'after_head' then
  begin
    P := FindBytes(Base, #13#10#13#10);
    if P >= 0 then
      Subject := Copy(Base, P + 5, MaxInt)
    else
      Subject := '';
  end
  else if Scope = 'body' then
  begin
    NeedResp(Cap, 'scope body');
    Subject := Cap.Resp.Body;
  end
  else
    raise ECase.CreateFmt('unknown scope %s', [JsonStr(Scope)]);
  Ci := GetBool(M, 'ci');
  if Scope = 'all' then
    Where := ''
  else
    Where := ' (scope ' + Scope + ')';

  if (Kind = 'len') or (Kind = 'min_len') or (Kind = 'max_len') then
  begin
    if not V.AsU64(N) then
      raise ECase.CreateFmt('%s: expected an integer', [Kind]);
    if Kind = 'len' then Ok := QWord(Length(Subject)) = N
    else if Kind = 'min_len' then Ok := QWord(Length(Subject)) >= N
    else Ok := QWord(Length(Subject)) <= N;
    if not Ok then
      raise ECase.CreateFmt('expected %s %d%s, got length %d: %s', [Kind, N, Where, Length(Subject), Show(Subject, 300)]);
    Exit;
  end;
  if Kind = 'utf8' then
  begin
    if V.Kind <> jkBool then
      raise ECase.Create('utf8: expected a boolean');
    if IsValidUtf8(Subject) <> V.B then
    begin
      if V.B then W := 'valid' else W := 'invalid';
      raise ECase.CreateFmt('expected %s UTF-8%s, got %s', [W, Where, Show(Subject, 600)]);
    end;
    Exit;
  end;
  Want := DecodeBytes(V, Vars);
  if Ci then
  begin
    S := LowerAscii(Subject);
    W := LowerAscii(Want);
  end
  else
  begin
    S := Subject;
    W := Want;
  end;
  if Kind = 'equals' then Ok := S = W
  else if Kind = 'starts_with' then Ok := StartsWith(S, W)
  else if Kind = 'ends_with' then Ok := EndsWith(S, W)
  else if Kind = 'contains' then Ok := FindBytes(S, W) >= 0
  else Ok := FindBytes(S, W) < 0;
  if not Ok then
  begin
    if Ci then W := ' (case-insensitive)' else W := '';
    raise ECase.CreateFmt('expected %s %s%s%s, got %s', [Kind, Show(Want, 300), Where, W, Show(Subject, 800)]);
  end;
end;

procedure CheckField(const Kind: RawByteString; M: TJValue; const Cap: TCapture; const Vars: TVars);
var
  NameV, X: TJValue;
  Name, Want: RawByteString;
  Vals, All: TFields;
  Checked: Boolean;
  N: QWord;
  K: Integer;
  Wants, Got: RawByteString;
  Same: Boolean;
begin
  CheckKeys(M, [Kind, 'value', 'values', 'present', 'count', 'comment']);
  NeedResp(Cap, Kind);
  NameV := M.Get(Kind);
  if NameV.Kind <> jkStr then
    raise ECase.CreateFmt('%s: expected a field name string', [Kind]);
  Name := NameV.S;
  if Kind = 'header' then
    All := Cap.Resp.Headers
  else
    All := Cap.Resp.Trailers;
  Vals := FieldValues(All, Name);
  Checked := False;
  X := M.Get('present');
  if X <> nil then
  begin
    Checked := True;
    if X.Kind <> jkBool then
      raise ECase.Create('present: expected a boolean');
    if X.B <> (Length(Vals) > 0) then
    begin
      if X.B then Want := 'present' else Want := 'absent';
      raise ECase.CreateFmt('expected %s %s to be %s; fields: %s', [Kind, JsonStr(Name), Want, FieldsShow(All)]);
    end;
  end;
  X := M.Get('count');
  if X <> nil then
  begin
    Checked := True;
    if not X.AsU64(N) then
      raise ECase.Create('count: expected an integer');
    if QWord(Length(Vals)) <> N then
      raise ECase.CreateFmt('expected %d %s field(s) %s, found %d', [N, Kind, JsonStr(Name), Length(Vals)]);
  end;
  X := M.Get('value');
  if X <> nil then
  begin
    Checked := True;
    Want := DecodeBytes(X, Vars);
    if Length(Vals) = 0 then
      raise ECase.CreateFmt('expected %s %s = %s, field absent', [Kind, JsonStr(Name), Show(Want, 200)]);
    if Vals[0].Value <> Want then
      raise ECase.CreateFmt('expected %s %s = %s, got %s', [Kind, JsonStr(Name), Show(Want, 200), Show(Vals[0].Value, 200)]);
  end;
  X := M.Get('values');
  if X <> nil then
  begin
    Checked := True;
    if X.Kind <> jkArr then
      raise ECase.Create('values: expected an array');
    Same := Length(X.Items) = Length(Vals);
    Wants := '[';
    for K := 0 to High(X.Items) do
    begin
      Want := DecodeBytes(X.Items[K], Vars);
      if K > 0 then Wants := Wants + ', ';
      Wants := Wants + JsonStr(Latin1(Want));
      if Same and (Vals[K].Value <> Want) then
        Same := False;
    end;
    Wants := Wants + ']';
    if not Same then
    begin
      Got := '[';
      for K := 0 to High(Vals) do
      begin
        if K > 0 then Got := Got + ', ';
        Got := Got + JsonStr(Latin1(Vals[K].Value));
      end;
      Got := Got + ']';
      raise ECase.CreateFmt('expected %s %s values %s, got %s', [Kind, JsonStr(Name), Wants, Got]);
    end;
  end;
  if not Checked then
    raise ECase.CreateFmt('%s assertion needs one of value, values, present, count', [Kind]);
end;

procedure Check(A: TJValue; const Cap: TCapture; const Vars: TVars);
var
  Kinds: array of RawByteString;
  K: Integer;
  Kind: RawByteString;
begin
  if A.Kind <> jkObj then
    raise ECase.CreateFmt('assertion must be an object: %s', [JsonText(A)]);
  if A.Has('regex') or A.Has('not_regex') then
    raise ECase.Create('regex assertions are not supported (SPEC.md section 10: use the byte kinds or utf8)');
  Kinds := nil;
  for K := 0 to High(A.Keys) do
    if InList(A.Keys[K], BYTE_KINDS) or InList(A.Keys[K], OTHER_KINDS) then
    begin
      SetLength(Kinds, Length(Kinds) + 1);
      Kinds[High(Kinds)] := A.Keys[K];
    end;
  if Length(Kinds) <> 1 then
    raise ECase.CreateFmt('assertion needs exactly one kind key, found %s', [JsonText(A)]);
  Kind := Kinds[0];
  if (Kind = 'header') or (Kind = 'trailer') then
    CheckField(Kind, A, Cap, Vars)
  else
  begin
    CheckKeys(A, ['scope', 'ci', 'raw', 'comment', Kind]);
    CheckSimple(Kind, A.Get(Kind), A, Cap, Vars);
  end;
end;

{ ---- event patterns ---- }

function MatchOp(const Op: RawByteString; Arg, Act: TJValue; const Vars: TVars): Boolean;
var
  Want: RawByteString;
  K, J: Integer;
  Found: Boolean;
begin
  if Op = '$absent' then
    Exit(Act = nil);
  if Op = '$any' then
    Exit(Act <> nil);
  if Op = '$not' then
    Exit(not Matches(Arg, Act, Vars));
  if Op = '$bytes' then
  begin
    Want := Latin1(DecodeBytes(Arg, Vars));
    Exit((Act <> nil) and (Act.Kind = jkStr) and (Act.S = Want));
  end;
  if Op = '$contains' then
  begin
    Want := Latin1(DecodeBytes(Arg, Vars));
    Exit((Act <> nil) and (Act.Kind = jkStr) and (FindBytes(Act.S, Want) >= 0));
  end;
  if Op = '$includes' then
  begin
    if Arg.Kind <> jkArr then
      raise ECase.Create('$includes: expected an array');
    if (Act = nil) or (Act.Kind <> jkArr) then
      Exit(False);
    for K := 0 to High(Arg.Items) do
    begin
      Found := False;
      for J := 0 to High(Act.Items) do
        if Matches(Arg.Items[K], Act.Items[J], Vars) then
        begin
          Found := True;
          Break;
        end;
      if not Found then
        Exit(False);
    end;
    Exit(True);
  end;
  raise ECase.CreateFmt('unknown pattern operator %s', [Op]);
end;

function Matches(Pat, Act: TJValue; const Vars: TVars): Boolean;
var
  K: Integer;
begin
  if Pat.Kind = jkObj then
  begin
    if (Length(Pat.Keys) = 1) and (Copy(Pat.Keys[0], 1, 1) = '$') then
      Exit(MatchOp(Pat.Keys[0], Pat.Items[0], Act, Vars));
    if (Act = nil) or (Act.Kind <> jkObj) then
      Exit(False);
    for K := 0 to High(Pat.Keys) do
      if not Matches(Pat.Items[K], Act.Get(Pat.Keys[K]), Vars) then
        Exit(False);
    Exit(True);
  end;
  if Act = nil then
    Exit(False);
  if (Pat.Kind = jkStr) and (Act.Kind = jkStr) then
    Exit(Substitute(Pat.S, Vars, True) = Act.S);
  if (Pat.Kind = jkArr) and (Act.Kind = jkArr) then
  begin
    if Length(Pat.Items) <> Length(Act.Items) then
      Exit(False);
    for K := 0 to High(Pat.Items) do
      if not Matches(Pat.Items[K], Act.Items[K], Vars) then
        Exit(False);
    Exit(True);
  end;
  Result := JsonEqual(Pat, Act);
end;

end.

{ crun.bytes - the byte strings of the conformance cases (SPEC.md section
  2): the latin-1 mapping between bytes and JSON strings, the substitution
  of variables (dollar, brace, name, brace), the "bytes spec" (a string, or parts with "repeat" and
  "hex"), the allowed-keys check and the escaped display of bytes used in
  failure messages.

  Errors are raised as ECase with the message the runner prints.

  Test tooling only. }
unit crun.bytes;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, crun.json;

type
  ECase = class(Exception);

  TVar = record
    Name, Value: RawByteString;
  end;
  TVars = array of TVar;

procedure SetVar(var Vars: TVars; const Name, Value: RawByteString);
function FindVar(const Vars: TVars; const Name: RawByteString; out Value: RawByteString): Boolean;

{ every byte as the code point of the same value, in UTF-8 }
function Latin1(const Bytes: RawByteString): RawByteString;
{ the inverse: every code point must be <= U+00FF }
function FromLatin1(const S: RawByteString): RawByteString;
// a variable reference (dollar, brace, name, brace) -> its value; a doubled
// dollar before a brace -> one dollar; Enabled = False: no substitution
function Substitute(const S: RawByteString; Vars: TVars; Enabled: Boolean): RawByteString;
{ a bytes spec: a JSON string, an array of parts, or one part object }
function DecodeBytes(V: TJValue; const Vars: TVars; WithVars: Boolean = True): RawByteString;
{ raises when O has a key outside Allowed }
procedure CheckKeys(O: TJValue; const Allowed: array of RawByteString);
function InList(const S: RawByteString; const List: array of RawByteString): Boolean;
{ the bytes in quotes, with \r \n \t \\ \" and \xNN escapes, at most Limit
  bytes then "... (N bytes total)" }
function Show(const B: RawByteString; Limit: SizeInt): RawByteString;
function LowerAscii(const B: RawByteString): RawByteString;
{ valid UTF-8 as Rust's str::from_utf8 accepts it: no overlong forms, no
  surrogates, nothing above U+10FFFF }
function IsValidUtf8(const B: RawByteString): Boolean;
function StartsWith(const S, Prefix: RawByteString): Boolean;
function EndsWith(const S, Suffix: RawByteString): Boolean;
{ 0-based offset of Needle in Hay at or after From, or -1; an empty Needle is found at From }
function FindBytes(const Hay, Needle: RawByteString; From: SizeInt = 0): SizeInt;

implementation

procedure SetVar(var Vars: TVars; const Name, Value: RawByteString);
var
  K: Integer;
begin
  for K := 0 to High(Vars) do
    if Vars[K].Name = Name then
    begin
      Vars[K].Value := Value;
      Exit;
    end;
  SetLength(Vars, Length(Vars) + 1);
  Vars[High(Vars)].Name := Name;
  Vars[High(Vars)].Value := Value;
end;

function FindVar(const Vars: TVars; const Name: RawByteString; out Value: RawByteString): Boolean;
var
  K: Integer;
begin
  for K := 0 to High(Vars) do
    if Vars[K].Name = Name then
    begin
      Value := Vars[K].Value;
      Exit(True);
    end;
  Value := '';
  Result := False;
end;

function Latin1(const Bytes: RawByteString): RawByteString;
var
  K: SizeInt;
  C: Byte;
begin
  Result := '';
  for K := 1 to Length(Bytes) do
  begin
    C := Ord(Bytes[K]);
    if C < $80 then
      Result := Result + AnsiChar(C)
    else
      Result := Result + AnsiChar($C0 or (C shr 6)) + AnsiChar($80 or (C and $3F));
  end;
end;

function FromLatin1(const S: RawByteString): RawByteString;
var
  K, N: SizeInt;
  C: Byte;
  Cp: Cardinal;
begin
  Result := '';
  K := 1;
  N := Length(S);
  while K <= N do
  begin
    C := Ord(S[K]);
    if C < $80 then
    begin
      Result := Result + AnsiChar(C);
      Inc(K);
      Continue;
    end;
    { the strings come from JSON, so they are valid UTF-8 }
    if (C and $E0) = $C0 then
    begin
      Cp := ((C and $1F) shl 6) or (Ord(S[K + 1]) and $3F);
      Inc(K, 2);
    end
    else if (C and $F0) = $E0 then
    begin
      Cp := ((C and $0F) shl 12) or ((Ord(S[K + 1]) and $3F) shl 6) or (Ord(S[K + 2]) and $3F);
      Inc(K, 3);
    end
    else
    begin
      Cp := ((C and $07) shl 18) or ((Ord(S[K + 1]) and $3F) shl 12) or
        ((Ord(S[K + 2]) and $3F) shl 6) or (Ord(S[K + 3]) and $3F);
      Inc(K, 4);
    end;
    if Cp > $FF then
      raise ECase.CreateFmt('byte string contains code point U+%.4X (> U+00FF); use \u00XX escapes for bytes', [Cp]);
    Result := Result + AnsiChar(Cp);
  end;
end;

function Substitute(const S: RawByteString; Vars: TVars; Enabled: Boolean): RawByteString;
var
  K, N, E: SizeInt;
  Name, Val: RawByteString;
begin
  if not Enabled then
    Exit(S);
  Result := '';
  K := 1;
  N := Length(S);
  while K <= N do
  begin
    if S[K] <> '$' then
    begin
      Result := Result + S[K];
      Inc(K);
      Continue;
    end;
    if (K + 2 <= N) and (S[K + 1] = '$') and (S[K + 2] = '{') then
    begin
      Result := Result + '${';
      Inc(K, 3);
    end
    else if (K + 1 <= N) and (S[K + 1] = '{') then
    begin
      E := K + 2;
      while (E <= N) and (S[E] <> '}') do
        Inc(E);
      if E > N then
        raise ECase.CreateFmt('unterminated ${...} in %s', [Show(S, 200)]);
      Name := Copy(S, K + 2, E - K - 2);
      if not FindVar(Vars, Name, Val) then
        raise ECase.CreateFmt('unknown variable ${%s} in %s', [Name, Show(S, 200)]);
      Result := Result + Val;
      K := E + 1;
    end
    else
    begin
      Result := Result + '$';
      Inc(K);
    end;
  end;
end;

function DecodeHex(const H: RawByteString): RawByteString;
var
  D: RawByteString;
  K: SizeInt;
  Hi, Lo: Integer;

  function Digit(C: AnsiChar): Integer;
  begin
    case C of
      '0'..'9': Result := Ord(C) - Ord('0');
      'a'..'f': Result := Ord(C) - Ord('a') + 10;
      'A'..'F': Result := Ord(C) - Ord('A') + 10;
    else
      raise ECase.CreateFmt('invalid hex digit ''%s''', [C]);
    end;
  end;

begin
  D := '';
  for K := 1 to Length(H) do
    if not (H[K] in [' ', #9, #10, #12, #13]) then
      D := D + H[K];
  if Odd(Length(D)) then
    raise ECase.CreateFmt('odd number of hex digits in %s', [Show(H, 200)]);
  Result := '';
  K := 1;
  while K < Length(D) do
  begin
    Hi := Digit(D[K]);
    Lo := Digit(D[K + 1]);
    Result := Result + AnsiChar(Hi shl 4 or Lo);
    Inc(K, 2);
  end;
end;

function DecodePart(P: TJValue; const Vars: TVars; WithVars: Boolean): RawByteString; forward;

function DecodeBytes(V: TJValue; const Vars: TVars; WithVars: Boolean): RawByteString;
var
  K: Integer;
begin
  case V.Kind of
    jkStr: Result := FromLatin1(Substitute(V.S, Vars, WithVars));
    jkArr:
      begin
        Result := '';
        for K := 0 to High(V.Items) do
          Result := Result + DecodePart(V.Items[K], Vars, WithVars);
      end;
    jkObj: Result := DecodePart(V, Vars, WithVars);
  else
    raise ECase.CreateFmt('expected a byte string, found %s', [JsonText(V)]);
  end;
end;

function DecodePart(P: TJValue; const Vars: TVars; WithVars: Boolean): RawByteString;
var
  Unit_: RawByteString;
  Count: QWord;
  K: QWord;
  H: TJValue;
begin
  case P.Kind of
    jkStr: Result := DecodeBytes(P, Vars, WithVars);
    jkObj:
      if P.Has('repeat') then
      begin
        CheckKeys(P, ['repeat', 'count']);
        Unit_ := DecodeBytes(P.Get('repeat'), Vars, WithVars);
        if not GetU64(P, 'count', Count) then
          raise ECase.Create('repeat part needs an integer "count"');
        Result := '';
        SetLength(Result, Length(Unit_) * Count);
        if (Count > 0) and (Length(Unit_) > 0) then
          for K := 0 to Count - 1 do
            Move(Unit_[1], Result[K * QWord(Length(Unit_)) + 1], Length(Unit_));
      end
      else if P.Has('hex') then
      begin
        CheckKeys(P, ['hex']);
        H := P.Get('hex');
        if H.Kind <> jkStr then
          raise ECase.Create('"hex" must be a string');
        Result := DecodeHex(H.S);
      end
      else
        raise ECase.CreateFmt('unknown byte-string part %s', [JsonText(P)]);
  else
    raise ECase.CreateFmt('unknown byte-string part %s', [JsonText(P)]);
  end;
end;

function InList(const S: RawByteString; const List: array of RawByteString): Boolean;
var
  K: Integer;
begin
  for K := 0 to High(List) do
    if List[K] = S then
      Exit(True);
  Result := False;
end;

procedure CheckKeys(O: TJValue; const Allowed: array of RawByteString);
var
  K, J: Integer;
  All: RawByteString;
begin
  for K := 0 to High(O.Keys) do
    if not InList(O.Keys[K], Allowed) then
    begin
      All := '';
      for J := 0 to High(Allowed) do
      begin
        if J > 0 then
          All := All + ', ';
        All := All + Allowed[J];
      end;
      raise ECase.CreateFmt('unknown field %s (allowed: %s)', [JsonStr(O.Keys[K]), All]);
    end;
end;

function Show(const B: RawByteString; Limit: SizeInt): RawByteString;
const
  HexD: array[0..15] of AnsiChar = '0123456789abcdef';
var
  K, N: SizeInt;
  C: AnsiChar;
begin
  Result := '"';
  N := Length(B);
  if N > Limit then
    N := Limit;
  for K := 1 to N do
  begin
    C := B[K];
    case C of
      #13: Result := Result + '\r';
      #10: Result := Result + '\n';
      #9: Result := Result + '\t';
      '\': Result := Result + '\\';
      '"': Result := Result + '\"';
      #$20..#$21, #$23..#$5B, #$5D..#$7E: Result := Result + C;
    else
      Result := Result + '\x' + HexD[Ord(C) shr 4] + HexD[Ord(C) and 15];
    end;
  end;
  if Length(B) > Limit then
    Result := Result + Format('... (%d bytes total)', [Length(B)]);
  Result := Result + '"';
end;

function LowerAscii(const B: RawByteString): RawByteString;
var
  K: SizeInt;
begin
  Result := B;
  UniqueString(Result);
  for K := 1 to Length(Result) do
    if Result[K] in ['A'..'Z'] then
      Result[K] := AnsiChar(Ord(Result[K]) + 32);
end;

function IsValidUtf8(const B: RawByteString): Boolean;
var
  K, N, L, J: SizeInt;
  C, D: Byte;
  Cp: Cardinal;
begin
  K := 1;
  N := Length(B);
  while K <= N do
  begin
    C := Ord(B[K]);
    if C < $80 then
    begin
      Inc(K);
      Continue;
    end;
    if (C >= $C2) and (C <= $DF) then
    begin
      L := 2;
      Cp := C and $1F;
    end
    else if (C >= $E0) and (C <= $EF) then
    begin
      L := 3;
      Cp := C and $0F;
    end
    else if (C >= $F0) and (C <= $F4) then
    begin
      L := 4;
      Cp := C and $07;
    end
    else
      Exit(False);
    if K + L - 1 > N then
      Exit(False);
    for J := 1 to L - 1 do
    begin
      D := Ord(B[K + J]);
      if (D and $C0) <> $80 then
        Exit(False);
      Cp := (Cp shl 6) or (D and $3F);
    end;
    if (L = 3) and ((Cp < $800) or ((Cp >= $D800) and (Cp <= $DFFF))) then
      Exit(False);
    if (L = 4) and ((Cp < $10000) or (Cp > $10FFFF)) then
      Exit(False);
    Inc(K, L);
  end;
  Result := True;
end;

function StartsWith(const S, Prefix: RawByteString): Boolean;
begin
  Result := (Length(S) >= Length(Prefix)) and
    ((Length(Prefix) = 0) or (CompareByte(S[1], Prefix[1], Length(Prefix)) = 0));
end;

function EndsWith(const S, Suffix: RawByteString): Boolean;
begin
  Result := (Length(S) >= Length(Suffix)) and
    ((Length(Suffix) = 0) or (CompareByte(S[Length(S) - Length(Suffix) + 1], Suffix[1], Length(Suffix)) = 0));
end;

function FindBytes(const Hay, Needle: RawByteString; From: SizeInt): SizeInt;
var
  K, Last: SizeInt;
begin
  if From > Length(Hay) then
    Exit(-1);
  if Needle = '' then
    Exit(From);
  Last := Length(Hay) - Length(Needle);
  for K := From to Last do
    if (Hay[K + 1] = Needle[1]) and (CompareByte(Hay[K + 1], Needle[1], Length(Needle)) = 0) then
      Exit(K);
  Result := -1;
end;

end.

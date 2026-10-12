{ wdconf.spec - the server spec of conformance/SPEC.md sections 2, 4, 5 and
  6.3: JSON parsing and validation (design m3-transport.md 6.1, 6.2).
  Test tooling.

  Validation follows the reference server (reference-server/src/main.rs
  parse_server_spec and the functions it calls) rule by rule: unknown
  fields, wrong types, and every value hyper rejects (max_buf_size < 8192,
  header_read_timeout_ms with timer false, invalid header names and values,
  invalid reason bytes, status outside 100..999, an unknown version) are
  errors. opt_bool rejects null; opt_u64 and opt_str treat null as absent;
  a number is an unsigned integer only when serde_json's as_u64 accepts it
  (no sign, no fraction, no exponent, at most 2^64 - 1).

  The JSON parser is a small one of its own, not fpjson: fpjson's scanner
  drops "\u0000" and converts string values between code pages (M5 probe
  F0.8), and byte strings (SPEC 2) need the exact code points. Strings keep
  their UTF-8 text and, when every code point is at most U+00FF, the
  latin-1 bytes. Duplicate object keys: the last value wins (serde_json
  Map::insert). }
unit wdconf.spec;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

uses
  SysUtils, Classes, bearings.http.headers, bearings.http1.role, bearings.http1.reason, bearings.http1.config;

type
  EJsonError = class(Exception);
  ESpecError = class(Exception);

  TJKind = (jkNull, jkBool, jkNumber, jkString, jkArray, jkObject);

  TJValue = class
  public
    Kind: TJKind;
    B: Boolean;
    IsUInt: Boolean;                 { serde_json Number::as_u64 is Some }
    UInt: QWord;
    Text: RawByteString;             { jkString: UTF-8; jkNumber: the literal }
    Latin1Ok: Boolean;               { jkString: every code point <= U+00FF }
    Latin1: RawByteString;
    Items: array of TJValue;         { jkArray: elements; jkObject: values }
    Keys: array of RawByteString;    { jkObject }
    destructor Destroy; override;
    function Count: Integer;
    { jkObject: the value of Key (the last one when repeated), or nil }
    function Get(const Key: RawByteString): TJValue;
    function Describe: string;       { for error messages }
  end;

  THeaderPair = record
    Name, Value: RawByteString;
  end;
  THeaderPairs = array of THeaderPair;

  TStreamItemKind = (siData, siError);
  TStreamItem = record
    Kind: TStreamItemKind;
    Data: RawByteString;
    Message: RawByteString;
    DelayMs: QWord;
  end;

  TBodySpecKind = (bsEmpty, bsKnown, bsStream);
  TBodySpec = record
    Kind: TBodySpecKind;
    Known: RawByteString;
    Items: array of TStreamItem;     { "times" already expanded }
    HasTrailers: Boolean;
    Trailers: THeaderPairs;          { applied with insert semantics }
  end;

  TUpgradeSpec = class
  public
    OnUpgrade: Boolean;              { true }
    HasAwait: Boolean;
    AwaitSignal: RawByteString;
    HasWrite: Boolean;
    Write: RawByteString;
    ReadToEof: Boolean;              { true }
  end;

  TReply = class
  public
    Status: Word;                    { 200 }
    HasReason: Boolean;
    Reason: RawByteString;
    HasVersion: Boolean;
    Version: THttpVersion;
    Headers: THeaderPairs;           { applied with insert semantics, in order }
    Body: TBodySpec;
    HasError: Boolean;
    Error: RawByteString;
    ReadBody: Boolean;               { true }
    DelayMs: QWord;
    Upgrade: TUpgradeSpec;           { nil = none }
    constructor Create;
    destructor Destroy; override;
  end;

  THandlerKind = (hkTestService, hkHelloWorld, hkUnreachable);

  TServerSpec = class
  private
    FReplies: TList;                 { the reply queue (SPEC 5.2), process-wide }
    FHead: LongInt;
    FDefault: TReply;
  public
    Cfg: TH1Config;
    Handler: THandlerKind;
    BytesReadEvents: Boolean;
    GracefulShutdownOnAccept: Boolean;
    constructor Create;
    destructor Destroy; override;
    { the next reply; the default reply (an empty object) when the queue is empty }
    function NextReply: TReply;
  end;

function ParseJson(const Text: RawByteString): TJValue;
{ Parses and validates a server spec (SPEC 4, 5). Raises EJsonError or ESpecError. }
function ParseServerSpec(const Text: RawByteString): TServerSpec;

implementation

{ ---- JSON ---- }

destructor TJValue.Destroy;
var
  I: Integer;
begin
  for I := 0 to High(Items) do
    Items[I].Free;
  inherited Destroy;
end;

function TJValue.Count: Integer;
begin
  Result := Length(Items);
end;

function TJValue.Get(const Key: RawByteString): TJValue;
var
  I: Integer;
begin
  Result := nil;
  if Kind <> jkObject then
    Exit;
  for I := High(Keys) downto 0 do
    if Keys[I] = Key then
      Exit(Items[I]);
end;

function TJValue.Describe: string;
var
  I: Integer;
begin
  case Kind of
    jkNull: Result := 'null';
    jkBool: if B then Result := 'true' else Result := 'false';
    jkNumber: Result := Text;
    jkString: Result := '"' + Text + '"';
    jkArray:
      begin
        Result := '[';
        for I := 0 to High(Items) do
        begin
          if I > 0 then
            Result := Result + ',';
          Result := Result + Items[I].Describe;
        end;
        Result := Result + ']';
      end;
  else
    begin
      Result := '{';
      for I := 0 to High(Items) do
      begin
        if I > 0 then
          Result := Result + ',';
        Result := Result + '"' + Keys[I] + '":' + Items[I].Describe;
      end;
      Result := Result + '}';
    end;
  end;
end;

type
  TJParser = record
    S: RawByteString;
    Pos: SizeInt;                    { 1-based }
    procedure Fail(const Msg: string);
    procedure SkipWs;
    function Peek: AnsiChar;
    function ParseValue(Depth: Integer): TJValue;
    function ParseString(V: TJValue): Boolean;
    procedure ParseNumber(V: TJValue);
    procedure Expect(const Lit: RawByteString);
  end;

procedure TJParser.Fail(const Msg: string);
begin
  raise EJsonError.CreateFmt('config is not valid JSON: %s at byte %d', [Msg, Pos]);
end;

procedure TJParser.SkipWs;
begin
  while (Pos <= Length(S)) and (S[Pos] in [' ', #9, #10, #13]) do
    Inc(Pos);
end;

function TJParser.Peek: AnsiChar;
begin
  if Pos > Length(S) then
    Fail('unexpected end');
  Result := S[Pos];
end;

procedure TJParser.Expect(const Lit: RawByteString);
begin
  if Copy(S, Pos, Length(Lit)) <> Lit then
    Fail('expected ' + Lit);
  Inc(Pos, Length(Lit));
end;

procedure AppendUtf8(var R: RawByteString; Cp: LongWord);
begin
  if Cp < $80 then
    R := R + AnsiChar(Cp)
  else if Cp < $800 then
    R := R + AnsiChar($C0 or (Cp shr 6)) + AnsiChar($80 or (Cp and $3F))
  else if Cp < $10000 then
    R := R + AnsiChar($E0 or (Cp shr 12)) + AnsiChar($80 or ((Cp shr 6) and $3F))
      + AnsiChar($80 or (Cp and $3F))
  else
    R := R + AnsiChar($F0 or (Cp shr 18)) + AnsiChar($80 or ((Cp shr 12) and $3F))
      + AnsiChar($80 or ((Cp shr 6) and $3F)) + AnsiChar($80 or (Cp and $3F));
end;

function HexVal(C: AnsiChar): Integer;
begin
  case C of
    '0'..'9': Result := Ord(C) - Ord('0');
    'a'..'f': Result := Ord(C) - Ord('a') + 10;
    'A'..'F': Result := Ord(C) - Ord('A') + 10;
  else
    Result := -1;
  end;
end;

function TJParser.ParseString(V: TJValue): Boolean;
var
  C: AnsiChar;
  Cp, Lo: LongWord;
  B0: Byte;
  N, I, H: Integer;

  function Hex4: LongWord;
  var
    K: Integer;
  begin
    Result := 0;
    for K := 1 to 4 do
    begin
      if Pos > Length(S) then
        Fail('unexpected end in \u escape');
      H := HexVal(S[Pos]);
      if H < 0 then
        Fail('invalid \u escape');
      Result := Result * 16 + LongWord(H);
      Inc(Pos);
    end;
  end;

  procedure Add(X: LongWord);
  begin
    AppendUtf8(V.Text, X);
    if X <= $FF then
      V.Latin1 := V.Latin1 + AnsiChar(X)
    else
      V.Latin1Ok := False;
  end;

begin
  { at the opening quote }
  Inc(Pos);
  V.Kind := jkString;
  V.Text := '';
  V.Latin1 := '';
  V.Latin1Ok := True;
  while True do
  begin
    if Pos > Length(S) then
      Fail('unterminated string');
    C := S[Pos];
    if C = '"' then
    begin
      Inc(Pos);
      Exit(True);
    end;
    if C = '\' then
    begin
      Inc(Pos);
      if Pos > Length(S) then
        Fail('unterminated escape');
      C := S[Pos];
      Inc(Pos);
      case C of
        '"': Add(Ord('"'));
        '\': Add(Ord('\'));
        '/': Add(Ord('/'));
        'b': Add(8);
        'f': Add(12);
        'n': Add(10);
        'r': Add(13);
        't': Add(9);
        'u':
          begin
            Cp := Hex4;
            if (Cp >= $D800) and (Cp <= $DBFF) then
            begin
              if Copy(S, Pos, 2) <> '\u' then
                Fail('lone leading surrogate');
              Inc(Pos, 2);
              Lo := Hex4;
              if (Lo < $DC00) or (Lo > $DFFF) then
                Fail('invalid trailing surrogate');
              Cp := $10000 + ((Cp - $D800) shl 10) + (Lo - $DC00);
            end
            else if (Cp >= $DC00) and (Cp <= $DFFF) then
              Fail('lone trailing surrogate');
            Add(Cp);
          end;
      else
        Fail('invalid escape');
      end;
      Continue;
    end;
    B0 := Byte(C);
    if B0 < $20 then
      Fail('control character in string');
    if B0 < $80 then
    begin
      Add(B0);
      Inc(Pos);
      Continue;
    end;
    { raw UTF-8 }
    if (B0 and $E0) = $C0 then begin N := 1; Cp := B0 and $1F; end
    else if (B0 and $F0) = $E0 then begin N := 2; Cp := B0 and $0F; end
    else if (B0 and $F8) = $F0 then begin N := 3; Cp := B0 and $07; end
    else
      Fail('invalid UTF-8');
    if Pos + N > Length(S) then
      Fail('truncated UTF-8');
    for I := 1 to N do
    begin
      if (Byte(S[Pos + I]) and $C0) <> $80 then
        Fail('invalid UTF-8');
      Cp := (Cp shl 6) or (Byte(S[Pos + I]) and $3F);
    end;
    Inc(Pos, N + 1);
    Add(Cp);
  end;
end;

procedure TJParser.ParseNumber(V: TJValue);
var
  Start: SizeInt;
  Neg, Frac: Boolean;
  Acc: QWord;
  Over: Boolean;
  D: Integer;
begin
  Start := Pos;
  Neg := False;
  Frac := False;
  if S[Pos] = '-' then
  begin
    Neg := True;
    Inc(Pos);
  end;
  if (Pos > Length(S)) or not (S[Pos] in ['0'..'9']) then
    Fail('invalid number');
  if (S[Pos] = '0') and (Pos < Length(S)) and (S[Pos + 1] in ['0'..'9']) then
    Fail('leading zero');
  Acc := 0;
  Over := False;
  while (Pos <= Length(S)) and (S[Pos] in ['0'..'9']) do
  begin
    D := Ord(S[Pos]) - Ord('0');
    if (Acc > (High(QWord) - QWord(D)) div 10) then
      Over := True
    else
      Acc := Acc * 10 + QWord(D);
    Inc(Pos);
  end;
  if (Pos <= Length(S)) and (S[Pos] = '.') then
  begin
    Frac := True;
    Inc(Pos);
    if (Pos > Length(S)) or not (S[Pos] in ['0'..'9']) then
      Fail('invalid number');
    while (Pos <= Length(S)) and (S[Pos] in ['0'..'9']) do
      Inc(Pos);
  end;
  if (Pos <= Length(S)) and (S[Pos] in ['e', 'E']) then
  begin
    Frac := True;
    Inc(Pos);
    if (Pos <= Length(S)) and (S[Pos] in ['+', '-']) then
      Inc(Pos);
    if (Pos > Length(S)) or not (S[Pos] in ['0'..'9']) then
      Fail('invalid number');
    while (Pos <= Length(S)) and (S[Pos] in ['0'..'9']) do
      Inc(Pos);
  end;
  V.Kind := jkNumber;
  V.Text := Copy(S, Start, Pos - Start);
  { serde_json 1.0.151 parse_number (de.rs:509-527): a non-negative integer
    that fits u64 is U64 (as_u64 is Some); every negative literal, "-0"
    included ("Convert into a float if we underflow, or on `-0`"), is I64 or
    F64, so as_u64 is None }
  V.IsUInt := (not Frac) and (not Over) and (not Neg);
  V.UInt := Acc;
end;

function TJParser.ParseValue(Depth: Integer): TJValue;
var
  V, Item: TJValue;
  KeyV: TJValue;
  N: Integer;
begin
  if Depth > 128 then
    Fail('nesting too deep');
  SkipWs;
  V := TJValue.Create;
  try
    case Peek of
      'n': begin Expect('null'); V.Kind := jkNull; end;
      't': begin Expect('true'); V.Kind := jkBool; V.B := True; end;
      'f': begin Expect('false'); V.Kind := jkBool; V.B := False; end;
      '"': ParseString(V);
      '-', '0'..'9': ParseNumber(V);
      '[':
        begin
          V.Kind := jkArray;
          Inc(Pos);
          SkipWs;
          if Peek = ']' then
            Inc(Pos)
          else
            while True do
            begin
              Item := ParseValue(Depth + 1);
              N := Length(V.Items);
              SetLength(V.Items, N + 1);
              V.Items[N] := Item;
              SkipWs;
              if Peek = ',' then
                Inc(Pos)
              else if Peek = ']' then
              begin
                Inc(Pos);
                Break;
              end
              else
                Fail('expected , or ]');
            end;
        end;
      '{':
        begin
          V.Kind := jkObject;
          Inc(Pos);
          SkipWs;
          if Peek = '}' then
            Inc(Pos)
          else
            while True do
            begin
              SkipWs;
              if Peek <> '"' then
                Fail('expected a key');
              KeyV := TJValue.Create;
              try
                ParseString(KeyV);
                SkipWs;
                if Peek <> ':' then
                  Fail('expected :');
                Inc(Pos);
                Item := ParseValue(Depth + 1);
                N := Length(V.Items);
                SetLength(V.Items, N + 1);
                SetLength(V.Keys, N + 1);
                V.Items[N] := Item;
                V.Keys[N] := KeyV.Text;
              finally
                KeyV.Free;
              end;
              SkipWs;
              if Peek = ',' then
                Inc(Pos)
              else if Peek = '}' then
              begin
                Inc(Pos);
                Break;
              end
              else
                Fail('expected , or }');
            end;
        end;
    else
      Fail('unexpected character');
    end;
  except
    V.Free;
    raise;
  end;
  Result := V;
end;

function ParseJson(const Text: RawByteString): TJValue;
var
  P: TJParser;
begin
  P.S := Text;
  P.Pos := 1;
  Result := P.ParseValue(0);
  P.SkipWs;
  if P.Pos <= Length(P.S) then
  begin
    Result.Free;
    P.Fail('trailing characters');
  end;
end;

{ ---- the reference server's helpers ---- }

procedure SpecFail(const Msg: string);
begin
  raise ESpecError.Create(Msg);
end;

procedure CheckKeys(M: TJValue; const Allowed: array of RawByteString; const Prefix: string);
var
  I, J: Integer;
  Ok: Boolean;
  List: string;
begin
  for I := 0 to High(M.Keys) do
  begin
    Ok := False;
    for J := 0 to High(Allowed) do
      if M.Keys[I] = Allowed[J] then
        Ok := True;
    if not Ok then
    begin
      List := '';
      for J := 0 to High(Allowed) do
      begin
        if J > 0 then
          List := List + ', ';
        List := List + Allowed[J];
      end;
      SpecFail(Prefix + 'unknown field "' + M.Keys[I] + '" (allowed: ' + List + ')');
    end;
  end;
end;

{ opt_bool: absent -> Default; a boolean; anything else (null too) is an error }
function OptBool(M: TJValue; const K: RawByteString; Default: Boolean; out Present: Boolean): Boolean;
var
  V: TJValue;
begin
  V := M.Get(K);
  Present := V <> nil;
  if V = nil then
    Exit(Default);
  if V.Kind <> jkBool then
    SpecFail(K + ': expected a boolean, found ' + V.Describe);
  Result := V.B;
end;

function OptBoolD(M: TJValue; const K: RawByteString; Default: Boolean): Boolean;
var
  P: Boolean;
begin
  Result := OptBool(M, K, Default, P);
end;

{ opt_u64: absent or null -> not present; else as_u64 or an error }
function OptU64(M: TJValue; const K: RawByteString; out N: QWord): Boolean;
var
  V: TJValue;
begin
  N := 0;
  V := M.Get(K);
  if (V = nil) or (V.Kind = jkNull) then
    Exit(False);
  if (V.Kind <> jkNumber) or not V.IsUInt then
    SpecFail(K + ': expected a non-negative integer, found ' + V.Describe);
  N := V.UInt;
  Result := True;
end;

{ opt_str: absent or null -> not present }
function OptStr(M: TJValue; const K: RawByteString; out S: RawByteString): Boolean;
var
  V: TJValue;
begin
  S := '';
  V := M.Get(K);
  if (V = nil) or (V.Kind = jkNull) then
    Exit(False);
  if V.Kind <> jkString then
    SpecFail(K + ': expected a string, found ' + V.Describe);
  S := V.Text;
  Result := True;
end;

function DecodeHex(const H: RawByteString): RawByteString;
var
  D: RawByteString;
  I, A, B: Integer;
begin
  D := '';
  for I := 1 to Length(H) do
    if not (H[I] in [' ', #9, #10, #12, #13]) then
      D := D + H[I];
  if Odd(Length(D)) then
    SpecFail('odd number of hex digits in "' + H + '"');
  SetLength(Result, Length(D) div 2);
  I := 1;
  while I < Length(D) do
  begin
    A := HexVal(D[I]);
    B := HexVal(D[I + 1]);
    if (A < 0) or (B < 0) then
      SpecFail('invalid hex digit in "' + H + '"');
    Result[(I + 1) div 2] := AnsiChar(A * 16 + B);
    Inc(I, 2);
  end;
end;

function DecodeBytes(V: TJValue): RawByteString; forward;

function DecodePart(P: TJValue): RawByteString;
var
  R, H: TJValue;
  Cnt: QWord;
  U: RawByteString;
  I: QWord;
begin
  case P.Kind of
    jkString: Result := DecodeBytes(P);
    jkObject:
      begin
        R := P.Get('repeat');
        H := P.Get('hex');
        if R <> nil then
        begin
          CheckKeys(P, ['repeat', 'count'], '');
          U := DecodeBytes(R);
          if (P.Get('count') = nil) or (P.Get('count').Kind <> jkNumber)
            or not P.Get('count').IsUInt then
            SpecFail('repeat part needs an integer "count"');
          Cnt := P.Get('count').UInt;
          Result := '';
          if (Cnt > 0) and (Length(U) > 0) then
          begin
            SetLength(Result, QWord(Length(U)) * Cnt);
            for I := 0 to Cnt - 1 do
              Move(U[1], Result[1 + I * QWord(Length(U))], Length(U));
          end;
        end
        else if H <> nil then
        begin
          CheckKeys(P, ['hex'], '');
          if H.Kind <> jkString then
            SpecFail('"hex" must be a string');
          Result := DecodeHex(H.Text);
        end
        else
          SpecFail('unknown byte-string part ' + P.Describe);
      end;
  else
    SpecFail('unknown byte-string part ' + P.Describe);
  end;
end;

{ SPEC 2 byte string; no variable substitution in the server spec }
function DecodeBytes(V: TJValue): RawByteString;
var
  I: Integer;
begin
  case V.Kind of
    jkString:
      begin
        if not V.Latin1Ok then
          SpecFail('byte string contains a code point above U+00FF; use \u00XX escapes for bytes');
        Result := V.Latin1;
      end;
    jkArray:
      begin
        Result := '';
        for I := 0 to High(V.Items) do
          Result := Result + DecodePart(V.Items[I]);
      end;
    jkObject:
      Result := DecodePart(V);
  else
    SpecFail('expected a byte string, found ' + V.Describe);
  end;
end;

function ParseHeaderList(V: TJValue; const What: string): THeaderPairs;
var
  I, N: Integer;
  P: TJValue;
  Name, Value: RawByteString;
begin
  Result := nil;
  if V.Kind <> jkArray then
    SpecFail(What + ': expected an array of [name, value] pairs');
  for I := 0 to High(V.Items) do
  begin
    P := V.Items[I];
    if (P.Kind <> jkArray) or (P.Count <> 2) then
      SpecFail(What + ': each entry must be [name, value], found ' + P.Describe);
    Name := DecodeBytes(P.Items[0]);
    Value := DecodeBytes(P.Items[1]);
    { HeaderName::from_bytes / HeaderValue::from_bytes }
    if not IsValidHeaderName(PByte(Pointer(Name)), Length(Name)) then
      SpecFail(What + ': invalid header name "' + Name + '": invalid HTTP header name');
    if not IsValidHeaderValue(PByte(Pointer(Value)), Length(Value)) then
      SpecFail(What + ': invalid header value "' + Value + '": failed to parse header value');
    N := Length(Result);
    SetLength(Result, N + 1);
    Result[N].Name := Name;
    Result[N].Value := Value;
  end;
end;

procedure ParseConfig(V: TJValue; S: TServerSpec);
var
  Empty: TJValue;
  M, T: TJValue;
  N: QWord;
  Str: RawByteString;
  B, Present: Boolean;
  C: TH1Config;
begin
  Empty := nil;
  if V = nil then
  begin
    Empty := TJValue.Create;
    Empty.Kind := jkObject;
    M := Empty;
  end
  else if V.Kind <> jkObject then
  begin
    SpecFail('config: expected an object, found ' + V.Describe);
    M := nil;
  end
  else
    M := V;
  try
    CheckKeys(M, ['keep_alive', 'half_close', 'title_case_headers', 'preserve_header_case',
      'max_headers', 'max_header_size', 'max_buf_size', 'timer', 'header_read_timeout_ms',
      'writev', 'pipeline_flush', 'auto_date_header', 'ignore_invalid_headers',
      'allow_multiple_spaces_in_request_line_delimiters', 'conn_mode',
      'graceful_shutdown_on_accept'], 'config: ');
    C := HyperDefaultH1Config;
    { header_read_timeout_ms: absent = default, null = disabled, else an integer }
    T := M.Get('header_read_timeout_ms');
    if T = nil then
      C.HeaderReadTimeout := tsDefault
    else if T.Kind = jkNull then
      C.HeaderReadTimeout := tsDisabled
    else
    begin
      if (T.Kind <> jkNumber) or not T.IsUInt then
        SpecFail('header_read_timeout_ms: expected integer or null, found ' + T.Describe);
      C.HeaderReadTimeout := tsMs;
      if T.UInt > QWord(High(Int64) div 2) then
        C.HeaderReadTimeoutMs := High(Int64) div 2
      else
        C.HeaderReadTimeoutMs := Int64(T.UInt);
    end;
    C.Timer := OptBoolD(M, 'timer', False);
    if (C.HeaderReadTimeout = tsMs) and not C.Timer then
      SpecFail('header_read_timeout_ms is set but timer is false (hyper requires a timer)');
    if OptU64(M, 'max_buf_size', N) then
    begin
      if N < 8192 then
        SpecFail(Format('max_buf_size %d is below hyper''s minimum of 8192', [N]));
      if N > QWord(High(SizeInt)) then
        C.MaxBufSize := High(SizeInt)
      else
        C.MaxBufSize := SizeInt(N);
    end;
    if OptStr(M, 'conn_mode', Str) then
    begin
      if Str = 'plain' then C.Mode := cmPlain
      else if Str = 'with_upgrades' then C.Mode := cmWithUpgrades
      else if Str = 'without_shutdown' then C.Mode := cmWithoutShutdown
      else SpecFail('conn_mode: unknown value "' + Str + '"');
    end
    else
      C.Mode := cmPlain;
    B := OptBool(M, 'keep_alive', True, Present);
    C.KeepAlive := B;
    C.HalfClose := OptBoolD(M, 'half_close', False);
    C.TitleCaseHeaders := OptBoolD(M, 'title_case_headers', False);
    C.PreserveHeaderCase := OptBoolD(M, 'preserve_header_case', False);
    if OptU64(M, 'max_headers', N) then
    begin
      if N > QWord(High(Integer)) then
        C.MaxHeaders := High(Integer)
      else
        C.MaxHeaders := Integer(N);
    end;
    if OptU64(M, 'max_header_size', N) then
    begin
      if N > QWord(High(SizeInt)) then
        C.MaxHeaderSize := High(SizeInt)
      else
        C.MaxHeaderSize := SizeInt(N);
    end;
    { writev: checked as a boolean and otherwise ignored (step T1: one
      write path; it chose between hyper's two write strategies) }
    OptBool(M, 'writev', False, Present);
    C.PipelineFlush := OptBoolD(M, 'pipeline_flush', False);
    C.AutoDateHeader := OptBoolD(M, 'auto_date_header', True);
    C.Parser.IgnoreInvalidHeadersInRequests := OptBoolD(M, 'ignore_invalid_headers',
      C.Parser.IgnoreInvalidHeadersInRequests);
    C.Parser.AllowMultipleSpacesInRequestLineDelimiters :=
      OptBoolD(M, 'allow_multiple_spaces_in_request_line_delimiters',
      C.Parser.AllowMultipleSpacesInRequestLineDelimiters);
    S.GracefulShutdownOnAccept := OptBoolD(M, 'graceful_shutdown_on_accept', False);
    S.Cfg := C;
  finally
    Empty.Free;
  end;
end;

function ParseBody(V: TJValue): TBodySpec;
var
  K, St, It, T, Dv: TJValue;
  I, N: Integer;
  Times, R: QWord;
  Item: TStreamItem;
begin
  Result := Default(TBodySpec);
  if V.Kind <> jkObject then
    SpecFail('body: expected an object');
  K := V.Get('known');
  if K <> nil then
  begin
    CheckKeys(V, ['known'], 'body: ');
    Result.Kind := bsKnown;
    Result.Known := DecodeBytes(K);
    Exit;
  end;
  St := V.Get('stream');
  if St = nil then
    SpecFail('body: expected {"known": ...} or {"stream": [...]}');
  CheckKeys(V, ['stream', 'trailers'], 'body: ');
  if St.Kind <> jkArray then
    SpecFail('body.stream: expected an array');
  Result.Kind := bsStream;
  for I := 0 to High(St.Items) do
  begin
    It := St.Items[I];
    if It.Kind <> jkObject then
      SpecFail('body.stream: each item must be an object');
    CheckKeys(It, ['data', 'error', 'delay_ms', 'times'], 'body.stream item: ');
    Item := Default(TStreamItem);
    OptU64(It, 'delay_ms', Item.DelayMs);
    if not OptU64(It, 'times', Times) then
      Times := 1;
    Dv := It.Get('data');
    T := It.Get('error');
    if (Dv <> nil) and (T = nil) then
    begin
      Item.Kind := siData;
      Item.Data := DecodeBytes(Dv);
    end
    else if (Dv = nil) and (T <> nil) and (T.Kind = jkString) then
    begin
      Item.Kind := siError;
      Item.Message := T.Text;
    end
    else
      SpecFail('body.stream item: needs exactly one of "data" or "error" (string)');
    R := 0;
    while R < Times do
    begin
      N := Length(Result.Items);
      SetLength(Result.Items, N + 1);
      Result.Items[N] := Item;
      Inc(R);
    end;
  end;
  T := V.Get('trailers');
  if T <> nil then
  begin
    Result.HasTrailers := True;
    Result.Trailers := ParseHeaderList(T, 'body.trailers');
  end;
end;

function ParseUpgrade(V: TJValue): TUpgradeSpec;
var
  W: TJValue;
begin
  if V.Kind <> jkObject then
    SpecFail('upgrade: expected an object');
  CheckKeys(V, ['on_upgrade', 'await_signal', 'write', 'read_to_eof'], 'upgrade: ');
  Result := TUpgradeSpec.Create;
  try
    Result.OnUpgrade := OptBoolD(V, 'on_upgrade', True);
    Result.HasAwait := OptStr(V, 'await_signal', Result.AwaitSignal);
    W := V.Get('write');
    if W <> nil then
    begin
      Result.HasWrite := True;
      Result.Write := DecodeBytes(W);
    end;
    Result.ReadToEof := OptBoolD(V, 'read_to_eof', True);
  except
    Result.Free;
    raise;
  end;
end;

function ParseVersionStr(const S: RawByteString): THttpVersion;
begin
  if S = 'HTTP/0.9' then Result := hv09
  else if S = 'HTTP/1.0' then Result := hv10
  else if S = 'HTTP/1.1' then Result := hv11
  else if S = 'HTTP/2.0' then Result := hv2
  else if S = 'HTTP/3.0' then Result := hv3
  else
  begin
    SpecFail('unknown version "' + S + '"');
    Result := hv11;
  end;
end;

function ParseReply(V: TJValue): TReply;
var
  N: QWord;
  Str: RawByteString;
  X: TJValue;
  Bad: Byte;
begin
  if V.Kind <> jkObject then
    SpecFail('reply: expected an object');
  CheckKeys(V, ['status', 'reason', 'version', 'headers', 'body', 'error', 'read_body',
    'delay_ms', 'upgrade', 'comment'], 'reply: ');
  Result := TReply.Create;
  try
    if OptU64(V, 'status', N) then
    begin
      { StatusCode::from_u16(s as u16), filtered by s <= u16::MAX: 100..=999 }
      if (N > 65535) or (N < 100) or (N > 999) then
        SpecFail(Format('reply.status: invalid status %d', [N]));
      Result.Status := Word(N);
    end;
    X := V.Get('reason');
    if X <> nil then
    begin
      Str := DecodeBytes(X);
      { ext::ReasonPhrase::try_from }
      if FindInvalidReasonByte(PByte(Pointer(Str)), Length(Str), Bad) then
        SpecFail('reply.reason: invalid reason phrase: invalid byte in reason phrase');
      Result.HasReason := True;
      Result.Reason := Str;
    end;
    if OptStr(V, 'version', Str) then
    begin
      Result.HasVersion := True;
      Result.Version := ParseVersionStr(Str);
    end;
    X := V.Get('headers');
    if X <> nil then
      Result.Headers := ParseHeaderList(X, 'reply.headers');
    X := V.Get('body');
    if X <> nil then
      Result.Body := ParseBody(X);
    Result.HasError := OptStr(V, 'error', Result.Error);
    Result.ReadBody := OptBoolD(V, 'read_body', True);
    OptU64(V, 'delay_ms', Result.DelayMs);
    X := V.Get('upgrade');
    if X <> nil then
      Result.Upgrade := ParseUpgrade(X);
  except
    Result.Free;
    raise;
  end;
end;

{ ---- TReply, TServerSpec ---- }

constructor TReply.Create;
begin
  inherited Create;
  Status := 200;
  ReadBody := True;
  Version := hv11;
  Body.Kind := bsEmpty;
end;

destructor TReply.Destroy;
begin
  Upgrade.Free;
  inherited Destroy;
end;

constructor TServerSpec.Create;
begin
  inherited Create;
  FReplies := TList.Create;
  FDefault := TReply.Create;
  Cfg := HyperDefaultH1Config;
  Handler := hkTestService;
end;

destructor TServerSpec.Destroy;
var
  I: Integer;
begin
  for I := 0 to FReplies.Count - 1 do
    TReply(FReplies[I]).Free;
  FReplies.Free;
  FDefault.Free;
  inherited Destroy;
end;

function TServerSpec.NextReply: TReply;
var
  I: LongInt;
begin
  { replies are kept (calls hold them) until the spec is freed; the queue
    is read-only after parsing, so one atomic increment takes a reply
    (--loops N: loops call this concurrently) }
  I := InterLockedIncrement(FHead) - 1;
  if I < FReplies.Count then
    Result := TReply(FReplies[I])
  else
    Result := FDefault;
end;

function ParseServerSpec(const Text: RawByteString): TServerSpec;
var
  Root, Rs: TJValue;
  Str: RawByteString;
  I: Integer;
begin
  Root := ParseJson(Text);
  Result := TServerSpec.Create;
  try
    if Root.Kind <> jkObject then
      SpecFail('server spec must be a JSON object');
    CheckKeys(Root, ['config', 'handler', 'replies', 'bytes_read_events', 'comment'], '');
    Result.BytesReadEvents := OptBoolD(Root, 'bytes_read_events', False);
    ParseConfig(Root.Get('config'), Result);
    if OptStr(Root, 'handler', Str) then
    begin
      if Str = 'test_service' then Result.Handler := hkTestService
      else if Str = 'hello_world' then Result.Handler := hkHelloWorld
      else if Str = 'unreachable' then Result.Handler := hkUnreachable
      else SpecFail('handler: unknown handler "' + Str + '"');
    end;
    Rs := Root.Get('replies');
    if Rs <> nil then
    begin
      if Rs.Kind <> jkArray then
        SpecFail('replies: expected an array');
      for I := 0 to High(Rs.Items) do
        Result.FReplies.Add(ParseReply(Rs.Items[I]));
    end;
    if (Result.Handler <> hkTestService) and (Result.FReplies.Count > 0) then
      SpecFail('replies are only used by the test_service handler');
  except
    Result.Free;
    Root.Free;
    raise;
  end;
  Root.Free;
end;

end.

{ M3 step S0 tests (docs/design.md sections 8 and 7.4):
  - every validating THttpHeaders mutator raises EInvalidHeader on CR, LF,
    NUL, 0x7F in a value and on a bad name, and leaves the list unchanged;
  - Try* return the right THeaderCheck; *Trusted do not check;
  - twin of the M2 test that stores invalid names on purpose;
  - EncodeTrailers: T1 grouping, T3 None cases, appending to a TByteVec,
    T2 assertion (-Sa builds);
  - ServerEncode: the TByteVec overload writes the same bytes as the TBytes
    one, stores declared trailer names in the context's set, asserts header
    validity (-Sa); ResponseVersionPanics;
  - TDecoder trailer scratch; TByteVec growth (Max(2 * cap, len + additional)).
  Run: test_headers_validate --all --format=plain
  Build with the M2 test flags (-Sa): the assertion tests only exist then. }
program test_headers_validate;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Classes, SysUtils, fpcunit, testregistry, consoletestrunner,
  bearings.rt.buf, bearings.http.headers, bearings.http1.encode, bearings.http1.decode, bearings.http1.role,
  bearings.http1.reason;

type
  TTestHeadersValidate = class(TTestCase)
  private
    H: THttpHeaders;
    FName, FValue: RawByteString;
    FIndex: SizeInt;
    procedure DoAddP;
    procedure DoAddS;
    procedure DoAppend;
    procedure DoInsertP;
    procedure DoInsertS;
    procedure DoSetValueP;
    procedure DoSetValueS;
    procedure ExpectRaise(const Ctx: string; M: TRunMethod; Want: THeaderCheck);
    procedure CheckUnchanged(const Ctx: string);
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure Mutators_raise_on_bad_value_bytes;
    procedure Mutators_raise_on_bad_names;
    procedure Mutators_accept_valid_bytes;
    procedure Every_value_byte_matches_HeaderValue_from_bytes;
    procedure Every_name_byte_matches_HeaderName_from_bytes;
    procedure Try_variants_return_the_check;
    procedure Trusted_variants_do_not_check;
    procedure Library_callers_use_trusted_paths;
    procedure Twin_codec_extra_invalid_names;
    procedure EncodeTrailers_T1_groups_by_first_appearance;
    procedure EncodeTrailers_title_case_grouped;
    procedure EncodeTrailers_T3_none_cases;
    procedure EncodeTrailers_appends_to_vec;
    procedure EncodeTrailers_uses_given_field_set;
    {$IFOPT C+}
    procedure EncodeTrailers_T2_asserts_on_injected_crlf;
    procedure ServerEncode_asserts_on_injected_crlf;
    {$ENDIF}
    procedure ServerEncode_vec_overload_same_bytes;
    procedure ServerEncode_vec_overload_trailer_names_in_context;
    procedure ServerEncode_reason_slice;
    procedure Response_version_panics_table;
    procedure Decoder_trailer_scratch;
    procedure ByteVec_growth;
  end;

function S2B(const S: RawByteString): PByte; inline;
begin
  Result := PByte(Pointer(S));
end;

function VecStr(const V: TByteVec): RawByteString;
begin
  SetLength(Result, V.Len);
  if V.Len > 0 then
    Move(V.Data^, Pointer(Result)^, V.Len);
end;

procedure FreeVec(var V: TByteVec);
begin
  V.Clear;
  V.ReleaseIdle(nil);
end;

function ListStr(L: THttpHeaders): RawByteString;
var
  I: SizeInt;
begin
  Result := '';
  for I := 0 to L.Count - 1 do
    Result := Result + L.Name(I) + '=' + L.Value(I) + ';';
end;

{ ---- fixture ---- }

procedure TTestHeadersValidate.SetUp;
begin
  H := THttpHeaders.Create;
end;

procedure TTestHeadersValidate.TearDown;
begin
  H.Free;
end;

procedure TTestHeadersValidate.DoAddP;
begin
  H.Add(S2B(FName), Length(FName), S2B(FValue), Length(FValue));
end;

procedure TTestHeadersValidate.DoAddS;
begin
  H.Add(FName, FValue);
end;

procedure TTestHeadersValidate.DoAppend;
begin
  H.Append(FName, FValue);
end;

procedure TTestHeadersValidate.DoInsertP;
begin
  H.Insert(S2B(FName), Length(FName), S2B(FValue), Length(FValue));
end;

procedure TTestHeadersValidate.DoInsertS;
begin
  H.Insert(FName, FValue);
end;

procedure TTestHeadersValidate.DoSetValueP;
begin
  H.SetValue(FIndex, S2B(FValue), Length(FValue));
end;

procedure TTestHeadersValidate.DoSetValueS;
begin
  H.SetValue(FIndex, FValue);
end;

procedure TTestHeadersValidate.ExpectRaise(const Ctx: string; M: TRunMethod; Want: THeaderCheck);
var
  Raised: Boolean;
  Got: THeaderCheck;
begin
  Raised := False;
  Got := hcOk;
  try
    M;
  except
    on E: EInvalidHeader do
    begin
      Raised := True;
      Got := E.Check;
    end;
  end;
  AssertTrue(Ctx + ': EInvalidHeader raised', Raised);
  AssertTrue(Ctx + ': Check', Got = Want);
end;

{ the list holds exactly x-a: 1, x-b: 2, x-a: 3 }
procedure TTestHeadersValidate.CheckUnchanged(const Ctx: string);
begin
  AssertEquals(Ctx + ': list unchanged', 'x-a=1;x-b=2;x-a=3;', ListStr(H));
end;

const
  BAD_VALUES: array[0..7] of RawByteString = (
    'a'#13'b', 'a'#10'b', 'a'#0'b', 'a'#127'b', #13#10, 'x'#13#10'injected: 1', #1, #31);
  BAD_NAMES: array[0..7] of RawByteString = (
    '', 'a b', 'a:', 'a'#13, 'a'#10, 'a'#0, 'caf'#$C3#$A9, '(x)');

procedure TTestHeadersValidate.Mutators_raise_on_bad_value_bytes;
var
  I: Integer;
begin
  for I := 0 to High(BAD_VALUES) do
  begin
    H.Clear;
    H.AddTrusted('x-a', '1');
    H.AddTrusted('x-b', '2');
    H.AddTrusted('x-a', '3');
    FName := 'x-a';
    FValue := BAD_VALUES[I];
    FIndex := 1;
    ExpectRaise('Add(P) value ' + IntToStr(I), @DoAddP, hcBadValue);
    CheckUnchanged('Add(P) value ' + IntToStr(I));
    ExpectRaise('Add(S) value ' + IntToStr(I), @DoAddS, hcBadValue);
    CheckUnchanged('Add(S) value ' + IntToStr(I));
    ExpectRaise('Append value ' + IntToStr(I), @DoAppend, hcBadValue);
    CheckUnchanged('Append value ' + IntToStr(I));
    { Insert of an existing name would replace and delete: must not start }
    ExpectRaise('Insert(P) value ' + IntToStr(I), @DoInsertP, hcBadValue);
    CheckUnchanged('Insert(P) value ' + IntToStr(I));
    ExpectRaise('Insert(S) value ' + IntToStr(I), @DoInsertS, hcBadValue);
    CheckUnchanged('Insert(S) value ' + IntToStr(I));
    ExpectRaise('SetValue(P) value ' + IntToStr(I), @DoSetValueP, hcBadValue);
    CheckUnchanged('SetValue(P) value ' + IntToStr(I));
    ExpectRaise('SetValue(S) value ' + IntToStr(I), @DoSetValueS, hcBadValue);
    CheckUnchanged('SetValue(S) value ' + IntToStr(I));
  end;
end;

procedure TTestHeadersValidate.Mutators_raise_on_bad_names;
var
  I: Integer;
begin
  for I := 0 to High(BAD_NAMES) do
  begin
    H.Clear;
    H.AddTrusted('x-a', '1');
    H.AddTrusted('x-b', '2');
    H.AddTrusted('x-a', '3');
    FName := BAD_NAMES[I];
    FValue := 'ok';
    ExpectRaise('Add(P) name ' + IntToStr(I), @DoAddP, hcBadName);
    ExpectRaise('Add(S) name ' + IntToStr(I), @DoAddS, hcBadName);
    ExpectRaise('Append name ' + IntToStr(I), @DoAppend, hcBadName);
    ExpectRaise('Insert(P) name ' + IntToStr(I), @DoInsertP, hcBadName);
    ExpectRaise('Insert(S) name ' + IntToStr(I), @DoInsertS, hcBadName);
    CheckUnchanged('names ' + IntToStr(I));
    { a bad name and a bad value: the name is reported (checked first) }
    FValue := 'a'#13'b';
    ExpectRaise('Add(P) name+value ' + IntToStr(I), @DoAddP, hcBadName);
    CheckUnchanged('names+value ' + IntToStr(I));
  end;
  { a name longer than MAX_HEADER_NAME_LEN }
  FName := StringOfChar('a', MAX_HEADER_NAME_LEN + 1);
  FValue := 'v';
  ExpectRaise('Add(P) long name', @DoAddP, hcBadName);
  FName := StringOfChar('a', MAX_HEADER_NAME_LEN);
  DoAddP;
  AssertEquals(MAX_HEADER_NAME_LEN, H.NameLen(H.Count - 1));
end;

procedure TTestHeadersValidate.Mutators_accept_valid_bytes;
begin
  H.Add('X-Custom_Name.~!#$%&''*+^`|', 'tab'#9'space obs'#$80#$FF);
  H.Add('empty', '');
  H.Append('a', 'b');
  H.Insert('a', 'c');
  H.SetValue(0, 'v'#9'w');
  H.Add(S2B('n'), 1, S2B('v'), 1);
  H.Insert(S2B('n'), 1, S2B('w'), 1);
  H.SetValue(1, S2B('e'), 1);
  AssertEquals('X-Custom_Name.~!#$%&''*+^`|=v'#9'w;empty=e;a=c;n=w;', ListStr(H));
end;

procedure TTestHeadersValidate.Every_value_byte_matches_HeaderValue_from_bytes;
var
  B: Integer;
  Want: Boolean;
  C: THeaderCheck;
  V: RawByteString;
begin
  for B := 0 to 255 do
  begin
    { http 1.x HeaderValue::from_bytes: b >= 32 && b != 127 || b == b'\t' }
    Want := ((B >= 32) and (B <> 127)) or (B = 9);
    V := 'a' + AnsiChar(B) + 'z';
    H.Clear;
    C := H.TryAdd(S2B('x'), 1, S2B(V), 3);
    if Want then
      AssertTrue('byte ' + IntToStr(B) + ' accepted', (C = hcOk) and (H.Count = 1))
    else
      AssertTrue('byte ' + IntToStr(B) + ' rejected', (C = hcBadValue) and (H.Count = 0));
    AssertEquals('IsValidHeaderValue byte ' + IntToStr(B), Want, IsValidHeaderValue(S2B(V), 3));
  end;
end;

procedure TTestHeadersValidate.Every_name_byte_matches_HeaderName_from_bytes;
var
  B: Integer;
  Want: Boolean;
  C: THeaderCheck;
  N: RawByteString;
begin
  for B := 0 to 255 do
  begin
    { RFC 9110 tchar, as http's HEADER_CHARS (uppercase accepted, normalized) }
    Want := AnsiChar(B) in ['A'..'Z', 'a'..'z', '0'..'9', '!', '#', '$', '%', '&', '''',
      '*', '+', '-', '.', '^', '_', '`', '|', '~'];
    N := 'a' + AnsiChar(B);
    H.Clear;
    C := H.TryAdd(S2B(N), 2, S2B('v'), 1);
    if Want then
      AssertTrue('name byte ' + IntToStr(B) + ' accepted', C = hcOk)
    else
      AssertTrue('name byte ' + IntToStr(B) + ' rejected', (C = hcBadName) and (H.Count = 0));
  end;
end;

procedure TTestHeadersValidate.Try_variants_return_the_check;
begin
  AssertTrue(H.TryAdd(S2B('a'), 1, S2B('1'), 1) = hcOk);
  AssertTrue(H.TryAdd(S2B('a b'), 3, S2B('1'), 1) = hcBadName);
  AssertTrue(H.TryAdd(S2B('b'), 1, S2B('1'#10), 2) = hcBadValue);
  AssertTrue(H.TryAdd(S2B('a b'), 3, S2B('1'#10), 2) = hcBadName);
  AssertTrue(H.TryAdd(nil, 0, S2B('1'), 1) = hcBadName);
  AssertEquals('a=1;', ListStr(H));
  AssertTrue(H.TryInsert(S2B('a'), 1, S2B('2'), 1) = hcOk);
  AssertTrue(H.TryInsert(S2B('a'), 1, S2B(#0), 1) = hcBadValue);
  AssertTrue(H.TryInsert(S2B('a:'), 2, S2B('3'), 1) = hcBadName);
  AssertTrue(H.TryInsert(S2B('c'), 1, S2B('3'), 1) = hcOk);
  AssertEquals('a=2;c=3;', ListStr(H));
  AssertTrue(H.TrySetValue(1, S2B('4'), 1) = hcOk);
  AssertTrue(H.TrySetValue(1, S2B(#127), 1) = hcBadValue);
  AssertTrue(H.TrySetValue(0, S2B('x'#13'y'), 3) = hcBadValue);
  AssertTrue(H.TrySetValue(0, nil, 0) = hcOk);
  AssertEquals('a=;c=4;', ListStr(H));
  AssertTrue(CheckHeaderField(S2B('ok'), 2, S2B('ok'), 2) = hcOk);
end;

procedure TTestHeadersValidate.Trusted_variants_do_not_check;
begin
  { valid-by-construction paths copy any bytes as given }
  AssertEquals(0, H.AddTrusted(S2B('a b'), 3, S2B('x'#13#10'y'), 4));
  AssertEquals(1, H.AddTrusted('c:', #0));
  H.InsertTrusted(S2B('a b'), 3, S2B(#127), 1);
  H.InsertTrusted('n'#10, 'v');
  H.SetValueTrusted(1, S2B(#13), 1);
  AssertEquals(3, H.Count);
  AssertEquals('a b=' + #127 + ';c:=' + #13 + ';n' + #10 + '=v;', ListStr(H));
end;

procedure TTestHeadersValidate.Library_callers_use_trusted_paths;
var
  Err: TDecodeError;
  N0: QWord;
  H2: THttpHeaders;
const
  TR: RawByteString = 'Expires: never'#13#10'X-A: 1'#13#10#13#10;
begin
  { decision 13: valid bytes alone cannot tell the paths apart, so the test
    counts the validating mutator calls (-Sa builds: ValidatingMutatorCalls) }
  H2 := THttpHeaders.Create;
  try
    N0 := ValidatingMutatorCalls;
    H2.Add('a', 'b');
    H2.TryAdd(S2B('c'), 1, S2B('d'), 1);
    H2.SetValue(0, 'e');
    AssertEquals('the counter sees the validating mutators', N0 + 3, ValidatingMutatorCalls);
  finally
    H2.Free;
  end;
  N0 := ValidatingMutatorCalls;
  AssertTrue(ParseTrailers(S2B(TR), Length(TR), 10, H, Err));
  AssertEquals('Expires=never;X-A=1;', ListStr(H));
  AssertEquals('no validating mutator was called by the library', N0, ValidatingMutatorCalls);
end;

procedure TTestHeadersValidate.Twin_codec_extra_invalid_names;
begin
  { test_codec_extra Extra_encode_trailer_header_lines stores 'e f' and 'g@'
    with AddTrusted; the validating Add rejects both }
  FValue := '5';
  FName := 'e f';
  ExpectRaise('Add e f', @DoAddS, hcBadName);
  FName := 'g@';
  ExpectRaise('Add g@', @DoAddS, hcBadName);
  AssertEquals(0, H.Count);
end;

{ ---- trailers ---- }

function ChunkedWith(const Decl: array of RawByteString): TEncoder;
begin
  Result := TEncoder.Chunked;
  Result.IntoChunkedWithTrailingFields(Decl);
end;

procedure TTestHeadersValidate.EncodeTrailers_T1_groups_by_first_appearance;
var
  E: TEncoder;
  V: TByteVec;
begin
  { hyper collects into a HeaderMap: a: 1, b: 2, a: 3 -> a, a, b }
  H.Add('a', '1');
  H.Add('b', '2');
  H.Add('A', '3');
  H.Add('c', '4');
  H.Add('B', '5');
  H.Add('a', '6');
  E := ChunkedWith(['a', 'b', 'c']);
  V := Default(TByteVec);
  AssertTrue(E.EncodeTrailers(H, False, V, nil));
  AssertEquals('0'#13#10'a: 1'#13#10'a: 3'#13#10'a: 6'#13#10'b: 2'#13#10'b: 5'#13#10 +
    'c: 4'#13#10#13#10, VecStr(V));
  FreeVec(V);
  { an undeclared or forbidden group is dropped whole; order of the rest kept }
  H.Clear;
  H.Add('x-und', '0');
  H.Add('b', '1');
  H.Add('content-length', '9');
  H.Add('a', '2');
  H.Add('b', '3');
  H.Add('Content-Length', '8');
  H.Add('a', '4');
  E := ChunkedWith(['a', 'B', 'content-length']);
  V := Default(TByteVec);
  AssertTrue(E.EncodeTrailers(H, False, V, nil));
  AssertEquals('0'#13#10'b: 1'#13#10'b: 3'#13#10'a: 2'#13#10'a: 4'#13#10#13#10, VecStr(V));
  FreeVec(V);
end;

procedure TTestHeadersValidate.EncodeTrailers_title_case_grouped;
var
  E: TEncoder;
  V: TByteVec;
begin
  H.Add('x-trace-id', '1');
  H.Add('expires', '2');
  H.Add('X-TRACE-ID', '3');
  E := ChunkedWith(['X-Trace-Id', 'Expires']);
  V := Default(TByteVec);
  AssertTrue(E.EncodeTrailers(H, True, V, nil));
  AssertEquals('0'#13#10'X-Trace-Id: 1'#13#10'X-Trace-Id: 3'#13#10'Expires: 2'#13#10#13#10, VecStr(V));
  FreeVec(V);
end;

procedure TTestHeadersValidate.EncodeTrailers_T3_none_cases;
var
  E: TEncoder;
  V: TByteVec;
begin
  H.Add('a', '1');
  V := Default(TByteVec);
  { Chunked(None): no Trailer header }
  E := TEncoder.Chunked;
  AssertFalse('Chunked(None)', E.EncodeTrailers(H, False, V, nil));
  { not chunked }
  E := TEncoder.Length(10);
  E.IntoChunkedWithTrailingFields(['a']);
  AssertFalse('Length', E.EncodeTrailers(H, False, V, nil));
  E := TEncoder.CloseDelimited;
  AssertFalse('CloseDelimited', E.EncodeTrailers(H, False, V, nil));
  { Chunked(Some(..)) but no declared field survives }
  E := ChunkedWith(['b']);
  AssertFalse('undeclared', E.EncodeTrailers(H, False, V, nil));
  H.Clear;
  H.Add('content-type', 'x');
  H.Add('te', 'trailers');
  E := ChunkedWith(['content-type', 'te']);
  AssertFalse('forbidden', E.EncodeTrailers(H, False, V, nil));
  { Chunked(Some(vec![])) }
  E := ChunkedWith([]);
  AssertFalse('empty declared list', E.EncodeTrailers(H, False, V, nil));
  { no trailers at all }
  E := ChunkedWith(['a']);
  AssertFalse('nil list', E.EncodeTrailers(nil, False, V, nil));
  H.Clear;
  AssertFalse('empty list', E.EncodeTrailers(H, False, V, nil));
  AssertEquals('nothing appended', 0, V.Len);
  AssertTrue('no memory taken', V.Block = nil);
end;

procedure TTestHeadersValidate.EncodeTrailers_appends_to_vec;
var
  E: TEncoder;
  V: TByteVec;
  Pre: RawByteString;
begin
  Pre := '5'#13#10'hello'#13#10;
  V := Default(TByteVec);
  V.Append(S2B(Pre), Length(Pre), nil);
  H.Add('expires', 'never');
  E := ChunkedWith(['expires']);
  AssertTrue(E.EncodeTrailers(H, False, V, nil));
  AssertEquals(Pre + '0'#13#10'expires: never'#13#10#13#10, VecStr(V));
  { False leaves Dst as it was }
  E := ChunkedWith(['other']);
  AssertFalse(E.EncodeTrailers(H, False, V, nil));
  AssertEquals(Pre + '0'#13#10'expires: never'#13#10#13#10, VecStr(V));
  FreeVec(V);
end;

procedure TTestHeadersValidate.EncodeTrailers_uses_given_field_set;
var
  S1, S2: TTrailerFieldSet;
  E1, E2: TEncoder;
  V: TByteVec;
begin
  S1 := Default(TTrailerFieldSet);
  S2 := Default(TTrailerFieldSet);
  try
    E1 := TEncoder.Chunked;
    E1.SetTrailerFieldSet(@S1);
    E1.IntoChunkedWithTrailerHeader(S2B('a, b'), 4);
    E2 := TEncoder.Chunked;
    E2.SetTrailerFieldSet(@S2);
    E2.IntoChunkedWithTrailerHeader(S2B('c'), 1);
    E2.IntoChunkedWithTrailerHeader(S2B(' d ,'), 4);      { names accumulate across lines }
    AssertEquals(2, S1.Count);
    AssertEquals(2, S2.Count);
    AssertTrue(S1.Contains(S2B('B'), 1));
    AssertFalse(S1.Contains(S2B('c'), 1));
    AssertTrue(S2.Contains(S2B('d'), 1));
    H.Add('a', '1');
    H.Add('c', '2');
    H.Add('d', '3');
    V := Default(TByteVec);
    AssertTrue(E1.EncodeTrailers(H, False, V, nil));
    AssertEquals('0'#13#10'a: 1'#13#10#13#10, VecStr(V));
    V.Clear;
    AssertTrue(E2.EncodeTrailers(H, False, V, nil));
    AssertEquals('0'#13#10'c: 2'#13#10'd: 3'#13#10#13#10, VecStr(V));
    FreeVec(V);
  finally
    S1.Done;
    S2.Done;
  end;
end;

{$IFOPT C+}
procedure TTestHeadersValidate.EncodeTrailers_T2_asserts_on_injected_crlf;
var
  E: TEncoder;
  V: TByteVec;
  Raised: Boolean;
begin
  { M2 copied any bytes: a CR/LF in a trailer value injected lines. The
    validating Add rejects it (5.1); a value smuggled in through a trusted
    path is caught by the encoder's assertion in -Sa builds. }
  FName := 'x-a';
  FValue := '1'#13#10'injected: yes';
  ExpectRaise('Add trailer with CRLF', @DoAddS, hcBadValue);
  H.AddTrusted(FName, FValue);
  E := ChunkedWith(['x-a']);
  V := Default(TByteVec);
  Raised := False;
  try
    E.EncodeTrailers(H, False, V, nil);
  except
    on EAssertionFailed do Raised := True;
  end;
  FreeVec(V);
  AssertTrue('EncodeTrailers asserts in -Sa builds', Raised);
end;

procedure TTestHeadersValidate.ServerEncode_asserts_on_injected_crlf;
var
  Head: TResponseHead;
  P: TServerEncodeParams;
  Enc: TEncoder;
  Dst: TBytes;
  DstLen: SizeInt;
  Raised: Boolean;
begin
  H.AddTrusted('x-a', '1'#10'set-cookie: evil');
  Head := DefaultResponseHead;
  Head.Headers := H;
  P := DefaultEncodeParams;
  Dst := nil;
  DstLen := 0;
  Raised := False;
  try
    ServerEncode(Head, P, Dst, DstLen, Enc);
  except
    on EAssertionFailed do Raised := True;
  end;
  AssertTrue('ServerEncode asserts in -Sa builds', Raised);
end;
{$ENDIF}

procedure TTestHeadersValidate.ServerEncode_vec_overload_same_bytes;
const
  DATE: RawByteString = 'Sun, 06 Nov 1994 08:49:37 GMT';
var
  Head: TResponseHead;
  P: TServerEncodeParams;
  Ctx: TEncodeContext;
  E1, E2: TEncoder;
  Dst: TBytes;
  DstLen: SizeInt;
  V: TByteVec;
  R1, R2: TServerEncodeResult;
  I, Round: Integer;
  B1: RawByteString;
begin
  H.Add('content-type', 'text/plain');
  H.Add('server', 'wd-40');
  H.Add('x-multi', 'a');
  H.Add('Connection', 'keep-alive');
  H.Add('x-multi', 'b');
  V := Default(TByteVec);
  for Round := 0 to 5 do
  begin
    Head := DefaultResponseHead;
    Head.Headers := H;
    P := DefaultEncodeParams;
    P.Date := S2B(DATE);
    case Round of
      0: begin P.Body := blkKnown; P.BodyLen := 13; P.ReqMethod := hmGet; end;
      1: begin P.Body := blkUnknown; P.TitleCaseHeaders := True; end;
      2: begin Head.Status := 404; P.Body := blkNone; P.KeepAlive := False; end;
      3: begin Head.Version := hv10; P.Body := blkUnknown; end;
      4: begin Head.Status := 103; end;                 { serUnsupportedStatusCode }
      5: begin H.Add('content-length', 'x'); P.Body := blkUnknown; end;   { serUserHeader }
    end;
    Dst := nil;
    SetLength(Dst, 3);
    DstLen := 3;
    R1 := ServerEncode(Head, P, Dst, DstLen, E1);
    SetLength(B1, DstLen - 3);
    if DstLen > 3 then
      Move(Dst[3], Pointer(B1)^, DstLen - 3);
    V.Clear;
    V.Append(S2B('pre'), 3, nil);
    Ctx.Date := S2B(DATE);
    Ctx.Trailers := nil;
    P.Date := nil;                                     { the overload reads Ctx.Date }
    R2 := ServerEncode(Head, P, Ctx, V, nil, E2);
    AssertTrue('result round ' + IntToStr(Round), R1 = R2);
    AssertEquals('bytes round ' + IntToStr(Round), 'pre' + B1, VecStr(V));
    AssertTrue('encoder kind round ' + IntToStr(Round), E1.Kind = E2.Kind);
    AssertEquals('encoder remaining round ' + IntToStr(Round), E1.Remaining, E2.Remaining);
    AssertEquals('encoder is_last round ' + IntToStr(Round), E1.IsLast, E2.IsLast);
    if Round = 5 then
      AssertEquals('rewound', 3, V.Len);
  end;
  FreeVec(V);
  { no headers at all }
  Head := DefaultResponseHead;
  P := DefaultEncodeParams;
  P.DateHeader := False;
  Ctx.Date := nil;
  Ctx.Trailers := nil;
  V := Default(TByteVec);
  for I := 1 to 3 do
    ServerEncode(Head, P, Ctx, V, nil, E2);
  AssertEquals(StringOfChar('-', 0) + 'HTTP/1.1 200 OK'#13#10'content-length: 0'#13#10#13#10 +
    'HTTP/1.1 200 OK'#13#10'content-length: 0'#13#10#13#10 +
    'HTTP/1.1 200 OK'#13#10'content-length: 0'#13#10#13#10, VecStr(V));
  FreeVec(V);
end;

procedure TTestHeadersValidate.ServerEncode_vec_overload_trailer_names_in_context;
var
  Head: TResponseHead;
  P: TServerEncodeParams;
  Ctx: TEncodeContext;
  S: TTrailerFieldSet;
  E: TEncoder;
  V, TV: TByteVec;
  T: THttpHeaders;
begin
  S := Default(TTrailerFieldSet);
  T := THttpHeaders.Create;
  V := Default(TByteVec);
  TV := Default(TByteVec);
  try
    H.Add('trailer', 'x-sum, Content-Length');
    H.Add('trailer', 'x-late');
    Head := DefaultResponseHead;
    Head.Headers := H;
    P := DefaultEncodeParams;
    P.Body := blkUnknown;
    P.DateHeader := False;
    Ctx.Date := nil;
    Ctx.Trailers := @S;
    AssertTrue(ServerEncode(Head, P, Ctx, V, nil, E) = serOk);
    AssertEquals('HTTP/1.1 200 OK'#13#10'trailer: x-sum, Content-Length, x-late'#13#10 +
      'transfer-encoding: chunked'#13#10#13#10, VecStr(V));
    AssertEquals('names stored in the context set', 3, S.Count);
    T.Add('x-late', '2');
    T.Add('content-length', '5');
    T.Add('x-sum', '1');
    T.Add('x-other', '0');
    AssertTrue(E.EncodeTrailers(T, False, TV, nil));
    AssertEquals('0'#13#10'x-late: 2'#13#10'x-sum: 1'#13#10#13#10, VecStr(TV));
  finally
    FreeVec(V);
    FreeVec(TV);
    T.Free;
    S.Done;
  end;
end;

procedure TTestHeadersValidate.ServerEncode_reason_slice;
var
  Head: TResponseHead;
  P: TServerEncodeParams;
  Ctx: TEncodeContext;
  E: TEncoder;
  V: TByteVec;
  R: TReasonPhrase;
begin
  AssertTrue(TReasonPhrase.TryFrom('Very Fine', R));
  Head := DefaultResponseHead;
  Head.HasReason := True;
  Head.ReasonP := R.Data;
  Head.ReasonLen := R.Len;
  P := DefaultEncodeParams;
  P.DateHeader := False;
  Ctx.Date := nil;
  Ctx.Trailers := nil;
  V := Default(TByteVec);
  ServerEncode(Head, P, Ctx, V, nil, E);
  AssertEquals('HTTP/1.1 200 Very Fine'#13#10'content-length: 0'#13#10#13#10, VecStr(V));
  { an empty custom reason is still a custom reason (no shortcut) }
  V.Clear;
  Head.ReasonP := nil;
  Head.ReasonLen := 0;
  ServerEncode(Head, P, Ctx, V, nil, E);
  AssertEquals('HTTP/1.1 200 '#13#10'content-length: 0'#13#10#13#10, VecStr(V));
  FreeVec(V);
end;

procedure TTestHeadersValidate.Response_version_panics_table;
var
  V: THttpVersion;
  St: Word;
  Want: Boolean;
begin
  for V := Low(THttpVersion) to High(THttpVersion) do
    for St := 100 to 999 do
    begin
      if (St >= 100) and (St <= 199) and (St <> 101) then
        Want := False
      else
        Want := V in [hv09, hv3];
      AssertEquals(Format('status %d version %d', [St, Ord(V)]), Want, ResponseVersionPanics(St, V));
    end;
end;

procedure TTestHeadersValidate.Decoder_trailer_scratch;
const
  BODY: RawByteString = '3'#13#10'abc'#13#10'0'#13#10'Expires: never'#13#10'X-N: 1'#13#10#13#10;
var
  D: TDecoder;
  R: TDecodeResult;
  Scr: TByteVec;
  Pos: SizeInt;
  St: TDecodeStatus;
begin
  Scr := Default(TByteVec);
  D.InitChunked;
  D.SetTrailerScratch(@Scr);
  Pos := 0;
  repeat
    St := D.Decode(S2B(BODY) + Pos, Length(BODY) - Pos, False, H, R);
    Inc(Pos, R.Consumed);
  until St in [dsTrailers, dsEnd, dsError];
  AssertTrue(St = dsTrailers);
  AssertEquals('Expires=never;X-N=1;', ListStr(H));
  AssertTrue('trailer bytes went to the given scratch', Scr.Len > 0);
  AssertEquals('Expires: never'#13#10'X-N: 1'#13#10#13#10, VecStr(Scr));
  FreeVec(Scr);
  { without a scratch: the per-thread default, same result }
  H.Clear;
  D.InitChunked;
  Pos := 0;
  repeat
    St := D.Decode(S2B(BODY) + Pos, Length(BODY) - Pos, False, H, R);
    Inc(Pos, R.Consumed);
  until St in [dsTrailers, dsEnd, dsError];
  AssertTrue(St = dsTrailers);
  AssertEquals('Expires=never;X-N=1;', ListStr(H));
end;

procedure TTestHeadersValidate.ByteVec_growth;
var
  V: TByteVec;
  Buf: array[0..99] of Byte;
begin
  FillChar(Buf, SizeOf(Buf), 7);
  V := Default(TByteVec);
  V.Reserve(0, nil);
  AssertEquals('reserve(0) on empty', 0, V.Cap);
  V.Reserve(1, nil);
  AssertEquals('heap block: exact', 1, V.Cap);
  V.Append(@Buf[0], 8, nil);
  AssertEquals('len + additional wins', 8, V.Cap);
  V.Append(@Buf[0], 1, nil);
  AssertEquals('doubling', 16, V.Cap);
  V.Reserve(100, nil);
  AssertEquals('len + additional wins', 109, V.Cap);
  V.Reserve(100, nil);
  AssertEquals('enough room: unchanged', 109, V.Cap);
  V.Append(@Buf[0], 100, nil);
  AssertEquals(109, V.Len);
  V.Append(@Buf[0], 1, nil);
  AssertEquals('2 * cap', 218, V.Cap);
  Buf[0] := 1; Buf[1] := 2; Buf[2] := 3;
  V.Clear;
  V.Append(@Buf[0], 3, nil);
  V.DrainFront(1);
  AssertEquals(2, V.Len);
  AssertEquals(2, V.Data[0]);
  AssertEquals(3, V.Data[1]);
  V.Clear;
  V.ReleaseIdle(nil);
  AssertTrue('idle: no block', V.Block = nil);
  AssertEquals('idle: no capacity', 0, V.Cap);
  V.Reserve(5, nil);
  AssertTrue('a block again', V.Block <> nil);
  AssertEquals(5, V.Cap);
  V.Append(@Buf[0], 3, nil);
  AssertEquals(1, V.Data[0]);
  FreeVec(V);
end;

var
  App: TTestRunner;
begin
  RegisterTest(TTestHeadersValidate);
  DefaultFormat := fPlain;
  DefaultRunAllTests := True;
  App := TTestRunner.Create(nil);
  try
    App.Initialize;
    App.Title := 'bearings S0: header validation, trailers, ServerEncode overload';
    App.Run;
  finally
    App.Free;
  end;
end.

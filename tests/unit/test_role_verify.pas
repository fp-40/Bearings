{ Adversarial verification tests for bearings.http1.role and bearings.http.uri (edge
  cases the hyper test ports do not cover). Not hyper test ports.

  Every expected value below is hyper v1.12.0's own answer (role.rs with
  httparse 1.10.1 and http 1.5.0), obtained by replaying the same inputs
  through hyper's unmodified role.rs (the test_role_diff_rs sources driven
  from a case file; since step T1 that tool runs the parse cases only, and
  the encode values here are fixed expectations). Where a test checks a property instead of a table
  (every prefix, every split point, the is_complete_fast model) the comment
  says which hyper rule it follows.

  Inputs are copied to the end of a page followed by a PROT_NONE page, so a
  read past the given length faults instead of passing silently. }
unit test_role_verify;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, BaseUnix, fpcunit, testregistry,
  bearings.http1.parser, bearings.http.headers, bearings.http.uri, bearings.http1.encode,
  bearings.http1.decode, bearings.http1.reason, bearings.http1.role, test_role_server;

type
  TTestRoleVerify = class(TTestCase)
  published
    procedure Extra_empty_input;
    procedure Extra_every_prefix_is_partial_until_head_end;
    procedure Extra_incremental_parse_byte_by_byte;
    procedure Extra_incremental_parse_split_at_every_byte;
    procedure Extra_is_complete_fast_exhaustive_model;
    procedure Extra_content_length_values;
    procedure Extra_content_length_and_transfer_encoding_order;
    procedure Extra_transfer_encoding_values;
    procedure Extra_connection_expect_upgrade_values;
    procedure Extra_cr_lf_handling;
    procedure Extra_method_tokens;
    procedure Extra_max_headers_heap_slots;
    procedure Extra_uri_scheme_and_name_length_limits;
    procedure Extra_decoder_chunk_size_overflow;
    procedure Extra_encode_status_line_every_code;
    procedure Extra_encode_huge_body_length;
    procedure Extra_encode_user_content_length_values;
    procedure Extra_encode_more_than_256_headers;
    procedure Extra_encode_case_map_spelling_per_value;
    procedure Extra_no_allocation_more_paths;
    procedure Extra_headers_left_empty_on_partial_and_error;
  end;

implementation

const
  CRLF = #13#10;

{ ---- guard page ---- }

var
  GBase: PByte = nil;
  GSize: SizeInt = 0;

{ Copies S so that its last byte is followed by a PROT_NONE page. The
  pointer is valid until the next call. }
function Guarded(const S: RawByteString): PByte;
const
  Page = 4096;
var
  Need: SizeInt;
begin
  Need := ((Length(S) + Page - 1) div Page + 1) * Page;
  if Need > GSize then
  begin
    if GBase <> nil then
      Fpmunmap(GBase, GSize);
    GBase := Fpmmap(nil, Need, PROT_READ or PROT_WRITE, MAP_PRIVATE or MAP_ANONYMOUS, -1, 0);
    if GBase = Pointer(-1) then
      raise Exception.Create('mmap failed');
    GSize := Need;
  end;
  Fpmprotect(GBase, GSize, PROT_READ or PROT_WRITE);
  Fpmprotect(GBase + GSize - Page, Page, PROT_NONE);
  Result := GBase + GSize - Page - Length(S);
  if Length(S) > 0 then
    Move(Pointer(S)^, Result^, Length(S));
end;

{ ---- helpers ---- }

function Show(const S: RawByteString): string;
var
  I: Integer;
begin
  Result := '';
  for I := 1 to Length(S) do
    case S[I] of
      #13: Result := Result + '\r';
      #10: Result := Result + '\n';
      #9: Result := Result + '\t';
      #32..#126: Result := Result + S[I];
    else
      Result := Result + '\x' + IntToHex(Ord(S[I]), 2);
    end;
end;

function ParseG(const S: RawByteString; H: THttpHeaders; out Msg: TParsedRequestHead;
  MaxHeaders: Integer = -1; MaxHeaderSize: SizeInt = -1): TServerParseStatus;
var
  Ctx: TH1ParseContext;
begin
  Ctx := DefaultParseContext;
  Ctx.MaxHeaders := MaxHeaders;
  Ctx.MaxHeaderSize := MaxHeaderSize;
  Result := ServerParse(Guarded(S), Length(S), Ctx, H, Msg);
end;

type
  TExpect = record
    Status: TServerParseStatus;
    Error: TH1ParseError;
    HeadLen: SizeInt;    { checked when Status = spsComplete }
    Decode: QWord;       { checked when Status = spsComplete }
    KeepAlive: Integer;  { -1 = not checked }
  end;

function Ok(HeadLen: SizeInt; Decode: QWord; KeepAlive: Integer = -1): TExpect;
begin
  Result.Status := spsComplete;
  Result.Error := h1peNone;
  Result.HeadLen := HeadLen;
  Result.Decode := Decode;
  Result.KeepAlive := KeepAlive;
end;

function Err(E: TH1ParseError): TExpect;
begin
  Result.Status := spsError;
  Result.Error := E;
  Result.HeadLen := 0;
  Result.Decode := 0;
  Result.KeepAlive := -1;
end;

function Partial: TExpect;
begin
  Result := Err(h1peNone);
  Result.Status := spsPartial;
end;

procedure CheckParse(T: TTestCase; const S: RawByteString; const X: TExpect; H: THttpHeaders);
var
  Msg: TParsedRequestHead;
  St: TServerParseStatus;
  Ctx: string;
begin
  St := ParseG(S, H, Msg);
  Ctx := Show(S);
  T.AssertEquals(Ctx + ' status', Ord(X.Status), Ord(St));
  case X.Status of
    spsError:
      T.AssertEquals(Ctx + ' error ' + H1ParseErrorDescription(Msg.Error), Ord(X.Error), Ord(Msg.Error));
    spsComplete:
      begin
        T.AssertEquals(Ctx + ' head len', X.HeadLen, Msg.HeadLen);
        T.AssertEquals(Ctx + ' decode', X.Decode, Msg.Decode);
        if X.KeepAlive >= 0 then
          T.AssertEquals(Ctx + ' keep-alive', X.KeepAlive = 1, Msg.KeepAlive);
      end;
  end;
end;

{ requests whose head ends before BodyLen trailing body bytes }
type
  TReq = record
    S: RawByteString;
    BodyLen: SizeInt;
  end;
  TReqArray = array of TReq;

function Requests: TReqArray;
var
  A: TReqArray;

  procedure Add(const S: RawByteString; BodyLen: SizeInt);
  begin
    SetLength(A, Length(A) + 1);
    A[High(A)].S := S;
    A[High(A)].BodyLen := BodyLen;
  end;

begin
  A := nil;
  Add('GET / HTTP/1.1'#13#10'Host: x'#13#10#13#10, 0);
  Add('GET / HTTP/1.1'#10'Host: x'#10#10, 0);
  Add('GET / HTTP/1.1'#13#10'Host: x'#10#13#10, 0);
  Add('GET / HTTP/1.1'#13#10'Host: x'#13#10#10, 0);
  Add(#13#10#13#10'GET / HTTP/1.1'#13#10#13#10, 0);
  Add('POST /a/b?c=d#e HTTP/1.0'#13#10'Content-Length: 5'#13#10'Connection: keep-alive'#13#10#13#10'hello', 5);
  Add('CONNECT example.com:443 HTTP/1.1'#13#10'Host: example.com:443'#13#10#13#10, 0);
  Add('OPTIONS * HTTP/1.1'#13#10#13#10, 0);
  Add('PUT http://u:p@[::1]:8080/p?q HTTP/1.1'#13#10'Transfer-Encoding: gzip, chunked'#13#10 +
    'Expect: 100-continue'#13#10#13#10'5'#13#10'hello'#13#10'0'#13#10#13#10, 15);
  Add('M-SEARCH * HTTP/1.1'#13#10'X:'#13#10'Y: '#9' a'#9'b '#9#13#10'Upgrade: websocket'#13#10 +
    'Connection: Upgrade'#13#10#13#10, 0);
  Add('GET /caf'#$C3#$A9' HTTP/1.1'#13#10'x-a: '#$C3#$A9#$80#13#10#13#10, 0);
  Result := A;
end;

{ ---- parse ---- }

procedure TTestRoleVerify.Extra_empty_input;
var
  H: THttpHeaders;
  Msg: TParsedRequestHead;
begin
  H := THttpHeaders.Create;
  try
    { parse_headers: an empty buffer is Ok(None), with or without prev_len }
    AssertTrue(ServerParseHeaders(nil, 0, -1, DefaultParseContext, H, Msg) = spsPartial);
    AssertTrue(ServerParseHeaders(nil, 0, 0, DefaultParseContext, H, Msg) = spsPartial);
    AssertTrue(ServerParseHeaders(Guarded(''), 0, 7, DefaultParseContext, H, Msg) = spsPartial);
    AssertTrue(Msg.Error = h1peNone);
    AssertEquals(0, Msg.HeadLen);
    { Server::parse is never called with an empty buffer by hyper; the port
      answers Partial without reading }
    AssertTrue(ServerParse(Guarded(''), 0, DefaultParseContext, H, Msg) = spsPartial);
    AssertFalse(IsCompleteFast(nil, 0, 0));
    AssertFalse(IsCompleteFast(Guarded(''), 0, 3));
    { prev_len > len never happens in hyper (it would panic on the slice);
      the port clamps and must not read }
    AssertFalse(IsCompleteFast(Guarded(#13#10#13#10), 4, 10));
  finally
    H.Free;
  end;
end;

procedure TTestRoleVerify.Extra_every_prefix_is_partial_until_head_end;
var
  H: THttpHeaders;
  Msg: TParsedRequestHead;
  R: TReq;
  N, HeadLen: SizeInt;
  St: TServerParseStatus;
begin
  { httparse returns Partial for every strict prefix of a valid head, and
    Complete(head length) once the blank line is in; body bytes are not
    consumed. hyper's answer for every prefix below is PARTIAL / OK len. }
  H := THttpHeaders.Create;
  try
    for R in Requests do
    begin
      HeadLen := Length(R.S) - R.BodyLen;
      for N := 1 to Length(R.S) do
      begin
        St := ServerParse(Guarded(Copy(R.S, 1, N)), N, DefaultParseContext, H, Msg);
        if N < HeadLen then
          AssertTrue(Format('%s [%d]: partial', [Show(R.S), N]), St = spsPartial)
        else
        begin
          AssertTrue(Format('%s [%d]: complete', [Show(R.S), N]), St = spsComplete);
          AssertEquals(Format('%s [%d]: head len', [Show(R.S), N]), HeadLen, Msg.HeadLen);
        end;
      end;
    end;
  finally
    H.Free;
  end;
end;

procedure TTestRoleVerify.Extra_incremental_parse_byte_by_byte;
var
  H: THttpHeaders;
  Msg: TParsedRequestHead;
  R: TReq;
  N, HeadLen: SizeInt;
  St: TServerParseStatus;
begin
  { hyper's read loop calls parse_headers(buf, Some(previous len)) after
    each read; one byte per read here. is_complete_fast must not skip the
    read that completes the head. }
  H := THttpHeaders.Create;
  try
    for R in Requests do
    begin
      HeadLen := Length(R.S) - R.BodyLen;
      for N := 1 to HeadLen do
      begin
        if N = 1 then
          St := ServerParseHeaders(Guarded(Copy(R.S, 1, N)), N, -1, DefaultParseContext, H, Msg)
        else
          St := ServerParseHeaders(Guarded(Copy(R.S, 1, N)), N, N - 1, DefaultParseContext, H, Msg);
        if N < HeadLen then
          AssertTrue(Format('%s [%d]: partial', [Show(R.S), N]), St = spsPartial)
        else
        begin
          AssertTrue(Format('%s [%d]: complete', [Show(R.S), N]), St = spsComplete);
          AssertEquals(HeadLen, Msg.HeadLen);
        end;
      end;
    end;
  finally
    H.Free;
  end;
end;

procedure TTestRoleVerify.Extra_incremental_parse_split_at_every_byte;
var
  H: THttpHeaders;
  Msg: TParsedRequestHead;
  R: TReq;
  Split, HeadLen: SizeInt;
  Head: RawByteString;
begin
  { two reads: Split bytes (prev_len None), then the rest of the head
    (prev_len Some(Split)) }
  H := THttpHeaders.Create;
  try
    for R in Requests do
    begin
      HeadLen := Length(R.S) - R.BodyLen;
      Head := Copy(R.S, 1, HeadLen);
      for Split := 1 to HeadLen - 1 do
      begin
        AssertTrue(Format('%s [%d]: first read partial', [Show(Head), Split]),
          ServerParseHeaders(Guarded(Copy(Head, 1, Split)), Split, -1, DefaultParseContext, H, Msg) = spsPartial);
        AssertTrue(Format('%s [%d]: second read complete', [Show(Head), Split]),
          ServerParseHeaders(Guarded(Head), HeadLen, Split, DefaultParseContext, H, Msg) = spsComplete);
        AssertEquals(HeadLen, Msg.HeadLen);
      end;
    end;
  finally
    H.Free;
  end;
end;

procedure TTestRoleVerify.Extra_is_complete_fast_exhaustive_model;
const
  Alpha: array[0..2] of AnsiChar = (#13, #10, 'a');
var
  Len, Code, Total, K, I, Prev, Start: Integer;
  S, T: RawByteString;
  B: PByte;
  Model: Boolean;
begin
  { role.rs is_complete_fast(bytes, prev_len): true iff "\r\n\r\n", "\n\n"
    or "\n\r\n" starts at an index >= prev_len.saturating_sub(3).
    Every string over (CR, LF, 'a') up to 9 bytes, every prev_len <= len. }
  Total := 1;
  for Len := 0 to 9 do
  begin
    for Code := 0 to Total - 1 do
    begin
      SetLength(S, Len);
      K := Code;
      for I := 1 to Len do
      begin
        S[I] := Alpha[K mod 3];
        K := K div 3;
      end;
      B := Guarded(S);
      for Prev := 0 to Len do
      begin
        Start := Prev - 3;
        if Start < 0 then
          Start := 0;
        T := Copy(S, Start + 1, MaxInt);
        Model := (Pos(#13#10#13#10, T) > 0) or (Pos(#10#10, T) > 0) or (Pos(#10#13#10, T) > 0);
        if IsCompleteFast(B, Len, Prev) <> Model then
          Fail(Format('is_complete_fast(%s, %d) should be %s', [Show(S), Prev, BoolToStr(Model, True)]));
      end;
    end;
    Total := Total * 3;
  end;
end;

procedure TTestRoleVerify.Extra_content_length_values;
var
  H: THttpHeaders;

  procedure C(const V: RawByteString; const X: TExpect);
  begin
    CheckParse(Self, 'POST / HTTP/1.1'#13#10'Content-Length: ' + V + #13#10#13#10, X, H);
  end;

begin
  H := THttpHeaders.Create;
  try
    C('0', Ok(38, 0, 1));
    C('05', Ok(39, 5, 1));
    C(StringOfChar('0', 40) + '7', Ok(78, 7, 1));
    { DecodedLength::MAX_LEN = u64::MAX - 2 }
    C('18446744073709551613', Ok(57, DECODED_LENGTH_MAX, 1));
    C('18446744073709551614', Err(h1peTooLarge));
    C('18446744073709551615', Err(h1peTooLarge));
    { u64 overflow in from_digits }
    C('18446744073709551616', Err(h1peHeaderContentLengthInvalid));
    C('99999999999999999999', Err(h1peHeaderContentLengthInvalid));
    C('+5', Err(h1peHeaderContentLengthInvalid));
    C('-5', Err(h1peHeaderContentLengthInvalid));
    C('5 5', Err(h1peHeaderContentLengthInvalid));
    C('5,5', Err(h1peHeaderContentLengthInvalid));
    C('5, 5', Err(h1peHeaderContentLengthInvalid));
    C('0x5', Err(h1peHeaderContentLengthInvalid));
    C('', Err(h1peHeaderContentLengthInvalid));
    C(#$FF, Err(h1peHeaderContentLengthInvalid));
    C('5'#$80, Err(h1peHeaderContentLengthInvalid));
    AssertEquals(431, ServerErrorStatus(h1peTooLarge));
    AssertEquals(400, ServerErrorStatus(h1peHeaderContentLengthInvalid));
  finally
    H.Free;
  end;
end;

procedure TTestRoleVerify.Extra_content_length_and_transfer_encoding_order;
var
  H: THttpHeaders;
  Msg: TParsedRequestHead;
begin
  H := THttpHeaders.Create;
  try
    { a Content-Length after Transfer-Encoding is skipped before it is
      parsed, so even an invalid one is accepted (and not stored) }
    CheckParse(Self, 'POST / HTTP/1.1'#13#10'Transfer-Encoding: chunked'#13#10'Content-Length: +5'#13#10#13#10,
      Ok(67, DECODED_LENGTH_CHUNKED, 0), H);
    AssertEquals(1, H.Count);
    AssertFalse(H.Contains(HN_CONTENT_LENGTH));
    CheckParse(Self, 'POST / HTTP/1.1'#13#10'Transfer-Encoding: chunked'#13#10'Content-Length: 18446744073709551616'#13#10#13#10,
      Ok(85, DECODED_LENGTH_CHUNKED, 0), H);
    { ... but before it, it is parsed first }
    CheckParse(Self, 'POST / HTTP/1.1'#13#10'Content-Length: +5'#13#10'Transfer-Encoding: chunked'#13#10#13#10,
      Err(h1peHeaderContentLengthInvalid), H);
    CheckParse(Self, 'POST / HTTP/1.1'#13#10'Content-Length: 18446744073709551616'#13#10'Transfer-Encoding: chunked'#13#10#13#10,
      Err(h1peHeaderContentLengthInvalid), H);
    { equal duplicates are stored once, then removed by TE }
    AssertTrue(ParseG('POST / HTTP/1.1'#13#10'Content-Length: 5'#13#10'content-length: 5'#13#10 +
      'X: y'#13#10'Transfer-Encoding: chunked'#13#10#13#10, H, Msg) = spsComplete);
    AssertEquals(DECODED_LENGTH_CHUNKED, Msg.Decode);
    AssertFalse(Msg.KeepAlive);
    AssertEquals(2, H.Count);
    AssertEquals('y', H.GetValue('x'));
    AssertEquals('chunked', H.GetValue('transfer-encoding'));
    { TE, CL, TE: both TE lines kept, CL dropped }
    AssertTrue(ParseG('POST / HTTP/1.1'#13#10'Content-Length: 5'#13#10'Transfer-Encoding: gzip'#13#10 +
      'Transfer-Encoding: chunked'#13#10'Content-Length: 7'#13#10#13#10, H, Msg) = spsComplete);
    AssertEquals(DECODED_LENGTH_CHUNKED, Msg.Decode);
    AssertEquals(2, H.CountOf('transfer-encoding'));
    AssertEquals(0, H.CountOf('content-length'));
    { HTTP/1.0: a Transfer-Encoding line is an error wherever it is }
    CheckParse(Self, 'POST / HTTP/1.0'#13#10'Content-Length: 5'#13#10'Transfer-Encoding: chunked'#13#10#13#10,
      Err(h1peHeaderTransferEncodingUnexpected), H);
    CheckParse(Self, 'POST / HTTP/1.0'#13#10'Transfer-Encoding: identity'#13#10#13#10,
      Err(h1peHeaderTransferEncodingUnexpected), H);
  finally
    H.Free;
  end;
end;

procedure TTestRoleVerify.Extra_transfer_encoding_values;
var
  H: THttpHeaders;

  procedure C(const V: RawByteString; const X: TExpect);
  begin
    CheckParse(Self, 'POST / HTTP/1.1'#13#10'Transfer-Encoding: ' + V + #13#10#13#10, X, H);
  end;

begin
  H := THttpHeaders.Create;
  try
    C('chunked', Ok(47, DECODED_LENGTH_CHUNKED, 1));
    C('Chunked', Ok(47, DECODED_LENGTH_CHUNKED, 1));
    C(' chunked', Ok(48, DECODED_LENGTH_CHUNKED, 1));
    C('gzip,chunked', Ok(52, DECODED_LENGTH_CHUNKED, 1));
    C('gzip , chunked ', Ok(55, DECODED_LENGTH_CHUNKED, 1));
    C(',chunked', Ok(48, DECODED_LENGTH_CHUNKED, 1));
    { the last comma-separated item must be "chunked" }
    C('chunked,', Err(h1peHeaderTransferEncodingInvalid));
    C('chunked, ', Err(h1peHeaderTransferEncodingInvalid));
    C('chunkedx', Err(h1peHeaderTransferEncodingInvalid));
    C('x chunked', Err(h1peHeaderTransferEncodingInvalid));
    C('identity', Err(h1peHeaderTransferEncodingInvalid));
    C('', Err(h1peHeaderTransferEncodingInvalid));
    { HeaderValue::to_str fails on obs-text: not chunked }
    C('chunked'#$80, Err(h1peHeaderTransferEncodingInvalid));
    C(#$80', chunked', Err(h1peHeaderTransferEncodingInvalid));
  finally
    H.Free;
  end;
end;

procedure TTestRoleVerify.Extra_connection_expect_upgrade_values;
var
  H: THttpHeaders;
  Msg: TParsedRequestHead;

  function KA(const Ver, V: RawByteString): Boolean;
  begin
    AssertTrue(ParseG('GET / HTTP/' + Ver + #13#10'Connection: ' + V + #13#10#13#10, H, Msg) = spsComplete);
    Result := Msg.KeepAlive;
  end;

  function EC(const Ver, V: RawByteString): Boolean;
  begin
    AssertTrue(ParseG('POST / HTTP/' + Ver + #13#10'Expect: ' + V + #13#10#13#10, H, Msg) = spsComplete);
    Result := Msg.ExpectContinue;
  end;

begin
  H := THttpHeaders.Create;
  try
    { connection_has: to_str() must succeed, so obs-text anywhere in the
      line hides a "close" or "keep-alive" token }
    AssertTrue(KA('1.1', #$80', close'));
    AssertTrue(KA('1.1', 'close'#$80));
    AssertFalse(KA('1.0', 'keep-alive, '#$80));
    AssertFalse(KA('1.0', #$80', close'));
    AssertTrue(KA('1.1', 'closed'));
    AssertFalse(KA('1.1', ' close '));
    AssertTrue(KA('1.1', ','));
    AssertFalse(KA('1.0', ','));
    { Expect: case-insensitive, whole (trimmed) value }
    AssertTrue(EC('1.1', '100-CONTINUE'));
    AssertTrue(EC('1.1', '100-continue '));
    AssertTrue(EC('1.1', ' 100-continue'));
    AssertFalse(EC('1.1', '100-continue, x'));
    AssertTrue(EC('1.0', '100-continue'));
    { CONNECT wants an upgrade, but an Upgrade header resets it to
      is_http_11 }
    AssertTrue(ParseG('CONNECT h:1 HTTP/1.0'#13#10'Upgrade: x'#13#10#13#10, H, Msg) = spsComplete);
    AssertFalse(Msg.WantsUpgrade);
    AssertTrue(ParseG('CONNECT h:1 HTTP/1.1'#13#10'Upgrade: x'#13#10#13#10, H, Msg) = spsComplete);
    AssertTrue(Msg.WantsUpgrade);
  finally
    H.Free;
  end;
end;

procedure TTestRoleVerify.Extra_cr_lf_handling;
var
  H: THttpHeaders;

  procedure C(const S: RawByteString; const X: TExpect);
  begin
    CheckParse(Self, S, X, H);
  end;

begin
  H := THttpHeaders.Create;
  try
    C('GET / HTTP/1.1'#13, Partial);
    C('GET / HTTP/1.1'#13'X', Err(h1peHeaderToken));
    C('GET / HTTP/1.1'#13#13#10#13#10, Err(h1peHeaderToken));
    C('GET / HTTP/1.1'#10#13#10, Ok(17, 0));
    C('GET / HTTP/1.1'#13#10'a: b'#13'c'#13#10#13#10, Err(h1peHeaderToken));
    C('GET / HTTP/1.1'#13#10'a: b'#13#13#10#13#10, Err(h1peHeaderToken));
    C('GET / HTTP/1.1'#13#10'a: b'#10#10, Ok(22, 0));
    C('GET / HTTP/1.1'#13#10#13'a: b'#13#10#13#10, Err(h1peHeaderToken));
    C('GET / HTTP/1.1'#13#10'a: b'#13#10#13#13#10, Err(h1peHeaderToken));
    C('GET / HTTP/1.1'#13#10'a: b'#13#10#13'x', Err(h1peHeaderToken));
    C('GET / HTTP/1.1'#13#10' a: b'#13#10#13#10, Err(h1peHeaderToken));
    C('GET / HTTP/1.1'#13#10#9'a: b'#13#10#13#10, Err(h1peHeaderToken));
    C('GET / HTTP/1.1'#13#10'a: b'#13#10' c'#13#10#13#10, Err(h1peHeaderToken));
    C('GET / HTTP/1.1'#13#10'a:b'#13#10#13#10, Ok(23, 0));
    C('GET / HTTP/1.1'#13#10'a :b'#13#10#13#10, Err(h1peHeaderToken));
    C('GET / HTTP/1.1'#13#10':b'#13#10#13#10, Err(h1peHeaderToken));
    C('GET / HTTP/1.1'#13#10'a'#13#10#13#10, Err(h1peHeaderToken));
    C('GET / HTTP/1.1'#13#10'a: '#0#13#10#13#10, Err(h1peHeaderToken));
    C('GET / HTTP/1.1'#13#10'a: '#127#13#10#13#10, Err(h1peHeaderToken));
    C('GET'#9'/ HTTP/1.1'#13#10#13#10, Err(h1peMethod));
    C('GET /'#9'HTTP/1.1'#13#10#13#10, Err(h1peUri));
    C(' GET / HTTP/1.1'#13#10#13#10, Err(h1peMethod));
    C('GET / HTTP/1.1 '#13#10#13#10, Err(h1peHeaderToken));
    C('GET / http/1.1'#13#10#13#10, Err(h1peVersion));
    C('GET / HTTP/1.10'#13#10#13#10, Err(h1peHeaderToken));
    C('GET / HTTP/0.9'#13#10#13#10, Err(h1peVersion));
    { the HTTP/2 preface is a Version error here; VersionH2 is decided by
      the connection, not by Server::parse }
    C('PRI * HTTP/2.0'#13#10#13#10'SM'#13#10#13#10, Err(h1peVersion));
    C('GET / HTTP/1.1'#13#10#13#10#13#10, Ok(18, 0));
    C(#10#10'GET / HTTP/1.1'#10#10, Ok(18, 0));
    C(#13#13#10'GET / HTTP/1.1'#13#10#13#10, Err(h1peHeaderToken));
  finally
    H.Free;
  end;
end;

procedure TTestRoleVerify.Extra_method_tokens;
var
  H: THttpHeaders;
  Msg: TParsedRequestHead;
  S: RawByteString;
begin
  H := THttpHeaders.Create;
  try
    CheckParse(Self, ' / HTTP/1.1'#13#10#13#10, Err(h1peMethod), H);
    CheckParse(Self, 'GET'#0' / HTTP/1.1'#13#10#13#10, Err(h1peMethod), H);
    CheckParse(Self, #$FF' / HTTP/1.1'#13#10#13#10, Err(h1peMethod), H);
    { http::Method: case-sensitive standard methods, any other token is an
      extension method (inline up to 15 bytes, allocated beyond: same result) }
    AssertTrue(ParseG('get / HTTP/1.1'#13#10#13#10, H, Msg) = spsComplete);
    AssertTrue(Msg.Method = hmExtension);
    S := StringOfChar('A', 16) + ' / HTTP/1.1'#13#10#13#10;
    AssertTrue(ParseG(S, H, Msg) = spsComplete);
    AssertTrue(Msg.Method = hmExtension);
    AssertEquals(16, Msg.MethodSlice.Len);
    S := 'M-SEARCH * HTTP/1.1'#13#10#13#10;
    AssertTrue(ParseG(S, H, Msg) = spsComplete);
    AssertTrue(Msg.Method = hmExtension);
    AssertEquals('M-SEARCH', SliceStr(S, Msg.MethodSlice));
    AssertTrue(ParseG('DELETE / HTTP/1.1'#13#10#13#10, H, Msg) = spsComplete);
    AssertTrue(Msg.Method = hmDelete);
  finally
    H.Free;
  end;
end;

procedure TTestRoleVerify.Extra_max_headers_heap_slots;
var
  H: THttpHeaders;
  Msg: TParsedRequestHead;

  function Gen(N: Integer; Chunked: Boolean): RawByteString;
  var
    I: Integer;
  begin
    Result := 'GET / HTTP/1.1'#13#10;
    for I := 0 to N - 1 do
      if (I = 0) and Chunked then
        Result := Result + 'transfer-encoding: chunked'#13#10
      else
        Result := Result + 'k' + IntToStr(I) + ': v'#13#10;
    Result := Result + #13#10;
  end;

  procedure C(MaxH, N: Integer; Expect: Boolean);
  var
    Ci: Integer;
    Ch: Boolean;
  begin
    for Ci := 0 to 1 do
    begin
      Ch := Ci = 1;
      if Ch and (N = 0) then
        Continue;
      if Expect then
      begin
        AssertTrue(Format('max=%d n=%d', [MaxH, N]), ParseG(Gen(N, Ch), H, Msg, MaxH) = spsComplete);
        AssertEquals(N, H.Count);
        if Ch then
          AssertEquals(DECODED_LENGTH_CHUNKED, Msg.Decode)
        else
          AssertEquals(QWord(0), Msg.Decode);
        if N > 0 then
          AssertEquals('v', H.Value(N - 1));
      end
      else
      begin
        AssertTrue(Format('max=%d n=%d', [MaxH, N]), ParseG(Gen(N, Ch), H, Msg, MaxH) = spsError);
        AssertTrue(Msg.Error = h1peTooLarge);
      end;
    end;
  end;

begin
  H := THttpHeaders.Create;
  try
    C(-1, 100, True);
    C(-1, 101, False);
    C(0, 0, True);
    C(0, 1, False);
    { > DEFAULT_MAX_HEADERS: slots on the heap, as hyper's spilled SmallVec }
    C(101, 101, True);
    C(101, 102, False);
    C(150, 150, True);
    C(150, 151, False);
    C(1000, 999, True);
  finally
    H.Free;
  end;
end;

procedure TTestRoleVerify.Extra_uri_scheme_and_name_length_limits;
var
  H: THttpHeaders;
  Msg: TParsedRequestHead;
  S: RawByteString;
begin
  H := THttpHeaders.Create;
  try
    { request-target: MAX_URI_LEN = 65534 (role.rs), checked before http::Uri }
    S := 'GET /' + StringOfChar('a', 65533) + ' HTTP/1.1'#13#10#13#10;
    CheckParse(Self, S, Ok(Length(S), 0), H);
    CheckParse(Self, 'GET /' + StringOfChar('a', 65534) + ' HTTP/1.1'#13#10#13#10, Err(h1peUriTooLong), H);
    S := 'GET http://h/' + StringOfChar('a', 65525) + ' HTTP/1.1'#13#10#13#10;
    CheckParse(Self, S, Ok(Length(S), 0), H);
    CheckParse(Self, 'GET http://h/' + StringOfChar('a', 65526) + ' HTTP/1.1'#13#10#13#10, Err(h1peUriTooLong), H);
    AssertEquals(414, ServerErrorStatus(h1peUriTooLong));
    { scheme: MAX_SCHEME_LEN = 64 (http), SchemeTooLong -> Parse::Uri }
    S := 'GET ' + StringOfChar('a', 64) + '://h/p HTTP/1.1'#13#10#13#10;
    AssertTrue(ParseG(S, H, Msg) = spsComplete);
    AssertTrue(Msg.Uri.Scheme = usOther);
    AssertEquals(64, Msg.Uri.SchemeLen);
    AssertEquals('h', Copy(S, Msg.Uri.AuthorityOff + 1, Msg.Uri.AuthorityLen));
    AssertTrue(ParseG('GET ' + StringOfChar('a', 65) + '://h/p HTTP/1.1'#13#10#13#10, H, Msg) = spsError);
    AssertTrue(Msg.Error = h1peUri);
    AssertTrue(Msg.UriError = ueSchemeTooLong);
    { header name: >= 64 KiB -> TooLarge (record_header_indices); a long
      value has no limit without max_header_size }
    S := 'GET / HTTP/1.1'#13#10 + StringOfChar('n', 65535) + ': v'#13#10#13#10;
    CheckParse(Self, S, Ok(Length(S), 0), H);
    CheckParse(Self, 'GET / HTTP/1.1'#13#10 + StringOfChar('n', 65536) + ': v'#13#10#13#10, Err(h1peTooLarge), H);
    S := 'GET / HTTP/1.1'#13#10'x: ' + StringOfChar('v', 70000) + #13#10#13#10;
    CheckParse(Self, S, Ok(Length(S), 0), H);
    { max_header_size is checked first }
    AssertTrue(ParseG('GET / HTTP/1.1'#13#10 + StringOfChar('n', 65536) + ': v'#13#10#13#10, H, Msg, -1, 100) = spsError);
    AssertTrue(Msg.Error = h1peTooLarge);
    AssertTrue(ParseG('GET /' + StringOfChar('a', 65534) + ' HTTP/1.1'#13#10#13#10, H, Msg, -1, 100) = spsError);
    AssertTrue(Msg.Error = h1peTooLarge);
  finally
    H.Free;
  end;
end;

procedure TTestRoleVerify.Extra_decoder_chunk_size_overflow;
var
  D: TDecoder;
  R: TDecodeResult;
  S: RawByteString;
  St: TDecodeStatus;
  Body: RawByteString;
  Pos0: SizeInt;
begin
  { decode.rs read_size: checked_mul(16) / checked_add -> InvalidData
    "invalid chunk size: overflow". 16 hex digits fit in a u64, 17 do not. }
  InitDecoderFor(D, DECODED_LENGTH_CHUNKED);
  S := '10000000000000000'#13#10;
  AssertTrue(D.Decode(Guarded(S), Length(S), False, R) = dsError);
  AssertTrue(R.Error = deSizeOverflow);
  InitDecoderFor(D, DECODED_LENGTH_CHUNKED);
  S := StringOfChar('f', 17) + #13#10;
  AssertTrue(D.Decode(Guarded(S), Length(S), False, R) = dsError);
  AssertTrue(R.Error = deSizeOverflow);
  InitDecoderFor(D, DECODED_LENGTH_CHUNKED);
  S := StringOfChar('f', 16) + #13#10'abc';
  St := D.Decode(Guarded(S), Length(S), False, R);
  AssertTrue(St = dsData);
  AssertEquals(3, R.DataLen);
  AssertEquals(High(QWord) - 3, D.Remaining);
  { leading zeros do not count towards overflow }
  InitDecoderFor(D, DECODED_LENGTH_CHUNKED);
  S := StringOfChar('0', 40) + '5'#13#10'hello'#13#10'0'#13#10#13#10;
  Body := '';
  Pos0 := 0;
  repeat
    St := D.Decode(Guarded(Copy(S, Pos0 + 1, MaxInt)), Length(S) - Pos0, True, R);
    if R.DataLen > 0 then
      Body := Body + Copy(S, Pos0 + R.DataOfs + 1, R.DataLen);
    Inc(Pos0, R.Consumed);
  until St in [dsEnd, dsError];
  AssertTrue(St = dsEnd);
  AssertEquals('hello', Body);
  { DecodedLength::MAX_LEN: a Length decoder; EOF before the end is an error }
  InitDecoderFor(D, DECODED_LENGTH_MAX);
  AssertTrue(D.Kind = dkLength);
  S := 'abc';
  AssertTrue(D.Decode(Guarded(S), 3, False, R) = dsData);
  AssertEquals(DECODED_LENGTH_MAX - 3, D.Remaining);
  AssertTrue(D.Decode(nil, 0, True, R) = dsError);
  AssertTrue(R.Error = deIncompleteBody);
  { CLOSE_DELIMITED: read to EOF }
  InitDecoderFor(D, DECODED_LENGTH_CLOSE_DELIMITED);
  AssertTrue(D.Kind = dkEof);
  AssertTrue(D.Decode(Guarded(S), 3, False, R) = dsData);
  AssertTrue(D.Decode(nil, 0, True, R) = dsEnd);
  { ZERO }
  InitDecoderFor(D, DECODED_LENGTH_ZERO);
  AssertTrue(D.IsEof);
end;

{ ---- encode ---- }

type
  TReasonEntry = record
    Code: Word;
    Reason: RawByteString;
  end;

const
  { http 1.5.0 src/status.rs status_codes! (canonical_reason) }
  HTTP_REASONS: array[0..61] of TReasonEntry = (
    (Code: 100; Reason: 'Continue'), (Code: 101; Reason: 'Switching Protocols'),
    (Code: 102; Reason: 'Processing'), (Code: 103; Reason: 'Early Hints'),
    (Code: 200; Reason: 'OK'), (Code: 201; Reason: 'Created'), (Code: 202; Reason: 'Accepted'),
    (Code: 203; Reason: 'Non Authoritative Information'), (Code: 204; Reason: 'No Content'),
    (Code: 205; Reason: 'Reset Content'), (Code: 206; Reason: 'Partial Content'),
    (Code: 207; Reason: 'Multi-Status'), (Code: 208; Reason: 'Already Reported'),
    (Code: 226; Reason: 'IM Used'), (Code: 300; Reason: 'Multiple Choices'),
    (Code: 301; Reason: 'Moved Permanently'), (Code: 302; Reason: 'Found'),
    (Code: 303; Reason: 'See Other'), (Code: 304; Reason: 'Not Modified'),
    (Code: 305; Reason: 'Use Proxy'), (Code: 307; Reason: 'Temporary Redirect'),
    (Code: 308; Reason: 'Permanent Redirect'), (Code: 400; Reason: 'Bad Request'),
    (Code: 401; Reason: 'Unauthorized'), (Code: 402; Reason: 'Payment Required'),
    (Code: 403; Reason: 'Forbidden'), (Code: 404; Reason: 'Not Found'),
    (Code: 405; Reason: 'Method Not Allowed'), (Code: 406; Reason: 'Not Acceptable'),
    (Code: 407; Reason: 'Proxy Authentication Required'), (Code: 408; Reason: 'Request Timeout'),
    (Code: 409; Reason: 'Conflict'), (Code: 410; Reason: 'Gone'),
    (Code: 411; Reason: 'Length Required'), (Code: 412; Reason: 'Precondition Failed'),
    (Code: 413; Reason: 'Payload Too Large'), (Code: 414; Reason: 'URI Too Long'),
    (Code: 415; Reason: 'Unsupported Media Type'), (Code: 416; Reason: 'Range Not Satisfiable'),
    (Code: 417; Reason: 'Expectation Failed'), (Code: 418; Reason: 'I''m a teapot'),
    (Code: 421; Reason: 'Misdirected Request'), (Code: 422; Reason: 'Unprocessable Entity'),
    (Code: 423; Reason: 'Locked'), (Code: 424; Reason: 'Failed Dependency'),
    (Code: 425; Reason: 'Too Early'), (Code: 426; Reason: 'Upgrade Required'),
    (Code: 428; Reason: 'Precondition Required'), (Code: 429; Reason: 'Too Many Requests'),
    (Code: 431; Reason: 'Request Header Fields Too Large'),
    (Code: 451; Reason: 'Unavailable For Legal Reasons'),
    (Code: 500; Reason: 'Internal Server Error'), (Code: 501; Reason: 'Not Implemented'),
    (Code: 502; Reason: 'Bad Gateway'), (Code: 503; Reason: 'Service Unavailable'),
    (Code: 504; Reason: 'Gateway Timeout'), (Code: 505; Reason: 'HTTP Version Not Supported'),
    (Code: 506; Reason: 'Variant Also Negotiates'), (Code: 507; Reason: 'Insufficient Storage'),
    (Code: 508; Reason: 'Loop Detected'), (Code: 510; Reason: 'Not Extended'),
    (Code: 511; Reason: 'Network Authentication Required'));

function ReasonOf(Code: Word): RawByteString;
var
  E: TReasonEntry;
begin
  for E in HTTP_REASONS do
    if E.Code = Code then
      Exit(E.Reason);
  Result := '<none>';
end;

function EncodeP(Status: Word; Body: TBodyLengthKind; BodyLen: QWord; Method: THttpMethod;
  H: THttpHeaders; out Enc: TEncoder; out Res: TServerEncodeResult): RawByteString;
var
  Head: TResponseHead;
  P: TServerEncodeParams;
begin
  Head := DefaultResponseHead;
  Head.Status := Status;
  Head.Headers := H;
  P := DefaultEncodeParams;
  P.Body := Body;
  P.BodyLen := BodyLen;
  P.ReqMethod := Method;
  P.DateHeader := False;
  Result := EncodeStr(Head, P, Enc, Res);
end;

procedure TTestRoleVerify.Extra_encode_status_line_every_code;
var
  Code: Word;
  S, Want: RawByteString;
  Enc: TEncoder;
  Res: TServerEncodeResult;
begin
  for Code := 100 to 999 do
  begin
    S := EncodeP(Code, blkKnown, 0, hmGet, nil, Enc, Res);
    if (Code >= 100) and (Code < 200) and (Code <> 101) then
    begin
      { 1xx is not supported: a 500 head, and an error }
      AssertTrue(IntToStr(Code), Res = serUnsupportedStatusCode);
      Want := 'HTTP/1.1 500 Internal Server Error'#13#10'content-length: 0'#13#10#13#10;
      AssertTrue(Enc.IsLast);
    end
    else
    begin
      AssertTrue(IntToStr(Code), Res = serOk);
      Want := 'HTTP/1.1 ' + IntToStr(Code) + ' ' + ReasonOf(Code) + #13#10;
      { can_have_implicit_zero_content_length: not 1xx, 204, 304 }
      if (Code <> 101) and (Code <> 204) and (Code <> 304) then
        Want := Want + 'content-length: 0'#13#10;
      Want := Want + #13#10;
    end;
    AssertEquals(IntToStr(Code), Want, S);
  end;
end;

procedure TTestRoleVerify.Extra_encode_huge_body_length;
var
  Enc: TEncoder;
  Res: TServerEncodeResult;
begin
  AssertEquals('HTTP/1.1 200 OK'#13#10'content-length: 18446744073709551615'#13#10#13#10,
    EncodeP(200, blkKnown, High(QWord), hmGet, nil, Enc, Res));
  AssertTrue(Enc.Kind = ekLength);
  AssertEquals(High(QWord), Enc.Remaining);
  AssertEquals('HTTP/1.1 200 OK'#13#10'content-length: 18446744073709551614'#13#10#13#10,
    EncodeP(200, blkKnown, High(QWord) - 1, hmGet, nil, Enc, Res));
  { HEAD: the length is announced, nothing is sent }
  AssertEquals('HTTP/1.1 200 OK'#13#10'content-length: 18446744073709551615'#13#10#13#10,
    EncodeP(200, blkKnown, High(QWord), hmHead, nil, Enc, Res));
  AssertEquals(QWord(0), Enc.Remaining);
  { 204: no content-length at all }
  AssertEquals('HTTP/1.1 204 No Content'#13#10#13#10,
    EncodeP(204, blkKnown, High(QWord), hmGet, nil, Enc, Res));
  AssertEquals(QWord(0), Enc.Remaining);
end;

procedure TTestRoleVerify.Extra_encode_user_content_length_values;
var
  H: THttpHeaders;
  Enc: TEncoder;
  Res: TServerEncodeResult;
  Head: TResponseHead;
  P: TServerEncodeParams;
  Dst: TBytes;
  DstLen: SizeInt;

  procedure Bad(const V: RawByteString);
  begin
    H.Clear;
    H.Add('content-length', V);
    DstLen := 3;
    AssertTrue(Show(V), ServerEncode(Head, P, Dst, DstLen, Enc) = serUserHeader);
    AssertEquals(Show(V) + ': rewound', 3, DstLen);
  end;

  procedure Good(const V: RawByteString; N: QWord);
  begin
    H.Clear;
    H.Add('content-length', V);
    AssertEquals(Show(V), 'HTTP/1.1 200 OK'#13#10'content-length: ' + V + #13#10#13#10,
      EncodeP(200, blkUnknown, 0, hmGet, H, Enc, Res));
    AssertTrue(Res = serOk);
    AssertEquals(N, Enc.Remaining);
  end;

begin
  H := THttpHeaders.Create;
  try
    { BodyLength::Unknown: the user value is parsed with from_digits }
    Good('0', 0);
    Good('18446744073709551615', High(QWord));
    Good('00000000000000000000000001', 1);
    Head := DefaultResponseHead;
    Head.Headers := H;
    P := DefaultEncodeParams;
    P.Body := blkUnknown;
    P.ReqMethod := hmGet;
    P.DateHeader := False;
    SetLength(Dst, 16);
    Bad('18446744073709551616');
    Bad(' 1');
    Bad('1 ');
    Bad('1,1');
    Bad('-1');
    Bad('');
    { Known: the header is trusted and written as given }
    H.Clear;
    H.Add('content-length', '1,1');
    AssertEquals('HTTP/1.1 200 OK'#13#10'content-length: 1,1'#13#10#13#10,
      EncodeP(200, blkKnown, 5, hmGet, H, Enc, Res));
    AssertEquals(QWord(5), Enc.Remaining);
    { no body and HEAD: kept as given, nothing is sent }
    AssertEquals('HTTP/1.1 200 OK'#13#10'content-length: 1,1'#13#10#13#10,
      EncodeP(200, blkNone, 0, hmHead, H, Enc, Res));
    AssertEquals(QWord(0), Enc.Remaining);
  finally
    H.Free;
  end;
end;

procedure TTestRoleVerify.Extra_encode_more_than_256_headers;
const
  Names: array[0..7] of RawByteString = ('x-a', 'X-B', 'content-type', 'set-cookie', 'x-c', 'X-D',
    'server', 'x-e');
var
  H: THttpHeaders;
  Enc: TEncoder;
  Res: TServerEncodeResult;
  I, K: Integer;
  Want, WantTitle: RawByteString;

  function Title(const S: RawByteString): RawByteString;
  var
    J: Integer;
  begin
    Result := LowerCase(S);
    for J := 1 to Length(Result) do
      if ((J = 1) or (Result[J - 1] = '-')) and (Result[J] in ['a'..'z']) then
        Result[J] := UpCase(Result[J]);
  end;

var
  Head: TResponseHead;
  P: TServerEncodeParams;
begin
  { HeaderMap::drain order with 300 entries (more than the 256 inline
    "done" flags): each name at its first position, then its later values }
  H := THttpHeaders.Create;
  try
    for I := 0 to 299 do
      H.Add(Names[I mod 8], 'v' + IntToStr(I));
    Want := 'HTTP/1.1 200 OK'#13#10;
    WantTitle := Want;
    for K := 0 to 7 do
    begin
      I := K;
      while I < 300 do
      begin
        Want := Want + LowerCase(Names[K]) + ': v' + IntToStr(I) + #13#10;
        WantTitle := WantTitle + Title(Names[K]) + ': v' + IntToStr(I) + #13#10;
        Inc(I, 8);
      end;
    end;
    AssertEquals(Want + 'transfer-encoding: chunked'#13#10#13#10,
      EncodeP(200, blkUnknown, 0, hmGet, H, Enc, Res));
    AssertTrue(Enc.IsChunked);
    Head := DefaultResponseHead;
    Head.Headers := H;
    P := DefaultEncodeParams;
    P.Body := blkKnown;
    P.BodyLen := 2;
    P.TitleCaseHeaders := True;
    P.DateHeader := False;
    AssertEquals(WantTitle + 'Content-Length: 2'#13#10#13#10, EncodeStr(Head, P, Enc, Res));
  finally
    H.Free;
  end;
end;

procedure TTestRoleVerify.Extra_encode_case_map_spelling_per_value;
var
  Head: TResponseHead;
  P: TServerEncodeParams;
  Enc: TEncoder;
  Res: TServerEncodeResult;
begin
  Head := DefaultResponseHead;
  Head.Headers := THttpHeaders.Create;
  Head.CaseMap := THttpHeaders.Create;
  try
    Head.Headers.Add('x-a', '1');
    Head.Headers.Add('x-a', '2');
    Head.Headers.Add('x-a', '3');
    Head.CaseMap.Add('X-A', '');
    Head.CaseMap.Add('x-A', '');
    P := DefaultEncodeParams;
    P.Body := blkKnown;
    P.BodyLen := 1;
    P.DateHeader := False;
    { the n-th spelling goes with the n-th value; then the lowercase name }
    AssertEquals('HTTP/1.1 200 OK'#13#10'X-A: 1'#13#10'x-A: 2'#13#10'x-a: 3'#13#10'content-length: 1'#13#10#13#10,
      EncodeStr(Head, P, Enc, Res));
    { title case only applies once the spellings run out }
    P.TitleCaseHeaders := True;
    AssertEquals('HTTP/1.1 200 OK'#13#10'X-A: 1'#13#10'x-A: 2'#13#10'X-A: 3'#13#10'Content-Length: 1'#13#10#13#10,
      EncodeStr(Head, P, Enc, Res));
    { more spellings than values: the extra ones are unused }
    Head.Headers.Clear;
    Head.Headers.Add('x-a', '1');
    Head.CaseMap.Add('X-a', '');
    AssertEquals('HTTP/1.1 200 OK'#13#10'X-A: 1'#13#10'Content-Length: 1'#13#10#13#10,
      EncodeStr(Head, P, Enc, Res));
  finally
    Head.Headers.Free;
    Head.CaseMap.Free;
  end;
end;

{ ---- allocation counting ---- }

var
  OldMM: TMemoryManager;
  AllocCount: PtrUInt = 0;

function CountGetMem(Size: PtrUInt): Pointer;
begin
  Inc(AllocCount);
  Result := OldMM.GetMem(Size);
end;

function CountAllocMem(Size: PtrUInt): Pointer;
begin
  Inc(AllocCount);
  Result := OldMM.AllocMem(Size);
end;

function CountReAllocMem(var P: Pointer; Size: PtrUInt): Pointer;
begin
  Inc(AllocCount);
  Result := OldMM.ReAllocMem(P, Size);
end;

procedure TTestRoleVerify.Extra_no_allocation_more_paths;
const
  Req: RawByteString = 'PUT http://example.com:8080/items/7?x=1 HTTP/1.1'#13#10'Host: example.com'#13#10 +
    'Content-Length: 12'#13#10'Transfer-Encoding: gzip, chunked'#13#10'Expect: 100-continue'#13#10 +
    'Upgrade: h2c'#13#10'Connection: keep-alive, Upgrade'#13#10#13#10;
var
  NewMM: TMemoryManager;
  H, RH, CM: THttpHeaders;
  Msg: TParsedRequestHead;
  Head: TResponseHead;
  P: TServerEncodeParams;
  Enc: TEncoder;
  Dst: TBytes;
  DstLen: SizeInt;
  I, N, K: Integer;
  St: TServerParseStatus;
  Count: PtrUInt;
  B: PByte;
  Ok1: Boolean;

  procedure EncodeAll;
  const
    Statuses: array[0..6] of Word = (200, 204, 304, 404, 101, 100, 500);
    Methods: array[0..3] of THttpMethod = (hmGet, hmHead, hmConnect, hmNone);
  var
    SI, MI: Integer;
    BK: TBodyLengthKind;
  begin
    for SI := 0 to High(Statuses) do
      for MI := 0 to High(Methods) do
        for BK := Low(TBodyLengthKind) to High(TBodyLengthKind) do
        begin
          Head.Status := Statuses[SI];
          P.ReqMethod := Methods[MI];
          P.Body := BK;
          P.BodyLen := 12;
          P.TitleCaseHeaders := (SI and 1) = 1;
          P.KeepAlive := (MI and 1) = 0;
          Head.CaseMap := nil;
          if MI = 2 then
            Head.CaseMap := CM;
          Head.Version := hv11;
          if SI = 3 then
            Head.Version := hv10;
          DstLen := 0;
          ServerEncode(Head, P, Dst, DstLen, Enc);
        end;
  end;

begin
  H := THttpHeaders.Create;
  RH := THttpHeaders.Create;
  CM := THttpHeaders.Create;
  try
    RH.Add('Content-Type', 'text/plain');
    RH.Add('Connection', 'close');
    RH.Add('x-a', '1');
    RH.Add('X-A', '2');
    CM.Add('CONTENT-TYPE', '');
    CM.Add('X-a', '');
    Head := DefaultResponseHead;
    Head.Headers := RH;
    P := DefaultEncodeParams;
    P.Date := PByte(Pointer(FIXED_DATE));
    SetLength(Dst, 4096);
    B := Guarded(Req);
    { warm up: grows the request header list once }
    AssertTrue(ServerParse(B, Length(Req), DefaultParseContext, H, Msg) = spsComplete);
    EncodeAll;

    GetMemoryManager(OldMM);
    NewMM := OldMM;
    NewMM.GetMem := @CountGetMem;
    NewMM.AllocMem := @CountAllocMem;
    NewMM.ReAllocMem := @CountReAllocMem;
    AllocCount := 0;
    Ok1 := True;
    SetMemoryManager(NewMM);
    try
      for K := 1 to 20 do
      begin
        { byte-at-a-time reads through the is_complete_fast path }
        N := Length(Req);
        for I := 1 to N do
        begin
          if I = 1 then
            St := ServerParseHeaders(B, I, -1, DefaultParseContext, H, Msg)
          else
            St := ServerParseHeaders(B, I, I - 1, DefaultParseContext, H, Msg);
          if (I < N) <> (St = spsPartial) then
            Ok1 := False;
        end;
        EncodeAll;
      end;
    finally
      SetMemoryManager(OldMM);
    end;
    Count := AllocCount;
    AssertTrue('incremental parse results', Ok1);
    AssertTrue(St = spsComplete);
    AssertEquals(DECODED_LENGTH_CHUNKED, Msg.Decode);
    AssertTrue(Msg.ExpectContinue);
    AssertTrue(Msg.WantsUpgrade);
    AssertFalse(Msg.KeepAlive);
    AssertEquals('allocations in parse+encode rounds', 0, Count);
  finally
    H.Free;
    RH.Free;
    CM.Free;
  end;
end;

procedure TTestRoleVerify.Extra_headers_left_empty_on_partial_and_error;
const
  Good: RawByteString = 'GET / HTTP/1.1'#13#10'Host: x'#13#10'A: b'#13#10#13#10;
var
  H: THttpHeaders;
  Msg: TParsedRequestHead;
begin
  { a header list reused across requests must not keep entries that point
    into an earlier buffer once a parse did not complete }
  H := THttpHeaders.Create;
  try
    AssertTrue(ParseG(Good, H, Msg) = spsComplete);
    AssertEquals(2, H.Count);
    { error before the header loop (http::Uri) }
    AssertTrue(ParseG('GET htt:p// HTTP/1.1'#13#10'Host: x'#13#10#13#10, H, Msg) = spsError);
    AssertEquals(0, H.Count);
    AssertTrue(ParseG(Good, H, Msg) = spsComplete);
    { error inside the header loop, after a stored header }
    AssertTrue(ParseG('POST / HTTP/1.1'#13#10'Host: x'#13#10'Content-Length: x'#13#10#13#10, H, Msg) = spsError);
    AssertEquals(0, H.Count);
    AssertTrue(ParseG(Good, H, Msg) = spsComplete);
    { error after the header loop }
    AssertTrue(ParseG('POST / HTTP/1.1'#13#10'Host: x'#13#10'Transfer-Encoding: gzip'#13#10#13#10, H, Msg) = spsError);
    AssertEquals(0, H.Count);
    AssertTrue(ParseG(Good, H, Msg) = spsComplete);
    { Partial from the full parser and from the fast path }
    AssertTrue(ParseG('GET / HTTP/1.1'#13#10'Host: x'#13#10, H, Msg) = spsPartial);
    AssertEquals(0, H.Count);
    AssertTrue(ParseG(Good, H, Msg) = spsComplete);
    AssertTrue(ServerParseHeaders(Guarded('GET / HTTP/1.1'#13#10), 16, 15, DefaultParseContext, H, Msg) = spsPartial);
    AssertEquals(0, H.Count);
    AssertTrue(ParseG(Good, H, Msg) = spsComplete);
    AssertTrue(ServerParseHeaders(nil, 0, -1, DefaultParseContext, H, Msg) = spsPartial);
    AssertEquals(0, H.Count);
  finally
    H.Free;
  end;
end;

initialization
  RegisterTest(TTestRoleVerify);
finalization
  if GBase <> nil then
    Fpmunmap(GBase, GSize);
end.

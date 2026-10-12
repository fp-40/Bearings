{ Extra tests of bearings.http1.role and bearings.http.uri (not hyper test ports).
  Each expected value was derived from hyper's role.rs / http 1.5.0 code;
  test_role_diff.sh checks the parse rules against hyper itself (the encode
  expectations here are fixed values since step T1).
  Test_wd_bench_* port the byte-length assertions of role.rs's nightly
  benches bench_server_encode_no_headers / bench_server_encode_headers_preset. }
unit test_role_extra;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  bearings.http1.parser, bearings.http.headers, bearings.http.uri, bearings.http1.encode,
  bearings.http1.reason, bearings.http1.role, test_role_server;

type
  TTestRoleExtra = class(TTestCase)
  published
    procedure Test_wd_parse_error_status_mapping;
    procedure Test_wd_parse_partial_and_fast_path;
    procedure Test_wd_parse_content_length_limits;
    procedure Test_wd_parse_expect_upgrade_connect_keepalive;
    procedure Test_wd_parse_headers_are_zero_copy;
    procedure Test_wd_uri_forms;
    procedure Test_wd_uri_rejects;
    procedure Test_wd_encode_body_rules;
    procedure Test_wd_encode_head_204_304;
    procedure Test_wd_encode_user_transfer_encoding;
    procedure Test_wd_encode_header_grouping;
    procedure Test_wd_encode_must_write_chunked_quirk;
    procedure Test_wd_encode_user_header_errors;
    procedure Test_wd_encode_unsupported_1xx;
    procedure Test_wd_encode_status_line;
    procedure Test_wd_encode_connection_close_and_keep_alive;
    procedure Test_wd_encode_trailer_fields;
    procedure Test_wd_encode_case_map_implicit_headers;
    procedure Test_wd_bench_server_encode_no_headers;
    procedure Test_wd_bench_server_encode_headers_preset;
    procedure Test_wd_encode_appends_and_reuses_buffer;
    procedure Test_wd_no_allocation_on_hot_paths;
  end;

implementation

const
  CRLF = #13#10;

function DateLine: RawByteString;
begin
  Result := 'date: ' + FIXED_DATE + CRLF;
end;

function Params(Body: TBodyLengthKind; BodyLen: QWord; Method: THttpMethod): TServerEncodeParams;
begin
  Result := DefaultEncodeParams;
  Result.Body := Body;
  Result.BodyLen := BodyLen;
  Result.ReqMethod := Method;
  Result.Date := PByte(Pointer(FIXED_DATE));
end;

function Enc1(Status: Word; const P: TServerEncodeParams; H: THttpHeaders;
  out Enc: TEncoder; out Res: TServerEncodeResult): RawByteString;
var
  Head: TResponseHead;
begin
  Head := DefaultResponseHead;
  Head.Status := Status;
  Head.Headers := H;
  Result := EncodeStr(Head, P, Enc, Res);
end;

{ ---- parse ---- }

procedure TTestRoleExtra.Test_wd_parse_error_status_mapping;
var
  H: THttpHeaders;
  Msg: TParsedRequestHead;
  S: RawByteString;
  I: Integer;
begin
  H := THttpHeaders.Create;
  try
    { Token before the method -> Parse::Method }
    AssertTrue(ParseStr('G@T / HTTP/1.1'#13#10#13#10, DefaultParseContext, H, Msg) = spsError);
    AssertTrue(Msg.Error = h1peMethod);
    AssertEquals(400, ServerErrorStatus(Msg.Error));
    { bad version }
    AssertTrue(ParseStr('GET / HTTP/2.0'#13#10#13#10, DefaultParseContext, H, Msg) = spsError);
    AssertTrue(Msg.Error = h1peVersion);
    AssertEquals(400, ServerErrorStatus(Msg.Error));
    { bad header byte -> Header(Token) }
    AssertTrue(ParseStr('GET / HTTP/1.1'#13#10'a'#1'b: c'#13#10#13#10, DefaultParseContext, H, Msg) = spsError);
    AssertTrue(Msg.Error = h1peHeaderToken);
    { 101 headers -> TooLarge -> 431 }
    S := 'GET / HTTP/1.1'#13#10;
    for I := 0 to 100 do
      S := S + 'k' + IntToStr(I) + ': v'#13#10;
    S := S + #13#10;
    AssertTrue(ParseStr(S, DefaultParseContext, H, Msg) = spsError);
    AssertTrue(Msg.Error = h1peTooLarge);
    AssertEquals(431, ServerErrorStatus(Msg.Error));
    { request-target longer than MAX_URI_LEN -> 414 }
    S := 'GET /' + StringOfChar('a', MAX_URI_LEN) + ' HTTP/1.1'#13#10#13#10;
    AssertTrue(ParseStr(S, DefaultParseContext, H, Msg) = spsError);
    AssertTrue(Msg.Error = h1peUriTooLong);
    AssertEquals(414, ServerErrorStatus(Msg.Error));
    { exactly MAX_URI_LEN is fine }
    S := 'GET /' + StringOfChar('a', MAX_URI_LEN - 1) + ' HTTP/1.1'#13#10#13#10;
    AssertTrue(ParseStr(S, DefaultParseContext, H, Msg) = spsComplete);
    { header name of 64 KiB -> TooLarge (record_header_indices) }
    S := 'GET / HTTP/1.1'#13#10 + StringOfChar('n', 1 shl 16) + ': v'#13#10#13#10;
    AssertTrue(ParseStr(S, DefaultParseContext, H, Msg) = spsError);
    AssertTrue(Msg.Error = h1peTooLarge);
    S := 'GET / HTTP/1.1'#13#10 + StringOfChar('n', (1 shl 16) - 1) + ': v'#13#10#13#10;
    AssertTrue(ParseStr(S, DefaultParseContext, H, Msg) = spsComplete);
    { errors without an automatic response }
    AssertEquals(0, ServerErrorStatus(h1peNone));
    AssertEquals(0, ServerErrorStatus(h1peInternal));
    AssertEquals(0, ServerErrorStatus(h1peStatus));
    AssertEquals(0, ServerErrorStatus(h1peVersionH2));
    AssertEquals('invalid URI', H1ParseErrorDescription(h1peUri));
  finally
    H.Free;
  end;
end;

procedure TTestRoleExtra.Test_wd_parse_partial_and_fast_path;
var
  H: THttpHeaders;
  Msg: TParsedRequestHead;
  S: RawByteString;
  N: Integer;
begin
  H := THttpHeaders.Create;
  try
    S := 'GET / HTTP/1.1'#13#10'Host: x'#13#10#13#10;
    for N := 1 to Length(S) - 1 do
      AssertTrue(IntToStr(N), ServerParse(PByte(Pointer(S)), N, DefaultParseContext, H, Msg) = spsPartial);
    { parse_headers: empty buffer }
    AssertTrue(ServerParseHeaders(nil, 0, -1, DefaultParseContext, H, Msg) = spsPartial);
    { prev_len given and no end of head in the new bytes: Partial without
      parsing, even for bytes that would be an error }
    AssertTrue(ServerParseHeaders(PByte(PAnsiChar('G@T / HTTP/1.1'#13#10)), 16, 10, DefaultParseContext, H, Msg) = spsPartial);
    AssertTrue(ServerParseHeaders(PByte(PAnsiChar('G@T / HTTP/1.1'#13#10)), 16, -1, DefaultParseContext, H, Msg) = spsError);
    AssertTrue(ServerParseHeaders(PByte(Pointer(S)), Length(S), Length(S) - 2, DefaultParseContext, H, Msg) = spsComplete);
    { body bytes after the head are not consumed }
    S := 'POST / HTTP/1.1'#13#10'content-length: 3'#13#10#13#10'abc';
    AssertTrue(ParseStr(S, DefaultParseContext, H, Msg) = spsComplete);
    AssertEquals(Length(S) - 3, Msg.HeadLen);
    AssertEquals(QWord(3), Msg.Decode);
  finally
    H.Free;
  end;
end;

procedure TTestRoleExtra.Test_wd_parse_content_length_limits;
var
  H: THttpHeaders;
  Msg: TParsedRequestHead;
begin
  H := THttpHeaders.Create;
  try
    { DecodedLength MAX_LEN = u64::MAX - 2 }
    AssertTrue(ParseStr('POST / HTTP/1.1'#13#10'content-length: 18446744073709551613'#13#10#13#10, DefaultParseContext, H, Msg) = spsComplete);
    AssertEquals(DECODED_LENGTH_MAX, Msg.Decode);
    AssertTrue(ParseStr('POST / HTTP/1.1'#13#10'content-length: 18446744073709551614'#13#10#13#10, DefaultParseContext, H, Msg) = spsError);
    AssertTrue(Msg.Error = h1peTooLarge);
    { overflow of u64 -> invalid }
    AssertTrue(ParseStr('POST / HTTP/1.1'#13#10'content-length: 18446744073709551616'#13#10#13#10, DefaultParseContext, H, Msg) = spsError);
    AssertTrue(Msg.Error = h1peHeaderContentLengthInvalid);
    { comma lists are not accepted in requests (content_length_parse) }
    AssertTrue(ParseStr('POST / HTTP/1.1'#13#10'content-length: 10, 10'#13#10#13#10, DefaultParseContext, H, Msg) = spsError);
    AssertTrue(Msg.Error = h1peHeaderContentLengthInvalid);
    { leading zeros are fine }
    AssertTrue(ParseStr('POST / HTTP/1.1'#13#10'content-length: 007'#13#10#13#10, DefaultParseContext, H, Msg) = spsComplete);
    AssertEquals(QWord(7), Msg.Decode);
    { the second equal Content-Length is not stored }
    AssertTrue(ParseStr('POST / HTTP/1.1'#13#10'Content-Length: 4'#13#10'content-length: 4'#13#10#13#10, DefaultParseContext, H, Msg) = spsComplete);
    AssertEquals(1, H.Count);
    AssertEquals('Content-Length', H.Name(0));
  finally
    H.Free;
  end;
end;

procedure TTestRoleExtra.Test_wd_parse_expect_upgrade_connect_keepalive;
var
  H: THttpHeaders;
  Msg: TParsedRequestHead;
  S: RawByteString;
begin
  H := THttpHeaders.Create;
  try
    AssertTrue(ParseStr('POST / HTTP/1.1'#13#10'Expect: 100-Continue'#13#10'content-length: 1'#13#10#13#10, DefaultParseContext, H, Msg) = spsComplete);
    AssertTrue(Msg.ExpectContinue);
    AssertTrue(ParseStr('POST / HTTP/1.1'#13#10'Expect: 100-continue, x'#13#10#13#10, DefaultParseContext, H, Msg) = spsComplete);
    AssertFalse(Msg.ExpectContinue);
    { the last Expect line decides }
    AssertTrue(ParseStr('POST / HTTP/1.1'#13#10'Expect: 100-continue'#13#10'Expect: x'#13#10#13#10, DefaultParseContext, H, Msg) = spsComplete);
    AssertFalse(Msg.ExpectContinue);

    AssertTrue(ParseStr('GET / HTTP/1.1'#13#10'Upgrade: websocket'#13#10#13#10, DefaultParseContext, H, Msg) = spsComplete);
    AssertTrue(Msg.WantsUpgrade);
    AssertTrue(ParseStr('GET / HTTP/1.0'#13#10'Upgrade: websocket'#13#10#13#10, DefaultParseContext, H, Msg) = spsComplete);
    AssertFalse(Msg.WantsUpgrade);

    S := 'CONNECT example.com:443 HTTP/1.1'#13#10#13#10;
    AssertTrue(ParseStr(S, DefaultParseContext, H, Msg) = spsComplete);
    AssertTrue(Msg.Method = hmConnect);
    AssertTrue(Msg.WantsUpgrade);
    AssertTrue(Msg.Uri.HasAuthority);
    AssertEquals('example.com:443', Copy(S, Msg.Uri.AuthorityOff + 1, Msg.Uri.AuthorityLen));
    { CONNECT on 1.0 is still an upgrade (only Upgrade: needs 1.1) }
    AssertTrue(ParseStr('CONNECT h:1 HTTP/1.0'#13#10#13#10, DefaultParseContext, H, Msg) = spsComplete);
    AssertTrue(Msg.WantsUpgrade);

    AssertTrue(ParseStr('GET / HTTP/1.0'#13#10#13#10, DefaultParseContext, H, Msg) = spsComplete);
    AssertFalse(Msg.KeepAlive);
    AssertTrue(Msg.Version = hv10);
    AssertTrue(ParseStr('GET / HTTP/1.0'#13#10'Connection: Keep-Alive'#13#10#13#10, DefaultParseContext, H, Msg) = spsComplete);
    AssertTrue(Msg.KeepAlive);
    AssertTrue(ParseStr('GET / HTTP/1.1'#13#10'Connection: foo, CLOSE'#13#10#13#10, DefaultParseContext, H, Msg) = spsComplete);
    AssertFalse(Msg.KeepAlive);

    AssertTrue(MethodFromBytes(PByte(PAnsiChar('get')), 3) = hmExtension);
    AssertTrue(MethodFromBytes(PByte(PAnsiChar('OPTIONS')), 7) = hmOptions);
    AssertEquals('PATCH', HttpMethodName(hmPatch));
  finally
    H.Free;
  end;
end;

procedure TTestRoleExtra.Test_wd_parse_headers_are_zero_copy;
var
  H: THttpHeaders;
  Msg: TParsedRequestHead;
  S: RawByteString;
  B: PByte;
begin
  H := THttpHeaders.Create;
  try
    S := 'GET /x HTTP/1.1'#13#10'Host: example.com'#13#10'X-Y:  z  '#13#10#13#10;
    B := PByte(Pointer(S));
    AssertTrue(ParseStr(S, DefaultParseContext, H, Msg) = spsComplete);
    AssertEquals(2, H.Count);
    AssertTrue(H.ExternalBase = B);
    AssertTrue(H.NamePtr(0) = B + 17);
    AssertTrue(H.ValuePtr(0) = B + 23);
    AssertEquals('z', H.Value(1));
    { reusing the list for the next request clears it }
    AssertTrue(ParseStr('GET / HTTP/1.1'#13#10#13#10, DefaultParseContext, H, Msg) = spsComplete);
    AssertEquals(0, H.Count);
  finally
    H.Free;
  end;
end;

{ ---- uri ---- }

procedure TTestRoleExtra.Test_wd_uri_forms;

  procedure Check(const T: RawByteString; Scheme: TUriScheme; const SchemeS, Auth, Path: RawByteString;
    HasQuery: Boolean; const Query: RawByteString);
  var
    U: TUriParts;
    E: TUriError;
    P: PByte;
    L: SizeInt;
    B: PByte;
  begin
    B := PByte(Pointer(T));
    AssertTrue(T, ParseUri(B, Length(T), U, E));
    AssertTrue(T + ' scheme', U.Scheme = Scheme);
    AssertEquals(T + ' scheme bytes', SchemeS, Copy(T, U.SchemeOff + 1, U.SchemeLen));
    AssertEquals(T + ' authority', Auth, Copy(T, U.AuthorityOff + 1, U.AuthorityLen));
    U.GetPath(B, P, L);
    AssertEquals(T + ' path', Path, Copy(PAnsiChar(P), 1, L));
    AssertEquals(T + ' has query', HasQuery, U.GetQuery(B, P, L));
    if HasQuery then
      AssertEquals(T + ' query', Query, Copy(PAnsiChar(P), 1, L));
  end;

begin
  Check('/', usNone, '', '', '/', False, '');
  Check('*', usNone, '', '', '*', False, '');
  Check('/a/b?c=d', usNone, '', '', '/a/b', True, 'c=d');
  Check('/a?', usNone, '', '', '/a', True, '');
  Check('/a#frag?x', usNone, '', '', '/a', False, '');
  Check('/a?b#c', usNone, '', '', '/a', True, 'b');
  Check('/{"json"}', usNone, '', '', '/{"json"}', False, '');
  Check('example.com:443', usNone, '', 'example.com:443', '', False, '');
  Check('x', usNone, '', 'x', '', False, '');
  Check('[::1]:8080', usNone, '', '[::1]:8080', '', False, '');
  Check('http://example.com', usHttp, 'http', 'example.com', '/', False, '');
  Check('HTTPS://h:1/p?q', usHttps, 'HTTPS', 'h:1', '/p', True, 'q');
  Check('http://h?q', usHttp, 'http', 'h', '/', True, 'q');
  Check('ftp://x/y', usOther, 'ftp', 'x', '/y', False, '');
  Check('http://u:p@h:1/', usHttp, 'http', 'u:p@h:1', '/', False, '');
  Check('http://[fe80::1%25en0]/', usHttp, 'http', '[fe80::1%25en0]', '/', False, '');
  Check('http://u%41@h/', usHttp, 'http', 'u%41@h', '/', False, '');
end;

procedure TTestRoleExtra.Test_wd_uri_rejects;

  procedure Bad(const T: RawByteString; Expect: TUriError);
  var
    U: TUriParts;
    E: TUriError;
  begin
    AssertFalse(T, ParseUri(PByte(Pointer(T)), Length(T), U, E));
    AssertEquals(T, Ord(Expect), Ord(E));
  end;

begin
  Bad('', ueEmpty);
  Bad('htt:p//', ueInvalidFormat);
  Bad('example.com/path', ueInvalidFormat);
  Bad('a:b:c', ueInvalidAuthority);
  Bad('localhost:8080:3030', ueInvalidAuthority);
  Bad('user@', ueInvalidAuthority);
  Bad('h%20st', ueInvalidAuthority);
  Bad('[::1', ueInvalidAuthority);
  Bad('::1]', ueInvalidAuthority);
  Bad('a^b', ueInvalidUriChar);
  Bad('%', ueInvalidAuthority);
  Bad('http://', ueEmpty);
  Bad('http:///', ueInvalidFormat);
  Bad('/a b', ueInvalidUriChar);
  Bad('/<', ueInvalidUriChar);
  Bad('/a?<', ueInvalidUriChar);
  Bad('/'#$FF, ueInvalidUriChar);
  Bad(StringOfChar('a', 65) + '://h/', ueSchemeTooLong);
  Bad('/' + StringOfChar('a', URI_MAX_LEN), ueTooLong);
  AssertEquals('invalid format', UriErrorDescription(ueInvalidFormat));
end;

{ ---- encode ---- }

procedure TTestRoleExtra.Test_wd_encode_body_rules;
var
  Enc: TEncoder;
  Res: TServerEncodeResult;
  P: TServerEncodeParams;
  Head: TResponseHead;
begin
  { None -> implicit content-length: 0 }
  AssertEquals('HTTP/1.1 200 OK'#13#10'content-length: 0'#13#10 + DateLine + CRLF,
    Enc1(200, Params(blkNone, 0, hmGet), nil, Enc, Res));
  AssertTrue(Enc.Kind = ekLength);
  AssertEquals(QWord(0), Enc.Remaining);
  AssertFalse(Enc.IsLast);
  { Known(10) }
  AssertEquals('HTTP/1.1 200 OK'#13#10'content-length: 10'#13#10 + DateLine + CRLF,
    Enc1(200, Params(blkKnown, 10, hmGet), nil, Enc, Res));
  AssertEquals(QWord(10), Enc.Remaining);
  { Unknown, HTTP/1.1 -> chunked }
  AssertEquals('HTTP/1.1 200 OK'#13#10'transfer-encoding: chunked'#13#10 + DateLine + CRLF,
    Enc1(200, Params(blkUnknown, 0, hmGet), nil, Enc, Res));
  AssertTrue(Enc.IsChunked);
  { Unknown, HTTP/1.0 -> close-delimited, no framing header }
  P := Params(blkUnknown, 0, hmGet);
  Head := DefaultResponseHead;
  Head.Version := hv10;
  AssertEquals('HTTP/1.0 200 OK'#13#10 + DateLine + CRLF, EncodeStr(Head, P, Enc, Res));
  AssertTrue(Enc.IsCloseDelimited);
  { Known(0) behaves like None }
  AssertEquals('HTTP/1.1 200 OK'#13#10'content-length: 0'#13#10 + DateLine + CRLF,
    Enc1(200, Params(blkKnown, 0, hmGet), nil, Enc, Res));
end;

procedure TTestRoleExtra.Test_wd_encode_head_204_304;
var
  Enc: TEncoder;
  Res: TServerEncodeResult;
begin
  { HEAD + Known(10): the length is announced, no body is sent }
  AssertEquals('HTTP/1.1 200 OK'#13#10'content-length: 10'#13#10 + DateLine + CRLF,
    Enc1(200, Params(blkKnown, 10, hmHead), nil, Enc, Res));
  AssertTrue(Enc.Kind = ekLength);
  AssertEquals(QWord(0), Enc.Remaining);
  { HEAD + None: no implicit content-length: 0 }
  AssertEquals('HTTP/1.1 200 OK'#13#10 + DateLine + CRLF,
    Enc1(200, Params(blkNone, 0, hmHead), nil, Enc, Res));
  { HEAD + Unknown: not chunked }
  AssertEquals('HTTP/1.1 200 OK'#13#10 + DateLine + CRLF,
    Enc1(200, Params(blkUnknown, 0, hmHead), nil, Enc, Res));
  AssertEquals(QWord(0), Enc.Remaining);
  AssertTrue(Enc.Kind = ekLength);
  { 204 / 304: no content-length, no body }
  AssertEquals('HTTP/1.1 204 No Content'#13#10 + DateLine + CRLF,
    Enc1(204, Params(blkKnown, 10, hmGet), nil, Enc, Res));
  AssertEquals(QWord(0), Enc.Remaining);
  AssertEquals('HTTP/1.1 304 Not Modified'#13#10 + DateLine + CRLF,
    Enc1(304, Params(blkUnknown, 0, hmGet), nil, Enc, Res));
  AssertTrue(Enc.Kind = ekLength);
  { 2xx to CONNECT: nothing, and the connection becomes a tunnel }
  AssertEquals('HTTP/1.1 200 OK'#13#10 + DateLine + CRLF,
    Enc1(200, Params(blkUnknown, 0, hmConnect), nil, Enc, Res));
  AssertTrue(Enc.IsLast);
  { non-2xx to CONNECT: normal framing }
  AssertEquals('HTTP/1.1 400 Bad Request'#13#10'content-length: 0'#13#10 + DateLine + CRLF,
    Enc1(400, Params(blkNone, 0, hmConnect), nil, Enc, Res));
end;

procedure TTestRoleExtra.Test_wd_encode_user_transfer_encoding;
var
  H: THttpHeaders;
  Enc: TEncoder;
  Res: TServerEncodeResult;
begin
  H := THttpHeaders.Create;
  try
    H.Add('Transfer-Encoding', 'gzip');
    AssertEquals('HTTP/1.1 200 OK'#13#10'transfer-encoding: gzip, chunked'#13#10 + DateLine + CRLF,
      Enc1(200, Params(blkUnknown, 0, hmGet), H, Enc, Res));
    AssertTrue(Enc.IsChunked);
    { two lines are joined into one }
    H.Add('transfer-encoding', 'chunked');
    AssertEquals('HTTP/1.1 200 OK'#13#10'transfer-encoding: gzip, chunked'#13#10 + DateLine + CRLF,
      Enc1(200, Params(blkKnown, 5, hmGet), H, Enc, Res));
    AssertTrue(Enc.IsChunked);
    { user content-length with an unknown body length }
    H.Clear;
    H.Add('content-length', '42');
    AssertEquals('HTTP/1.1 200 OK'#13#10'content-length: 42'#13#10 + DateLine + CRLF,
      Enc1(200, Params(blkUnknown, 0, hmGet), H, Enc, Res));
    AssertEquals(QWord(42), Enc.Remaining);
    { None body: a content-length header is dropped (not HEAD) }
    AssertEquals('HTTP/1.1 200 OK'#13#10'content-length: 0'#13#10 + DateLine + CRLF,
      Enc1(200, Params(blkNone, 0, hmGet), H, Enc, Res));
  finally
    H.Free;
  end;
end;

procedure TTestRoleExtra.Test_wd_encode_header_grouping;
var
  H: THttpHeaders;
  Enc: TEncoder;
  Res: TServerEncodeResult;
  P: TServerEncodeParams;
begin
  H := THttpHeaders.Create;
  try
    H.Add('a', '1');
    H.Add('B', '2');
    H.Add('A', '3');
    H.Add('c', '4');
    H.Add('b', '5');
    P := Params(blkKnown, 0, hmGet);
    P.DateHeader := False;
    { HeaderMap::drain order: names in order of first appearance }
    AssertEquals('HTTP/1.1 200 OK'#13#10'a: 1'#13#10'a: 3'#13#10'b: 2'#13#10'b: 5'#13#10'c: 4'#13#10'content-length: 0'#13#10#13#10,
      Enc1(200, P, H, Enc, Res));
    { a user date header suppresses the automatic one }
    H.Clear;
    H.Add('Date', 'x');
    P.DateHeader := True;
    AssertEquals('HTTP/1.1 200 OK'#13#10'date: x'#13#10'content-length: 0'#13#10#13#10,
      Enc1(200, P, H, Enc, Res));
  finally
    H.Free;
  end;
end;

procedure TTestRoleExtra.Test_wd_encode_must_write_chunked_quirk;
var
  H: THttpHeaders;
  Enc: TEncoder;
  Res: TServerEncodeResult;
begin
  { hyper sets must_write_chunked for a Transfer-Encoding not ending in
    chunked and never clears it, so the next special header group
    (connection, trailer, a second content-length group) also gets
    ', chunked'. Reproduced on purpose (hyper's output, checked by the
    role encode differential before step T1). }
  H := THttpHeaders.Create;
  try
    H.Add('transfer-encoding', 'gzip');
    H.Add('connection', 'close');
    AssertEquals('HTTP/1.1 200 OK'#13#10'transfer-encoding: gzip, chunked'#13#10'connection: close, chunked'#13#10 +
      DateLine + CRLF, Enc1(200, Params(blkUnknown, 0, hmGet), H, Enc, Res));
    AssertTrue(Enc.IsLast);
  finally
    H.Free;
  end;
end;

procedure TTestRoleExtra.Test_wd_encode_user_header_errors;
var
  H: THttpHeaders;
  Enc: TEncoder;
  Res: TServerEncodeResult;
  Head: TResponseHead;
  Dst: TBytes;
  DstLen: SizeInt;
begin
  H := THttpHeaders.Create;
  try
    Head := DefaultResponseHead;
    Head.Headers := H;
    { illegal content-length with an unknown body: rewind }
    H.Add('content-length', 'abc');
    SetLength(Dst, 4);
    Dst[0] := Ord('x');
    DstLen := 1;
    Res := ServerEncode(Head, Params(blkUnknown, 0, hmGet), Dst, DstLen, Enc);
    AssertTrue(Res = serUserHeader);
    AssertEquals(1, DstLen);
    { different content-length values }
    H.Clear;
    H.Add('content-length', '1');
    H.Add('content-length', '2');
    AssertTrue(ServerEncode(Head, Params(blkUnknown, 0, hmGet), Dst, DstLen, Enc) = serUserHeader);
    { equal values are written once }
    H.Clear;
    H.Add('content-length', '2');
    H.Add('content-length', '2');
    AssertEquals('HTTP/1.1 200 OK'#13#10'content-length: 2'#13#10 + DateLine + CRLF,
      Enc1(200, Params(blkUnknown, 0, hmGet), H, Enc, Res));
    { content-length then transfer-encoding }
    H.Clear;
    H.Add('content-length', '2');
    H.Add('transfer-encoding', 'chunked');
    AssertTrue(ServerEncode(Head, Params(blkKnown, 2, hmGet), Dst, DstLen, Enc) = serUserHeader);
    { a 2xx CONNECT response must not carry content-length }
    H.Clear;
    H.Add('content-length', '0');
    AssertTrue(ServerEncode(Head, Params(blkKnown, 0, hmConnect), Dst, DstLen, Enc) = serUserHeader);
    { HEAD with no body keeps the header; a second one is an error }
    H.Clear;
    H.Add('content-length', '7');
    AssertEquals('HTTP/1.1 200 OK'#13#10'content-length: 7'#13#10 + DateLine + CRLF,
      Enc1(200, Params(blkNone, 0, hmHead), H, Enc, Res));
    H.Add('content-length', '7');
    AssertTrue(ServerEncode(Head, Params(blkNone, 0, hmHead), Dst, DstLen, Enc) = serUserHeader);
    AssertEquals(1, DstLen);
  finally
    H.Free;
  end;
end;

procedure TTestRoleExtra.Test_wd_encode_unsupported_1xx;
var
  H: THttpHeaders;
  Enc: TEncoder;
  Res: TServerEncodeResult;
  S: RawByteString;
begin
  H := THttpHeaders.Create;
  try
    H.Add('x-a', '1');
    S := Enc1(100, Params(blkKnown, 10, hmGet), H, Enc, Res);
    AssertTrue(Res = serUnsupportedStatusCode);
    { MessageHead::default() with status 500: the user headers are gone }
    AssertEquals('HTTP/1.1 500 Internal Server Error'#13#10'content-length: 0'#13#10 + DateLine + CRLF, S);
    AssertTrue(Enc.IsLast);
    { 101 is allowed and is last }
    S := Enc1(101, Params(blkNone, 0, hmGet), nil, Enc, Res);
    AssertTrue(Res = serOk);
    AssertEquals('HTTP/1.1 101 Switching Protocols'#13#10 + DateLine + CRLF, S);
    AssertTrue(Enc.IsLast);
  finally
    H.Free;
  end;
end;

procedure TTestRoleExtra.Test_wd_encode_status_line;
var
  Head: TResponseHead;
  P: TServerEncodeParams;
  Enc: TEncoder;
  Res: TServerEncodeResult;
  Phrase: TReasonPhrase;
begin
  P := Params(blkKnown, 0, hmGet);
  P.DateHeader := False;
  Head := DefaultResponseHead;
  Head.Version := hv10;
  AssertEquals('HTTP/1.0 200 OK'#13#10'content-length: 0'#13#10#13#10, EncodeStr(Head, P, Enc, Res));
  Head.Version := hv11;
  Head.Status := 599;
  AssertEquals('HTTP/1.1 599 <none>'#13#10'content-length: 0'#13#10#13#10, EncodeStr(Head, P, Enc, Res));
  Head.Status := 200;
  Head.HasReason := TReasonPhrase.TryFrom('Awesome', Phrase);
  Head.ReasonP := Phrase.Data;     { M3 S0: TResponseHead holds a slice }
  Head.ReasonLen := Phrase.Len;
  AssertEquals('HTTP/1.1 200 Awesome'#13#10'content-length: 0'#13#10#13#10, EncodeStr(Head, P, Enc, Res));
  Head.HasReason := False;
  Head.Version := hv09;
  try
    EncodeStr(Head, P, Enc, Res);
    Fail('HTTP/0.9 response must raise');
  except
    on E: EArgumentException do ;
  end;
end;

procedure TTestRoleExtra.Test_wd_encode_connection_close_and_keep_alive;
var
  H: THttpHeaders;
  Enc: TEncoder;
  Res: TServerEncodeResult;
  P: TServerEncodeParams;
begin
  H := THttpHeaders.Create;
  try
    H.Add('Connection', 'close');
    AssertEquals('HTTP/1.1 200 OK'#13#10'connection: close'#13#10'content-length: 0'#13#10 + DateLine + CRLF,
      Enc1(200, Params(blkNone, 0, hmGet), H, Enc, Res));
    AssertTrue(Enc.IsLast);
    H.Clear;
    H.Add('connection', 'keep-alive');
    H.Add('connection', 'upgrade');
    AssertEquals('HTTP/1.1 200 OK'#13#10'connection: keep-alive, upgrade'#13#10'content-length: 0'#13#10 + DateLine + CRLF,
      Enc1(200, Params(blkNone, 0, hmGet), H, Enc, Res));
    AssertFalse(Enc.IsLast);
    { keep_alive = false: last }
    P := Params(blkNone, 0, hmGet);
    P.KeepAlive := False;
    Enc1(200, P, nil, Enc, Res);
    AssertTrue(Enc.IsLast);
  finally
    H.Free;
  end;
end;

procedure TTestRoleExtra.Test_wd_encode_trailer_fields;
var
  H, T: THttpHeaders;
  Enc: TEncoder;
  Res: TServerEncodeResult;
  B: TBytes;
  S: RawByteString;
begin
  H := THttpHeaders.Create;
  T := THttpHeaders.Create;
  try
    H.Add('trailer', 'chunky-trailer');
    AssertEquals('HTTP/1.1 200 OK'#13#10'trailer: chunky-trailer'#13#10'transfer-encoding: chunked'#13#10 + DateLine + CRLF,
      Enc1(200, Params(blkUnknown, 0, hmGet), H, Enc, Res));
    AssertTrue(Enc.IsChunked);
    T.Add('chunky-trailer', 'header data');
    T.Add('x-other', 'no');
    AssertTrue(Enc.EncodeTrailers(T, False, B));
    SetLength(S, Length(B));
    Move(B[0], Pointer(S)^, Length(B));
    AssertEquals('0'#13#10'chunky-trailer: header data'#13#10#13#10, S);
    { HTTP/1.0 or a HEAD response drops the Trailer header }
    AssertEquals('HTTP/1.1 200 OK'#13#10 + DateLine + CRLF,
      Enc1(200, Params(blkUnknown, 0, hmHead), H, Enc, Res));
  finally
    H.Free;
    T.Free;
  end;
end;

procedure TTestRoleExtra.Test_wd_encode_case_map_implicit_headers;
var
  Head: TResponseHead;
  P: TServerEncodeParams;
  Enc: TEncoder;
  Res: TServerEncodeResult;
begin
  { the case map also spells the implicit content-length and date lines }
  Head := DefaultResponseHead;
  Head.CaseMap := THttpHeaders.Create;
  try
    Head.CaseMap.Add('CONTENT-length', '');
    Head.CaseMap.Add('DaTe', '');
    P := Params(blkKnown, 3, hmGet);
    AssertEquals('HTTP/1.1 200 OK'#13#10'CONTENT-length: 3'#13#10'DaTe: ' + FIXED_DATE + #13#10#13#10,
      EncodeStr(Head, P, Enc, Res));
    { the response's own list as its case map: names as stored }
    Head.CaseMap.Clear;
    Head.Headers := Head.CaseMap;
    Head.Headers.Add('X-Custom-HEADER', 'v');
    AssertEquals('HTTP/1.1 200 OK'#13#10'X-Custom-HEADER: v'#13#10'content-length: 3'#13#10'date: ' + FIXED_DATE + #13#10#13#10,
      EncodeStr(Head, P, Enc, Res));
  finally
    Head.CaseMap.Free;
  end;
end;

procedure TTestRoleExtra.Test_wd_bench_server_encode_no_headers;
var
  Head: TResponseHead;
  P: TServerEncodeParams;
  Enc: TEncoder;
  Res: TServerEncodeResult;
begin
  Head := DefaultResponseHead;
  P := DefaultEncodeParams;
  P.Body := blkKnown;
  P.BodyLen := 10;
  P.ReqMethod := hmGet;
  AssertEquals(76, Length(EncodeStr(Head, P, Enc, Res)));
end;

procedure TTestRoleExtra.Test_wd_bench_server_encode_headers_preset;
var
  Head: TResponseHead;
  P: TServerEncodeParams;
  Enc: TEncoder;
  Res: TServerEncodeResult;
begin
  Head := DefaultResponseHead;
  Head.Headers := THttpHeaders.Create;
  try
    Head.Headers.Insert('content-length', '10');
    Head.Headers.Insert('content-type', 'application/json');
    P := DefaultEncodeParams;
    P.Body := blkKnown;
    P.BodyLen := 10;
    P.ReqMethod := hmGet;
    AssertEquals(108, Length(EncodeStr(Head, P, Enc, Res)));
  finally
    Head.Headers.Free;
  end;
end;

procedure TTestRoleExtra.Test_wd_encode_appends_and_reuses_buffer;
var
  Head: TResponseHead;
  P: TServerEncodeParams;
  Enc: TEncoder;
  Dst: TBytes;
  DstLen: SizeInt;
  Before: Pointer;
  S: RawByteString;
begin
  Head := DefaultResponseHead;
  P := Params(blkKnown, 10, hmGet);
  SetLength(Dst, 4096);
  Before := @Dst[0];
  Dst[0] := Ord('!');
  DstLen := 1;
  AssertTrue(ServerEncode(Head, P, Dst, DstLen, Enc) = serOk);
  AssertTrue(ServerEncode(Head, P, Dst, DstLen, Enc) = serOk);
  AssertTrue(Before = Pointer(@Dst[0]));
  SetLength(S, DstLen);
  Move(Dst[0], Pointer(S)^, DstLen);
  AssertEquals('!' + 'HTTP/1.1 200 OK'#13#10'content-length: 10'#13#10 + DateLine + CRLF +
    'HTTP/1.1 200 OK'#13#10'content-length: 10'#13#10 + DateLine + CRLF, S);
  { growing from an empty buffer }
  Dst := nil;
  DstLen := 0;
  AssertTrue(ServerEncode(Head, P, Dst, DstLen, Enc) = serOk);
  AssertEquals(76, DstLen);
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

procedure TTestRoleExtra.Test_wd_no_allocation_on_hot_paths;
var
  NewMM: TMemoryManager;
  H, RH: THttpHeaders;
  Msg: TParsedRequestHead;
  Req: RawByteString;
  Head: TResponseHead;
  P: TServerEncodeParams;
  Enc: TEncoder;
  Dst: TBytes;
  DstLen: SizeInt;
  I: Integer;
  St: TServerParseStatus;
  Count: PtrUInt;
begin
  Req := 'POST /api/items?id=7 HTTP/1.1'#13#10'Host: example.com'#13#10'User-Agent: x'#13#10 +
    'Content-Type: application/json'#13#10'Content-Length: 12'#13#10'Connection: keep-alive'#13#10 +
    'Accept: */*'#13#10#13#10'{"a":"bcd"}';
  H := THttpHeaders.Create;
  RH := THttpHeaders.Create;
  try
    RH.Add('content-type', 'application/json');
    RH.Add('server', 'wd-40');
    Head := DefaultResponseHead;
    Head.Headers := RH;
    P := Params(blkKnown, 12, hmPost);
    SetLength(Dst, 4096);
    { warm up: grows the header list once }
    St := ParseStr(Req, DefaultParseContext, H, Msg);
    AssertTrue(St = spsComplete);
    DstLen := 0;
    ServerEncode(Head, P, Dst, DstLen, Enc);

    GetMemoryManager(OldMM);
    NewMM := OldMM;
    NewMM.GetMem := @CountGetMem;
    NewMM.AllocMem := @CountAllocMem;
    NewMM.ReAllocMem := @CountReAllocMem;
    AllocCount := 0;
    SetMemoryManager(NewMM);
    try
      for I := 1 to 100 do
      begin
        St := ServerParse(PByte(Pointer(Req)), Length(Req), DefaultParseContext, H, Msg);
        DstLen := 0;
        ServerEncode(Head, P, Dst, DstLen, Enc);
      end;
    finally
      SetMemoryManager(OldMM);
    end;
    Count := AllocCount;
    AssertTrue(St = spsComplete);
    AssertEquals(6, H.Count);
    AssertEquals('allocations in 100 parse+encode rounds', 0, Count);
  finally
    H.Free;
    RH.Free;
  end;
end;

initialization
  RegisterTest(TTestRoleExtra);
end.

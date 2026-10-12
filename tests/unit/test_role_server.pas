{ Ports of the server-side unit tests of hyper v1.12.0
  src/proto/h1/role.rs, plus the unit-category tests of tests/server.rs
  (http1_response_with_http2_version, http1_trailer_recv_fields) and
  src/proto/h1/conn.rs (conn_writes_chunked_body).

  Methods named Test_<hyper name>_request_variant / _server_variant port a
  client-side role.rs test to the server side, as its catalog port note
  asks. }
unit test_role_server;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  bearings.http1.parser, bearings.http.headers, bearings.http.uri, bearings.http1.encode,
  bearings.http1.decode, bearings.http.date, bearings.http1.role;

type
  TTestRoleServer = class(TTestCase)
  published
    { role.rs, server side }
    procedure Test_parse_request;
    procedure Test_parse_request_errors;
    procedure Test_parse_allow_request_with_multiple_spaces_in_request_line;
    procedure Test_parse_reject_request_with_multiple_spaces_in_request_line;
    procedure Test_parse_preserve_header_case_in_request;
    procedure Test_decoder_request;
    procedure Test_parse_request_multiple_connection_headers;
    procedure Test_server_encode_connect_method;
    procedure Test_server_response_encode_title_case;
    procedure Test_server_response_encode_orig_case;
    procedure Test_server_response_encode_orig_and_title_case;
    procedure Test_disabled_date_header;
    procedure Test_parse_too_large_headers;
    procedure Test_h1_server_max_header_size;
    procedure Test_is_complete_fast;
    procedure Test_parse_accepts_lf_crlf_terminator;
    { role.rs client tests ported to the server side }
    procedure Test_parse_reject_response_with_spaces_before_colons_request_variant;
    procedure Test_parse_header_htabs_request_variant;
    procedure Test_client_obs_fold_line_request_variant;
    procedure Test_client_request_encode_title_case_server_variant;
    procedure Test_write_headers_orig_case_empty_value_server_variant;
    procedure Test_write_headers_orig_case_multiple_entries_server_variant;
    { tests/server.rs }
    procedure Test_http1_response_with_http2_version;
    procedure Test_http1_trailer_recv_fields;
    { conn.rs }
    procedure Test_conn_writes_chunked_body;
  end;

{ shared helpers (also used by test_role_extra) }
const
  FIXED_DATE: RawByteString = 'Sun, 06 Nov 1994 08:49:37 GMT';

function ParseStr(const S: RawByteString; const Ctx: TH1ParseContext; H: THttpHeaders;
  out Msg: TParsedRequestHead): TServerParseStatus;
function SliceStr(const S: RawByteString; const Sl: TSlice): RawByteString;
function EncodeStr(const Head: TResponseHead; const P: TServerEncodeParams;
  out Encoder: TEncoder; out Res: TServerEncodeResult): RawByteString;

implementation

function ParseStr(const S: RawByteString; const Ctx: TH1ParseContext; H: THttpHeaders;
  out Msg: TParsedRequestHead): TServerParseStatus;
begin
  Result := ServerParse(PByte(Pointer(S)), Length(S), Ctx, H, Msg);
end;

function SliceStr(const S: RawByteString; const Sl: TSlice): RawByteString;
begin
  Result := Copy(S, Sl.Off + 1, Sl.Len);
end;

function EncodeStr(const Head: TResponseHead; const P: TServerEncodeParams;
  out Encoder: TEncoder; out Res: TServerEncodeResult): RawByteString;
var
  Dst: TBytes;
  DstLen: SizeInt;
begin
  Dst := nil;
  DstLen := 0;
  Res := ServerEncode(Head, P, Dst, DstLen, Encoder);
  SetLength(Result, DstLen);
  if DstLen > 0 then
    Move(Dst[0], Pointer(Result)^, DstLen);
end;

function StartsWith(const S, Prefix: RawByteString): Boolean;
begin
  Result := Copy(S, 1, Length(Prefix)) = Prefix;
end;

{ ---- role.rs ---- }

procedure TTestRoleServer.Test_parse_request;
var
  Raw: RawByteString;
  H: THttpHeaders;
  Msg: TParsedRequestHead;
  P: PByte;
  L: SizeInt;
begin
  Raw := 'GET /echo HTTP/1.1'#13#10'Host: hyper.rs'#13#10#13#10;
  H := THttpHeaders.Create;
  try
    AssertTrue(ParseStr(Raw, DefaultParseContext, H, Msg) = spsComplete);
    { raw.len() == 0: the whole buffer is the head }
    AssertEquals(Length(Raw), Msg.HeadLen);
    AssertTrue(Msg.Method = hmGet);
    AssertEquals('GET', SliceStr(Raw, Msg.MethodSlice));
    AssertEquals('/echo', SliceStr(Raw, Msg.Target));
    Msg.Uri.GetPath(PByte(Pointer(Raw)), P, L);
    AssertEquals(5, L);
    AssertEquals(0, CompareByte(P^, PAnsiChar('/echo')^, 5));
    AssertTrue(Msg.Version = hv11);
    AssertEquals(1, H.Count);
    AssertEquals('hyper.rs', H.GetValue('Host'));
    { ctx.req_method = Some(GET) }
    AssertTrue(Msg.Method = hmGet);
  finally
    H.Free;
  end;
end;

procedure TTestRoleServer.Test_parse_request_errors;
var
  H: THttpHeaders;
  Msg: TParsedRequestHead;
begin
  H := THttpHeaders.Create;
  try
    AssertTrue(ParseStr('GET htt:p// HTTP/1.1'#13#10'Host: hyper.rs'#13#10#13#10,
      DefaultParseContext, H, Msg) = spsError);
    { http::Uri rejects it: Parse::Uri -> 400 }
    AssertTrue(Msg.Error = h1peUri);
    AssertTrue(Msg.UriError = ueInvalidFormat);
    AssertEquals(400, ServerErrorStatus(Msg.Error));
  finally
    H.Free;
  end;
end;

const
  REQUEST_WITH_MULTIPLE_SPACES_IN_REQUEST_LINE: RawByteString =
    'GET  /echo  HTTP/1.1'#13#10'Host: hyper.rs'#13#10#13#10;

procedure TTestRoleServer.Test_parse_allow_request_with_multiple_spaces_in_request_line;
var
  Ctx: TH1ParseContext;
  H: THttpHeaders;
  Msg: TParsedRequestHead;
  Raw: RawByteString;
begin
  Raw := REQUEST_WITH_MULTIPLE_SPACES_IN_REQUEST_LINE;
  Ctx := DefaultParseContext;
  Ctx.ParserConfig.AllowMultipleSpacesInRequestLineDelimiters := True;
  H := THttpHeaders.Create;
  try
    AssertTrue(ParseStr(Raw, Ctx, H, Msg) = spsComplete);
    AssertEquals(Length(Raw), Msg.HeadLen);
    AssertTrue(Msg.Method = hmGet);
    AssertEquals('/echo', SliceStr(Raw, Msg.Target));
    AssertTrue(Msg.Version = hv11);
    AssertEquals(1, H.Count);
    AssertEquals('hyper.rs', H.GetValue('Host'));
  finally
    H.Free;
  end;
end;

procedure TTestRoleServer.Test_parse_reject_request_with_multiple_spaces_in_request_line;
var
  H: THttpHeaders;
  Msg: TParsedRequestHead;
begin
  H := THttpHeaders.Create;
  try
    AssertTrue(ParseStr(REQUEST_WITH_MULTIPLE_SPACES_IN_REQUEST_LINE,
      DefaultParseContext, H, Msg) = spsError);
    { not asserted by hyper; httparse gives Token after the method -> Uri }
    AssertTrue(Msg.Error = h1peUri);
    AssertEquals(400, ServerErrorStatus(Msg.Error));
  finally
    H.Free;
  end;
end;

procedure TTestRoleServer.Test_parse_preserve_header_case_in_request;
var
  H: THttpHeaders;
  Msg: TParsedRequestHead;
begin
  { hyper builds a HeaderCaseMap; THttpHeaders keeps the original spelling
    of each occurrence and finds it case-insensitively }
  H := THttpHeaders.Create;
  try
    AssertTrue(ParseStr('GET / HTTP/1.1'#13#10'Host: hyper.rs'#13#10'X-BREAD: baguette'#13#10#13#10,
      DefaultParseContext, H, Msg) = spsComplete);
    AssertEquals(1, H.CountOf('host'));
    AssertEquals('Host', H.Name(H.IndexOf('host')));
    AssertEquals(1, H.CountOf('x-bread'));
    AssertEquals('X-BREAD', H.Name(H.IndexOf('x-bread')));
  finally
    H.Free;
  end;
end;

procedure TTestRoleServer.Test_decoder_request;
var
  H: THttpHeaders;

  function Parse(const S: RawByteString): TParsedRequestHead;
  begin
    if ParseStr(S, DefaultParseContext, H, Result) <> spsComplete then
      Fail('parse ok / parse complete: ' + S);
  end;

  function ParseErr(const S, Comment: RawByteString): TH1ParseError;
  var
    Msg: TParsedRequestHead;
  begin
    if ParseStr(S, DefaultParseContext, H, Msg) <> spsError then
      Fail(Comment);
    Result := Msg.Error;
  end;

var
  Msg: TParsedRequestHead;
begin
  H := THttpHeaders.Create;
  try
    { no length or transfer-encoding means 0-length body }
    AssertEquals(DECODED_LENGTH_ZERO, Parse('GET / HTTP/1.1'#13#10#13#10).Decode);
    AssertEquals(DECODED_LENGTH_ZERO, Parse('POST / HTTP/1.1'#13#10#13#10).Decode);

    { transfer-encoding: chunked }
    AssertEquals(DECODED_LENGTH_CHUNKED, Parse('POST / HTTP/1.1'#13#10'transfer-encoding: chunked'#13#10#13#10).Decode);
    AssertEquals(DECODED_LENGTH_CHUNKED, Parse('POST / HTTP/1.1'#13#10'transfer-encoding: gzip, chunked'#13#10#13#10).Decode);
    AssertEquals(DECODED_LENGTH_CHUNKED, Parse('POST / HTTP/1.1'#13#10'transfer-encoding: gzip'#13#10'transfer-encoding: chunked'#13#10#13#10).Decode);

    { content-length }
    AssertEquals(QWord(10), Parse('POST / HTTP/1.1'#13#10'content-length: 10'#13#10#13#10).Decode);

    { transfer-encoding and content-length = chunked }
    Msg := Parse('POST / HTTP/1.1'#13#10'content-length: 10'#13#10'transfer-encoding: chunked'#13#10#13#10);
    AssertEquals(DECODED_LENGTH_CHUNKED, Msg.Decode);
    AssertFalse(H.Contains(HN_CONTENT_LENGTH));
    AssertFalse(Msg.KeepAlive);

    Msg := Parse('POST / HTTP/1.1'#13#10'transfer-encoding: chunked'#13#10'content-length: 10'#13#10#13#10);
    AssertEquals(DECODED_LENGTH_CHUNKED, Msg.Decode);
    AssertFalse(H.Contains(HN_CONTENT_LENGTH));
    AssertFalse(Msg.KeepAlive);

    Msg := Parse('POST / HTTP/1.1'#13#10'transfer-encoding: gzip'#13#10'content-length: 10'#13#10'transfer-encoding: chunked'#13#10#13#10);
    AssertEquals(DECODED_LENGTH_CHUNKED, Msg.Decode);
    AssertFalse(H.Contains(HN_CONTENT_LENGTH));
    AssertFalse(Msg.KeepAlive);

    Msg := Parse('POST / HTTP/1.1'#13#10'connection: keep-alive'#13#10'content-length: 10'#13#10'transfer-encoding: chunked'#13#10#13#10);
    AssertEquals(DECODED_LENGTH_CHUNKED, Msg.Decode);
    AssertFalse(H.Contains(HN_CONTENT_LENGTH));
    AssertFalse(Msg.KeepAlive);

    { multiple content-lengths of same value are fine }
    AssertEquals(QWord(10), Parse('POST / HTTP/1.1'#13#10'content-length: 10'#13#10'content-length: 10'#13#10#13#10).Decode);

    { multiple content-lengths with different values is an error }
    AssertTrue(ParseErr('POST / HTTP/1.1'#13#10'content-length: 10'#13#10'content-length: 11'#13#10#13#10,
      'multiple content-lengths') = h1peHeaderContentLengthInvalid);

    { content-length with prefix is not allowed }
    AssertTrue(ParseErr('POST / HTTP/1.1'#13#10'content-length: +10'#13#10#13#10,
      'prefixed content-length') = h1peHeaderContentLengthInvalid);

    { transfer-encoding that isn't chunked is an error }
    AssertTrue(ParseErr('POST / HTTP/1.1'#13#10'transfer-encoding: gzip'#13#10#13#10,
      'transfer-encoding but not chunked') = h1peHeaderTransferEncodingInvalid);
    AssertTrue(ParseErr('POST / HTTP/1.1'#13#10'transfer-encoding: chunked, gzip'#13#10#13#10,
      'transfer-encoding doesn''t end in chunked') = h1peHeaderTransferEncodingInvalid);
    AssertTrue(ParseErr('POST / HTTP/1.1'#13#10'transfer-encoding: chunked'#13#10'transfer-encoding: afterlol'#13#10#13#10,
      'transfer-encoding multiple lines doesn''t end in chunked') = h1peHeaderTransferEncodingInvalid);

    { http/1.0 }
    AssertEquals(QWord(10), Parse('POST / HTTP/1.0'#13#10'content-length: 10'#13#10#13#10).Decode);

    { 1.0 doesn't understand chunked, so its an error }
    AssertTrue(ParseErr('POST / HTTP/1.0'#13#10'transfer-encoding: chunked'#13#10#13#10,
      '1.0 chunked') = h1peHeaderTransferEncodingUnexpected);
  finally
    H.Free;
  end;
end;

procedure TTestRoleServer.Test_parse_request_multiple_connection_headers;
var
  H: THttpHeaders;

  function Parse(const S: RawByteString): TParsedRequestHead;
  begin
    if ParseStr(S, DefaultParseContext, H, Result) <> spsComplete then
      Fail('parse: ' + S);
  end;

begin
  H := THttpHeaders.Create;
  try
    AssertFalse('close before keep-alive is still close',
      Parse('GET / HTTP/1.1'#13#10'connection: close'#13#10'connection: keep-alive'#13#10#13#10).KeepAlive);
    AssertFalse('keep-alive before close is still close',
      Parse('GET / HTTP/1.1'#13#10'connection: keep-alive'#13#10'connection: close'#13#10#13#10).KeepAlive);
    AssertTrue('HTTP/1.0 keep-alive is not undone by an unrelated token',
      Parse('GET / HTTP/1.0'#13#10'connection: keep-alive'#13#10'connection: foo'#13#10#13#10).KeepAlive);
    AssertFalse('HTTP/1.0 close wins over an earlier keep-alive',
      Parse('GET / HTTP/1.0'#13#10'connection: keep-alive'#13#10'connection: close'#13#10#13#10).KeepAlive);
  finally
    H.Free;
  end;
end;

procedure TTestRoleServer.Test_server_encode_connect_method;
var
  Head: TResponseHead;
  P: TServerEncodeParams;
  Enc: TEncoder;
  Res: TServerEncodeResult;
  S: RawByteString;
begin
  Head := DefaultResponseHead;
  P := DefaultEncodeParams;
  P.Body := blkNone;
  P.KeepAlive := True;
  P.ReqMethod := hmConnect;
  P.DateHeader := True;
  S := EncodeStr(Head, P, Enc, Res);
  AssertTrue(Res = serOk);
  AssertTrue(Enc.IsLast);
  { not asserted by hyper: no content-length / transfer-encoding }
  AssertEquals(0, Pos('content-length', S));
  AssertEquals(0, Pos('transfer-encoding', S));
end;

procedure TTestRoleServer.Test_server_response_encode_title_case;
var
  Head: TResponseHead;
  P: TServerEncodeParams;
  Enc: TEncoder;
  Res: TServerEncodeResult;
  S: RawByteString;
const
  Expected = 'HTTP/1.1 200 OK'#13#10'Content-Length: 10'#13#10'Content-Type: application/json'#13#10'Weird--Header: '#13#10;
begin
  Head := DefaultResponseHead;
  Head.Headers := THttpHeaders.Create;
  try
    Head.Headers.Insert('content-length', '10');
    Head.Headers.Insert('content-type', 'application/json');
    Head.Headers.Insert('weird--header', '');
    P := DefaultEncodeParams;
    P.Body := blkKnown;
    P.BodyLen := 10;
    P.KeepAlive := True;
    P.ReqMethod := hmNone;
    P.TitleCaseHeaders := True;
    P.DateHeader := True;
    S := EncodeStr(Head, P, Enc, Res);
    AssertTrue(Res = serOk);
    AssertEquals(Expected, Copy(S, 1, Length(Expected)));
  finally
    Head.Headers.Free;
  end;
end;

procedure TTestRoleServer.Test_server_response_encode_orig_case;
var
  Head: TResponseHead;
  P: TServerEncodeParams;
  Enc: TEncoder;
  Res: TServerEncodeResult;
  S: RawByteString;
const
  Expected = 'HTTP/1.1 200 OK'#13#10'CONTENT-LENGTH: 10'#13#10'content-type: application/json'#13#10'date: ';
begin
  Head := DefaultResponseHead;
  Head.Headers := THttpHeaders.Create;
  Head.CaseMap := THttpHeaders.Create;
  try
    Head.Headers.Insert('content-length', '10');
    Head.Headers.Insert('content-type', 'application/json');
    Head.CaseMap.Insert('CONTENT-LENGTH', '');
    P := DefaultEncodeParams;
    P.Body := blkKnown;
    P.BodyLen := 10;
    P.KeepAlive := True;
    P.TitleCaseHeaders := False;
    P.DateHeader := True;
    S := EncodeStr(Head, P, Enc, Res);
    AssertTrue(Res = serOk);
    AssertEquals(Expected, Copy(S, 1, Length(Expected)));
  finally
    Head.Headers.Free;
    Head.CaseMap.Free;
  end;
end;

procedure TTestRoleServer.Test_server_response_encode_orig_and_title_case;
var
  Head: TResponseHead;
  P: TServerEncodeParams;
  Enc: TEncoder;
  Res: TServerEncodeResult;
  S: RawByteString;
const
  Expected = 'HTTP/1.1 200 OK'#13#10'CONTENT-LENGTH: 10'#13#10'Content-Type: application/json'#13#10'Date: ';
begin
  Head := DefaultResponseHead;
  Head.Headers := THttpHeaders.Create;
  Head.CaseMap := THttpHeaders.Create;
  try
    Head.Headers.Insert('content-length', '10');
    Head.Headers.Insert('content-type', 'application/json');
    Head.CaseMap.Insert('CONTENT-LENGTH', '');
    P := DefaultEncodeParams;
    P.Body := blkKnown;
    P.BodyLen := 10;
    P.KeepAlive := True;
    P.TitleCaseHeaders := True;
    P.DateHeader := True;
    S := EncodeStr(Head, P, Enc, Res);
    AssertTrue(Res = serOk);
    { this will also test that the date does exist }
    AssertEquals(Expected, Copy(S, 1, Length(Expected)));
  finally
    Head.Headers.Free;
    Head.CaseMap.Free;
  end;
end;

procedure TTestRoleServer.Test_disabled_date_header;
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
    Head.Headers.Insert('content-length', '10');
    Head.Headers.Insert('content-type', 'application/json');
    Head.CaseMap.Insert('CONTENT-LENGTH', '');
    P := DefaultEncodeParams;
    P.Body := blkKnown;
    P.BodyLen := 10;
    P.KeepAlive := True;
    P.TitleCaseHeaders := True;
    P.DateHeader := False;
    AssertEquals('HTTP/1.1 200 OK'#13#10'CONTENT-LENGTH: 10'#13#10'Content-Type: application/json'#13#10#13#10,
      EncodeStr(Head, P, Enc, Res));
    AssertTrue(Res = serOk);
  finally
    Head.Headers.Free;
    Head.CaseMap.Free;
  end;
end;

procedure TTestRoleServer.Test_parse_too_large_headers;
var
  H: THttpHeaders;

  function GenReqWithHeaders(Num: Integer): RawByteString;
  var
    I: Integer;
  begin
    Result := 'GET / HTTP/1.1'#13#10;
    for I := 0 to Num - 1 do
      Result := Result + 'key' + IntToStr(I) + ': val' + IntToStr(I) + #13#10;
    Result := Result + #13#10;
  end;

  procedure Parse(MaxHeaders: Integer; GenSize: Integer; ShouldSucceed: Boolean);
  var
    Ctx: TH1ParseContext;
    Msg: TParsedRequestHead;
    St: TServerParseStatus;
  begin
    { server side (the client half of this hyper test is not ported) }
    Ctx := DefaultParseContext;
    Ctx.MaxHeaders := MaxHeaders;
    St := ParseStr(GenReqWithHeaders(GenSize), Ctx, H, Msg);
    if ShouldSucceed then
      AssertTrue(Format('max=%d n=%d: parse complete', [MaxHeaders, GenSize]), St = spsComplete)
    else
    begin
      AssertTrue(Format('max=%d n=%d: parse should err', [MaxHeaders, GenSize]), St = spsError);
      AssertTrue(Msg.Error = h1peTooLarge);
    end;
  end;

begin
  H := THttpHeaders.Create;
  try
    { check generator }
    AssertEquals('GET / HTTP/1.1'#13#10#13#10, GenReqWithHeaders(0));
    AssertEquals('GET / HTTP/1.1'#13#10'key0: val0'#13#10#13#10, GenReqWithHeaders(1));
    AssertEquals('GET / HTTP/1.1'#13#10'key0: val0'#13#10'key1: val1'#13#10#13#10, GenReqWithHeaders(2));
    AssertEquals('GET / HTTP/1.1'#13#10'key0: val0'#13#10'key1: val1'#13#10'key2: val2'#13#10#13#10, GenReqWithHeaders(3));

    { default max_headers is 100 }
    Parse(-1, 0, True);
    Parse(-1, 1, True);
    Parse(-1, 50, True);
    Parse(-1, 99, True);
    Parse(-1, 100, True);
    Parse(-1, 101, False);
    Parse(-1, 102, False);
    Parse(-1, 200, False);

    { max_headers is 0 }
    Parse(0, 0, True);
    Parse(0, 1, False);
    Parse(0, 100, False);

    { max_headers is 200 }
    Parse(200, 0, True);
    Parse(200, 1, True);
    Parse(200, 100, True);
    Parse(200, 200, True);
    Parse(200, 201, False);
    Parse(200, 210, False);
  finally
    H.Free;
  end;
end;

procedure TTestRoleServer.Test_h1_server_max_header_size;
const
  ReqStr: RawByteString = 'GET / HTTP/1.1'#13#10'Host: example.com'#13#10#13#10;
var
  H: THttpHeaders;

  function ParseReq(MaxHeaderSize: SizeInt; out Msg: TParsedRequestHead): TServerParseStatus;
  var
    Ctx: TH1ParseContext;
  begin
    Ctx := DefaultParseContext;
    Ctx.MaxHeaderSize := MaxHeaderSize;
    Result := ParseStr(ReqStr, Ctx, H, Msg);
  end;

var
  Msg: TParsedRequestHead;
begin
  AssertEquals(37, Length(ReqStr));
  H := THttpHeaders.Create;
  try
    AssertTrue(ParseReq(-1, Msg) = spsComplete);
    AssertTrue(ParseReq(37, Msg) = spsComplete);
    AssertTrue(ParseReq(50, Msg) = spsComplete);
    AssertTrue(ParseReq(36, Msg) = spsError);
    AssertTrue(Msg.Error = h1peTooLarge);
    AssertTrue(ParseReq(10, Msg) = spsError);
    AssertTrue(Msg.Error = h1peTooLarge);
  finally
    H.Free;
  end;
end;

procedure TTestRoleServer.Test_is_complete_fast;

  procedure Check(const S: RawByteString; Expect: Boolean);
  var
    N: Integer;
    Buf: TBytes;
  begin
    { an exact-size copy so -Cr / a heap checker catches reads past the end }
    SetLength(Buf, Length(S));
    Move(Pointer(S)^, Buf[0], Length(S));
    for N := 0 to Length(S) - 1 do
      AssertEquals(Format('%s; %d', [StringReplace(StringReplace(S, #13, '\r', [rfReplaceAll]), #10, '\n', [rfReplaceAll]), N]),
        Expect, IsCompleteFast(@Buf[0], Length(Buf), N));
  end;

begin
  Check('GET / HTTP/1.1'#13#10'a: b'#13#10#13#10, True);
  Check('GET / HTTP/1.1'#10'a: b'#10#10, True);
  Check('GET / HTTP/1.1'#13#10'a: b'#10#13#10, True);
  { Not }
  Check('GET / HTTP/1.1'#13#10'a: b'#13#10#13, False);
  Check('GET / HTTP/1.1'#10'a: b'#10, False);
  Check('GET / HTTP/1.1'#13#10'a: b'#10#13, False);
end;

procedure TTestRoleServer.Test_parse_accepts_lf_crlf_terminator;
var
  H: THttpHeaders;
  Msg: TParsedRequestHead;
begin
  H := THttpHeaders.Create;
  try
    AssertTrue(ParseStr('GET / HTTP/1.1'#13#10'a: b'#10#13#10, DefaultParseContext, H, Msg) = spsComplete);
  finally
    H.Free;
  end;
end;

{ ---- client tests, server variants ---- }

procedure TTestRoleServer.Test_parse_reject_response_with_spaces_before_colons_request_variant;
var
  H: THttpHeaders;
  Msg: TParsedRequestHead;
begin
  H := THttpHeaders.Create;
  try
    AssertTrue(ParseStr('GET / HTTP/1.1'#13#10'Host : x'#13#10#13#10, DefaultParseContext, H, Msg) = spsError);
    AssertTrue(Msg.Error = h1peHeaderToken);
    AssertEquals(400, ServerErrorStatus(Msg.Error));
    { the same bytes as the hyper test's header line, in a request }
    AssertTrue(ParseStr('GET / HTTP/1.1'#13#10'Access-Control-Allow-Credentials : true'#13#10#13#10,
      DefaultParseContext, H, Msg) = spsError);
    AssertTrue(Msg.Error = h1peHeaderToken);
  finally
    H.Free;
  end;
end;

procedure TTestRoleServer.Test_parse_header_htabs_request_variant;
var
  H: THttpHeaders;
  Msg: TParsedRequestHead;
begin
  H := THttpHeaders.Create;
  try
    AssertTrue(ParseStr('GET / HTTP/1.1'#13#10'server: hello'#9'world'#13#10#13#10, DefaultParseContext, H, Msg) = spsComplete);
    AssertEquals('hello'#9'world', H.GetValue('server'));
    AssertTrue(ParseStr('GET / HTTP/1.1'#13#10'x: a'#9'b'#13#10#13#10, DefaultParseContext, H, Msg) = spsComplete);
    AssertEquals('a'#9'b', H.GetValue('x'));
  finally
    H.Free;
  end;
end;

procedure TTestRoleServer.Test_client_obs_fold_line_request_variant;
var
  H: THttpHeaders;
  Msg: TParsedRequestHead;
begin
  { hyper unfolds obs-fold only in responses; in requests httparse rejects
    it, so the server answers 400 }
  H := THttpHeaders.Create;
  try
    AssertTrue(ParseStr('GET / HTTP/1.1'#13#10'x: obs'#13#10' fold'#13#10#9' line'#13#10#13#10,
      DefaultParseContext, H, Msg) = spsError);
    AssertTrue(Msg.Error = h1peHeaderToken);
    AssertEquals(400, ServerErrorStatus(Msg.Error));
    { a normal line is fine }
    AssertTrue(ParseStr('GET / HTTP/1.1'#13#10'x: a normal line'#13#10#13#10, DefaultParseContext, H, Msg) = spsComplete);
    AssertEquals('a normal line', H.GetValue('x'));
  finally
    H.Free;
  end;
end;

procedure TTestRoleServer.Test_client_request_encode_title_case_server_variant;
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
    Head.Headers.Insert('*-*', 'o_o');
    P := DefaultEncodeParams;
    P.Body := blkKnown;
    P.BodyLen := 10;
    P.TitleCaseHeaders := True;
    P.DateHeader := False;
    AssertEquals('HTTP/1.1 200 OK'#13#10'Content-Length: 10'#13#10'Content-Type: application/json'#13#10'*-*: o_o'#13#10#13#10,
      EncodeStr(Head, P, Enc, Res));
  finally
    Head.Headers.Free;
  end;
end;

procedure TTestRoleServer.Test_write_headers_orig_case_empty_value_server_variant;
var
  Head: TResponseHead;
  P: TServerEncodeParams;
  Enc: TEncoder;
  Res: TServerEncodeResult;
begin
  { the client path writes 'X-EmptY:\r\n'; the server path writes a space }
  Head := DefaultResponseHead;
  Head.Headers := THttpHeaders.Create;
  Head.CaseMap := THttpHeaders.Create;
  try
    Head.Headers.Insert('x-empty', '');
    Head.CaseMap.Insert('X-EmptY', '');
    P := DefaultEncodeParams;
    P.DateHeader := False;
    AssertEquals('HTTP/1.1 200 OK'#13#10'X-EmptY: '#13#10'content-length: 0'#13#10#13#10,
      EncodeStr(Head, P, Enc, Res));
  finally
    Head.Headers.Free;
    Head.CaseMap.Free;
  end;
end;

procedure TTestRoleServer.Test_write_headers_orig_case_multiple_entries_server_variant;
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
    Head.Headers.Insert('x-empty', 'a');
    Head.Headers.Append('x-empty', 'b');
    Head.CaseMap.Insert('X-Empty', '');
    Head.CaseMap.Append('X-EMPTY', '');
    P := DefaultEncodeParams;
    P.DateHeader := False;
    AssertEquals('HTTP/1.1 200 OK'#13#10'X-Empty: a'#13#10'X-EMPTY: b'#13#10'content-length: 0'#13#10#13#10,
      EncodeStr(Head, P, Enc, Res));
  finally
    Head.Headers.Free;
    Head.CaseMap.Free;
  end;
end;

{ ---- tests/server.rs ---- }

procedure TTestRoleServer.Test_http1_response_with_http2_version;
var
  Head: TResponseHead;
  P: TServerEncodeParams;
  Enc: TEncoder;
  Res: TServerEncodeResult;
  S: RawByteString;
begin
  { the service sets version HTTP/2.0; role.rs:440-443 writes HTTP/1.1 }
  Head := DefaultResponseHead;
  Head.Version := hv2;
  P := DefaultEncodeParams;
  P.ReqMethod := hmGet;
  P.Date := PByte(Pointer(FIXED_DATE));
  S := EncodeStr(Head, P, Enc, Res);
  AssertTrue(Res = serOk);
  AssertTrue(StartsWith(S, 'HTTP/1.1 200 OK'#13#10));
  AssertEquals('HTTP/1.1 200 OK'#13#10'content-length: 0'#13#10'date: ' + FIXED_DATE + #13#10#13#10, S);
end;

procedure TTestRoleServer.Test_http1_trailer_recv_fields;
var
  Req: RawByteString;
  H, Trailers: THttpHeaders;
  Msg: TParsedRequestHead;
  D: TDecoder;
  R: TDecodeResult;
  Body: RawByteString;
  Pos0: SizeInt;
  St: TDecodeStatus;
  GotTrailers: Boolean;
begin
  Req := 'POST / HTTP/1.1'#13#10'trailer: chunky-trailer'#13#10'host: example.domain'#13#10 +
    'transfer-encoding: chunked'#13#10#13#10'5'#13#10'hello'#13#10'0'#13#10'chunky-trailer: header data'#13#10#13#10;
  H := THttpHeaders.Create;
  Trailers := THttpHeaders.Create;
  try
    AssertTrue(ParseStr(Req, DefaultParseContext, H, Msg) = spsComplete);
    AssertEquals(DECODED_LENGTH_CHUNKED, Msg.Decode);
    InitDecoderFor(D, Msg.Decode);
    Pos0 := Msg.HeadLen;
    Body := '';
    GotTrailers := False;
    repeat
      St := D.Decode(PByte(Pointer(Req)) + Pos0, Length(Req) - Pos0, True, Trailers, R);
      if R.DataLen > 0 then
        Body := Body + Copy(Req, Pos0 + R.DataOfs + 1, R.DataLen);
      Inc(Pos0, R.Consumed);
      if St = dsTrailers then
        GotTrailers := True;
    until St in [dsEnd, dsError];
    AssertTrue(St = dsEnd);
    AssertEquals('hello', Body);
    AssertTrue(GotTrailers);
    AssertEquals('header data', Trailers.GetValue('chunky-trailer'));
    AssertEquals(Length(Req), Pos0);
  finally
    H.Free;
    Trailers.Free;
  end;
end;

{ ---- conn.rs ---- }

procedure TTestRoleServer.Test_conn_writes_chunked_body;
var
  Enc: TEncoder;
  Buf: TEncodedBuf;
  Wire: TBytes;
  WireLen: SizeInt;
  Data: RawByteString;
  NotEof: QWord;
  S: RawByteString;
begin
  { Conn with writing = Body(Encoder::chunked()): write_body("headers"),
    end_body(), flush. There is no Conn yet; this checks the encoder plus
    an append-only write buffer produce the bytes the mock IO expects. }
  Enc := TEncoder.Chunked;
  Wire := nil;
  WireLen := 0;
  Data := 'headers';
  Enc.Encode(PByte(Pointer(Data)), Length(Data), Buf);
  Buf.AppendTo(Wire, WireLen);
  AssertTrue(Enc.Finish(Buf, NotEof) = eeBuf);
  Buf.AppendTo(Wire, WireLen);
  SetLength(S, WireLen);
  Move(Wire[0], Pointer(S)^, WireLen);
  AssertEquals('7'#13#10'headers'#13#10'0'#13#10#13#10, S);
end;

initialization
  RegisterTest(TTestRoleServer);
end.

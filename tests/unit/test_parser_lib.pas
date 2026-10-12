{ Hand ports of the request-side #[test] functions in httparse v1.10.1
  src/lib.rs (mod tests).  Response-only tests are out of scope (M2).
  Tests that check a response and a request in one function are ported
  for the request half only; the comment on each says so. }
unit test_parser_lib;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, fpcunit, testregistry, bearings.http1.parser, test_parser_base;

type
  TTestHttparseLib = class(TParserTestCase)
  private
    function Cfg: TParserConfig;
  published
    procedure Test_request_partial_parses_headers_as_much_as_it_can;
    procedure Test_partial_permutations;
    procedure Test_forbid_request_with_whitespace_between_header_name_and_colon;
    procedure Test_ignore_header_line_with_whitespaces_after_header_name_in_request;
    procedure Test_forbid_request_with_multiple_space_delimiters;
    procedure Test_allow_request_with_multiple_space_delimiters;
    procedure Test_forbid_request_with_weird_whitespace_delimiters;
    procedure Test_still_forbid_request_with_weird_whitespace_delimiters;
    procedure Test_request_with_multiple_spaces_and_bad_path;
    procedure Test_request_with_del_in_path;
    procedure Test_all_utf8_char_in_paths;
    procedure Test_request_with_empty_header_name;
    procedure Test_request_with_whitespace_between_header_name_and_colon;
    procedure Test_request_with_invalid_char_between_header_name_and_colon;
    procedure Test_ignore_header_line_with_missing_colon_in_request;
    procedure Test_request_header_with_missing_colon_with_folding;
    procedure Test_request_header_with_nul_in_header_name;
    procedure Test_header_with_cr_in_header_name;
    procedure Test_header_with_nul_in_whitespace_before_colon;
    procedure Test_header_with_nul_in_value;
    procedure Test_header_with_invalid_char_in_value;
    procedure Test_header_with_invalid_char_in_value_with_folding;
    procedure Test_method_within_buffer;
    procedure Test_request_with_leading_space;
    procedure Test_request_with_invalid_method;
    procedure Test_utf8_in_path_ok;
    procedure Test_bad_utf8_in_path;
    { Response tests whose header-block rule also applies to requests,
      re-run with the status line replaced by a request line. }
    procedure Test_forbid_response_with_space_before_first_header_as_request;
    procedure Test_allow_response_response_with_space_before_first_header_as_request;
    procedure Test_no_space_after_colon_as_request;
    { Doc test of httparse::parse_headers (lib.rs:952-959). }
    procedure Test_doc_parse_headers;
    { Not httparse tests: extra checks of the TooManyHeaders limit, which no
      httparse request test exercises past the exact limit. }
    procedure Extra_request_headers_too_many;
    procedure Extra_request_headers_partial_line_before_limit;
    procedure Extra_request_headers_zero_slots;
  end;

implementation

function TTestHttparseLib.Cfg: TParserConfig;
begin
  Result := DefaultParserConfig;
end;

{ lib.rs req! test_request_partial_parses_headers_as_much_as_it_can.
  httparse asserts headers.len() == NUM_OF_HEADERS on Partial because it
  leaves the caller's slice unshrunk; this API reports NumHeaders = number
  of header lines parsed so far (1), and slot 0 holds Host: yolo, which is
  what the Rust test then checks. }
procedure TTestHttparseLib.Test_request_partial_parses_headers_as_much_as_it_can;
begin
  ParseReq('GET / HTTP/1.1'#13#10'Host: yolo'#13#10);
  CheckPartial;
  CheckMethod('GET');
  CheckPath('/');
  CheckVersion(1);
  CheckHeaderCount(1);
  CheckHeader(0, 'Host', 'yolo');
end;

procedure TTestHttparseLib.Test_partial_permutations;
const
  REQ_STR = 'GET / HTTP/1.1'#13#10#13#10;
var
  I: Integer;
begin
  for I := 0 to Length(REQ_STR) - 1 do
  begin
    ParseReq(Copy(REQ_STR, 1, I));
    AssertEquals(Format('partial request line should return partial. ' +
      'Portion which failed: ''%s'' (below %d)', [Printable(FBuf), I]),
      'Ok(Partial)', ResultStr(FRes));
  end;
end;

const
  REQUEST_WITH_WHITESPACE_BETWEEN_HEADER_NAME_AND_COLON =
    'GET / HTTP/1.1'#13#10'Host : localhost'#13#10#13#10;

procedure TTestHttparseLib.Test_forbid_request_with_whitespace_between_header_name_and_colon;
begin
  ParseReq(REQUEST_WITH_WHITESPACE_BETWEEN_HEADER_NAME_AND_COLON, 1);
  CheckError(peHeaderName);
end;

procedure TTestHttparseLib.Test_ignore_header_line_with_whitespaces_after_header_name_in_request;
var
  C: TParserConfig;
begin
  C := Cfg;
  C.IgnoreInvalidHeadersInRequests := True;
  ParseReq(REQUEST_WITH_WHITESPACE_BETWEEN_HEADER_NAME_AND_COLON, 2, C);
  CheckComplete(36);
end;

const
  REQUEST_WITH_MULTIPLE_SPACE_DELIMITERS = 'GET  /    HTTP/1.1'#13#10#13#10;

procedure TTestHttparseLib.Test_forbid_request_with_multiple_space_delimiters;
begin
  ParseReq(REQUEST_WITH_MULTIPLE_SPACE_DELIMITERS);
  CheckError(peToken);
end;

procedure TTestHttparseLib.Test_allow_request_with_multiple_space_delimiters;
var
  C: TParserConfig;
begin
  C := Cfg;
  C.AllowMultipleSpacesInRequestLineDelimiters := True;
  ParseReq(REQUEST_WITH_MULTIPLE_SPACE_DELIMITERS, NUM_OF_HEADERS, C);
  CheckComplete(Length(REQUEST_WITH_MULTIPLE_SPACE_DELIMITERS));
  CheckMethod('GET');
  CheckPath('/');
  CheckVersion(1);
  CheckHeaderCount(0);
end;

const
  REQUEST_WITH_WEIRD_WHITESPACE_DELIMITERS = 'GET'#13'/'#13'HTTP/1.1'#13#10#13#10;

procedure TTestHttparseLib.Test_forbid_request_with_weird_whitespace_delimiters;
begin
  ParseReq(REQUEST_WITH_WEIRD_WHITESPACE_DELIMITERS);
  CheckError(peToken);
end;

procedure TTestHttparseLib.Test_still_forbid_request_with_weird_whitespace_delimiters;
var
  C: TParserConfig;
begin
  C := Cfg;
  C.AllowMultipleSpacesInRequestLineDelimiters := True;
  ParseReq(REQUEST_WITH_WEIRD_WHITESPACE_DELIMITERS, NUM_OF_HEADERS, C);
  CheckError(peToken);
end;

procedure TTestHttparseLib.Test_request_with_multiple_spaces_and_bad_path;
var
  C: TParserConfig;
begin
  C := Cfg;
  C.AllowMultipleSpacesInRequestLineDelimiters := True;
  ParseReq('GET   /foo ohno HTTP/1.1'#13#10#13#10, NUM_OF_HEADERS, C);
  CheckError(peVersion);
end;

procedure TTestHttparseLib.Test_request_with_del_in_path;
var
  C: TParserConfig;
begin
  C := Cfg;
  C.AllowMultipleSpacesInRequestLineDelimiters := True;
  ParseReq('GET   /foo'#$7F'ohno HTTP/1.1'#13#10#13#10, NUM_OF_HEADERS, C);
  CheckError(peToken);
end;

{ Reference UTF-8 check used as the oracle for test_all_utf8_char_in_paths
  (the Rust test uses core::str::from_utf8).  Written independently of
  bearings.http1.parser.IsValidUtf8: it decodes the code point and then rejects
  overlong forms, surrogates and values above U+10FFFF. }
function RefUtf8Valid(const B: array of Byte; N: Integer): Boolean;
var
  I, K, Need: Integer;
  Cp, MinCp: LongWord;
begin
  Result := False;
  I := 0;
  while I < N do
  begin
    if B[I] < $80 then
    begin
      Inc(I);
      Continue;
    end;
    if (B[I] and $E0) = $C0 then
    begin
      Need := 1; Cp := B[I] and $1F; MinCp := $80;
    end
    else if (B[I] and $F0) = $E0 then
    begin
      Need := 2; Cp := B[I] and $0F; MinCp := $800;
    end
    else if (B[I] and $F8) = $F0 then
    begin
      Need := 3; Cp := B[I] and $07; MinCp := $10000;
    end
    else
      Exit;
    if I + Need > N - 1 then
      Exit;
    for K := 1 to Need do
    begin
      if (B[I + K] and $C0) <> $80 then
        Exit;
      Cp := (Cp shl 6) or (B[I + K] and $3F);
    end;
    if (Cp < MinCp) or (Cp > $10FFFF) or ((Cp >= $D800) and (Cp <= $DFFF)) then
      Exit;
    Inc(I, Need + 1);
  end;
  Result := True;
end;

procedure TTestHttparseLib.Test_all_utf8_char_in_paths;
const
  PREFIX = 'GET /';
  SUFFIX = ' HTTP/1.1'#13#10#13#10;
var
  C: TParserConfig;
  Buf: array[0..63] of Byte;
  Seq: array[0..3] of Byte;
  I, J, K, L, NBytes: Integer;
  Valid2, Valid3, Valid4: Integer;
  Hdrs: array[0..NUM_OF_HEADERS - 1] of THeaderSlice;
  Req: TParsedRequest;
  R: TParseResult;

  procedure Run;
  var
    Len: Integer;
    Ok: Boolean;
    Msg: string;
  begin
    Move(PREFIX[1], Buf[0], Length(PREFIX));
    Move(Seq[0], Buf[Length(PREFIX)], NBytes);
    Move(SUFFIX[1], Buf[Length(PREFIX) + NBytes], Length(SUFFIX));
    Len := Length(PREFIX) + NBytes + Length(SUFFIX);
    R := ParseRequest(@Buf[0], Len, Req, @Hdrs[0], NUM_OF_HEADERS, C);
    Ok := RefUtf8Valid(Seq, NBytes);
    if Ok then
    begin
      case NBytes of
        2: Inc(Valid2);
        3: Inc(Valid3);
        4: Inc(Valid4);
      end;
      if (R.Status <> psComplete) or (R.Consumed <> 18 + NBytes) then
      begin
        Msg := Format('failed for utf8 char i: %d, j: %d', [I, J]);
        if NBytes >= 3 then Msg := Msg + Format(', k: %d', [K]);
        if NBytes >= 4 then Msg := Msg + Format(', l: %d', [L]);
        Fail(Msg + ': expected Ok(Complete(' + IntToStr(18 + NBytes) +
          ')), got ' + ResultStr(R));
      end;
    end
    else if (R.Status <> psError) or (R.Error <> peToken) then
    begin
      Msg := Format('failed for utf8 char i: %d, j: %d', [I, J]);
      if NBytes >= 3 then Msg := Msg + Format(', k: %d', [K]);
      if NBytes >= 4 then Msg := Msg + Format(', l: %d', [L]);
      Fail(Msg + ': expected Err(Token), got ' + ResultStr(R));
    end;
  end;

begin
  C := Cfg;
  C.AllowMultipleSpacesInRequestLineDelimiters := True;
  Valid2 := 0; Valid3 := 0; Valid4 := 0;
  K := 0; L := 0;
  for I := 128 to 255 do
    for J := 128 to 255 do
    begin
      Seq[0] := I; Seq[1] := J; NBytes := 2;
      Run;
      if I < $E0 then
        Continue;
      for K := 128 to 255 do
      begin
        Seq[2] := K; NBytes := 3;
        Run;
        if I < $F0 then
          Continue;
        for L := 128 to 255 do
        begin
          Seq[3] := L; NBytes := 4;
          Run;
        end;
      end;
    end;
  { Cross-check of the oracle: counts of valid sequences in each loop, as
    computed with Python's strict UTF-8 decoder (same rules as Rust). }
  AssertEquals('valid 2-byte sequences', 1920, Valid2);
  AssertEquals('valid 3-byte sequences', 61440, Valid3);
  AssertEquals('valid 4-byte sequences', 1048576, Valid4);
end;

procedure TTestHttparseLib.Test_request_with_empty_header_name;
const
  REQ = 'GET / HTTP/1.1'#13#10': hello'#13#10'Bread: baguette'#13#10#13#10;
var
  C: TParserConfig;
begin
  ParseReq(REQ, 2, Cfg);
  CheckError(peHeaderName);
  C := Cfg;
  C.IgnoreInvalidHeadersInRequests := True;
  ParseReq(REQ, 2, C);
  CheckComplete(44);
end;

procedure TTestHttparseLib.Test_request_with_whitespace_between_header_name_and_colon;
const
  REQ = 'GET / HTTP/1.1'#13#10'Access-Control-Allow-Credentials  : true'#13#10 +
    'Bread: baguette'#13#10#13#10;
var
  C: TParserConfig;
begin
  { The response-only options must not relax request parsing. }
  C := Cfg;
  C.AllowSpacesAfterHeaderNameInResponses := True;
  ParseReq(REQ, 2, C);
  CheckError(peHeaderName);
  C := Cfg;
  C.IgnoreInvalidHeadersInResponses := True;
  ParseReq(REQ, 2, C);
  CheckError(peHeaderName);
end;

procedure TTestHttparseLib.Test_request_with_invalid_char_between_header_name_and_colon;
const
  REQ = 'GET / HTTP/1.1'#13#10'Access-Control-Allow-Credentials'#$FF'  : true'#13#10 +
    'Bread: baguette'#13#10#13#10;
var
  C: TParserConfig;
begin
  ParseReq(REQ, 2, Cfg);
  CheckError(peHeaderName);
  C := Cfg;
  C.IgnoreInvalidHeadersInRequests := True;
  ParseReq(REQ, 2, C);
  CheckComplete(78);
end;

procedure TTestHttparseLib.Test_ignore_header_line_with_missing_colon_in_request;
const
  REQ = 'GET / HTTP/1.1'#13#10'Access-Control-Allow-Credentials'#13#10 +
    'Bread: baguette'#13#10#13#10;
var
  C: TParserConfig;
begin
  ParseReq(REQ, 2, Cfg);
  CheckError(peHeaderName);
  C := Cfg;
  C.IgnoreInvalidHeadersInRequests := True;
  ParseReq(REQ, 2, C);
  CheckComplete(69);
end;

procedure TTestHttparseLib.Test_request_header_with_missing_colon_with_folding;
const
  REQ = 'GET / HTTP/1.1'#13#10'Access-Control-Allow-Credentials   '#13#10' hello'#13#10 +
    'Bread: baguette'#13#10#13#10;
var
  C: TParserConfig;
begin
  ParseReq(REQ, 2, Cfg);
  CheckError(peHeaderName);
  C := Cfg;
  C.IgnoreInvalidHeadersInRequests := True;
  ParseReq(REQ, 2, C);
  CheckComplete(80);
end;

procedure TTestHttparseLib.Test_request_header_with_nul_in_header_name;
const
  REQ = 'GET / HTTP/1.1'#13#10'Access-Control-Allow-Cred'#0'entials: hello'#13#10 +
    'Bread: baguette'#13#10#13#10;
var
  C: TParserConfig;
begin
  ParseReq(REQ, 2, Cfg);
  CheckError(peHeaderName);
  C := Cfg;
  C.IgnoreInvalidHeadersInRequests := True;
  ParseReq(REQ, 2, C);
  CheckError(peHeaderName);
end;

{ Request half only (the response half needs the response parser). }
procedure TTestHttparseLib.Test_header_with_cr_in_header_name;
const
  REQ = 'GET / HTTP/1.1'#13#10'Access-Control-Allow-Cred'#13'entials: hello'#13#10 +
    'Bread: baguette'#13#10#13#10;
var
  C: TParserConfig;
begin
  ParseReq(REQ, 2, Cfg);
  CheckError(peHeaderName);
  C := Cfg;
  C.IgnoreInvalidHeadersInRequests := True;
  ParseReq(REQ, 2, C);
  CheckError(peHeaderName);
end;

{ Request half only. }
procedure TTestHttparseLib.Test_header_with_nul_in_whitespace_before_colon;
const
  REQ = 'GET / HTTP/1.1'#13#10'Access-Control-Allow-Credentials   '#0': hello'#13#10 +
    'Bread: baguette'#13#10#13#10;
var
  C: TParserConfig;
begin
  C := Cfg;
  C.IgnoreInvalidHeadersInRequests := True;
  ParseReq(REQ, 2, C);
  CheckError(peHeaderName);
end;

{ Request half only. }
procedure TTestHttparseLib.Test_header_with_nul_in_value;
const
  REQ = 'GET / HTTP/1.1'#13#10'Access-Control-Allow-Credentials: hell'#0'o'#13#10 +
    'Bread: baguette'#13#10#13#10;
var
  C: TParserConfig;
begin
  ParseReq(REQ, 2, Cfg);
  CheckError(peHeaderValue);
  C := Cfg;
  C.IgnoreInvalidHeadersInRequests := True;
  ParseReq(REQ, 2, C);
  CheckError(peHeaderValue);
end;

{ Request half only. }
procedure TTestHttparseLib.Test_header_with_invalid_char_in_value;
const
  REQ = 'GET / HTTP/1.1'#13#10'Access-Control-Allow-Credentials: hell'#1'o'#13#10 +
    'Bread: baguette'#13#10#13#10;
var
  C: TParserConfig;
begin
  ParseReq(REQ, 2, Cfg);
  CheckError(peHeaderValue);
  C := Cfg;
  C.IgnoreInvalidHeadersInRequests := True;
  ParseReq(REQ, 2, C);
  CheckComplete(77);
  CheckVersion(1);
  CheckMethod('GET');
  CheckPath('/');
  CheckHeaderCount(1);
  CheckHeader(0, 'Bread', 'baguette');
end;

{ Request half only. }
procedure TTestHttparseLib.Test_header_with_invalid_char_in_value_with_folding;
const
  REQ = 'GET / HTTP/1.1'#13#10'Access-Control-Allow-Credentials: hell'#1'o  '#10 +
    ' world!'#13#10'Bread: baguette'#13#10#13#10;
var
  C: TParserConfig;
begin
  ParseReq(REQ, 2, Cfg);
  CheckError(peHeaderValue);
  C := Cfg;
  C.IgnoreInvalidHeadersInRequests := True;
  ParseReq(REQ, 2, C);
  CheckComplete(87);
  CheckVersion(1);
  CheckMethod('GET');
  CheckPath('/');
  CheckHeaderCount(1);
  CheckHeader(0, 'Bread', 'baguette');
end;

procedure TTestHttparseLib.Test_method_within_buffer;
begin
  ParseReq('GET / HTTP/1.1'#13#10#13#10, 0, Cfg);
  AssertTrue('parse_request unwrap', FRes.Status = psComplete);
  AssertTrue('method is Some', FReq.HasMethod);
  AssertTrue('method starts inside buffer', FReq.Method.Off >= 0);
  AssertTrue('method ends inside buffer',
    FReq.Method.Off + FReq.Method.Len <= Length(FBuf));
end;

procedure TTestHttparseLib.Test_request_with_leading_space;
begin
  ParseReq(' GET / HTTP/1.1'#13#10'foo:bar'#13#10#13#10, 1, Cfg);
  CheckError(peToken);
end;

procedure TTestHttparseLib.Test_request_with_invalid_method;
begin
  ParseReq('P()ST / HTTP/1.1'#13#10'foo:bar'#13#10#13#10, 1, Cfg);
  CheckError(peToken);
end;

procedure TTestHttparseLib.Test_utf8_in_path_ok;
begin
  ParseReq('GET /test?post=I'#$E2#$80#$99'msorryIforkedyou HTTP/1.1'#13#10 +
    'Host: example.org'#13#10#13#10, 1, Cfg);
  CheckComplete(67);
  CheckVersion(1);
  CheckMethod('GET');
  CheckPath('/test?post=I'#$E2#$80#$99'msorryIforkedyou');
  CheckHeaderCount(1);
  CheckHeader(0, 'Host', 'example.org');
end;

procedure TTestHttparseLib.Test_bad_utf8_in_path;
begin
  ParseReq('GET /test?post=I'#$E2'msorryIforkedyou HTTP/1.1'#13#10 +
    'Host: example.org'#13#10#13#10, 1, Cfg);
  CheckError(peToken);
end;

const
  REQUEST_WITH_SPACE_BEFORE_FIRST_HEADER =
    'GET / HTTP/1.1'#13#10' Space-Before-Header: hello there'#13#10#13#10;

procedure TTestHttparseLib.Test_forbid_response_with_space_before_first_header_as_request;
begin
  ParseReq(REQUEST_WITH_SPACE_BEFORE_FIRST_HEADER, 1);
  CheckError(peHeaderName);
end;

procedure TTestHttparseLib.Test_allow_response_response_with_space_before_first_header_as_request;
var
  C: TParserConfig;
begin
  C := Cfg;
  C.AllowSpaceBeforeFirstHeaderName := True;
  ParseReq(REQUEST_WITH_SPACE_BEFORE_FIRST_HEADER, 1, C);
  CheckComplete(Length(REQUEST_WITH_SPACE_BEFORE_FIRST_HEADER));
  CheckVersion(1);
  CheckMethod('GET');
  CheckPath('/');
  CheckHeaderCount(1);
  CheckHeader(0, 'Space-Before-Header', 'hello there');
end;

procedure TTestHttparseLib.Test_no_space_after_colon_as_request;
begin
  ParseReq('GET / HTTP/1.1'#13#10'foo:bar'#13#10#13#10, 1, Cfg);
  CheckComplete(27);
  CheckVersion(1);
  CheckMethod('GET');
  CheckPath('/');
  CheckHeaderCount(1);
  CheckHeader(0, 'foo', 'bar');
end;

procedure TTestHttparseLib.Test_doc_parse_headers;
begin
  ParseHdrs('Host: foo.bar'#10'Accept: */*'#10#10'blah blah', 4);
  CheckComplete(27);
  CheckHeaderCount(2);
  CheckHeader(0, 'Host', 'foo.bar');
  CheckHeader(1, 'Accept', '*/*');
end;

procedure TTestHttparseLib.Extra_request_headers_too_many;
begin
  ParseReq('GET / HTTP/1.1'#13#10'A: A'#13#10'B: B'#13#10'C: C'#13#10'D: D'#13#10 +
    'E: E'#13#10#13#10);
  CheckError(peTooManyHeaders);
end;

procedure TTestHttparseLib.Extra_request_headers_partial_line_before_limit;
begin
  { httparse checks the slot only after a whole header line is parsed, so
    an incomplete 5th line with 4 slots is Partial, not TooManyHeaders. }
  ParseReq('GET / HTTP/1.1'#13#10'A: A'#13#10'B: B'#13#10'C: C'#13#10'D: D'#13#10 +
    'E: E');
  CheckPartial;
  CheckHeaderCount(4);
end;

procedure TTestHttparseLib.Extra_request_headers_zero_slots;
begin
  ParseReq('GET / HTTP/1.1'#13#10#13#10, 0);
  CheckComplete(18);
  ParseReq('GET / HTTP/1.1'#13#10'A: A'#13#10#13#10, 0);
  CheckError(peTooManyHeaders);
end;

initialization
  RegisterTest(TTestHttparseLib);
end.

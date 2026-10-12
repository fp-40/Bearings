{ Extra tests for bearings.http1.parser (not ports of httparse tests).
  They cover edge cases that httparse's own tests do not: empty input,
  partial input at every byte boundary, CR/LF handling at each grammar
  position, the exact version match, method fast paths, request-target
  bytes and UTF-8, config options (including the response-only ones,
  which must not change request parsing), the header-count limit and the
  order in which it is checked, slot writes, large offsets, parse_headers
  and the field reset between calls.

  ExpectReq / ExpectHdrs compare a one-line rendering of the result with
  the expected line.  The format is the one printed by the differential
  oracle: for a request,
    'C <consumed> m=<off>,<len> p=<off>,<len> v=<minor> h=<n> <name off>,<len>:<value off>,<len> ...'
    'P m=... p=... v=...'          (Partial)
    'E <httparse::Error> m=... p=... v=...'
  where '-' means None; for parse_headers 'C <consumed> h=<n> ...', 'P'
  or 'E <Error>'.  Every ExpectReq / ExpectHdrs expectation in this file
  is checked against the real httparse 1.10.1 by test_parser_extra_check.py,
  which reads the calls out of this file and runs the same inputs through
  the `expect` binary of test_parser_diff_rs (Rust, test tooling only). }
unit test_parser_extra;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, fpcunit, testregistry, bearings.http1.parser, test_parser_base;

const
  F_MULTI_SP = 1;       // AllowMultipleSpacesInRequestLineDelimiters
  F_SP_FIRST = 2;       // AllowSpaceBeforeFirstHeaderName
  F_IGNORE = 4;         // IgnoreInvalidHeadersInRequests
  { Response-only options: they must not change request parsing. }
  F_RESP_SP_NAME = 8;   // AllowSpacesAfterHeaderNameInResponses
  F_RESP_IGNORE = 16;   // IgnoreInvalidHeadersInResponses
  F_RESP_FOLD = 32;     // AllowObsoleteMultilineHeadersInResponses
  F_RESP_MULTI_SP = 64; // AllowMultipleSpacesInResponseStatusDelimiters

type
  TTestParserExtra = class(TParserTestCase)
  private
    function FlagsConfig(Flags: Integer): TParserConfig;
    function ReqLine: string;
    function HdrsLine: string;
    procedure ExpectReq(const Buf: RawByteString; Flags, Slots: Integer;
      const Expected: string);
    procedure ExpectHdrs(const Buf: RawByteString; Slots: Integer;
      const Expected: string);
    procedure CheckEveryPrefix(const Head: RawByteString; Flags: Integer);
  published
    procedure Extra_empty_input;
    procedure Extra_partial_at_every_byte_boundary;
    procedure Extra_leading_empty_lines;
    procedure Extra_request_line_newline;
    procedure Extra_end_of_head_cr_lf;
    procedure Extra_header_line_cr_lf;
    procedure Extra_empty_header_value_offset;
    procedure Extra_version_exact_match;
    procedure Extra_version_partial_prefixes;
    procedure Extra_method_token;
    procedure Extra_method_fast_paths;
    procedure Extra_request_target;
    procedure Extra_request_target_scan_boundaries;
    procedure Extra_request_target_utf8;
    procedure Extra_multiple_spaces_config;
    procedure Extra_response_options_do_not_affect_requests;
    procedure Extra_ignore_invalid_headers;
    procedure Extra_space_before_first_header;
    procedure Extra_header_limit_order;
    procedure Extra_header_limit_hyper_default;
    procedure Extra_header_slots_written_only;
    procedure Extra_large_head_offsets;
    procedure Extra_parse_headers_trailers;
    procedure Extra_parse_header_block_offset;
    procedure Extra_request_reset_between_calls;
    procedure Extra_hyper_token_error_mapping;
    procedure Extra_scanners_stop_at_len;
    procedure Extra_utf8_validation;
  end;

implementation

const
  ERR_NAMES: array[THttpParseError] of string = ('None', 'HeaderName',
    'HeaderValue', 'NewLine', 'Status', 'Token', 'TooManyHeaders', 'Version');

function OptSlice(Has: Boolean; const S: TSlice): string;
begin
  if Has then
    Result := IntToStr(S.Off) + ',' + IntToStr(S.Len)
  else
    Result := '-';
end;

function TTestParserExtra.FlagsConfig(Flags: Integer): TParserConfig;
begin
  Result := DefaultParserConfig;
  Result.AllowMultipleSpacesInRequestLineDelimiters := (Flags and F_MULTI_SP) <> 0;
  Result.AllowSpaceBeforeFirstHeaderName := (Flags and F_SP_FIRST) <> 0;
  Result.IgnoreInvalidHeadersInRequests := (Flags and F_IGNORE) <> 0;
  Result.AllowSpacesAfterHeaderNameInResponses := (Flags and F_RESP_SP_NAME) <> 0;
  Result.IgnoreInvalidHeadersInResponses := (Flags and F_RESP_IGNORE) <> 0;
  Result.AllowObsoleteMultilineHeadersInResponses := (Flags and F_RESP_FOLD) <> 0;
  Result.AllowMultipleSpacesInResponseStatusDelimiters := (Flags and F_RESP_MULTI_SP) <> 0;
end;

function TTestParserExtra.ReqLine: string;
var
  I: Integer;
  V: string;
begin
  if FReq.HasVersion then V := IntToStr(FReq.Version) else V := '-';
  V := 'm=' + OptSlice(FReq.HasMethod, FReq.Method) + ' p=' +
    OptSlice(FReq.HasPath, FReq.Path) + ' v=' + V;
  case FRes.Status of
    psComplete:
      begin
        Result := Format('C %d %s h=%d', [FRes.Consumed, V, FNumHeaders]);
        for I := 0 to FNumHeaders - 1 do
          Result := Result + Format(' %d,%d:%d,%d', [FHeaders[I].Name.Off,
            FHeaders[I].Name.Len, FHeaders[I].Value.Off, FHeaders[I].Value.Len]);
      end;
    psPartial:
      Result := 'P ' + V;
  else
    Result := 'E ' + ERR_NAMES[FRes.Error] + ' ' + V;
  end;
end;

function TTestParserExtra.HdrsLine: string;
var
  I: Integer;
begin
  case FRes.Status of
    psComplete:
      begin
        Result := Format('C %d h=%d', [FRes.Consumed, FNumHeaders]);
        for I := 0 to FNumHeaders - 1 do
          Result := Result + Format(' %d,%d:%d,%d', [FHeaders[I].Name.Off,
            FHeaders[I].Name.Len, FHeaders[I].Value.Off, FHeaders[I].Value.Len]);
      end;
    psPartial:
      Result := 'P';
  else
    Result := 'E ' + ERR_NAMES[FRes.Error];
  end;
end;

procedure TTestParserExtra.ExpectReq(const Buf: RawByteString; Flags,
  Slots: Integer; const Expected: string);
begin
  ParseReq(Buf, Slots, FlagsConfig(Flags));
  AssertEquals(Format('request "%s" flags=%d slots=%d', [Printable(Buf), Flags, Slots]),
    Expected, ReqLine);
  { Consumed is 0 unless Complete, Error is peNone unless Error. }
  if FRes.Status <> psComplete then
    AssertEquals('Consumed when not Complete', 0, FRes.Consumed);
  if FRes.Status <> psError then
    AssertTrue('Error is peNone when not Error', FRes.Error = peNone);
end;

procedure TTestParserExtra.ExpectHdrs(const Buf: RawByteString; Slots: Integer;
  const Expected: string);
begin
  ParseHdrs(Buf, Slots);
  AssertEquals(Format('parse_headers "%s" slots=%d', [Printable(Buf), Slots]),
    Expected, HdrsLine);
end;

{ Every proper prefix of a complete head must be Partial; the full head
  is Complete(Length); the head followed by body bytes is Complete with
  the same result.  On each Partial, the header slots reported so far
  equal the first slots of the final parse, and HasMethod / HasPath /
  HasVersion never go from True back to False as the prefix grows. }
procedure TTestParserExtra.CheckEveryPrefix(const Head: RawByteString; Flags: Integer);
var
  Final: array[0..MAX_TEST_HEADERS - 1] of THeaderSlice;
  FinalReq: TParsedRequest;
  FinalLine: string;
  L, I: Integer;
  PrevM, PrevP, PrevV: Boolean;
begin
  ParseReq(Head, MAX_TEST_HEADERS, FlagsConfig(Flags));
  AssertTrue('full head is Complete: ' + Printable(Head) + ' got ' + ReqLine,
    FRes.Status = psComplete);
  AssertEquals('Consumed = head length', Length(Head), FRes.Consumed);
  FinalReq := FReq;
  Move(FHeaders, Final, SizeOf(Final));
  FinalLine := ReqLine;
  PrevM := False; PrevP := False; PrevV := False;
  for L := 0 to Length(Head) - 1 do
  begin
    ParseReq(Copy(Head, 1, L), MAX_TEST_HEADERS, FlagsConfig(Flags));
    AssertEquals(Format('prefix %d of "%s"', [L, Printable(Head)]),
      'Ok(Partial)', ResultStr(FRes));
    AssertTrue('NumHeaders on Partial <= final', FNumHeaders <= FinalReq.NumHeaders);
    for I := 0 to FNumHeaders - 1 do
      AssertTrue(Format('prefix %d: header slot %d equals final', [L, I]),
        CompareByte(FHeaders[I], Final[I], SizeOf(THeaderSlice)) = 0);
    if FReq.HasMethod then
      AssertTrue('method slice stable', (FReq.Method.Off = FinalReq.Method.Off) and
        (FReq.Method.Len = FinalReq.Method.Len));
    if FReq.HasPath then
      AssertTrue('path slice stable', (FReq.Path.Off = FinalReq.Path.Off) and
        (FReq.Path.Len = FinalReq.Path.Len));
    AssertTrue(Format('prefix %d: HasMethod monotonic', [L]), FReq.HasMethod or not PrevM);
    AssertTrue(Format('prefix %d: HasPath monotonic', [L]), FReq.HasPath or not PrevP);
    AssertTrue(Format('prefix %d: HasVersion monotonic', [L]), FReq.HasVersion or not PrevV);
    PrevM := FReq.HasMethod; PrevP := FReq.HasPath; PrevV := FReq.HasVersion;
  end;
  ParseReq(Head + 'BODY'#13#10#13#10, MAX_TEST_HEADERS, FlagsConfig(Flags));
  AssertEquals('head + body: same result as head alone', FinalLine, ReqLine);
end;

procedure TTestParserExtra.Extra_empty_input;
var
  Req: TParsedRequest;
  R: TParseResult;
  N: Integer;
begin
  { Buf = nil, Len = 0, no header slots. }
  R := ParseRequest(nil, 0, Req, nil, 0);
  AssertTrue('nil/0 request is Partial', R.Status = psPartial);
  AssertFalse('no method', Req.HasMethod);
  N := -1;
  R := ParseHeaders(nil, 0, nil, 0, N);
  AssertTrue('nil/0 parse_headers is Partial', R.Status = psPartial);
  AssertEquals('NumHeaders', 0, N);
  ExpectReq('', 0, 4, 'P m=- p=- v=-');
  ExpectReq(#13#10#13#10, 0, 4, 'P m=- p=- v=-');
  ExpectReq(#10, 0, 4, 'P m=- p=- v=-');
  ExpectReq(#13, 0, 4, 'P m=- p=- v=-');
  ExpectHdrs('', 4, 'P');
end;

procedure TTestParserExtra.Extra_partial_at_every_byte_boundary;
var
  L: Integer;
const
  HDRS = 'A: b'#13#10'C:d'#10#13#10;
begin
  CheckEveryPrefix('GET /a?b HTTP/1.1'#13#10'Host: x'#13#10'Accept: */*'#13#10#13#10, 0);
  CheckEveryPrefix(#13#10#10'POST /p HTTP/1.0'#10'A:b'#10'C: '#9#10#10, 0);
  CheckEveryPrefix('GET  /  HTTP/1.1'#13#10#13#10, F_MULTI_SP);
  CheckEveryPrefix('GET / HTTP/1.1'#13#10' Lead: x'#13#10#13#10, F_SP_FIRST);
  CheckEveryPrefix('GET / HTTP/1.1'#13#10'Bad Name: v'#13#10': x'#13#10'Ok: 1'#13#10#13#10, F_IGNORE);
  CheckEveryPrefix('M-SEARCH * HTTP/1.1'#13#10'X-V: '#$E3#$81#$B2#13#10#13#10, 0);
  CheckEveryPrefix('GET /'#$C3#$A9' HTTP/1.1'#13#10'A:'#13#10'B:  '#9#13#10#13#10, 0);
  CheckEveryPrefix('GETX /x HTTP/1.1'#13#10#13#10, 0);
  CheckEveryPrefix('POST /x HTTP/1.1'#13#10#13#10, 0);
  { parse_headers (chunked trailers in hyper). }
  for L := 0 to Length(HDRS) - 1 do
  begin
    ParseHdrs(Copy(HDRS, 1, L), 4);
    AssertEquals(Format('parse_headers prefix %d', [L]), 'P', HdrsLine);
  end;
  ExpectHdrs(HDRS, 4, 'C 12 h=2 0,1:3,1 6,1:8,1');
end;

procedure TTestParserExtra.Extra_leading_empty_lines;
begin
  ExpectReq(#13'GET / HTTP/1.1'#13#10#13#10, 0, 4, 'E NewLine m=- p=- v=-');
  ExpectReq(#13#13, 0, 4, 'E NewLine m=- p=- v=-');
  ExpectReq(#13#10#13, 0, 4, 'P m=- p=- v=-');
  ExpectReq(#10#13#10#10'GET / HTTP/1.1'#10#10, 0, 4, 'C 20 m=4,3 p=8,1 v=1 h=0');
  { Only CRLF / LF are skipped: no other whitespace before the method. }
  ExpectReq(#13#10' GET / HTTP/1.1'#13#10#13#10, 0, 4, 'E Token m=- p=- v=-');
  ExpectReq(#9'GET / HTTP/1.1'#13#10#13#10, 0, 4, 'E Token m=- p=- v=-');
  ExpectReq(#13#10' GET / HTTP/1.1'#13#10#13#10, F_MULTI_SP, 4, 'E Token m=- p=- v=-');
end;

procedure TTestParserExtra.Extra_request_line_newline;
begin
  ExpectReq('GET / HTTP/1.1'#13'X', 0, 4, 'E NewLine m=0,3 p=4,1 v=1');
  ExpectReq('GET / HTTP/1.1'#13, 0, 4, 'P m=0,3 p=4,1 v=1');
  ExpectReq('GET / HTTP/1.1', 0, 4, 'P m=0,3 p=4,1 v=1');
  ExpectReq('GET / HTTP/1.1X'#13#10#13#10, 0, 4, 'E NewLine m=0,3 p=4,1 v=1');
  ExpectReq('GET / HTTP/1.1 '#13#10#13#10, 0, 4, 'E NewLine m=0,3 p=4,1 v=1');
  ExpectReq('GET / HTTP/1.1 '#13#10#13#10, F_MULTI_SP, 4, 'E NewLine m=0,3 p=4,1 v=1');
  ExpectReq('GET / HTTP/1.10'#13#10#13#10, 0, 4, 'E NewLine m=0,3 p=4,1 v=1');
  ExpectReq('GET / HTTP/1.1'#10#10, 0, 4, 'C 16 m=0,3 p=4,1 v=1 h=0');
  { CR or LF inside the request-target. }
  ExpectReq('GET /a'#10'b HTTP/1.1'#13#10#13#10, 0, 4, 'E Token m=0,3 p=- v=-');
  ExpectReq('GET /a'#13'b HTTP/1.1'#13#10#13#10, 0, 4, 'E Token m=0,3 p=- v=-');
  ExpectReq('GET /'#13#10#13#10, 0, 4, 'E Token m=0,3 p=- v=-');
end;

procedure TTestParserExtra.Extra_end_of_head_cr_lf;
begin
  { A lone CR where the empty line ending the head is expected. }
  ExpectReq('GET / HTTP/1.1'#13#10#13'X', 0, 4, 'E NewLine m=0,3 p=4,1 v=1');
  ExpectReq('GET / HTTP/1.1'#13#10#13'X', F_IGNORE, 4, 'E NewLine m=0,3 p=4,1 v=1');
  ExpectReq('GET / HTTP/1.1'#13#10#13, 0, 4, 'P m=0,3 p=4,1 v=1');
  ExpectReq('GET / HTTP/1.1'#13#10'A: b'#13#10#13'X', 0, 4, 'E NewLine m=0,3 p=4,1 v=1');
  ExpectReq('GET / HTTP/1.1'#13#10'A: b'#13#10#13'X', F_IGNORE, 4, 'E NewLine m=0,3 p=4,1 v=1');
  ExpectReq('GET / HTTP/1.1'#13#10'A: b'#13#10#10, 0, 4, 'C 23 m=0,3 p=4,1 v=1 h=1 16,1:19,1');
  { Mixed CRLF and bare LF line endings. }
  ExpectReq('GET / HTTP/1.1'#10'A: b'#13#10'C: d'#10#13#10, 0, 4,
    'C 28 m=0,3 p=4,1 v=1 h=2 15,1:18,1 21,1:24,1');
end;

procedure TTestParserExtra.Extra_header_line_cr_lf;
begin
  { CR not followed by LF ends in HeaderValue even with IgnoreInvalidHeaders. }
  ExpectReq('GET / HTTP/1.1'#13#10'A: b'#13'X'#13#10#13#10, 0, 4, 'E HeaderValue m=0,3 p=4,1 v=1');
  ExpectReq('GET / HTTP/1.1'#13#10'A: b'#13'X'#13#10#13#10, F_IGNORE, 4, 'E HeaderValue m=0,3 p=4,1 v=1');
  ExpectReq('GET / HTTP/1.1'#13#10'A:'#13'X'#13#10#13#10, 0, 4, 'E HeaderValue m=0,3 p=4,1 v=1');
  ExpectReq('GET / HTTP/1.1'#13#10'A:'#13'X'#13#10#13#10, F_IGNORE, 4, 'E HeaderValue m=0,3 p=4,1 v=1');
  ExpectReq('GET / HTTP/1.1'#13#10'A: b'#13#13#10#13#10, 0, 4, 'E HeaderValue m=0,3 p=4,1 v=1');
  { CR inside a header name. }
  ExpectReq('GET / HTTP/1.1'#13#10'A'#13'B: c'#13#10#13#10, 0, 4, 'E HeaderName m=0,3 p=4,1 v=1');
  ExpectReq('GET / HTTP/1.1'#13#10'A'#13'B: c'#13#10#13#10, F_IGNORE, 4, 'E HeaderName m=0,3 p=4,1 v=1');
  { A name followed by CRLF is a missing colon: skipped with IgnoreInvalidHeaders. }
  ExpectReq('GET / HTTP/1.1'#13#10'A'#13#10'B: c'#13#10#13#10, 0, 4, 'E HeaderName m=0,3 p=4,1 v=1');
  ExpectReq('GET / HTTP/1.1'#13#10'A'#13#10'B: c'#13#10#13#10, F_IGNORE, 4,
    'C 27 m=0,3 p=4,1 v=1 h=1 19,1:22,1');
  { Trailing SP / HTAB before a bare LF are trimmed from the value. }
  ExpectReq('GET / HTTP/1.1'#13#10'A: b '#9#10#10, 0, 4, 'C 24 m=0,3 p=4,1 v=1 h=1 16,1:19,1');
  { Inner SP / HTAB are kept. }
  ExpectReq('GET / HTTP/1.1'#13#10'A: b '#9'c'#13#10#13#10, 0, 4, 'C 27 m=0,3 p=4,1 v=1 h=1 16,1:19,4');
  { Each partial position inside a header line. }
  ExpectReq('GET / HTTP/1.1'#13#10'A', 0, 4, 'P m=0,3 p=4,1 v=1');
  ExpectReq('GET / HTTP/1.1'#13#10'A:', 0, 4, 'P m=0,3 p=4,1 v=1');
  ExpectReq('GET / HTTP/1.1'#13#10'A: ', 0, 4, 'P m=0,3 p=4,1 v=1');
  ExpectReq('GET / HTTP/1.1'#13#10'A:'#13, 0, 4, 'P m=0,3 p=4,1 v=1');
  ExpectReq('GET / HTTP/1.1'#13#10'A: b', 0, 4, 'P m=0,3 p=4,1 v=1');
  ExpectReq('GET / HTTP/1.1'#13#10'A: b'#13, 0, 4, 'P m=0,3 p=4,1 v=1');
  ExpectReq('GET / HTTP/1.1'#13#10'A: b'#13#10, 0, 4, 'P m=0,3 p=4,1 v=1');
  { obs-fold is never allowed in requests: the continuation line starts
    with SP, which is not a header name byte. }
  ExpectReq('GET / HTTP/1.1'#13#10'A: b'#13#10' c'#13#10#13#10, 0, 4, 'E HeaderName m=0,3 p=4,1 v=1');
  ExpectReq('GET / HTTP/1.1'#13#10'A: b'#13#10' c'#13#10#13#10, F_RESP_FOLD, 4, 'E HeaderName m=0,3 p=4,1 v=1');
end;

procedure TTestParserExtra.Extra_empty_header_value_offset;
begin
  { An empty value has Len 0 and Off = the position of its CR or LF. }
  ExpectReq('GET / HTTP/1.1'#13#10'A:   '#13#10#13#10, 0, 4, 'C 25 m=0,3 p=4,1 v=1 h=1 16,1:21,0');
  ExpectReq('GET / HTTP/1.1'#13#10'A:'#10#10, 0, 4, 'C 20 m=0,3 p=4,1 v=1 h=1 16,1:18,0');
  ExpectReq('GET / HTTP/1.1'#13#10'A:'#9' '#9#13#10'B: x'#13#10#13#10, 0, 4,
    'C 31 m=0,3 p=4,1 v=1 h=2 16,1:21,0 23,1:26,1');
  CheckHeader(0, 'A', '');
  CheckHeader(1, 'B', 'x');
end;

procedure TTestParserExtra.Extra_version_exact_match;
begin
  ExpectReq('GET / HTTP/1.0'#13#10#13#10, 0, 4, 'C 18 m=0,3 p=4,1 v=0 h=0');
  ExpectReq('GET / HTTP/1.1'#13#10#13#10, 0, 4, 'C 18 m=0,3 p=4,1 v=1 h=0');
  ExpectReq('GET / HTTP/1.2'#13#10#13#10, 0, 4, 'E Version m=0,3 p=4,1 v=-');
  ExpectReq('GET / HTTP/1.9'#13#10#13#10, 0, 4, 'E Version m=0,3 p=4,1 v=-');
  ExpectReq('GET / HTTP/2.0'#13#10#13#10, 0, 4, 'E Version m=0,3 p=4,1 v=-');
  ExpectReq('GET / HTTP/0.9'#13#10#13#10, 0, 4, 'E Version m=0,3 p=4,1 v=-');
  ExpectReq('GET / http/1.1'#13#10#13#10, 0, 4, 'E Version m=0,3 p=4,1 v=-');
  ExpectReq('GET / HTTP/1,1'#13#10#13#10, 0, 4, 'E Version m=0,3 p=4,1 v=-');
  ExpectReq('GET / HTTP/11'#13#10#13#10, 0, 4, 'E Version m=0,3 p=4,1 v=-');
  { Exactly 8 bytes available: compared as a whole. }
  ExpectReq('GET / HTTP/1.x', 0, 4, 'E Version m=0,3 p=4,1 v=-');
  ExpectReq('PRI * HTTP/2.0'#13#10#13#10'SM'#13#10#13#10, 0, 4, 'E Version m=0,3 p=4,1 v=-');
end;

procedure TTestParserExtra.Extra_version_partial_prefixes;
const
  PREFIX = 'HTTP/1.';
var
  I: Integer;
begin
  { Fewer than 8 bytes: a prefix of 'HTTP/1.' is Partial ... }
  for I := 0 to Length(PREFIX) do
  begin
    ParseReq('GET / ' + Copy(PREFIX, 1, I));
    AssertEquals(Format('version prefix %d', [I]), 'P m=0,3 p=4,1 v=-', ReqLine);
  end;
  { ... and the first wrong byte is a Version error at once. }
  for I := 0 to Length(PREFIX) - 1 do
  begin
    ParseReq('GET / ' + Copy(PREFIX, 1, I) + 'X');
    AssertEquals(Format('bad version byte at %d', [I]), 'E Version m=0,3 p=4,1 v=-', ReqLine);
  end;
  ExpectReq('GET / HTTP/1', 0, 4, 'P m=0,3 p=4,1 v=-');
  ExpectReq('GET / HTTX', 0, 4, 'E Version m=0,3 p=4,1 v=-');
  ExpectReq('GET / h', 0, 4, 'E Version m=0,3 p=4,1 v=-');
end;

procedure TTestParserExtra.Extra_method_token;
begin
  { Every tchar class: the 15 symbols, digits and letters. }
  ExpectReq('!#$%&''*+-.^_`|~09AZaz / HTTP/1.1'#13#10#13#10, 0, 4, 'C 36 m=0,21 p=22,1 v=1 h=0');
  ExpectReq('get / HTTP/1.1'#13#10#13#10, 0, 4, 'C 18 m=0,3 p=4,1 v=1 h=0');
  ExpectReq('G(T / HTTP/1.1'#13#10#13#10, 0, 4, 'E Token m=- p=- v=-');
  ExpectReq(#$80'ET / HTTP/1.1'#13#10#13#10, 0, 4, 'E Token m=- p=- v=-');
  ExpectReq('GET'#9'/ HTTP/1.1'#13#10#13#10, 0, 4, 'E Token m=- p=- v=-');
  ExpectReq('GET'#0'/ HTTP/1.1'#13#10#13#10, 0, 4, 'E Token m=- p=- v=-');
  ExpectReq('GET:/ HTTP/1.1'#13#10#13#10, 0, 4, 'E Token m=- p=- v=-');
  { 'GE' is the method, 'T' the target, then '/ HTTP/1' is a bad version. }
  ExpectReq('GE T / HTTP/1.1'#13#10#13#10, 0, 4, 'E Version m=0,2 p=3,1 v=-');
end;

procedure TTestParserExtra.Extra_method_fast_paths;
begin
  { Bytes that start like GET / POST but are other tokens. }
  ExpectReq('GETX / HTTP/1.1'#13#10#13#10, 0, 4, 'C 19 m=0,4 p=5,1 v=1 h=0');
  ExpectReq('POSTX / HTTP/1.1'#13#10#13#10, 0, 4, 'C 20 m=0,5 p=6,1 v=1 h=0');
  ExpectReq('PUT / HTTP/1.1'#13#10#13#10, 0, 4, 'C 18 m=0,3 p=4,1 v=1 h=0');
  ExpectReq('GET/ HTTP/1.1'#13#10#13#10, 0, 4, 'E Token m=- p=- v=-');
  ExpectReq('POST/ HTTP/1.1'#13#10#13#10, 0, 4, 'E Token m=- p=- v=-');
  { Partial at each length around the 4- and 5-byte fast-path checks. }
  ExpectReq('P', 0, 4, 'P m=- p=- v=-');
  ExpectReq('PO', 0, 4, 'P m=- p=- v=-');
  ExpectReq('POS', 0, 4, 'P m=- p=- v=-');
  ExpectReq('POST', 0, 4, 'P m=- p=- v=-');
  ExpectReq('POST ', 0, 4, 'P m=0,4 p=- v=-');
  ExpectReq('GET ', 0, 4, 'P m=0,3 p=- v=-');
  ExpectReq('GETX', 0, 4, 'P m=- p=- v=-');
  ExpectReq('GETX ', 0, 4, 'P m=0,4 p=- v=-');
end;

procedure TTestParserExtra.Extra_request_target;
begin
  ExpectReq('GET * HTTP/1.1'#13#10#13#10, 0, 4, 'C 18 m=0,3 p=4,1 v=1 h=0');
  ExpectReq('GET http://a.b:80/c?d#e HTTP/1.1'#13#10#13#10, 0, 4, 'C 36 m=0,3 p=4,19 v=1 h=0');
  { URI_MAP accepts all of 0x21..0x7E, including bytes that RFC 3986 does not. }
  ExpectReq('GET /"{}|\^`<>[] HTTP/1.1'#13#10#13#10, 0, 4, 'C 29 m=0,3 p=4,12 v=1 h=0');
  ExpectReq('GET /a'#9'b HTTP/1.1'#13#10#13#10, 0, 4, 'E Token m=0,3 p=- v=-');
  ExpectReq('GET /a'#0'b HTTP/1.1'#13#10#13#10, 0, 4, 'E Token m=0,3 p=- v=-');
  ExpectReq('GET /a'#$7F'b HTTP/1.1'#13#10#13#10, 0, 4, 'E Token m=0,3 p=- v=-');
  ExpectReq('GET /a'#$1F'b HTTP/1.1'#13#10#13#10, 0, 4, 'E Token m=0,3 p=- v=-');
  { A target that runs to the end of the buffer is Partial. }
  ExpectReq('GET /abc', 0, 4, 'P m=0,3 p=- v=-');
end;

procedure TTestParserExtra.Extra_request_target_scan_boundaries;
var
  N, K: Integer;
  Path, Buf: RawByteString;
begin
  { Path lengths around 8/16/32/64-byte block sizes. }
  for N := 1 to 70 do
  begin
    Path := '/' + StringOfChar('a', N - 1);
    ParseReq('GET ' + Path + ' HTTP/1.1'#13#10#13#10);
    AssertEquals(Format('path length %d', [N]),
      Format('C %d m=0,3 p=4,%d v=1 h=0', [N + 17, N]), ReqLine);
  end;
  { One invalid byte at every position of a 65-byte path. }
  for K := 2 to 65 do
  begin
    Buf := 'GET /' + StringOfChar('a', 64) + ' HTTP/1.1'#13#10#13#10;
    Buf[4 + K] := #$7F;
    ParseReq(Buf);
    AssertEquals(Format('DEL at path byte %d', [K]), 'E Token m=0,3 p=- v=-', ReqLine);
  end;
  { Header value lengths around block sizes, with an HTAB inside. }
  for N := 1 to 70 do
  begin
    Buf := StringOfChar('v', N);
    if N >= 3 then
      Buf[N div 2 + 1] := #9; // inside the value: not leading, not trailing
    ParseReq('GET / HTTP/1.1'#13#10'X: ' + Buf + #13#10#13#10);
    AssertEquals(Format('value length %d', [N]),
      Format('C %d m=0,3 p=4,1 v=1 h=1 16,1:19,%d', [N + 23, N]), ReqLine);
  end;
end;

procedure TTestParserExtra.Extra_request_target_utf8;
begin
  ExpectReq('GET /'#$C3#$A9' HTTP/1.1'#13#10#13#10, 0, 4, 'C 20 m=0,3 p=4,3 v=1 h=0');
  ExpectReq('GET /a'#$E2#$82#$AC'b'#$F0#$9F#$98#$80'c HTTP/1.1'#13#10#13#10, 0, 4,
    'C 28 m=0,3 p=4,11 v=1 h=0');
  ExpectReq('GET /'#$F4#$8F#$BF#$BF' HTTP/1.1'#13#10#13#10, 0, 4, 'C 22 m=0,3 p=4,5 v=1 h=0');
  { UTF-8 is checked only once the delimiting SP has arrived. }
  ExpectReq('GET /'#$FF, 0, 4, 'P m=0,3 p=- v=-');
  ExpectReq('GET /'#$FF' ', 0, 4, 'E Token m=0,3 p=- v=-');
  ExpectReq('GET /'#$C3, 0, 4, 'P m=0,3 p=- v=-');
  ExpectReq('GET /'#$C3' ', 0, 4, 'E Token m=0,3 p=- v=-');
  ExpectReq('GET /'#$C3'a HTTP/1.1'#13#10#13#10, 0, 4, 'E Token m=0,3 p=- v=-');
  ExpectReq('GET /'#$C0#$80' HTTP/1.1'#13#10#13#10, 0, 4, 'E Token m=0,3 p=- v=-');
  ExpectReq('GET /'#$ED#$A0#$80' HTTP/1.1'#13#10#13#10, 0, 4, 'E Token m=0,3 p=- v=-');
  ExpectReq('GET /'#$F4#$90#$80#$80' HTTP/1.1'#13#10#13#10, 0, 4, 'E Token m=0,3 p=- v=-');
  { Header values are not UTF-8 checked. }
  ExpectReq('GET / HTTP/1.1'#13#10'A: '#$FF#$C0#13#10#13#10, 0, 4, 'C 25 m=0,3 p=4,1 v=1 h=1 16,1:19,2');
end;

procedure TTestParserExtra.Extra_multiple_spaces_config;
begin
  ExpectReq('GET  /  HTTP/1.1'#13#10#13#10, F_MULTI_SP, 4, 'C 20 m=0,3 p=5,1 v=1 h=0');
  ExpectReq('POST   /x   HTTP/1.0'#13#10#13#10, F_MULTI_SP, 4, 'C 24 m=0,4 p=7,2 v=0 h=0');
  ExpectReq('GET  ', F_MULTI_SP, 4, 'P m=0,3 p=- v=-');
  ExpectReq('GET  /  ', F_MULTI_SP, 4, 'P m=0,3 p=5,1 v=-');
  { Only SP is skipped, not HTAB. }
  ExpectReq('GET '#9'/ HTTP/1.1'#13#10#13#10, F_MULTI_SP, 4, 'E Token m=0,3 p=- v=-');
  ExpectReq('GET /'#9'HTTP/1.1'#13#10#13#10, F_MULTI_SP, 4, 'E Token m=0,3 p=- v=-');
  ExpectReq('GET / '#9'HTTP/1.1'#13#10#13#10, F_MULTI_SP, 4, 'E Version m=0,3 p=4,1 v=-');
  { The same inputs without the option. }
  ExpectReq('GET  /  HTTP/1.1'#13#10#13#10, 0, 4, 'E Token m=0,3 p=- v=-');
  ExpectReq('GET /  HTTP/1.1'#13#10#13#10, 0, 4, 'E Version m=0,3 p=4,1 v=-');
end;

procedure TTestParserExtra.Extra_response_options_do_not_affect_requests;
begin
  ExpectReq('GET / HTTP/1.1'#13#10'Host : x'#13#10#13#10, F_RESP_SP_NAME, 4, 'E HeaderName m=0,3 p=4,1 v=1');
  ExpectReq('GET / HTTP/1.1'#13#10'Host : x'#13#10#13#10, F_RESP_IGNORE, 4, 'E HeaderName m=0,3 p=4,1 v=1');
  ExpectReq('GET / HTTP/1.1'#13#10'Host : x'#13#10#13#10, F_RESP_SP_NAME or F_RESP_IGNORE, 4,
    'E HeaderName m=0,3 p=4,1 v=1');
  ExpectReq('GET / HTTP/1.1'#13#10'A: b'#1#13#10#13#10, F_RESP_IGNORE, 4, 'E HeaderValue m=0,3 p=4,1 v=1');
  ExpectReq('GET  / HTTP/1.1'#13#10#13#10, F_RESP_MULTI_SP, 4, 'E Token m=0,3 p=- v=-');
  { The request option still works when response options are also set. }
  ExpectReq('GET / HTTP/1.1'#13#10'Host : x'#13#10#13#10, F_IGNORE or F_RESP_SP_NAME, 4,
    'C 28 m=0,3 p=4,1 v=1 h=0');
end;

procedure TTestParserExtra.Extra_ignore_invalid_headers;
begin
  { NUL or a lone CR in a skipped line is still an error. }
  ExpectReq('GET / HTTP/1.1'#13#10'Bad Name'#0'x'#13#10#13#10, F_IGNORE, 4, 'E HeaderName m=0,3 p=4,1 v=1');
  ExpectReq('GET / HTTP/1.1'#13#10'Bad Name'#13'x'#13#10#13#10, F_IGNORE, 4, 'E HeaderName m=0,3 p=4,1 v=1');
  ExpectReq('GET / HTTP/1.1'#13#10'A: b'#0'c'#13#10#13#10, F_IGNORE, 4, 'E HeaderValue m=0,3 p=4,1 v=1');
  ExpectReq('GET / HTTP/1.1'#13#10'A:'#0#13#10#13#10, F_IGNORE, 4, 'E HeaderValue m=0,3 p=4,1 v=1');
  { A skipped line that runs to the end of the buffer is Partial. }
  ExpectReq('GET / HTTP/1.1'#13#10'Bad Name', F_IGNORE, 4, 'P m=0,3 p=4,1 v=1');
  ExpectReq('GET / HTTP/1.1'#13#10'Bad Name'#13, F_IGNORE, 4, 'P m=0,3 p=4,1 v=1');
  { Skipped lines: bad value byte, bad value byte right after the colon,
    empty name, bad name byte, LF-only line ends. }
  ExpectReq('GET / HTTP/1.1'#13#10'A: b'#1'c'#13#10'D: e'#13#10#13#10, F_IGNORE, 4,
    'C 32 m=0,3 p=4,1 v=1 h=1 24,1:27,1');
  ExpectReq('GET / HTTP/1.1'#13#10'A:'#1#13#10'D: e'#13#10#13#10, F_IGNORE, 4,
    'C 29 m=0,3 p=4,1 v=1 h=1 21,1:24,1');
  ExpectReq('GET / HTTP/1.1'#13#10':'#13#10'B: c'#13#10#13#10, F_IGNORE, 4,
    'C 27 m=0,3 p=4,1 v=1 h=1 19,1:22,1');
  ExpectReq('GET / HTTP/1.1'#10'X Y'#10'B: c'#10#10, F_IGNORE, 4, 'C 25 m=0,3 p=4,1 v=1 h=1 19,1:22,1');
  ExpectReq('GET / HTTP/1.1'#13#10'X Y'#13#10#13#10, F_IGNORE, 4, 'C 23 m=0,3 p=4,1 v=1 h=0');
  { A line starting with ':' has an empty name, even if a second ':' follows. }
  ExpectReq('GET / HTTP/1.1'#13#10'::x'#13#10#13#10, 0, 4, 'E HeaderName m=0,3 p=4,1 v=1');
  ExpectReq('GET / HTTP/1.1'#13#10'::x'#13#10#13#10, F_IGNORE, 4, 'C 23 m=0,3 p=4,1 v=1 h=0');
  ExpectHdrs(':a:b'#13#10#13#10, 4, 'E HeaderName');
  { Without the option the same inputs are errors. }
  ExpectReq('GET / HTTP/1.1'#13#10'A: b'#1'c'#13#10'D: e'#13#10#13#10, 0, 4, 'E HeaderValue m=0,3 p=4,1 v=1');
  ExpectReq('GET / HTTP/1.1'#13#10':'#13#10'B: c'#13#10#13#10, 0, 4, 'E HeaderName m=0,3 p=4,1 v=1');
  ExpectReq('GET / HTTP/1.1'#10'X Y'#10'B: c'#10#10, 0, 4, 'E HeaderName m=0,3 p=4,1 v=1');
end;

procedure TTestParserExtra.Extra_space_before_first_header;
begin
  ExpectReq('GET / HTTP/1.1'#13#10'  '#9'A: b'#13#10#13#10, F_SP_FIRST, 4,
    'C 27 m=0,3 p=4,1 v=1 h=1 19,1:22,1');
  { Only before the first header. }
  ExpectReq('GET / HTTP/1.1'#13#10'A: b'#13#10' C: d'#13#10#13#10, F_SP_FIRST, 4,
    'E HeaderName m=0,3 p=4,1 v=1');
  ExpectReq('GET / HTTP/1.1'#13#10'A: b'#13#10' C: d'#13#10#13#10, F_SP_FIRST or F_IGNORE, 4,
    'C 31 m=0,3 p=4,1 v=1 h=1 16,1:19,1');
  { Whitespace, then the empty line: no headers. }
  ExpectReq('GET / HTTP/1.1'#13#10'   '#13#10, F_SP_FIRST, 4, 'C 21 m=0,3 p=4,1 v=1 h=0');
  ExpectReq('GET / HTTP/1.1'#13#10'  ', F_SP_FIRST, 4, 'P m=0,3 p=4,1 v=1');
  { A skipped invalid line does not count as the first header. }
  ExpectReq('GET / HTTP/1.1'#13#10':x'#13#10' A: b'#13#10#13#10, F_SP_FIRST or F_IGNORE, 4,
    'C 29 m=0,3 p=4,1 v=1 h=1 21,1:24,1');
  ExpectReq('GET / HTTP/1.1'#13#10':x'#13#10' A: b'#13#10#13#10, F_SP_FIRST, 4,
    'E HeaderName m=0,3 p=4,1 v=1');
  ExpectReq('GET / HTTP/1.1'#13#10' A: b'#13#10#13#10, 0, 4, 'E HeaderName m=0,3 p=4,1 v=1');
  ExpectReq('GET / HTTP/1.1'#13#10' A: b'#13#10#13#10, F_IGNORE, 4, 'C 25 m=0,3 p=4,1 v=1 h=0');
end;

procedure TTestParserExtra.Extra_header_limit_order;
begin
  { The slot is taken only after the whole line has been parsed, so a
    bad byte in an extra line is reported before TooManyHeaders, and an
    incomplete extra line is Partial. }
  ExpectReq('GET / HTTP/1.1'#13#10'A: a'#13#10'B: b'#1#13#10#13#10, 0, 1, 'E HeaderValue m=0,3 p=4,1 v=1');
  ExpectReq('GET / HTTP/1.1'#13#10'A: a'#13#10'B: b'#13#10'C'#1, 0, 1, 'E TooManyHeaders m=0,3 p=4,1 v=1');
  ExpectReq('GET / HTTP/1.1'#13#10'A: a'#13#10'B: b', 0, 1, 'P m=0,3 p=4,1 v=1');
  AssertEquals('NumHeaders on Partial', 1, FNumHeaders);
  ExpectReq('GET / HTTP/1.1'#13#10'A: a'#13#10'B: b'#13#10#13#10, 0, 1, 'E TooManyHeaders m=0,3 p=4,1 v=1');
  { Skipped lines do not take a slot. }
  ExpectReq('GET / HTTP/1.1'#13#10'A: a'#13#10'X Y'#13#10#13#10, F_IGNORE, 1,
    'C 29 m=0,3 p=4,1 v=1 h=1 16,1:19,1');
  ExpectReq('GET / HTTP/1.1'#13#10'A: a'#13#10'B: b'#13#10#13#10, F_IGNORE, 1,
    'E TooManyHeaders m=0,3 p=4,1 v=1');
  { Zero slots. }
  ExpectReq('GET / HTTP/1.1'#13#10'A', 0, 0, 'P m=0,3 p=4,1 v=1');
  ExpectReq('GET / HTTP/1.1'#13#10'A: a'#13, 0, 0, 'P m=0,3 p=4,1 v=1');
  ExpectReq('GET / HTTP/1.1'#13#10'A: a'#13#10, 0, 0, 'E TooManyHeaders m=0,3 p=4,1 v=1');
  ExpectReq('GET / HTTP/1.1'#13#10'A:'#13#10, 0, 0, 'E TooManyHeaders m=0,3 p=4,1 v=1');
  ExpectHdrs('A: b'#13#10#13#10, 0, 'E TooManyHeaders');
end;

procedure TTestParserExtra.Extra_header_limit_hyper_default;
const
  SLOTS = 100; // hyper DEFAULT_MAX_HEADERS
var
  Hdrs: array[0..SLOTS] of THeaderSlice;
  Req: TParsedRequest;
  R: TParseResult;
  Buf, Line: RawByteString;
  I: Integer;
begin
  Buf := 'GET / HTTP/1.1'#13#10;
  for I := 0 to SLOTS - 1 do
    Buf := Buf + 'H' + IntToStr(I) + ': v' + IntToStr(I) + #13#10;
  R := ParseRequest(@Buf[1], Length(Buf), Req, @Hdrs[0], SLOTS);
  AssertTrue('100 complete lines, no end yet: Partial', R.Status = psPartial);
  AssertEquals('NumHeaders', SLOTS, Req.NumHeaders);
  Line := Buf + #13#10;
  R := ParseRequest(@Line[1], Length(Line), Req, @Hdrs[0], SLOTS);
  AssertTrue('100 headers in 100 slots: Complete', R.Status = psComplete);
  AssertEquals('Consumed', Length(Line), R.Consumed);
  AssertEquals('NumHeaders', SLOTS, Req.NumHeaders);
  AssertEquals('last name', 'H99', Copy(Line, Hdrs[99].Name.Off + 1, Hdrs[99].Name.Len));
  AssertEquals('last value', 'v99', Copy(Line, Hdrs[99].Value.Off + 1, Hdrs[99].Value.Len));
  Line := Buf + 'H100: v';
  R := ParseRequest(@Line[1], Length(Line), Req, @Hdrs[0], SLOTS);
  AssertTrue('101st line incomplete: Partial', R.Status = psPartial);
  Line := Buf + 'H100: v'#13#10#13#10;
  R := ParseRequest(@Line[1], Length(Line), Req, @Hdrs[0], SLOTS);
  AssertTrue('101 headers in 100 slots: Error', R.Status = psError);
  AssertTrue('TooManyHeaders', R.Error = peTooManyHeaders);
end;

procedure TTestParserExtra.Extra_header_slots_written_only;
var
  Sentinel: THeaderSlice;
  I: Integer;
begin
  FillChar(Sentinel, SizeOf(Sentinel), $FF); // ParseReq pre-fills slots with $FF
  ParseReq('GET / HTTP/1.1'#13#10'A: 1'#13#10'B: 2'#13#10#13#10, 4);
  CheckComplete(Length(FBuf));
  for I := 2 to MAX_TEST_HEADERS - 1 do
    AssertTrue(Format('slot %d untouched after Complete', [I]),
      CompareByte(FHeaders[I], Sentinel, SizeOf(Sentinel)) = 0);
  ParseReq('GET / HTTP/1.1'#13#10'A: 1'#13#10'B: 2'#13#10'C: 3'#13#10#13#10, 2);
  CheckError(peTooManyHeaders);
  for I := 2 to MAX_TEST_HEADERS - 1 do
    AssertTrue(Format('slot %d untouched after TooManyHeaders', [I]),
      CompareByte(FHeaders[I], Sentinel, SizeOf(Sentinel)) = 0);
  ParseReq('GET / HTTP/1.1'#13#10'A: 1'#13#10'B: 2', 4);
  CheckPartial;
  AssertEquals('NumHeaders on Partial', 1, FNumHeaders);
  CheckHeader(0, 'A', '1');
  for I := 1 to MAX_TEST_HEADERS - 1 do
    AssertTrue(Format('slot %d untouched after Partial', [I]),
      CompareByte(FHeaders[I], Sentinel, SizeOf(Sentinel)) = 0);
end;

procedure TTestParserExtra.Extra_large_head_offsets;
var
  Buf: RawByteString;
  N: Integer;
begin
  { 100000-byte header value. }
  Buf := 'GET / HTTP/1.1'#13#10'X: ' + StringOfChar('x', 100000) + #13#10'Y: z'#13#10#13#10;
  ParseReq(Buf);
  CheckComplete(Length(Buf));
  CheckHeaderCount(2);
  AssertEquals('value offset', 19, FHeaders[0].Value.Off);
  AssertEquals('value length', 100000, FHeaders[0].Value.Len);
  AssertEquals('second name offset', 100021, FHeaders[1].Name.Off);
  { 70000-byte request-target. }
  Buf := 'GET /' + StringOfChar('p', 69999) + ' HTTP/1.1'#13#10#13#10;
  ParseReq(Buf);
  CheckComplete(Length(Buf));
  AssertEquals('path length', 70000, FReq.Path.Len);
  { 50000 leading CRLFs. }
  SetLength(Buf, 100000);
  for N := 1 to 50000 do
  begin
    Buf[2 * N - 1] := #13;
    Buf[2 * N] := #10;
  end;
  Buf := Buf + 'GET / HTTP/1.1'#13#10#13#10;
  ParseReq(Buf);
  CheckComplete(Length(Buf));
  AssertEquals('method offset', 100000, FReq.Method.Off);
  { 100000-byte method token and header name. }
  Buf := StringOfChar('M', 100000) + ' / HTTP/1.1'#13#10 + StringOfChar('N', 100000) + ': v'#13#10#13#10;
  ParseReq(Buf);
  CheckComplete(Length(Buf));
  AssertEquals('method length', 100000, FReq.Method.Len);
  AssertEquals('name length', 100000, FHeaders[0].Name.Len);
end;

procedure TTestParserExtra.Extra_parse_headers_trailers;
begin
  ExpectHdrs(#13#10, 4, 'C 2 h=0');
  ExpectHdrs(#10, 4, 'C 1 h=0');
  ExpectHdrs('', 4, 'P');
  ExpectHdrs('A: b'#13#10, 4, 'P');
  AssertEquals('NumHeaders on Partial', 1, FNumHeaders);
  ExpectHdrs('A: b'#13#10#13#10'body', 4, 'C 8 h=1 0,1:3,1');
  ExpectHdrs('Expires: never'#13#10'X-Sum: abc'#13#10#13#10, 4, 'C 30 h=2 0,7:9,5 16,5:23,3');
  { Default config: no leading whitespace, no invalid lines, no obs-fold. }
  ExpectHdrs(' A: b'#13#10#13#10, 4, 'E HeaderName');
  ExpectHdrs('A b'#13#10#13#10, 4, 'E HeaderName');
  ExpectHdrs('A: b'#13#10' c'#13#10#13#10, 4, 'E HeaderName');
  ExpectHdrs('A: b'#1#13#10#13#10, 4, 'E HeaderValue');
  ExpectHdrs('A: b'#13#10#13'X', 4, 'E NewLine');
  ExpectHdrs(#13'X', 4, 'E NewLine');
  ExpectHdrs('A: 1'#13#10'B: 2'#13#10#13#10, 1, 'E TooManyHeaders');
end;

procedure TTestParserExtra.Extra_parse_header_block_offset;
var
  Buf: RawByteString;
  Pos: SizeInt;
  Hdrs: array[0..3] of THeaderSlice;
  N: Integer;
  R: TParseResult;
  HC: THeaderParserConfig;
begin
  HC := Default(THeaderParserConfig);
  Buf := 'xxxxxA: b'#13#10#13#10'rest';
  Pos := 5;
  R := ParseHeaderBlock(@Buf[1], Length(Buf), Pos, @Hdrs[0], 4, N, HC);
  AssertTrue('Complete', R.Status = psComplete);
  AssertEquals('Consumed counts from the start Pos', 8, R.Consumed);
  AssertEquals('Pos after the empty line', 13, Pos);
  AssertEquals('NumHeaders', 1, N);
  AssertEquals('name offset is absolute', 5, Hdrs[0].Name.Off);
  AssertEquals('value offset is absolute', 8, Hdrs[0].Value.Off);
  Pos := Length(Buf);
  R := ParseHeaderBlock(@Buf[1], Length(Buf), Pos, @Hdrs[0], 4, N, HC);
  AssertTrue('Pos = Len: Partial', R.Status = psPartial);
end;

procedure TTestParserExtra.Extra_request_reset_between_calls;
begin
  ParseReq('GET /x HTTP/1.1'#13#10'A: b'#13#10#13#10);
  CheckComplete(Length(FBuf));
  { Same Req record, new input: no field may survive from the last call. }
  FBuf := 'G';
  FRes := ParseRequest(BufPtr, Length(FBuf), FReq, @FHeaders[0], NUM_OF_HEADERS);
  FNumHeaders := FReq.NumHeaders;
  AssertEquals('P m=- p=- v=-', ReqLine);
  AssertEquals('NumHeaders reset', 0, FReq.NumHeaders);
  AssertEquals('Method.Len reset', 0, FReq.Method.Len);
  AssertEquals('Path.Len reset', 0, FReq.Path.Len);
  AssertEquals('Version reset', 0, FReq.Version);
end;

procedure TTestParserExtra.Extra_hyper_token_error_mapping;
begin
  { hyper role.rs: Token with method None -> Parse::Method, else Parse::Uri. }
  ExpectReq(' / HTTP/1.1'#13#10#13#10, 0, 4, 'E Token m=- p=- v=-');
  ExpectReq('GET '#$7F' HTTP/1.1'#13#10#13#10, 0, 4, 'E Token m=0,3 p=- v=-');
  ExpectReq('GET  / HTTP/1.1'#13#10#13#10, 0, 4, 'E Token m=0,3 p=- v=-');
  { Header errors come after a complete request line. }
  ExpectReq('GET / HTTP/1.1'#13#10'A'#1': b'#13#10#13#10, 0, 4, 'E HeaderName m=0,3 p=4,1 v=1');
end;

procedure TTestParserExtra.Extra_scanners_stop_at_len;
var
  S: RawByteString;
begin
  S := 'aaaaaaaa';
  AssertEquals('ScanToken Len=3', 3, ScanToken(@S[1], 3));
  AssertEquals('ScanUri Len=3', 3, ScanUri(@S[1], 3));
  AssertEquals('ScanHeaderName Len=3', 3, ScanHeaderName(@S[1], 3));
  AssertEquals('ScanHeaderValue Len=3', 3, ScanHeaderValue(@S[1], 3));
  AssertEquals('ScanToken nil', 0, ScanToken(nil, 0));
  AssertEquals('ScanUri nil', 0, ScanUri(nil, 0));
  AssertEquals('ScanHeaderName nil', 0, ScanHeaderName(nil, 0));
  AssertEquals('ScanHeaderValue nil', 0, ScanHeaderValue(nil, 0));
  S := #9' a'#13;
  AssertEquals('ScanHeaderValue takes HTAB and SP', 3, ScanHeaderValue(@S[1], 4));
  AssertEquals('ScanUri stops at HTAB', 0, ScanUri(@S[1], 4));
  S := #$C3#$A9;
  AssertFalse('IsValidUtf8 does not read past Len', IsValidUtf8(@S[1], 1));
  AssertTrue('IsValidUtf8 empty', IsValidUtf8(nil, 0));
end;

procedure TTestParserExtra.Extra_utf8_validation;

  procedure V(const S: RawByteString; Expected: Boolean);
  var
    P: PByte;
  begin
    if S = '' then P := nil else P := @S[1];
    AssertEquals('IsValidUtf8("' + Printable(S) + '")', Expected, IsValidUtf8(P, Length(S)));
  end;

begin
  { Valid: mixed widths and the boundaries of each range. }
  V('a'#$C3#$A9'b'#$E2#$82#$AC'c'#$F0#$9F#$98#$80, True);
  V(#$C2#$80, True);
  V(#$DF#$BF, True);
  V(#$E0#$A0#$80, True);
  V(#$ED#$9F#$BF, True);
  V(#$EE#$80#$80, True);
  V(#$EF#$BF#$BF, True);
  V(#$F0#$90#$80#$80, True);
  V(#$F4#$8F#$BF#$BF, True);
  { Invalid: overlong, surrogates, above U+10FFFF, stray or missing
    continuation bytes. }
  V(#$C0#$80, False);
  V(#$C1#$BF, False);
  V(#$E0#$9F#$BF, False);
  V(#$ED#$A0#$80, False);
  V(#$ED#$BF#$BF, False);
  V(#$F0#$8F#$BF#$BF, False);
  V(#$F4#$90#$80#$80, False);
  V(#$F5#$80#$80#$80, False);
  V(#$FF, False);
  V(#$80, False);
  V(#$C3, False);
  V(#$E2#$82, False);
  V(#$F0#$9F#$98, False);
  V('a'#$C3'a', False);
  V(#$E2#$82'a', False);
end;

initialization
  RegisterTest(TTestParserExtra);
end.

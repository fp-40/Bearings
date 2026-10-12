{ Shared fixture for the httparse ports (test_parser_*.pas).
  Mirrors the req! macro of httparse src/lib.rs and tests/uri.rs:
  a Request with NUM_OF_HEADERS = 4 header slots, parsed from a byte
  string, then checked field by field. }
unit test_parser_base;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, fpcunit, bearings.http1.parser;

const
  NUM_OF_HEADERS = 4;
  MAX_TEST_HEADERS = 16;

type
  TParserTestCase = class(TTestCase)
  protected
    FBuf: RawByteString;
    FReq: TParsedRequest;
    FHeaders: array[0..MAX_TEST_HEADERS - 1] of THeaderSlice;
    FRes: TParseResult;
    FNumHeaders: Integer;
    function BufPtr: PByte;
    function SliceStr(const S: TSlice): RawByteString;
    function ResultStr(const R: TParseResult): string;
    { Request::parse / ParserConfig::parse_request with NumSlots header slots. }
    procedure ParseReq(const Buf: RawByteString; NumSlots: Integer;
      const Config: TParserConfig); overload;
    procedure ParseReq(const Buf: RawByteString; NumSlots: Integer = NUM_OF_HEADERS); overload;
    { httparse::parse_headers }
    procedure ParseHdrs(const Buf: RawByteString; NumSlots: Integer);
    procedure CheckComplete(Expected: SizeInt);
    procedure CheckPartial;
    procedure CheckError(E: THttpParseError);
    procedure CheckMethod(const Expected: RawByteString);
    procedure CheckPath(const Expected: RawByteString);
    procedure CheckVersion(Expected: Byte);
    procedure CheckHeaderCount(Expected: Integer);
    procedure CheckHeader(Index: Integer; const Name, Value: RawByteString);
  end;

function Printable(const S: RawByteString): string;
function SameBytes(const A, B: RawByteString): Boolean;

implementation

function Printable(const S: RawByteString): string;
var
  I: Integer;
  C: Byte;
begin
  Result := '';
  for I := 1 to Length(S) do
  begin
    C := Byte(S[I]);
    if (C >= $20) and (C < $7F) and (C <> Ord('\')) then
      Result := Result + Chr(C)
    else
      Result := Result + '\x' + IntToHex(C, 2);
  end;
end;

function SameBytes(const A, B: RawByteString): Boolean;
begin
  Result := (Length(A) = Length(B)) and
    ((Length(A) = 0) or (CompareByte(A[1], B[1], Length(A)) = 0));
end;

function TParserTestCase.BufPtr: PByte;
begin
  if FBuf = '' then
    Result := nil
  else
    Result := PByte(@FBuf[1]);
end;

function TParserTestCase.SliceStr(const S: TSlice): RawByteString;
begin
  Result := '';
  if S.Len > 0 then
  begin
    AssertTrue('slice inside buffer', (S.Off >= 0) and (S.Off + S.Len <= Length(FBuf)));
    SetLength(Result, S.Len);
    Move(FBuf[S.Off + 1], Result[1], S.Len);
  end;
end;

function TParserTestCase.ResultStr(const R: TParseResult): string;
begin
  case R.Status of
    psComplete: Result := Format('Ok(Complete(%d))', [R.Consumed]);
    psPartial: Result := 'Ok(Partial)';
  else
    Result := 'Err(' + ParseErrorDescription(R.Error) + ')';
  end;
end;

procedure TParserTestCase.ParseReq(const Buf: RawByteString; NumSlots: Integer;
  const Config: TParserConfig);
begin
  AssertTrue('test slot count', NumSlots <= MAX_TEST_HEADERS);
  FBuf := Buf;
  FillChar(FHeaders, SizeOf(FHeaders), $FF);
  FRes := ParseRequest(BufPtr, Length(FBuf), FReq, @FHeaders[0], NumSlots, Config);
  FNumHeaders := FReq.NumHeaders;
end;

procedure TParserTestCase.ParseReq(const Buf: RawByteString; NumSlots: Integer);
begin
  ParseReq(Buf, NumSlots, DefaultParserConfig);
end;

procedure TParserTestCase.ParseHdrs(const Buf: RawByteString; NumSlots: Integer);
begin
  AssertTrue('test slot count', NumSlots <= MAX_TEST_HEADERS);
  FBuf := Buf;
  FillChar(FHeaders, SizeOf(FHeaders), $FF);
  FRes := ParseHeaders(BufPtr, Length(FBuf), @FHeaders[0], NumSlots, FNumHeaders);
end;

procedure TParserTestCase.CheckComplete(Expected: SizeInt);
begin
  AssertEquals('result for "' + Printable(FBuf) + '"',
    Format('Ok(Complete(%d))', [Expected]), ResultStr(FRes));
end;

procedure TParserTestCase.CheckPartial;
begin
  AssertEquals('result for "' + Printable(FBuf) + '"', 'Ok(Partial)', ResultStr(FRes));
end;

procedure TParserTestCase.CheckError(E: THttpParseError);
var
  R: TParseResult;
begin
  R.Status := psError;
  R.Error := E;
  R.Consumed := 0;
  AssertEquals('result for "' + Printable(FBuf) + '"', ResultStr(R), ResultStr(FRes));
  AssertTrue('error kind', FRes.Error = E);
end;

procedure TParserTestCase.CheckMethod(const Expected: RawByteString);
begin
  AssertTrue('method is Some', FReq.HasMethod);
  AssertEquals('method', Printable(Expected), Printable(SliceStr(FReq.Method)));
  AssertTrue('method bytes', SameBytes(Expected, SliceStr(FReq.Method)));
end;

procedure TParserTestCase.CheckPath(const Expected: RawByteString);
begin
  AssertTrue('path is Some', FReq.HasPath);
  AssertEquals('path', Printable(Expected), Printable(SliceStr(FReq.Path)));
  AssertTrue('path bytes', SameBytes(Expected, SliceStr(FReq.Path)));
end;

procedure TParserTestCase.CheckVersion(Expected: Byte);
begin
  AssertTrue('version is Some', FReq.HasVersion);
  AssertEquals('version', Expected, FReq.Version);
end;

procedure TParserTestCase.CheckHeaderCount(Expected: Integer);
begin
  AssertEquals('headers.len()', Expected, FNumHeaders);
end;

procedure TParserTestCase.CheckHeader(Index: Integer; const Name, Value: RawByteString);
begin
  AssertTrue('header index in range', Index < FNumHeaders);
  AssertEquals(Format('headers[%d].name', [Index]), Printable(Name),
    Printable(SliceStr(FHeaders[Index].Name)));
  AssertEquals(Format('headers[%d].value', [Index]), Printable(Value),
    Printable(SliceStr(FHeaders[Index].Value)));
  AssertTrue('header value bytes', SameBytes(Value, SliceStr(FHeaders[Index].Value)));
end;

end.

{ The byte-class scanners of bearings.http1.parser: each must stop exactly
  at the first byte outside its class, probed with a run of '_' and the
  byte under test at index 10 of 16, or 26 of 32 (the widths of a NEON or
  SSE4.2 block and of an AVX2 block). First written as ports of the
  backend tests of httparse v1.10.1 src/simd/.

  bearings.http1.parser has only scalar scanners today, so these tests run the
  scalar ScanUri / ScanHeaderValue / ScanHeaderName.  They are the
  acceptance tests for a future SSE4.2/AVX2 replacement.  Each byte class
  is also compared with its definition written out in the test. }
unit test_parser_simd;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, fpcunit, testregistry, bearings.http1.parser;

type
  TScanFunc = function(P: PByte; Len: SizeInt): SizeInt;
  TClassFunc = function(B: Byte): Boolean;

  TTestParserByteClasses = class(TTestCase)
  private
    function ByteIsAllowed(B: Byte; F: TScanFunc; Width, At: Integer): Boolean;
    procedure CheckTable(F: TScanFunc; Spec: TClassFunc; Width, At: Integer;
      const What: string);
  published
    procedure Test_sse_code_matches_uri_chars_table;
    procedure Test_sse_code_matches_header_value_chars_table;
    procedure Test_avx2_code_matches_uri_chars_table;
    procedure Test_avx2_code_matches_header_value_chars_table;
    procedure Test_neon_code_matches_uri_chars_table;
    procedure Test_neon_code_matches_header_value_chars_table;
    procedure Test_neon_code_matches_header_name_chars_table;
    procedure Test_is_uri_block;
  end;

implementation

{ The byte classes (request-target, field value, token), spelled out
  independently of bearings.http1.parser. }
function SpecUri(B: Byte): Boolean;
begin
  Result := ((B >= $21) and (B <= $7E)) or (B >= $80);
end;

function SpecHeaderValue(B: Byte): Boolean;
begin
  Result := (B = 9) or ((B >= $20) and (B <= $7E)) or (B >= $80);
end;

function SpecToken(B: Byte): Boolean;
begin
  Result := (Chr(B) in ['A'..'Z', 'a'..'z', '0'..'9']) or
    (Pos(Chr(B), '!#$%&''*+-.^_`|~') > 0);
end;

function TTestParserByteClasses.ByteIsAllowed(B: Byte; F: TScanFunc;
  Width, At: Integer): Boolean;
var
  Slice: array[0..31] of Byte;
  N: SizeInt;
begin
  FillChar(Slice, SizeOf(Slice), Ord('_'));
  Slice[At] := B;
  N := F(@Slice[0], Width);
  if N = Width then
    Result := True
  else if N = At then
    Result := False
  else
  begin
    Fail(Format('unexpected pos: %d', [N]));
    Result := False;
  end;
end;

procedure TTestParserByteClasses.CheckTable(F: TScanFunc; Spec: TClassFunc;
  Width, At: Integer; const What: string);
var
  B: Integer;
begin
  AssertTrue('byte_is_allowed(''_'')', ByteIsAllowed(Ord('_'), F, Width, At));
  for B := 0 to 255 do
    AssertEquals(Format('byte_is_allowed(%d) should be %s (%s)',
      [B, BoolToStr(Spec(B), True), What]), Spec(B),
      ByteIsAllowed(B, F, Width, At));
end;

procedure TTestParserByteClasses.Test_sse_code_matches_uri_chars_table;
var
  B: Integer;
begin
  for B := 0 to 255 do
    AssertEquals(Format('IsUriChar(%d)', [B]), SpecUri(B), IsUriChar(B));
  CheckTable(@ScanUri, @SpecUri, 16, 10, 'request-target bytes');
end;

procedure TTestParserByteClasses.Test_sse_code_matches_header_value_chars_table;
var
  B: Integer;
begin
  for B := 0 to 255 do
    AssertEquals(Format('IsHeaderValueChar(%d)', [B]), SpecHeaderValue(B),
      IsHeaderValueChar(B));
  CheckTable(@ScanHeaderValue, @SpecHeaderValue, 16, 10, 'field-value bytes');
end;

procedure TTestParserByteClasses.Test_avx2_code_matches_uri_chars_table;
begin
  CheckTable(@ScanUri, @SpecUri, 32, 26, 'request-target bytes');
end;

procedure TTestParserByteClasses.Test_avx2_code_matches_header_value_chars_table;
begin
  CheckTable(@ScanHeaderValue, @SpecHeaderValue, 32, 26, 'field-value bytes');
end;

procedure TTestParserByteClasses.Test_neon_code_matches_uri_chars_table;
begin
  CheckTable(@ScanUri, @SpecUri, 16, 10, 'request-target bytes');
end;

procedure TTestParserByteClasses.Test_neon_code_matches_header_value_chars_table;
begin
  CheckTable(@ScanHeaderValue, @SpecHeaderValue, 16, 10, 'field-value bytes');
end;

procedure TTestParserByteClasses.Test_neon_code_matches_header_name_chars_table;
var
  B: Integer;
begin
  for B := 0 to 255 do
    AssertEquals(Format('IsTokenChar(%d)', [B]), SpecToken(B), IsTokenChar(B));
  CheckTable(@ScanHeaderName, @SpecToken, 16, 10, 'token bytes');
  CheckTable(@ScanToken, @SpecToken, 16, 10, 'token bytes (ScanToken)');
end;

{ A block of 8 equal bytes is fully accepted as request-target bytes
  exactly for 33..126 and 128..255. }
procedure TTestParserByteClasses.Test_is_uri_block;
var
  Block: array[0..7] of Byte;
  B: Integer;
begin
  for B := 0 to 255 do
  begin
    FillChar(Block, SizeOf(Block), B);
    AssertEquals(Format('b=%d', [B]), ((B >= 33) and (B <= 126)) or (B >= 128),
      ScanUri(@Block[0], 8) = 8);
  end;
end;

initialization
  RegisterTest(TTestParserByteClasses);
end.

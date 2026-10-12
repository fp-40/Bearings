{ Ports of the 17 tests in hyper v1.12.0 src/proto/h1/decode.rs.
  Test methods named Test_<hyper name> are ports; Test_wd_<name> are extra
  tests of this port's own API. }
unit test_codec_decode;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  bearings.http.headers, bearings.http1.decode;

type
  TTestDecoder = class(TTestCase)
  private
    procedure CheckReadSize(const S: RawByteString; Expected: QWord);
    procedure CheckReadErr(const S: RawByteString; Expected: TIoErrorKind);
    function ReadAsync(const ADecoder: TDecoder; const Content: RawByteString; BlockAt: SizeInt): RawByteString;
    procedure AllAsyncCases(const Content, Expected: RawByteString; const ADecoder: TDecoder);
  published
    procedure Test_read_chunk_size;
    procedure Test_read_sized_early_eof;
    procedure Test_read_chunked_early_eof;
    procedure Test_read_chunked_single_read;
    procedure Test_read_chunked_with_missing_zero_digit;
    procedure Test_read_chunked_extensions_over_limit;
    procedure Test_read_chunked_trailer_with_missing_lf;
    procedure Test_read_chunked_after_eof;
    procedure Test_read_length_async;
    procedure Test_read_chunked_async;
    procedure Test_read_eof_async;
    procedure Test_decode_trailers;
    procedure Test_decode_trailers_preserves_duplicate_values;
    procedure Test_trailer_max_headers_enforced;
    procedure Test_trailer_max_headers_allows_exact_limit;
    procedure Test_trailer_max_header_size_huge_trailer;
    procedure Test_trailer_max_header_size_many_small_trailers;
    { extra (not hyper) }
    procedure Test_wd_chunked_byte_at_a_time_with_trailers;
    procedure Test_wd_data_slice_is_zero_copy;
    procedure Test_wd_error_is_sticky;
  end;

{ hyper decode_fut over a &[u8] / Bytes reader: every byte is available and
  EOF follows. Decodes once, returns the data copy, removes consumed bytes. }
function DecodeFut(var D: TDecoder; var Buf: RawByteString; Trailers: THttpHeaders;
  out Data: RawByteString; out R: TDecodeResult): TDecodeStatus;

implementation

function DecodeFut(var D: TDecoder; var Buf: RawByteString; Trailers: THttpHeaders;
  out Data: RawByteString; out R: TDecodeResult): TDecodeStatus;
begin
  Result := D.Decode(PByte(Pointer(Buf)), Length(Buf), True, Trailers, R);
  Data := '';
  if Result = dsData then
    Data := Copy(Buf, R.DataOfs + 1, R.DataLen);
  Delete(Buf, 1, R.Consumed);
end;

function KindName(K: TIoErrorKind): string;
begin
  case K of
    iekNone: Result := 'None';
    iekUnexpectedEof: Result := 'UnexpectedEof';
    iekInvalidInput: Result := 'InvalidInput';
    iekInvalidData: Result := 'InvalidData';
  end;
end;

function Rep(const S: RawByteString; N: SizeInt): RawByteString;
var
  I: SizeInt;
begin
  Result := '';
  for I := 1 to N do
    Result := Result + S;
end;

{ ---- test_read_chunk_size helpers ---- }

procedure TTestDecoder.CheckReadSize(const S: RawByteString; Expected: QWord);
var
  D: TDecoder;
  R: TDecodeResult;
  St: TDecodeStatus;
begin
  D.InitChunked;
  { hyper's read() steps until the state is Body or EndCr. Our decoder stops
    there with dsNeedMore because no body byte follows the size line. }
  St := D.Decode(PByte(Pointer(S)), Length(S), False, R);
  AssertTrue(Format('read_size failed for %s: status %d error %s',
    [S, Ord(St), DecodeErrorMessage(R.Error)]), St = dsNeedMore);
  AssertTrue('state must be Body or EndCr for ' + S, D.State in [csBody, csEndCr]);
  AssertEquals('consumed all of ' + S, Length(S), R.Consumed);
  AssertEquals('size for ' + S, Expected, D.Remaining);
end;

procedure TTestDecoder.CheckReadErr(const S: RawByteString; Expected: TIoErrorKind);
var
  D: TDecoder;
  R: TDecodeResult;
  St: TDecodeStatus;
begin
  D.InitChunked;
  St := D.Decode(PByte(Pointer(S)), Length(S), False, R);
  if St <> dsError then
  begin
    if D.State in [csBody, csEnd] then
      Fail('Was Ok. Expected Err for ' + S);
    AssertTrue('expected NeedMore before EOF for ' + S, St = dsNeedMore);
    { the &[u8] reader is exhausted: next read is EOF }
    St := D.Decode(nil, 0, True, R);
  end;
  AssertTrue('expected an error for ' + S, St = dsError);
  AssertEquals(Format('Reading %s, expected %s, but got %s',
    [S, KindName(Expected), KindName(DecodeErrorKind(R.Error))]),
    Ord(Expected), Ord(DecodeErrorKind(R.Error)));
end;

procedure TTestDecoder.Test_read_chunk_size;
begin
  CheckReadSize('1'#13#10, 1);
  CheckReadSize('01'#13#10, 1);
  CheckReadSize('0'#13#10, 0);
  CheckReadSize('00'#13#10, 0);
  CheckReadSize('A'#13#10, 10);
  CheckReadSize('a'#13#10, 10);
  CheckReadSize('Ff'#13#10, 255);
  CheckReadSize('Ff   '#13#10, 255);
  // Missing LF or CRLF
  CheckReadErr('F'#13'F', iekInvalidInput);
  CheckReadErr('F', iekUnexpectedEof);
  // Missing digit
  CheckReadErr(#13#10#13#10, iekInvalidInput);
  CheckReadErr(#13#10, iekInvalidInput);
  // Invalid hex digit
  CheckReadErr('X'#13#10, iekInvalidInput);
  CheckReadErr('1X'#13#10, iekInvalidInput);
  CheckReadErr('-'#13#10, iekInvalidInput);
  CheckReadErr('-1'#13#10, iekInvalidInput);
  // Acceptable (if not fully valid) extensions do not influence the size
  CheckReadSize('1;extension'#13#10, 1);
  CheckReadSize('a;ext name=value'#13#10, 10);
  CheckReadSize('1;extension;extension2'#13#10, 1);
  CheckReadSize('1;;;  ;'#13#10, 1);
  CheckReadSize('2; extension...'#13#10, 2);
  CheckReadSize('3   ; extension=123'#13#10, 3);
  CheckReadSize('3   ;'#13#10, 3);
  CheckReadSize('3   ;   '#13#10, 3);
  // Invalid extensions cause an error
  CheckReadErr('1 invalid extension'#13#10, iekInvalidInput);
  CheckReadErr('1 A'#13#10, iekInvalidInput);
  CheckReadErr('1;no CRLF', iekUnexpectedEof);
  CheckReadErr('1;reject'#10'newlines'#13#10, iekInvalidData);
  // Overflow
  CheckReadErr('f0000000000000003'#13#10, iekInvalidData);
end;

procedure TTestDecoder.Test_read_sized_early_eof;
var
  D: TDecoder;
  Buf, Data: RawByteString;
  R: TDecodeResult;
begin
  Buf := 'foo bar';
  D.InitLength(10);
  AssertTrue(DecodeFut(D, Buf, nil, Data, R) = dsData);
  AssertEquals(7, Length(Data));
  AssertTrue(DecodeFut(D, Buf, nil, Data, R) = dsError);
  AssertEquals(Ord(iekUnexpectedEof), Ord(DecodeErrorKind(R.Error)));
  AssertEquals('end of file before message length reached', DecodeErrorMessage(R.Error));
end;

procedure TTestDecoder.Test_read_chunked_early_eof;
var
  D: TDecoder;
  Buf, Data: RawByteString;
  R: TDecodeResult;
begin
  Buf := '9'#13#10'foo bar';
  D.InitChunked;
  AssertTrue(DecodeFut(D, Buf, nil, Data, R) = dsData);
  AssertEquals(7, Length(Data));
  AssertTrue(DecodeFut(D, Buf, nil, Data, R) = dsError);
  AssertEquals(Ord(iekUnexpectedEof), Ord(DecodeErrorKind(R.Error)));
end;

procedure TTestDecoder.Test_read_chunked_single_read;
var
  D: TDecoder;
  Buf, Data: RawByteString;
  R: TDecodeResult;
begin
  Buf := '10'#13#10'1234567890abcdef'#13#10'0'#13#10;
  D.InitChunked;
  AssertTrue('decode', DecodeFut(D, Buf, nil, Data, R) = dsData);
  AssertEquals(16, Length(Data));
  AssertEquals('1234567890abcdef', Data);
end;

procedure TTestDecoder.Test_read_chunked_with_missing_zero_digit;
var
  D: TDecoder;
  Buf, Data: RawByteString;
  R: TDecodeResult;
begin
  Buf := '1'#13#10'Z'#13#10#13#10#13#10;
  D.InitChunked;
  AssertTrue('decode', DecodeFut(D, Buf, nil, Data, R) = dsData);
  AssertEquals('Z', Data);
  AssertTrue('decode 2', DecodeFut(D, Buf, nil, Data, R) = dsError);
  AssertEquals(Ord(iekInvalidInput), Ord(DecodeErrorKind(R.Error)));
end;

procedure TTestDecoder.Test_read_chunked_extensions_over_limit;
var
  D: TDecoder;
  Buf, Data, Scratch: RawByteString;
  R: TDecodeResult;
  PerChunk, I: Integer;
begin
  // construct a chunked body where each individual chunked extension
  // is totally fine, but combined is over the limit.
  PerChunk := CHUNKED_EXTENSIONS_LIMIT * 2 div 3;
  Scratch := '';
  for I := 0 to 1 do
    Scratch := Scratch + '1;' + StringOfChar('x', PerChunk) + #13#10'A'#13#10;
  Scratch := Scratch + '0'#13#10#13#10;
  Buf := Scratch;

  D.InitChunked;
  AssertTrue('decode1', DecodeFut(D, Buf, nil, Data, R) = dsData);
  AssertEquals('A', Data);
  AssertTrue('decode2', DecodeFut(D, Buf, nil, Data, R) = dsError);
  AssertEquals(Ord(iekInvalidData), Ord(DecodeErrorKind(R.Error)));
  AssertEquals('chunk extensions over limit', DecodeErrorMessage(R.Error));
end;

procedure TTestDecoder.Test_read_chunked_trailer_with_missing_lf;
var
  D: TDecoder;
  Buf, Data: RawByteString;
  R: TDecodeResult;
begin
  Buf := '10'#13#10'1234567890abcdef'#13#10'0'#13#10'bad'#13#13#10;
  D.InitChunked;
  AssertTrue('decode', DecodeFut(D, Buf, nil, Data, R) = dsData);
  AssertTrue(DecodeFut(D, Buf, nil, Data, R) = dsError);
  AssertEquals(Ord(iekInvalidInput), Ord(DecodeErrorKind(R.Error)));
end;

procedure TTestDecoder.Test_read_chunked_after_eof;
var
  D: TDecoder;
  Buf, Data: RawByteString;
  R: TDecodeResult;
begin
  Buf := '10'#13#10'1234567890abcdef'#13#10'0'#13#10#13#10;
  D.InitChunked;
  // normal read
  AssertTrue(DecodeFut(D, Buf, nil, Data, R) = dsData);
  AssertEquals(16, Length(Data));
  AssertEquals('1234567890abcdef', Data);
  // eof read
  AssertTrue('decode', DecodeFut(D, Buf, nil, Data, R) = dsEnd);
  AssertEquals(0, Length(Data));
  // ensure read after eof also returns eof
  AssertTrue('decode', DecodeFut(D, Buf, nil, Data, R) = dsEnd);
  AssertEquals(0, Length(Data));
end;

{ hyper read_async: the mock transport delivers Content[..BlockAt], then is
  Pending, then delivers Content[BlockAt..], then EOF (BlockAt = 0: Pending
  first, then everything). The caller keeps unconsumed bytes buffered. }
function TTestDecoder.ReadAsync(const ADecoder: TDecoder; const Content: RawByteString;
  BlockAt: SizeInt): RawByteString;
var
  D: TDecoder;
  Segs: array of RawByteString;
  NextSeg: Integer;
  Buf: RawByteString;
  R: TDecodeResult;
  St: TDecodeStatus;
  Guard: Integer;
begin
  D := ADecoder;
  if BlockAt = 0 then
  begin
    SetLength(Segs, 2);
    Segs[0] := '';
    Segs[1] := Content;
  end
  else
  begin
    SetLength(Segs, 2);
    Segs[0] := Copy(Content, 1, BlockAt);
    Segs[1] := Copy(Content, BlockAt + 1, MaxInt);
  end;
  NextSeg := 0;
  Buf := '';
  Result := '';
  Guard := 0;
  while True do
  begin
    Inc(Guard);
    if Guard > 10000 then
      Fail('decoder made no progress');
    St := D.Decode(PByte(Pointer(Buf)), Length(Buf), NextSeg >= Length(Segs), R);
    case St of
      dsData:
        begin
          Result := Result + Copy(Buf, R.DataOfs + 1, R.DataLen);
          Delete(Buf, 1, R.Consumed);
        end;
      dsNeedMore:
        begin
          AssertEquals('NeedMore consumes everything', Length(Buf), R.Consumed);
          Buf := '';
          if NextSeg < Length(Segs) then
          begin
            Buf := Segs[NextSeg];
            Inc(NextSeg);
          end;
        end;
      dsEnd, dsTrailers:
        Break; // eof
      dsError:
        Fail('unexpected decode error: ' + DecodeErrorMessage(R.Error));
    end;
  end;
end;

procedure TTestDecoder.AllAsyncCases(const Content, Expected: RawByteString; const ADecoder: TDecoder);
var
  BlockAt: SizeInt;
begin
  for BlockAt := 0 to Length(Content) - 1 do
    AssertEquals(Format('Failed async. Blocking at %d', [BlockAt]),
      Expected, ReadAsync(ADecoder, Content, BlockAt));
end;

procedure TTestDecoder.Test_read_length_async;
var
  D: TDecoder;
begin
  D.InitLength(Length('foobar'));
  AllAsyncCases('foobar', 'foobar', D);
end;

procedure TTestDecoder.Test_read_chunked_async;
var
  D: TDecoder;
begin
  D.InitChunked;
  AllAsyncCases('3'#13#10'foo'#13#10'3'#13#10'bar'#13#10'0'#13#10#13#10, 'foobar', D);
end;

procedure TTestDecoder.Test_read_eof_async;
var
  D: TDecoder;
begin
  D.InitEof;
  AllAsyncCases('foobar', 'foobar', D);
end;

procedure TTestDecoder.Test_decode_trailers;
var
  H: THttpHeaders;
  Buf: RawByteString;
  Err: TDecodeError;
begin
  H := THttpHeaders.Create;
  try
    Buf := 'Expires: Wed, 21 Oct 2015 07:28:00 GMT'#13#10'X-Stream-Error: failed to decode'#13#10#13#10;
    AssertTrue('decode_trailers', ParseTrailers(PByte(Pointer(Buf)), Length(Buf), 2, H, Err));
    AssertEquals(2, H.Count);
    AssertEquals('Wed, 21 Oct 2015 07:28:00 GMT', H.GetValue('Expires'));
    AssertEquals('failed to decode', H.GetValue('X-Stream-Error'));
  finally
    H.Free;
  end;
end;

procedure TTestDecoder.Test_decode_trailers_preserves_duplicate_values;
var
  H: THttpHeaders;
  Buf, Values: RawByteString;
  Err: TDecodeError;
  I: SizeInt;
begin
  H := THttpHeaders.Create;
  try
    Buf := 'X-Trace: first'#13#10'X-Trace: second'#13#10#13#10;
    AssertTrue('decode_trailers', ParseTrailers(PByte(Pointer(Buf)), Length(Buf), 2, H, Err));
    Values := '';
    I := H.IndexOf('X-Trace');
    while I >= 0 do
    begin
      Values := Values + '[' + H.Value(I) + ']';
      I := H.IndexOf('X-Trace', I + 1);
    end;
    AssertEquals('[first][second]', Values);
  finally
    H.Free;
  end;
end;

procedure TTestDecoder.Test_trailer_max_headers_enforced;
const
  H1_MAX_HEADERS = 10;
var
  D: TDecoder;
  Buf, Data: RawByteString;
  R: TDecodeResult;
  I: Integer;
  T: THttpHeaders;
begin
  Buf := '10'#13#10'1234567890abcdef'#13#10'0'#13#10;
  for I := 0 to H1_MAX_HEADERS do
    Buf := Buf + Format('trailer%d: %d', [I, I]) + #13#10;
  Buf := Buf + #13#10;
  T := THttpHeaders.Create;
  try
    D.InitChunked(H1_MAX_HEADERS, -1);
    // ready chunked body
    AssertTrue(DecodeFut(D, Buf, T, Data, R) = dsData);
    AssertEquals(16, Length(Data));
    // eof read
    AssertTrue('trailer fields over limit', DecodeFut(D, Buf, T, Data, R) = dsError);
    AssertEquals(Ord(iekInvalidData), Ord(DecodeErrorKind(R.Error)));
    AssertEquals('chunk trailers count overflow', DecodeErrorMessage(R.Error));
  finally
    T.Free;
  end;
end;

procedure TTestDecoder.Test_trailer_max_headers_allows_exact_limit;
const
  H1_MAX_HEADERS = 10;
var
  D: TDecoder;
  Buf, Data: RawByteString;
  R: TDecodeResult;
  I: Integer;
  T: THttpHeaders;
begin
  Buf := '10'#13#10'1234567890abcdef'#13#10'0'#13#10;
  for I := 0 to H1_MAX_HEADERS - 1 do
    Buf := Buf + Format('trailer%d: %d', [I, I]) + #13#10;
  Buf := Buf + #13#10;
  T := THttpHeaders.Create;
  try
    D.InitChunked(H1_MAX_HEADERS, -1);
    AssertTrue(DecodeFut(D, Buf, T, Data, R) = dsData);
    AssertEquals(16, Length(Data));
    AssertTrue('trailers at limit', DecodeFut(D, Buf, T, Data, R) = dsTrailers);
    AssertEquals(H1_MAX_HEADERS, T.Count);
  finally
    T.Free;
  end;
end;

procedure TTestDecoder.Test_trailer_max_header_size_huge_trailer;
const
  MAX_HEADER_SIZE = 1024;
var
  D: TDecoder;
  Buf, Data: RawByteString;
  R: TDecodeResult;
begin
  Buf := '10'#13#10'1234567890abcdef'#13#10'0'#13#10;
  Buf := Buf + 'huge_trailer: ' + StringOfChar('x', MAX_HEADER_SIZE) + #13#10;
  Buf := Buf + #13#10;
  D.InitChunked(-1, MAX_HEADER_SIZE);
  // ready chunked body
  AssertTrue(DecodeFut(D, Buf, nil, Data, R) = dsData);
  AssertEquals(16, Length(Data));
  // eof read
  AssertTrue('trailers over limit', DecodeFut(D, Buf, nil, Data, R) = dsError);
  AssertEquals(Ord(iekInvalidData), Ord(DecodeErrorKind(R.Error)));
  AssertEquals('chunk trailers bytes over limit', DecodeErrorMessage(R.Error));
end;

procedure TTestDecoder.Test_trailer_max_header_size_many_small_trailers;
const
  MAX_HEADERS = 10;
  HEADER_SIZE = 64;
var
  D: TDecoder;
  Buf, Data: RawByteString;
  R: TDecodeResult;
  I: Integer;
begin
  Buf := '10'#13#10'1234567890abcdef'#13#10'0'#13#10;
  for I := 0 to MAX_HEADERS - 1 do
    Buf := Buf + Format('trailer%d: ', [I]) + StringOfChar('x', HEADER_SIZE) + #13#10;
  Buf := Buf + #13#10;
  D.InitChunked(-1, MAX_HEADERS * HEADER_SIZE);
  // ready chunked body
  AssertTrue(DecodeFut(D, Buf, nil, Data, R) = dsData);
  AssertEquals(16, Length(Data));
  // eof read
  AssertTrue('trailers over limit', DecodeFut(D, Buf, nil, Data, R) = dsError);
  AssertEquals(Ord(iekInvalidData), Ord(DecodeErrorKind(R.Error)));
end;

{ ---- extra ---- }

procedure TTestDecoder.Test_wd_chunked_byte_at_a_time_with_trailers;
const
  CONTENT: RawByteString = '3;ext=1'#13#10'foo'#13#10'A'#13#10'0123456789'#13#10 +
    '0'#13#10'Expires: never'#13#10'X-A: b'#13#10#13#10;
var
  D: TDecoder;
  T: THttpHeaders;
  Buf, Body: RawByteString;
  R: TDecodeResult;
  St: TDecodeStatus;
  I: SizeInt;
  GotTrailers: Boolean;
begin
  T := THttpHeaders.Create;
  try
    D.InitChunked;
    Body := '';
    Buf := '';
    I := 1;
    GotTrailers := False;
    while True do
    begin
      St := D.Decode(PByte(Pointer(Buf)), Length(Buf), I > Length(CONTENT), T, R);
      case St of
        dsData:
          begin
            Body := Body + Copy(Buf, R.DataOfs + 1, R.DataLen);
            Delete(Buf, 1, R.Consumed);
          end;
        dsNeedMore:
          begin
            Buf := '';
            AssertTrue('ran out of input', I <= Length(CONTENT));
            Buf := CONTENT[I];
            Inc(I);
          end;
        dsTrailers:
          GotTrailers := True;
        dsEnd:
          Break;
        dsError:
          Fail(DecodeErrorMessage(R.Error));
      end;
    end;
    AssertEquals('foo0123456789', Body);
    AssertTrue('trailers frame', GotTrailers);
    AssertEquals(2, T.Count);
    AssertEquals('never', T.GetValue('expires'));
    AssertEquals('b', T.GetValue('x-a'));
    AssertTrue(D.IsEof);
  finally
    T.Free;
  end;
end;

procedure TTestDecoder.Test_wd_data_slice_is_zero_copy;
var
  D: TDecoder;
  Buf: RawByteString;
  R: TDecodeResult;
begin
  Buf := '5'#13#10'hello'#13#10'0'#13#10#13#10;
  D.InitChunked;
  AssertTrue(D.Decode(PByte(Pointer(Buf)), Length(Buf), False, R) = dsData);
  AssertEquals(3, R.DataOfs);
  AssertEquals(5, R.DataLen);
  AssertEquals(8, R.Consumed);
  AssertTrue(D.State = csBodyCr);
  Delete(Buf, 1, R.Consumed);
  AssertTrue(D.Decode(PByte(Pointer(Buf)), Length(Buf), False, R) = dsEnd);
  AssertEquals(Length(Buf), R.Consumed);
end;

procedure TTestDecoder.Test_wd_error_is_sticky;
var
  D: TDecoder;
  Buf: RawByteString;
  R: TDecodeResult;
begin
  Buf := 'Z'#13#10;
  D.InitChunked;
  AssertTrue(D.Decode(PByte(Pointer(Buf)), Length(Buf), False, R) = dsError);
  AssertTrue(R.Error = deMissingSizeDigit);
  Buf := '1'#13#10'a'#13#10;
  AssertTrue(D.Decode(PByte(Pointer(Buf)), Length(Buf), False, R) = dsError);
  AssertTrue(R.Error = deMissingSizeDigit);
end;

initialization
  RegisterTest(TTestDecoder);
end.

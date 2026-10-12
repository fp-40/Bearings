{ Ports of the 10 tests in hyper v1.12.0 src/proto/h1/encode.rs.
  Test_wd_<name> methods are extra tests of this port's own API. }
unit test_codec_encode;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  bearings.http.headers, bearings.http1.encode;

type
  TTestEncoder = class(TTestCase)
  published
    procedure Test_chunked;
    procedure Test_length;
    procedure Test_eof;
    procedure Test_chunked_with_valid_trailers;
    procedure Test_chunked_with_multiple_trailer_headers;
    procedure Test_chunked_with_duplicate_trailer_values;
    procedure Test_chunked_with_no_trailer_header;
    procedure Test_chunked_with_invalid_trailers;
    procedure Test_chunked_with_title_case_headers;
    procedure Test_chunked_trailers_case_insensitive_matching;
    { extra (not hyper) }
    procedure Test_wd_iovec_and_advance;
    procedure Test_wd_encode_and_end;
    procedure Test_wd_trailer_header_value_parsing;
  end;

implementation

{ dst.put(buf) }
procedure Put(var Dst: RawByteString; const B: TEncodedBuf);
var
  S: RawByteString;
begin
  SetLength(S, B.Remaining);
  if Length(S) > 0 then
    B.CopyTo(PByte(Pointer(S)));
  Dst := Dst + S;
end;

function BytesToStr(const B: TBytes): RawByteString;
begin
  SetLength(Result, Length(B));
  if Length(B) > 0 then
    Move(B[0], Pointer(Result)^, Length(B));
end;

procedure TTestEncoder.Test_chunked;
var
  Encoder: TEncoder;
  Dst, Msg1, Msg2: RawByteString;
  Buf: TEncodedBuf;
  NotEof: QWord;
begin
  Encoder := TEncoder.Chunked;
  Dst := '';
  Msg1 := 'foo bar';
  Encoder.Encode(PByte(Pointer(Msg1)), Length(Msg1), Buf);
  Put(Dst, Buf);
  AssertEquals('7'#13#10'foo bar'#13#10, Dst);

  Msg2 := 'baz quux herp';
  Encoder.Encode(PByte(Pointer(Msg2)), Length(Msg2), Buf);
  Put(Dst, Buf);
  AssertEquals('7'#13#10'foo bar'#13#10'D'#13#10'baz quux herp'#13#10, Dst);

  AssertTrue(Encoder.Finish(Buf, NotEof) = eeBuf);
  Put(Dst, Buf);
  AssertEquals('7'#13#10'foo bar'#13#10'D'#13#10'baz quux herp'#13#10'0'#13#10#13#10, Dst);
end;

procedure TTestEncoder.Test_length;
const
  MAX_LEN = 8;
var
  Encoder: TEncoder;
  Dst, Msg1, Msg2: RawByteString;
  Buf: TEncodedBuf;
  NotEof: QWord;
begin
  Encoder := TEncoder.Length(MAX_LEN);
  Dst := '';
  Msg1 := 'foo bar';
  Encoder.Encode(PByte(Pointer(Msg1)), Length(Msg1), Buf);
  Put(Dst, Buf);
  AssertEquals('foo bar', Dst);
  AssertFalse(Encoder.IsEof);
  AssertTrue('end() must be Err(NotEof)', Encoder.Finish(Buf, NotEof) = eeNotEof);
  AssertEquals(1, NotEof);

  Msg2 := 'baz';
  Encoder.Encode(PByte(Pointer(Msg2)), Length(Msg2), Buf);
  Put(Dst, Buf);
  AssertEquals(MAX_LEN, Length(Dst));
  AssertEquals('foo barb', Dst);
  AssertTrue(Encoder.IsEof);
  AssertTrue('end() must be Ok(None)', Encoder.Finish(Buf, NotEof) = eeNone);
end;

procedure TTestEncoder.Test_eof;
var
  Encoder: TEncoder;
  Dst, Msg1, Msg2: RawByteString;
  Buf: TEncodedBuf;
  NotEof: QWord;
begin
  Encoder := TEncoder.CloseDelimited;
  Dst := '';
  Msg1 := 'foo bar';
  Encoder.Encode(PByte(Pointer(Msg1)), Length(Msg1), Buf);
  Put(Dst, Buf);
  AssertEquals('foo bar', Dst);
  AssertFalse(Encoder.IsEof);
  AssertTrue(Encoder.Finish(Buf, NotEof) <> eeNotEof);

  Msg2 := 'baz';
  Encoder.Encode(PByte(Pointer(Msg2)), Length(Msg2), Buf);
  Put(Dst, Buf);
  AssertEquals('foo barbaz', Dst);
  AssertFalse(Encoder.IsEof);
  AssertTrue(Encoder.Finish(Buf, NotEof) <> eeNotEof);
end;

procedure TTestEncoder.Test_chunked_with_valid_trailers;
var
  Encoder: TEncoder;
  H: THttpHeaders;
  Dst: TBytes;
begin
  Encoder := TEncoder.Chunked;
  Encoder.IntoChunkedWithTrailingFields(['chunky-trailer']);
  H := THttpHeaders.Create;
  try
    H.Add('chunky-trailer', 'header data');
    H.Add('should-not-be-included', 'oops');
    AssertTrue(Encoder.EncodeTrailers(H, False, Dst));
    AssertEquals('0'#13#10'chunky-trailer: header data'#13#10#13#10, BytesToStr(Dst));
  finally
    H.Free;
  end;
end;

procedure TTestEncoder.Test_chunked_with_multiple_trailer_headers;
var
  Encoder: TEncoder;
  H: THttpHeaders;
  Dst: TBytes;
begin
  Encoder := TEncoder.Chunked;
  Encoder.IntoChunkedWithTrailingFields(['chunky-trailer', 'chunky-trailer-2']);
  H := THttpHeaders.Create;
  try
    H.Add('chunky-trailer', 'header data');
    H.Add('chunky-trailer-2', 'more header data');
    AssertTrue(Encoder.EncodeTrailers(H, False, Dst));
    AssertEquals('0'#13#10'chunky-trailer: header data'#13#10'chunky-trailer-2: more header data'#13#10#13#10,
      BytesToStr(Dst));
  finally
    H.Free;
  end;
end;

procedure TTestEncoder.Test_chunked_with_duplicate_trailer_values;
var
  Encoder: TEncoder;
  H: THttpHeaders;
  Dst: TBytes;
begin
  Encoder := TEncoder.Chunked;
  Encoder.IntoChunkedWithTrailingFields(['chunky-trailer']);
  H := THttpHeaders.Create;
  try
    H.Append('chunky-trailer', 'first');
    H.Append('chunky-trailer', 'second');
    AssertTrue(Encoder.EncodeTrailers(H, False, Dst));
    AssertEquals('0'#13#10'chunky-trailer: first'#13#10'chunky-trailer: second'#13#10#13#10,
      BytesToStr(Dst));
  finally
    H.Free;
  end;
end;

procedure TTestEncoder.Test_chunked_with_no_trailer_header;
var
  Encoder: TEncoder;
  H: THttpHeaders;
  Dst: TBytes;
begin
  Encoder := TEncoder.Chunked;
  H := THttpHeaders.Create;
  try
    H.Add('chunky-trailer', 'header data');
    AssertFalse(Encoder.EncodeTrailers(H, False, Dst));
    AssertEquals(0, Length(Dst));

    Encoder.IntoChunkedWithTrailingFields([]);
    AssertFalse(Encoder.EncodeTrailers(H, False, Dst));
    AssertEquals(0, Length(Dst));
  finally
    H.Free;
  end;
end;

procedure TTestEncoder.Test_chunked_with_invalid_trailers;
const
  NAMES: array[0..11] of RawByteString = (
    HN_AUTHORIZATION, HN_CACHE_CONTROL, HN_CONTENT_ENCODING, HN_CONTENT_LENGTH,
    HN_CONTENT_RANGE, HN_CONTENT_TYPE, HN_HOST, HN_MAX_FORWARDS, HN_SET_COOKIE,
    HN_TRAILER, HN_TRANSFER_ENCODING, HN_TE);
var
  Encoder: TEncoder;
  H: THttpHeaders;
  Dst: TBytes;
  I: Integer;
begin
  Encoder := TEncoder.Chunked;
  Encoder.IntoChunkedWithTrailingFields(NAMES);
  H := THttpHeaders.Create;
  try
    for I := Low(NAMES) to High(NAMES) do
      H.Insert(NAMES[I], 'header data');
    AssertEquals(12, H.Count);
    AssertFalse(Encoder.EncodeTrailers(H, True, Dst));
  finally
    H.Free;
  end;
end;

procedure TTestEncoder.Test_chunked_with_title_case_headers;
var
  Encoder: TEncoder;
  H: THttpHeaders;
  Dst: TBytes;
begin
  Encoder := TEncoder.Chunked;
  Encoder.IntoChunkedWithTrailingFields(['chunky-trailer']);
  H := THttpHeaders.Create;
  try
    H.Add('chunky-trailer', 'header data');
    AssertTrue(Encoder.EncodeTrailers(H, True, Dst));
    AssertEquals('0'#13#10'Chunky-Trailer: header data'#13#10#13#10, BytesToStr(Dst));
  finally
    H.Free;
  end;
end;

procedure TTestEncoder.Test_chunked_trailers_case_insensitive_matching;
var
  Encoder: TEncoder;
  H: THttpHeaders;
  Dst: TBytes;
begin
  // hyper's assertion: declared lowercase, sent lowercase
  Encoder := TEncoder.Chunked;
  Encoder.IntoChunkedWithTrailingFields(['chunky-trailer']);
  H := THttpHeaders.Create;
  try
    H.Add('chunky-trailer', 'trailer value');
    AssertTrue(Encoder.EncodeTrailers(H, False, Dst));
    AssertEquals('0'#13#10'chunky-trailer: trailer value'#13#10#13#10, BytesToStr(Dst));

    // the case the regression (issue #4010) is about: the Trailer header
    // declares 'Chunky-Trailer' and the trailer is sent as 'chunky-trailer'
    Encoder := TEncoder.Chunked;
    Encoder.IntoChunkedWithTrailingFields(['Chunky-Trailer']);
    AssertTrue(Encoder.EncodeTrailers(H, False, Dst));
    AssertEquals('0'#13#10'chunky-trailer: trailer value'#13#10#13#10, BytesToStr(Dst));
  finally
    H.Free;
  end;
end;

{ ---- extra ---- }

procedure TTestEncoder.Test_wd_iovec_and_advance;
var
  Encoder: TEncoder;
  Msg, Got: RawByteString;
  Buf: TEncodedBuf;
  V: array[0..2] of TIoSlice;
  N, I: Integer;
  S: RawByteString;
begin
  Encoder := TEncoder.Chunked;
  SetLength(Msg, 300);
  FillChar(Msg[1], 300, Ord('z'));
  Encoder.Encode(PByte(Pointer(Msg)), Length(Msg), Buf);
  AssertTrue(Buf.Kind = ebkChunked);
  AssertEquals(5 + 300 + 2, Buf.Remaining);
  N := Buf.FillIoVec(@V[0], 3);
  AssertEquals(3, N);
  Got := '';
  for I := 0 to N - 1 do
  begin
    SetLength(S, V[I].Len);
    Move(V[I].Base^, Pointer(S)^, V[I].Len);
    Got := Got + S;
  end;
  AssertEquals('12C'#13#10 + Msg + #13#10, Got);
  AssertTrue('data segment points at caller memory', V[1].Base = Pointer(Msg));
  // partial write of 7 bytes: prefix (5) + 2 data bytes
  Buf.Advance(7);
  AssertEquals(298 + 2, Buf.Remaining);
  N := Buf.FillIoVec(@V[0], 3);
  AssertEquals(2, N);
  AssertTrue(V[0].Base = Pointer(PByte(Pointer(Msg)) + 2));
  Buf.Advance(299);
  AssertEquals(1, Buf.Remaining);
  N := Buf.FillIoVec(@V[0], 3);
  AssertEquals(1, N);
  AssertEquals(10, PByte(V[0].Base)^);
  // the largest size line: 16 hex digits + CRLF
  Encoder := TEncoder.Chunked;
  SetLength(S, CHUNK_SIZE_MAX_BYTES + 2);
  AssertEquals(18, WriteChunkSize(PByte(Pointer(S)), High(SizeUInt)));
  AssertEquals('FFFFFFFFFFFFFFFF'#13#10, S);
end;

procedure TTestEncoder.Test_wd_encode_and_end;
var
  Encoder: TEncoder;
  Msg, Dst: RawByteString;
  Buf: TEncodedBuf;
begin
  Msg := 'hello';
  Encoder := TEncoder.Chunked;
  AssertTrue(Encoder.EncodeAndEnd(PByte(Pointer(Msg)), 5, Buf));
  Dst := '';
  Put(Dst, Buf);
  AssertEquals('5'#13#10'hello'#13#10'0'#13#10#13#10, Dst);

  Encoder := TEncoder.Length(5);
  AssertTrue(Encoder.EncodeAndEnd(PByte(Pointer(Msg)), 5, Buf));
  Encoder.SetLast(True);
  AssertFalse(Encoder.EncodeAndEnd(PByte(Pointer(Msg)), 5, Buf));

  Encoder := TEncoder.Length(3);
  AssertTrue(Encoder.EncodeAndEnd(PByte(Pointer(Msg)), 5, Buf));
  Dst := '';
  Put(Dst, Buf);
  AssertEquals('hel', Dst);

  Encoder := TEncoder.Length(10);
  AssertFalse(Encoder.EncodeAndEnd(PByte(Pointer(Msg)), 5, Buf));

  Encoder := TEncoder.CloseDelimited;
  AssertFalse(Encoder.EncodeAndEnd(PByte(Pointer(Msg)), 5, Buf));
  Dst := '';
  Put(Dst, Buf);
  AssertEquals('hello', Dst);
end;

procedure TTestEncoder.Test_wd_trailer_header_value_parsing;
var
  Encoder: TEncoder;
  V: RawByteString;
  H: THttpHeaders;
  Dst: TBytes;
begin
  V := ' X-A ,x-b,, Content-Length ';
  Encoder := TEncoder.Chunked;
  Encoder.IntoChunkedWithTrailerHeader(PByte(Pointer(V)), Length(V));
  H := THttpHeaders.Create;
  try
    H.Add('x-b', '2');
    H.Add('X-C', '3');
    H.Add('x-a', '1');
    H.Add('content-length', '5');
    AssertTrue(Encoder.EncodeTrailers(H, False, Dst));
    AssertEquals('0'#13#10'x-b: 2'#13#10'x-a: 1'#13#10#13#10, BytesToStr(Dst));
    // non-chunked encoders never emit trailers
    Encoder := TEncoder.Length(3);
    Encoder.IntoChunkedWithTrailerHeader(PByte(Pointer(V)), Length(V));
    AssertFalse(Encoder.EncodeTrailers(H, False, Dst));
  finally
    H.Free;
  end;
end;

initialization
  RegisterTest(TTestEncoder);
end.

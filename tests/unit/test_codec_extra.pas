{ Extra_* tests: edge cases the hyper tests do not cover.

  Decoder expectations are hyper's own results: each body was run through
  hyper v1.12.0's src/proto/h1/decode.rs with test_codec_diff_rs ("run"
  mode), with the same splits as below, and hyper gave the same result for
  every split. The strings use the format of test_codec_replay:
    STATUS|DATALEN|DATAFNV|LEFTOVER|THEN|ISEOF
  The helpers OkR/ErrR rebuild them from the status, the decoded data and
  the leftover byte count.

  Encoder, header, date and reason-phrase expectations come from the hyper,
  http-crate and httpdate source named in each test. }
unit test_codec_extra;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  bearings.http.headers, bearings.http1.decode, bearings.http1.encode, bearings.http.date, bearings.http1.reason,
  test_codec_replay;

type
  TTestCodecExtra = class(TTestCase)
  private
    procedure CheckBody(const What: string; Kind: Char; N: QWord; MaxH, MaxHS: SizeInt;
      const Body: RawByteString; const Expected: string);
    procedure DoFormatNegative;
    procedure DoFormatYear10000;
  published
    { decoder }
    procedure Extra_decode_chunk_size_overflow;
    procedure Extra_decode_chunk_extensions_limit;
    procedure Extra_decode_trailer_limits;
    procedure Extra_decode_trailer_parsing;
    procedure Extra_decode_trailer_long_name_error_order;
    procedure Extra_decode_cr_lf_handling;
    procedure Extra_decode_empty_input;
    procedure Extra_decode_leaves_bytes_after_body;
    procedure Extra_decode_length_max_u64;
    procedure Extra_decode_every_split_point;
    procedure Extra_decode_eof_at_every_byte;
    procedure Extra_decode_contract_details;
    { encoder }
    procedure Extra_encode_length_limits;
    procedure Extra_encode_chunk_size_lines;
    procedure Extra_encode_and_end_details;
    procedure Extra_encode_trailers_details;
    procedure Extra_encode_trailer_header_lines;
    { headers.rs helpers and the header list }
    procedure Extra_headers_list_value_edges;
    procedure Extra_headers_content_length_edges;
    procedure Extra_headers_copy_from_same_list;
    { date, reason phrase }
    procedure Extra_date_boundaries;
    procedure Extra_reason_every_byte;
    { hot paths }
    procedure Extra_hot_paths_do_not_allocate;
  end;

implementation

{ ---- memory manager hooks: count allocations, or poison freed memory ---- }

var
  OldMM: TMemoryManager;
  AllocCount: SizeInt;

function CntGetMem(Size: PtrUInt): Pointer;
begin
  Inc(AllocCount);
  Result := OldMM.GetMem(Size);
end;

function CntAllocMem(Size: PtrUInt): Pointer;
begin
  Inc(AllocCount);
  Result := OldMM.AllocMem(Size);
end;

function CntReAllocMem(var P: Pointer; Size: PtrUInt): Pointer;
begin
  Inc(AllocCount);
  Result := OldMM.ReAllocMem(P, Size);
end;

procedure StartCounting;
var
  M: TMemoryManager;
begin
  GetMemoryManager(OldMM);
  M := OldMM;
  M.GetMem := @CntGetMem;
  M.AllocMem := @CntAllocMem;
  M.ReAllocMem := @CntReAllocMem;
  AllocCount := 0;
  SetMemoryManager(M);
end;

function StopCounting: SizeInt;
begin
  SetMemoryManager(OldMM);
  Result := AllocCount;
end;

{ Every free fills the block with $F0 first, and every realloc moves the
  block (then frees the old one), so a read through a stale pointer sees
  $F0 instead of the old bytes. }
function PoisonFreeMem(P: Pointer): PtrUInt;
begin
  if P <> nil then
    FillChar(P^, OldMM.MemSize(P), $F0);
  Result := OldMM.FreeMem(P);
end;

function PoisonFreeMemSize(P: Pointer; Size: PtrUInt): PtrUInt;
begin
  Result := PoisonFreeMem(P);
end;

function PoisonReAllocMem(var P: Pointer; Size: PtrUInt): Pointer;
var
  NewP: Pointer;
  OldSize: PtrUInt;
begin
  if Size = 0 then
  begin
    PoisonFreeMem(P);
    P := nil;
    Exit(nil);
  end;
  NewP := OldMM.GetMem(Size);
  if P <> nil then
  begin
    OldSize := OldMM.MemSize(P);
    if OldSize > Size then OldSize := Size;
    Move(P^, NewP^, OldSize);
    PoisonFreeMem(P);
  end;
  P := NewP;
  Result := NewP;
end;

procedure StartPoisoning;
var
  M: TMemoryManager;
begin
  GetMemoryManager(OldMM);
  M := OldMM;
  M.FreeMem := @PoisonFreeMem;
  M.FreeMemSize := @PoisonFreeMemSize;
  M.ReAllocMem := @PoisonReAllocMem;
  SetMemoryManager(M);
end;

procedure StopPoisoning;
begin
  SetMemoryManager(OldMM);
end;

{ ---- helpers ---- }

function Rep(const S: RawByteString; N: SizeInt): RawByteString;
var
  I: SizeInt;
begin
  SetLength(Result, Length(S) * N);
  for I := 0 to N - 1 do
    if Length(S) > 0 then
      Move(S[1], Result[I * Length(S) + 1], Length(S));
end;

{ hyper finished the body: STATUS is END or TRL:..., then one more call gave
  END, and is_eof() was true. }
function OkR(const Status: string; const Data: RawByteString; Leftover: SizeInt): string;
begin
  Result := Format('%s|%d|%s|%d|END|1', [Status, Length(Data), Fnv1aHex(Data), Leftover]);
end;

{ hyper returned this error after yielding Data. }
function ErrR(const KindAndMessage: string; const Data: RawByteString): string;
begin
  Result := Format('ERR:%s|%d|%s|-|-|-', [KindAndMessage, Length(Data), Fnv1aHex(Data)]);
end;

const
  E_EOF_LINE = 'UnexpectedEof:unexpected EOF during chunk size line';
  E_EOF_BODY = 'UnexpectedEof:end of file before message length reached';
  E_OVERFLOW = 'InvalidData:invalid chunk size: overflow';
  E_EXT_LIMIT = 'InvalidData:chunk extensions over limit';
  E_TRL_BYTES = 'InvalidData:chunk trailers bytes over limit';
  E_TRL_COUNT = 'InvalidData:chunk trailers count overflow';
  E_HP_NAME = 'InvalidInput:invalid header name';     { httparse Error::HeaderName }
  E_HP_VALUE = 'InvalidInput:invalid header value';   { httparse Error::HeaderValue }
  E_HP_TOO_MANY = 'InvalidInput:too many headers';    { httparse Error::TooManyHeaders }
  E_HN_INVALID = 'InvalidInput:Invalid header name';  { http HeaderName::try_from }

{ Runs Body with: one read, one byte per read, two reads split at every
  offset (bodies up to 600 bytes; longer ones at 40 offsets), and three
  reads at every pair of offsets (bodies up to 72 bytes). Every run must
  give Expected. }
procedure TTestCodecExtra.CheckBody(const What: string; Kind: Char; N: QWord;
  MaxH, MaxHS: SizeInt; const Body: RawByteString; const Expected: string);
var
  L, I, J, Step: SizeInt;
  Splits: array of SizeInt;
  Got: string;

  procedure Check(const How: string);
  begin
    Got := ReplayDecode(Kind, N, MaxH, MaxHS, Body, Splits);
    if Got <> Expected then
      Fail(Format('%s (%s): expected %s, got %s',
        [What, How, Copy(Expected, 1, 200), Copy(Got, 1, 200)]));
  end;

begin
  L := Length(Body);
  if L = 0 then
  begin
    SetLength(Splits, 0);
    Check('no reads');
    SetLength(Splits, 3);
    Splits[0] := 0; Splits[1] := 0; Splits[2] := 0;
    Check('three empty reads');
    Exit;
  end;
  SetLength(Splits, 1);
  Splits[0] := L;
  Check('one read');
  SetLength(Splits, L);
  for I := 0 to L - 1 do
    Splits[I] := 1;
  Check('one byte per read');
  if L <= 600 then
    Step := 1
  else
    Step := L div 40;
  SetLength(Splits, 2);
  I := 0;
  while I <= L do
  begin
    Splits[0] := I;
    Splits[1] := L - I;
    Check(Format('split at %d', [I]));
    Inc(I, Step);
  end;
  if L <= 72 then
  begin
    SetLength(Splits, 3);
    for I := 0 to L do
      for J := I to L do
      begin
        Splits[0] := I;
        Splits[1] := J - I;
        Splits[2] := L - J;
        Check(Format('split at %d and %d', [I, J]));
      end;
  end;
end;

{ ---- decoder ---- }

procedure TTestCodecExtra.Extra_decode_chunk_size_overflow;
begin
  // u64::MAX is a valid size (both cases); the body is then cut short
  CheckBody('ffff...ffff', 'C', 0, -1, -1, 'ffffffffffffffff'#13#10'abc', ErrR(E_EOF_BODY, 'abc'));
  CheckBody('FFFF...FFFF', 'C', 0, -1, -1, 'FFFFFFFFFFFFFFFF'#13#10'abc', ErrR(E_EOF_BODY, 'abc'));
  // 2^64 and u64::MAX * 16 overflow (checked_mul)
  CheckBody('2^64', 'C', 0, -1, -1, '10000000000000000'#13#10, ErrR(E_OVERFLOW, ''));
  CheckBody('max*16', 'C', 0, -1, -1, 'ffffffffffffffff0'#13#10, ErrR(E_OVERFLOW, ''));
  // leading zeros never overflow
  CheckBody('27 zeros then 1', 'C', 0, -1, -1,
    StringOfChar('0', 27) + '1'#13#10'a'#13#10'0'#13#10#13#10, OkR('END', 'a', 0));
  CheckBody('28 zeros', 'C', 0, -1, -1, StringOfChar('0', 28) + #13#10#13#10, OkR('END', '', 0));
end;

procedure TTestCodecExtra.Extra_decode_chunk_extensions_limit;
begin
  // CHUNKED_EXTENSIONS_LIMIT = 16384 bytes after the ';' that starts the
  // extensions, counted over the whole body; ext_cnt >= limit is an error
  CheckBody('16383', 'C', 0, -1, -1,
    '1;' + StringOfChar('x', 16383) + #13#10'a'#13#10'0'#13#10#13#10, OkR('END', 'a', 0));
  CheckBody('16384', 'C', 0, -1, -1,
    '1;' + StringOfChar('x', 16384) + #13#10'a'#13#10'0'#13#10#13#10, ErrR(E_EXT_LIMIT, ''));
  CheckBody('8000+8383', 'C', 0, -1, -1,
    '1;' + StringOfChar('x', 8000) + #13#10'a'#13#10'1;' + StringOfChar('x', 8383) +
    #13#10'b'#13#10'0'#13#10#13#10, OkR('END', 'ab', 0));
  CheckBody('8000+8384', 'C', 0, -1, -1,
    '1;' + StringOfChar('x', 8000) + #13#10'a'#13#10'1;' + StringOfChar('x', 8384) +
    #13#10'b'#13#10'0'#13#10#13#10, ErrR(E_EXT_LIMIT, 'a'));
  // later ';' are extension bytes too
  CheckBody('semicolons', 'C', 0, -1, -1,
    '1;' + StringOfChar(';', 16383) + #13#10'a'#13#10'0'#13#10#13#10, OkR('END', 'a', 0));
  CheckBody('last chunk', 'C', 0, -1, -1,
    '0;' + StringOfChar('x', 16383) + #13#10#13#10, OkR('END', '', 0));
  // whitespace after the size is not counted
  CheckBody('20000 spaces', 'C', 0, -1, -1,
    '1' + StringOfChar(' ', 20000) + #13#10'a'#13#10'0'#13#10#13#10, OkR('END', 'a', 0));
end;

procedure TTestCodecExtra.Extra_decode_trailer_limits;
begin
  // trailer buffer "a: b\r\n\r\n" is 8 bytes; put_u8 fails once len >= limit
  CheckBody('8 bytes, limit 8', 'C', 0, -1, 8, '0'#13#10'a: b'#13#10#13#10, ErrR(E_TRL_BYTES, ''));
  CheckBody('8 bytes, limit 9', 'C', 0, -1, 9, '0'#13#10'a: b'#13#10#13#10, OkR('TRL:a=62', '', 0));
  // the first trailer byte creates the buffer without a limit check
  CheckBody('limit 0, one byte, EOF', 'C', 0, -1, 0, '0'#13#10'X', ErrR(E_EOF_LINE, ''));
  CheckBody('limit 1, two bytes', 'C', 0, -1, 1, '0'#13#10'XY', ErrR(E_TRL_BYTES, ''));
  CheckBody('limit 1, no trailers', 'C', 0, -1, 1, '0'#13#10#13#10, OkR('END', '', 0));
  CheckBody('max headers 0, one trailer', 'C', 0, 0, -1, '0'#13#10'a: b'#13#10#13#10, ErrR(E_TRL_COUNT, ''));
  CheckBody('max headers 0, no trailers', 'C', 0, 0, -1, '0'#13#10#13#10, OkR('END', '', 0));
  // default TRAILER_LIMIT 16384: buffer = "t: " + value + "\r\n\r\n"
  CheckBody('default limit, 16383 bytes', 'C', 0, -1, -1,
    '0'#13#10't: ' + StringOfChar('v', 16376) + #13#10#13#10, OkR('TRL:t=' + Rep('76', 16376), '', 0));
  CheckBody('default limit, 16384 bytes', 'C', 0, -1, -1,
    '0'#13#10't: ' + StringOfChar('v', 16377) + #13#10#13#10, ErrR(E_TRL_BYTES, ''));
end;

procedure TTestCodecExtra.Extra_decode_trailer_parsing;
begin
  // the decoder counts CRLF lines; httparse also ends a line at a bare LF,
  // so it finds 2 fields with room for 1
  CheckBody('bare LF', 'C', 0, -1, -1, '0'#13#10'a: b'#10'c: d'#13#10#13#10, ErrR(E_HP_TOO_MANY, ''));
  // httparse sees the empty line first: trailers frame with no fields
  CheckBody('starts with LF', 'C', 0, -1, -1, '0'#13#10#10'foo: bar'#13#10#13#10, OkR('TRL:', '', 0));
  CheckBody('obs-fold', 'C', 0, -1, -1, '0'#13#10'a: b'#13#10' c'#13#10#13#10, ErrR(E_HP_NAME, ''));
  CheckBody('empty and trimmed values', 'C', 0, -1, -1,
    '0'#13#10'a:'#13#10'b: '#9' x '#9#13#10#13#10, OkR('TRL:a=-,b=78', '', 0));
  CheckBody('space before colon', 'C', 0, -1, -1, '0'#13#10'a : b'#13#10#13#10, ErrR(E_HP_NAME, ''));
  CheckBody('DEL in value', 'C', 0, -1, -1, '0'#13#10'a: b'#$7F'c'#13#10#13#10, ErrR(E_HP_VALUE, ''));
  CheckBody('NUL in value', 'C', 0, -1, -1, '0'#13#10'a: b'#0'c'#13#10#13#10, ErrR(E_HP_VALUE, ''));
  CheckBody('obs-text value', 'C', 0, -1, -1,
    '0'#13#10'a: b'#$80#$FF'c'#13#10#13#10, OkR('TRL:a=6280ff63', '', 0));
  CheckBody('no colon', 'C', 0, -1, -1, '0'#13#10'nocolon'#13#10#13#10, ErrR(E_HP_NAME, ''));
  CheckBody('empty name', 'C', 0, -1, -1, '0'#13#10':v'#13#10#13#10, ErrR(E_HP_NAME, ''));
  // http MAX_HEADER_NAME_LEN = 65535
  CheckBody('name 65535', 'C', 0, -1, 200000,
    '0'#13#10 + StringOfChar('a', 65535) + ': v'#13#10#13#10,
    OkR('TRL:' + StringOfChar('a', 65535) + '=76', '', 0));
  CheckBody('name 65536', 'C', 0, -1, 200000,
    '0'#13#10 + StringOfChar('a', 65536) + ': v'#13#10#13#10, ErrR(E_HN_INVALID, ''));
end;

procedure TTestCodecExtra.Extra_decode_trailer_long_name_error_order;
begin
  // hyper runs HeaderName::try_from only after httparse parsed every line,
  // so a later httparse error wins over a too-long name
  CheckBody('long name, then bad line', 'C', 0, -1, 200000,
    '0'#13#10 + StringOfChar('a', 65536) + ': v'#13#10'b@: x'#13#10#13#10, ErrR(E_HP_NAME, ''));
  CheckBody('long name, then too many', 'C', 0, -1, 200000,
    '0'#13#10 + StringOfChar('a', 65536) + ': v'#10'b: x'#13#10#13#10, ErrR(E_HP_TOO_MANY, ''));
end;

procedure TTestCodecExtra.Extra_decode_cr_lf_handling;
begin
  CheckBody('size LF', 'C', 0, -1, -1, '1'#10, ErrR('InvalidInput:Invalid chunk size line: Invalid Size', ''));
  CheckBody('size CR CR', 'C', 0, -1, -1, '1'#13#13#10, ErrR('InvalidInput:Invalid chunk size LF', ''));
  CheckBody('body LF', 'C', 0, -1, -1, '1'#13#10'a'#10, ErrR('InvalidInput:Invalid chunk body CR', 'a'));
  CheckBody('body CR CR', 'C', 0, -1, -1, '1'#13#10'a'#13#13, ErrR('InvalidInput:Invalid chunk body LF', 'a'));
  CheckBody('end CR CR', 'C', 0, -1, -1, '0'#13#10#13#13, ErrR('InvalidInput:Invalid chunk end LF', ''));
  CheckBody('trailer CR CR', 'C', 0, -1, -1, '0'#13#10'a'#13#13, ErrR('InvalidInput:Invalid trailer end LF', ''));
  CheckBody('extension LF', 'C', 0, -1, -1, '1;a'#10'b',
    ErrR('InvalidData:invalid chunk extension contains newline', ''));
  CheckBody('LWS LF', 'C', 0, -1, -1, '1 '#10, ErrR('InvalidInput:Invalid chunk size linear white space', ''));
  CheckBody('extension CR CR', 'C', 0, -1, -1, '1;a'#13#13, ErrR('InvalidInput:Invalid chunk size LF', ''));
  CheckBody('LF first', 'C', 0, -1, -1, #10,
    ErrR('InvalidInput:Invalid chunk size line: missing size digit', ''));
  CheckBody('digit after LWS', 'C', 0, -1, -1, '1 2'#13#10,
    ErrR('InvalidInput:Invalid chunk size linear white space', ''));
  CheckBody('tab LWS then extension', 'C', 0, -1, -1, '1'#9';x'#13#10'a'#13#10'0'#13#10#13#10, OkR('END', 'a', 0));
  // a lone LF after the last chunk starts a trailer section
  CheckBody('last chunk then LF', 'C', 0, -1, -1, '0'#13#10#10, ErrR(E_EOF_LINE, ''));
end;

procedure TTestCodecExtra.Extra_decode_empty_input;
var
  D: TDecoder;
  R: TDecodeResult;
begin
  CheckBody('Length(5)', 'L', 5, -1, -1, '', ErrR(E_EOF_BODY, ''));
  CheckBody('Length(0)', 'L', 0, -1, -1, '', OkR('END', '', 0));
  CheckBody('Chunked', 'C', 0, -1, -1, '', ErrR(E_EOF_LINE, ''));
  CheckBody('Eof', 'E', 0, -1, -1, '', OkR('END', '', 0));
  // no bytes and no EOF: nothing happens
  D.InitLength(5);
  AssertTrue(D.Decode(nil, 0, False, R) = dsNeedMore);
  AssertEquals(0, R.Consumed);
  AssertEquals(5, D.Remaining);
  D.InitChunked;
  AssertTrue(D.Decode(nil, 0, False, R) = dsNeedMore);
  AssertTrue(D.State = csStart);
  D.InitEof;
  AssertTrue(D.Decode(nil, 0, False, R) = dsNeedMore);
  AssertFalse(D.IsEof);
end;

procedure TTestCodecExtra.Extra_decode_leaves_bytes_after_body;
begin
  CheckBody('chunked', 'C', 0, -1, -1, '3'#13#10'abc'#13#10'0'#13#10#13#10'GET', OkR('END', 'abc', 3));
  CheckBody('length', 'L', 3, -1, -1, 'abcGET', OkR('END', 'abc', 3));
  CheckBody('trailers', 'C', 0, -1, -1, '0'#13#10'x: y'#13#10#13#10'GET / HTTP/1.1'#13#10#13#10,
    OkR('TRL:x=79', '', 18));
end;

procedure TTestCodecExtra.Extra_decode_length_max_u64;
var
  D: TDecoder;
  R: TDecodeResult;
  S: RawByteString;
begin
  CheckBody('u64::MAX', 'L', High(QWord), -1, -1, 'abc', ErrR(E_EOF_BODY, 'abc'));
  D.InitLength(High(QWord));
  S := 'abc';
  AssertTrue(D.Decode(PByte(Pointer(S)), 3, False, R) = dsData);
  AssertEquals(3, R.DataLen);
  AssertTrue(D.Remaining = High(QWord) - 3);
end;

const
  { size line with LWS and an extension, a 10-byte chunk with LWS after its
    size, an extension on the last chunk, two trailers with one name }
  COMPLEX: RawByteString = '3;e=1'#13#10'abc'#13#10'A '#9#13#10'0123456789'#13#10 +
    '0;z'#13#10'X-A: b'#13#10'x-a: c'#13#10#13#10;

procedure TTestCodecExtra.Extra_decode_every_split_point;
begin
  CheckBody('complex body', 'C', 0, -1, -1, COMPLEX, OkR('TRL:x-a=62,x-a=63', 'abc0123456789', 0));
  CheckBody('complex body + next request', 'C', 0, -1, -1, COMPLEX + 'GET / HTTP/1.1'#13#10,
    OkR('TRL:x-a=62,x-a=63', 'abc0123456789', 16));
end;

procedure TTestCodecExtra.Extra_decode_eof_at_every_byte;
const
  DATA: RawByteString = 'abc0123456789';
var
  K, DataLen: Integer;
  Msg: string;
begin
  // hyper's result for COMPLEX cut to K bytes, then EOF:
  //   K 0..6  : EOF in the size line            (no data)
  //   K 7..9  : EOF in the 3-byte chunk          (K-7 data bytes)
  //   K 10..16: EOF in a framing line            (3)
  //   K 17..26: EOF in the 10-byte chunk         (K-14)
  //   K 27..  : EOF in the last chunk / trailers (13)
  for K := 0 to Length(COMPLEX) - 1 do
  begin
    case K of
      0..6: begin Msg := E_EOF_LINE; DataLen := 0; end;
      7..9: begin Msg := E_EOF_BODY; DataLen := K - 7; end;
      10..16: begin Msg := E_EOF_LINE; DataLen := 3; end;
      17..26: begin Msg := E_EOF_BODY; DataLen := K - 14; end;
    else
      Msg := E_EOF_LINE;
      DataLen := 13;
    end;
    CheckBody(Format('cut at %d', [K]), 'C', 0, -1, -1, Copy(COMPLEX, 1, K),
      ErrR(Msg, Copy(DATA, 1, DataLen)));
  end;
end;

procedure TTestCodecExtra.Extra_decode_contract_details;
var
  D: TDecoder;
  R: TDecodeResult;
  S: RawByteString;
  T: THttpHeaders;
begin
  // the size accumulated so far is visible while reading the size line
  D.InitChunked;
  S := 'ffffffffffffffff'#13#10;
  AssertTrue(D.Decode(PByte(Pointer(S)), Length(S), False, R) = dsNeedMore);
  AssertEquals(Length(S), R.Consumed);
  AssertTrue(D.State = csBody);
  AssertTrue(D.Remaining = High(QWord));
  // Length: data longer than owed is cut at the length, rest left unconsumed
  D.InitLength(2);
  S := 'abcd';
  AssertTrue(D.Decode(PByte(Pointer(S)), 4, False, R) = dsData);
  AssertEquals(0, R.DataOfs);
  AssertEquals(2, R.DataLen);
  AssertEquals(2, R.Consumed);
  AssertTrue(D.IsEof);
  // Eof: is_eof only after EOF was seen
  D.InitEof;
  S := 'xy';
  AssertTrue(D.Decode(PByte(Pointer(S)), 2, True, R) = dsData);
  AssertFalse(D.IsEof);
  AssertTrue(D.Decode(nil, 0, True, R) = dsEnd);
  AssertTrue(D.IsEof);
  // a trailers frame is followed by End; the Trailers list is cleared first
  T := THttpHeaders.Create;
  try
    T.Add('stale', 'value');
    D.InitChunked;
    S := '0'#13#10'a: 1'#13#10#13#10;
    AssertTrue(D.Decode(PByte(Pointer(S)), Length(S), False, T, R) = dsTrailers);
    AssertEquals(Length(S), R.Consumed);
    AssertEquals(1, T.Count);
    AssertEquals('a', T.Name(0));
    AssertTrue(D.Decode(nil, 0, False, T, R) = dsEnd);
    AssertTrue(D.IsEof);
    // a reused decoder starts clean
    D.InitChunked;
    S := '0'#13#10#13#10;
    AssertTrue(D.Decode(PByte(Pointer(S)), Length(S), False, T, R) = dsEnd);
  finally
    T.Free;
  end;
end;

{ ---- encoder ---- }

function BufStr(const B: TEncodedBuf): RawByteString;
begin
  SetLength(Result, B.Remaining);
  if Length(Result) > 0 then
    B.CopyTo(PByte(Pointer(Result)));
end;

function BytesStr(const B: TBytes): RawByteString;
begin
  SetLength(Result, Length(B));
  if Length(B) > 0 then
    Move(B[0], Result[1], Length(B));
end;

procedure TTestCodecExtra.Extra_encode_length_limits;
var
  E: TEncoder;
  B: TEncodedBuf;
  S: RawByteString;
  NotEof: QWord;
begin
  S := 'abc';
  // hyper encode: Ok(limit) if limit < len => Limited(take(limit)), remaining = 0
  E := TEncoder.Length(0);
  E.Encode(PByte(Pointer(S)), 3, B);
  AssertTrue(B.Kind = ebkLimited);
  AssertEquals(0, B.Remaining);
  AssertTrue(E.IsEof);
  AssertTrue(E.Finish(B, NotEof) = eeNone);
  E := TEncoder.Length(2);
  E.Encode(PByte(Pointer(S)), 3, B);
  AssertEquals('ab', BufStr(B));
  E.Encode(PByte(Pointer(S)), 1, B);
  AssertTrue(B.Kind = ebkLimited);
  AssertEquals(0, B.Remaining);
  // owed more than any write: Exact, remaining -= len
  E := TEncoder.Length(High(QWord));
  E.Encode(PByte(Pointer(S)), 3, B);
  AssertTrue(B.Kind = ebkExact);
  AssertEquals('abc', BufStr(B));
  AssertTrue(E.Remaining = High(QWord) - 3);
  AssertTrue(E.Finish(B, NotEof) = eeNotEof);
  AssertTrue(NotEof = High(QWord) - 3);
  // CloseDelimited: never eof, end() is Ok(None)
  E := TEncoder.CloseDelimited;
  AssertFalse(E.IsEof);
  AssertTrue(E.IsCloseDelimited);
  AssertFalse(E.IsChunked);
  AssertTrue(E.Finish(B, NotEof) = eeNone);
end;

procedure TTestCodecExtra.Extra_encode_chunk_size_lines;
var
  E: TEncoder;
  B: TEncodedBuf;
  S: RawByteString;

  function Line(N: SizeUInt): RawByteString;
  begin
    SetLength(Result, CHUNK_SIZE_MAX_BYTES + 2);
    SetLength(Result, WriteChunkSize(PByte(Pointer(Result)), N));
  end;

begin
  // hyper ChunkSize::new: write!("{len:X}\r\n"), uppercase, no leading zeros
  AssertEquals('1'#13#10, Line(1));
  AssertEquals('F'#13#10, Line(15));
  AssertEquals('10'#13#10, Line(16));
  AssertEquals('FF'#13#10, Line(255));
  AssertEquals('1000'#13#10, Line(4096));
  AssertEquals('ABCDEF'#13#10, Line($ABCDEF));
  AssertEquals('8000000000000000'#13#10, Line(SizeUInt(1) shl 63));
  S := StringOfChar('q', 4096);
  E := TEncoder.Chunked;
  E.Encode(PByte(Pointer(S)), Length(S), B);
  AssertEquals('1000'#13#10 + S + #13#10, BufStr(B));
end;

procedure TTestCodecExtra.Extra_encode_and_end_details;
var
  E: TEncoder;
  B: TEncodedBuf;
  S: RawByteString;
begin
  S := 'abc';
  // encode_and_end takes &self: remaining is not changed
  E := TEncoder.Length(5);
  AssertFalse(E.EncodeAndEnd(PByte(Pointer(S)), 3, B));
  AssertEquals('abc', BufStr(B));
  AssertEquals(5, E.Remaining);
  // chunked, is_last: body and end written, returns !is_last = False
  E := TEncoder.Chunked;
  E.SetLast(True);
  AssertFalse(E.EncodeAndEnd(PByte(Pointer(S)), 3, B));
  AssertEquals('3'#13#10'abc'#13#10'0'#13#10#13#10, BufStr(B));
  // Length Greater with is_last: take(remaining), False
  E := TEncoder.Length(2);
  E.SetLast(True);
  AssertFalse(E.EncodeAndEnd(PByte(Pointer(S)), 3, B));
  AssertEquals('ab', BufStr(B));
end;

procedure TTestCodecExtra.Extra_encode_trailers_details;
var
  E: TEncoder;
  H: THttpHeaders;
  Dst: TBytes;
begin
  H := THttpHeaders.Create;
  try
    // HeaderName is lowercase, so a stored upper-case name is written in
    // lowercase, or title case from the lowercased name
    H.Add('CHUNKY-TRAILER', 'v');
    H.Add('x-FOO-bar', 'w');
    E := TEncoder.Chunked;
    E.IntoChunkedWithTrailingFields(['chunky-trailer', 'X-Foo-Bar']);
    AssertTrue(E.EncodeTrailers(H, False, Dst));
    AssertEquals('0'#13#10'chunky-trailer: v'#13#10'x-foo-bar: w'#13#10#13#10, BytesStr(Dst));
    AssertTrue(E.EncodeTrailers(H, True, Dst));
    AssertEquals('0'#13#10'Chunky-Trailer: v'#13#10'X-Foo-Bar: w'#13#10#13#10, BytesStr(Dst));
    // an empty value is written as "name: \r\n"
    H.Clear;
    H.Add('a', '');
    E := TEncoder.Chunked;
    E.IntoChunkedWithTrailingFields(['a']);
    AssertTrue(E.EncodeTrailers(H, False, Dst));
    AssertEquals('0'#13#10'a: '#13#10#13#10, BytesStr(Dst));
    // no trailers at all: None
    H.Clear;
    AssertFalse(E.EncodeTrailers(H, False, Dst));
    AssertFalse(E.EncodeTrailers(nil, False, Dst));
    // non-chunked encoders: None (into_chunked_with_trailing_fields is a no-op)
    H.Add('a', '1');
    E := TEncoder.Length(10);
    E.IntoChunkedWithTrailingFields(['a']);
    AssertFalse(E.EncodeTrailers(H, False, Dst));
    E := TEncoder.CloseDelimited;
    E.IntoChunkedWithTrailingFields(['a']);
    AssertFalse(E.EncodeTrailers(H, False, Dst));
  finally
    H.Free;
  end;
end;

procedure TTestCodecExtra.Extra_encode_trailer_header_lines;
var
  E: TEncoder;
  H: THttpHeaders;
  Dst: TBytes;

  procedure Line(const V: RawByteString);
  begin
    E.IntoChunkedWithTrailerHeader(PByte(Pointer(V)), Length(V));
  end;

begin
  H := THttpHeaders.Create;
  try
    H.Add('a', '1');
    H.Add('b', '2');
    H.Add('c', '3');
    H.Add('d', '4');
    // hyper role.rs: each Trailer line extends the list
    E := TEncoder.Chunked;
    Line('a');
    Line(' b ,c');
    AssertTrue(E.EncodeTrailers(H, False, Dst));
    AssertEquals('0'#13#10'a: 1'#13#10'b: 2'#13#10'c: 3'#13#10#13#10, BytesStr(Dst));
    // a line that fails HeaderValue::to_str is ignored entirely
    E := TEncoder.Chunked;
    Line('a');
    Line('d, x'#$80);
    AssertTrue(E.EncodeTrailers(H, False, Dst));
    AssertEquals('0'#13#10'a: 1'#13#10#13#10, BytesStr(Dst));
    // only to_str-failing lines: allowed_trailer_fields stays None
    E := TEncoder.Chunked;
    Line('a'#$80);
    AssertFalse(E.EncodeTrailers(H, False, Dst));
    // items that are not valid header names are dropped. The list itself
    // holds the invalid names only through AddTrusted (M3 S0: Add raises;
    // twin test: test_headers_validate Twin_codec_extra_invalid_names).
    H.AddTrusted('e f', '5');
    H.AddTrusted('g@', '6');
    E := TEncoder.Chunked;
    Line('e f, g@, d');
    AssertTrue(E.EncodeTrailers(H, False, Dst));
    AssertEquals('0'#13#10'd: 4'#13#10#13#10, BytesStr(Dst));
    // an empty Trailer value: Some(vec![]) -> nothing to write
    E := TEncoder.Chunked;
    Line('');
    AssertFalse(E.EncodeTrailers(H, False, Dst));
  finally
    H.Free;
  end;
end;

{ ---- headers ---- }

function V(const S: RawByteString): PByte;
begin
  Result := PByte(Pointer(S));
end;

procedure TTestCodecExtra.Extra_headers_list_value_edges;
begin
  // connection_has: to_str, split(','), trim, eq_ignore_ascii_case
  AssertTrue(ConnectionClose(V(',close'), 6));
  AssertTrue(ConnectionClose(V('close,'), 6));
  AssertTrue(ConnectionClose(V(#9'close'#9), 7));
  AssertFalse(ConnectionClose(V(',,'), 2));
  AssertFalse(ConnectionClose(nil, 0));
  AssertFalse(ConnectionClose(V('clo se'), 6));
  AssertFalse(ConnectionClose(V('close'#$80), 6));
  AssertFalse(ConnectionKeepAlive(V('keep-alive;q=1'), 14));
  // is_chunked_: rsplit(',').next(), trim, eq_ignore_ascii_case
  AssertFalse(IsChunkedValue(V('chunked,'), 8));
  AssertTrue(IsChunkedValue(V(',chunked'), 8));
  AssertTrue(IsChunkedValue(V('CHUNKED'), 7));
  AssertTrue(IsChunkedValue(V('gzip,chunked'), 12));
  AssertTrue(IsChunkedValue(V(' chunked '), 9));
  AssertFalse(IsChunkedValue(V('chunked'#$80), 8));
  // HeaderName::from_bytes
  AssertTrue(IsValidHeaderName(V('x-A_b.c~!#$%&''*+^`|'), 19));
  AssertFalse(IsValidHeaderName(nil, 0));
  AssertFalse(IsValidHeaderName(V('a b'), 3));
  AssertFalse(IsValidHeaderName(V('a:'), 2));
  AssertFalse(IsValidHeaderName(V('a'#$80), 2));
end;

procedure TTestCodecExtra.Extra_headers_content_length_edges;
var
  H: THttpHeaders;
  N: QWord;

  function All(const Lines: array of RawByteString): string;
  var
    I: Integer;
  begin
    H.Clear;
    for I := 0 to High(Lines) do
      H.Add('content-length', Lines[I]);
    if ContentLengthParseAll(H, N) then
      Result := IntToStr(N)
    else
      Result := 'None';
  end;

begin
  H := THttpHeaders.Create;
  try
    // content_length_parse_all_values
    AssertEquals('18446744073709551615', All(['18446744073709551615']));
    AssertEquals('None', All(['18446744073709551616']));
    AssertEquals('None', All(['99999999999999999999']));
    AssertEquals('5', All(['5', '5, 5', #9'5 ']));
    AssertEquals('None', All(['5', '']));
    AssertEquals('None', All(['5', '6']));
    AssertEquals('None', All(['5,']));
    AssertEquals('0', All(['00']));
    AssertEquals('None', All(['+5']));
    AssertEquals('None', All(['5'#$80]));
    AssertEquals('None', All([]));
  finally
    H.Free;
  end;
  // content_length_parse: raw from_digits
  AssertTrue(ContentLengthParse(V('0'), 1, N));
  AssertTrue(N = 0);
  AssertFalse(ContentLengthParse(V('5 '), 2, N));
  AssertFalse(ContentLengthParse(V('5,5'), 3, N));
  AssertFalse(ContentLengthParse(V('-0'), 2, N));
end;

procedure TTestCodecExtra.Extra_headers_copy_from_same_list;
var
  H: THttpHeaders;
  Big: RawByteString;
  OkAdd, OkSet, OkInsert, OkName: Boolean;
begin
  // Add / SetValue / Insert given NamePtr/ValuePtr of the same list: the
  // arena grows during the copy and must not read its freed old block.
  // The poisoning memory manager makes a stale read visible.
  Big := StringOfChar('q', 5000);
  H := THttpHeaders.Create(2, 16);
  try
    StartPoisoning;
    try
      H.Add('a', Big);
      H.Add(H.NamePtr(0), H.NameLen(0), H.ValuePtr(0), H.ValueLen(0));
      OkAdd := (H.Count = 2) and (H.ValueLen(1) = 5000) and
        (CompareByte(H.ValuePtr(1)^, Big[1], 5000) = 0);
      OkName := (H.NameLen(1) = 1) and (H.NamePtr(1)^ = Ord('a'));
      H.Add('b', 'x');
      H.SetValue(2, H.ValuePtr(1), H.ValueLen(1));
      OkSet := (H.ValueLen(2) = 5000) and (CompareByte(H.ValuePtr(2)^, Big[1], 5000) = 0);
      H.Insert(H.NamePtr(2), H.NameLen(2), H.ValuePtr(0), H.ValueLen(0));
      OkInsert := (H.ValueLen(2) = 5000) and (CompareByte(H.ValuePtr(2)^, Big[1], 5000) = 0);
    finally
      StopPoisoning;
    end;
    AssertTrue('Add from same list', OkAdd);
    AssertTrue('Add from same list: name', OkName);
    AssertTrue('SetValue from same list', OkSet);
    AssertTrue('Insert from same list', OkInsert);
  finally
    H.Free;
  end;
end;

{ ---- date, reason ---- }

procedure TTestCodecExtra.DoFormatNegative;
begin
  FormatHttpDateStr(-1);
end;

procedure TTestCodecExtra.DoFormatYear10000;
begin
  FormatHttpDateStr(253402300800);
end;

procedure TTestCodecExtra.Extra_date_boundaries;
var
  C: TDateCache;
begin
  // reference values: Python email.utils.formatdate(t, usegmt=True)
  AssertEquals('Tue, 29 Feb 2000 00:00:00 GMT', FormatHttpDateStr(951782400));
  AssertEquals('Sun, 28 Feb 2100 23:59:59 GMT', FormatHttpDateStr(4107542399));
  AssertEquals('Mon, 01 Mar 2100 00:00:00 GMT', FormatHttpDateStr(4107542400));
  AssertEquals('Tue, 29 Feb 2400 12:00:00 GMT', FormatHttpDateStr(13574606400));
  AssertEquals('Fri, 31 Dec 1999 23:59:59 GMT', FormatHttpDateStr(946684799));
  AssertEquals('Tue, 19 Jan 2038 03:14:08 GMT', FormatHttpDateStr(2147483648));
  AssertEquals('Thu, 01 Jan 1970 00:00:59 GMT', FormatHttpDateStr(59));
  // httpdate panics before the epoch and from year 10000
  AssertException(ERangeError, @DoFormatNegative);
  AssertException(ERangeError, @DoFormatYear10000);
  // update(now) on a whole second: next update one second later
  C.Update(Int64(951782400) * 1000000);
  AssertEquals(Int64(951782401) * 1000000, C.NextUpdateUs);
end;

procedure TTestCodecExtra.Extra_reason_every_byte;
var
  B, Bad: Byte;
  R: TReasonPhrase;
  S: RawByteString;
  Want: Boolean;
begin
  // hyper is_valid_byte: HTAB, SP, VCHAR 0x21..0x7E, obs-text 0x80..0xFF
  for B := 0 to 255 do
  begin
    S := 'a' + AnsiChar(B) + 'b';
    Want := (B = 9) or (B = 32) or ((B >= $21) and (B <= $7E)) or (B >= $80);
    AssertEquals(Format('byte %d', [B]), Want, TReasonPhrase.TryFrom(S, R, Bad));
    if not Want then
      AssertEquals(B, Bad);
  end;
  // find_invalid_byte reports the first invalid byte
  AssertFalse(TReasonPhrase.TryFrom('ok'#1#2, R, Bad));
  AssertEquals(1, Bad);
end;

{ ---- hot paths ---- }

procedure TTestCodecExtra.Extra_hot_paths_do_not_allocate;
const
  CHUNKED_BODY: RawByteString = '5;name=value'#13#10'hello'#13#10'A '#13#10'0123456789'#13#10 +
    '0'#13#10#13#10;
  TRAILER_BODY: RawByteString = '3'#13#10'abc'#13#10'0'#13#10'Expires: never'#13#10'X-A: b'#13#10#13#10;
var
  D: TDecoder;
  R: TDecodeResult;
  E: TEncoder;
  B: TEncodedBuf;
  Vec: array[0..2] of TIoSlice;
  Body, Out1: RawByteString;
  OutBuf: array[0..8191] of Byte;
  T, H: THttpHeaders;
  Dc: TDateCache;
  Iter, Pos, Step: Integer;
  St: TDecodeStatus;
  NotEof, N: QWord;
  P: PAnsiChar;
  PL: SizeInt;
  VP: PByte;
  Bad: Byte;
  Sink: SizeInt;
  Counts: array[0..5] of SizeInt;
  Err: TDecodeError;

  procedure FeedAll(const S: RawByteString; Trailers: THttpHeaders; ChunkLen: Integer);
  begin
    Pos := 0;
    repeat
      Step := Length(S) - Pos;
      if Step > ChunkLen then Step := ChunkLen;
      St := D.Decode(PByte(Pointer(S)) + Pos, Step, Pos + Step >= Length(S), Trailers, R);
      Inc(Sink, R.DataLen);
      Inc(Pos, R.Consumed);
    until St in [dsEnd, dsError];
  end;

begin
  Sink := 0;
  SetLength(Body, 1024);
  FillChar(Body[1], 1024, Ord('z'));
  T := THttpHeaders.Create;
  H := THttpHeaders.Create;
  try
    H.Add('Host', 'example.com');
    H.Add('Connection', 'keep-alive, Upgrade');
    H.Add('Content-Length', '1024');
    H.Add('TE', 'gzip, trailers');
    H.Add('Transfer-Encoding', 'gzip, chunked');
    // warm up the trailer paths once so buffers reach their capacity
    D.InitChunked;
    FeedAll(TRAILER_BODY, T, 7);
    AssertTrue('warm-up trailers', St = dsEnd);
    ParseTrailers(PByte(Pointer(TRAILER_BODY)) + 11, Length(TRAILER_BODY) - 11, 2, T, Err);
    Dc.Update(UnixTimeMicros);
    DateUpdate;

    // the counter itself: a string concatenation must be counted
    Out1 := 'x';
    StartCounting;
    Out1 := Out1 + IntToStr(Sink);
    AssertTrue('counting memory manager sees allocations', StopCounting > 0);

    // 0: decoder, Length / Chunked (with extensions and LWS) / Eof, odd splits
    StartCounting;
    for Iter := 1 to 200 do
    begin
      D.InitLength(1024);
      FeedAll(Body, nil, 7);
      D.InitChunked;
      FeedAll(CHUNKED_BODY, nil, 3);
      D.InitChunked;
      FeedAll(CHUNKED_BODY, nil, 1000);
      D.InitEof;
      D.Decode(PByte(Pointer(Body)), 100, False, R);
      D.Decode(nil, 0, True, R);
    end;
    Counts[0] := StopCounting;

    // 1: decoder with trailers, reusing the decoder and the trailers list
    StartCounting;
    for Iter := 1 to 200 do
    begin
      D.InitChunked;
      FeedAll(TRAILER_BODY, T, 5);
    end;
    Counts[1] := StopCounting;

    // 2: encoder, all kinds, iovecs, copies, partial writes
    StartCounting;
    for Iter := 1 to 200 do
    begin
      E := TEncoder.Chunked;
      E.Encode(PByte(Pointer(Body)), 1024, B);
      B.FillIoVec(@Vec[0], 3);
      B.Advance(10);
      Inc(Sink, B.CopyTo(@OutBuf[0]));
      E.EncodeAndEnd(PByte(Pointer(Body)), 1024, B);
      Inc(Sink, B.CopyTo(@OutBuf[0]));
      E.Finish(B, NotEof);
      E := TEncoder.Length(2000);
      E.Encode(PByte(Pointer(Body)), 1024, B);
      E.Encode(PByte(Pointer(Body)), 1024, B);
      E.Finish(B, NotEof);
      E := TEncoder.CloseDelimited;
      E.Encode(PByte(Pointer(Body)), 1024, B);
      Inc(Sink, B.FillIoVec(@Vec[0], 3));
    end;
    Counts[2] := StopCounting;

    // 3: date cache
    StartCounting;
    for Iter := 1 to 200 do
    begin
      Dc.Check(Int64(1700000000 + Iter) * 1000000 + 1);
      Dc.CopyTo(@OutBuf[0]);
      DateUpdate;
      DateExtend(@OutBuf[0]);
    end;
    Counts[3] := StopCounting;

    // 4: header helpers and lookups on an existing list
    StartCounting;
    for Iter := 1 to 200 do
    begin
      Inc(Sink, Ord(ConnectionKeepAlive(H.ValuePtr(1), H.ValueLen(1))));
      Inc(Sink, Ord(ConnectionAnyClose(H)));
      Inc(Sink, Ord(TeIsTrailers(H)));
      Inc(Sink, Ord(ContentLengthParseAll(H, N)));
      Inc(Sink, Ord(TransferEncodingIsChunked(H)));
      Inc(Sink, Ord(H.Get('content-length', VP, PL)));
      Inc(Sink, H.IndexOf('host'));
      Inc(Sink, H.WriteTo(@OutBuf[0], hncTitle));
      Inc(Sink, Ord(CanonicalReason(404, P, PL)));
      Inc(Sink, Ord(FindInvalidReasonByte(V('Not Found'), 9, Bad)));
    end;
    Counts[4] := StopCounting;

    // 5: refilling a cleared list (steady state of a per-connection list)
    StartCounting;
    for Iter := 1 to 200 do
    begin
      T.Clear;
      T.Add(PByte(PAnsiChar('Expires')), 7, PByte(PAnsiChar('never')), 5);
      T.Add(PByte(PAnsiChar('content-length')), 14, PByte(PAnsiChar('1024')), 4);
      ParseTrailers(PByte(Pointer(TRAILER_BODY)) + 11, Length(TRAILER_BODY) - 11, 2, T, Err);
    end;
    Counts[5] := StopCounting;
  finally
    H.Free;
    T.Free;
  end;
  Out1 := Format('decode %d, decode+trailers %d, encode %d, date %d, headers %d, list refill %d',
    [Counts[0], Counts[1], Counts[2], Counts[3], Counts[4], Counts[5]]);
  AssertTrue('allocations: ' + Out1, Sink <> 0);
  AssertEquals('decoder allocations: ' + Out1, 0, Counts[0]);
  AssertEquals('decoder with trailers allocations: ' + Out1, 0, Counts[1]);
  AssertEquals('encoder allocations: ' + Out1, 0, Counts[2]);
  AssertEquals('date allocations: ' + Out1, 0, Counts[3]);
  AssertEquals('header helper allocations: ' + Out1, 0, Counts[4]);
  AssertEquals('list refill allocations: ' + Out1, 0, Counts[5]);
end;

initialization
  RegisterTest(TTestCodecExtra);
end.

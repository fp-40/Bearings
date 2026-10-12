{ Ports of the tests in hyper v1.12.0 src/common/date.rs (1),
  src/ext/h1_reason_phrase.rs (7) and src/headers.rs (3).
  Test_wd_<name> methods are extra tests of this port's own API. }
unit test_codec_misc;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpcunit, testregistry,
  bearings.http.headers, bearings.http.date, bearings.http1.reason;

type
  TTestDate = class(TTestCase)
  published
    procedure Test_date_len;
    { extra: httpdate known values and the once-per-second cache }
    procedure Test_wd_format_known_values;
    procedure Test_wd_cache_rerenders_once_per_second;
    procedure Test_wd_thread_local_cache;
  end;

  TTestReasonPhrase = class(TTestCase)
  private
    procedure DoNewlineFromStatic;
    procedure DoCrFromStatic;
  published
    procedure Test_basic_valid;
    procedure Test_empty_valid;
    procedure Test_obs_text_valid;
    procedure Test_newline_invalid_panic;
    procedure Test_newline_invalid_err;
    procedure Test_cr_invalid_panic;
    procedure Test_cr_invalid_err;
    procedure Test_wd_canonical_reason;
  end;

  TTestHeaders = class(TTestCase)
  published
    procedure Test_te_is_trailers_accepts_comma_separated_values;
    procedure Test_te_is_trailers_accepts_multiple_header_lines;
    procedure Test_te_is_trailers_rejects_missing_trailers_token;
    { extra }
    procedure Test_wd_ordered_case_preserving_list;
    procedure Test_wd_external_slices;
    procedure Test_wd_write_name_cases;
    procedure Test_wd_connection_helpers;
    procedure Test_wd_content_length_helpers;
    procedure Test_wd_transfer_encoding_helpers;
  end;

implementation

{ ---- date ---- }

procedure TTestDate.Test_date_len;
begin
  AssertEquals(DATE_VALUE_LENGTH, Length('Sun, 06 Nov 1994 08:49:37 GMT'));
end;

procedure TTestDate.Test_wd_format_known_values;
begin
  AssertEquals('Sun, 06 Nov 1994 08:49:37 GMT', FormatHttpDateStr(784111777));
  AssertEquals('Sun, 02 Oct 2016 14:44:11 GMT', FormatHttpDateStr(1475419451));
  AssertEquals('Thu, 01 Jan 1970 00:00:00 GMT', FormatHttpDateStr(0));
  AssertEquals('Tue, 29 Feb 2000 23:59:59 GMT', FormatHttpDateStr(951868799));
  AssertEquals('Fri, 31 Dec 9999 23:59:59 GMT', FormatHttpDateStr(253402300799));
end;

procedure TTestDate.Test_wd_cache_rerenders_once_per_second;
var
  C: TDateCache;
  T0: Int64;
begin
  T0 := Int64(784111777) * 1000000 + 250000; // .25 s into the second
  C.Update(T0);
  AssertEquals('Sun, 06 Nov 1994 08:49:37 GMT', C.AsString);
  AssertEquals(Int64(784111778) * 1000000, C.NextUpdateUs);
  C.Check(T0 + 700000);                       // .95 s: same second
  AssertEquals('Sun, 06 Nov 1994 08:49:37 GMT', C.AsString);
  C.Check(Int64(784111778) * 1000000);        // exactly at next_update: hyper uses '>'
  AssertEquals('Sun, 06 Nov 1994 08:49:37 GMT', C.AsString);
  C.Check(Int64(784111778) * 1000000 + 1);
  AssertEquals('Sun, 06 Nov 1994 08:49:38 GMT', C.AsString);
end;

procedure TTestDate.Test_wd_thread_local_cache;
var
  B: array[0..DATE_VALUE_LENGTH - 1] of Byte;
  S: RawByteString;
begin
  DateUpdate;
  DateExtend(@B[0]);
  SetLength(S, DATE_VALUE_LENGTH);
  Move(B[0], S[1], DATE_VALUE_LENGTH);
  AssertEquals(' GMT', Copy(S, 26, 4));
  AssertEquals(', ', Copy(S, 4, 2));
  AssertTrue(CompareByte(DateBuffer^, B[0], DATE_VALUE_LENGTH) = 0);
end;

{ ---- reason phrase ---- }

procedure TTestReasonPhrase.Test_basic_valid;
const
  PHRASE = 'OK';
var
  R: TReasonPhrase;
begin
  AssertEquals(PHRASE, TReasonPhrase.FromStatic(PHRASE).AsBytes);
  AssertTrue(TReasonPhrase.TryFrom(PHRASE, R));
  AssertEquals(PHRASE, R.AsBytes);
end;

procedure TTestReasonPhrase.Test_empty_valid;
const
  PHRASE = '';
var
  R: TReasonPhrase;
begin
  AssertEquals(PHRASE, TReasonPhrase.FromStatic(PHRASE).AsBytes);
  AssertTrue(TReasonPhrase.TryFrom(PHRASE, R));
  AssertEquals(PHRASE, R.AsBytes);
end;

procedure TTestReasonPhrase.Test_obs_text_valid;
const
  PHRASE: RawByteString = 'hyp'#$E9'r';
var
  R: TReasonPhrase;
begin
  AssertTrue(TReasonPhrase.FromStatic(PHRASE).AsBytes = PHRASE);
  AssertTrue(TReasonPhrase.TryFrom(PHRASE, R));
  AssertTrue(R.AsBytes = PHRASE);
  AssertEquals(5, R.Len);
end;

procedure TTestReasonPhrase.DoNewlineFromStatic;
begin
  TReasonPhrase.FromStatic('hyp'#10'er');
end;

procedure TTestReasonPhrase.DoCrFromStatic;
begin
  TReasonPhrase.FromStatic('hyp'#13'er');
end;

procedure TTestReasonPhrase.Test_newline_invalid_panic;
begin
  // #[should_panic] -> FromStatic raises EInvalidReasonPhrase
  AssertException(EInvalidReasonPhrase, @DoNewlineFromStatic);
end;

procedure TTestReasonPhrase.Test_newline_invalid_err;
var
  R: TReasonPhrase;
  Bad: Byte;
begin
  AssertFalse(TReasonPhrase.TryFrom('hyp'#10'er', R, Bad));
  AssertEquals(10, Bad);
end;

procedure TTestReasonPhrase.Test_cr_invalid_panic;
begin
  AssertException(EInvalidReasonPhrase, @DoCrFromStatic);
end;

procedure TTestReasonPhrase.Test_cr_invalid_err;
var
  R: TReasonPhrase;
  Bad: Byte;
begin
  AssertFalse(TReasonPhrase.TryFrom('hyp'#13'er', R, Bad));
  AssertEquals(13, Bad);
end;

procedure TTestReasonPhrase.Test_wd_canonical_reason;
var
  P: PAnsiChar;
  L: SizeInt;
begin
  AssertTrue(CanonicalReason(200, P, L));
  AssertEquals(2, L);
  AssertEquals('OK', Copy(StrPas(P), 1, L));
  AssertEquals('Non Authoritative Information', CanonicalReasonStr(203));
  AssertEquals('I''m a teapot', CanonicalReasonStr(418));
  AssertEquals('Network Authentication Required', CanonicalReasonStr(511));
  AssertFalse(CanonicalReason(299, P, L));
  AssertEquals('', CanonicalReasonStr(600));
end;

{ ---- headers.rs ---- }

procedure TTestHeaders.Test_te_is_trailers_accepts_comma_separated_values;
var
  H: THttpHeaders;
begin
  H := THttpHeaders.Create;
  try
    H.Insert(HN_TE, 'gzip, Trailers');
    AssertTrue(TeIsTrailers(H));
  finally
    H.Free;
  end;
end;

procedure TTestHeaders.Test_te_is_trailers_accepts_multiple_header_lines;
var
  H: THttpHeaders;
begin
  H := THttpHeaders.Create;
  try
    H.Append(HN_TE, 'gzip');
    H.Append(HN_TE, 'trailers');
    AssertTrue(TeIsTrailers(H));
  finally
    H.Free;
  end;
end;

procedure TTestHeaders.Test_te_is_trailers_rejects_missing_trailers_token;
var
  H: THttpHeaders;
begin
  H := THttpHeaders.Create;
  try
    H.Insert(HN_TE, 'gzip');
    AssertFalse(TeIsTrailers(H));
  finally
    H.Free;
  end;
end;

{ ---- extra ---- }

procedure TTestHeaders.Test_wd_ordered_case_preserving_list;
var
  H: THttpHeaders;
  I: Integer;
begin
  H := THttpHeaders.Create(1, 16);
  try
    H.Add('Content-Type', 'text/plain');
    H.Add('X-Custom', 'a');
    H.Add('x-custom', 'b');
    H.Add('Host', 'example.com');
    AssertEquals(4, H.Count);
    AssertEquals('Content-Type', H.Name(0));
    AssertEquals('x-custom', H.Name(2));
    AssertEquals(1, H.IndexOf('X-CUSTOM'));
    AssertEquals(2, H.IndexOf('X-CUSTOM', 2));
    AssertEquals(-1, H.IndexOf('X-CUSTOM', 3));
    AssertEquals(2, H.CountOf('x-Custom'));
    AssertEquals('text/plain', H.GetValue('content-type'));
    // HeaderMap::insert: first keeps its position, later ones are removed
    H.Insert('X-CUSTOM', 'c');
    AssertEquals(3, H.Count);
    AssertEquals('X-Custom', H.Name(1));
    AssertEquals('c', H.Value(1));
    AssertEquals('Host', H.Name(2));
    AssertEquals(1, H.Remove('host'));
    AssertEquals(2, H.Count);
    // growth of entries and arena keeps content
    for I := 0 to 199 do
      H.Add('n' + IntToStr(I), StringOfChar('v', I));
    AssertEquals(202, H.Count);
    AssertEquals(StringOfChar('v', 150), H.GetValue('N150'));
    H.Clear;
    AssertEquals(0, H.Count);
    AssertFalse(H.Contains('content-type'));
  finally
    H.Free;
  end;
end;

procedure TTestHeaders.Test_wd_external_slices;
var
  H: THttpHeaders;
  Buf, Copy2: RawByteString;
begin
  Buf := 'Host: a'#13#10'Accept: */*'#13#10;
  H := THttpHeaders.Create;
  try
    H.SetExternalBase(PByte(Pointer(Buf)));
    H.AddExternal(0, 4, 6, 1);
    H.AddExternal(9, 6, 17, 3);
    AssertEquals('Host', H.Name(0));
    AssertEquals('*/*', H.GetValue('accept'));
    AssertTrue('no copy', H.ValuePtr(1) = PByte(Pointer(Buf)) + 17);
    // the caller moves the bytes: rebase
    Copy2 := Buf;
    UniqueString(Copy2);
    H.SetExternalBase(PByte(Pointer(Copy2)));
    AssertEquals('a', H.GetValue('host'));
    // detach copies into the arena; the external buffer can then be reused
    H.Detach;
    FillChar(Copy2[1], Length(Copy2), Ord('#'));
    AssertEquals('a', H.GetValue('host'));
    AssertEquals('Accept', H.Name(1));
  finally
    H.Free;
  end;
end;

procedure TTestHeaders.Test_wd_write_name_cases;
var
  H: THttpHeaders;
  B: TBytes;
  L: SizeInt;

  function Str: RawByteString;
  begin
    SetLength(Result, L);
    if L > 0 then Move(B[0], Result[1], L);
  end;

begin
  H := THttpHeaders.Create;
  try
    H.Add('X-FOO-bar', 'v1');
    H.Add('content-length', '0');
    L := 0;
    H.AppendTo(B, L, hncLower);
    AssertEquals('x-foo-bar: v1'#13#10'content-length: 0'#13#10, Str);
    AssertEquals(L, H.WireLength);
    L := 0;
    H.AppendTo(B, L, hncTitle);
    AssertEquals('X-Foo-Bar: v1'#13#10'Content-Length: 0'#13#10, Str);
    L := 0;
    H.AppendTo(B, L, hncAsIs);
    AssertEquals('X-FOO-bar: v1'#13#10'content-length: 0'#13#10, Str);
  finally
    H.Free;
  end;
end;

function VS(const S: RawByteString): PByte; inline;
begin
  Result := PByte(Pointer(S));
end;

procedure TTestHeaders.Test_wd_connection_helpers;
var
  H: THttpHeaders;
begin
  AssertTrue(ConnectionClose(VS('close'), 5));
  AssertTrue(ConnectionClose(VS('Upgrade, CLOSE '), 15));
  AssertFalse(ConnectionClose(VS('closed'), 6));
  AssertTrue(ConnectionKeepAlive(VS(' keep-alive'), 11));
  AssertFalse(ConnectionKeepAlive(VS('keep-alive'#$80), 11)); // to_str fails on obs-text
  H := THttpHeaders.Create;
  try
    H.Add('Connection', 'keep-alive');
    AssertFalse(ConnectionAnyClose(H));
    H.Add('connection', 'upgrade, close');
    AssertTrue(ConnectionAnyClose(H));
  finally
    H.Free;
  end;
end;

procedure TTestHeaders.Test_wd_content_length_helpers;
var
  H: THttpHeaders;
  N: QWord;
begin
  AssertTrue(FromDigits(VS('18446744073709551615'), 20, N));
  AssertTrue(N = High(QWord));
  AssertFalse(FromDigits(VS('18446744073709551616'), 20, N));
  AssertFalse(FromDigits(VS('+5'), 2, N));
  AssertFalse(FromDigits(VS(''), 0, N));
  AssertFalse(ContentLengthParse(VS(' 5'), 2, N)); // raw: no trim
  H := THttpHeaders.Create;
  try
    AssertFalse(ContentLengthParseAll(H, N));      // none present
    H.Add('Content-Length', '10');
    AssertTrue(ContentLengthParseAll(H, N));
    AssertEquals(10, N);
    H.Add('content-length', ' 10 , 10');
    AssertTrue(ContentLengthParseAll(H, N));
    AssertEquals(10, N);
    H.Add('content-length', '11');
    AssertFalse(ContentLengthParseAll(H, N));      // mismatch
    H.Clear;
    H.Add('content-length', '10,');
    AssertFalse(ContentLengthParseAll(H, N));      // empty item
  finally
    H.Free;
  end;
end;

procedure TTestHeaders.Test_wd_transfer_encoding_helpers;
var
  H: THttpHeaders;
begin
  AssertTrue(IsChunkedValue(VS('chunked'), 7));
  AssertTrue(IsChunkedValue(VS('gzip, Chunked '), 14));
  AssertFalse(IsChunkedValue(VS('chunked, gzip'), 13));
  AssertFalse(IsChunkedValue(VS(''), 0));
  H := THttpHeaders.Create;
  try
    AssertFalse(TransferEncodingIsChunked(H));
    H.Add('Transfer-Encoding', 'chunked');
    H.Add('transfer-encoding', 'gzip');
    AssertFalse('only the last line counts', TransferEncodingIsChunked(H));
    H.Add('transfer-encoding', 'gzip, chunked');
    AssertTrue(TransferEncodingIsChunked(H));
  finally
    H.Free;
  end;
end;

initialization
  RegisterTest(TTestDate);
  RegisterTest(TTestReasonPhrase);
  RegisterTest(TTestHeaders);
end.

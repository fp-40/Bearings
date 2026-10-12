{ Differential test of bearings.http1.role's request parsing (and bearings.http.uri)
  against hyper v1.12.0's own Server::parse and http::Uri: which requests
  are accepted, with which framing (request smuggling). Step T1 removed the
  Server::encode cases (response encoding is checked by the fixed
  expectations of test_role_verify / test_role_extra).

  test_role_diff_rs (test tooling, Rust) writes role_cases.txt and hyper's
  results to role_expected.txt; this program replays every case through
  ServerParse / ServerEncode, formats the result the same way and compares.
  Usage: test_role_diff <dir> [--guard]
    --guard: each request is copied so that it ends exactly at a
             PROT_NONE page, so a read past the end of the buffer crashes.
  Exit code 0 only if every case matches. See test_role_diff.sh. }
program test_role_diff;

{$mode objfpc}{$H+}

uses
  SysUtils, Classes, BaseUnix,
  bearings.http1.parser, bearings.http.headers, bearings.http.uri, bearings.http1.role;

var
  Guard: Boolean = False;
  GuardBase: PByte = nil;
  GuardSize: SizeInt = 0;

function Hex(P: PByte; Len: SizeInt): RawByteString;
const
  D: array[0..15] of AnsiChar = '0123456789abcdef';
var
  I: SizeInt;
  B: Byte;
begin
  if Len = 0 then
    Exit('-');
  SetLength(Result, Len * 2);
  for I := 0 to Len - 1 do
  begin
    { one byte load: FPC 3.2.2 -O2 compiles D[P[I] and 15] as a 16-bit
      load, which reads past the end of the input }
    B := P[I];
    Result[2 * I + 1] := D[B shr 4];
    Result[2 * I + 2] := D[B and 15];
  end;
end;

function HexS(const S: RawByteString): RawByteString;
begin
  Result := Hex(PByte(Pointer(S)), Length(S));
end;

function Unhex(const S: RawByteString): RawByteString;
var
  I: SizeInt;
begin
  if S = '-' then
    Exit('');
  SetLength(Result, Length(S) div 2);
  for I := 1 to Length(S) div 2 do
    Result[I] := AnsiChar(StrToInt('$' + Copy(S, 2 * I - 1, 2)));
end;

procedure Split(const S: RawByteString; Sep: AnsiChar; L: TStrings);
var
  I, St: Integer;
begin
  L.Clear;
  St := 1;
  for I := 1 to Length(S) + 1 do
    if (I > Length(S)) or (S[I] = Sep) then
    begin
      L.Add(Copy(S, St, I - St));
      St := I + 1;
    end;
end;

{ A buffer holding Data that ends at a PROT_NONE page (in --guard mode). }
function PlaceBuffer(const Data: RawByteString): PByte;
var
  Need, Page: SizeInt;
begin
  if not Guard then
    Exit(PByte(Pointer(Data)));
  Page := 4096;
  Need := ((Length(Data) + Page - 1) div Page + 1) * Page;
  if Need > GuardSize then
  begin
    if GuardBase <> nil then
      Fpmunmap(GuardBase, GuardSize);
    GuardBase := Fpmmap(nil, Need, PROT_READ or PROT_WRITE, MAP_PRIVATE or MAP_ANONYMOUS, -1, 0);
    if GuardBase = Pointer(-1) then
      raise Exception.Create('mmap failed');
    GuardSize := Need;
  end;
  Fpmprotect(GuardBase, GuardSize, PROT_READ or PROT_WRITE);
  Fpmprotect(GuardBase + GuardSize - Page, Page, PROT_NONE);
  Result := GuardBase + GuardSize - Page - Length(Data);
  if Length(Data) > 0 then
    Move(Pointer(Data)^, Result^, Length(Data));
end;

function ErrName(E: TH1ParseError): RawByteString;
begin
  case E of
    h1peMethod: Result := 'Method';
    h1peVersion: Result := 'Version';
    h1peVersionH2: Result := 'VersionH2';
    h1peUri: Result := 'Uri';
    h1peUriTooLong: Result := 'UriTooLong';
    h1peHeaderToken: Result := 'Header(Token)';
    h1peHeaderContentLengthInvalid: Result := 'Header(ContentLengthInvalid)';
    h1peHeaderTransferEncodingInvalid: Result := 'Header(TransferEncodingInvalid)';
    h1peHeaderTransferEncodingUnexpected: Result := 'Header(TransferEncodingUnexpected)';
    h1peTooLarge: Result := 'TooLarge';
    h1peStatus: Result := 'Status';
    h1peInternal: Result := 'Internal';
  else
    Result := '?';
  end;
end;

function LowerS(const S: RawByteString): RawByteString;
var
  I: Integer;
begin
  Result := S;
  UniqueString(Result);
  for I := 1 to Length(Result) do
    Result[I] := AnsiChar(AsciiLower(Byte(Result[I])));
end;

function RunParse(const Fields: TStrings; H: THttpHeaders): RawByteString;
var
  Ctx: TH1ParseContext;
  Req: RawByteString;
  Buf, P: PByte;
  Msg: TParsedRequestHead;
  St: TServerParseStatus;
  Flags, Scheme, Auth, Query, Ver, DecS, Hs: RawByteString;
  L: SizeInt;
  Idx: array of SizeInt;
  I, J, T: SizeInt;
  Ni, Nj: RawByteString;
begin
  Ctx := DefaultParseContext;
  Ctx.MaxHeaders := StrToInt(Fields[1]);
  Ctx.MaxHeaderSize := StrToInt(Fields[2]);
  Flags := Fields[3];
  Ctx.ParserConfig.AllowMultipleSpacesInRequestLineDelimiters := Flags[1] = '1';
  Ctx.ParserConfig.AllowSpaceBeforeFirstHeaderName := Flags[2] = '1';
  Ctx.ParserConfig.IgnoreInvalidHeadersInRequests := Flags[3] = '1';
  Req := Unhex(Fields[4]);
  Buf := PlaceBuffer(Req);
  { hyper's Server::parse is only called with a non-empty buffer }
  if Length(Req) = 0 then
    St := ServerParseHeaders(Buf, 0, -1, Ctx, H, Msg)
  else
    St := ServerParse(Buf, Length(Req), Ctx, H, Msg);
  case St of
    spsPartial: Exit('PARTIAL');
    spsError: Exit('ERR ' + ErrName(Msg.Error));
  end;

  case Msg.Uri.Scheme of
    usNone: Scheme := '~';
    usHttp: Scheme := HexS('http');
    usHttps: Scheme := HexS('https');
    usOther: Scheme := Hex(Buf + Msg.Uri.SchemeOff, Msg.Uri.SchemeLen);
  end;
  if Msg.Uri.HasAuthority then
    Auth := Hex(Buf + Msg.Uri.AuthorityOff, Msg.Uri.AuthorityLen)
  else
    Auth := '~';
  if Msg.Uri.GetQuery(Buf, P, L) then
    Query := Hex(P, L)
  else
    Query := '~';
  if Msg.Version = hv10 then
    Ver := '1.0'
  else
    Ver := '1.1';
  if Msg.Decode = DECODED_LENGTH_CHUNKED then
    DecS := 'CHUNKED'
  else if Msg.Decode = DECODED_LENGTH_CLOSE_DELIMITED then
    DecS := 'CLOSE_DELIMITED'
  else
    DecS := 'DecodedLength(' + IntToStr(Msg.Decode) + ')';

  { headers sorted by lowercase name, stable }
  SetLength(Idx, H.Count);
  for I := 0 to H.Count - 1 do
    Idx[I] := I;
  for I := 1 to H.Count - 1 do
  begin
    T := Idx[I];
    Ni := LowerS(H.Name(T));
    J := I - 1;
    while J >= 0 do
    begin
      Nj := LowerS(H.Name(Idx[J]));
      if Nj <= Ni then
        Break;
      Idx[J + 1] := Idx[J];
      Dec(J);
    end;
    Idx[J + 1] := T;
  end;
  Hs := '';
  for I := 0 to H.Count - 1 do
  begin
    if I > 0 then
      Hs := Hs + ',';
    Hs := Hs + Hex(H.NamePtr(Idx[I]), H.NameLen(Idx[I])) + '=' +
      Hex(H.ValuePtr(Idx[I]), H.ValueLen(Idx[I]));
  end;
  if Hs = '' then
    Hs := '-';

  Msg.Uri.GetPath(Buf, P, L);
  Result := Format('OK %d %s %s %s %s %s %s %s %d %d %d %s',
    [Msg.HeadLen, Hex(Buf + Msg.MethodSlice.Off, Msg.MethodSlice.Len), Scheme, Auth,
     Hex(P, L), Query, Ver, DecS, Ord(Msg.ExpectContinue), Ord(Msg.KeepAlive),
     Ord(Msg.WantsUpgrade), Hs]);
end;

function RunUri(const Fields: TStrings): RawByteString;
var
  T, Scheme, Auth, Query: RawByteString;
  B, P: PByte;
  L: SizeInt;
  U: TUriParts;
  E: TUriError;
begin
  T := Unhex(Fields[1]);
  B := PlaceBuffer(T);
  if not ParseUri(B, Length(T), U, E) then
    Exit('ERR ' + UriErrorDescription(E));
  case U.Scheme of
    usNone: Scheme := '~';
    usHttp: Scheme := HexS('http');
    usHttps: Scheme := HexS('https');
    usOther: Scheme := Hex(B + U.SchemeOff, U.SchemeLen);
  end;
  if U.HasAuthority then
    Auth := Hex(B + U.AuthorityOff, U.AuthorityLen)
  else
    Auth := '~';
  if U.GetQuery(B, P, L) then
    Query := Hex(P, L)
  else
    Query := '~';
  U.GetPath(B, P, L);
  Result := 'OK ' + Scheme + ' ' + Auth + ' ' + Hex(P, L) + ' ' + Query;
end;

var
  Dir: string;
  Cases, Expected: TStringList;
  Fields: TStringList;
  H: THttpHeaders;
  I, Mism, NP, NU: Integer;
  Got: RawByteString;
begin
  if ParamCount < 1 then
  begin
    WriteLn('usage: test_role_diff <dir> [--guard]');
    Halt(2);
  end;
  Dir := IncludeTrailingPathDelimiter(ParamStr(1));
  Guard := (ParamCount >= 2) and (ParamStr(2) = '--guard');
  Cases := TStringList.Create;
  Expected := TStringList.Create;
  Fields := TStringList.Create;
  H := THttpHeaders.Create;
  try
    Cases.LoadFromFile(Dir + 'role_cases.txt');
    Expected.LoadFromFile(Dir + 'role_expected.txt');
    if Cases.Count <> Expected.Count then
    begin
      WriteLn('case/expected line count differ');
      Halt(1);
    end;
    Mism := 0;
    NP := 0;
    NU := 0;
    for I := 0 to Cases.Count - 1 do
    begin
      Split(Cases[I], ' ', Fields);
      try
      if Fields[0] = 'P' then
      begin
        Got := RunParse(Fields, H);
        Inc(NP);
      end
      else if Fields[0] = 'U' then
      begin
        Got := RunUri(Fields);
        Inc(NU);
      end
      else
        Got := 'UNKNOWN CASE KIND ' + Fields[0];
      except
        on E: Exception do
          Got := 'EXCEPTION ' + E.ClassName + ': ' + E.Message;
      end;
      if Got <> Expected[I] then
      begin
        Inc(Mism);
        if Mism <= 15 then
        begin
          WriteLn('MISMATCH line ', I + 1, ': ', Copy(Cases[I], 1, 400));
          WriteLn('  hyper: ', Copy(Expected[I], 1, 400));
          WriteLn('  wd   : ', Copy(Got, 1, 400));
        end;
      end;
    end;
    WriteLn(Format('role diff%s: %d parse + %d uri cases, %d mismatches',
      [BoolToStr(Guard, ' (guard page)', ''), NP, NU, Mism]));
    if Mism > 0 then
      Halt(1);
  finally
    Cases.Free;
    Expected.Free;
    Fields.Free;
    H.Free;
  end;
end.

{ bearings.http.uri - request-target validation and splitting.

  The request-target is the second part of the request line ("GET
  /a/b?x=1 HTTP/1.1"). bearings.http1.parser only checks that it is a run of
  allowed bytes; bearings.http1.role then calls ParseUri on it to check its
  structure and to find its parts. A target ParseUri rejects is answered
  with 400 Bad Request. (A target longer than the limit in bearings.http1.role
  is answered with 414 URI Too Long before ParseUri runs.)

  RFC 9112 section 3.2 defines four forms of request-target:
    "/" or "/..."          origin-form: path and optional query; what
                           browsers send to a server directly
    "*"                    asterisk-form: only for "OPTIONS * HTTP/1.1"
    "host[:port]"          authority-form: only for CONNECT
    "scheme://auth[/...]"  absolute-form: what clients send to a proxy;
                           scheme, authority, path and query
  The query starts at the first '?'. A fragment ('#' and after) is not
  meant to be sent; if present it is cut off from the path and query
  and not validated.

  Zero allocation: the result is a set of (offset, length) slices relative
  to the P passed to ParseUri. Nothing is copied, decoded or lowercased;
  percent-escapes stay as they are.

  Threading: the lookup tables are filled at unit initialization and only
  read afterwards; any thread may call any routine. }
unit bearings.http.uri;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

const
  { Longest target ParseUri accepts (64 KiB - 2). }
  URI_MAX_LEN = 65534;
  { Longest scheme name accepted in an absolute-form target. }
  URI_MAX_SCHEME_LEN = 64;

type
  { Why a target was rejected. ueNone only on success. Some kinds
    (ueInvalidScheme, ueInvalidPort, ueSchemeMissing, ueAuthorityMissing,
    uePathAndQueryMissing) are never returned by ParseUri; they exist so
    UriErrorDescription covers every kind. }
  TUriError = (
    ueNone,
    ueInvalidUriChar,
    ueInvalidScheme,
    ueInvalidAuthority,
    ueInvalidPort,
    ueInvalidFormat,
    ueSchemeMissing,
    ueAuthorityMissing,
    uePathAndQueryMissing,
    uePathDoesNotStartWithSlash,
    ueTooLong,
    ueEmpty,
    ueSchemeTooLong
  );

  { usNone: no scheme (origin, asterisk or authority form). usOther: a
    scheme other than http or https. }
  TUriScheme = (usNone, usHttp, usHttps, usOther);

  { TUriParts: slices of the parsed target, offsets relative to the P given
    to ParseUri (call Shift to rebase them). }
  TUriParts = record
    Scheme: TUriScheme;
    SchemeOff, SchemeLen: SizeInt;   { the scheme bytes without "://"; 0 if usNone }
    AuthorityOff, AuthorityLen: SizeInt;  { AuthorityLen = 0: no authority }
    PathAndQueryOff, PathAndQueryLen: SizeInt;
      { Path and query, fragment removed. Len = 0 with Scheme <> usNone
        means the path "/" (an absolute-form target with nothing after
        the authority, such as "http://example.com"). }
    QueryPos: SizeInt;
      { index of '?' inside PathAndQuery, -1 if there is no query }
    procedure Shift(Delta: SizeInt);
    { The path without the query: '' when there is no path
      (authority-form); '/' when the path part is empty but a path exists
      (an absolute-form target with no path, or with only a query as in
      "http://a?x").
      Base is the buffer the offsets refer to. Out P points into Base or
      at a static '/'. }
    procedure GetPath(Base: PByte; out P: PByte; out Len: SizeInt);
    { The query without the '?'; False if there is none. An empty query
      ("/a?") returns True with Len = 0. }
    function GetQuery(Base: PByte; out P: PByte; out Len: SizeInt): Boolean;
    function HasAuthority: Boolean; inline;
  end;

{ Validates and splits a request-target. Returns True on success. On
  failure U is reset and Err tells why. P may be nil when Len = 0. Reads
  only P[0..Len). Bytes >= 0x80 in the path or query must form valid
  UTF-8. }
function ParseUri(P: PByte; Len: SizeInt; out U: TUriParts; out Err: TUriError): Boolean;

{ A short English description of an error kind, e.g. 'invalid uri character'. }
function UriErrorDescription(E: TUriError): string;

{ True for the bytes allowed in an authority (RFC 3986 unreserved,
  sub-delims, ':', '@', '[', ']', and the delimiters '/', '?', '#' that
  end it). '%' is not in the set; AuthorityParse handles it. }
function IsUriAuthorityChar(B: Byte): Boolean; inline;

implementation

uses
  bearings.http1.parser;   { IsValidUtf8 }

const
  CLASS_VALID = 0;
  CLASS_QUERY = 1;
  CLASS_FRAGMENT = 2;
  CLASS_HIGH = 3;
  CLASS_INVALID = 4;

var
  URI_CHARS: array[Byte] of Byte;      { authority bytes: 0, or the byte itself }
  SCHEME_CHARS: array[Byte] of Byte;   { scheme bytes and ':': 0, or the byte itself }
  PATH_MAP: array[Byte] of Byte;       { CLASS_* of each byte in the path }
  QUERY_MAP: array[Byte] of Byte;      { CLASS_* of each byte in the query }

const
  SLASH: array[0..0] of Byte = (Ord('/'));

procedure InitTables;
const
  UriSet = '!#$&''()*+,-./0123456789:;=?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[]_abcdefghijklmnopqrstuvwxyz~';
  SchemeSet = '+-.0123456789:ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz~';
var
  I: Integer;
begin
  FillChar(URI_CHARS, SizeOf(URI_CHARS), 0);
  FillChar(SCHEME_CHARS, SizeOf(SCHEME_CHARS), 0);
  for I := 1 to Length(UriSet) do
    URI_CHARS[Ord(UriSet[I])] := Ord(UriSet[I]);
  for I := 1 to Length(SchemeSet) do
    SCHEME_CHARS[Ord(SchemeSet[I])] := Ord(SchemeSet[I]);

  for I := 0 to 255 do
  begin
    { path: see https://url.spec.whatwg.org/#path-state. Besides the RFC
      3986 bytes, the double quote and the two curly brackets are
      accepted, as browsers send them unescaped. Control bytes, space,
      '<', '>', '`' and DEL are not. }
    case I of
      Ord('?'): PATH_MAP[I] := CLASS_QUERY;
      Ord('#'): PATH_MAP[I] := CLASS_FRAGMENT;
      $21, $24..$3B, $3D, $40..$5F, $61..$7A, $7C, $7E: PATH_MAP[I] := CLASS_VALID;
      $80..$FF: PATH_MAP[I] := CLASS_HIGH;
      Ord('"'), Ord('{'), Ord('}'): PATH_MAP[I] := CLASS_VALID;
    else
      PATH_MAP[I] := CLASS_INVALID;
    end;
    { query: see https://url.spec.whatwg.org/#query-state. The query also
      accepts every visible ASCII byte except '"', '#', '<' and '>'. }
    case I of
      Ord('#'): QUERY_MAP[I] := CLASS_FRAGMENT;
      $21, $24..$3B, $3D, $3F..$7E: QUERY_MAP[I] := CLASS_VALID;
      $80..$FF: QUERY_MAP[I] := CLASS_HIGH;
    else
      QUERY_MAP[I] := CLASS_INVALID;
    end;
  end;
end;

function IsUriAuthorityChar(B: Byte): Boolean; inline;
begin
  Result := URI_CHARS[B] <> 0;
end;

{ ---- TUriParts ---- }

procedure TUriParts.Shift(Delta: SizeInt);
begin
  Inc(SchemeOff, Delta);
  Inc(AuthorityOff, Delta);
  Inc(PathAndQueryOff, Delta);
end;

procedure TUriParts.GetPath(Base: PByte; out P: PByte; out Len: SizeInt);
begin
  { no path at all: authority-form }
  if (PathAndQueryLen = 0) and (Scheme = usNone) then
  begin
    P := Base + PathAndQueryOff;
    Len := 0;
    Exit;
  end;
  P := Base + PathAndQueryOff;
  if QueryPos >= 0 then
    Len := QueryPos
  else
    Len := PathAndQueryLen;
  if Len = 0 then
  begin
    P := @SLASH[0];
    Len := 1;
  end;
end;

function TUriParts.GetQuery(Base: PByte; out P: PByte; out Len: SizeInt): Boolean;
begin
  Result := QueryPos >= 0;
  if Result then
  begin
    P := Base + PathAndQueryOff + QueryPos + 1;
    Len := PathAndQueryLen - QueryPos - 1;
  end
  else
  begin
    P := nil;
    Len := 0;
  end;
end;

function TUriParts.HasAuthority: Boolean; inline;
begin
  Result := AuthorityLen > 0;
end;

{ ---- scanners ---- }

{ Validates the authority ("user@host:port", "[::1]:8080") at the start
  of S. Returns the end of the authority (index of the first '/', '?' or
  '#', or Len), or -1 with Err set. Rejected: bytes outside URI_CHARS, more
  than one ':' outside brackets (a port separator), unbalanced or misplaced
  '[' ']', an empty part after '@', and any '%' in the host part (the
  colon and '%' counters restart after '@' and after ']'). }
function AuthorityParse(S: PByte; Len: SizeInt; out Err: TUriError): SizeInt;
const
  MAX_COLONS = 8;
var
  ColonCnt: Cardinal;
  StartBracket, EndBracket, HasPercent: Boolean;
  EndPos, AtSignPos, I: SizeInt;
  B, Ch: Byte;
begin
  Err := ueNone;
  if Len = 0 then
  begin
    Err := ueEmpty;
    Exit(-1);
  end;
  ColonCnt := 0;
  StartBracket := False;
  EndBracket := False;
  HasPercent := False;
  EndPos := Len;
  AtSignPos := Len;
  I := 0;
  while I < Len do
  begin
    B := S[I];
    Ch := URI_CHARS[B];
    if (Ch = Ord('/')) or (Ch = Ord('?')) or (Ch = Ord('#')) then
    begin
      EndPos := I;
      Break;
    end;
    if Ch = 0 then
    begin
      if B = Ord('%') then
        HasPercent := True
      else
      begin
        Err := ueInvalidUriChar;
        Exit(-1);
      end;
    end
    else if Ch = Ord(':') then
    begin
      if ColonCnt >= MAX_COLONS then
      begin
        Err := ueInvalidAuthority;   { too many colons }
        Exit(-1);
      end;
      Inc(ColonCnt);
    end
    else if Ch = Ord('[') then
    begin
      if HasPercent or StartBracket then
      begin
        Err := ueInvalidAuthority;   { '[' after '%', or a second '[' }
        Exit(-1);
      end;
      StartBracket := True;
    end
    else if Ch = Ord(']') then
    begin
      if (not StartBracket) or EndBracket then
      begin
        Err := ueInvalidAuthority;   { ']' without '[', or a second ']' }
        Exit(-1);
      end;
      EndBracket := True;
      ColonCnt := 0;
      HasPercent := False;
    end
    else if Ch = Ord('@') then
    begin
      AtSignPos := I;
      ColonCnt := 0;
      HasPercent := False;
    end;
    Inc(I);
  end;

  if StartBracket <> EndBracket then
  begin
    Err := ueInvalidAuthority;       { '[' without ']' }
    Exit(-1);
  end;
  if ColonCnt > 1 then
  begin
    Err := ueInvalidAuthority;       { more than one ':' after the host start }
    Exit(-1);
  end;
  if (EndPos > 0) and (AtSignPos = EndPos - 1) then
  begin
    Err := ueInvalidAuthority;       { nothing after '@' }
    Exit(-1);
  end;
  if HasPercent then
  begin
    Err := ueInvalidAuthority;       { '%' in the host part }
    Exit(-1);
  end;
  Result := EndPos;
end;

{ Validates the path and query in S[0..Len) and sets the PathAndQuery
  fields of U (Off is the offset of S in the caller's buffer). The path
  must start with '/', '?' or '#', or be exactly "*". Bytes >= 0x80 are
  checked as UTF-8 once, at the end, and only if one was seen. }
function PathAndQueryFromShared(S: PByte; Off, Len: SizeInt; var U: TUriParts;
  out Err: TUriError): Boolean;
var
  I, Query, Fragment: SizeInt;
  MaybeNotUtf8: Boolean;
  C: Byte;
begin
  Err := ueNone;
  Result := False;
  Query := -1;
  Fragment := -1;
  MaybeNotUtf8 := False;
  if Len = 0 then
  begin
    Err := ueEmpty;
    Exit;
  end;
  if Len > URI_MAX_LEN then
  begin
    Err := ueTooLong;
    Exit;
  end;
  if not ((Len = 1) and (S[0] = Ord('*'))) then
  begin
    C := S[0];
    if not ((C = Ord('/')) or (C = Ord('?')) or (C = Ord('#'))) then
    begin
      Err := uePathDoesNotStartWithSlash;
      Exit;
    end;
    I := 0;
    while I < Len do
    begin
      case PATH_MAP[S[I]] of
        CLASS_VALID: ;
        CLASS_QUERY:
          begin
            Query := I;
            Inc(I);
            Break;
          end;
        CLASS_FRAGMENT:
          begin
            Fragment := I;
            Break;
          end;
        CLASS_HIGH:
          MaybeNotUtf8 := True;
      else
        Err := ueInvalidUriChar;
        Exit;
      end;
      Inc(I);
    end;
    if Query >= 0 then
      while I < Len do
      begin
        case QUERY_MAP[S[I]] of
          CLASS_VALID: ;
          CLASS_HIGH:
            MaybeNotUtf8 := True;
          CLASS_FRAGMENT:
            begin
              Fragment := I;
              Break;
            end;
        else
          Err := ueInvalidUriChar;
          Exit;
        end;
        Inc(I);
      end;
  end;

  if Fragment >= 0 then
    Len := Fragment;
  if MaybeNotUtf8 and not IsValidUtf8(S, Len) then
  begin
    Err := ueInvalidUriChar;
    Exit;
  end;
  U.PathAndQueryOff := Off;
  U.PathAndQueryLen := Len;
  U.QueryPos := Query;
  Result := True;
end;

procedure ResetParts(out U: TUriParts);
begin
  U.Scheme := usNone;
  U.SchemeOff := 0;
  U.SchemeLen := 0;
  U.AuthorityOff := 0;
  U.AuthorityLen := 0;
  U.PathAndQueryOff := 0;
  U.PathAndQueryLen := 0;
  U.QueryPos := -1;
end;

function EqIgnoreCase(P: PByte; const S: ShortString): Boolean;
var
  I: Integer;
  B: Byte;
begin
  for I := 1 to Length(S) do
  begin
    B := P[I - 1];
    if (B >= Ord('A')) and (B <= Ord('Z')) then
      B := B + 32;
    if B <> Ord(S[I]) then
      Exit(False);
  end;
  Result := True;
end;

{ Looks for a scheme ("name://") at the start of S. Returns False with Err
  only for a scheme longer than URI_MAX_SCHEME_LEN. Otherwise Kind is the
  scheme found (usNone if S does not start with one) and SchemeLen the
  length of its name, without "://". http and https are matched ignoring
  case. }
function SchemeParse(S: PByte; Len: SizeInt; out Kind: TUriScheme; out SchemeLen: SizeInt;
  out Err: TUriError): Boolean;
var
  I: SizeInt;
begin
  Err := ueNone;
  Kind := usNone;
  SchemeLen := 0;
  Result := True;
  if (Len >= 7) and EqIgnoreCase(S, 'http://') then
  begin
    Kind := usHttp;
    SchemeLen := 4;
    Exit;
  end;
  if (Len >= 8) and EqIgnoreCase(S, 'https://') then
  begin
    Kind := usHttps;
    SchemeLen := 5;
    Exit;
  end;
  if Len > 3 then
    for I := 0 to Len - 1 do
      case SCHEME_CHARS[S[I]] of
        Ord(':'):
          begin
            if Len < I + 3 then
              Break;
            if (S[I + 1] <> Ord('/')) or (S[I + 2] <> Ord('/')) then
              Break;
            if I > URI_MAX_SCHEME_LEN then
            begin
              Err := ueSchemeTooLong;
              Exit(False);
            end;
            Kind := usOther;
            SchemeLen := I;
            Exit;
          end;
        0:
          Break;
      end;
end;

function ParseUri(P: PByte; Len: SizeInt; out U: TUriParts; out Err: TUriError): Boolean;
var
  Kind: TUriScheme;
  SchemeLen, Pos, AuthEnd: SizeInt;
begin
  ResetParts(U);
  Err := ueNone;
  Result := False;
  if Len > URI_MAX_LEN then
  begin
    Err := ueTooLong;
    Exit;
  end;
  if Len = 0 then
  begin
    Err := ueEmpty;
    Exit;
  end;
  if Len = 1 then
  begin
    if (P[0] = Ord('/')) or (P[0] = Ord('*')) then
    begin
      { "/" or "*" }
      U.PathAndQueryOff := 0;
      U.PathAndQueryLen := 1;
      Exit(True);
    end;
    { one byte, not "/" or "*": an authority-form target such as "a" }
    AuthEnd := AuthorityParse(P, Len, Err);
    if AuthEnd < 0 then
    begin
      ResetParts(U);
      Exit;
    end;
    if AuthEnd <> Len then
    begin
      Err := ueInvalidUriChar;
      Exit;
    end;
    U.AuthorityOff := 0;
    U.AuthorityLen := Len;
    U.PathAndQueryOff := Len;
    Exit(True);
  end;

  if P[0] = Ord('/') then
  begin
    Result := PathAndQueryFromShared(P, 0, Len, U, Err);
    if not Result then
      ResetParts(U);
    Exit;
  end;

  { absolute-form or authority-form }
  if not SchemeParse(P, Len, Kind, SchemeLen, Err) then
    Exit;
  Pos := 0;
  if Kind <> usNone then
  begin
    U.Scheme := Kind;
    U.SchemeOff := 0;
    U.SchemeLen := SchemeLen;
    Pos := SchemeLen + 3;
  end;

  AuthEnd := AuthorityParse(P + Pos, Len - Pos, Err);
  if AuthEnd < 0 then
  begin
    ResetParts(U);
    Exit;
  end;

  if Kind = usNone then
  begin
    if AuthEnd <> Len - Pos then
    begin
      Err := ueInvalidFormat;
      Exit;
    end;
    U.AuthorityOff := Pos;
    U.AuthorityLen := Len - Pos;
    U.PathAndQueryOff := Len;
    Exit(True);
  end;

  { an absolute-form target must have an authority }
  if AuthEnd = 0 then
  begin
    Err := ueInvalidFormat;
    ResetParts(U);
    Exit;
  end;
  U.AuthorityOff := Pos;
  U.AuthorityLen := AuthEnd;
  Pos := Pos + AuthEnd;

  { absolute-form without a path: the path is "/" (see PathAndQueryLen) }
  if Pos = Len then
  begin
    U.PathAndQueryOff := Len;
    U.PathAndQueryLen := 0;
    U.QueryPos := -1;
    Exit(True);
  end;
  Result := PathAndQueryFromShared(P + Pos, Pos, Len - Pos, U, Err);
  if not Result then
    ResetParts(U);
end;

function UriErrorDescription(E: TUriError): string;
begin
  case E of
    ueNone: Result := '';
    ueInvalidUriChar: Result := 'invalid uri character';
    ueInvalidScheme: Result := 'invalid scheme';
    ueInvalidAuthority: Result := 'invalid authority';
    ueInvalidPort: Result := 'invalid port';
    ueInvalidFormat: Result := 'invalid format';
    ueSchemeMissing: Result := 'scheme missing';
    ueAuthorityMissing: Result := 'authority missing';
    uePathAndQueryMissing: Result := 'path missing';
    uePathDoesNotStartWithSlash: Result := 'path does not start with slash';
    ueTooLong: Result := 'uri too long';
    ueEmpty: Result := 'empty string';
    ueSchemeTooLong: Result := 'scheme too long';
  end;
end;

initialization
  InitTables;
end.

{ bearings.http.headers - an ordered list of HTTP header fields, plus helpers
  that interpret the header fields the HTTP/1.1 code depends on.

  A header field is a "name: value" line in a request or response head
  (see bearings.http1.parser for the wire format). Names are case-insensitive
  ("Content-Length" and "content-length" are the same field), the same
  name may appear more than once, and the order of fields with the same
  name matters (RFC 9110 section 5.3), so the list keeps insertion order.

  Main types:
  - THttpHeaders: the list. It keeps the name/value pairs in insertion
    order, keeps the original case of each name, and looks names up
    case-insensitively (linear search; a head has few fields). The
    request parser (bearings.http1.role) fills one list per request; the
    response encoder (bearings.http1.encode) writes one out; a framework on top
    (for example its request and response objects) reads and edits them.
  - THttpHeaderEntry: one field, stored as offsets and lengths.

  Storage. Every entry is four (offset, length) numbers. The bytes live
  either in the list's own byte arena (Add, Append, Insert, SetValue copy
  into it) or in one caller-owned external buffer (AddExternal, no copy).
  The parser uses AddExternal: the fields of a request stay in the
  connection's read buffer and are not copied. External offsets are
  relative to ExternalBase. If the caller moves or compacts that buffer it
  must call SetExternalBase with the new address, or call Detach first to
  copy all external bytes into the arena.

  Pointers returned by NamePtr/ValuePtr stay valid until the next call that
  adds bytes to the arena (Add, Append, Insert, SetValue, Detach) or until
  Clear / Free. Clear keeps the allocated capacity, so a list reused for
  every request of a connection stops allocating once it is large enough.
  Delete and Remove do not reclaim arena bytes; Clear does. Add, Insert and
  SetValue may be given NamePtr/ValuePtr of the same list as their source:
  the arena keeps those bytes valid while it grows (ArenaGrow).

  Validation. A header with an invalid name or a value containing CR, LF
  or NUL would let the sender inject extra header lines or end the head
  early (response splitting), so the mutators check what they store: Add,
  Append, Insert and SetValue raise EInvalidHeader on a bad name or value;
  TryAdd, TryInsert and TrySetValue return a THeaderCheck instead;
  AddTrusted, InsertTrusted and SetValueTrusted skip the check, for bytes
  that are valid by construction (parser output, constants). AddExternal
  never checks.

  The value helpers (ConnectionClose, IsChunkedValue, ContentLengthParse,
  ...) take PByte + length so they work directly on slices of a read
  buffer.

  Threading: a THttpHeaders has no locking; one thread uses it at a time.
  The lookup tables are filled at unit initialization and only read
  afterwards. }
unit bearings.http.headers;

{$mode objfpc}{$H+}

interface

uses
  SysUtils;

const
  { Default maximum number of header fields in a request head; one more is
    answered with 431 Request Header Fields Too Large (bearings.http1.role). }
  DEFAULT_MAX_HEADERS = 100;

  { Longest header name IsValidHeaderName accepts (64 KiB - 1). }
  MAX_HEADER_NAME_LEN = (1 shl 16) - 1;

  { Lowercase names of the headers this unit and the codec refer to. }
  HN_AUTHORIZATION      = 'authorization';
  HN_CACHE_CONTROL      = 'cache-control';
  HN_CONNECTION         = 'connection';
  HN_CONTENT_ENCODING   = 'content-encoding';
  HN_CONTENT_LENGTH     = 'content-length';
  HN_CONTENT_RANGE      = 'content-range';
  HN_CONTENT_TYPE       = 'content-type';
  HN_DATE               = 'date';
  HN_EXPECT             = 'expect';
  HN_HOST               = 'host';
  HN_KEEP_ALIVE         = 'keep-alive';
  HN_MAX_FORWARDS       = 'max-forwards';
  HN_SERVER             = 'server';
  HN_SET_COOKIE         = 'set-cookie';
  HN_TE                 = 'te';
  HN_TRAILER            = 'trailer';
  HN_TRANSFER_ENCODING  = 'transfer-encoding';
  HN_UPGRADE            = 'upgrade';

type
  { How WriteTo/AppendTo spell header names.
    Header names are case-insensitive, so all three are valid HTTP; some
    old clients expect a particular spelling.
    hncLower : all lowercase.
    hncTitle : the lowercased name with the first letter and every letter
               after '-' uppercased ("Content-Length").
    hncAsIs  : the name exactly as stored. }
  THeaderNameCase = (hncLower, hncTitle, hncAsIs);

  THttpHeaderEntry = record
    NameOfs: SizeInt;
    NameLen: SizeInt;
    ValueOfs: SizeInt;
    ValueLen: SizeInt;
    NameExt: Boolean;   { True: NameOfs is relative to ExternalBase }
    ValueExt: Boolean;  { True: ValueOfs is relative to ExternalBase }
  end;
  PHttpHeaderEntry = ^THttpHeaderEntry;

  { Result of a header field check (IsValidHeaderName, IsValidHeaderValue). }
  THeaderCheck = (hcOk, hcBadName, hcBadValue);

  { Raised by the validating THttpHeaders mutators. }
  EInvalidHeader = class(Exception)
  public
    Check: THeaderCheck;
  end;

  { THttpHeaders }

  THttpHeaders = class
  private
    FEntries: array of THttpHeaderEntry;
    FCount: SizeInt;
    FData: array of Byte;
    FDataLen: SizeInt;
    FExtBase: PByte;
    procedure ArenaGrow(Need: SizeInt; var A, B: PByte);
    function ArenaAppend(P: PByte; Len: SizeInt): SizeInt;
    procedure EnsureEntryCapacity(N: SizeInt);
    function NewEntry: PHttpHeaderEntry;
    function GetEntry(I: SizeInt): THttpHeaderEntry;
    procedure CheckIndex(I: SizeInt);
  public
    constructor Create(AEntryCapacity: SizeInt = 16; ADataCapacity: SizeInt = 1024);
    { Removes all entries; keeps capacity; keeps ExternalBase. }
    procedure Clear;

    { ---- validating mutators ----
      Name must pass IsValidHeaderName and Value IsValidHeaderValue, else
      EInvalidHeader is raised and the list is unchanged. }

    { Appends a pair, copying both into the arena. Returns its index. }
    function Add(Name: PByte; NameLen: SizeInt; Value: PByte; ValueLen: SizeInt): SizeInt; overload;
    function Add(const Name, Value: RawByteString): SizeInt; overload;
    { Same as Add: adds another field even if Name already exists. }
    function Append(const Name, Value: RawByteString): SizeInt;
    { Sets the only value of Name: if Name exists, the first entry gets
      Value and every later entry with that name is removed; otherwise
      appends. }
    procedure Insert(Name: PByte; NameLen: SizeInt; Value: PByte; ValueLen: SizeInt); overload;
    procedure Insert(const Name, Value: RawByteString); overload;
    { Replaces the value of entry I (copied into the arena). Checks Value. }
    procedure SetValue(I: SizeInt; Value: PByte; ValueLen: SizeInt); overload;
    procedure SetValue(I: SizeInt; const Value: RawByteString); overload;

    { ---- same checks, no exception: hcOk and the change made, or the
      failed check and the list unchanged ---- }
    function TryAdd(Name: PByte; NameLen: SizeInt; Value: PByte; ValueLen: SizeInt): THeaderCheck;
    function TryInsert(Name: PByte; NameLen: SizeInt; Value: PByte; ValueLen: SizeInt): THeaderCheck;
    function TrySetValue(I: SizeInt; Value: PByte; ValueLen: SizeInt): THeaderCheck;

    { ---- no checks: the bytes are valid by construction (parser and
      decoder output, constants covered by a unit test, copies from another
      validated list). The encoders (ServerEncode, EncodeTrailers) assert
      every name and value they write in -Sa builds. ---- }
    function AddTrusted(Name: PByte; NameLen: SizeInt; Value: PByte; ValueLen: SizeInt): SizeInt; overload;
    function AddTrusted(const Name, Value: RawByteString): SizeInt; overload;
    procedure InsertTrusted(Name: PByte; NameLen: SizeInt; Value: PByte; ValueLen: SizeInt); overload;
    procedure InsertTrusted(const Name, Value: RawByteString); overload;
    procedure SetValueTrusted(I: SizeInt; Value: PByte; ValueLen: SizeInt);
    { Appends a pair whose bytes stay in the external buffer (no copy, no
      check). Offsets are relative to ExternalBase. }
    function AddExternal(NameOfs, NameLen, ValueOfs, ValueLen: SizeInt): SizeInt;

    procedure Delete(I: SizeInt);
    { Removes every entry named Name. Returns how many were removed. }
    function Remove(const Name: RawByteString): SizeInt;

    procedure SetExternalBase(Base: PByte);
    { Copies every external name/value into the arena. }
    procedure Detach;

    { Case-insensitive search from StartIndex. Returns -1 if not found. }
    function IndexOf(Name: PByte; NameLen: SizeInt; StartIndex: SizeInt = 0): SizeInt; overload;
    function IndexOf(const Name: RawByteString; StartIndex: SizeInt = 0): SizeInt; overload;
    { Index of the last entry named Name, or -1. }
    function LastIndexOf(const Name: RawByteString): SizeInt;
    function Contains(const Name: RawByteString): Boolean;
    function CountOf(const Name: RawByteString): SizeInt;
    { First value for Name, as a slice. }
    function Get(const Name: RawByteString; out Value: PByte; out ValueLen: SizeInt): Boolean;
    { First value for Name as a new string ('' if absent). Allocates. }
    function GetValue(const Name: RawByteString): RawByteString;

    function NamePtr(I: SizeInt): PByte;
    function NameLen(I: SizeInt): SizeInt;
    function ValuePtr(I: SizeInt): PByte;
    function ValueLen(I: SizeInt): SizeInt;
    { Allocating copies, for tests and cold paths. }
    function Name(I: SizeInt): RawByteString;
    function Value(I: SizeInt): RawByteString;
    function NameIs(I: SizeInt; const AName: RawByteString): Boolean;

    { Bytes WriteTo writes: sum of name + ': ' + value + CRLF. }
    function WireLength: SizeInt;
    { Writes every entry as "name: value\r\n". Dst must hold WireLength
      bytes. Returns the number of bytes written. }
    function WriteTo(Dst: PByte; NameCase: THeaderNameCase): SizeInt;
    { Appends the same bytes at Buf[Len], growing Buf; advances Len. }
    procedure AppendTo(var Buf: TBytes; var Len: SizeInt; NameCase: THeaderNameCase);

    property Count: SizeInt read FCount;
    property Entries[I: SizeInt]: THttpHeaderEntry read GetEntry;
    property ExternalBase: PByte read FExtBase;
  end;

{ ---- byte helpers ---- }

{ ASCII lowercase table (A-Z -> a-z, all other bytes unchanged). }
function AsciiLower(B: Byte): Byte; inline;
function AsciiEqualIgnoreCase(A: PByte; ALen: SizeInt; B: PByte; BLen: SizeInt): Boolean;
function AsciiEqualIgnoreCaseStr(A: PByte; ALen: SizeInt; const B: RawByteString): Boolean;
{ True when every byte is HTAB or 0x20..0x7E (no control bytes, no bytes
  >= 0x80). The list helpers below require it before they look for
  tokens. }
function IsVisibleAscii(P: PByte; Len: SizeInt): Boolean;
{ A storable value: every byte is HTAB, or >= 0x20 and <> 0x7F. This
  excludes CR, LF and NUL, which would break the line structure of the
  head. Bytes >= 0x80 (obs-text) are allowed. }
function IsValidHeaderValue(P: PByte; Len: SizeInt): Boolean;
{ A valid name: 1..MAX_HEADER_NAME_LEN bytes, each a tchar (RFC 9110
  token: ALPHA DIGIT ! # $ % & ' * + - . ^ _ ` | ~). }
function IsValidHeaderName(P: PByte; Len: SizeInt): Boolean;
{ Both checks of the validating mutators: hcBadName if the name fails
  IsValidHeaderName, else hcBadValue if the value fails IsValidHeaderValue. }
function CheckHeaderField(Name: PByte; NameLen: SizeInt; Value: PByte; ValueLen: SizeInt): THeaderCheck;
{ Raises EInvalidHeader for C (C <> hcOk). }
procedure RaiseInvalidHeader(C: THeaderCheck);
{ Writes Name in title case (see hncTitle). Returns Len. }
function WriteTitleCase(Dst: PByte; Name: PByte; Len: SizeInt): SizeInt;

{ ---- interpretation of header values ----
  Many header values are comma-separated lists ("Connection: keep-alive,
  Upgrade"). The helpers split on ',', trim SP/HTAB around each item and
  compare ignoring ASCII case. A value with bytes outside IsVisibleAscii
  never matches. }

{ Whether one Connection value lists "keep-alive" / "close". In HTTP/1.1
  the connection stays open after a response unless either side sends
  "Connection: close"; in HTTP/1.0 it closes unless the client sends
  "Connection: keep-alive". bearings.http1.role decides from these. }
function ConnectionKeepAlive(Value: PByte; Len: SizeInt): Boolean;
function ConnectionClose(Value: PByte; Len: SizeInt): Boolean;
{ True when Value is visible ASCII and one comma-separated item, trimmed
  of SP/HTAB, equals Needle ignoring ASCII case. }
function ConnectionHas(Value: PByte; Len: SizeInt; const Needle: RawByteString): Boolean;
{ True when any Connection field lists "close". }
function ConnectionAnyClose(H: THttpHeaders): Boolean;
{ True when any TE field lists "trailers": the client accepts trailer
  fields after a chunked response body. }
function TeIsTrailers(H: THttpHeaders): Boolean;
{ ConnectionHas applied to every field named Name. }
function HeaderValueListHas(H: THttpHeaders; const Name, Needle: RawByteString): Boolean;
{ Parses one raw Content-Length value with FromDigits (no trimming, no
  list). }
function ContentLengthParse(Value: PByte; Len: SizeInt; out N: QWord): Boolean;
{ The body length from all Content-Length fields. Every Content-Length
  field must be visible ASCII; each comma-separated, trimmed item must
  parse and all must be equal ("5, 5" or two fields of 5 are accepted, as
  RFC 9110 section 8.6 allows). False if there is no Content-Length field
  or any check fails. Different values must be rejected: if a proxy and
  the server picked different ones they would split the byte stream into
  requests differently (request smuggling). }
function ContentLengthParseAll(H: THttpHeaders; out N: QWord): Boolean;
{ Parses 1*DIGIT: no sign, no spaces, no overflow past 2^64-1. }
function FromDigits(P: PByte; Len: SizeInt; out N: QWord): Boolean;
{ True when the LAST Transfer-Encoding field ends with the "chunked"
  coding. Transfer-Encoding lists the codings applied to the body in
  order; chunked framing must be the last one, otherwise the body is not
  chunk-framed (RFC 9112 section 6.3). }
function TransferEncodingIsChunked(H: THttpHeaders): Boolean;
{ True when Value is visible ASCII and its last comma-separated item,
  trimmed, equals 'chunked' ignoring ASCII case. }
function IsChunkedValue(Value: PByte; Len: SizeInt): Boolean;
{ Writes the decimal digits of N to Dst (at most 20 bytes). Returns length. }
function WriteDecimal(Dst: PByte; N: QWord): SizeInt;

{$IFOPT C+}
var
  { Builds with assertions on (-Sa, IFOPT C+) only: the number of
    calls of the validating mutators (Add, Insert, SetValue and their Try*
    forms). Tests use it to show that the server's own code uses the
    *Trusted forms. Incremented with an interlocked add because worker
    threads build response heads too. }
  ValidatingMutatorCalls: QWord = 0;
{$ENDIF}

implementation

var
  LowerMap: array[Byte] of Byte;
  TcharMap: array[Byte] of Boolean;   { tchar (RFC 9110 token byte) }
  ValueOkMap: array[Byte] of Boolean; { IsValidHeaderValue: HTAB, or >= 0x20 and <> 0x7F }

function IsValidHeaderName(P: PByte; Len: SizeInt): Boolean;
var
  I: SizeInt;
begin
  if (Len <= 0) or (Len > MAX_HEADER_NAME_LEN) then
    Exit(False);
  for I := 0 to Len - 1 do
    if not TcharMap[P[I]] then
      Exit(False);
  Result := True;
end;

function AsciiLower(B: Byte): Byte; inline;
begin
  Result := LowerMap[B];
end;

function AsciiEqualIgnoreCase(A: PByte; ALen: SizeInt; B: PByte; BLen: SizeInt): Boolean;
var
  I: SizeInt;
begin
  if ALen <> BLen then
    Exit(False);
  for I := 0 to ALen - 1 do
    if LowerMap[A[I]] <> LowerMap[B[I]] then
      Exit(False);
  Result := True;
end;

function AsciiEqualIgnoreCaseStr(A: PByte; ALen: SizeInt; const B: RawByteString): Boolean;
begin
  Result := AsciiEqualIgnoreCase(A, ALen, PByte(Pointer(B)), Length(B));
end;

function IsVisibleAscii(P: PByte; Len: SizeInt): Boolean;
var
  I: SizeInt;
  B: Byte;
begin
  for I := 0 to Len - 1 do
  begin
    B := P[I];
    if not (((B >= 32) and (B < 127)) or (B = 9)) then
      Exit(False);
  end;
  Result := True;
end;

function IsValidHeaderValue(P: PByte; Len: SizeInt): Boolean;
var
  I: SizeInt;
begin
  for I := 0 to Len - 1 do
    if not ValueOkMap[P[I]] then
      Exit(False);
  Result := True;
end;

function CheckHeaderField(Name: PByte; NameLen: SizeInt; Value: PByte; ValueLen: SizeInt): THeaderCheck;
begin
  if not IsValidHeaderName(Name, NameLen) then
    Exit(hcBadName);
  if not IsValidHeaderValue(Value, ValueLen) then
    Exit(hcBadValue);
  Result := hcOk;
end;

{ cold: the exception object and its message live only here }
procedure RaiseInvalidHeader(C: THeaderCheck);
var
  E: EInvalidHeader;
begin
  if C = hcBadName then
    E := EInvalidHeader.Create('invalid HTTP header name')
  else
    E := EInvalidHeader.Create('invalid HTTP header value');
  E.Check := C;
  raise E;
end;

function WriteTitleCase(Dst: PByte; Name: PByte; Len: SizeInt): SizeInt;
var
  I: SizeInt;
  Prev, C: Byte;
begin
  Prev := Ord('-');
  for I := 0 to Len - 1 do
  begin
    C := LowerMap[Name[I]];
    if (Prev = Ord('-')) and (C >= Ord('a')) and (C <= Ord('z')) then
      C := C - 32;
    Dst[I] := C;
    Prev := C;
  end;
  Result := Len;
end;

function WriteDecimal(Dst: PByte; N: QWord): SizeInt;
var
  Tmp: array[0..19] of Byte;
  I, L: Integer;
begin
  L := 0;
  repeat
    Tmp[L] := Ord('0') + Byte(N mod 10);
    N := N div 10;
    Inc(L);
  until N = 0;
  for I := 0 to L - 1 do
    Dst[I] := Tmp[L - 1 - I];
  Result := L;
end;

{ THttpHeaders }

constructor THttpHeaders.Create(AEntryCapacity: SizeInt; ADataCapacity: SizeInt);
begin
  inherited Create;
  if AEntryCapacity < 1 then AEntryCapacity := 1;
  if ADataCapacity < 16 then ADataCapacity := 16;
  SetLength(FEntries, AEntryCapacity);
  SetLength(FData, ADataCapacity);
end;

procedure THttpHeaders.Clear;
begin
  FCount := 0;
  FDataLen := 0;
end;

procedure THttpHeaders.CheckIndex(I: SizeInt);
begin
  if (I < 0) or (I >= FCount) then
    raise ERangeError.CreateFmt('THttpHeaders: index %d out of range (count %d)', [I, FCount]);
end;

function THttpHeaders.GetEntry(I: SizeInt): THttpHeaderEntry;
begin
  CheckIndex(I);
  Result := FEntries[I];
end;

{ Makes room for Need more arena bytes. A and B are source pointers the
  caller is about to copy from; if one points into the arena it is moved
  along with it, so copying an entry of this list into itself stays valid
  (otherwise it would read the freed old block). Only runs when the arena
  has to grow. }
procedure THttpHeaders.ArenaGrow(Need: SizeInt; var A, B: PByte);
var
  NewCap: SizeInt;
  OldBase, OldEnd: PByte;
  AOfs, BOfs: SizeInt;
begin
  if FDataLen + Need <= System.Length(FData) then
    Exit;
  OldBase := PByte(Pointer(FData));
  OldEnd := OldBase + System.Length(FData);
  AOfs := -1;
  BOfs := -1;
  if (A >= OldBase) and (A < OldEnd) then AOfs := A - OldBase;
  if (B >= OldBase) and (B < OldEnd) then BOfs := B - OldBase;
  NewCap := System.Length(FData) * 2;
  if NewCap < FDataLen + Need then
    NewCap := FDataLen + Need;
  SetLength(FData, NewCap);
  if AOfs >= 0 then A := PByte(Pointer(FData)) + AOfs;
  if BOfs >= 0 then B := PByte(Pointer(FData)) + BOfs;
end;

function THttpHeaders.ArenaAppend(P: PByte; Len: SizeInt): SizeInt;
var
  Dummy: PByte;
begin
  Result := FDataLen;
  if Len <= 0 then
    Exit;
  Dummy := nil;
  ArenaGrow(Len, P, Dummy);
  Move(P^, FData[FDataLen], Len);
  Inc(FDataLen, Len);
end;

procedure THttpHeaders.EnsureEntryCapacity(N: SizeInt);
var
  NewCap: SizeInt;
begin
  if N > System.Length(FEntries) then
  begin
    NewCap := System.Length(FEntries) * 2;
    if NewCap < N then NewCap := N;
    SetLength(FEntries, NewCap);
  end;
end;

function THttpHeaders.NewEntry: PHttpHeaderEntry;
begin
  EnsureEntryCapacity(FCount + 1);
  Result := @FEntries[FCount];
  Inc(FCount);
end;

function THttpHeaders.AddTrusted(Name: PByte; NameLen: SizeInt; Value: PByte; ValueLen: SizeInt): SizeInt;
var
  E: PHttpHeaderEntry;
  NOfs: SizeInt;
  D: PByte;
begin
  { grow once for both, so a Value pointer into the arena is not left
    behind by a growth caused by copying Name. The capacity checks are
    done here once (no ArenaGrow / ArenaAppend / NewEntry calls when the
    arena and the entry array have room), because this runs for every
    header a handler adds to a response }
  if NameLen < 0 then NameLen := 0;
  if ValueLen < 0 then ValueLen := 0;
  if FDataLen + NameLen + ValueLen > System.Length(FData) then
    ArenaGrow(NameLen + ValueLen, Name, Value);
  NOfs := FDataLen;
  D := PByte(Pointer(FData));
  if NameLen > 0 then
    Move(Name^, D[NOfs], NameLen);
  if ValueLen > 0 then
    Move(Value^, D[NOfs + NameLen], ValueLen);
  FDataLen := NOfs + NameLen + ValueLen;
  if FCount >= System.Length(FEntries) then
    EnsureEntryCapacity(FCount + 1);
  E := @FEntries[FCount];
  Inc(FCount);
  E^.NameOfs := NOfs;
  E^.NameLen := NameLen;
  E^.ValueOfs := NOfs + NameLen;
  E^.ValueLen := ValueLen;
  E^.NameExt := False;
  E^.ValueExt := False;
  Result := FCount - 1;
end;

function THttpHeaders.AddTrusted(const Name, Value: RawByteString): SizeInt;
begin
  Result := AddTrusted(PByte(Pointer(Name)), System.Length(Name), PByte(Pointer(Value)), System.Length(Value));
end;

function THttpHeaders.Add(Name: PByte; NameLen: SizeInt; Value: PByte; ValueLen: SizeInt): SizeInt;
var
  C: THeaderCheck;
begin
  {$IFOPT C+}InterLockedIncrement64(Int64(ValidatingMutatorCalls));{$ENDIF}
  C := CheckHeaderField(Name, NameLen, Value, ValueLen);
  if C <> hcOk then
    RaiseInvalidHeader(C);
  Result := AddTrusted(Name, NameLen, Value, ValueLen);
end;

function THttpHeaders.Add(const Name, Value: RawByteString): SizeInt;
begin
  Result := Add(PByte(Pointer(Name)), System.Length(Name), PByte(Pointer(Value)), System.Length(Value));
end;

function THttpHeaders.TryAdd(Name: PByte; NameLen: SizeInt; Value: PByte; ValueLen: SizeInt): THeaderCheck;
begin
  {$IFOPT C+}InterLockedIncrement64(Int64(ValidatingMutatorCalls));{$ENDIF}
  Result := CheckHeaderField(Name, NameLen, Value, ValueLen);
  if Result = hcOk then
    AddTrusted(Name, NameLen, Value, ValueLen);
end;

function THttpHeaders.Append(const Name, Value: RawByteString): SizeInt;
begin
  Result := Add(Name, Value);
end;

function THttpHeaders.AddExternal(NameOfs, NameLen, ValueOfs, ValueLen: SizeInt): SizeInt;
var
  E: PHttpHeaderEntry;
begin
  E := NewEntry;
  E^.NameOfs := NameOfs;
  E^.NameLen := NameLen;
  E^.ValueOfs := ValueOfs;
  E^.ValueLen := ValueLen;
  E^.NameExt := True;
  E^.ValueExt := True;
  Result := FCount - 1;
end;

procedure THttpHeaders.InsertTrusted(Name: PByte; NameLen: SizeInt; Value: PByte; ValueLen: SizeInt);
var
  I, J: SizeInt;
begin
  I := IndexOf(Name, NameLen, 0);
  if I < 0 then
  begin
    AddTrusted(Name, NameLen, Value, ValueLen);
    Exit;
  end;
  SetValueTrusted(I, Value, ValueLen);
  J := FCount - 1;
  while J > I do
  begin
    if AsciiEqualIgnoreCase(NamePtr(J), FEntries[J].NameLen, NamePtr(I), FEntries[I].NameLen) then
      Delete(J);
    Dec(J);
  end;
end;

procedure THttpHeaders.InsertTrusted(const Name, Value: RawByteString);
begin
  InsertTrusted(PByte(Pointer(Name)), System.Length(Name), PByte(Pointer(Value)), System.Length(Value));
end;

procedure THttpHeaders.Insert(Name: PByte; NameLen: SizeInt; Value: PByte; ValueLen: SizeInt);
var
  C: THeaderCheck;
begin
  {$IFOPT C+}InterLockedIncrement64(Int64(ValidatingMutatorCalls));{$ENDIF}
  C := CheckHeaderField(Name, NameLen, Value, ValueLen);
  if C <> hcOk then
    RaiseInvalidHeader(C);
  InsertTrusted(Name, NameLen, Value, ValueLen);
end;

procedure THttpHeaders.Insert(const Name, Value: RawByteString);
begin
  Insert(PByte(Pointer(Name)), System.Length(Name), PByte(Pointer(Value)), System.Length(Value));
end;

function THttpHeaders.TryInsert(Name: PByte; NameLen: SizeInt; Value: PByte; ValueLen: SizeInt): THeaderCheck;
begin
  {$IFOPT C+}InterLockedIncrement64(Int64(ValidatingMutatorCalls));{$ENDIF}
  Result := CheckHeaderField(Name, NameLen, Value, ValueLen);
  if Result = hcOk then
    InsertTrusted(Name, NameLen, Value, ValueLen);
end;

procedure THttpHeaders.SetValue(I: SizeInt; Value: PByte; ValueLen: SizeInt);
begin
  {$IFOPT C+}InterLockedIncrement64(Int64(ValidatingMutatorCalls));{$ENDIF}
  CheckIndex(I);
  if not IsValidHeaderValue(Value, ValueLen) then
    RaiseInvalidHeader(hcBadValue);
  SetValueTrusted(I, Value, ValueLen);
end;

function THttpHeaders.TrySetValue(I: SizeInt; Value: PByte; ValueLen: SizeInt): THeaderCheck;
begin
  {$IFOPT C+}InterLockedIncrement64(Int64(ValidatingMutatorCalls));{$ENDIF}
  CheckIndex(I);
  if not IsValidHeaderValue(Value, ValueLen) then
    Exit(hcBadValue);
  SetValueTrusted(I, Value, ValueLen);
  Result := hcOk;
end;

procedure THttpHeaders.SetValueTrusted(I: SizeInt; Value: PByte; ValueLen: SizeInt);
var
  Ofs: SizeInt;
begin
  CheckIndex(I);
  Ofs := ArenaAppend(Value, ValueLen);
  FEntries[I].ValueOfs := Ofs;
  FEntries[I].ValueLen := ValueLen;
  FEntries[I].ValueExt := False;
end;

procedure THttpHeaders.SetValue(I: SizeInt; const Value: RawByteString);
begin
  SetValue(I, PByte(Pointer(Value)), System.Length(Value));
end;

procedure THttpHeaders.Delete(I: SizeInt);
begin
  CheckIndex(I);
  if I < FCount - 1 then
    Move(FEntries[I + 1], FEntries[I], (FCount - 1 - I) * SizeOf(THttpHeaderEntry));
  Dec(FCount);
end;

function THttpHeaders.Remove(const Name: RawByteString): SizeInt;
var
  I: SizeInt;
begin
  Result := 0;
  I := FCount - 1;
  while I >= 0 do
  begin
    if NameIs(I, Name) then
    begin
      Delete(I);
      Inc(Result);
    end;
    Dec(I);
  end;
end;

procedure THttpHeaders.SetExternalBase(Base: PByte);
begin
  FExtBase := Base;
end;

procedure THttpHeaders.Detach;
var
  I: SizeInt;
begin
  for I := 0 to FCount - 1 do
  begin
    if FEntries[I].NameExt then
    begin
      FEntries[I].NameOfs := ArenaAppend(FExtBase + FEntries[I].NameOfs, FEntries[I].NameLen);
      FEntries[I].NameExt := False;
    end;
    if FEntries[I].ValueExt then
    begin
      FEntries[I].ValueOfs := ArenaAppend(FExtBase + FEntries[I].ValueOfs, FEntries[I].ValueLen);
      FEntries[I].ValueExt := False;
    end;
  end;
end;

function THttpHeaders.NamePtr(I: SizeInt): PByte;
begin
  if FEntries[I].NameExt then
    Result := FExtBase + FEntries[I].NameOfs
  else
    Result := PByte(Pointer(FData)) + FEntries[I].NameOfs;
end;

function THttpHeaders.NameLen(I: SizeInt): SizeInt;
begin
  Result := FEntries[I].NameLen;
end;

function THttpHeaders.ValuePtr(I: SizeInt): PByte;
begin
  if FEntries[I].ValueExt then
    Result := FExtBase + FEntries[I].ValueOfs
  else
    Result := PByte(Pointer(FData)) + FEntries[I].ValueOfs;
end;

function THttpHeaders.ValueLen(I: SizeInt): SizeInt;
begin
  Result := FEntries[I].ValueLen;
end;

function THttpHeaders.Name(I: SizeInt): RawByteString;
begin
  CheckIndex(I);
  SetLength(Result, FEntries[I].NameLen);
  if FEntries[I].NameLen > 0 then
    Move(NamePtr(I)^, Pointer(Result)^, FEntries[I].NameLen);
end;

function THttpHeaders.Value(I: SizeInt): RawByteString;
begin
  CheckIndex(I);
  SetLength(Result, FEntries[I].ValueLen);
  if FEntries[I].ValueLen > 0 then
    Move(ValuePtr(I)^, Pointer(Result)^, FEntries[I].ValueLen);
end;

function THttpHeaders.NameIs(I: SizeInt; const AName: RawByteString): Boolean;
begin
  Result := AsciiEqualIgnoreCase(NamePtr(I), FEntries[I].NameLen,
    PByte(Pointer(AName)), System.Length(AName));
end;

function THttpHeaders.IndexOf(Name: PByte; NameLen: SizeInt; StartIndex: SizeInt): SizeInt;
var
  I: SizeInt;
begin
  if StartIndex < 0 then StartIndex := 0;
  for I := StartIndex to FCount - 1 do
    if (FEntries[I].NameLen = NameLen) and
       AsciiEqualIgnoreCase(NamePtr(I), NameLen, Name, NameLen) then
      Exit(I);
  Result := -1;
end;

function THttpHeaders.IndexOf(const Name: RawByteString; StartIndex: SizeInt): SizeInt;
begin
  Result := IndexOf(PByte(Pointer(Name)), System.Length(Name), StartIndex);
end;

function THttpHeaders.LastIndexOf(const Name: RawByteString): SizeInt;
var
  I: SizeInt;
begin
  for I := FCount - 1 downto 0 do
    if NameIs(I, Name) then
      Exit(I);
  Result := -1;
end;

function THttpHeaders.Contains(const Name: RawByteString): Boolean;
begin
  Result := IndexOf(Name, 0) >= 0;
end;

function THttpHeaders.CountOf(const Name: RawByteString): SizeInt;
var
  I: SizeInt;
begin
  Result := 0;
  for I := 0 to FCount - 1 do
    if NameIs(I, Name) then
      Inc(Result);
end;

function THttpHeaders.Get(const Name: RawByteString; out Value: PByte; out ValueLen: SizeInt): Boolean;
var
  I: SizeInt;
begin
  I := IndexOf(Name, 0);
  Result := I >= 0;
  if Result then
  begin
    Value := ValuePtr(I);
    ValueLen := FEntries[I].ValueLen;
  end
  else
  begin
    Value := nil;
    ValueLen := 0;
  end;
end;

function THttpHeaders.GetValue(const Name: RawByteString): RawByteString;
var
  I: SizeInt;
begin
  I := IndexOf(Name, 0);
  if I < 0 then
    Result := ''
  else
    Result := Value(I);
end;

function THttpHeaders.WireLength: SizeInt;
var
  I: SizeInt;
begin
  Result := 0;
  for I := 0 to FCount - 1 do
    Inc(Result, FEntries[I].NameLen + FEntries[I].ValueLen + 4);
end;

function THttpHeaders.WriteTo(Dst: PByte; NameCase: THeaderNameCase): SizeInt;
var
  I, J, NL, VL: SizeInt;
  P: PByte;
  Q: PByte;
begin
  Q := Dst;
  for I := 0 to FCount - 1 do
  begin
    NL := FEntries[I].NameLen;
    VL := FEntries[I].ValueLen;
    P := NamePtr(I);
    case NameCase of
      hncLower:
        for J := 0 to NL - 1 do
          Q[J] := LowerMap[P[J]];
      hncTitle:
        WriteTitleCase(Q, P, NL);
      hncAsIs:
        if NL > 0 then Move(P^, Q^, NL);
    end;
    Inc(Q, NL);
    Q[0] := Ord(':');
    Q[1] := Ord(' ');
    Inc(Q, 2);
    if VL > 0 then
      Move(ValuePtr(I)^, Q^, VL);
    Inc(Q, VL);
    Q[0] := 13;
    Q[1] := 10;
    Inc(Q, 2);
  end;
  Result := Q - Dst;
end;

procedure THttpHeaders.AppendTo(var Buf: TBytes; var Len: SizeInt; NameCase: THeaderNameCase);
var
  Need, NewCap: SizeInt;
begin
  Need := WireLength;
  if Need = 0 then
    Exit;
  if Len + Need > System.Length(Buf) then
  begin
    NewCap := System.Length(Buf) * 2;
    if NewCap < Len + Need then NewCap := Len + Need;
    SetLength(Buf, NewCap);
  end;
  Inc(Len, WriteTo(@Buf[Len], NameCase));
end;

{ ---- interpretation of header values ---- }

{ Trims SP/HTAB on both ends of P[S..E) (E exclusive). The callers have
  checked IsVisibleAscii, so SP and HTAB are the only whitespace left. }
procedure TrimSpTab(P: PByte; var S, E: SizeInt); inline;
begin
  while (S < E) and ((P[S] = 32) or (P[S] = 9)) do Inc(S);
  while (E > S) and ((P[E - 1] = 32) or (P[E - 1] = 9)) do Dec(E);
end;

function ConnectionHas(Value: PByte; Len: SizeInt; const Needle: RawByteString): Boolean;
var
  S, E, I: SizeInt;
begin
  Result := False;
  if not IsVisibleAscii(Value, Len) then
    Exit;
  I := 0;
  while I <= Len do
  begin
    S := I;
    while (I < Len) and (Value[I] <> Ord(',')) do Inc(I);
    E := I;
    TrimSpTab(Value, S, E);
    if AsciiEqualIgnoreCaseStr(Value + S, E - S, Needle) then
      Exit(True);
    Inc(I); { skip ',' (or step past the end) }
  end;
end;

function ConnectionKeepAlive(Value: PByte; Len: SizeInt): Boolean;
begin
  Result := ConnectionHas(Value, Len, 'keep-alive');
end;

function ConnectionClose(Value: PByte; Len: SizeInt): Boolean;
begin
  Result := ConnectionHas(Value, Len, 'close');
end;

function ConnectionAnyClose(H: THttpHeaders): Boolean;
var
  I: SizeInt;
begin
  I := H.IndexOf(HN_CONNECTION, 0);
  while I >= 0 do
  begin
    if ConnectionClose(H.ValuePtr(I), H.ValueLen(I)) then
      Exit(True);
    I := H.IndexOf(HN_CONNECTION, I + 1);
  end;
  Result := False;
end;

function HeaderValueListHas(H: THttpHeaders; const Name, Needle: RawByteString): Boolean;
var
  I: SizeInt;
begin
  I := H.IndexOf(Name, 0);
  while I >= 0 do
  begin
    { each field separately: an item never spans two fields }
    if ConnectionHas(H.ValuePtr(I), H.ValueLen(I), Needle) then
      Exit(True);
    I := H.IndexOf(Name, I + 1);
  end;
  Result := False;
end;

function TeIsTrailers(H: THttpHeaders): Boolean;
var
  I: SizeInt;
  Any: Boolean;
begin
  { fast path, because this runs for every request head: without a
    2-byte header name there is no TE field }
  Any := False;
  for I := 0 to H.Count - 1 do
    if H.NameLen(I) = 2 then
    begin
      Any := True;
      Break;
    end;
  if not Any then
    Exit(False);
  Result := HeaderValueListHas(H, HN_TE, 'trailers');
end;

function FromDigits(P: PByte; Len: SizeInt; out N: QWord): Boolean;
var
  I: SizeInt;
  D: QWord;
  R: QWord;
begin
  N := 0;
  if Len <= 0 then
    Exit(False);
  R := 0;
  for I := 0 to Len - 1 do
  begin
    if (P[I] < Ord('0')) or (P[I] > Ord('9')) then
      Exit(False);
    D := P[I] - Ord('0');
    { R * 10 + D, failing on QWord overflow }
    if R > High(QWord) div 10 then
      Exit(False);
    R := R * 10;
    if R > High(QWord) - D then
      Exit(False);
    R := R + D;
  end;
  N := R;
  Result := True;
end;

function ContentLengthParse(Value: PByte; Len: SizeInt; out N: QWord): Boolean;
begin
  Result := FromDigits(Value, Len, N);
end;

function ContentLengthParseAll(H: THttpHeaders; out N: QWord): Boolean;
var
  I, S, E, J, Len: SizeInt;
  P: PByte;
  V: QWord;
  Have: Boolean;
begin
  N := 0;
  Have := False;
  I := H.IndexOf(HN_CONTENT_LENGTH, 0);
  while I >= 0 do
  begin
    P := H.ValuePtr(I);
    Len := H.ValueLen(I);
    if not IsVisibleAscii(P, Len) then
      Exit(False);
    J := 0;
    while J <= Len do
    begin
      S := J;
      while (J < Len) and (P[J] <> Ord(',')) do Inc(J);
      E := J;
      TrimSpTab(P, S, E);
      if not FromDigits(P + S, E - S, V) then
        Exit(False);
      if not Have then
      begin
        N := V;
        Have := True;
      end
      else if N <> V then
        Exit(False);
      Inc(J);
    end;
    I := H.IndexOf(HN_CONTENT_LENGTH, I + 1);
  end;
  Result := Have;
end;

function IsChunkedValue(Value: PByte; Len: SizeInt): Boolean;
var
  S, E: SizeInt;
begin
  Result := False;
  if not IsVisibleAscii(Value, Len) then
    Exit;
  { the part after the last comma (the whole value if there is none) }
  S := Len;
  while (S > 0) and (Value[S - 1] <> Ord(',')) do Dec(S);
  E := Len;
  TrimSpTab(Value, S, E);
  Result := AsciiEqualIgnoreCaseStr(Value + S, E - S, 'chunked');
end;

function TransferEncodingIsChunked(H: THttpHeaders): Boolean;
var
  I: SizeInt;
begin
  I := H.LastIndexOf(HN_TRANSFER_ENCODING);
  if I < 0 then
    Exit(False);
  Result := IsChunkedValue(H.ValuePtr(I), H.ValueLen(I));
end;

procedure InitTables;
var
  B: Integer;
begin
  for B := 0 to 255 do
  begin
    if (B >= Ord('A')) and (B <= Ord('Z')) then
      LowerMap[B] := B + 32
    else
      LowerMap[B] := B;
    TcharMap[B] := B in [Ord('A')..Ord('Z'), Ord('a')..Ord('z'), Ord('0')..Ord('9'),
      Ord('!'), Ord('#'), Ord('$'), Ord('%'), Ord('&'), Ord(''''), Ord('*'), Ord('+'),
      Ord('-'), Ord('.'), Ord('^'), Ord('_'), Ord('`'), Ord('|'), Ord('~')];
    ValueOkMap[B] := (B = 9) or ((B >= 32) and (B <> 127));
  end;
end;

initialization
  InitTables;
end.

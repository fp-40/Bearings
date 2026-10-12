{ bearings.http1.parser - the HTTP/1.x request head parser.

  An HTTP/1.1 request starts with a "head" in plain ASCII text:

    GET /index.html?x=1 HTTP/1.1\r\n        <- request line
    Host: example.com\r\n                    <- header fields,
    Content-Length: 5\r\n                    <- one per line
    \r\n                                     <- empty line: end of the head
    hello                                    <- body (framing: bearings.http1.decode)

  The request line holds three parts separated by single spaces: the
  method (a token such as GET or POST), the request-target (usually a path
  plus query string) and the protocol version. Each header field is
  "name: value"; the name is a token, the value may have spaces or tabs
  around it that are not part of the value. Lines end with CRLF; a bare LF
  is also accepted (RFC 9112 section 2.2 allows it). The head ends at the
  first empty line, so a complete head ends in CRLF CRLF (or LF LF).

  This unit parses one head from a byte buffer. It checks only the syntax;
  the meaning of the headers (framing, keep-alive, size limits, the status
  code sent for an error) is decided in bearings.http1.role.

  Why strict parsing matters: a server and a proxy in front of it must
  agree on where one request ends and the next begins. A parser that
  accepts bytes other parsers reject (spaces in unusual places, odd line
  endings, control bytes) lets an attacker craft input that the two read
  differently ("request smuggling"). So every byte is checked against the
  RFC 9110/9112 grammar, and the lenient options of TParserConfig are all
  off by default.

  Zero allocation: the parser creates no strings. The method, the target
  and each header name and value are returned as (Off, Len) slices of the
  caller's buffer. The caller owns the array of header slots and so
  decides how many headers fit (one more is peTooManyHeaders).

  Incremental use: bytes arrive from the socket in pieces. The caller
  calls ParseRequest on everything received so far; it returns psPartial
  until the head is complete. Each call starts again from the first byte.

  Main routines:
  - ParseRequest: request line plus header block; bearings.http1.role calls it.
  - ParseHeaderBlock / ParseHeaders: a header block on its own.
  - The byte-class scanners (ScanToken, ScanUri, ScanHeaderName,
    ScanHeaderValue) take (P, Len) and return the length of the longest
    prefix whose bytes all belong to the class. They are the inner loops of
    the parser; a faster (for example SIMD) version must keep exactly this
    contract. The unit tests check each scanner against the IsXxxChar
    functions.
  - IsValidUtf8, also used by bearings.http.uri.

  Threading: no shared mutable state. The lookup tables are filled once at
  unit initialization and only read afterwards, so any thread may call
  any routine. }
unit bearings.http1.parser;

{$mode objfpc}{$H+}
{$goto on} // ParseHeaderBlock is a state machine written with labels

interface

type
  { The kind of syntax error. peNone is used only when Status <> psError.
    bearings.http1.role maps each kind to its own error (and so to a 400 or 431
    response). }
  THttpParseError = (
    peNone,
    peHeaderName,     // Invalid byte in header name.
    peHeaderValue,    // Invalid byte in header value.
    peNewLine,        // Invalid byte in new line.
    peStatus,         // Invalid byte in a response status line (response side; never returned here).
    peToken,          // Invalid byte where token is required.
    peTooManyHeaders, // Parsed more headers than provided buffer can contain.
    peVersion         // Invalid byte in HTTP version.
  );

  { psComplete: a whole head was parsed. psPartial: the bytes so far are a
    valid beginning of a head; more are needed. psError: the bytes can not
    begin a valid head. }
  TParseStatus = (psComplete, psPartial, psError);

  TParseResult = record
    Status: TParseStatus;
    Error: THttpParseError; // set when Status = psError, else peNone
    Consumed: SizeInt;      // set when Status = psComplete: bytes of the head
                            // (offset of the first body byte), else 0
  end;

  { A byte range [Off, Off+Len) inside the caller's buffer. }
  TSlice = record
    Off: SizeInt;
    Len: SizeInt;
  end;

  THeaderSlice = record
    Name: TSlice;   // bytes are all tchar (ASCII)
    Value: TSlice;  // leading SP/HTAB skipped, trailing SP/HTAB/CR/LF trimmed
  end;
  PHeaderSlice = ^THeaderSlice;

  { The parsed request line and header count. On psPartial or psError the
    HasXxx flags tell how far the request line got (bearings.http1.role uses
    HasMethod to tell a bad method from a bad target when the error is
    peToken). }
  TParsedRequest = record
    HasMethod: Boolean;
    HasPath: Boolean;
    HasVersion: Boolean;
    Method: TSlice;
    Path: TSlice;      // request-target; validated as UTF-8
    Version: Byte;     // minor version: 0 = HTTP/1.0, 1 = HTTP/1.1
    NumHeaders: Integer;
      { Number of slots of Headers[] written.  On psComplete it is the
        header count. On psPartial it is the number of complete header
        lines parsed so far (those slots are filled too). }
  end;

  { Options that relax the parser. All default to False, the strict
    behaviour (see DefaultParserConfig). Only
    AllowMultipleSpacesInRequestLineDelimiters,
    AllowSpaceBeforeFirstHeaderName and IgnoreInvalidHeadersInRequests
    affect request parsing. The *InResponses fields are for parsing
    responses, which this unit does not do; they are kept so that one
    config value can describe both directions. }
  TParserConfig = record
    AllowSpacesAfterHeaderNameInResponses: Boolean;
    AllowObsoleteMultilineHeadersInResponses: Boolean;
    AllowMultipleSpacesInRequestLineDelimiters: Boolean;
    AllowMultipleSpacesInResponseStatusDelimiters: Boolean;
    AllowSpaceBeforeFirstHeaderName: Boolean;
    IgnoreInvalidHeadersInResponses: Boolean;
    IgnoreInvalidHeadersInRequests: Boolean;
  end;

  { The options seen by the header block parser, derived from
    TParserConfig after the request line has been parsed. }
  THeaderParserConfig = record
    AllowSpacesAfterHeaderName: Boolean;
    AllowObsoleteMultilineHeaders: Boolean;
    AllowSpaceBeforeFirstHeaderName: Boolean;
    IgnoreInvalidHeaders: Boolean;
  end;

function DefaultParserConfig: TParserConfig; inline;

{ Parses a request head from the start of the buffer.
  Buf, Len: the bytes received so far (Buf may be nil when Len = 0).
  Headers: caller-owned array of MaxHeaders slots (may be nil when
  MaxHeaders = 0). Req is fully (re)initialised on every call.
  Empty lines before the request line are skipped (RFC 9112 section 2.2
  asks servers to ignore at least one).
  Returns psComplete with Consumed = head length (the offset of the first
  body byte), psPartial when more bytes are needed, or psError with the
  error kind. }
function ParseRequest(Buf: PByte; Len: SizeInt; out Req: TParsedRequest;
  Headers: PHeaderSlice; MaxHeaders: Integer;
  const Config: TParserConfig): TParseResult; overload;
function ParseRequest(Buf: PByte; Len: SizeInt; out Req: TParsedRequest;
  Headers: PHeaderSlice; MaxHeaders: Integer): TParseResult; overload;

{ Parses a header block alone (header lines up to an empty line) with the
  strict default options. NumHeaders is set as in
  TParsedRequest.NumHeaders. The server does not call it (chunked trailers
  have their own parser in bearings.http1.decode); the tests do. }
function ParseHeaders(Buf: PByte; Len: SizeInt; Headers: PHeaderSlice;
  MaxHeaders: Integer; out NumHeaders: Integer): TParseResult;

{ The header block parser used by both routines above. Parses from
  Buf[Pos] and, on psComplete, leaves Pos after the terminating empty line;
  Consumed is the number of bytes parsed by this call (not counting the
  initial Pos). }
function ParseHeaderBlock(Buf: PByte; Len: SizeInt; var Pos: SizeInt;
  Headers: PHeaderSlice; MaxHeaders: Integer; out NumHeaders: Integer;
  const HConfig: THeaderParserConfig): TParseResult;

{ A short English description of an error kind, e.g. 'invalid header name'. }
function ParseErrorDescription(E: THttpParseError): string;

{ Byte classes. A token (method, header name) is made of the "tchar"
  bytes of RFC 9110 section 5.6.2. The request-target may hold any visible
  ASCII byte or any byte >= 0x80 (then checked as UTF-8). A header value
  may also hold spaces and tabs. Control bytes (NUL, CR, LF, DEL, ...) are
  in no class, so they end every scan. }
function IsTokenChar(B: Byte): Boolean; inline;       // tchar; method and header name
function IsUriChar(B: Byte): Boolean; inline;         // 0x21..0x7E, 0x80..0xFF
function IsHeaderValueChar(B: Byte): Boolean; inline; // HTAB, 0x20..0x7E, 0x80..0xFF

{ Scanners: return the length of the longest prefix of P[0..Len) whose
  bytes are all in the class. ScanHeaderName uses the token class. }
function ScanToken(P: PByte; Len: SizeInt): SizeInt;
function ScanUri(P: PByte; Len: SizeInt): SizeInt;
function ScanHeaderName(P: PByte; Len: SizeInt): SizeInt;
function ScanHeaderValue(P: PByte; Len: SizeInt): SizeInt;

{ Strict UTF-8 validation (RFC 3629): rejects overlong forms, UTF-16
  surrogates (U+D800..U+DFFF), code points above U+10FFFF and truncated
  sequences. }
function IsValidUtf8(P: PByte; Len: SizeInt): Boolean;

implementation

type
  TByteSet = set of Byte;

const
  { tchar = "!" / "#" / "$" / "%" / "&" / "'" / "*" / "+" / "-" / "." /
            "^" / "_" / "`" / "|" / "~" / DIGIT / ALPHA }
  TOKEN_CHARS: TByteSet = [Ord('A')..Ord('Z'), Ord('a')..Ord('z'),
    Ord('0')..Ord('9'), Ord('!'), Ord('#'), Ord('$'), Ord('%'), Ord('&'),
    Ord(''''), Ord('*'), Ord('+'), Ord('-'), Ord('.'), Ord('^'), Ord('_'),
    Ord('`'), Ord('|'), Ord('~')];
  { visible ASCII ('!'..'~') and every byte >= 0x80 }
  URI_CHARS: TByteSet = [$21..$7E, $80..$FF];
  { HTAB, SP, visible ASCII and every byte >= 0x80 (obs-text) }
  HEADER_VALUE_CHARS: TByteSet = [$09, $20..$7E, $80..$FF];

type
  TByteTable = array[Byte] of Boolean;

var
  { Lookup tables filled from the sets above at unit initialization.  The
    scan loops index these instead of using `in`, because FPC compiles
    `b in typed-const-set` to a memory-operand BT instruction, which is
    microcoded and several times slower than a byte load. }
  TokenTable, UriTable, HeaderValueTable: TByteTable;

const
  CR = 13;
  LF = 10;
  SP = 32;
  HTAB = 9;

  { Internal step results. }
  STEP_OK = 0;
  STEP_PARTIAL = 1;
  STEP_ERROR = 2;

function DefaultParserConfig: TParserConfig;
begin
  Result := Default(TParserConfig);
end;

function IsTokenChar(B: Byte): Boolean;
begin
  Result := TokenTable[B];
end;

function IsUriChar(B: Byte): Boolean;
begin
  Result := UriTable[B];
end;

function IsHeaderValueChar(B: Byte): Boolean;
begin
  Result := HeaderValueTable[B];
end;

{ ---- scanners (plain loops; a SIMD version would replace these) ---- }

function ScanToken(P: PByte; Len: SizeInt): SizeInt;
var
  I: SizeInt;
begin
  I := 0;
  while (I < Len) and TokenTable[P[I]] do
    Inc(I);
  Result := I;
end;

function ScanUri(P: PByte; Len: SizeInt): SizeInt;
var
  I: SizeInt;
begin
  I := 0;
  while (I < Len) and UriTable[P[I]] do
    Inc(I);
  Result := I;
end;

function ScanHeaderName(P: PByte; Len: SizeInt): SizeInt;
var
  I: SizeInt;
begin
  I := 0;
  while (I < Len) and TokenTable[P[I]] do
    Inc(I);
  Result := I;
end;

function ScanHeaderValue(P: PByte; Len: SizeInt): SizeInt;
var
  I: SizeInt;
begin
  I := 0;
  while (I < Len) and HeaderValueTable[P[I]] do
    Inc(I);
  Result := I;
end;

function IsValidUtf8(P: PByte; Len: SizeInt): Boolean;
var
  I: SizeInt;
  B, Lo, Hi: Byte;
  N, K: Integer;
begin
  Result := False;
  I := 0;
  while I < Len do
  begin
    B := P[I];
    if B < $80 then
    begin
      Inc(I);
      Continue;
    end;
    { N = number of continuation bytes. Lo..Hi is the allowed range of the
      second byte (RFC 3629 section 4): it excludes overlong forms (E0, F0),
      surrogates (ED) and code points above U+10FFFF (F4). C0, C1 and
      F5..FF never start a valid sequence. }
    Lo := $80;
    Hi := $BF;
    case B of
      $C2..$DF: N := 1;
      $E0: begin N := 2; Lo := $A0; end;
      $E1..$EC, $EE..$EF: N := 2;
      $ED: begin N := 2; Hi := $9F; end;
      $F0: begin N := 3; Lo := $90; end;
      $F1..$F3: N := 3;
      $F4: begin N := 3; Hi := $8F; end;
    else
      Exit;
    end;
    if Len - I - 1 < N then
      Exit;
    B := P[I + 1];
    if (B < Lo) or (B > Hi) then
      Exit;
    for K := 2 to N do
    begin
      B := P[I + K];
      if (B < $80) or (B > $BF) then
        Exit;
    end;
    Inc(I, N + 1);
  end;
  Result := True;
end;

{ ---- result helpers ---- }

function MakeComplete(Consumed: SizeInt): TParseResult; inline;
begin
  Result.Status := psComplete;
  Result.Error := peNone;
  Result.Consumed := Consumed;
end;

function MakePartial: TParseResult; inline;
begin
  Result.Status := psPartial;
  Result.Error := peNone;
  Result.Consumed := 0;
end;

function MakeError(E: THttpParseError): TParseResult; inline;
begin
  Result.Status := psError;
  Result.Error := E;
  Result.Consumed := 0;
end;

{ ---- request line pieces ----
  Each returns STEP_OK, STEP_PARTIAL or STEP_ERROR (with Err set) and
  advances Pos only past what it accepted. }

{ Skips empty lines (CRLF or LF) before the request line. A CR not
  followed by LF is an error. }
function SkipEmptyLines(Buf: PByte; Len: SizeInt; var Pos: SizeInt;
  out Err: THttpParseError): Integer; inline;
begin
  Err := peNone;
  while True do
  begin
    if Pos >= Len then
      Exit(STEP_PARTIAL);
    case Buf[Pos] of
      CR:
        begin
          Inc(Pos);
          if Pos >= Len then
            Exit(STEP_PARTIAL);
          if Buf[Pos] <> LF then
          begin
            Err := peNewLine;
            Exit(STEP_ERROR);
          end;
          Inc(Pos);
        end;
      LF:
        Inc(Pos);
    else
      Exit(STEP_OK);
    end;
  end;
end;

{ Skips a run of spaces; only used with
  AllowMultipleSpacesInRequestLineDelimiters. }
function SkipSpaces(Buf: PByte; Len: SizeInt; var Pos: SizeInt): Integer; inline;
begin
  while True do
  begin
    if Pos >= Len then
      Exit(STEP_PARTIAL);
    if Buf[Pos] <> SP then
      Exit(STEP_OK);
    Inc(Pos);
  end;
end;

{ The method: a token followed by one SP. The SP is consumed and is not
  part of the slice. }
function ParseMethod(Buf: PByte; Len: SizeInt; var Pos: SizeInt;
  out Slice: TSlice; out Err: THttpParseError): Integer; inline;
var
  Start, N: SizeInt;
  P: PByte;
begin
  Err := peNone;
  Start := Pos;
  P := Buf + Pos;
  { Fast paths for "GET " and "POST ". }
  if Len - Pos >= 4 then
  begin
    if (P[0] = Ord('G')) and (P[1] = Ord('E')) and (P[2] = Ord('T')) and
       (P[3] = SP) then
    begin
      Slice.Off := Start;
      Slice.Len := 3;
      Inc(Pos, 4);
      Exit(STEP_OK);
    end;
    if (Len - Pos >= 5) and (P[0] = Ord('P')) and (P[1] = Ord('O')) and
       (P[2] = Ord('S')) and (P[3] = Ord('T')) and (P[4] = SP) then
    begin
      Slice.Off := Start;
      Slice.Len := 4;
      Inc(Pos, 5);
      Exit(STEP_OK);
    end;
  end;
  { The first byte must be a tchar (an SP here means an empty method). }
  if Pos >= Len then
    Exit(STEP_PARTIAL);
  if not TokenTable[Buf[Pos]] then
  begin
    Err := peToken;
    Exit(STEP_ERROR);
  end;
  N := 1 + ScanToken(Buf + Pos + 1, Len - Pos - 1);
  Pos := Start + N;
  if Pos >= Len then
    Exit(STEP_PARTIAL);
  if Buf[Pos] <> SP then
  begin
    Err := peToken;
    Exit(STEP_ERROR);
  end;
  Slice.Off := Start;
  Slice.Len := N;
  Inc(Pos);
  Result := STEP_OK;
end;

{ The request-target: a non-empty run of URI bytes followed by one SP; it
  must be valid UTF-8. Any other byte where the SP should be (a control
  byte, for example) is a peToken error. }
function ParseUri(Buf: PByte; Len: SizeInt; var Pos: SizeInt;
  out Slice: TSlice; out Err: THttpParseError): Integer; inline;
var
  Start, N: SizeInt;
begin
  Err := peNone;
  Start := Pos;
  N := ScanUri(Buf + Pos, Len - Pos);
  Pos := Start + N;
  if Pos >= Len then
    Exit(STEP_PARTIAL);
  if (Buf[Pos] <> SP) or (N = 0) or not IsValidUtf8(Buf + Start, N) then
  begin
    Inc(Pos);
    Err := peToken;
    Exit(STEP_ERROR);
  end;
  Slice.Off := Start;
  Slice.Len := N;
  Inc(Pos);
  Result := STEP_OK;
end;

{ The version: exactly "HTTP/1.0" or "HTTP/1.1" (Minor = 0 or 1). With
  fewer than 8 bytes available, a prefix of "HTTP/1." is Partial and
  anything else a Version error, so a wrong version is reported as soon as
  its first wrong byte arrives. }
function ParseVersion(Buf: PByte; Len: SizeInt; var Pos: SizeInt;
  out Minor: Byte; out Err: THttpParseError): Integer; inline;
const
  PREFIX: array[0..6] of Byte = (Ord('H'), Ord('T'), Ord('T'), Ord('P'),
    Ord('/'), Ord('1'), Ord('.'));
var
  P: PByte;
  I, Avail: SizeInt;
begin
  Err := peNone;
  Minor := 0;
  P := Buf + Pos;
  Avail := Len - Pos;
  if Avail >= 8 then
  begin
    Inc(Pos, 8);
    if (P[0] = Ord('H')) and (P[1] = Ord('T')) and (P[2] = Ord('T')) and
       (P[3] = Ord('P')) and (P[4] = Ord('/')) and (P[5] = Ord('1')) and
       (P[6] = Ord('.')) then
    begin
      if P[7] = Ord('1') then
      begin
        Minor := 1;
        Exit(STEP_OK);
      end;
      if P[7] = Ord('0') then
      begin
        Minor := 0;
        Exit(STEP_OK);
      end;
    end;
    Err := peVersion;
    Exit(STEP_ERROR);
  end;
  for I := 0 to Avail - 1 do
  begin
    if I > 6 then
      Break;
    if P[I] <> PREFIX[I] then
    begin
      Pos := Pos + I + 1;
      Err := peVersion;
      Exit(STEP_ERROR);
    end;
  end;
  Pos := Len;
  Result := STEP_PARTIAL;
end;

{ A line end: CRLF or LF; anything else is a NewLine error. }
function ParseNewline(Buf: PByte; Len: SizeInt; var Pos: SizeInt;
  out Err: THttpParseError): Integer; inline;
begin
  Err := peNone;
  if Pos >= Len then
    Exit(STEP_PARTIAL);
  if Buf[Pos] = LF then
  begin
    Inc(Pos);
    Exit(STEP_OK);
  end;
  if Buf[Pos] <> CR then
  begin
    Err := peNewLine;
    Exit(STEP_ERROR);
  end;
  Inc(Pos);
  if Pos >= Len then
    Exit(STEP_PARTIAL);
  if Buf[Pos] <> LF then
  begin
    Err := peNewLine;
    Exit(STEP_ERROR);
  end;
  Inc(Pos);
  Result := STEP_OK;
end;

{ ---- header block ---- }

{ Handles an invalid byte B in a header line (B is already consumed).
  Without Ignore (the default) it is an error of kind E. With
  IgnoreInvalidHeaders the rest of the line is skipped and the header
  dropped; a NUL, or a CR not followed by LF, is still an error of kind E.
  Returns STEP_OK when the line was skipped and parsing must resume at
  Pos. }
function SkipInvalidLine(Buf: PByte; Len: SizeInt; var Pos: SizeInt;
  B: Byte; Ignore: Boolean; E: THttpParseError;
  out Err: THttpParseError): Integer;
begin
  Err := E;
  if not Ignore then
    Exit(STEP_ERROR);
  while True do
  begin
    if B = CR then
    begin
      if Pos >= Len then
        Exit(STEP_PARTIAL);
      B := Buf[Pos];
      Inc(Pos);
      if B <> LF then
        Exit(STEP_ERROR);
      Break;
    end;
    if B = LF then
      Break;
    if B = 0 then
      Exit(STEP_ERROR);
    if Pos >= Len then
      Exit(STEP_PARTIAL);
    B := Buf[Pos];
    Inc(Pos);
  end;
  Err := peNone;
  Result := STEP_OK;
end;

{ States (labels): NextHeader reads the first byte of a line (an empty
  line ends the head); WhitespaceAfterColon skips the optional whitespace
  before the value; ValueLines scans the value up to the line end;
  ValueDone stores the header in the next slot. "obs-fold" (a line
  starting with SP or HTAB that continues the previous value, obsolete
  since RFC 7230) is accepted only with AllowObsoleteMultilineHeaders,
  which requests never use. }
function ParseHeaderBlock(Buf: PByte; Len: SizeInt; var Pos: SizeInt;
  Headers: PHeaderSlice; MaxHeaders: Integer; out NumHeaders: Integer;
  const HConfig: THeaderParserConfig): TParseResult;
label
  NextHeader, WhitespaceAfterColon, ValueLines, ValueDone;
var
  Start, NameStart, NameLen, ValStart, ValEnd, TermPos: SizeInt;
  B: Byte;
  Skip, Step: Integer;
  Err: THttpParseError;
  H: PHeaderSlice;
begin
  NumHeaders := 0;
  Start := Pos;

NextHeader:
  { A newline here means the head is over. }
  if Pos >= Len then
    Exit(MakePartial);
  B := Buf[Pos];
  Inc(Pos);
  if B = CR then
  begin
    if Pos >= Len then
      Exit(MakePartial);
    if Buf[Pos] <> LF then
      Exit(MakeError(peNewLine));
    Inc(Pos);
    Exit(MakeComplete(Pos - Start));
  end;
  if B = LF then
    Exit(MakeComplete(Pos - Start));

  if not TokenTable[B] then
  begin
    if HConfig.AllowSpaceBeforeFirstHeaderName and (NumHeaders = 0) and
       ((B = SP) or (B = HTAB)) then
    begin
      while (Pos < Len) and ((Buf[Pos] = SP) or (Buf[Pos] = HTAB)) do
        Inc(Pos);
      goto NextHeader;
    end;
    Step := SkipInvalidLine(Buf, Len, Pos, B, HConfig.IgnoreInvalidHeaders,
      peHeaderName, Err);
    if Step = STEP_OK then goto NextHeader;
    if Step = STEP_PARTIAL then Exit(MakePartial);
    Exit(MakeError(Err));
  end;

  { Header name: a tchar run up to ':'. A space or tab before the colon is
    an error (RFC 9112 section 5.1 requires servers to reject it, because
    other parsers may read such a name differently). }
  NameStart := Pos - 1;
  Pos := Pos + ScanHeaderName(Buf + Pos, Len - Pos);
  if Pos >= Len then
    Exit(MakePartial);
  NameLen := Pos - NameStart;
  B := Buf[Pos];
  Inc(Pos);
  if B = Ord(':') then
    goto WhitespaceAfterColon;
  if HConfig.AllowSpacesAfterHeaderName then
    while (B = SP) or (B = HTAB) do
    begin
      if Pos >= Len then
        Exit(MakePartial);
      B := Buf[Pos];
      Inc(Pos);
      if B = Ord(':') then
        goto WhitespaceAfterColon;
    end;
  Step := SkipInvalidLine(Buf, Len, Pos, B, HConfig.IgnoreInvalidHeaders,
    peHeaderName, Err);
  if Step = STEP_OK then goto NextHeader;
  if Step = STEP_PARTIAL then Exit(MakePartial);
  Exit(MakeError(Err));

  { Skip optional whitespace between the colon and the value. }
WhitespaceAfterColon:
  if Pos >= Len then
    Exit(MakePartial);
  TermPos := Pos;
  B := Buf[Pos];
  Inc(Pos);
  if (B = SP) or (B = HTAB) then
    goto WhitespaceAfterColon;
  if HeaderValueTable[B] then
  begin
    ValStart := Pos - 1;
    goto ValueLines;
  end;
  { Empty value: the line ends right after the whitespace. }
  if B = CR then
  begin
    if Pos >= Len then
      Exit(MakePartial);
    if Buf[Pos] <> LF then
      Exit(MakeError(peHeaderValue));
    Inc(Pos);
  end
  else if B <> LF then
  begin
    Step := SkipInvalidLine(Buf, Len, Pos, B, HConfig.IgnoreInvalidHeaders,
      peHeaderValue, Err);
    if Step = STEP_OK then goto NextHeader;
    if Step = STEP_PARTIAL then Exit(MakePartial);
    Exit(MakeError(Err));
  end;
  if HConfig.AllowObsoleteMultilineHeaders then
  begin
    if Pos >= Len then
      Exit(MakePartial);
    if (Buf[Pos] = SP) or (Buf[Pos] = HTAB) then
      goto WhitespaceAfterColon;
  end;
  { The empty slice points at the line terminator. }
  ValStart := TermPos;
  ValEnd := TermPos;
  goto ValueDone;

ValueLines:
  { Value bytes up to the end of the line. }
  Pos := Pos + ScanHeaderValue(Buf + Pos, Len - Pos);
  if Pos >= Len then
    Exit(MakePartial);
  B := Buf[Pos];
  Inc(Pos);
  if B = CR then
  begin
    if Pos >= Len then
      Exit(MakePartial);
    if Buf[Pos] <> LF then
      Exit(MakeError(peHeaderValue));
    Inc(Pos);
    Skip := 2;
  end
  else if B = LF then
    Skip := 1
  else
  begin
    Step := SkipInvalidLine(Buf, Len, Pos, B, HConfig.IgnoreInvalidHeaders,
      peHeaderValue, Err);
    if Step = STEP_OK then goto NextHeader;
    if Step = STEP_PARTIAL then Exit(MakePartial);
    Exit(MakeError(Err));
  end;
  if HConfig.AllowObsoleteMultilineHeaders then
  begin
    if Pos >= Len then
      Exit(MakePartial);
    if (Buf[Pos] = SP) or (Buf[Pos] = HTAB) then
      goto ValueLines;
  end;
  ValEnd := Pos - Skip;
  { Trim trailing whitespace (SP, HTAB, and the CR/LF of folded lines when
    AllowObsoleteMultilineHeaders is on). }
  while (ValEnd > ValStart) and (Buf[ValEnd - 1] in [SP, HTAB, CR, LF]) do
    Dec(ValEnd);

ValueDone:
  if NumHeaders >= MaxHeaders then
    Exit(MakeError(peTooManyHeaders));
  H := Headers + NumHeaders;
  H^.Name.Off := NameStart;
  H^.Name.Len := NameLen;
  H^.Value.Off := ValStart;
  H^.Value.Len := ValEnd - ValStart;
  Inc(NumHeaders);
  goto NextHeader;
end;

function ParseRequest(Buf: PByte; Len: SizeInt; out Req: TParsedRequest;
  Headers: PHeaderSlice; MaxHeaders: Integer;
  const Config: TParserConfig): TParseResult;
var
  Pos: SizeInt;
  Err: THttpParseError;
  Step: Integer;
  HConfig: THeaderParserConfig;
begin
  Req.HasMethod := False;
  Req.HasPath := False;
  Req.HasVersion := False;
  Req.Method.Off := 0;
  Req.Method.Len := 0;
  Req.Path.Off := 0;
  Req.Path.Len := 0;
  Req.Version := 0;
  Req.NumHeaders := 0;
  Pos := 0;

  Step := SkipEmptyLines(Buf, Len, Pos, Err);
  if Step <> STEP_OK then
    if Step = STEP_PARTIAL then Exit(MakePartial) else Exit(MakeError(Err));

  Step := ParseMethod(Buf, Len, Pos, Req.Method, Err);
  if Step <> STEP_OK then
    if Step = STEP_PARTIAL then Exit(MakePartial) else Exit(MakeError(Err));
  Req.HasMethod := True;

  if Config.AllowMultipleSpacesInRequestLineDelimiters then
    if SkipSpaces(Buf, Len, Pos) = STEP_PARTIAL then
      Exit(MakePartial);

  Step := ParseUri(Buf, Len, Pos, Req.Path, Err);
  if Step <> STEP_OK then
    if Step = STEP_PARTIAL then Exit(MakePartial) else Exit(MakeError(Err));
  Req.HasPath := True;

  if Config.AllowMultipleSpacesInRequestLineDelimiters then
    if SkipSpaces(Buf, Len, Pos) = STEP_PARTIAL then
      Exit(MakePartial);

  Step := ParseVersion(Buf, Len, Pos, Req.Version, Err);
  if Step <> STEP_OK then
    if Step = STEP_PARTIAL then Exit(MakePartial) else Exit(MakeError(Err));
  Req.HasVersion := True;

  Step := ParseNewline(Buf, Len, Pos, Err);
  if Step <> STEP_OK then
    if Step = STEP_PARTIAL then Exit(MakePartial) else Exit(MakeError(Err));

  HConfig.AllowSpacesAfterHeaderName := False;
  HConfig.AllowObsoleteMultilineHeaders := False;
  HConfig.AllowSpaceBeforeFirstHeaderName := Config.AllowSpaceBeforeFirstHeaderName;
  HConfig.IgnoreInvalidHeaders := Config.IgnoreInvalidHeadersInRequests;
  Result := ParseHeaderBlock(Buf, Len, Pos, Headers, MaxHeaders,
    Req.NumHeaders, HConfig);
  if Result.Status = psComplete then
    Result.Consumed := Pos;
end;

function ParseRequest(Buf: PByte; Len: SizeInt; out Req: TParsedRequest;
  Headers: PHeaderSlice; MaxHeaders: Integer): TParseResult;
begin
  Result := ParseRequest(Buf, Len, Req, Headers, MaxHeaders,
    DefaultParserConfig);
end;

function ParseHeaders(Buf: PByte; Len: SizeInt; Headers: PHeaderSlice;
  MaxHeaders: Integer; out NumHeaders: Integer): TParseResult;
var
  Pos: SizeInt;
  HConfig: THeaderParserConfig;
begin
  Pos := 0;
  HConfig := Default(THeaderParserConfig);
  Result := ParseHeaderBlock(Buf, Len, Pos, Headers, MaxHeaders, NumHeaders,
    HConfig);
end;

function ParseErrorDescription(E: THttpParseError): string;
begin
  case E of
    peHeaderName: Result := 'invalid header name';
    peHeaderValue: Result := 'invalid header value';
    peNewLine: Result := 'invalid new line';
    peStatus: Result := 'invalid response status';
    peToken: Result := 'invalid token';
    peTooManyHeaders: Result := 'too many headers';
    peVersion: Result := 'invalid HTTP version';
  else
    Result := '';
  end;
end;

procedure InitTables;
var
  B: Byte;
begin
  for B := Low(Byte) to High(Byte) do
  begin
    TokenTable[B] := B in TOKEN_CHARS;
    UriTable[B] := B in URI_CHARS;
    HeaderValueTable[B] := B in HEADER_VALUE_CHARS;
  end;
end;

initialization
  InitTables;
end.

{ bearings.http1.role - the server side of HTTP/1.1 message heads: parsing a
  request head and encoding a response head.

  A request head is the request line ("GET /path?q=1 HTTP/1.1") followed by
  header field lines ("Host: example.com"), each ended by CRLF, and an empty
  line: the head ends at CRLF CRLF. The body, if any, follows. A response
  head is the status line ("HTTP/1.1 200 OK") and header lines, also ended
  by an empty line.

  Parsing (ServerParse, ServerParseHeaders). The byte-level syntax is
  checked by bearings.http1.parser; this unit then applies the HTTP rules:
  - the method, the target (split by bearings.http.uri), the version (1.0 or
    1.1);
  - message framing: how long the request body is (RFC 9112 section 6.3).
    "Transfer-Encoding: chunked" means a chunked body (bearings.http1.decode);
    else "Content-Length: n" means n bytes; else there is no body. A
    Transfer-Encoding whose last coding is not chunked, a Transfer-Encoding
    in an HTTP/1.0 request, an invalid Content-Length, and several
    Content-Length values that differ are rejected with 400. When a request
    has both Transfer-Encoding and Content-Length, Transfer-Encoding wins,
    the Content-Length lines are dropped from the header list, and the
    connection is closed after the response. These rules matter because a
    proxy in front of the server and the server must agree on where a
    request ends; if they disagree, an attacker can hide a second request
    inside the body of the first one ("request smuggling");
  - keep-alive: HTTP/1.1 keeps the connection open unless "Connection:
    close"; HTTP/1.0 closes it unless "Connection: keep-alive";
  - "Expect: 100-continue" (the client waits for an interim "100 Continue"
    response before it sends the body), "Upgrade" (HTTP/1.1 only) and
    CONNECT (both ask to switch the connection to another protocol);
  - limits: a target longer than MAX_URI_LEN gives 414 URI Too Long; too
    many header lines, a head longer than MaxHeaderSize, or a header name
    of 64 KiB or more gives 431 Request Header Fields Too Large.

  Parsing does not allocate or copy. Method, target and header names and
  values stay in the caller's read buffer: the caller's THttpHeaders gets
  external entries (AddExternal) whose offsets are relative to Buf, and the
  target is split into slices (bearings.http.uri). Header names keep the case in
  which they were received. The parser fills an array of header slots: up
  to DEFAULT_MAX_HEADERS slots are on the stack; a larger MaxHeaders
  allocates the array on the heap for each call.

  Encoding (ServerEncode) writes the status line and the header lines of
  the response and chooses the body framing, returned as a TEncoder
  (bearings.http1.encode): Content-Length when the length is known, chunked when
  it is not (HTTP/1.1), or "until the connection closes" (HTTP/1.0). It
  also adds Date and a zero Content-Length when needed, and removes framing
  headers that a response must not have (HEAD, 1xx, 204, 304 and 2xx to
  CONNECT responses have no body). Header lines with the same name are
  written next to each other, at the position of the name's first line;
  Connection, Transfer-Encoding and Trailer lines are joined into one line
  each. ServerEncode does not modify the response head. Header names are
  written in lowercase, or in title case with TitleCaseHeaders, or with
  the spellings found in TResponseHead.CaseMap. A 1xx status other than
  101 cannot be sent this way; a 500 head is written instead and the result
  is serUnsupportedStatusCode.

  Encoding computes an upper bound of the head size first and grows the
  output buffer at most once. The routines on the per-request path
  (ServerParseSlots, EncodeHead, MakeEncoder and the Set*Encoder helpers)
  have no managed locals or temporaries, so FPC gives them no implicit
  exception frame (a setjmp per call on Linux); tools/check-hot-asm.sh
  checks this. The heap fallbacks (MaxHeaders > DEFAULT_MAX_HEADERS, more
  than INLINE_DONE_FLAGS response headers) are separate routines.

  Used by bearings.http1.io (parsing the head in the read buffer) and
  bearings.http1.conn (encoding the response head).

  Threading: no shared mutable state except the thread-local Date cache of
  bearings.http.date (used when no Date bytes are given); the routines may run on
  any thread. }
unit bearings.http1.role;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

uses
  SysUtils, bearings.rt.buf, bearings.http1.parser, bearings.http.headers, bearings.http.uri, bearings.http1.encode,
  bearings.http1.decode, bearings.http.date, bearings.http1.reason;

const
  { The longest request target accepted; longer gives 414 URI Too Long. }
  MAX_URI_LEN = 65534;

  { The body length of a parsed message: a byte count, or one of two
    reserved values for a chunked body and for a body that ends when the
    connection closes (only responses can have the latter). }
  DECODED_LENGTH_ZERO = QWord(0);
  DECODED_LENGTH_CLOSE_DELIMITED = High(QWord);
  DECODED_LENGTH_CHUNKED = High(QWord) - 1;
  DECODED_LENGTH_MAX = High(QWord) - 2;

type
  { The HTTP version. A request is parsed as hv10 or hv11 only. }
  THttpVersion = (hv09, hv10, hv11, hv2, hv3);

  { The request method. hmNone: no method known; hmExtension: a method
    that is not one of the standard ones (the text is in MethodSlice). }
  THttpMethod = (hmNone, hmOptions, hmGet, hmPost, hmPut, hmDelete, hmHead,
    hmTrace, hmConnect, hmPatch, hmExtension);

  { Why a request head was rejected. ServerErrorStatus maps it to the
    automatic response status. h1peStatus is for response status lines;
    h1peVersionH2 is used by the connection when the client sent the
    HTTP/2 connection preface. }
  TH1ParseError = (
    h1peNone,
    h1peMethod,
    h1peVersion,
    h1peVersionH2,
    h1peUri,
    h1peUriTooLong,
    h1peHeaderToken,                       { invalid byte in a header line }
    h1peHeaderContentLengthInvalid,        { bad or conflicting Content-Length }
    h1peHeaderTransferEncodingInvalid,     { last coding is not chunked }
    h1peHeaderTransferEncodingUnexpected,  { Transfer-Encoding in HTTP/1.0 }
    h1peTooLarge,
    h1peStatus,
    h1peInternal,
    h1peProxyProtocol                      { the connection's PROXY protocol header is missing or invalid (bearings.rt.proxyproto) }
  );

  { spsComplete: a whole head was parsed; spsPartial: the head is not
    complete yet, read more bytes; spsError: the head is invalid. }
  TServerParseStatus = (spsComplete, spsPartial, spsError);

  { The parse settings of a connection (set from TH1Config). }
  TH1ParseContext = record
    ParserConfig: TParserConfig;   { leniency switches of bearings.http1.parser }
    MaxHeaders: Integer;           { < 0: DEFAULT_MAX_HEADERS }
    MaxHeaderSize: SizeInt;        { < 0: no limit of its own }
  end;

  { The result of parsing a request head. Slices are offsets into the parsed
    buffer. }
  TParsedRequestHead = record
    Error: TH1ParseError;          { set when the result is spsError }
    UriError: TUriError;           { the URI parser's reason when Error = h1peUri came from it }
    HeadLen: SizeInt;              { bytes of the head, up to and including the final CRLF CRLF }
    Method: THttpMethod;
    MethodSlice: TSlice;
    Target: TSlice;                { the request-target as sent }
    Uri: TUriParts;                { the target split into its parts; offsets into Buf }
    Version: THttpVersion;         { hv10 or hv11 }
    Decode: QWord;                 { the body length: DECODED_LENGTH_ZERO, _CHUNKED or a byte count }
    ExpectContinue: Boolean;       { "Expect: 100-continue" }
    KeepAlive: Boolean;            { the client allows another request on this connection }
    WantsUpgrade: Boolean;         { an Upgrade header (HTTP/1.1) or a CONNECT request }
    { True when the whole head was recognised (HeadLen is valid): on
      spsComplete, and on the errors found after the head was complete
      (URI, Transfer-Encoding, Content-Length). False on spsPartial and on
      syntax errors. When it is True, the read path (TH1Io.Parse in
      bearings.http1.io) removes HeadLen bytes from its buffer. }
    HeadSplit: Boolean;
  end;

  { What the application knows about the response body length:
    blkNone: no body; blkKnown: BodyLen bytes; blkUnknown: a body whose
    length is not known in advance (a stream). }
  TBodyLengthKind = (blkNone, blkKnown, blkUnknown);

  { The response head given to ServerEncode. No managed fields: the reason
    is a slice of memory the caller keeps alive until the head is encoded
    (a TReasonPhrase, a copy in the exchange, or a constant). }
  TResponseHead = record
    Version: THttpVersion;         { hv10, hv11 or hv2 (written as HTTP/1.1) }
    Status: Word;                  { 100..999 }
    HasReason: Boolean;            { False: the standard phrase of Status (bearings.http1.reason) }
    ReasonP: PByte;                { the phrase bytes, already checked (TReasonPhrase / FindInvalidReasonByte) }
    ReasonLen: SizeInt;
    Headers: THttpHeaders;         { nil = no headers }
    { nil, or a list whose entry NAMES give the spelling to write for each
      header name (values are ignored). Passing Headers itself writes every
      name as stored. }
    CaseMap: THttpHeaders;
  end;

  { The connection-side inputs of ServerEncode. }
  TServerEncodeParams = record
    Body: TBodyLengthKind;
    BodyLen: QWord;                { the length when Body = blkKnown }
    KeepAlive: Boolean;            { False: the connection closes after this response }
    ReqMethod: THttpMethod;        { the request's method (HEAD and CONNECT change the rules); hmNone = unknown }
    TitleCaseHeaders: Boolean;
    DateHeader: Boolean;
    Date: PByte;                   { 29 bytes of IMF-fixdate; nil = this thread's cache (DateBuffer) }
  end;

  { What the connection supplies to the TByteVec form of ServerEncode. }
  TEncodeContext = record
    Date: PByte;                      { the loop's 29 date bytes; nil = this thread's cache }
    Trailers: PTrailerFieldSet;       { per-connection scratch for declared trailer names; nil = default }
  end;

  TServerEncodeResult = (
    serOk,
    serUserHeader,                 { the application's framing headers are invalid; nothing written }
    serUnsupportedStatusCode       { 1xx (not 101): a 500 head was written instead }
  );

function DefaultParseContext: TH1ParseContext;
function DefaultResponseHead: TResponseHead;     { HTTP/1.1 200, no headers }
function DefaultEncodeParams: TServerEncodeParams;

{ True if Buf contains the end of a head: CR LF CR LF, LF LF or LF CR LF
  (the parser accepts a bare LF as a line end). Scans only from PrevLen - 3,
  where PrevLen is the buffer length at the previous attempt, so a head
  that arrives in many small reads is not scanned again from the start
  each time. }
function IsCompleteFast(Buf: PByte; Len: SizeInt; PrevLen: SizeInt): Boolean;

{ The entry point of the read path. spsPartial for an empty buffer; when
  PrevLen >= 0 (an earlier attempt on this head returned spsPartial) and
  IsCompleteFast finds no end of head, spsPartial without parsing;
  otherwise ServerParse. Headers is left empty on spsPartial. }
function ServerParseHeaders(Buf: PByte; Len: SizeInt; PrevLen: SizeInt;
  const Ctx: TH1ParseContext; Headers: THttpHeaders;
  out Msg: TParsedRequestHead): TServerParseStatus;

{ Parses a request head. Buf/Len: the bytes read so far, from the start of
  the request head. Headers is cleared, its ExternalBase set to Buf, and on
  spsComplete filled with external entries; on spsPartial and spsError it
  is left empty. }
function ServerParse(Buf: PByte; Len: SizeInt; const Ctx: TH1ParseContext;
  Headers: THttpHeaders; out Msg: TParsedRequestHead): TServerParseStatus;

{ Encodes a response head. Appends it at Dst[DstLen] and advances DstLen
  (not on serUserHeader). Encoder is the body encoder to use. The date
  comes from P.Date; declared trailer names go to the per-thread default
  set. Used by the unit tests. }
function ServerEncode(const Head: TResponseHead; const P: TServerEncodeParams;
  var Dst: TBytes; var DstLen: SizeInt; out Encoder: TEncoder): TServerEncodeResult; overload;
{ The form the connection uses: the same bytes, appended to Dst (Dst.Len
  advanced except on serUserHeader). Date from Ctx.Date (P.Date is
  ignored); declared trailer names into Ctx.Trailers. Pool: where Dst takes
  a larger block (nil = heap). }
function ServerEncode(const Head: TResponseHead; const P: TServerEncodeParams;
  const Ctx: TEncodeContext; var Dst: TByteVec; Pool: PBlockPool;
  out Encoder: TEncoder): TServerEncodeResult; overload;

{ True when ServerEncode cannot encode this head because of its version:
  the version is not HTTP/1.0, 1.1 or 2 and the status is not a 1xx other
  than 101 (those are replaced by an HTTP/1.1 500 head first). ServerEncode
  raises EArgumentException in that case; the connection checks this first
  and raises EH1Panic instead. }
function ResponseVersionPanics(Status: Word; Version: THttpVersion): Boolean;

{ The status of the automatic response sent for a parse error, or 0 when
  no response is sent (the connection is just closed). 400 for method,
  header, URI and version errors, 431 for h1peTooLarge, 414 for
  h1peUriTooLong. }
function ServerErrorStatus(E: TH1ParseError): Word;

{ The error message text for E. }
function H1ParseErrorDescription(E: TH1ParseError): string;

{ The method of a method token: a standard method (method names are
  case-sensitive, so "get" is an extension method) or hmExtension. }
function MethodFromBytes(P: PByte; Len: SizeInt): THttpMethod;
{ The name of a standard method ('' for hmNone/hmExtension). }
function HttpMethodName(M: THttpMethod): RawByteString;

{ Initializes the body decoder for a body length: DECODED_LENGTH_CHUNKED ->
  InitChunked, DECODED_LENGTH_CLOSE_DELIMITED -> InitEof, n ->
  InitLength(n). MaxHeaders/MaxHeaderSize limit the trailer section of a
  chunked body; < 0 selects the decoder's defaults (see TDecoder.InitChunked). }
procedure InitDecoderFor(var D: TDecoder; Len: QWord; MaxHeaders: SizeInt = -1;
  MaxHeaderSize: SizeInt = -1);

implementation

var
  { ASCII lowercase table (AsciiLower cannot be inlined across units);
    filled in the initialization section }
  Lower: array[Byte] of Byte;

type
  THdrKind = (hkOther, hkContentLength, hkTransferEncoding, hkConnection,
    hkDate, hkTrailer, hkExpect, hkUpgrade);

const
  STR_CONTENT_LENGTH: array[0..13] of AnsiChar = 'content-length';
  STR_TRANSFER_ENCODING: array[0..16] of AnsiChar = 'transfer-encoding';
  STR_CONNECTION: array[0..9] of AnsiChar = 'connection';
  STR_DATE: array[0..3] of AnsiChar = 'date';
  STR_TRAILER: array[0..6] of AnsiChar = 'trailer';
  STR_EXPECT: array[0..5] of AnsiChar = 'expect';
  STR_UPGRADE: array[0..6] of AnsiChar = 'upgrade';
  STR_100_CONTINUE: array[0..11] of AnsiChar = '100-continue';

function EqLower(P: PByte; Lit: PAnsiChar; Len: SizeInt): Boolean; inline;
var
  I: SizeInt;
begin
  for I := 0 to Len - 1 do
    if Lower[P[I]] <> Byte(Lit[I]) then
      Exit(False);
  Result := True;
end;

function ClassifyName(P: PByte; Len: SizeInt): THdrKind;
begin
  Result := hkOther;
  case Len of
    4: if EqLower(P, @STR_DATE[0], 4) then Result := hkDate;
    6: if EqLower(P, @STR_EXPECT[0], 6) then Result := hkExpect;
    7: if EqLower(P, @STR_TRAILER[0], 7) then Result := hkTrailer
       else if EqLower(P, @STR_UPGRADE[0], 7) then Result := hkUpgrade;
    10: if EqLower(P, @STR_CONNECTION[0], 10) then Result := hkConnection;
    14: if EqLower(P, @STR_CONTENT_LENGTH[0], 14) then Result := hkContentLength;
    17: if EqLower(P, @STR_TRANSFER_ENCODING[0], 17) then Result := hkTransferEncoding;
  end;
end;

function DefaultParseContext: TH1ParseContext;
begin
  Result.ParserConfig := DefaultParserConfig;
  Result.MaxHeaders := -1;
  Result.MaxHeaderSize := -1;
end;

function DefaultResponseHead: TResponseHead;
begin
  Result.Version := hv11;
  Result.Status := 200;
  Result.HasReason := False;
  Result.ReasonP := nil;
  Result.ReasonLen := 0;
  Result.Headers := nil;
  Result.CaseMap := nil;
end;

function DefaultEncodeParams: TServerEncodeParams;
begin
  Result.Body := blkNone;
  Result.BodyLen := 0;
  Result.KeepAlive := True;
  Result.ReqMethod := hmNone;
  Result.TitleCaseHeaders := False;
  Result.DateHeader := True;
  Result.Date := nil;
end;

function MethodFromBytes(P: PByte; Len: SizeInt): THttpMethod;

  function Eq(const S: ShortString): Boolean; inline;
  begin
    Result := CompareByte(P^, S[1], Len) = 0;
  end;

begin
  Result := hmExtension;
  case Len of
    3: if Eq('GET') then Result := hmGet
       else if Eq('PUT') then Result := hmPut;
    4: if Eq('POST') then Result := hmPost
       else if Eq('HEAD') then Result := hmHead;
    5: if Eq('PATCH') then Result := hmPatch
       else if Eq('TRACE') then Result := hmTrace;
    6: if Eq('DELETE') then Result := hmDelete;
    7: if Eq('OPTIONS') then Result := hmOptions
       else if Eq('CONNECT') then Result := hmConnect;
  end;
end;

function HttpMethodName(M: THttpMethod): RawByteString;
begin
  case M of
    hmOptions: Result := 'OPTIONS';
    hmGet: Result := 'GET';
    hmPost: Result := 'POST';
    hmPut: Result := 'PUT';
    hmDelete: Result := 'DELETE';
    hmHead: Result := 'HEAD';
    hmTrace: Result := 'TRACE';
    hmConnect: Result := 'CONNECT';
    hmPatch: Result := 'PATCH';
  else
    Result := '';
  end;
end;

procedure InitDecoderFor(var D: TDecoder; Len: QWord; MaxHeaders: SizeInt;
  MaxHeaderSize: SizeInt);
begin
  if Len = DECODED_LENGTH_CHUNKED then
    D.InitChunked(MaxHeaders, MaxHeaderSize)
  else if Len = DECODED_LENGTH_CLOSE_DELIMITED then
    D.InitEof
  else
    D.InitLength(Len);
end;

{ ---------------------------------------------------------------- parse }

function IsCompleteFast(Buf: PByte; Len: SizeInt; PrevLen: SizeInt): Boolean;
var
  Start, I, N: SizeInt;
  P: PByte;
begin
  Start := PrevLen - 3;
  if Start < 0 then
    Start := 0;
  if Start > Len then
    Start := Len;
  P := Buf + Start;
  N := Len - Start;
  for I := 0 to N - 1 do
  begin
    if P[I] = 13 then
    begin
      { bytes[i+1..].chunks(3).next() == Some(b"\n\r\n") }
      if I + 3 < N then
        if (P[I + 1] = 10) and (P[I + 2] = 13) and (P[I + 3] = 10) then
          Exit(True);
    end
    else if P[I] = 10 then
    begin
      if (I + 1 < N) and (P[I + 1] = 10) then
        Exit(True);
      { bytes[i+1..].chunks(2).next() == Some(b"\r\n") }
      if I + 2 < N then
        if (P[I + 1] = 13) and (P[I + 2] = 10) then
          Exit(True);
    end;
  end;
  Result := False;
end;

procedure ResetMsg(out Msg: TParsedRequestHead);
begin
  Msg.Error := h1peNone;
  Msg.UriError := ueNone;
  Msg.HeadLen := 0;
  Msg.Method := hmNone;
  Msg.MethodSlice.Off := 0;
  Msg.MethodSlice.Len := 0;
  Msg.Target.Off := 0;
  Msg.Target.Len := 0;
  FillChar(Msg.Uri, SizeOf(Msg.Uri), 0);
  Msg.Uri.QueryPos := -1;
  Msg.Version := hv11;
  Msg.Decode := DECODED_LENGTH_ZERO;
  Msg.ExpectContinue := False;
  Msg.KeepAlive := False;
  Msg.WantsUpgrade := False;
  Msg.HeadSplit := False;
end;

function ServerParseHeaders(Buf: PByte; Len: SizeInt; PrevLen: SizeInt;
  const Ctx: TH1ParseContext; Headers: THttpHeaders;
  out Msg: TParsedRequestHead): TServerParseStatus;
begin
  if (Len = 0) or ((PrevLen >= 0) and not IsCompleteFast(Buf, Len, PrevLen)) then
  begin
    ResetMsg(Msg);
    Headers.Clear;
    Exit(spsPartial);
  end;
  Result := ServerParse(Buf, Len, Ctx, Headers, Msg);
end;

{ Maps a syntax error of bearings.http1.parser to a TH1ParseError. }
function HttparseErrorToParse(E: THttpParseError): TH1ParseError; inline;
begin
  case E of
    peHeaderName, peHeaderValue, peNewLine, peToken: Result := h1peHeaderToken;
    peStatus: Result := h1peStatus;
    peTooManyHeaders: Result := h1peTooLarge;
    peVersion: Result := h1peVersion;
  else
    Result := h1peInternal;
  end;
end;

{ ServerParse with the caller's header slot array (MaxH slots). This
  routine has no managed locals, so it gets no implicit exception frame;
  the heap slot array of a large MaxHeaders lives in ServerParseHeapSlots. }
function ServerParseSlots(Buf: PByte; Len: SizeInt; const Ctx: TH1ParseContext;
  Headers: THttpHeaders; out Msg: TParsedRequestHead; Slots: PHeaderSlice;
  MaxH: Integer): TServerParseStatus;
var
  Req: TParsedRequest;
  R: TParseResult;
  IsHttp11, IsCl, IsTe, IsTeChunked, HasConLen, SawClose: Boolean;
  ConLen, L: QWord;
  I: Integer;
  H: PHeaderSlice;
  NameP, ValP: PByte;
  UriErr: TUriError;

  function Fail(E: TH1ParseError): TServerParseStatus;
  begin
    { no partial header list is left behind on an error }
    Headers.Clear;
    Msg.Error := E;
    Result := spsError;
  end;

begin
  ResetMsg(Msg);
  { cleared up front, so that after Partial or an error the list never
    holds entries from a previous buffer }
  Headers.Clear;
  Headers.SetExternalBase(Buf);

  R := ParseRequest(Buf, Len, Req, Slots, MaxH, Ctx.ParserConfig);
  case R.Status of
    psPartial:
      Exit(spsPartial);
    psError:
      begin
        { an invalid token: before the method was parsed it is in the
          method, else in the target }
        if R.Error = peToken then
        begin
          if not Req.HasMethod then
            Exit(Fail(h1peMethod))
          else
            Exit(Fail(h1peUri));
        end;
        Exit(Fail(HttparseErrorToParse(R.Error)));
      end;
  end;

  if (Ctx.MaxHeaderSize >= 0) and (R.Consumed > Ctx.MaxHeaderSize) then
    Exit(Fail(h1peTooLarge));
  Msg.HeadLen := R.Consumed;
  if Req.Path.Len > MAX_URI_LEN then
    Exit(Fail(h1peUriTooLong));
  Msg.MethodSlice := Req.Method;
  Msg.Method := MethodFromBytes(Buf + Req.Method.Off, Req.Method.Len);
  Msg.Target := Req.Path;
  if Req.Version = 1 then
  begin
    Msg.KeepAlive := True;
    IsHttp11 := True;
    Msg.Version := hv11;
  end
  else
  begin
    Msg.KeepAlive := False;
    IsHttp11 := False;
    Msg.Version := hv10;
  end;

  { header names are stored with 16-bit lengths }
  for I := 0 to Req.NumHeaders - 1 do
    if Slots[I].Name.Len >= (1 shl 16) then
      Exit(Fail(h1peTooLarge));

  { the head is complete and HeadLen is known; every error below comes
    after this point }
  Msg.HeadSplit := True;

  { split the target into its parts and validate it }
  if not ParseUri(Buf + Req.Path.Off, Req.Path.Len, Msg.Uri, UriErr) then
  begin
    Msg.UriError := UriErr;
    Exit(Fail(h1peUri));
  end;
  Msg.Uri.Shift(Req.Path.Off);

  { Message framing (RFC 9112 section 6.3): Transfer-Encoding ending in
    chunked -> chunked body; invalid or differing Content-Length values ->
    error; Content-Length -> body of that length; else no body.
    Transfer-Encoding takes precedence over Content-Length: a
    Content-Length line before it is removed from Headers, one after it is
    skipped (not added). A repeated Content-Length with the same value is
    not added either. So Headers never has both, and has at most one
    Content-Length. }
  IsCl := False;
  IsTe := False;
  IsTeChunked := False;
  HasConLen := False;
  ConLen := 0;
  SawClose := False;
  Msg.WantsUpgrade := Msg.Method = hmConnect;

  for I := 0 to Req.NumHeaders - 1 do
  begin
    H := @Slots[I];
    NameP := Buf + H^.Name.Off;
    ValP := Buf + H^.Value.Off;
    case ClassifyName(NameP, H^.Name.Len) of
      hkTransferEncoding:
        begin
          if not IsHttp11 then
            Exit(Fail(h1peHeaderTransferEncodingUnexpected));
          IsTe := True;
          if IsCl and HasConLen then
          begin
            HasConLen := False;
            Headers.Remove(HN_CONTENT_LENGTH);
          end;
          if IsChunkedValue(ValP, H^.Value.Len) then
          begin
            IsTeChunked := True;
            Msg.Decode := DECODED_LENGTH_CHUNKED;
          end
          else
            IsTeChunked := False;
        end;
      hkContentLength:
        begin
          IsCl := True;
          if IsTe then
            Continue;
          if not ContentLengthParse(ValP, H^.Value.Len, L) then
            Exit(Fail(h1peHeaderContentLengthInvalid));
          if HasConLen then
          begin
            if ConLen <> L then
              Exit(Fail(h1peHeaderContentLengthInvalid));
            { we don't need to append this secondary length }
            Continue;
          end;
          { the two highest values are reserved (DECODED_LENGTH_*) }
          if L > DECODED_LENGTH_MAX then
            Exit(Fail(h1peTooLarge));
          Msg.Decode := L;
          ConLen := L;
          HasConLen := True;
        end;
      hkConnection:
        begin
          { once any Connection line asks to close, a later keep-alive
            must not undo it }
          if SawClose or ConnectionClose(ValP, H^.Value.Len) then
          begin
            SawClose := True;
            Msg.KeepAlive := False;
          end
          else if not Msg.KeepAlive then
            Msg.KeepAlive := ConnectionKeepAlive(ValP, H^.Value.Len);
        end;
      hkExpect:
        Msg.ExpectContinue := AsciiEqualIgnoreCase(ValP, H^.Value.Len,
          @STR_100_CONTINUE[0], Length(STR_100_CONTINUE));
      hkUpgrade:
        { upgrades are only allowed with HTTP/1.1 }
        Msg.WantsUpgrade := IsHttp11;
    end;
    Headers.AddExternal(H^.Name.Off, H^.Name.Len, H^.Value.Off, H^.Value.Len);
  end;

  { the last Transfer-Encoding line decides: the body length is only
    known when the final coding is chunked }
  if IsTe and not IsTeChunked then
    Exit(Fail(h1peHeaderTransferEncodingInvalid));
  { both framing headers: a sign of a smuggling attempt or a broken
    intermediary; serve this request, then close the connection }
  if IsTe and IsCl then
    Msg.KeepAlive := False;
  Result := spsComplete;
end;

{ MaxHeaders > DEFAULT_MAX_HEADERS: the slots are allocated per call.
  GetMem/FreeMem rather than a dynamic array: a managed local would give
  this per-request routine an implicit exception frame. ServerParseSlots
  raises only on out-of-memory, in which case the slot block leaks. }
function ServerParseHeapSlots(Buf: PByte; Len: SizeInt; const Ctx: TH1ParseContext;
  Headers: THttpHeaders; out Msg: TParsedRequestHead; MaxH: Integer): TServerParseStatus;
var
  HeapSlots: PHeaderSlice;
begin
  HeapSlots := GetMem(SizeInt(MaxH) * SizeOf(THeaderSlice));
  Result := ServerParseSlots(Buf, Len, Ctx, Headers, Msg, HeapSlots, MaxH);
  FreeMem(HeapSlots);
end;

function ServerParse(Buf: PByte; Len: SizeInt; const Ctx: TH1ParseContext;
  Headers: THttpHeaders; out Msg: TParsedRequestHead): TServerParseStatus;
var
  InlineSlots: array[0..DEFAULT_MAX_HEADERS - 1] of THeaderSlice;
  MaxH: Integer;
begin
  MaxH := Ctx.MaxHeaders;
  if MaxH < 0 then
    MaxH := DEFAULT_MAX_HEADERS;
  if MaxH <= DEFAULT_MAX_HEADERS then
    Result := ServerParseSlots(Buf, Len, Ctx, Headers, Msg, @InlineSlots[0], MaxH)
  else
    Result := ServerParseHeapSlots(Buf, Len, Ctx, Headers, Msg, MaxH);
end;

function ServerErrorStatus(E: TH1ParseError): Word;
begin
  case E of
    h1peMethod, h1peHeaderToken, h1peHeaderContentLengthInvalid,
    h1peHeaderTransferEncodingInvalid, h1peHeaderTransferEncodingUnexpected,
    h1peUri, h1peVersion:
      Result := 400;
    h1peTooLarge:
      Result := 431;
    h1peUriTooLong:
      Result := 414;
  else
    Result := 0;
  end;
end;

function H1ParseErrorDescription(E: TH1ParseError): string;
begin
  case E of
    h1peNone: Result := '';
    h1peMethod: Result := 'invalid HTTP method parsed';
    h1peVersion: Result := 'invalid HTTP version parsed';
    h1peVersionH2: Result := 'invalid HTTP version parsed (found HTTP2 preface)';
    h1peUri: Result := 'invalid URI';
    h1peUriTooLong: Result := 'URI too long';
    h1peHeaderToken: Result := 'invalid HTTP header parsed';
    h1peHeaderContentLengthInvalid: Result := 'invalid content-length parsed';
    h1peHeaderTransferEncodingInvalid: Result := 'invalid transfer-encoding parsed';
    h1peHeaderTransferEncodingUnexpected: Result := 'unexpected transfer-encoding parsed';
    h1peTooLarge: Result := 'message head is too large';
    h1peStatus: Result := 'invalid HTTP status-code parsed';
    h1peInternal: Result := 'internal error in the HTTP/1 parser, please report';
    h1peProxyProtocol: Result := 'invalid PROXY protocol header';
  end;
end;

{ --------------------------------------------------------------- encode }

type
  { Writes header names. OrigCase = False: in lowercase. OrigCase = True:
    with the spelling from Map when Map has the name, else in title case
    (TitleCase) or lowercase. For a name with several lines, the Nth line
    takes the spelling of the Nth entry of that name in Map (CurPos). }
  TNameWriter = record
    OrigCase: Boolean;
    TitleCase: Boolean;
    Map: THttpHeaders;        { nil in OrigCase mode = empty HeaderCaseMap }
    HaveCur: Boolean;
    CurName: PByte;
    CurLen: SizeInt;
    CurPos: SizeInt;          { next index of Map to search for CurName }
    procedure WriteName(var D: PByte; Name: PByte; Len: SizeInt);
  end;

procedure TNameWriter.WriteName(var D: PByte; Name: PByte; Len: SizeInt);
var
  I, Idx: SizeInt;
begin
  if not OrigCase then
  begin
    { lowercase names }
    for I := 0 to Len - 1 do
      D[I] := Lower[Name[I]];
    Inc(D, Len);
    Exit;
  end;
  if not (HaveCur and AsciiEqualIgnoreCase(CurName, CurLen, Name, Len)) then
  begin
    HaveCur := True;
    CurName := Name;
    CurLen := Len;
    CurPos := 0;
  end;
  Idx := -1;
  if (Map <> nil) and (CurPos < Map.Count) then
    Idx := Map.IndexOf(Name, Len, CurPos);
  if Idx >= 0 then
  begin
    { the spelling has the same length: it matched case-insensitively }
    Move(Map.NamePtr(Idx)^, D^, Len);
    Inc(D, Len);
    CurPos := Idx + 1;
  end
  else
  begin
    if Map <> nil then
      CurPos := Map.Count;
    if TitleCase then
      WriteTitleCase(D, Name, Len)
    else
      for I := 0 to Len - 1 do
        D[I] := Lower[Name[I]];
    Inc(D, Len);
  end;
end;

procedure Put(var D: PByte; S: PAnsiChar; N: SizeInt); inline;
begin
  Move(S^, D^, N);
  Inc(D, N);
end;

procedure PutBytes(var D: PByte; S: PByte; N: SizeInt); inline;
begin
  if N > 0 then
    Move(S^, D^, N);
  Inc(D, N);
end;

procedure PutCrLf(var D: PByte); inline;
begin
  D[0] := 13;
  D[1] := 10;
  Inc(D, 2);
end;

procedure PutColonSp(var D: PByte); inline;
begin
  D[0] := Ord(':');
  D[1] := Ord(' ');
  Inc(D, 2);
end;

procedure PutCommaSp(var D: PByte); inline;
begin
  D[0] := Ord(',');
  D[1] := Ord(' ');
  Inc(D, 2);
end;

function IsSuccess(Status: Word): Boolean; inline;
begin
  Result := (Status >= 200) and (Status < 300);
end;

function IsInformational(Status: Word): Boolean; inline;
begin
  Result := (Status >= 100) and (Status < 200);
end;

{ Whether the response can have a body (and so chunked framing): not for
  HEAD requests, 2xx responses to CONNECT (the connection becomes a
  tunnel), 1xx, 204 No Content and 304 Not Modified. }
function CanChunked(M: THttpMethod; Status: Word): Boolean;
begin
  if (M = hmHead) or ((M = hmConnect) and IsSuccess(Status)) or IsInformational(Status) then
    Result := False
  else
    Result := not ((Status = 204) or (Status = 304));
end;

{ Whether the response may carry Content-Length. A response to HEAD may:
  it states the length a GET would have received. }
function CanHaveContentLength(M: THttpMethod; Status: Word): Boolean;
begin
  if IsInformational(Status) or ((M = hmConnect) and IsSuccess(Status)) then
    Result := False
  else
    Result := not ((Status = 204) or (Status = 304));
end;

{ Whether "Content-Length: 0" is added to a response with an empty body.
  Not for HEAD: there it would state that the GET body is empty. }
function CanHaveImplicitZeroContentLength(M: THttpMethod; Status: Word): Boolean;
begin
  Result := CanHaveContentLength(M, Status) and (M <> hmHead);
end;

const
  CRLF_CHUNKED: array[0..10] of AnsiChar = ', chunked'#13#10;
  STATUS_200_OK: array[0..16] of AnsiChar = 'HTTP/1.1 200 OK'#13#10;
  REASON_NONE: array[0..5] of AnsiChar = '<none>';

{ Builds the body encoder chosen by EncodeHead: by length, chunked or
  close-delimited; for chunked, the trailer names declared in the
  response's Trailer lines; and IsLast (the connection closes after this
  response). EncodeHead tracks the kind and length in plain locals and
  builds the record once, here. }
procedure SetLengthEncoder(var Encoder: TEncoder; Len: QWord);
begin
  Encoder := TEncoder.Length(Len);
end;

procedure SetChunkedEncoder(var Encoder: TEncoder);
begin
  Encoder := TEncoder.Chunked;
end;

procedure SetCloseDelimitedEncoder(var Encoder: TEncoder);
begin
  Encoder := TEncoder.CloseDelimited;
end;

procedure MakeEncoder(var Encoder: TEncoder; Kind: TEncoderKind; Len: QWord;
  IsLast: Boolean; Headers: THttpHeaders; TrailerFirst: SizeInt; Trailers: PTrailerFieldSet);
var
  J: SizeInt;
begin
  case Kind of
    ekChunked: SetChunkedEncoder(Encoder);
    ekCloseDelimited: SetCloseDelimitedEncoder(Encoder);
  else
    SetLengthEncoder(Encoder, Len);
  end;
  Encoder.SetTrailerFieldSet(Trailers);
  if (Kind = ekChunked) and (TrailerFirst >= 0) then
  begin
    J := TrailerFirst;
    while J >= 0 do
    begin
      Encoder.IntoChunkedWithTrailerHeader(Headers.ValuePtr(J), Headers.ValueLen(J));
      J := Headers.IndexOf(Headers.NamePtr(TrailerFirst), Headers.NameLen(TrailerFirst), J + 1);
    end;
  end;
  Encoder.SetLast(IsLast);
end;

procedure RaiseBadStatus(Status: Word);
begin
  raise ERangeError.CreateFmt('ServerEncode: invalid status code %d', [Status]);
end;

procedure RaiseBadVersion;
begin
  raise EArgumentException.Create('ServerEncode: unexpected response version');
end;

function ResponseVersionPanics(Status: Word; Version: THttpVersion): Boolean;
begin
  if IsInformational(Status) and (Status <> 101) then
    Result := False          { replaced by an HTTP/1.1 500 head }
  else
    Result := not (Version in [hv10, hv11, hv2]);
end;

type
  PBytesArr = ^TBytes;

  { Where EncodeHead writes: a TBytes at a length (the tests' form) or a
    TByteVec (the connection's form). }
  TEncodeSink = record
    Bytes: PBytesArr;          { nil: Vec }
    BytesLen: PSizeInt;
    Vec: PByteVec;
    Pool: PBlockPool;
  end;

{ Room for Bound more bytes; returns where to write them. }
function SinkReserve(var S: TEncodeSink; Bound: SizeInt): PByte;
var
  NewLen: SizeInt;
begin
  if S.Vec <> nil then
  begin
    S.Vec^.Reserve(Bound, S.Pool);
    Result := S.Vec^.Data + S.Vec^.Len;
  end
  else
  begin
    if System.Length(S.Bytes^) < S.BytesLen^ + Bound then
    begin
      NewLen := 2 * System.Length(S.Bytes^);
      if NewLen < S.BytesLen^ + Bound then
        NewLen := S.BytesLen^ + Bound;
      SetLength(S.Bytes^, NewLen);
    end;
    Result := PByte(Pointer(S.Bytes^)) + S.BytesLen^;
  end;
end;

procedure SinkCommit(var S: TEncodeSink; N: SizeInt); inline;
begin
  if S.Vec <> nil then
    Inc(S.Vec^.Len, N)
  else
    Inc(S.BytesLen^, N);
end;

{ Builds with assertions (-Sa): every header name and value ServerEncode
  writes must be valid. An invalid one here is a bug in the code that
  built the head, and writing it could let header text (a CR or LF) inject
  extra lines into the response. }
procedure AssertHeaderEntry(H: THttpHeaders; I: SizeInt);
begin
  Assert(CheckHeaderField(H.NamePtr(I), H.NameLen(I), H.ValuePtr(I), H.ValueLen(I)) = hcOk,
    'ServerEncode: invalid header field reached the encoder');
end;

{ ServerEncode with a caller-provided "done" flag array of at least
  Head.Headers.Count entries (Done[i]: line i was already written with the
  earlier lines of its name). No managed locals or temporaries: the hot
  path gets no implicit exception frame.

  IsLast is the encoder's "close after this response" flag. WroteLen means
  a framing header (Content-Length or Transfer-Encoding) was written or
  must not be written; IsNameWritten means the current name's line has
  been started and later values of the same name are appended to it. }
function EncodeHead(const Head: TResponseHead; const P: TServerEncodeParams;
  var Sink: TEncodeSink; Date: PByte; Trailers: PTrailerFieldSet; var Encoder: TEncoder;
  Done: PBoolean): TServerEncodeResult;
var
  Version: THttpVersion;
  Status: Word;
  Headers, CaseMap: THttpHeaders;
  HasReason, Shortcut: Boolean;
  Body: TBodyLengthKind;
  BodyLen: QWord;
  IsLast, WroteLen, WroteDate, IsNameWritten, MustWriteChunked: Boolean;
  HasPrevConLen: Boolean;
  PrevConLen, L: QWord;
  Ret: TServerEncodeResult;
  W: TNameWriter;
  Bound, Count, I, J: SizeInt;
  ReasonP: PByte;
  ReasonLen: SizeInt;
  CanonP: PAnsiChar;
  D, Start: PByte;
  CurKind: THdrKind;
  CurName: PByte;
  CurNameLen: SizeInt;
  TrailerFirst: SizeInt;
  VP: PByte;
  VL: SizeInt;
  First: Boolean;
  EncKind: TEncoderKind;
  EncLen: QWord;

  { ends the joined line of the previous name, adding ", chunked" when
    the application's Transfer-Encoding did not end with chunked }
  procedure HandleIsNameWritten;
  begin
    if IsNameWritten then
    begin
      if MustWriteChunked then
        Put(D, @CRLF_CHUNKED[0], Length(CRLF_CHUNKED))
      else
        PutCrLf(D);
    end;
  end;

  { the output length is not advanced, so the partial head is discarded }
  function UserHeaderError: TServerEncodeResult;
  begin
    MakeEncoder(Encoder, ekLength, 0, False, nil, -1, Trailers);
    Result := serUserHeader;
  end;

begin
  Version := Head.Version;
  Status := Head.Status;
  Headers := Head.Headers;
  CaseMap := Head.CaseMap;
  HasReason := Head.HasReason;
  Body := P.Body;
  BodyLen := P.BodyLen;
  if (Status < 100) or (Status > 999) then
    RaiseBadStatus(Status);

  WroteLen := False;
  Ret := serOk;
  { 101 Switching Protocols: after this head the connection speaks another
    protocol, so HTTP/1.1 is done with it }
  if Status = 101 then
    IsLast := True
  else if (P.ReqMethod = hmConnect) and IsSuccess(Status) then
  begin
    { sending content-length or transfer-encoding on a 2xx response to
      CONNECT is forbidden (RFC 9110 section 9.3.6); WroteLen = True makes
      such a header from the application an error }
    WroteLen := True;
    IsLast := True;
  end
  else if IsInformational(Status) then
  begin
    { other 1xx responses cannot be sent through this path: a bare
      HTTP/1.1 500 head is written instead }
    Version := hv11;
    Status := 500;
    Headers := nil;
    CaseMap := nil;
    HasReason := False;
    Body := blkNone;
    Ret := serUnsupportedStatusCode;
    IsLast := True;
  end
  else
    IsLast := not P.KeepAlive;

  if not (Version in [hv10, hv11, hv2]) then
    RaiseBadVersion;

  { status line parts, and an upper bound of the bytes written: the status
    line, each header line (name, value and 9 more bytes for ": ", CRLF and
    a possible ", chunked"), an added Content-Length or Transfer-Encoding
    line, a Date line and the final CRLF }
  Shortcut := (Version = hv11) and (Status = 200) and not HasReason;
  ReasonP := nil;
  ReasonLen := 0;
  if Shortcut then
    Bound := Length(STATUS_200_OK)
  else
  begin
    if HasReason then
    begin
      ReasonP := Head.ReasonP;
      ReasonLen := Head.ReasonLen;
    end
    else if CanonicalReason(Status, CanonP, ReasonLen) then
      ReasonP := PByte(CanonP)
    else
    begin
      { a reason MUST be written, as many parsers will expect it }
      ReasonP := PByte(@REASON_NONE[0]);
      ReasonLen := Length(REASON_NONE);
    end;
    Bound := 9 + 3 + 1 + ReasonLen + 2;
  end;
  Count := 0;
  if Headers <> nil then
  begin
    Count := Headers.Count;
    Bound := Bound + Headers.WireLength + 9 * Count;
  end;
  Bound := Bound + 16 + 20 + 2       { implicit content-length / transfer-encoding }
                 + 6 + DATE_VALUE_LENGTH + 4;
  Start := SinkReserve(Sink, Bound);
  D := Start;

  { status line }
  if Shortcut then
    Put(D, @STATUS_200_OK[0], Length(STATUS_200_OK))
  else
  begin
    if Version = hv10 then
      Put(D, 'HTTP/1.0 ', 9)
    else
      Put(D, 'HTTP/1.1 ', 9);   { hv11, and hv2 coerced to HTTP/1.1 }
    D[0] := Ord('0') + Status div 100;
    D[1] := Ord('0') + (Status div 10) mod 10;
    D[2] := Ord('0') + Status mod 10;
    D[3] := Ord(' ');
    Inc(D, 4);
    PutBytes(D, ReasonP, ReasonLen);
    PutCrLf(D);
  end;

  { header name writer }
  W.OrigCase := (CaseMap <> nil) or P.TitleCaseHeaders;
  W.TitleCase := P.TitleCaseHeaders;
  W.Map := CaseMap;
  W.HaveCur := False;
  W.CurName := nil;
  W.CurLen := 0;
  W.CurPos := 0;

  { header lines; the default framing is a zero-length body }
  EncKind := ekLength;
  EncLen := 0;
  WroteDate := False;
  IsNameWritten := False;
  MustWriteChunked := False;
  HasPrevConLen := False;
  PrevConLen := 0;
  TrailerFirst := -1;
  CurKind := hkOther;
  CurName := nil;
  CurNameLen := 0;

  if Count > 0 then
    FillChar(Done^, Count, 0);

  { Order: each distinct name at the position of its first line, followed
    by its later lines. Lines of a name are found with IndexOf from J + 1;
    Done marks them so the outer loop skips them. }
  for I := 0 to Count - 1 do
  begin
    if Done[I] then
      Continue;
    J := I;
    First := True;
    while J >= 0 do
    begin
      Done[J] := True;
      {$IFOPT C+}
      AssertHeaderEntry(Headers, J);
      {$ENDIF}
      VP := Headers.ValuePtr(J);
      VL := Headers.ValueLen(J);
      if First then
      begin
        CurName := Headers.NamePtr(J);
        CurNameLen := Headers.NameLen(J);
        CurKind := ClassifyName(CurName, CurNameLen);
        HandleIsNameWritten;
        IsNameWritten := False;
        First := False;
      end;

      case CurKind of
        hkContentLength:
          begin
            if WroteLen and not IsNameWritten then
              Exit(UserHeaderError);   { unexpected content-length; rewind }
            case Body of
              blkKnown:
                begin
                  { the body length is known: the encoder uses BodyLen
                    and the first Content-Length value is written as is
                    (assumed to match); later ones are dropped }
                  if not IsNameWritten then
                  begin
                    {$IFOPT C+}
                    { as hyper's debug_assert: with assertions on (-Sa, the
                      test builds), a value that does not match the body
                      stops the program; it would break the connection's
                      framing (the C interface leaves such a field out) }
                    if ContentLengthParse(VP, VL, L) then
                      Assert(L = BodyLen, 'Content-Length does not match the body length');
                    {$ENDIF}
                    EncKind := ekLength;
                    EncLen := BodyLen;
                    W.WriteName(D, @STR_CONTENT_LENGTH[0], 14);
                    PutColonSp(D);
                    PutBytes(D, VP, VL);
                    WroteLen := True;
                    IsNameWritten := True;
                  end;
                  J := Headers.IndexOf(CurName, CurNameLen, J + 1);
                  Continue;
                end;
              blkUnknown:
                begin
                  { a streamed body: the application's Content-Length gives
                    the length; repeated values must agree }
                  if ContentLengthParse(VP, VL, L) then
                  begin
                    if HasPrevConLen then
                    begin
                      if PrevConLen <> L then
                        Exit(UserHeaderError);   { multiple Content-Length values }
                      J := Headers.IndexOf(CurName, CurNameLen, J + 1);
                      Continue;
                    end;
                    EncKind := ekLength;
                    EncLen := L;
                    W.WriteName(D, @STR_CONTENT_LENGTH[0], 14);
                    PutColonSp(D);
                    PutBytes(D, VP, VL);
                    WroteLen := True;
                    IsNameWritten := True;
                    HasPrevConLen := True;
                    PrevConLen := L;
                    J := Headers.IndexOf(CurName, CurNameLen, J + 1);
                    Continue;
                  end
                  else
                    Exit(UserHeaderError);       { illegal Content-Length value }
                end;
              blkNone:
                begin
                  { no body: only a HEAD response keeps the header }
                  if P.ReqMethod <> hmHead then
                  begin
                    J := Headers.IndexOf(CurName, CurNameLen, J + 1);
                    Continue;
                  end;
                end;
            end;
            WroteLen := True;
          end;
        hkTransferEncoding:
          begin
            if WroteLen and not IsNameWritten then
              Exit(UserHeaderError);   { unexpected transfer-encoding }
            if (Version = hv10) or not CanChunked(P.ReqMethod, Status) then
            begin
              J := Headers.IndexOf(CurName, CurNameLen, J + 1);
              Continue;
            end;
            WroteLen := True;
            { chunked must be the last coding, or ", chunked" is added at
              the end of the line }
            MustWriteChunked := not IsChunkedValue(VP, VL);
            if not IsNameWritten then
            begin
              EncKind := ekChunked;
              IsNameWritten := True;
              W.WriteName(D, @STR_TRANSFER_ENCODING[0], 17);
              PutColonSp(D);
              PutBytes(D, VP, VL);
            end
            else
            begin
              PutCommaSp(D);
              PutBytes(D, VP, VL);
            end;
            J := Headers.IndexOf(CurName, CurNameLen, J + 1);
            Continue;
          end;
        hkConnection:
          begin
            { "Connection: close" from the application closes the
              connection after this response }
            if (not IsLast) and ConnectionClose(VP, VL) then
              IsLast := True;
            if not IsNameWritten then
            begin
              IsNameWritten := True;
              W.WriteName(D, @STR_CONNECTION[0], 10);
              PutColonSp(D);
              PutBytes(D, VP, VL);
            end
            else
            begin
              PutCommaSp(D);
              PutBytes(D, VP, VL);
            end;
            J := Headers.IndexOf(CurName, CurNameLen, J + 1);
            Continue;
          end;
        hkDate:
          WroteDate := True;
        hkTrailer:
          begin
            { Trailer declares the header fields sent after a chunked body;
              the encoder accepts only those names as trailers }
            if (Version = hv10) or not CanChunked(P.ReqMethod, Status) then
            begin
              J := Headers.IndexOf(CurName, CurNameLen, J + 1);
              Continue;
            end;
            if not IsNameWritten then
            begin
              IsNameWritten := True;
              W.WriteName(D, @STR_TRAILER[0], 7);
              PutColonSp(D);
              PutBytes(D, VP, VL);
            end
            else
            begin
              PutCommaSp(D);
              PutBytes(D, VP, VL);
            end;
            if TrailerFirst < 0 then
              TrailerFirst := J;
            J := Headers.IndexOf(CurName, CurNameLen, J + 1);
            Continue;
          end;
      end;

      { non-special: write name and value }
      W.WriteName(D, CurName, CurNameLen);
      PutColonSp(D);
      PutBytes(D, VP, VL);
      PutCrLf(D);
      J := Headers.IndexOf(CurName, CurNameLen, J + 1);
    end;
  end;

  HandleIsNameWritten;

  { no framing header from the application: choose one. An unknown length
    is sent chunked, or for HTTP/1.0 (which has no chunked coding) as a
    body that ends when the connection closes. }
  if not WroteLen then
  begin
    case Body of
      blkUnknown:
        if (Version = hv10) or not CanChunked(P.ReqMethod, Status) then
          EncKind := ekCloseDelimited
        else
        begin
          W.WriteName(D, @STR_TRANSFER_ENCODING[0], 17);
          Put(D, ': chunked'#13#10, 11);
          EncKind := ekChunked;
        end;
      blkNone:
        begin
          if CanHaveImplicitZeroContentLength(P.ReqMethod, Status) then
          begin
            W.WriteName(D, @STR_CONTENT_LENGTH[0], 14);
            Put(D, ': 0'#13#10, 5);
          end;
          EncKind := ekLength;
          EncLen := 0;
        end;
      blkKnown:
        if BodyLen = 0 then
        begin
          if CanHaveImplicitZeroContentLength(P.ReqMethod, Status) then
          begin
            W.WriteName(D, @STR_CONTENT_LENGTH[0], 14);
            Put(D, ': 0'#13#10, 5);
          end;
          EncKind := ekLength;
          EncLen := 0;
        end
        else if not CanHaveContentLength(P.ReqMethod, Status) then
        begin
          EncKind := ekLength;
          EncLen := 0;
        end
        else
        begin
          W.WriteName(D, @STR_CONTENT_LENGTH[0], 14);
          PutColonSp(D);
          Inc(D, WriteDecimal(D, BodyLen));
          PutCrLf(D);
          EncKind := ekLength;
          EncLen := BodyLen;
        end;
    end;
  end;

  if not CanChunked(P.ReqMethod, Status) then   { the response can have no body }
  begin
    EncKind := ekLength;
    EncLen := 0;
  end;

  { Date from the cache unless the application set one or it is disabled;
    then the empty line that ends the head }
  if (not WroteDate) and P.DateHeader then
  begin
    W.WriteName(D, @STR_DATE[0], 4);
    PutColonSp(D);
    if Date <> nil then
      PutBytes(D, Date, DATE_VALUE_LENGTH)
    else
      PutBytes(D, DateBuffer, DATE_VALUE_LENGTH);
    Put(D, #13#10#13#10, 4);
  end
  else
    PutCrLf(D);

  MakeEncoder(Encoder, EncKind, EncLen, IsLast, Headers, TrailerFirst, Trailers);
  SinkCommit(Sink, D - Start);
  Result := Ret;
end;

const
  INLINE_DONE_FLAGS = 256;

{ more than INLINE_DONE_FLAGS headers: the flags go on the heap. AllocMem /
  FreeMem, not a dynamic array: a managed local gives the routine an
  implicit exception frame. EncodeHead raises only on a -Sa assertion,
  where the block leaks with the failing test. }
function EncodeHeadHeapFlags(const Head: TResponseHead; const P: TServerEncodeParams;
  var Sink: TEncodeSink; Date: PByte; Trailers: PTrailerFieldSet;
  var Encoder: TEncoder): TServerEncodeResult;
var
  Flags: PBoolean;
begin
  Flags := AllocMem(Head.Headers.Count * SizeOf(Boolean));
  Result := EncodeHead(Head, P, Sink, Date, Trailers, Encoder, Flags);
  FreeMem(Flags);
end;

function ServerEncode(const Head: TResponseHead; const P: TServerEncodeParams;
  var Dst: TBytes; var DstLen: SizeInt; out Encoder: TEncoder): TServerEncodeResult;
var
  DoneInline: array[0..INLINE_DONE_FLAGS - 1] of Boolean;
  Sink: TEncodeSink;
begin
  Sink.Bytes := @Dst;
  Sink.BytesLen := @DstLen;
  Sink.Vec := nil;
  Sink.Pool := nil;
  if (Head.Headers = nil) or (Head.Headers.Count <= INLINE_DONE_FLAGS) then
    Result := EncodeHead(Head, P, Sink, P.Date, nil, Encoder, @DoneInline[0])
  else
    Result := EncodeHeadHeapFlags(Head, P, Sink, P.Date, nil, Encoder);
end;

function ServerEncode(const Head: TResponseHead; const P: TServerEncodeParams;
  const Ctx: TEncodeContext; var Dst: TByteVec; Pool: PBlockPool;
  out Encoder: TEncoder): TServerEncodeResult;
var
  DoneInline: array[0..INLINE_DONE_FLAGS - 1] of Boolean;
  Sink: TEncodeSink;
begin
  Sink.Bytes := nil;
  Sink.BytesLen := nil;
  Sink.Vec := @Dst;
  Sink.Pool := Pool;
  if (Head.Headers = nil) or (Head.Headers.Count <= INLINE_DONE_FLAGS) then
    Result := EncodeHead(Head, P, Sink, Ctx.Date, Ctx.Trailers, Encoder, @DoneInline[0])
  else
    Result := EncodeHeadHeapFlags(Head, P, Sink, Ctx.Date, Ctx.Trailers, Encoder);
end;

procedure InitLower;
var
  I: Integer;
begin
  for I := 0 to 255 do
    if (I >= Ord('A')) and (I <= Ord('Z')) then
      Lower[I] := I + 32
    else
      Lower[I] := I;
end;

initialization
  InitLower;
end.

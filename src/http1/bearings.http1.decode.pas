{ bearings.http1.decode - the HTTP/1.1 message body decoder.

  After the head of a request (request line and header fields, ending with
  an empty line) the body follows. HTTP/1.1 has three ways to tell where the
  body ends (its "framing", RFC 9112 section 6):
  - Content-Length: N. The body is exactly N bytes (dkLength).
  - Transfer-Encoding: chunked. The body is a sequence of chunks, each one a
    hexadecimal size line followed by that many bytes and CRLF:
        5;name=value CRLF  hello CRLF  0 CRLF  Expires: ... CRLF  CRLF
    The text after ';' on a size line is a "chunk extension" (ignored, but
    counted against a limit). A chunk of size 0 ends the body. After it come
    optional "trailer" fields (header fields sent after the body) and an
    empty line (dkChunked).
  - Neither: the body runs until the peer closes the connection
    (close-delimited, dkEof). Only responses use this; a request without
    Content-Length or chunked encoding has no body.
  The choice between them is made from the head by bearings.http1.role; this unit
  only decodes the bytes once the kind is known.

  Strictness matters here. If this server and a proxy in front of it
  disagree about where a body ends, the rest of the bytes are read as a new
  request by one side and not the other ("request smuggling"). So every
  malformed size line, missing CRLF, overflowing size or oversized
  extension is an error that ends the connection; nothing is guessed.

  Model. TDecoder is a resumable state machine. Each Decode call gets the
  bytes the caller has buffered (Input, InputLen) and returns at most one
  slice of body data. It never copies body data: the slice is
  Input[R.DataOfs .. R.DataOfs + R.DataLen - 1], so it points into the
  caller's read buffer (bearings.rt.buf).

  R.Consumed is how many input bytes the decoder used (framing + data). The
  caller drops them from its buffer and calls again with what remains plus
  any new bytes. When the status is dsNeedMore, Consumed = InputLen: every
  framing byte has been absorbed into the decoder state, so a size line
  split across two reads needs no buffering by the caller.

  AtEof = True tells the decoder the peer closed the connection and Input is
  all that is left. A Length or Chunked body that is not complete then is an
  error (deIncompleteBody, deEofInChunkLine); for an Eof body it is the end.

  Status values:
    dsData     : one data slice (DataLen > 0).
    dsNeedMore : no data yet; read more and call again.
    dsTrailers : end of a chunked body that had trailers; they were parsed
                 into the Trailers list passed to Decode (cleared first).
                 The following call returns dsEnd.
    dsEnd      : end of body. Repeats if called again.
    dsError    : R.Error says why. Sticky: later calls return it again.

  Trailer bytes are copied into a scratch TByteVec, because they may arrive
  over several reads and are parsed only when the final empty line is seen;
  bodies with trailers are rare. The scratch belongs to the connection
  (TConnScratch in bearings.http1.conn) and is set with SetTrailerScratch after
  Init*; without one the decoder uses a per-thread default scratch (tests,
  direct callers). TDecoder has no managed fields, so Decode gets no
  implicit exception frame. Do not copy a TDecoder by assignment while it
  is in the trailer states: the copy would share that scratch.

  Threading: a TDecoder belongs to one connection and is used by the thread
  that runs it. The lookup tables are filled in the initialization section
  and only read afterwards. }
unit bearings.http1.decode;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

uses
  SysUtils, bearings.rt.buf, bearings.http.headers;

const
  { Maximum bytes in chunk extensions, counted over the whole body (not per
    chunk), so a client cannot send unlimited data that is never stored. }
  CHUNKED_EXTENSIONS_LIMIT = 1024 * 16;
  { Default maximum bytes for all trailer fields together. }
  TRAILER_LIMIT = 1024 * 16;

type
  { dkLength: Content-Length; dkChunked: chunked encoding; dkEof: the body
    ends when the peer closes the connection. }
  TDecoderKind = (dkLength, dkChunked, dkEof);

  { Where the chunked decoder is in "SIZE[ ][;ext] CRLF data CRLF ... 0 CRLF
    [trailers] CRLF":
      csStart      before the first hex digit of a size line
      csSize       inside the hex digits
      csSizeLws    spaces/tabs after the digits
      csExtension  after ';' up to CR
      csSizeLf     CR of the size line seen, LF expected
      csBody       inside chunk data (Remaining bytes left)
      csBodyCr, csBodyLf  the CRLF after chunk data
      csTrailer    inside a trailer field line (bytes go to the scratch)
      csTrailerLf  CR of a trailer line seen, LF expected
      csEndCr, csEndLf    after the last chunk or a trailer line: CR LF
                   ends the body, any other byte starts a trailer line
      csEnd        the body is complete }

  TChunkedState = (csStart, csSize, csSizeLws, csExtension, csSizeLf,
    csBody, csBodyCr, csBodyLf, csTrailer, csTrailerLf, csEndCr, csEndLf, csEnd);

  TDecodeStatus = (dsNeedMore, dsData, dsTrailers, dsEnd, dsError);

  { The class of a body error, used by bearings.http.exchange to map it to its
    own error kinds: the peer closed early (iekUnexpectedEof), malformed
    framing (iekInvalidInput), or a framing value out of range or over a
    limit (iekInvalidData). }
  TIoErrorKind = (iekNone, iekUnexpectedEof, iekInvalidInput, iekInvalidData);

  TDecodeError = (
    deNone,
    { class (DecodeErrorKind) and meaning; DecodeErrorMessage has the text }
    deIncompleteBody,         { UnexpectedEof: the peer closed before the body was complete }
    deEofInChunkLine,         { UnexpectedEof: the peer closed inside a chunk size line or the chunk framing }
    deSizeOverflow,           { InvalidData  : chunk size does not fit in 64 bits }
    deMissingSizeDigit,       { InvalidInput : size line does not start with a hex digit }
    deInvalidSize,            { InvalidInput : bad byte after the size digits }
    deInvalidSizeLws,         { InvalidInput : bad byte after the spaces that follow the size }
    deExtensionNewline,       { InvalidData  : bare LF inside a chunk extension }
    deExtensionsOverLimit,    { InvalidData  : chunk extensions over CHUNKED_EXTENSIONS_LIMIT }
    deInvalidSizeLf,          { InvalidInput : size line CR not followed by LF }
    deInvalidBodyCr,          { InvalidInput : chunk data not followed by CR }
    deInvalidBodyLf,          { InvalidInput : chunk data CR not followed by LF }
    deTrailerBytesOverLimit,  { InvalidData  : trailers over the byte limit }
    deTrailerCountOverflow,   { InvalidData  : more trailer lines than the field limit }
    deInvalidTrailerEndLf,    { InvalidInput : trailer line CR not followed by LF }
    deInvalidChunkEndLf,      { InvalidInput : final CR not followed by LF }
    deTrailerHeaderName,      { InvalidInput : invalid trailer field name, or no ':' after it }
    deTrailerHeaderValue,     { InvalidInput : invalid byte in a trailer field value }
    deTrailerNewLine,         { InvalidInput : CR not followed by LF in place of the final empty line }
    deTrailerTooManyHeaders,  { InvalidInput : more trailer fields than the allowed count }
    deTrailerPartial,         { InvalidInput : trailer block ends inside a field line }
    deTrailerInvalidName      { InvalidInput : trailer field name longer than MAX_HEADER_NAME_LEN }
  );

  TDecodeResult = record
    Status: TDecodeStatus;
    Consumed: SizeInt;    { input bytes used (framing + data); the caller drops them }
    DataOfs: SizeInt;     { dsData: offset of the data slice in Input }
    DataLen: SizeInt;
    Error: TDecodeError;
  end;

  TDecoder = record
  private
    FKind: TDecoderKind;
    FRemaining: QWord;       { Length: body bytes left. Chunked: size of the current chunk (bytes left in it while in csBody) }
    FState: TChunkedState;
    FExtCnt: QWord;          { chunk extension bytes seen in the whole body }
    FTrailerScratch: PByteVec;   { trailer bytes; nil = the per-thread default }
    FHasTrailerBuf: Boolean;     { a trailer line started; the scratch holds this body's trailer bytes }
    FTrailersCnt: SizeInt;       { trailer lines seen }
    FMaxHeaders: SizeInt;        { maximum trailer lines }
    FMaxHeaderSize: SizeInt;     { maximum trailer bytes (the scratch length must stay below it) }
    FEofSeen: Boolean;           { dkEof: AtEof was seen, the body is complete }
    FError: TDecodeError;        { first error; once set, every Decode returns it }
    function Fail(E: TDecodeError; Pos: SizeInt; out R: TDecodeResult): TDecodeStatus;
    function Scratch: PByteVec; inline;
    function TrailerAppend(P: PByte; N: SizeInt): Boolean;
    function TrailerPut(B: Byte): Boolean; inline;
    function Step(B: Byte; out E: TDecodeError): Boolean;
    function DecodeChunked(Input: PByte; InputLen: SizeInt; AtEof: Boolean;
      Trailers: THttpHeaders; out R: TDecodeResult): TDecodeStatus;
  public
    { A Content-Length body of N bytes. }
    procedure InitLength(N: QWord);
    { A chunked body. MaxHeaders limits the number of trailer fields and
      MaxHeaderSize their total bytes. A negative argument selects the
      default: DEFAULT_MAX_HEADERS (100) and TRAILER_LIMIT (16384). }
    procedure InitChunked(MaxHeaders: SizeInt = -1; MaxHeaderSize: SizeInt = -1);
    { A body that ends when the peer closes the connection. }
    procedure InitEof;
    { Where trailer bytes are collected (the connection's TConnScratch).
      Call after Init*; Init* resets it to nil (the per-thread default). }
    procedure SetTrailerScratch(S: PByteVec);
    { True when the body is complete: Length with 0 bytes left, Chunked in
      csEnd, or Eof after AtEof was seen. }
    function IsEof: Boolean;

    { Decodes from Input (see the unit header). Trailers (may be nil)
      receives the trailer fields when the result is dsTrailers. }
    function Decode(Input: PByte; InputLen: SizeInt; AtEof: Boolean;
      Trailers: THttpHeaders; out R: TDecodeResult): TDecodeStatus; overload;
    { Same with no trailer sink: trailers are still validated, then dropped. }
    function Decode(Input: PByte; InputLen: SizeInt; AtEof: Boolean;
      out R: TDecodeResult): TDecodeStatus; overload;

    property Kind: TDecoderKind read FKind;
    property State: TChunkedState read FState;
    { Length: bytes left. Chunked: bytes left in the current chunk, or the
      size parsed so far while in the size line states. }
    property Remaining: QWord read FRemaining;
    property ExtensionsCount: QWord read FExtCnt;
    property TrailersCount: SizeInt read FTrailersCnt;
    property LastError: TDecodeError read FError;
  end;

function DecodeErrorKind(E: TDecodeError): TIoErrorKind;
{ A short English description of E (for logs and error messages). }
function DecodeErrorMessage(E: TDecodeError): string;

{ Parses Len bytes of trailer fields ("Name: value" lines) ending with the
  empty line, allowing at most MaxCount fields. Dest (may be nil) is
  cleared, then gets every field in order (duplicates kept). Each line may
  end with CRLF or a bare LF. Leading and trailing spaces and tabs of a
  value are removed. A name longer than MAX_HEADER_NAME_LEN is reported
  only after every line parsed, so a syntax error on a later line is
  reported first. }
function ParseTrailers(P: PByte; Len: SizeInt; MaxCount: SizeInt;
  Dest: THttpHeaders; out Err: TDecodeError): Boolean;

{ Byte scanners. Plain loops for now; kept as separate routines so that
  SSE4.2/AVX2 versions can replace them. Each returns the index of the
  first matching byte, or Len if there is none. }
function FindCrOrLf(P: PByte; Len: SizeInt): SizeInt;
function FindByte(P: PByte; Len: SizeInt; B: Byte): SizeInt;
{ Index of the first byte that is not a header-name token char (or Len).
  A token char is a letter, a digit or one of !#$%&'*+-.^_`|~ (RFC 9110
  section 5.6.2). }
function ScanHeaderNameTokens(P: PByte; Len: SizeInt): SizeInt;
{ Index of the first byte that is not a header-value char (or Len): tab,
  0x20..0x7E and 0x80..0xFF are allowed; other control bytes (CR, LF, NUL,
  DEL, ...) are not. }
function ScanHeaderValueTokens(P: PByte; Len: SizeInt): SizeInt;

function IsHeaderNameToken(B: Byte): Boolean; inline;
function IsHeaderValueToken(B: Byte): Boolean; inline;

implementation

threadvar
  { trailer scratch of decoders that were given none (tests, direct callers) }
  DefaultTrailerScratch: TByteVec;

var
  TokenMap: array[Byte] of Boolean;
  ValueMap: array[Byte] of Boolean;
  HexVal: array[Byte] of ShortInt;   { -1 if not a hex digit }

function IsHeaderNameToken(B: Byte): Boolean; inline;
begin
  Result := TokenMap[B];
end;

function IsHeaderValueToken(B: Byte): Boolean; inline;
begin
  Result := ValueMap[B];
end;

function FindCrOrLf(P: PByte; Len: SizeInt): SizeInt;
var
  I: SizeInt;
begin
  for I := 0 to Len - 1 do
    if (P[I] = 13) or (P[I] = 10) then
      Exit(I);
  Result := Len;
end;

function FindByte(P: PByte; Len: SizeInt; B: Byte): SizeInt;
var
  I: SizeInt;
begin
  for I := 0 to Len - 1 do
    if P[I] = B then
      Exit(I);
  Result := Len;
end;

function ScanHeaderNameTokens(P: PByte; Len: SizeInt): SizeInt;
var
  I: SizeInt;
begin
  for I := 0 to Len - 1 do
    if not TokenMap[P[I]] then
      Exit(I);
  Result := Len;
end;

function ScanHeaderValueTokens(P: PByte; Len: SizeInt): SizeInt;
var
  I: SizeInt;
begin
  for I := 0 to Len - 1 do
    if not ValueMap[P[I]] then
      Exit(I);
  Result := Len;
end;

function DecodeErrorKind(E: TDecodeError): TIoErrorKind;
begin
  case E of
    deNone: Result := iekNone;
    deIncompleteBody, deEofInChunkLine: Result := iekUnexpectedEof;
    deSizeOverflow, deExtensionNewline, deExtensionsOverLimit,
    deTrailerBytesOverLimit, deTrailerCountOverflow: Result := iekInvalidData;
  else
    Result := iekInvalidInput;
  end;
end;

function DecodeErrorMessage(E: TDecodeError): string;
begin
  case E of
    deNone: Result := '';
    deIncompleteBody: Result := 'end of file before message length reached';
    deEofInChunkLine: Result := 'unexpected EOF during chunk size line';
    deSizeOverflow: Result := 'invalid chunk size: overflow';
    deMissingSizeDigit: Result := 'Invalid chunk size line: missing size digit';
    deInvalidSize: Result := 'Invalid chunk size line: Invalid Size';
    deInvalidSizeLws: Result := 'Invalid chunk size linear white space';
    deExtensionNewline: Result := 'invalid chunk extension contains newline';
    deExtensionsOverLimit: Result := 'chunk extensions over limit';
    deInvalidSizeLf: Result := 'Invalid chunk size LF';
    deInvalidBodyCr: Result := 'Invalid chunk body CR';
    deInvalidBodyLf: Result := 'Invalid chunk body LF';
    deTrailerBytesOverLimit: Result := 'chunk trailers bytes over limit';
    deTrailerCountOverflow: Result := 'chunk trailers count overflow';
    deInvalidTrailerEndLf: Result := 'Invalid trailer end LF';
    deInvalidChunkEndLf: Result := 'Invalid chunk end LF';
    deTrailerHeaderName: Result := 'invalid header name';
    deTrailerHeaderValue: Result := 'invalid header value';
    deTrailerNewLine: Result := 'invalid new line';
    deTrailerTooManyHeaders: Result := 'too many headers';
    deTrailerPartial: Result := 'Partial header';
    deTrailerInvalidName: Result := 'Invalid header name';
  end;
end;

{ ---- trailers ---- }

function ParseTrailers(P: PByte; Len: SizeInt; MaxCount: SizeInt;
  Dest: THttpHeaders; out Err: TDecodeError): Boolean;
var
  Pos, NameStart, NameEnd, ValStart, ValEnd, Count: SizeInt;
  B: Byte;
  EmptyValue, LongName: Boolean;
label
  Partial, Complete;
begin
  Err := deNone;
  LongName := False;
  if Dest <> nil then
    Dest.Clear;
  Count := 0;
  Pos := 0;
  while True do
  begin
    { a newline here means the head is over }
    if Pos >= Len then goto Partial;
    B := P[Pos]; Inc(Pos);
    if B = 13 then
    begin
      if Pos >= Len then goto Partial;
      if P[Pos] <> 10 then
      begin
        Err := deTrailerNewLine;
        Exit(False);
      end;
      goto Complete;
    end;
    if B = 10 then
      goto Complete;
    if not TokenMap[B] then
    begin
      Err := deTrailerHeaderName;
      Exit(False);
    end;

    { name until ':' }
    NameStart := Pos - 1;
    Inc(Pos, ScanHeaderNameTokens(P + Pos, Len - Pos));
    if Pos >= Len then goto Partial;
    B := P[Pos]; Inc(Pos);
    if B <> Ord(':') then
    begin
      Err := deTrailerHeaderName;
      Exit(False);
    end;
    NameEnd := Pos - 1;

    { white space between colon and value }
    EmptyValue := False;
    ValStart := Pos;
    while True do
    begin
      if Pos >= Len then goto Partial;
      B := P[Pos]; Inc(Pos);
      if (B = 32) or (B = 9) then
        Continue;
      if ValueMap[B] then
      begin
        ValStart := Pos - 1;
        Break;
      end;
      if B = 13 then
      begin
        if Pos >= Len then goto Partial;
        if P[Pos] <> 10 then
        begin
          Err := deTrailerHeaderValue;
          Exit(False);
        end;
        Inc(Pos);
      end
      else if B <> 10 then
      begin
        Err := deTrailerHeaderValue;
        Exit(False);
      end;
      EmptyValue := True;
      Break;
    end;

    if EmptyValue then
    begin
      ValStart := Pos;
      ValEnd := Pos;
    end
    else
    begin
      { value until end of line }
      Inc(Pos, ScanHeaderValueTokens(P + Pos, Len - Pos));
      if Pos >= Len then goto Partial;
      B := P[Pos]; Inc(Pos);
      if B = 13 then
      begin
        if Pos >= Len then goto Partial;
        if P[Pos] <> 10 then
        begin
          Err := deTrailerHeaderValue;
          Exit(False);
        end;
        ValEnd := Pos - 1;
        Inc(Pos);
      end
      else if B = 10 then
        ValEnd := Pos - 1
      else
      begin
        Err := deTrailerHeaderValue;
        Exit(False);
      end;
      { trim trailing whitespace }
      while (ValEnd > ValStart) and (P[ValEnd - 1] in [32, 9, 13, 10]) do
        Dec(ValEnd);
    end;

    if Count >= MaxCount then
    begin
      Err := deTrailerTooManyHeaders;
      Exit(False);
    end;
    { An over-long name is reported at the end (see the declaration), so
      a syntax error or too many fields on a later line takes precedence. }
    if NameEnd - NameStart > MAX_HEADER_NAME_LEN then
      LongName := True;
    { The value needs no further validation: ValueMap already rejected
      every byte that is not allowed in a field value. }
    if Dest <> nil then
      Dest.AddTrusted(P + NameStart, NameEnd - NameStart, P + ValStart, ValEnd - ValStart);
    Inc(Count);
  end;

Complete:
  if LongName then
  begin
    Err := deTrailerInvalidName;
    Exit(False);
  end;
  Exit(True);

Partial:
  Err := deTrailerPartial;
  Result := False;
end;

{ ---- TDecoder ---- }

procedure TDecoder.InitLength(N: QWord);
begin
  FKind := dkLength;
  FRemaining := N;
  FState := csStart;
  FExtCnt := 0;
  FTrailerScratch := nil;
  FHasTrailerBuf := False;
  FTrailersCnt := 0;
  FMaxHeaders := DEFAULT_MAX_HEADERS;
  FMaxHeaderSize := TRAILER_LIMIT;
  FEofSeen := False;
  FError := deNone;
end;

procedure TDecoder.InitChunked(MaxHeaders: SizeInt; MaxHeaderSize: SizeInt);
begin
  InitLength(0);
  FKind := dkChunked;
  if MaxHeaders < 0 then
    FMaxHeaders := DEFAULT_MAX_HEADERS
  else
    FMaxHeaders := MaxHeaders;
  if MaxHeaderSize < 0 then
    FMaxHeaderSize := TRAILER_LIMIT
  else
    FMaxHeaderSize := MaxHeaderSize;
end;

procedure TDecoder.InitEof;
begin
  InitLength(0);
  FKind := dkEof;
end;

function TDecoder.IsEof: Boolean;
begin
  case FKind of
    dkLength: Result := FRemaining = 0;
    dkChunked: Result := FState = csEnd;
    dkEof: Result := FEofSeen;
  else
    Result := False;
  end;
end;

function TDecoder.Fail(E: TDecodeError; Pos: SizeInt; out R: TDecodeResult): TDecodeStatus;
begin
  FError := E;
  R.Status := dsError;
  R.Consumed := Pos;
  R.DataOfs := 0;
  R.DataLen := 0;
  R.Error := E;
  Result := dsError;
end;

procedure TDecoder.SetTrailerScratch(S: PByteVec);
begin
  FTrailerScratch := S;
end;

function TDecoder.Scratch: PByteVec;
begin
  if FTrailerScratch = nil then
    FTrailerScratch := @DefaultTrailerScratch;
  Result := FTrailerScratch;
end;

function TDecoder.TrailerAppend(P: PByte; N: SizeInt): Boolean;
var
  S: PByteVec;
begin
  S := Scratch;
  { The limit is exclusive: the scratch must stay shorter than
    FMaxHeaderSize. Checking the length after the whole append gives the
    same outcome as checking after each byte, because the length only
    grows. }
  if S^.Len + N >= FMaxHeaderSize then
    Exit(False);
  S^.Append(P, N, nil);
  Result := True;
end;

function TDecoder.TrailerPut(B: Byte): Boolean; inline;
begin
  Result := TrailerAppend(@B, 1);
end;

{ Consumes one byte of chunk framing in every state except csBody and csEnd
  (which DecodeChunked handles). Returns False with E set on error. }
function TDecoder.Step(B: Byte; out E: TDecodeError): Boolean;
var
  D: ShortInt;
  S: PByteVec;
begin
  E := deNone;
  case FState of
    csStart, csSize:
      begin
        D := HexVal[B];
        if D >= 0 then
        begin
          { Size := Size * 16 + D. The OR of D cannot overflow after a
            shift by 4 (the low 4 bits are zero), so only the shift needs
            a check. }
          if FRemaining > (High(QWord) shr 4) then
          begin
            E := deSizeOverflow;
            Exit(False);
          end;
          FRemaining := (FRemaining shl 4) or QWord(D);
          FState := csSize;
        end
        else if FState = csStart then
        begin
          E := deMissingSizeDigit;
          Exit(False);
        end
        else
          case B of
            9, 32: FState := csSizeLws;
            Ord(';'): FState := csExtension;
            13: FState := csSizeLf;
          else
            E := deInvalidSize;
            Exit(False);
          end;
      end;
    csSizeLws:
      case B of
        9, 32: ;
        Ord(';'): FState := csExtension;
        13: FState := csSizeLf;
      else
        E := deInvalidSizeLws;
        Exit(False);
      end;
    csExtension:
      case B of
        13: FState := csSizeLf;
        10:
          begin
            E := deExtensionNewline;
            Exit(False);
          end;
      else
        Inc(FExtCnt);
        if FExtCnt >= CHUNKED_EXTENSIONS_LIMIT then
        begin
          E := deExtensionsOverLimit;
          Exit(False);
        end;
      end;
    csSizeLf:
      if B = 10 then
      begin
        if FRemaining = 0 then
          FState := csEndCr
        else
          FState := csBody;
      end
      else
      begin
        E := deInvalidSizeLf;
        Exit(False);
      end;
    csBodyCr:
      if B = 13 then
        FState := csBodyLf
      else
      begin
        E := deInvalidBodyCr;
        Exit(False);
      end;
    csBodyLf:
      if B = 10 then
        FState := csStart
      else
      begin
        E := deInvalidBodyLf;
        Exit(False);
      end;
    csTrailer:
      begin
        if not TrailerPut(B) then
        begin
          E := deTrailerBytesOverLimit;
          Exit(False);
        end;
        if B = 13 then
          FState := csTrailerLf;
      end;
    csTrailerLf:
      if B = 10 then
      begin
        if FTrailersCnt >= FMaxHeaders then
        begin
          E := deTrailerCountOverflow;
          Exit(False);
        end;
        Inc(FTrailersCnt);
        if not TrailerPut(B) then
        begin
          E := deTrailerBytesOverLimit;
          Exit(False);
        end;
        FState := csEndCr;
      end
      else
      begin
        E := deInvalidTrailerEndLf;
        Exit(False);
      end;
    csEndCr:
      if B = 13 then
      begin
        if FHasTrailerBuf and not TrailerPut(B) then
        begin
          E := deTrailerBytesOverLimit;
          Exit(False);
        end;
        FState := csEndLf;
      end
      else
      begin
        if not FHasTrailerBuf then
        begin
          { first trailer byte: start the scratch for this body; one byte
            cannot exceed the limit, so no check }
          FHasTrailerBuf := True;
          S := Scratch;
          S^.Clear;
          if S^.Cap < 64 then
            S^.Reserve(64, nil);   { 64 fits a single Expires header }
          S^.Append(@B, 1, nil);
        end
        else if not TrailerPut(B) then
        begin
          E := deTrailerBytesOverLimit;
          Exit(False);
        end;
        FState := csTrailer;
      end;
    csEndLf:
      if B = 10 then
      begin
        if FHasTrailerBuf and not TrailerPut(B) then
        begin
          E := deTrailerBytesOverLimit;
          Exit(False);
        end;
        FState := csEnd;
      end
      else
      begin
        E := deInvalidChunkEndLf;
        Exit(False);
      end;
  else
    { csBody and csEnd are handled by DecodeChunked }
  end;
  Result := True;
end;

function TDecoder.DecodeChunked(Input: PByte; InputLen: SizeInt; AtEof: Boolean;
  Trailers: THttpHeaders; out R: TDecodeResult): TDecodeStatus;
var
  Pos, N, K: SizeInt;
  E: TDecodeError;
begin
  Pos := 0;
  while True do
  begin
    case FState of
      csEnd:
        begin
          { the trailers are parsed once, here; FHasTrailerBuf is cleared so
            the next call returns dsEnd }
          R.Consumed := Pos;
          R.DataOfs := 0;
          R.DataLen := 0;
          R.Error := deNone;
          if FHasTrailerBuf then
          begin
            FHasTrailerBuf := False;
            if not ParseTrailers(Scratch^.Data, Scratch^.Len, FTrailersCnt, Trailers, E) then
              Exit(Fail(E, Pos, R));
            R.Status := dsTrailers;
          end
          else
            R.Status := dsEnd;
          Exit(R.Status);
        end;
      csBody:
        begin
          { return as much of the chunk as is buffered, as one slice }
          if Pos >= InputLen then
          begin
            if AtEof then
            begin
              FRemaining := 0;
              Exit(Fail(deIncompleteBody, Pos, R));
            end;
            R.Status := dsNeedMore;
            R.Consumed := Pos;
            R.DataOfs := 0;
            R.DataLen := 0;
            R.Error := deNone;
            Exit(dsNeedMore);
          end;
          N := InputLen - Pos;
          if QWord(N) > FRemaining then
            N := SizeInt(FRemaining);
          Dec(FRemaining, QWord(N));
          if FRemaining = 0 then
            FState := csBodyCr;
          R.Status := dsData;
          R.DataOfs := Pos;
          R.DataLen := N;
          R.Consumed := Pos + N;
          R.Error := deNone;
          Exit(dsData);
        end;
      csExtension:
        if Pos < InputLen then
        begin
          { skip extension bytes up to CR/LF in one scan }
          K := FindCrOrLf(Input + Pos, InputLen - Pos);
          if K > 0 then
          begin
            if FExtCnt + QWord(K) >= CHUNKED_EXTENSIONS_LIMIT then
              Exit(Fail(deExtensionsOverLimit, Pos, R));
            Inc(FExtCnt, QWord(K));
            Inc(Pos, K);
          end;
        end;
      csTrailer:
        if Pos < InputLen then
        begin
          { copy trailer bytes up to CR in one scan }
          K := FindByte(Input + Pos, InputLen - Pos, 13);
          if K > 0 then
          begin
            if not TrailerAppend(Input + Pos, K) then
              Exit(Fail(deTrailerBytesOverLimit, Pos, R));
            Inc(Pos, K);
          end;
        end;
    else
    end;

    { one framing byte through Step; at the end of Input, ask for more
      (or fail if the peer closed) }
    if Pos >= InputLen then
    begin
      if AtEof then
        Exit(Fail(deEofInChunkLine, Pos, R));
      R.Status := dsNeedMore;
      R.Consumed := Pos;
      R.DataOfs := 0;
      R.DataLen := 0;
      R.Error := deNone;
      Exit(dsNeedMore);
    end;
    if not Step(Input[Pos], E) then
      Exit(Fail(E, Pos + 1, R));
    Inc(Pos);
  end;
end;

function TDecoder.Decode(Input: PByte; InputLen: SizeInt; AtEof: Boolean;
  Trailers: THttpHeaders; out R: TDecodeResult): TDecodeStatus;
var
  N: SizeInt;
begin
  R.Status := dsNeedMore;
  R.Consumed := 0;
  R.DataOfs := 0;
  R.DataLen := 0;
  R.Error := deNone;
  if FError <> deNone then
    Exit(Fail(FError, 0, R));
  if InputLen < 0 then
    InputLen := 0;

  case FKind of
    dkLength:
      begin
        if FRemaining = 0 then
        begin
          R.Status := dsEnd;
          Exit(dsEnd);
        end;
        if InputLen = 0 then
        begin
          if AtEof then
            Exit(Fail(deIncompleteBody, 0, R));
          Exit(dsNeedMore);
        end;
        N := InputLen;
        if QWord(N) > FRemaining then
          N := SizeInt(FRemaining);
        Dec(FRemaining, QWord(N));
        R.Status := dsData;
        R.DataOfs := 0;
        R.DataLen := N;
        R.Consumed := N;
        Result := dsData;
      end;
    dkChunked:
      Result := DecodeChunked(Input, InputLen, AtEof, Trailers, R);
    dkEof:
      begin
        if FEofSeen then
        begin
          R.Status := dsEnd;
          Exit(dsEnd);
        end;
        if InputLen > 0 then
        begin
          R.Status := dsData;
          R.DataOfs := 0;
          R.DataLen := InputLen;
          R.Consumed := InputLen;
          Exit(dsData);
        end;
        if AtEof then
        begin
          FEofSeen := True;
          R.Status := dsEnd;
          Exit(dsEnd);
        end;
        Result := dsNeedMore;
      end;
  else
    Result := dsNeedMore;
  end;
end;

function TDecoder.Decode(Input: PByte; InputLen: SizeInt; AtEof: Boolean;
  out R: TDecodeResult): TDecodeStatus;
begin
  Result := Decode(Input, InputLen, AtEof, nil, R);
end;

procedure InitTables;
var
  B: Integer;
begin
  for B := 0 to 255 do
  begin
    TokenMap[B] := (B in [Ord('A')..Ord('Z'), Ord('a')..Ord('z'), Ord('0')..Ord('9'),
      Ord('!'), Ord('#'), Ord('$'), Ord('%'), Ord('&'), Ord(''''), Ord('*'), Ord('+'),
      Ord('-'), Ord('.'), Ord('^'), Ord('_'), Ord('`'), Ord('|'), Ord('~')]);
    { field value bytes: tab, 0x20..0x7E, 0x80..0xFF (obs-text) }
    ValueMap[B] := (B = 9) or ((B >= 32) and (B <= $7E)) or (B >= $80);
    if (B >= Ord('0')) and (B <= Ord('9')) then
      HexVal[B] := B - Ord('0')
    else if (B >= Ord('a')) and (B <= Ord('f')) then
      HexVal[B] := B - Ord('a') + 10
    else if (B >= Ord('A')) and (B <= Ord('F')) then
      HexVal[B] := B - Ord('A') + 10
    else
      HexVal[B] := -1;
  end;
end;

initialization
  InitTables;
finalization
  { the main thread's default scratch }
  DefaultTrailerScratch.Clear;
  DefaultTrailerScratch.ReleaseIdle(nil);
end.

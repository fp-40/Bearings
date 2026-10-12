{ bearings.http1.encode - the HTTP/1.1 message body encoder.

  A response body must be framed so the client knows where it ends (RFC 9112
  section 6). bearings.http1.role picks the framing when it writes the response
  head, and creates a TEncoder of the matching kind:
  - ekLength: the head has "Content-Length: N" and the body is exactly N
    bytes, written as is.
  - ekChunked: the head has "Transfer-Encoding: chunked" (used when the
    length is not known in advance). Each piece of body is sent as
    "<size in hex>\r\n<data>\r\n"; "0\r\n\r\n" ends the body. Before that
    final empty line the sender may add trailer fields (header fields sent
    after the body), but only those the response announced in its "Trailer"
    header.
  - ekCloseDelimited: no length and no chunking; the body ends when the
    server closes the connection. Used when the length is unknown and
    chunked encoding cannot be used (an HTTP/1.0 client, which does not
    understand it, or a response for which bearings.http1.role does not allow
    it). The connection cannot be reused.

  Encode does not copy the body. It returns a TEncodedBuf of up to three
  segments: [chunk-size line] + [caller's data] + [static suffix]. The
  caller either copies them into its write buffer (CopyTo; small writes are
  cheaper to merge into one buffer) or hands them to writev (FillIoVec;
  large data is not copied). The chunk-size line is stored inside the
  TEncodedBuf record, so the record must stay alive and in place until
  those iovecs are written. Advance(N) drops N bytes from the front after a
  partial write. bearings.http1.io keeps TEncodedBuf values in its write queue.

  Kinds of TEncodedBuf:
    ebkExact      : the data as is (Length within the limit, CloseDelimited)
    ebkLimited    : the first part of the data (Length, when the data is
                    longer than the bytes still owed; the rest is dropped,
                    so the body never exceeds the declared Content-Length)
    ebkChunked    : "<HEX>\r\n" + data + "\r\n"
                    (EncodeAndEnd: + "\r\n0\r\n\r\n")
    ebkChunkedEnd : "0\r\n\r\n"
  Trailers are rare. EncodeTrailers appends the whole end of the body
  ("0\r\n", the fields, "\r\n") to a TByteVec, which becomes a qkTrailers
  write queue entry in bearings.http1.io; the TBytes overload is for tests.

  The trailer names announced in the Trailer header live in a
  TTrailerFieldSet that the encoder points to. Each connection owns one
  (TConnScratch in bearings.http1.conn, passed via SetTrailerFieldSet or
  TEncodeContext); without one the encoder uses a per-thread default set.
  TEncoder has no managed fields, so building, copying and returning one
  needs no implicit exception frame.

  Threading: a TEncoder and its TEncodedBuf values belong to one connection
  and are used by the thread that runs it. }
unit bearings.http1.encode;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

uses
  SysUtils, bearings.rt.sys, bearings.rt.buf, bearings.http.headers;

const
  { most hex digits of a chunk size: 2 per byte of SizeUInt }
  CHUNK_SIZE_MAX_BYTES = SizeOf(SizeUInt) * 2;

type
  TEncoderKind = (ekChunked, ekLength, ekCloseDelimited);

  TEncodedBufKind = (ebkExact, ebkLimited, ebkChunked, ebkChunkedEnd);

  { struct iovec (bearings.rt.sys); the transport's WriteV takes these. }
  TIoSlice = TSysIoVec;
  PIoSlice = PSysIoVec;

  { One encoded piece of body: prefix (chunk-size line, held in the record),
    data (the caller's memory) and suffix (a constant). Each segment is
    consumed from the front by Advance. }
  TEncodedBuf = record
  private
    FKind: TEncodedBufKind;
    FPrefix: array[0..CHUNK_SIZE_MAX_BYTES + 1] of Byte;   { hex + CRLF }
    FPrefixPos: Byte;      { first prefix byte not yet written }
    FPrefixLen: Byte;
    FData: PByte;          { the caller's data, not owned; must stay valid until written }
    FDataLen: SizeInt;
    FSuffix: PByte;        { points to a constant: CRLF, or a chunked end }
    FSuffixLen: SizeInt;
    procedure SetChunkSize(Len: SizeUInt);
  public
    { Bytes not yet written. }
    function Remaining: SizeInt;
    { Copies all remaining bytes to Dst (Dst must hold Remaining bytes).
      Returns the count. Does not advance. }
    function CopyTo(Dst: PByte): SizeInt;
    { Appends all remaining bytes at Buf[Len], growing Buf; advances Len. }
    procedure AppendTo(var Buf: TBytes; var Len: SizeInt);
    { Drops N bytes from the front (after a partial write). }
    procedure Advance(N: SizeInt);
    { Fills up to MaxCount iovecs with the non-empty remaining segments.
      Returns how many were filled (0..3). }
    function FillIoVec(Dst: PIoSlice; MaxCount: Integer): Integer;
    { For a file body: splits the frame into its framing and its data
      length. Head gets the chunk-size line, Tail the suffix; DataLen is the
      data length the encoder accepted (ebkLimited: less than offered). The
      data itself is then written from the file with sendfile, between Head
      and Tail (bearings.http1.conn). }
    procedure SplitData(out Head: TEncodedBuf; out DataLen: SizeInt; out Tail: TEncodedBuf);
    property Kind: TEncodedBufKind read FKind;
  end;

  { One declared trailer name: a slice of TTrailerFieldSet.Bytes. }
  TTrailerName = record
    Ofs: SizeInt;
    Len: SizeInt;
  end;
  PTrailerName = ^TTrailerName;

  { The trailer names a chunked response announced (its Trailer header).
    The names are slices of one heap byte array (GetMem, no managed types).
    A zeroed record is an empty set. Clear keeps the memory; Done frees it. }
  PTrailerFieldSet = ^TTrailerFieldSet;
  TTrailerFieldSet = record
    Bytes: PByte;
    BytesLen, BytesCap: SizeInt;
    Names: PTrailerName;
    Count, NamesCap: SizeInt;
    procedure Clear; inline;
    procedure Add(P: PByte; Len: SizeInt);
    { field names compare case-insensitively (RFC 9110 section 5.1) }
    function Contains(P: PByte; Len: SizeInt): Boolean;
    function NamePtr(I: SizeInt): PByte; inline;
    function NameLen(I: SizeInt): SizeInt; inline;
    procedure Done;
  end;

  { Result of TEncoder.Finish }
  TEncoderEnd = (
    eeNone,     { nothing to write (Length body complete, or CloseDelimited) }
    eeBuf,      { write Buf ("0\r\n\r\n") }
    eeNotEof    { Length body is NotEofRemaining bytes short: the response
                  cannot be completed, so the connection must be closed }
  );

  { The framing state of one response body. }
  TEncoder = record
  private
    FKind: TEncoderKind;
    FRemaining: QWord;                   { ekLength: bytes still owed }
    FIsLast: Boolean;                    { the connection closes after this response }
    FHasTrailerFields: Boolean;          { a trailer name list was set (it may be empty); without one no trailers are written }
    FTrailers: PTrailerFieldSet;         { the announced trailer names; nil = per-thread default }
    function TrailerSet: PTrailerFieldSet; inline;
    function TrailerAllowed(Trailers: THttpHeaders; I: SizeInt): Boolean;
  public
    class function Chunked: TEncoder; static;
    class function Length(Len: QWord): TEncoder; static;
    class function CloseDelimited: TEncoder; static;
    { Where the announced trailer names are stored (the connection's
      scratch). Call before IntoChunkedWith*; the constructors reset it to
      nil (the per-thread default set). }
    procedure SetTrailerFieldSet(S: PTrailerFieldSet);
    { Sets the allowed trailer names, replacing any earlier list. Only
      affects a Chunked encoder. Names are matched case-insensitively. }
    procedure IntoChunkedWithTrailingFields(const Names: array of RawByteString);
    { Adds the names of one Trailer header field of the response; called
      once per Trailer field line, and the names accumulate across calls.
      A value that is not visible ASCII is ignored; otherwise each
      comma-separated item, with spaces and tabs trimmed, is kept if it is
      a valid field name. Only affects a Chunked encoder. }
    procedure IntoChunkedWithTrailerHeader(Value: PByte; Len: SizeInt);

    { True for a Length encoder with no bytes left. }
    function IsEof: Boolean;
    { Marks the response as the last one on the connection. }
    procedure SetLast(AIsLast: Boolean);
    function IsLast: Boolean;
    function IsCloseDelimited: Boolean;
    function IsChunked: Boolean;
    { Length still owed (Length kind). }
    property Remaining: QWord read FRemaining;
    property Kind: TEncoderKind read FKind;

    { Ends the body (see TEncoderEnd). NotEofRemaining is set for eeNotEof. }
    function Finish(out Buf: TEncodedBuf; out NotEofRemaining: QWord): TEncoderEnd;
    { Encodes one piece of body; Len must be > 0 (an empty chunk would mean
      the end of a chunked body). }
    procedure Encode(Data: PByte; Len: SizeInt; out Buf: TEncodedBuf);
    { Encodes the last data and the end of the body together. Returns True
      when the body is complete and the connection may be kept alive (not
      the last response); False otherwise (a Length body still short, a
      close-delimited body, or the last response). For Length it does not
      change Remaining. }
    function EncodeAndEnd(Data: PByte; Len: SizeInt; out Buf: TEncodedBuf): Boolean;
    { Keeps the trailers whose names were announced and are allowed in
      trailers (IsValidTrailerField), and appends "0\r\n" + fields + "\r\n"
      to Dst. Returns False (Dst unchanged) when nothing is to be written:
      not chunked, no trailer name list set, or no field kept; the end of
      the body has then not been written yet (Finish writes it). Fields are grouped by name in order
      of first appearance, each group in list order. TitleCase writes names
      as "Content-Type", otherwise lowercase. Builds with assertions (-Sa)
      check that every written name and value is valid. }
    function EncodeTrailers(Trailers: THttpHeaders; TitleCase: Boolean; var Dst: TByteVec;
      Pool: PBlockPool): Boolean; overload;
    { Same, into a new byte array (Dst = nil when False). For tests. }
    function EncodeTrailers(Trailers: THttpHeaders; TitleCase: Boolean; out Dst: TBytes): Boolean; overload;
  end;

{ False for the fields that must not be sent as trailers, because they
  affect framing, routing, authentication or how the body is handled
  (RFC 9110 section 6.5.1): authorization, cache-control, content-encoding,
  content-length, content-range, content-type, host, max-forwards,
  set-cookie, trailer, transfer-encoding, te. }
function IsValidTrailerField(Name: PByte; Len: SizeInt): Boolean;

{ Writes "<HEX>\r\n" (uppercase, no leading zeros) to Dst. Returns length. }
function WriteChunkSize(Dst: PByte; Len: SizeUInt): SizeInt;

implementation

const
  CRLF: array[0..1] of Byte = (13, 10);
  CHUNKED_END: array[0..4] of Byte = (Ord('0'), 13, 10, 13, 10);
  CRLF_CHUNKED_END: array[0..6] of Byte = (13, 10, Ord('0'), 13, 10, 13, 10);
  HEX_UPPER: array[0..15] of AnsiChar = '0123456789ABCDEF';

  INVALID_TRAILERS: array[0..11] of RawByteString = (
    HN_AUTHORIZATION, HN_CACHE_CONTROL, HN_CONTENT_ENCODING, HN_CONTENT_LENGTH,
    HN_CONTENT_RANGE, HN_CONTENT_TYPE, HN_HOST, HN_MAX_FORWARDS, HN_SET_COOKIE,
    HN_TRAILER, HN_TRANSFER_ENCODING, HN_TE);

threadvar
  { announced trailer names of encoders that were given no set (tests,
    direct callers) }
  DefaultTrailerFields: TTrailerFieldSet;

function IsValidTrailerField(Name: PByte; Len: SizeInt): Boolean;
var
  I: Integer;
begin
  for I := Low(INVALID_TRAILERS) to High(INVALID_TRAILERS) do
    if AsciiEqualIgnoreCaseStr(Name, Len, INVALID_TRAILERS[I]) then
      Exit(False);
  Result := True;
end;

function WriteChunkSize(Dst: PByte; Len: SizeUInt): SizeInt;
var
  Tmp: array[0..CHUNK_SIZE_MAX_BYTES - 1] of Byte;
  N, I: Integer;
begin
  N := 0;
  repeat
    Tmp[N] := Ord(HEX_UPPER[Len and 15]);
    Len := Len shr 4;
    Inc(N);
  until Len = 0;
  for I := 0 to N - 1 do
    Dst[I] := Tmp[N - 1 - I];
  Dst[N] := 13;
  Dst[N + 1] := 10;
  Result := N + 2;
end;

{ TTrailerFieldSet }

procedure TTrailerFieldSet.Clear;
begin
  BytesLen := 0;
  Count := 0;
end;

procedure TTrailerFieldSet.Add(P: PByte; Len: SizeInt);
var
  NewCap: SizeInt;
  N: PTrailerName;
begin
  if BytesLen + Len > BytesCap then
  begin
    NewCap := 2 * BytesCap;
    if NewCap < 64 then NewCap := 64;
    if NewCap < BytesLen + Len then NewCap := BytesLen + Len;
    ReallocMem(Bytes, NewCap);
    BytesCap := NewCap;
  end;
  if Count >= NamesCap then
  begin
    NewCap := 2 * NamesCap;
    if NewCap < 4 then NewCap := 4;
    ReallocMem(Names, NewCap * SizeOf(TTrailerName));
    NamesCap := NewCap;
  end;
  if Len > 0 then
    Move(P^, Bytes[BytesLen], Len);
  N := @Names[Count];
  N^.Ofs := BytesLen;
  N^.Len := Len;
  Inc(BytesLen, Len);
  Inc(Count);
end;

function TTrailerFieldSet.Contains(P: PByte; Len: SizeInt): Boolean;
var
  I: SizeInt;
begin
  for I := 0 to Count - 1 do
    if (Names[I].Len = Len) and AsciiEqualIgnoreCase(Bytes + Names[I].Ofs, Len, P, Len) then
      Exit(True);
  Result := False;
end;

function TTrailerFieldSet.NamePtr(I: SizeInt): PByte;
begin
  Result := Bytes + Names[I].Ofs;
end;

function TTrailerFieldSet.NameLen(I: SizeInt): SizeInt;
begin
  Result := Names[I].Len;
end;

procedure TTrailerFieldSet.Done;
begin
  if Bytes <> nil then FreeMem(Bytes);
  if Names <> nil then FreeMem(Names);
  Bytes := nil;
  Names := nil;
  BytesLen := 0;
  BytesCap := 0;
  Count := 0;
  NamesCap := 0;
end;

{ TEncodedBuf }

procedure TEncodedBuf.SetChunkSize(Len: SizeUInt);
begin
  FPrefixPos := 0;
  FPrefixLen := Byte(WriteChunkSize(@FPrefix[0], Len));
end;

function TEncodedBuf.Remaining: SizeInt;
begin
  Result := (FPrefixLen - FPrefixPos) + FDataLen + FSuffixLen;
end;

function TEncodedBuf.CopyTo(Dst: PByte): SizeInt;
var
  N: SizeInt;
begin
  Result := 0;
  N := FPrefixLen - FPrefixPos;
  if N > 0 then
  begin
    Move(FPrefix[FPrefixPos], Dst^, N);
    Inc(Result, N);
  end;
  if FDataLen > 0 then
  begin
    Move(FData^, Dst[Result], FDataLen);
    Inc(Result, FDataLen);
  end;
  if FSuffixLen > 0 then
  begin
    Move(FSuffix^, Dst[Result], FSuffixLen);
    Inc(Result, FSuffixLen);
  end;
end;

procedure TEncodedBuf.AppendTo(var Buf: TBytes; var Len: SizeInt);
var
  Need, NewCap: SizeInt;
begin
  Need := Remaining;
  if Need = 0 then
    Exit;
  if Len + Need > System.Length(Buf) then
  begin
    NewCap := System.Length(Buf) * 2;
    if NewCap < Len + Need then NewCap := Len + Need;
    SetLength(Buf, NewCap);
  end;
  Inc(Len, CopyTo(@Buf[Len]));
end;

procedure TEncodedBuf.Advance(N: SizeInt);
var
  K: SizeInt;
begin
  if N > Remaining then
    raise ERangeError.Create('TEncodedBuf.Advance past end');
  K := FPrefixLen - FPrefixPos;
  if K > N then K := N;
  Inc(FPrefixPos, K);
  Dec(N, K);
  K := FDataLen;
  if K > N then K := N;
  Inc(FData, K);
  Dec(FDataLen, K);
  Dec(N, K);
  K := FSuffixLen;
  if K > N then K := N;
  Inc(FSuffix, K);
  Dec(FSuffixLen, K);
end;

function TEncodedBuf.FillIoVec(Dst: PIoSlice; MaxCount: Integer): Integer;
begin
  Result := 0;
  if (Result < MaxCount) and (FPrefixLen > FPrefixPos) then
  begin
    Dst[Result].Base := @FPrefix[FPrefixPos];
    Dst[Result].Len := FPrefixLen - FPrefixPos;
    Inc(Result);
  end;
  if (Result < MaxCount) and (FDataLen > 0) then
  begin
    Dst[Result].Base := FData;
    Dst[Result].Len := FDataLen;
    Inc(Result);
  end;
  if (Result < MaxCount) and (FSuffixLen > 0) then
  begin
    Dst[Result].Base := FSuffix;
    Dst[Result].Len := FSuffixLen;
    Inc(Result);
  end;
end;

procedure TEncodedBuf.SplitData(out Head: TEncodedBuf; out DataLen: SizeInt;
  out Tail: TEncodedBuf);
begin
  Head := Self;
  Head.FData := nil;
  Head.FDataLen := 0;
  Head.FSuffix := nil;
  Head.FSuffixLen := 0;
  DataLen := FDataLen;
  Tail := Self;
  Tail.FPrefixPos := 0;
  Tail.FPrefixLen := 0;
  Tail.FData := nil;
  Tail.FDataLen := 0;
end;

procedure ClearBuf(out Buf: TEncodedBuf; Kind: TEncodedBufKind); inline;
begin
  Buf.FKind := Kind;
  Buf.FPrefixPos := 0;
  Buf.FPrefixLen := 0;
  Buf.FData := nil;
  Buf.FDataLen := 0;
  Buf.FSuffix := nil;
  Buf.FSuffixLen := 0;
end;

{ TEncoder }

class function TEncoder.Chunked: TEncoder;
begin
  Result.FKind := ekChunked;
  Result.FRemaining := 0;
  Result.FIsLast := False;
  Result.FHasTrailerFields := False;
  Result.FTrailers := nil;
end;

class function TEncoder.Length(Len: QWord): TEncoder;
begin
  Result.FKind := ekLength;
  Result.FRemaining := Len;
  Result.FIsLast := False;
  Result.FHasTrailerFields := False;
  Result.FTrailers := nil;
end;

class function TEncoder.CloseDelimited: TEncoder;
begin
  Result.FKind := ekCloseDelimited;
  Result.FRemaining := 0;
  Result.FIsLast := False;
  Result.FHasTrailerFields := False;
  Result.FTrailers := nil;
end;

procedure TEncoder.SetTrailerFieldSet(S: PTrailerFieldSet);
begin
  FTrailers := S;
end;

function TEncoder.TrailerSet: PTrailerFieldSet;
begin
  if FTrailers = nil then
    FTrailers := @DefaultTrailerFields;
  Result := FTrailers;
end;

procedure TEncoder.IntoChunkedWithTrailingFields(const Names: array of RawByteString);
var
  I: Integer;
  T: PTrailerFieldSet;
begin
  if FKind <> ekChunked then
    Exit;
  { replaces any earlier list }
  T := TrailerSet;
  T^.Clear;
  FHasTrailerFields := True;
  for I := 0 to High(Names) do
    T^.Add(PByte(Pointer(Names[I])), System.Length(Names[I]));
end;

procedure TEncoder.IntoChunkedWithTrailerHeader(Value: PByte; Len: SizeInt);
var
  I, S, E: SizeInt;
  T: PTrailerFieldSet;
begin
  if FKind <> ekChunked then
    Exit;
  { only visible ASCII values are used }
  if not IsVisibleAscii(Value, Len) then
    Exit;
  { the first Trailer field starts a new list; later ones extend it }
  T := TrailerSet;
  if not FHasTrailerFields then
    T^.Clear;
  FHasTrailerFields := True;
  I := 0;
  while I <= Len do
  begin
    S := I;
    while (I < Len) and (Value[I] <> Ord(',')) do Inc(I);
    E := I;
    while (S < E) and ((Value[S] = 32) or (Value[S] = 9)) do Inc(S);
    while (E > S) and ((Value[E - 1] = 32) or (Value[E - 1] = 9)) do Dec(E);
    { invalid names (including empty items) are skipped }
    if IsValidHeaderName(Value + S, E - S) then
      T^.Add(Value + S, E - S);
    Inc(I);
  end;
end;

function TEncoder.IsEof: Boolean;
begin
  Result := (FKind = ekLength) and (FRemaining = 0);
end;

procedure TEncoder.SetLast(AIsLast: Boolean);
begin
  FIsLast := AIsLast;
end;

function TEncoder.IsLast: Boolean;
begin
  Result := FIsLast;
end;

function TEncoder.IsCloseDelimited: Boolean;
begin
  Result := FKind = ekCloseDelimited;
end;

function TEncoder.IsChunked: Boolean;
begin
  Result := FKind = ekChunked;
end;

function TEncoder.Finish(out Buf: TEncodedBuf; out NotEofRemaining: QWord): TEncoderEnd;
begin
  ClearBuf(Buf, ebkChunkedEnd);
  NotEofRemaining := 0;
  case FKind of
    ekLength:
      if FRemaining = 0 then
        Result := eeNone
      else
      begin
        NotEofRemaining := FRemaining;
        Result := eeNotEof;
      end;
    ekChunked:
      begin
        Buf.FSuffix := @CHUNKED_END[0];
        Buf.FSuffixLen := System.Length(CHUNKED_END);
        Result := eeBuf;
      end;
  else
    Result := eeNone;   { CloseDelimited }
  end;
end;

procedure TEncoder.Encode(Data: PByte; Len: SizeInt; out Buf: TEncodedBuf);
begin
  Assert(Len > 0, 'encode() called with empty buf');
  case FKind of
    ekChunked:
      begin
        ClearBuf(Buf, ebkChunked);
        Buf.SetChunkSize(SizeUInt(Len));
        Buf.FData := Data;
        Buf.FDataLen := Len;
        Buf.FSuffix := @CRLF[0];
        Buf.FSuffixLen := 2;
      end;
    ekLength:
      if FRemaining < QWord(Len) then
      begin
        { holding more than is owed: write only what is left }
        ClearBuf(Buf, ebkLimited);
        Buf.FData := Data;
        Buf.FDataLen := SizeInt(FRemaining);
        FRemaining := 0;
      end
      else
      begin
        ClearBuf(Buf, ebkExact);
        Buf.FData := Data;
        Buf.FDataLen := Len;
        Dec(FRemaining, QWord(Len));
      end;
  else
    begin
      ClearBuf(Buf, ebkExact);
      Buf.FData := Data;
      Buf.FDataLen := Len;
    end;
  end;
end;

function TEncoder.EncodeAndEnd(Data: PByte; Len: SizeInt; out Buf: TEncodedBuf): Boolean;
begin
  Assert(Len > 0, 'encode() called with empty buf');
  case FKind of
    ekChunked:
      begin
        ClearBuf(Buf, ebkChunked);
        Buf.SetChunkSize(SizeUInt(Len));
        Buf.FData := Data;
        Buf.FDataLen := Len;
        Buf.FSuffix := @CRLF_CHUNKED_END[0];
        Buf.FSuffixLen := System.Length(CRLF_CHUNKED_END);
        Result := not FIsLast;
      end;
    ekLength:
      begin
        if QWord(Len) = FRemaining then
        begin
          ClearBuf(Buf, ebkExact);
          Buf.FData := Data;
          Buf.FDataLen := Len;
          Result := not FIsLast;
        end
        else if QWord(Len) > FRemaining then
        begin
          ClearBuf(Buf, ebkLimited);
          Buf.FData := Data;
          Buf.FDataLen := SizeInt(FRemaining);
          Result := not FIsLast;
        end
        else
        begin
          ClearBuf(Buf, ebkExact);
          Buf.FData := Data;
          Buf.FDataLen := Len;
          Result := False;
        end;
        { FRemaining is not updated: the body ends here either way }
      end;
  else
    begin
      ClearBuf(Buf, ebkExact);
      Buf.FData := Data;
      Buf.FDataLen := Len;
      Result := False;
    end;
  end;
end;

function TEncoder.TrailerAllowed(Trailers: THttpHeaders; I: SizeInt): Boolean;
var
  NP: PByte;
  NL: SizeInt;
begin
  NP := Trailers.NamePtr(I);
  NL := Trailers.NameLen(I);
  { announced, and not a forbidden trailer field }
  Result := TrailerSet^.Contains(NP, NL) and IsValidTrailerField(NP, NL);
end;

procedure AssertTrailerField(Trailers: THttpHeaders; I: SizeInt);
begin
  Assert(CheckHeaderField(Trailers.NamePtr(I), Trailers.NameLen(I),
    Trailers.ValuePtr(I), Trailers.ValueLen(I)) = hcOk,
    'EncodeTrailers: invalid trailer field reached the encoder');
end;

function TEncoder.EncodeTrailers(Trailers: THttpHeaders; TitleCase: Boolean; var Dst: TByteVec;
  Pool: PBlockPool): Boolean;
var
  I, J, K, Count, Body, NL, VL: SizeInt;
  NP: PByte;
  D, Start: PByte;
  Later: Boolean;
begin
  Result := False;
  if (FKind <> ekChunked) or (not FHasTrailerFields) or (Trailers = nil) then
    Exit;
  Count := Trailers.Count;

  { first pass: size of the allowed fields }
  Body := 0;
  for I := 0 to Count - 1 do
    if TrailerAllowed(Trailers, I) then
      Inc(Body, Trailers.NameLen(I) + Trailers.ValueLen(I) + 4);
  { no field kept: nothing to write }
  if Body = 0 then
    Exit;

  Dst.Reserve(3 + Body + 2, Pool);
  Start := Dst.Data + Dst.Len;
  D := Start;
  D[0] := Ord('0');
  D[1] := 13;
  D[2] := 10;
  Inc(D, 3);
  { Each name once, at its first position, followed by all its values in
    list order. Allowed depends only on the name, so a group is either
    written whole or skipped. The O(n^2) scan is fine: trailer lists are
    short. }
  for I := 0 to Count - 1 do
  begin
    if not TrailerAllowed(Trailers, I) then
      Continue;
    NP := Trailers.NamePtr(I);
    NL := Trailers.NameLen(I);
    Later := False;
    for J := 0 to I - 1 do
      if AsciiEqualIgnoreCase(Trailers.NamePtr(J), Trailers.NameLen(J), NP, NL) then
      begin
        Later := True;
        Break;
      end;
    if Later then
      Continue;   { already written with its group }
    for K := I to Count - 1 do
    begin
      if (K > I) and not AsciiEqualIgnoreCase(Trailers.NamePtr(K), Trailers.NameLen(K), NP, NL) then
        Continue;
      {$IFOPT C+}
      AssertTrailerField(Trailers, K);
      {$ENDIF}
      if TitleCase then
        WriteTitleCase(D, NP, NL)
      else
        for J := 0 to NL - 1 do
          D[J] := AsciiLower(NP[J]);
      Inc(D, NL);
      D[0] := Ord(':');
      D[1] := Ord(' ');
      Inc(D, 2);
      VL := Trailers.ValueLen(K);
      if VL > 0 then
        Move(Trailers.ValuePtr(K)^, D^, VL);
      Inc(D, VL);
      D[0] := 13;
      D[1] := 10;
      Inc(D, 2);
    end;
  end;
  D[0] := 13;
  D[1] := 10;
  Inc(D, 2);
  Inc(Dst.Len, D - Start);
  Result := True;
end;

function TEncoder.EncodeTrailers(Trailers: THttpHeaders; TitleCase: Boolean; out Dst: TBytes): Boolean;
var
  V: TByteVec;
begin
  Dst := nil;
  V := Default(TByteVec);
  Result := EncodeTrailers(Trailers, TitleCase, V, nil);
  if Result then
  begin
    SetLength(Dst, V.Len);
    Move(V.Data^, Dst[0], V.Len);
  end;
  V.Clear;
  V.ReleaseIdle(nil);
end;

finalization
  DefaultTrailerFields.Done;

end.

{ bearings.ws.frame - WebSocket frames (RFC 6455 section 5): an incremental
  reader for the frames a client sends and an encoder for the frame headers
  the server sends.

  After the handshake, both sides of a WebSocket connection send frames. A
  frame is a header of 2 to 14 bytes followed by a payload:
    byte 0   FIN (this is the last frame of a message), three reserved bits
             RSV1-3 (used only by negotiated extensions), and a 4-bit opcode;
    byte 1   the MASK bit and a 7-bit length; 126 means a 16-bit length
             follows, 127 a 64-bit length (its top bit must be 0);
    then     a 4-byte masking key when MASK is set;
    then     the payload. A masked payload is XORed with the key, byte i
             with key[i mod 4].
  Every frame a client sends must be masked; frames from the server never
  are. A message (text or binary) is one frame, or a first frame with
  FIN = 0, any number of continuation frames (opcode 0), and a last
  continuation frame with FIN = 1. Control frames (close, ping, pong) may
  arrive between the frames of a message; they carry at most 125 bytes and
  are never fragmented. A text message must be valid UTF-8 as a whole; a
  frame boundary may fall inside a character.

  TWsReader takes the bytes as they arrive from the socket, in pieces of
  any size, and reports one event at a time (Next):
    reNeedMore  every byte given was used; call again with more bytes.
    reData      a piece of a data message's payload: Data/DataLen, already
                unmasked (in place: the reader writes into the caller's
                buffer), MsgOpcode (WS_OP_TEXT or WS_OP_BINARY), MsgFirst
                (no payload byte of this message came before) and MsgEnd
                (the message is complete after this piece). A text piece
                has passed the UTF-8 check. An empty message gives one
                reData event with DataLen = 0 and MsgEnd = True.
    reControl   a complete control frame: CtlOpcode and the payload in
                Ctl[0..CtlLen-1]. A close frame has passed the checks
                below.
    reError     the client broke the protocol. ErrCode is the close code to
                send (1002 protocol error, 1007 invalid UTF-8, 1009 message
                too large) and ErrText says what was wrong. The reader stays
                in this state; the connection must be failed.
  The checks: RSV bits must be 0 (no extension is negotiated); opcodes 3-7
  and 11-15 are reserved; a frame must be masked; a control frame must have
  FIN = 1 and at most 125 bytes; a 64-bit length must have its top bit
  clear; a continuation frame needs a message in progress and a new text or
  binary frame needs none; a message larger than MaxMessage bytes is
  refused as soon as a frame header announces it (1009); text is checked
  as UTF-8 piece by piece, so an invalid byte is found in the piece where it
  arrives; a close frame has no payload, or a 2-byte status code that may
  be sent on the wire (1000-1003, 1007-1014, 3000-4999) followed by a
  UTF-8 reason.

  The encoder writes a server frame header (never masked) with the shortest
  length form. The payload follows the header unchanged.

  TUtf8Check is the incremental UTF-8 validator (RFC 3629: no overlong
  forms, no surrogates, nothing above U+10FFFF). It keeps, between pieces,
  how many continuation bytes the current character still needs and the
  range the next byte must fall in.

  Threading: none. A reader belongs to one connection. }
unit bearings.ws.frame;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

const
  WS_OP_CONT = 0;
  WS_OP_TEXT = 1;
  WS_OP_BINARY = 2;
  WS_OP_CLOSE = 8;
  WS_OP_PING = 9;
  WS_OP_PONG = 10;

  { close codes (RFC 6455 section 7.4.1) }
  WS_CLOSE_NORMAL = 1000;
  WS_CLOSE_GOING_AWAY = 1001;
  WS_CLOSE_PROTOCOL_ERROR = 1002;
  WS_CLOSE_UNSUPPORTED = 1003;
  WS_CLOSE_NO_STATUS = 1005;           { never sent: the close frame had no code }
  WS_CLOSE_ABNORMAL = 1006;            { never sent: the connection ended without a close frame }
  WS_CLOSE_INVALID_DATA = 1007;
  WS_CLOSE_POLICY = 1008;
  WS_CLOSE_TOO_BIG = 1009;
  WS_CLOSE_INTERNAL_ERROR = 1011;

  WS_MAX_CONTROL = 125;                { payload bytes of a control frame }
  WS_MAX_HEADER = 14;                  { 2 + 8 (length) + 4 (mask) }

type
  { Incremental UTF-8 check. A zeroed record is the start state. }
  TUtf8Check = record
    Need: Integer;                     { continuation bytes the current character still needs }
    Lo, Hi: Byte;                      { the range of the next continuation byte }
    { False at the first invalid byte; the state is then meaningless }
    function Feed(P: PByte; Len: SizeInt): Boolean;
    { True when no character is cut off (the text may end here) }
    function Complete: Boolean; inline;
    procedure Reset; inline;
  end;

  TWsReadEvent = (reNeedMore, reData, reControl, reError);

  TWsReader = record
  private
    FHdr: array[0..WS_MAX_HEADER - 1] of Byte;
    FHdrLen, FHdrNeed: Integer;        { header bytes collected / needed (0: none started) }
    FInPayload: Boolean;               { the header is done; payload bytes follow }
    FFin: Boolean;
    FOpcode: Byte;                     { the current frame's opcode }
    FMask: array[0..3] of Byte;
    FMaskPos: Integer;                 { payload bytes of this frame already unmasked, mod 4 }
    FRemaining: QWord;                 { payload bytes of this frame not yet read }
    FMsgOp: Byte;                      { opcode of the message in progress; 0 none }
    FMsgLen: Int64;                    { payload bytes of the message in progress so far }
    FFailed: Boolean;
    FUtf8: TUtf8Check;
    function Fail(Code: Word; const Text: string): TWsReadEvent;
    function HeaderDone: TWsReadEvent;
    function FrameStart: TWsReadEvent;
    function ControlDone: TWsReadEvent;
    procedure Unmask(P: PByte; N: SizeInt);
  public
    { limit for one message's payload (the sum of its frames); 0 = none }
    MaxMessage: Int64;
    { the event of the last Next call }
    MsgOpcode: Byte;                   { reData: the message's opcode, WS_OP_TEXT or WS_OP_BINARY }
    Data: PByte;
    DataLen: SizeInt;
    MsgFirst, MsgEnd: Boolean;
    CtlOpcode: Byte;
    Ctl: array[0..WS_MAX_CONTROL - 1] of Byte;
    CtlLen: Integer;
    ErrCode: Word;
    ErrText: string;
    { A fresh reader with the given message limit. }
    procedure Init(AMaxMessage: Int64);
    { Uses bytes from [P, P + Len) and advances P and Len past them (reData:
      Data points into the bytes just used). Unmasks the payload in place. }
    function Next(var P: PByte; var Len: SizeInt): TWsReadEvent;
    property Failed: Boolean read FFailed;
  end;

{ The bytes a server frame header takes for a payload of Len bytes: 2, 4 or 10. }
function WsHeaderSize(Len: QWord): Integer; inline;
{ Writes a server frame header (no mask) at Dst; returns its size. }
function WsEncodeHeader(Dst: PByte; Fin: Boolean; Opcode: Byte; Len: QWord): Integer;
{ True for a close code an endpoint may send in a close frame. }
function WsCloseCodeValid(Code: Word): Boolean;
{ Whole-buffer UTF-8 check. }
function WsValidUtf8(P: PByte; Len: SizeInt): Boolean;

implementation

uses
  SysUtils;

{ ---- TUtf8Check ---- }

function TUtf8Check.Feed(P: PByte; Len: SizeInt): Boolean;
var
  I: SizeInt;
  B: Byte;
begin
  I := 0;
  while I < Len do
  begin
    if Need = 0 then
    begin
      { ASCII runs: eight bytes at a time while no high bit is set }
      while (I + 8 <= Len) and ((PQWord(P + I)^ and QWord($8080808080808080)) = 0) do
        Inc(I, 8);
      if I >= Len then
        Break;
      B := P[I];
      Inc(I);
      if B < $80 then
        Continue;
      Lo := $80;
      Hi := $BF;
      case B of
        $C2..$DF: Need := 1;
        $E0: begin Need := 2; Lo := $A0; end;           { no overlong 3-byte form }
        $E1..$EC, $EE, $EF: Need := 2;
        $ED: begin Need := 2; Hi := $9F; end;           { no surrogates U+D800..U+DFFF }
        $F0: begin Need := 3; Lo := $90; end;           { no overlong 4-byte form }
        $F1..$F3: Need := 3;
        $F4: begin Need := 3; Hi := $8F; end;           { nothing above U+10FFFF }
      else
        Exit(False);                                    { $80..$C1, $F5..$FF }
      end;
    end
    else
    begin
      B := P[I];
      Inc(I);
      if (B < Lo) or (B > Hi) then
        Exit(False);
      Dec(Need);
      Lo := $80;
      Hi := $BF;
    end;
  end;
  Result := True;
end;

function TUtf8Check.Complete: Boolean;
begin
  Result := Need = 0;
end;

procedure TUtf8Check.Reset;
begin
  Need := 0;
end;

function WsValidUtf8(P: PByte; Len: SizeInt): Boolean;
var
  C: TUtf8Check;
begin
  C := Default(TUtf8Check);
  Result := C.Feed(P, Len) and C.Complete;
end;

function WsCloseCodeValid(Code: Word): Boolean;
begin
  { 1004 is reserved; 1005, 1006 and 1015 must never be sent; 1012-1014 are
    registered with IANA; 3000-3999 are for libraries and frameworks,
    4000-4999 for applications }
  case Code of
    1000..1003, 1007..1014, 3000..4999: Result := True;
  else
    Result := False;
  end;
end;

{ ---- encoder ---- }

function WsHeaderSize(Len: QWord): Integer;
begin
  if Len < 126 then
    Result := 2
  else if Len <= $FFFF then
    Result := 4
  else
    Result := 10;
end;

function WsEncodeHeader(Dst: PByte; Fin: Boolean; Opcode: Byte; Len: QWord): Integer;
var
  I: Integer;
begin
  if Fin then
    Dst[0] := $80 or Opcode
  else
    Dst[0] := Opcode;
  if Len < 126 then
  begin
    Dst[1] := Len;
    Result := 2;
  end
  else if Len <= $FFFF then
  begin
    Dst[1] := 126;
    Dst[2] := Len shr 8;
    Dst[3] := Len and $FF;
    Result := 4;
  end
  else
  begin
    Dst[1] := 127;
    for I := 0 to 7 do
      Dst[2 + I] := (Len shr (8 * (7 - I))) and $FF;
    Result := 10;
  end;
end;

{ ---- TWsReader ---- }

procedure TWsReader.Init(AMaxMessage: Int64);
begin
  Self := Default(TWsReader);
  MaxMessage := AMaxMessage;
end;

function TWsReader.Fail(Code: Word; const Text: string): TWsReadEvent;
begin
  FFailed := True;
  ErrCode := Code;
  ErrText := Text;
  Result := reError;
end;

procedure TWsReader.Unmask(P: PByte; N: SizeInt);
var
  I: SizeInt;
  K: Integer;
  M: QWord;
begin
  K := FMaskPos;
  I := 0;
  { byte by byte until the key lines up with K = 0, then 8 bytes at a time }
  while (I < N) and (K <> 0) do
  begin
    P[I] := P[I] xor FMask[K];
    K := (K + 1) and 3;
    Inc(I);
  end;
  if N - I >= 8 then
  begin
    M := QWord(PLongWord(@FMask[0])^);
    M := M or (M shl 32);
    while N - I >= 8 do
    begin
      PQWord(P + I)^ := PQWord(P + I)^ xor M;
      Inc(I, 8);
    end;
  end;
  while I < N do
  begin
    P[I] := P[I] xor FMask[K];
    K := (K + 1) and 3;
    Inc(I);
  end;
  FMaskPos := K;
end;

{ The first two header bytes are in FHdr: checks what they alone decide and
  sets FHdrNeed to the full header size. }
function TWsReader.FrameStart: TWsReadEvent;
var
  L7: Byte;
begin
  Result := reNeedMore;
  if (FHdr[0] and $70) <> 0 then
    Exit(Fail(WS_CLOSE_PROTOCOL_ERROR, 'reserved bits set without an extension'));
  FOpcode := FHdr[0] and $0F;
  FFin := (FHdr[0] and $80) <> 0;
  case FOpcode of
    WS_OP_CONT, WS_OP_TEXT, WS_OP_BINARY, WS_OP_CLOSE, WS_OP_PING, WS_OP_PONG: ;
  else
    Exit(Fail(WS_CLOSE_PROTOCOL_ERROR, 'reserved opcode ' + IntToStr(FOpcode)));
  end;
  if (FHdr[1] and $80) = 0 then
    Exit(Fail(WS_CLOSE_PROTOCOL_ERROR, 'unmasked client frame'));
  L7 := FHdr[1] and $7F;
  if FOpcode >= 8 then
  begin
    if not FFin then
      Exit(Fail(WS_CLOSE_PROTOCOL_ERROR, 'fragmented control frame'));
    if L7 > WS_MAX_CONTROL then
      Exit(Fail(WS_CLOSE_PROTOCOL_ERROR, 'control frame longer than 125 bytes'));
  end;
  case L7 of
    126: FHdrNeed := 2 + 2 + 4;
    127: FHdrNeed := 2 + 8 + 4;
  else
    FHdrNeed := 2 + 4;
  end;
end;

{ The whole header is in FHdr: reads the length and the key, applies the
  message rules and starts the payload. }
function TWsReader.HeaderDone: TWsReadEvent;
var
  L: QWord;
  I, KeyAt: Integer;
begin
  Result := reNeedMore;
  L := FHdr[1] and $7F;
  KeyAt := 2;
  if L = 126 then
  begin
    L := (QWord(FHdr[2]) shl 8) or FHdr[3];
    KeyAt := 4;
  end
  else if L = 127 then
  begin
    if (FHdr[2] and $80) <> 0 then
      Exit(Fail(WS_CLOSE_PROTOCOL_ERROR, '64-bit length with the top bit set'));
    L := 0;
    for I := 2 to 9 do
      L := (L shl 8) or FHdr[I];
    KeyAt := 10;
  end;
  Move(FHdr[KeyAt], FMask[0], 4);
  FMaskPos := 0;
  FRemaining := L;
  FHdrLen := 0;
  FHdrNeed := 0;
  if FOpcode >= 8 then
  begin
    CtlLen := 0;
    FInPayload := L > 0;
    if L = 0 then
      Result := ControlDone;
    Exit;
  end;
  { data frames: the fragmentation rules }
  if FOpcode = WS_OP_CONT then
  begin
    if FMsgOp = 0 then
      Exit(Fail(WS_CLOSE_PROTOCOL_ERROR, 'continuation frame without a message in progress'));
  end
  else
  begin
    if FMsgOp <> 0 then
      Exit(Fail(WS_CLOSE_PROTOCOL_ERROR, 'new message before the previous one ended'));
    FMsgOp := FOpcode;
    FMsgLen := 0;
    FUtf8.Reset;
  end;
  if (MaxMessage > 0) and (L > QWord(MaxMessage - FMsgLen)) then
    Exit(Fail(WS_CLOSE_TOO_BIG, 'message larger than ' + IntToStr(MaxMessage) + ' bytes'));
  FInPayload := L > 0;
  if (L = 0) and FFin then
  begin
    { the message ends with an empty frame: one event with no bytes }
    if (FMsgOp = WS_OP_TEXT) and not FUtf8.Complete then
      Exit(Fail(WS_CLOSE_INVALID_DATA, 'text message ends inside a UTF-8 character'));
    Data := nil;
    DataLen := 0;
    MsgOpcode := FMsgOp;
    MsgFirst := FMsgLen = 0;
    MsgEnd := True;
    FMsgOp := 0;
    FMsgLen := 0;
    Result := reData;
  end;
end;

function TWsReader.ControlDone: TWsReadEvent;
var
  Code: Word;
begin
  CtlOpcode := FOpcode;
  if FOpcode = WS_OP_CLOSE then
  begin
    if CtlLen = 1 then
      Exit(Fail(WS_CLOSE_PROTOCOL_ERROR, 'close frame with a 1-byte payload'));
    if CtlLen >= 2 then
    begin
      Code := (Word(Ctl[0]) shl 8) or Ctl[1];
      if not WsCloseCodeValid(Code) then
        Exit(Fail(WS_CLOSE_PROTOCOL_ERROR, 'invalid close code ' + IntToStr(Code)));
      if not WsValidUtf8(@Ctl[2], CtlLen - 2) then
        Exit(Fail(WS_CLOSE_INVALID_DATA, 'close reason is not valid UTF-8'));
    end;
  end;
  Result := reControl;
end;

function TWsReader.Next(var P: PByte; var Len: SizeInt): TWsReadEvent;
var
  N: SizeInt;
begin
  if FFailed then
    Exit(reError);
  while Len > 0 do
  begin
    if not FInPayload then
    begin
      { header bytes: the first two decide how many follow }
      if FHdrNeed = 0 then
        FHdrNeed := 2;
      N := FHdrNeed - FHdrLen;
      if N > Len then
        N := Len;
      Move(P^, FHdr[FHdrLen], N);
      Inc(FHdrLen, N);
      Inc(P, N);
      Dec(Len, N);
      if FHdrLen < FHdrNeed then
        Exit(reNeedMore);
      if FHdrNeed = 2 then
      begin
        Result := FrameStart;
        if Result = reError then
          Exit;
        if FHdrLen < FHdrNeed then
          Continue;
      end;
      Result := HeaderDone;
      if Result <> reNeedMore then
        Exit;
      Continue;
    end;
    { payload bytes }
    N := Len;
    if QWord(N) > FRemaining then
      N := FRemaining;
    Unmask(P, N);
    Dec(FRemaining, N);
    if FOpcode >= 8 then
    begin
      Move(P^, Ctl[CtlLen], N);
      Inc(CtlLen, N);
      Inc(P, N);
      Dec(Len, N);
      if FRemaining = 0 then
      begin
        FInPayload := False;
        Exit(ControlDone);
      end;
      Continue;
    end;
    if (FMsgOp = WS_OP_TEXT) and not FUtf8.Feed(P, N) then
      Exit(Fail(WS_CLOSE_INVALID_DATA, 'text message is not valid UTF-8'));
    MsgOpcode := FMsgOp;
    Data := P;
    DataLen := N;
    MsgFirst := FMsgLen = 0;
    Inc(FMsgLen, N);
    Inc(P, N);
    Dec(Len, N);
    MsgEnd := False;
    if FRemaining = 0 then
    begin
      FInPayload := False;
      if FFin then
      begin
        if (FMsgOp = WS_OP_TEXT) and not FUtf8.Complete then
          Exit(Fail(WS_CLOSE_INVALID_DATA, 'text message ends inside a UTF-8 character'));
        MsgEnd := True;
        FMsgOp := 0;
        FMsgLen := 0;
      end;
    end;
    Exit(reData);
  end;
  Result := reNeedMore;
end;

end.

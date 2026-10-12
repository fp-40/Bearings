{ bearings.test.ws - helpers for the WebSocket tests: client frames (masked,
  as a client sends them), an event log of TWsReader runs (whole or in
  random pieces), a reader for the server frames a test receives, and a
  short digest of payloads for assertions. }
unit bearings.test.ws;

{$mode objfpc}{$H+}
{$Q-}{$R-}  { the hash and the pattern generator wrap around on purpose }

interface

uses
  SysUtils, bearings.ws.frame;

{ N deterministic bytes }
function Pattern(N: SizeInt): RawByteString;
{ 16 hex digits of the FNV-1a hash of S }
function Digest(const S: RawByteString): RawByteString;
{ a masked client frame, shortest length form }
function CFrame(Op: Byte; const Payload: RawByteString; Fin: Boolean = True;
  Mask: LongWord = $5A1C3E7F): RawByteString;
{ a masked final client frame with the length in the 16-bit (Form = 126) or
  64-bit (Form = 127) form whatever the length }
function CFrameForm(Op: Byte; const Payload: RawByteString; Form: Integer): RawByteString;
{ a client frame with first byte B0, masked or not, shortest length form }
function CFrameRaw(B0: Byte; const Payload: RawByteString; Masked: Boolean): RawByteString;
{ Runs a fresh TWsReader (MaxMessage) over S given whole and logs the
  events: 'T<len>:<digest>|' / 'B<len>:<digest>|' per complete message,
  'C<opcode>:<payload>|' per control frame, 'E<code>|' at an error (the end). }
function ReadAll(const S: RawByteString; MaxMessage: Int64): RawByteString;
{ The same, with S given in random pieces (seed Seed). }
function ReadSplit(const S: RawByteString; MaxMessage: Int64; Seed: LongWord): RawByteString;

type
  TServerFrame = record
    Fin: Boolean;
    Rsv: Byte;
    Opcode: Byte;
    Masked: Boolean;
    Payload: RawByteString;
  end;

{ Takes one complete server frame from the front of S. False when S does
  not hold a whole frame yet (S unchanged). }
function TakeServerFrame(var S: RawByteString; out F: TServerFrame): Boolean;
{ Every complete server frame of S as 'op:payload|' (op in decimal; text
  and binary payloads longer than 40 bytes as '<len>#<digest>'); S keeps
  what is left. }
function ServerFramesLog(var S: RawByteString): RawByteString;

implementation

function Pattern(N: SizeInt): RawByteString;
var
  I: SizeInt;
  X: LongWord;
begin
  SetLength(Result, N);
  X := 2463534242;
  for I := 1 to N do
  begin
    X := X xor (X shl 13);
    X := X xor (X shr 17);
    X := X xor (X shl 5);
    Result[I] := AnsiChar(X and $FF);
  end;
end;

function Digest(const S: RawByteString): RawByteString;
var
  H: QWord;
  I: SizeInt;
begin
  H := QWord($CBF29CE484222325);
  for I := 1 to Length(S) do
  begin
    H := H xor Byte(S[I]);
    H := H * QWord($100000001B3);
  end;
  Result := IntToHex(H, 16);
end;

function Build(B0: Byte; const Payload: RawByteString; Masked: Boolean; Mask: LongWord;
  Form: Integer): RawByteString;
var
  L: QWord;
  H: RawByteString;
  I: Integer;
  K: array[0..3] of Byte;
  P: RawByteString;
begin
  L := Length(Payload);
  H := AnsiChar(B0);
  if Form = 0 then
  begin
    if L < 126 then Form := 1
    else if L <= $FFFF then Form := 126
    else Form := 127;
  end;
  if Form = 1 then
    H := H + AnsiChar(L or (Ord(Masked) shl 7))
  else if Form = 126 then
    H := H + AnsiChar(126 or (Ord(Masked) shl 7)) + AnsiChar(L shr 8) + AnsiChar(L and $FF)
  else
  begin
    H := H + AnsiChar(127 or (Ord(Masked) shl 7));
    for I := 7 downto 0 do
      H := H + AnsiChar((L shr (8 * I)) and $FF);
  end;
  P := Payload;
  UniqueString(P);
  if Masked then
  begin
    K[0] := Mask shr 24; K[1] := (Mask shr 16) and $FF; K[2] := (Mask shr 8) and $FF; K[3] := Mask and $FF;
    H := H + AnsiChar(K[0]) + AnsiChar(K[1]) + AnsiChar(K[2]) + AnsiChar(K[3]);
    for I := 1 to Length(P) do
      P[I] := AnsiChar(Byte(P[I]) xor K[(I - 1) and 3]);
  end;
  Result := H + P;
end;

function CFrame(Op: Byte; const Payload: RawByteString; Fin: Boolean; Mask: LongWord): RawByteString;
begin
  Result := Build(Op or (Ord(Fin) shl 7), Payload, True, Mask, 0);
end;

function CFrameForm(Op: Byte; const Payload: RawByteString; Form: Integer): RawByteString;
begin
  Result := Build(Op or $80, Payload, True, $11223344, Form);
end;

function CFrameRaw(B0: Byte; const Payload: RawByteString; Masked: Boolean): RawByteString;
begin
  Result := Build(B0, Payload, Masked, $0BADF00D, 0);
end;

type
  TLogState = record
    R: TWsReader;
    Msg, Log: RawByteString;
    Done: Boolean;
  end;

procedure Feed(var St: TLogState; P: PByte; L: SizeInt);
var
  S: RawByteString;
begin
  while not St.Done do
    case St.R.Next(P, L) of
      reNeedMore: Exit;
      reData:
        begin
          SetString(S, PAnsiChar(St.R.Data), St.R.DataLen);
          St.Msg := St.Msg + S;
          if St.R.MsgEnd then
          begin
            if St.R.MsgOpcode = WS_OP_TEXT then St.Log := St.Log + 'T' else St.Log := St.Log + 'B';
            St.Log := St.Log + IntToStr(Length(St.Msg)) + ':' + Digest(St.Msg) + '|';
            St.Msg := '';
          end;
        end;
      reControl:
        begin
          SetString(S, PAnsiChar(@St.R.Ctl[0]), St.R.CtlLen);
          St.Log := St.Log + 'C' + IntToStr(St.R.CtlOpcode) + ':' + S + '|';
        end;
      reError:
        begin
          St.Log := St.Log + 'E' + IntToStr(St.R.ErrCode) + '|';
          St.Done := True;
        end;
    end;
end;

function ReadAll(const S: RawByteString; MaxMessage: Int64): RawByteString;
var
  St: TLogState;
  B: RawByteString;
begin
  St := Default(TLogState);
  St.R.Init(MaxMessage);
  B := S;
  UniqueString(B);
  Feed(St, PByte(B), Length(B));
  Result := St.Log;
end;

function ReadSplit(const S: RawByteString; MaxMessage: Int64; Seed: LongWord): RawByteString;
var
  St: TLogState;
  B: RawByteString;
  Pos, N, Max: SizeInt;
begin
  St := Default(TLogState);
  St.R.Init(MaxMessage);
  B := S;
  UniqueString(B);
  RandSeed := Seed;
  Pos := 0;
  while Pos < Length(B) do
  begin
    case Random(4) of
      0: Max := 1;
      1: Max := 8;
      2: Max := 200;
    else
      Max := 20000;
    end;
    N := 1 + Random(Max);
    if N > Length(B) - Pos then
      N := Length(B) - Pos;
    Feed(St, PByte(B) + Pos, N);
    Inc(Pos, N);
  end;
  Result := St.Log;
end;

function TakeServerFrame(var S: RawByteString; out F: TServerFrame): Boolean;
var
  L: QWord;
  H, I: Integer;
  K: array[0..3] of Byte;
begin
  Result := False;
  F := Default(TServerFrame);
  if Length(S) < 2 then
    Exit;
  F.Fin := (Byte(S[1]) and $80) <> 0;
  F.Rsv := (Byte(S[1]) shr 4) and 7;
  F.Opcode := Byte(S[1]) and $0F;
  F.Masked := (Byte(S[2]) and $80) <> 0;
  L := Byte(S[2]) and $7F;
  H := 2;
  if L = 126 then
  begin
    if Length(S) < 4 then Exit;
    L := (QWord(Byte(S[3])) shl 8) or Byte(S[4]);
    H := 4;
  end
  else if L = 127 then
  begin
    if Length(S) < 10 then Exit;
    L := 0;
    for I := 3 to 10 do
      L := (L shl 8) or Byte(S[I]);
    H := 10;
  end;
  if F.Masked then
  begin
    if Length(S) < H + 4 then Exit;
    for I := 0 to 3 do
      K[I] := Byte(S[H + 1 + I]);
    Inc(H, 4);
  end;
  if QWord(Length(S) - H) < L then
    Exit;
  F.Payload := Copy(S, H + 1, L);
  if F.Masked then
    for I := 1 to Length(F.Payload) do
      F.Payload[I] := AnsiChar(Byte(F.Payload[I]) xor K[(I - 1) and 3]);
  Delete(S, 1, H + L);
  Result := True;
end;

function ServerFramesLog(var S: RawByteString): RawByteString;
var
  F: TServerFrame;
begin
  Result := '';
  while TakeServerFrame(S, F) do
  begin
    Result := Result + IntToStr(F.Opcode) + ':';
    if (F.Opcode in [WS_OP_TEXT, WS_OP_BINARY]) and (Length(F.Payload) > 40) then
      Result := Result + IntToStr(Length(F.Payload)) + '#' + Digest(F.Payload)
    else
      Result := Result + F.Payload;
    if F.Masked or (F.Rsv <> 0) or not F.Fin then
      Result := Result + '!bad-header';
    Result := Result + '|';
  end;
end;

end.

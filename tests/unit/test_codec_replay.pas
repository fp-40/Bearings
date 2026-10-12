{ Replays a body through bearings.http1.decode the way test_codec_diff_rs drives
  hyper's decode.rs, and formats the outcome the same way, so results can be
  compared with hyper's as strings.

  The transport delivers one split per read, has nothing between splits
  (the decoder must answer dsNeedMore and consume everything), and hits EOF
  after the last split. The caller keeps the bytes the decoder did not
  consume.

  Result: STATUS|DATALEN|DATAFNV|LEFTOVER|THEN|ISEOF
    STATUS   END | TRL:<lowercase-name=hexvalue,...> (http HeaderMap order:
             names in first-insertion order, each with all its values)
             | ERR:<io::ErrorKind>:<message>
    DATALEN, DATAFNV  length and FNV-1a 64 hash of all body data
    LEFTOVER bytes the decoder did not consume ('-' after an error)
    THEN     result of one more Decode call ('-' after an error)
    ISEOF    IsEof after STATUS ('-' after an error)
  A string starting with 'BUG:' reports a broken Decode contract.

  Guard mode (SetGuardMode): every Decode call gets its input copied so that
  it ends exactly at a PROT_NONE page (gmEnd) or starts right after one
  (gmStart); a read outside Input[0..InputLen-1] then crashes. }
unit test_codec_replay;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, BaseUnix, bearings.http.headers, bearings.http1.decode;

type
  TGuardMode = (gmNone, gmEnd, gmStart);

procedure SetGuardMode(M: TGuardMode);

function HexToBytes(const S: string): RawByteString;
function BytesToHex(P: PByte; Len: SizeInt): string;
function Fnv1aHex(const S: RawByteString): string;
function KindName(K: TIoErrorKind): string;
function SerTrailers(H: THttpHeaders): string;

function ReplayDecode(Kind: Char; N: QWord; MaxH, MaxHS: SizeInt;
  const Body: RawByteString; const Splits: array of SizeInt): string;
{ One decode_cases.txt line: K N MAXH MAXHS BODYHEX SPLITS }
function ReplayDecodeLine(const Line: string): string;
{ One headers_cases.txt line: FUNC HEX1 HEX2 ... }
function ReplayHeadersLine(const Line: string): string;

implementation

const
  PAGE = 4096;
  REGION_PAGES = 66;   { guard + 64 data pages (256 KiB) + guard }

var
  GuardMode: TGuardMode = gmNone;
  Region: PByte = nil;

procedure SetGuardMode(M: TGuardMode);
begin
  GuardMode := M;
  if (M <> gmNone) and (Region = nil) then
  begin
    Region := Fpmmap(nil, REGION_PAGES * PAGE, PROT_READ or PROT_WRITE,
      MAP_PRIVATE or MAP_ANONYMOUS, -1, 0);
    if (Pointer(Region) = MAP_FAILED) or
       (Fpmprotect(Region, PAGE, PROT_NONE) <> 0) or
       (Fpmprotect(Region + (REGION_PAGES - 1) * PAGE, PAGE, PROT_NONE) <> 0) then
      raise Exception.Create('guard region: mmap/mprotect failed');
  end;
end;

{ The pointer Decode gets for Buf: Buf itself, or a copy placed against a
  guard page. }
function InputFor(const Buf: RawByteString): PByte;
var
  L: SizeInt;
begin
  L := System.Length(Buf);
  case GuardMode of
    gmEnd:
      begin
        if L > (REGION_PAGES - 2) * PAGE then
          raise Exception.Create('input too large for the guard region');
        Result := Region + (REGION_PAGES - 1) * PAGE - L;
      end;
    gmStart:
      begin
        if L > (REGION_PAGES - 2) * PAGE then
          raise Exception.Create('input too large for the guard region');
        Result := Region + PAGE;
      end;
  else
    Exit(PByte(Pointer(Buf)));
  end;
  if L > 0 then
    Move(Buf[1], Result^, L);
end;

function HexVal(C: AnsiChar): Integer;
begin
  case C of
    '0'..'9': Result := Ord(C) - Ord('0');
    'a'..'f': Result := Ord(C) - Ord('a') + 10;
    'A'..'F': Result := Ord(C) - Ord('A') + 10;
  else
    raise Exception.Create('bad hex digit');
  end;
end;

function HexToBytes(const S: string): RawByteString;
var
  I: SizeInt;
begin
  Result := '';
  if S = '-' then
    Exit;
  SetLength(Result, Length(S) div 2);
  for I := 1 to Length(S) div 2 do
    Result[I] := AnsiChar(HexVal(S[2 * I - 1]) * 16 + HexVal(S[2 * I]));
end;

function BytesToHex(P: PByte; Len: SizeInt): string;
const
  HD: array[0..15] of AnsiChar = '0123456789abcdef';
var
  I: SizeInt;
begin
  if Len = 0 then
    Exit('-');
  SetLength(Result, Len * 2);
  for I := 0 to Len - 1 do
  begin
    Result[2 * I + 1] := HD[P[I] shr 4];
    Result[2 * I + 2] := HD[P[I] and 15];
  end;
end;

{$push}{$Q-}{$R-}
function Fnv1a(const S: RawByteString): QWord;
var
  I: SizeInt;
begin
  Result := QWord($cbf29ce484222325);
  for I := 1 to Length(S) do
  begin
    Result := Result xor Byte(S[I]);
    Result := Result * QWord($00000100000001b3);
  end;
end;
{$pop}

function Fnv1aHex(const S: RawByteString): string;
begin
  Result := LowerCase(IntToHex(Int64(Fnv1a(S)), 16));
end;

function KindName(K: TIoErrorKind): string;
begin
  case K of
    iekUnexpectedEof: Result := 'UnexpectedEof';
    iekInvalidInput: Result := 'InvalidInput';
    iekInvalidData: Result := 'InvalidData';
  else
    Result := 'None';
  end;
end;

function LowerName(H: THttpHeaders; I: SizeInt): string;
var
  J: SizeInt;
  P: PByte;
begin
  SetLength(Result, H.NameLen(I));
  P := H.NamePtr(I);
  for J := 0 to H.NameLen(I) - 1 do
    Result[J + 1] := AnsiChar(AsciiLower(P[J]));
end;

function SerTrailers(H: THttpHeaders): string;
var
  Seen: TStringList;
  I, J: SizeInt;
  N: string;
  First: Boolean;
begin
  Result := 'TRL:';
  First := True;
  Seen := TStringList.Create;
  try
    Seen.Sorted := True;
    for I := 0 to H.Count - 1 do
    begin
      N := LowerName(H, I);
      if Seen.IndexOf(N) >= 0 then
        Continue;
      Seen.Add(N);
      for J := I to H.Count - 1 do
        if LowerName(H, J) = N then
        begin
          if not First then
            Result := Result + ',';
          First := False;
          Result := Result + N + '=' + BytesToHex(H.ValuePtr(J), H.ValueLen(J));
        end;
    end;
  finally
    Seen.Free;
  end;
end;

function ReplayDecode(Kind: Char; N: QWord; MaxH, MaxHS: SizeInt;
  const Body: RawByteString; const Splits: array of SizeInt): string;
var
  Buf, Data, Status: RawByteString;
  Segs: array of RawByteString;
  NextSeg, I, P: SizeInt;
  D: TDecoder;
  R: TDecodeResult;
  St: TDecodeStatus;
  T: THttpHeaders;
  AtEof: Boolean;
  Left: SizeInt;
  ThenS, IsEofS, LeftS: string;
  Guard: Int64;
begin
  T := THttpHeaders.Create;
  try
    SetLength(Segs, System.Length(Splits));
    P := 1;
    for I := 0 to High(Splits) do
    begin
      Segs[I] := Copy(Body, P, Splits[I]);
      Inc(P, Splits[I]);
    end;
    if P - 1 <> System.Length(Body) then
      Exit('BUG:splits do not cover the body');

    case Kind of
      'L': D.InitLength(N);
      'C': D.InitChunked(MaxH, MaxHS);
    else
      D.InitEof;
    end;

    Buf := '';
    Data := '';
    NextSeg := 0;
    Guard := 0;
    while True do
    begin
      Inc(Guard);
      if Guard > 50000000 then
        Exit('BUG:no progress');
      AtEof := NextSeg >= System.Length(Segs);
      St := D.Decode(InputFor(Buf), System.Length(Buf), AtEof, T, R);
      if R.Status <> St then
        Exit('BUG:R.Status differs from the result');
      case St of
        dsNeedMore:
          begin
            if R.Consumed <> System.Length(Buf) then
              Exit(Format('BUG:NeedMore consumed %d of %d', [R.Consumed, System.Length(Buf)]));
            if AtEof then
              Exit('BUG:NeedMore at EOF');
            Buf := Segs[NextSeg];
            Inc(NextSeg);
          end;
        dsData:
          begin
            if (R.DataLen <= 0) or (R.DataOfs < 0) or (R.DataOfs + R.DataLen > R.Consumed) or
               (R.Consumed > System.Length(Buf)) then
              Exit(Format('BUG:bad data slice ofs %d len %d consumed %d buf %d',
                [R.DataOfs, R.DataLen, R.Consumed, System.Length(Buf)]));
            Data := Data + Copy(Buf, R.DataOfs + 1, R.DataLen);
            Delete(Buf, 1, R.Consumed);
          end;
        dsTrailers:
          begin
            Status := SerTrailers(T);
            Delete(Buf, 1, R.Consumed);
            Break;
          end;
        dsEnd:
          begin
            Status := 'END';
            Delete(Buf, 1, R.Consumed);
            Break;
          end;
        dsError:
          begin
            Status := 'ERR:' + KindName(DecodeErrorKind(R.Error)) + ':' + DecodeErrorMessage(R.Error);
            Break;
          end;
      end;
    end;

    if Copy(Status, 1, 3) = 'ERR' then
    begin
      LeftS := '-';
      ThenS := '-';
      IsEofS := '-';
    end
    else
    begin
      Left := System.Length(Buf);
      for I := NextSeg to High(Segs) do
        Inc(Left, System.Length(Segs[I]));
      LeftS := IntToStr(Left);
      if D.IsEof then IsEofS := '1' else IsEofS := '0';
      while True do
      begin
        AtEof := NextSeg >= System.Length(Segs);
        St := D.Decode(InputFor(Buf), System.Length(Buf), AtEof, T, R);
        case St of
          dsNeedMore:
            begin
              if AtEof then
                Exit('BUG:NeedMore at EOF (then)');
              Buf := Segs[NextSeg];
              Inc(NextSeg);
            end;
          dsEnd: begin ThenS := 'END'; Break; end;
          dsData, dsTrailers: begin ThenS := 'FRAME'; Break; end;
          dsError: begin ThenS := 'ERR:' + KindName(DecodeErrorKind(R.Error)); Break; end;
        end;
      end;
    end;

    Result := Format('%s|%d|%s|%s|%s|%s',
      [Status, System.Length(Data), Fnv1aHex(Data), LeftS, ThenS, IsEofS]);
  finally
    T.Free;
  end;
end;

procedure SplitWords(const S: string; L: TStringList; Delim: Char);
begin
  L.Clear;
  L.Delimiter := Delim;
  L.StrictDelimiter := True;
  L.DelimitedText := S;
end;

function ReplayDecodeLine(const Line: string): string;
var
  W, SP: TStringList;
  Splits: array of SizeInt;
  I: SizeInt;
begin
  W := TStringList.Create;
  SP := TStringList.Create;
  try
    SplitWords(Line, W, ' ');
    SetLength(Splits, 0);
    if W[5] <> '-' then
    begin
      SplitWords(W[5], SP, ',');
      SetLength(Splits, SP.Count);
      for I := 0 to SP.Count - 1 do
        Splits[I] := StrToInt(SP[I]);
    end;
    Result := ReplayDecode(W[0][1], StrToQWord(W[1]), StrToInt64(W[2]), StrToInt64(W[3]),
      HexToBytes(W[4]), Splits);
  finally
    SP.Free;
    W.Free;
  end;
end;

function B2S(B: Boolean): string;
begin
  if B then Result := '1' else Result := '0';
end;

function ReplayHeadersLine(const Line: string): string;
var
  W: TStringList;
  F, V: RawByteString;
  H: THttpHeaders;
  I: SizeInt;
  Name: RawByteString;
  N: QWord;
begin
  W := TStringList.Create;
  H := THttpHeaders.Create;
  try
    SplitWords(Line, W, ' ');
    F := W[0];
    if (F = 'cla') or (F = 'cl') then Name := 'Content-Length'
    else if F = 'te' then Name := 'TE'
    else if (F = 'cac') or (F = 'cc') or (F = 'ka') then Name := 'Connection'
    else Name := 'Transfer-Encoding';
    for I := 1 to W.Count - 1 do
      H.Add(Name, HexToBytes(W[I]));
    if W.Count > 1 then
      V := HexToBytes(W[1])
    else
      V := '';

    if F = 'cc' then Result := B2S(ConnectionClose(PByte(Pointer(V)), System.Length(V)))
    else if F = 'ka' then Result := B2S(ConnectionKeepAlive(PByte(Pointer(V)), System.Length(V)))
    else if F = 'ic' then Result := B2S(IsChunkedValue(PByte(Pointer(V)), System.Length(V)))
    else if F = 'cl' then
    begin
      if ContentLengthParse(PByte(Pointer(V)), System.Length(V), N) then
        Result := 'N:' + IntToStr(N)
      else
        Result := 'NONE';
    end
    else if F = 'cla' then
    begin
      if ContentLengthParseAll(H, N) then
        Result := 'N:' + IntToStr(N)
      else
        Result := 'NONE';
    end
    else if F = 'te' then Result := B2S(TeIsTrailers(H))
    else if F = 'cac' then Result := B2S(ConnectionAnyClose(H))
    else if F = 'tec' then Result := B2S(TransferEncodingIsChunked(H))
    else
      Result := 'BUG:unknown function ' + F;
  finally
    H.Free;
    W.Free;
  end;
end;

end.

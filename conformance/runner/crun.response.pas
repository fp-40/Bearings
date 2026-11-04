{ crun.response - the reader of the read_response step: a minimal,
  permissive HTTP/1.x response reader that frames one response by the rules
  of RFC 9112 section 6.3 (no body for HEAD, 1xx, 204 and 304; chunked when
  the last transfer coding is chunked, else read until close; else
  Content-Length; else read until close), so that the following steps see
  the bytes after it.

  It is the runner's own code, independent of the server under test: it
  uses none of the Bearings units.

  Test tooling only. }
unit crun.response;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, crun.bytes, crun.conn;

type
  TField = record
    Name, Value: RawByteString;
  end;
  TFields = array of TField;

  TParsed = record
    Version: RawByteString;
    Status: Integer;
    Reason: RawByteString;
    Headers: TFields;
    Body: RawByteString;
    Trailers: TFields;
    Framing: RawByteString;          { none | content-length | chunked | close }
    Raw: RawByteString;
  end;

function FieldValues(const F: TFields; const Name: RawByteString): TFields;
function FieldsShow(const F: TFields): RawByteString;
{ reads one response from C; raises ECase }
procedure ReadResponse(C: TConn; IsHead: Boolean; TimeoutMs: Int64; AllowReset: Boolean;
  out P: TParsed; out End_: TEnd; out DoneAt: Int64);

implementation

function FieldValues(const F: TFields; const Name: RawByteString): TFields;
var
  K: Integer;
begin
  Result := nil;
  for K := 0 to High(F) do
    if LowerAscii(F[K].Name) = LowerAscii(Name) then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := F[K];
    end;
end;

function FieldsShow(const F: TFields): RawByteString;
var
  K: Integer;
begin
  Result := '';
  for K := 0 to High(F) do
  begin
    if K > 0 then
      Result := Result + ' | ';
    Result := Result + F[K].Name + ': ' + Latin1(F[K].Value);
  end;
end;

function TrimOws(const V: RawByteString): RawByteString;
var
  A, B: SizeInt;
begin
  A := 1;
  B := Length(V);
  while (A <= B) and (V[A] in [' ', #9]) do
    Inc(A);
  while (B >= A) and (V[B] in [' ', #9]) do
    Dec(B);
  Result := Copy(V, A, B - A + 1);
end;

function ParseFields(const Block: RawByteString): TFields;
var
  Start, Nl, Colon: SizeInt;
  Line: RawByteString;
begin
  Result := nil;
  Start := 1;
  while Start <= Length(Block) + 1 do
  begin
    Nl := Start;
    while (Nl <= Length(Block)) and (Block[Nl] <> #10) do
      Inc(Nl);
    Line := Copy(Block, Start, Nl - Start);
    Start := Nl + 1;
    if (Line <> '') and (Line[Length(Line)] = #13) then
      SetLength(Line, Length(Line) - 1);
    if Line = '' then
      Continue;
    Colon := Pos(':', Line);
    if Colon = 0 then
      raise ECase.CreateFmt('malformed field line %s', [Show(Line, 200)]);
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)].Name := Copy(Line, 1, Colon - 1);
    Result[High(Result)].Value := TrimOws(Copy(Line, Colon + 1, MaxInt));
  end;
end;

{ Result False: more bytes are needed (only when not Eof) }
function Incomplete(Eof: Boolean; const What: string): Boolean;
begin
  if Eof then
    raise ECase.CreateFmt('connection ended in the middle of the %s', [What]);
  Result := False;
end;

function AllDigits(const S: RawByteString): Boolean;
var
  K: SizeInt;
begin
  for K := 1 to Length(S) do
    if not (S[K] in ['0'..'9']) then
      Exit(False);
  Result := True;
end;

{ True: P is one response, Used bytes of Buf; False: need more bytes }
function TryParse(const Buf: RawByteString; IsHead, Eof: Boolean; out P: TParsed; out Used: SizeInt): Boolean;
var
  HeadEnd, LineEnd, Sp1, Sp2, PosB, TPos, Le, K: SizeInt;
  Head, StatusLine, Rest, Code, Joined, Last, Line, SizeStr: RawByteString;
  Te, Cl: TFields;
  Size: QWord;
  Ch: AnsiChar;
  D: Integer;
begin
  Used := 0;
  P := Default(TParsed);
  HeadEnd := FindBytes(Buf, #13#10#13#10);
  if HeadEnd < 0 then
  begin
    if Eof then
      raise ECase.Create('connection ended before a complete response head');
    Exit(False);
  end;
  Head := Copy(Buf, 1, HeadEnd);
  LineEnd := FindBytes(Head, #13#10);
  if LineEnd >= 0 then
  begin
    StatusLine := Copy(Head, 1, LineEnd);
    Rest := Copy(Head, LineEnd + 3, MaxInt);
  end
  else
  begin
    StatusLine := Head;
    Rest := '';
  end;
  { version SP code SP reason (the reason may hold spaces) }
  Sp1 := Pos(' ', StatusLine);
  if Sp1 = 0 then
  begin
    P.Version := StatusLine;
    Code := '';
  end
  else
  begin
    P.Version := Copy(StatusLine, 1, Sp1 - 1);
    Sp2 := Pos(' ', Copy(StatusLine, Sp1 + 1, MaxInt));
    if Sp2 = 0 then
      Code := Copy(StatusLine, Sp1 + 1, MaxInt)
    else
    begin
      Code := Copy(StatusLine, Sp1 + 1, Sp2 - 1);
      P.Reason := Copy(StatusLine, Sp1 + Sp2 + 1, MaxInt);
    end;
  end;
  if not StartsWith(P.Version, 'HTTP/') or (Length(Code) <> 3) or not AllDigits(Code) then
    raise ECase.CreateFmt('malformed status line %s', [Show(StatusLine, 200)]);
  P.Status := StrToInt(Code);
  P.Headers := ParseFields(Rest);
  PosB := HeadEnd + 4;               { 0-based offset of the body }
  P.Framing := 'none';
  Te := FieldValues(P.Headers, 'transfer-encoding');
  Cl := FieldValues(P.Headers, 'content-length');
  if IsHead or ((P.Status >= 100) and (P.Status < 200)) or (P.Status = 204) or (P.Status = 304) then
    P.Framing := 'none'
  else if Length(Te) > 0 then
  begin
    Joined := '';
    for K := 0 to High(Te) do
    begin
      if K > 0 then
        Joined := Joined + ',';
      Joined := Joined + Te[K].Value;
    end;
    K := Length(Joined);
    while (K >= 1) and (Joined[K] <> ',') do
      Dec(K);
    Last := TrimOws(Copy(Joined, K + 1, MaxInt));
    if LowerAscii(Last) = 'chunked' then
    begin
      P.Framing := 'chunked';
      while True do
      begin
        LineEnd := FindBytes(Buf, #13#10, PosB);
        if LineEnd < 0 then
          Exit(Incomplete(Eof, 'chunk size line'));
        Line := Copy(Buf, PosB + 1, LineEnd - PosB);
        K := Pos(';', Line);
        if K > 0 then
          SizeStr := TrimOws(Copy(Line, 1, K - 1))
        else
          SizeStr := TrimOws(Line);
        { u64::from_str_radix(.., 16): hex digits, an optional leading + }
        Size := 0;
        if (SizeStr <> '') and (SizeStr[1] = '+') then
          Delete(SizeStr, 1, 1);
        if SizeStr = '' then
          raise ECase.CreateFmt('invalid chunk size line %s', [Show(Line, 200)]);
        for K := 1 to Length(SizeStr) do
        begin
          Ch := SizeStr[K];
          case Ch of
            '0'..'9': D := Ord(Ch) - Ord('0');
            'a'..'f': D := Ord(Ch) - Ord('a') + 10;
            'A'..'F': D := Ord(Ch) - Ord('A') + 10;
          else
            raise ECase.CreateFmt('invalid chunk size line %s', [Show(Line, 200)]);
          end;
          if Size > (High(QWord) - QWord(D)) div 16 then
            raise ECase.CreateFmt('invalid chunk size line %s', [Show(Line, 200)]);
          Size := Size * 16 + QWord(D);
        end;
        PosB := LineEnd + 2;
        if Size = 0 then
        begin
          { the trailer section, up to an empty line }
          TPos := PosB;
          while True do
          begin
            Le := FindBytes(Buf, #13#10, TPos);
            if Le < 0 then
              Exit(Incomplete(Eof, 'trailer section'));
            if Le = TPos then
            begin
              P.Trailers := ParseFields(Copy(Buf, PosB + 1, TPos - PosB));
              PosB := Le + 2;
              Break;
            end;
            TPos := Le + 2;
          end;
          Break;
        end;
        if QWord(Length(Buf)) < QWord(PosB) + Size + 2 then
          Exit(Incomplete(Eof, 'chunk data'));
        P.Body := P.Body + Copy(Buf, PosB + 1, Size);
        if Copy(Buf, PosB + Size + 1, 2) <> #13#10 then
          raise ECase.Create('chunk data not followed by CRLF');
        PosB := PosB + SizeInt(Size) + 2;
      end;
    end
    else
      P.Framing := 'close';
  end
  else if Length(Cl) > 0 then
  begin
    for K := 0 to High(Cl) do
      if (Cl[K].Value <> Cl[0].Value) or (Cl[K].Value = '') or not AllDigits(Cl[K].Value) then
        raise ECase.CreateFmt('invalid content-length %s', [FieldsShow(Cl)]);
    if Length(Cl[0].Value) > 18 then
      raise ECase.Create('content-length overflow');
    Size := StrToQWord(Cl[0].Value);
    P.Framing := 'content-length';
    if QWord(Length(Buf)) < QWord(PosB) + Size then
      Exit(Incomplete(Eof, 'content-length body'));
    P.Body := Copy(Buf, PosB + 1, Size);
    PosB := PosB + SizeInt(Size);
  end
  else
    P.Framing := 'close';

  if P.Framing = 'close' then
  begin
    if not Eof then
      Exit(False);
    P.Body := P.Body + Copy(Buf, PosB + 1, MaxInt);
    PosB := Length(Buf);
  end;
  P.Raw := Copy(Buf, 1, PosB);
  Used := PosB;
  Result := True;
end;

procedure ReadResponse(C: TConn; IsHead: Boolean; TimeoutMs: Int64; AllowReset: Boolean;
  out P: TParsed; out End_: TEnd; out DoneAt: Int64);
var
  Used: SizeInt;
begin
  while True do
  begin
    if (C.End_ = endReset) and not AllowReset then
      raise ECase.Create('connection reset by peer (set allow_reset to accept)');
    if TryParse(C.Buf, IsHead, C.End_ <> endOpen, P, Used) then
    begin
      Delete(C.Buf, 1, Used);
      End_ := C.End_;
      DoneAt := NowUs;
      Exit;
    end;
    if C.ReadSome(TimeoutMs) = roTimeout then
      raise ECase.CreateFmt('timed out after %d ms waiting for response bytes (%d buffered)',
        [TimeoutMs, Length(C.Buf)]);
  end;
end;

end.

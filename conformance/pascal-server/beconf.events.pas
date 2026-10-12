{ beconf.events - SPEC 7 event lines on stdout (design m3-transport.md 6.1,
  6.7). Test tooling, cold path: strings are allowed.

  A line is built completely, then written with one write(1, ...) loop under
  a lock (SPEC 3.3: a line is atomic; the lock matters only when several
  threads emit, e.g. the stdin fallback reader or --loops N later). Byte
  strings use the latin-1 mapping of SPEC 2: each byte is the code point of
  the same value, written as UTF-8 (bytes 0x80..0xFF become two bytes),
  control characters as JSON escapes. }
unit beconf.events;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, bearings.http.headers;

{ Writes Line + LF to fd 1 (one write loop, under the lock); with EventHook
  set, hands Line to it instead (the in-process split fuzz, step S9). }
procedure EmitLine(const Line: RawByteString);

var
  EventHook: procedure(const Line: RawByteString) = nil;

{ Holds the event lock (recursive): the worker executor makes a terminal call and emits
  handler_done under it, so no event of the loop thread can come between the two (S7). }
procedure LockEvents;
procedure UnlockEvents;
{ JSON string literal of a byte string (SPEC 2, latin-1). }
function JBytes(const B: RawByteString): RawByteString;
function JBytesP(P: PByte; Len: SizeInt): RawByteString;
{ JSON string literal of text that is already UTF-8 (messages, names). }
function JText(const S: RawByteString): RawByteString;
{ SPEC 7 header list: names lowercased, values as stored, grouped by the
  first appearance of each name (http::HeaderMap iteration order). }
function JHeaders(H: THttpHeaders): RawByteString;
function JUInt(N: QWord): RawByteString;

implementation

uses
  BaseUnix;

var
  Lock: TRTLCriticalSection;

procedure EmitLine(const Line: RawByteString);
var
  S: RawByteString;
  P: PAnsiChar;
  Left: SizeInt;
  R: TSsize;
begin
  if Assigned(EventHook) then
  begin
    EventHook(Line);
    Exit;
  end;
  S := Line + #10;
  EnterCriticalSection(Lock);
  try
    P := PAnsiChar(S);
    Left := Length(S);
    while Left > 0 do
    begin
      R := FpWrite(1, P, Left);
      if R < 0 then
      begin
        if fpgeterrno = ESysEINTR then
          Continue;
        Break;                         { the runner is gone }
      end;
      Inc(P, R);
      Dec(Left, R);
    end;
  finally
    LeaveCriticalSection(Lock);
  end;
end;

procedure LockEvents;
begin
  EnterCriticalSection(Lock);
end;

procedure UnlockEvents;
begin
  LeaveCriticalSection(Lock);
end;

const
  HexD: array[0..15] of AnsiChar = '0123456789abcdef';

procedure AppendEscaped(var R: RawByteString; B: Byte; Latin1: Boolean);
begin
  case B of
    Ord('"'): R := R + '\"';
    Ord('\'): R := R + '\\';
    8: R := R + '\b';
    9: R := R + '\t';
    10: R := R + '\n';
    12: R := R + '\f';
    13: R := R + '\r';
    0..7, 11, 14..31:
      R := R + '\u00' + HexD[B shr 4] + HexD[B and 15];
    128..255:
      if Latin1 then
        R := R + AnsiChar($C0 or (B shr 6)) + AnsiChar($80 or (B and $3F))
      else
        R := R + AnsiChar(B);
  else
    R := R + AnsiChar(B);
  end;
end;

function JBytesP(P: PByte; Len: SizeInt): RawByteString;
var
  I: SizeInt;
begin
  Result := '"';
  for I := 0 to Len - 1 do
    AppendEscaped(Result, P[I], True);
  Result := Result + '"';
end;

function JBytes(const B: RawByteString): RawByteString;
begin
  Result := JBytesP(PByte(Pointer(B)), Length(B));
end;

function JText(const S: RawByteString): RawByteString;
var
  I: SizeInt;
begin
  Result := '"';
  for I := 1 to Length(S) do
    AppendEscaped(Result, Byte(S[I]), False);
  Result := Result + '"';
end;

function JUInt(N: QWord): RawByteString;
begin
  Result := IntToStr(N);
end;

function LowerName(P: PByte; Len: SizeInt): RawByteString;
var
  I: SizeInt;
begin
  SetLength(Result, Len);
  for I := 0 to Len - 1 do
    Result[I + 1] := AnsiChar(AsciiLower(P[I]));
end;

function JHeaders(H: THttpHeaders): RawByteString;
var
  Done: array of Boolean;
  I, J: SizeInt;
  First: Boolean;
  Name: RawByteString;
begin
  Result := '[';
  First := True;
  if H <> nil then
  begin
    SetLength(Done, H.Count);
    for I := 0 to H.Count - 1 do
    begin
      if Done[I] then
        Continue;
      Name := LowerName(H.NamePtr(I), H.NameLen(I));
      for J := I to H.Count - 1 do
        if (not Done[J]) and AsciiEqualIgnoreCase(H.NamePtr(J), H.NameLen(J),
          PByte(Pointer(Name)), Length(Name)) then
        begin
          Done[J] := True;
          if not First then
            Result := Result + ',';
          First := False;
          Result := Result + '[' + JBytes(Name) + ',' + JBytesP(H.ValuePtr(J), H.ValueLen(J)) + ']';
        end;
    end;
  end;
  Result := Result + ']';
end;

initialization
  InitCriticalSection(Lock);
finalization
  DoneCriticalSection(Lock);
end.

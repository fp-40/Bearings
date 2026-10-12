{ ws_bench - WebSocket echo benchmark client (for examples/ws_echo.pas).

  Opens Conns connections, one thread each (blocking sockets). Each
  connection sends binary messages of Size bytes, keeping Window of them in
  flight: it sends Window messages, then sends one more for every echo it
  receives. After Secs seconds it stops counting. Prints the echoed
  messages per second and the payload throughput in each direction.

  The client builds one masked frame per connection and sends it again and
  again, and counts the echoes by parsing frame headers only, so its own
  cost per message is small.

  Usage: ws_bench port conns size window secs
  Example: ws_bench 9101 16 64 16 5 }
program ws_bench;

{$mode objfpc}{$H+}

uses
  cthreads, Classes, SysUtils, BaseUnix, Sockets, ctypes;

type
  TConn = class(TThread)
  public
    Port: Word;
    Size, Window: Integer;
    StopAt: QWord;
    Count: Int64;
    Error: string;
    procedure Execute; override;
  end;

const
  CRLF = #13#10;

function NowMs: QWord;
begin
  Result := GetTickCount64;
end;

function MakeFrame(Size: Integer): RawByteString;
var
  H: RawByteString;
  I: Integer;
  K: array[0..3] of Byte = ($12, $34, $56, $78);
begin
  if Size < 126 then
    H := #$82 + AnsiChar($80 or Size)
  else if Size <= $FFFF then
    H := #$82 + AnsiChar($80 or 126) + AnsiChar(Size shr 8) + AnsiChar(Size and $FF)
  else
  begin
    H := #$82 + AnsiChar($80 or 127);
    for I := 7 downto 0 do
      H := H + AnsiChar((QWord(Size) shr (8 * I)) and $FF);
  end;
  H := H + AnsiChar(K[0]) + AnsiChar(K[1]) + AnsiChar(K[2]) + AnsiChar(K[3]);
  SetLength(Result, Size);
  for I := 1 to Size do
    Result[I] := AnsiChar((I and $FF) xor K[(I - 1) and 3]);
  Result := H + Result;
end;

procedure SendAll(Fd: cint; P: PAnsiChar; Len: SizeInt);
var
  R: SizeInt;
begin
  while Len > 0 do
  begin
    R := fpSend(Fd, P, Len, MSG_NOSIGNAL);
    if R <= 0 then
      raise Exception.Create('send failed');
    Inc(P, R);
    Dec(Len, R);
  end;
end;

procedure TConn.Execute;
var
  Fd: cint;
  A: TInetSockAddr;
  Frame, Req: RawByteString;
  Buf: array of Byte;
  Have, Pos0, I: SizeInt;
  Remaining: Int64;                  { payload bytes of the current echo still to skip }
  L: QWord;
  HL: Integer;
  InFlight: Integer;
  R: SizeInt;
  Head: RawByteString;
  One: Integer;
begin
  Fd := -1;
  try
    Fd := fpSocket(AF_INET, SOCK_STREAM, 0);
    A.sin_family := AF_INET;
    A.sin_port := htons(Port);
    A.sin_addr.s_addr := htonl($7F000001);
    if fpConnect(Fd, @A, SizeOf(A)) <> 0 then
      raise Exception.Create('connect failed');
    One := 1;
    fpSetSockOpt(Fd, IPPROTO_TCP, 1 { TCP_NODELAY }, @One, SizeOf(One));
    Req := 'GET / HTTP/1.1' + CRLF + 'Host: x' + CRLF + 'Upgrade: websocket' + CRLF
      + 'Connection: Upgrade' + CRLF + 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' + CRLF
      + 'Sec-WebSocket-Version: 13' + CRLF + CRLF;
    SendAll(Fd, PAnsiChar(Req), Length(Req));
    SetLength(Buf, 256 * 1024);
    Have := 0;
    { the 101 head }
    Head := '';
    while System.Pos(CRLF + CRLF, Head) = 0 do
    begin
      R := fpRecv(Fd, @Buf[0], 1, 0);
      if R <= 0 then
        raise Exception.Create('no 101');
      Head := Head + AnsiChar(Buf[0]);
    end;
    if Copy(Head, 1, 12) <> 'HTTP/1.1 101' then
      raise Exception.Create('not 101: ' + Head);
    Frame := MakeFrame(Size);
    for I := 1 to Window do
      SendAll(Fd, PAnsiChar(Frame), Length(Frame));
    InFlight := Window;
    Remaining := 0;
    while True do
    begin
      R := fpRecv(Fd, @Buf[Have], Length(Buf) - Have, 0);
      if R <= 0 then
        raise Exception.Create('recv failed');
      Inc(Have, R);
      Pos0 := 0;
      while True do
      begin
        if Remaining > 0 then
        begin
          if Have - Pos0 >= Remaining then
          begin
            Inc(Pos0, Remaining);
            Remaining := 0;
            { one echo complete }
            Inc(Count);
            Dec(InFlight);
            if NowMs < StopAt then
            begin
              SendAll(Fd, PAnsiChar(Frame), Length(Frame));
              Inc(InFlight);
            end
            else if InFlight = 0 then
              Exit;
          end
          else
          begin
            Dec(Remaining, Have - Pos0);
            Pos0 := Have;
            Break;
          end;
        end
        else
        begin
          { a frame header }
          if Have - Pos0 < 2 then Break;
          L := Buf[Pos0 + 1] and $7F;
          HL := 2;
          if L = 126 then
          begin
            if Have - Pos0 < 4 then Break;
            L := (QWord(Buf[Pos0 + 2]) shl 8) or Buf[Pos0 + 3];
            HL := 4;
          end
          else if L = 127 then
          begin
            if Have - Pos0 < 10 then Break;
            L := 0;
            for I := 2 to 9 do
              L := (L shl 8) or Buf[Pos0 + I];
            HL := 10;
          end;
          if (Buf[Pos0] and $0F) <> 2 then
            raise Exception.Create('unexpected opcode ' + IntToStr(Buf[Pos0] and $0F));
          Inc(Pos0, HL);
          Remaining := L;
          if Remaining = 0 then
            Remaining := -1;           { an empty echo: completed below }
          if Remaining = -1 then
          begin
            Remaining := 0;
            Inc(Count);
            Dec(InFlight);
            if NowMs < StopAt then
            begin
              SendAll(Fd, PAnsiChar(Frame), Length(Frame));
              Inc(InFlight);
            end
            else if InFlight = 0 then
              Exit;
          end;
        end;
      end;
      { keep the unparsed tail at the front }
      if Pos0 > 0 then
      begin
        if Have > Pos0 then
          Move(Buf[Pos0], Buf[0], Have - Pos0);
        Dec(Have, Pos0);
      end;
    end;
  except
    on E: Exception do
      Error := E.Message;
  end;
  if Fd >= 0 then
    fpClose(Fd);
end;

var
  Port: Word;
  Conns, Size, Window, Secs, I: Integer;
  C: array of TConn;
  T0, T1: QWord;
  Total: Int64;
  Sec: Double;
begin
  if ParamCount < 5 then
  begin
    WriteLn('usage: ws_bench port conns size window secs');
    Halt(2);
  end;
  Port := StrToInt(ParamStr(1));
  Conns := StrToInt(ParamStr(2));
  Size := StrToInt(ParamStr(3));
  Window := StrToInt(ParamStr(4));
  Secs := StrToInt(ParamStr(5));
  SetLength(C, Conns);
  T0 := NowMs;
  for I := 0 to Conns - 1 do
  begin
    C[I] := TConn.Create(True);
    C[I].Port := Port;
    C[I].Size := Size;
    C[I].Window := Window;
    C[I].StopAt := T0 + QWord(Secs) * 1000;
    C[I].Start;
  end;
  Total := 0;
  for I := 0 to Conns - 1 do
  begin
    C[I].WaitFor;
    if C[I].Error <> '' then
      WriteLn(StdErr, 'connection ', I, ': ', C[I].Error);
    Inc(Total, C[I].Count);
    C[I].Free;
  end;
  T1 := NowMs;
  Sec := (T1 - T0) / 1000;
  WriteLn(Format('conns=%d size=%d window=%d: %d echoes in %.2f s = %.0f msg/s, %.1f MB/s each way',
    [Conns, Size, Window, Total, Sec, Total / Sec, Total * Size / Sec / 1e6]));
end.

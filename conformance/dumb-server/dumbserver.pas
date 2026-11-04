{ dumbserver - a mutation check for the conformance cases (test tooling only).

  It implements the process protocol of SPEC.md section 3 (the LISTENING
  line, the stdin control commands with acknowledgements, "exit", exit at
  the end of stdin) and nothing else of the contract. The server spec passed
  with --config is ignored. Every time the bytes received on a connection
  hold a CRLF CRLF, everything up to and including it counts as one
  "request", and the server writes

      HTTP/1.1 200 OK CRLF content-length: 0 CRLF CRLF

  Request bodies are not parsed (their bytes become part of the next
  "request"). The connection is closed when the client sends EOF or the
  socket fails. No date field, no keep-alive logic, no error responses, no
  timeouts, no upgrades.

  Events: by default only control_ack / control_error. With --events
  (before --config), also conn_open, a request event per "request" (method,
  target and version split from the first line; fields split at the first
  colon, names lowercased, in received order), and conn_close with outcome
  ok when the socket closes.

  A case that PASSES against this server checks less than a fixed 200
  response can satisfy. See MANIFEST.md for how each such case was judged.

  Usage: dumbserver [--events] --config <file> }
program dumbserver;

{$mode objfpc}{$H+}

uses
  cthreads, SysUtils, Classes, SyncObjs, BaseUnix, Sockets;

const
  RESPONSE = 'HTTP/1.1 200 OK'#13#10'content-length: 0'#13#10#13#10;

var
  OutLock: TCriticalSection;
  Events: Boolean = False;
  Conns: LongInt = 0;

{ a byte string as a JSON string literal (SPEC.md section 2: latin-1) }
function JStr(const B: RawByteString): RawByteString;
const
  HexD: array[0..15] of AnsiChar = '0123456789abcdef';
var
  K: SizeInt;
  C: Byte;
begin
  Result := '"';
  for K := 1 to Length(B) do
  begin
    C := Ord(B[K]);
    case C of
      Ord('"'): Result := Result + '\"';
      Ord('\'): Result := Result + '\\';
      $00..$1F, $7F..$FF: Result := Result + '\u00' + HexD[C shr 4] + HexD[C and 15];
    else
      Result := Result + AnsiChar(C);
    end;
  end;
  Result := Result + '"';
end;

procedure Emit(const Line: RawByteString);
begin
  OutLock.Acquire;
  try
    WriteLn(Line);
    Flush(Output);
  finally
    OutLock.Release;
  end;
end;

function RequestEvent(Conn, Req: Integer; const Head: RawByteString): RawByteString;
var
  Lines: array of RawByteString;
  Start, K, C: SizeInt;
  L, First, Method, Target, Version, Hs: RawByteString;
  P: SizeInt;
begin
  Lines := nil;
  Start := 1;
  for K := 1 to Length(Head) + 1 do
    if (K > Length(Head)) or (Head[K] = #10) then
    begin
      L := Copy(Head, Start, K - Start);
      if (L <> '') and (L[Length(L)] = #13) then
        SetLength(L, Length(L) - 1);
      SetLength(Lines, Length(Lines) + 1);
      Lines[High(Lines)] := L;
      Start := K + 1;
    end;
  First := Lines[0];
  { splitn(3, ' '): method, target, the rest }
  P := Pos(' ', First);
  if P = 0 then
  begin
    Method := First;
    Target := '';
    Version := '';
  end
  else
  begin
    Method := Copy(First, 1, P - 1);
    L := Copy(First, P + 1, MaxInt);
    P := Pos(' ', L);
    if P = 0 then
    begin
      Target := L;
      Version := '';
    end
    else
    begin
      Target := Copy(L, 1, P - 1);
      Version := Copy(L, P + 1, MaxInt);
    end;
  end;
  Hs := '';
  for K := 1 to High(Lines) do
  begin
    L := Lines[K];
    if L = '' then
      Continue;
    C := Pos(':', L);
    if C = 0 then
      Continue;
    if Hs <> '' then
      Hs := Hs + ',';
    Hs := Hs + '[' + JStr(LowerCase(Copy(L, 1, C - 1))) + ',' + JStr(Trim(Copy(L, C + 1, MaxInt))) + ']';
  end;
  Result := Format('{"event":"request","conn":%d,"req":%d,"method":%s,"target":%s,"version":%s,"headers":[%s]}',
    [Conn, Req, JStr(Method), JStr(Target), JStr(Version), Hs]);
end;

type
  TConnThread = class(TThread)
  public
    Fd: cint;
    Id: Integer;
    procedure Execute; override;
  end;

procedure TConnThread.Execute;
var
  Buf: RawByteString;
  Chunk: array[0..65535] of Byte;
  N: SizeInt;
  Req, I, Sent: Integer;
  Failed: Boolean;
  R: RawByteString;
begin
  if Events then
    Emit(Format('{"event":"conn_open","conn":%d}', [Id]));
  Buf := '';
  Req := 0;
  Failed := False;
  while not Failed do
  begin
    N := fpRecv(Fd, @Chunk[0], SizeOf(Chunk), 0);
    if (N < 0) and (fpgeterrno = ESysEINTR) then
      Continue;
    if N <= 0 then
      Break;
    I := Length(Buf);
    SetLength(Buf, I + N);
    Move(Chunk[0], Buf[I + 1], N);
    while True do
    begin
      I := Pos(#13#10#13#10, Buf);
      if I = 0 then
        Break;
      Inc(Req);
      if Events then
        Emit(RequestEvent(Id, Req, Copy(Buf, 1, I - 1)));
      Delete(Buf, 1, I + 3);
      R := RESPONSE;
      Sent := 0;
      while Sent < Length(R) do
      begin
        N := fpSend(Fd, @R[Sent + 1], Length(R) - Sent, $4000 { MSG_NOSIGNAL });
        if (N < 0) and (fpgeterrno = ESysEINTR) then
          Continue;
        if N <= 0 then
        begin
          Failed := True;
          Break;
        end;
        Inc(Sent, N);
      end;
      if Failed then
        Break;
    end;
  end;
  fpClose(Fd);
  if Events then
    Emit(Format('{"event":"conn_close","conn":%d,"outcome":"ok"}', [Id]));
end;

type
  TStdinThread = class(TThread)
    procedure Execute; override;
  end;

procedure TStdinThread.Execute;
var
  Line: RawByteString;
begin
  while not EOF(Input) do
  begin
    ReadLn(Input, Line);
    while (Line <> '') and (Line[Length(Line)] = #13) do
      SetLength(Line, Length(Line) - 1);
    if Line = 'exit' then
      fpExit(0)
    else if Line = 'graceful_shutdown' then
      Emit('{"event":"control_ack","command":"graceful_shutdown"}')
    else if Copy(Line, 1, 7) = 'signal ' then
      Emit(Format('{"event":"control_ack","command":"signal","name":%s}', [JStr(Copy(Line, 8, MaxInt))]))
    else
      Emit(Format('{"event":"control_error","line":%s}', [JStr(Line)]));
  end;
  { the end of stdin: the runner is gone }
  fpExit(0);
end;

var
  L, Fd: cint;
  A: TInetSockAddr;
  Len: TSockLen;
  K: Integer;
  T: TConnThread;
begin
  for K := 1 to ParamCount do
    if ParamStr(K) = '--events' then
      Events := True;
  OutLock := TCriticalSection.Create;
  L := fpSocket(AF_INET, SOCK_STREAM, 0);
  FillChar(A, SizeOf(A), 0);
  A.sin_family := AF_INET;
  A.sin_addr.s_addr := htonl($7F000001);
  if (fpBind(L, @A, SizeOf(A)) <> 0) or (fpListen(L, 128) <> 0) then
  begin
    WriteLn(StdErr, 'dumbserver: bind failed');
    Halt(1);
  end;
  Len := SizeOf(A);
  fpGetSockName(L, @A, @Len);
  Emit('LISTENING ' + IntToStr(ntohs(A.sin_port)));
  TStdinThread.Create(False);
  while True do
  begin
    Fd := fpAccept(L, nil, nil);
    if Fd < 0 then
      Continue;
    T := TConnThread.Create(True);
    T.Fd := Fd;
    T.Id := InterLockedIncrement(Conns);
    T.FreeOnTerminate := True;
    T.Start;
  end;
end.

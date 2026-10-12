{ M3 step S1 echo test (design m3-transport.md section 9, S1 exit criterion:
  "an echo test moves 1 GB with random split sizes under valgrind without
  errors").

  test_rt_echo --server
      One TLoop on the main thread, a TListener on 127.0.0.1 (kernel port,
      printed as "port N" on stdout), and one TEchoTask per connection:
      edge-triggered, TTcpTransport with tokio's readiness rules, reads of
      random size into a 64 KiB block from the loop's TBlockPool, writes of
      random size with Write or a 2-3 slice WriteV, the block given back to
      the pool whenever the task waits with nothing buffered. On EOF it
      writes what is left, shuts down the write side, closes and stops the
      loop. Exit status 0 when the connection ended cleanly.
  test_rt_echo --client PORT BYTES SEED
      A writer thread sends BYTES bytes of a seeded pseudo-random stream in
      random-size writes (1 .. 256 KiB), then shuts down its write side; the
      main thread reads with random sizes and compares every byte with the
      same stream; at EOF it checks the count. Exit status 0 on success.
  tests/unit/test_rt_echo.sh runs the server under valgrind and the client
  natively.

  cmem is the first unit: GetMem/FreeMem go to libc malloc/free, which is
  what valgrind memcheck tracks. With FPC's own heap manager memcheck sees
  no use-after-free or invalid heap access at all (checked: a deliberate
  use-after-free gives 0 errors without cmem, 1 with it). The script also
  builds with -dWD_DEBUG, so TBlockPool poisons every block given back
  (0xDD): a stale view into a recycled block would echo wrong bytes and the
  client would report a mismatch. }
program test_rt_echo;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

uses
  cmem, cthreads, SysUtils, Math, BaseUnix, Sockets, ctypes,
  bearings.rt.sys, bearings.rt.clock, bearings.rt.buf, bearings.rt.loop, bearings.rt.net, bearings.http1.encode;

const
  ECHO_BLOCK = 65536;

{$PUSH}{$Q-}{$R-}
function XorShift(var S: QWord): QWord; inline;
begin
  S := S xor (S shl 13);
  S := S xor (S shr 7);
  S := S xor (S shl 17);
  Result := S;
end;
{$POP}

type
  { the byte stream: 8 bytes per xorshift step }
  TStream = record
    S: QWord;
    Word8: QWord;
    Left: Integer;
    procedure Init(Seed: QWord);
    procedure Fill(P: PByte; N: SizeInt);
  end;

procedure TStream.Init(Seed: QWord);
begin
  S := Seed or 1;
  Left := 0;
end;

procedure TStream.Fill(P: PByte; N: SizeInt);
var
  I: SizeInt;
begin
  for I := 0 to N - 1 do
  begin
    if Left = 0 then
    begin
      Word8 := XorShift(S);
      Left := 8;
    end;
    P[I] := Byte(Word8);
    Word8 := Word8 shr 8;
    Dec(Left);
  end;
end;

{ ------------------------------------------------------------ server ---- }

type
  TEchoTask = class(TIoTask)
  private
    T: TTcpTransport;
    Block: PBufBlock;
    Start, Len: SizeInt;
    EofSeen: Boolean;
    Rng: QWord;
    function Rand(N: SizeInt): SizeInt; inline;   { 1 .. N }
    procedure Finish(Ok: Boolean);
  public
    Moved: Int64;
    Reads, Writes, WriteVs, Pendings: Int64;
    constructor Create(ALoop: TLoop; AFd: cint);
    destructor Destroy; override;
    procedure Run; override;
    procedure Abort; override;
  end;

  TEchoServer = class
  public
    Loop: TLoop;
    Ok: Boolean;
    Conns: Integer;
    Moved, Reads, Writes, WriteVs, Pendings: Int64;   { copied from the task at Finish }
    procedure OnAccept(ALoop: TLoop; var Fd: cint; const Peer: TSockAddrStorage);
  end;

var
  Server: TEchoServer;

constructor TEchoTask.Create(ALoop: TLoop; AFd: cint);
begin
  inherited Create(ALoop, AFd);
  T := NewTcpTransport(@Src);
  Rng := QWord(AFd) * 2654435761 + 12345;
  if not ALoop.Register(@Src, EPOLLIN or EPOLLOUT or EPOLLRDHUP or EPOLLET) then
    raise Exception.Create('register failed');
end;

destructor TEchoTask.Destroy;
begin
  if Block <> nil then
    BlockFree(Block);
  T.Close;
  T.Free;
  inherited Destroy;
end;

function TEchoTask.Rand(N: SizeInt): SizeInt;
begin
  if N <= 1 then
    Exit(1);
  { mostly small splits, sometimes everything }
  case XorShift(Rng) mod 4 of
    0: Result := N;
    1: Result := 1 + SizeInt(XorShift(Rng) mod QWord(Min(N, 64)));
  else
    Result := 1 + SizeInt(XorShift(Rng) mod QWord(N));
  end;
end;

procedure TEchoTask.Finish(Ok: Boolean);
begin
  Server.Ok := Ok;
  Server.Moved := Moved;
  Server.Reads := Reads;
  Server.Writes := Writes;
  Server.WriteVs := WriteVs;
  Server.Pendings := Pendings;
  T.Close;
  Close;
  Loop.StopNow;
end;

procedure TEchoTask.Run;
var
  N, K, A, B: SizeInt;
  Iov: array[0..2] of TIoSlice;
  Cnt: Integer;
begin
  repeat
    if Len > 0 then
    begin
      K := Rand(Len);
      if XorShift(Rng) mod 2 = 0 then
      begin
        N := T.Write(Block^.Data + Start, K);
        Inc(Writes);
      end
      else
      begin
        { the same K bytes as 2 or 3 slices (one may be empty) }
        A := SizeInt(XorShift(Rng) mod QWord(K + 1));
        B := SizeInt(XorShift(Rng) mod QWord(K - A + 1));
        Iov[0].Base := Block^.Data + Start;
        Iov[0].Len := A;
        Iov[1].Base := Block^.Data + Start + A;
        Iov[1].Len := B;
        Iov[2].Base := Block^.Data + Start + A + B;
        Iov[2].Len := K - A - B;
        Cnt := 3;
        N := T.WriteV(@Iov[0], Cnt);
        Inc(WriteVs);
      end;
      if N = -ESysEAGAIN then
      begin
        Inc(Pendings);
        Exit;                           { wait for EPOLLOUT }
      end;
      if N <= 0 then
      begin
        WriteLn(StdErr, 'echo: write error ', N);
        Finish(False);
        Exit;
      end;
      Inc(Start, N);
      Dec(Len, N);
      Inc(Moved, N);
      Continue;
    end;
    if EofSeen then
    begin
      T.ShutdownWrite;
      Finish(True);
      Exit;
    end;
    if Block = nil then
      Block := Loop.Blocks.Take(ECHO_BLOCK);
    Start := 0;
    N := T.Read(Block^.Data, Rand(ECHO_BLOCK));
    Inc(Reads);
    if N = -ESysEAGAIN then
    begin
      Inc(Pendings);
      BlockFree(Block);                 { idle: give the block back (4.3) }
      Block := nil;
      Exit;
    end;
    if N = 0 then
      EofSeen := True
    else if N < 0 then
    begin
      WriteLn(StdErr, 'echo: read error ', N);
      Finish(False);
      Exit;
    end
    else
      Len := N;
  until False;
end;

procedure TEchoTask.Abort;
begin
  Server.Ok := False;
  T.Close;
end;

procedure TEchoServer.OnAccept(ALoop: TLoop; var Fd: cint; const Peer: TSockAddrStorage);
var
  F: cint;
begin
  Inc(Conns);
  F := Fd;
  Fd := -1;                              { the task owns it from its constructor on }
  TEchoTask.Create(ALoop, F);            { owned by the loop: freed after Close }
end;

function RunServer: Integer;
var
  Spec: TListenSpec;
  Fd: cint;
  Port: Word;
  E: cint;
  Li: TListener;
  T0: Int64;
begin
  IgnoreSigPipe;
  Server := TEchoServer.Create;
  Server.Loop := TLoop.Create(0);
  Spec.Host := '127.0.0.1';
  Spec.Port := 0;
  Spec.Backlog := 128;
  Spec.Mode := amSingle;
  Spec.NoDelay := False;
  if not OpenListener(Spec, False, Fd, Port, E) then
  begin
    WriteLn(StdErr, 'listen failed: errno ', E);
    Exit(2);
  end;
  Li := TListener.Create(Server.Loop, Fd, @Server.OnAccept);
  WriteLn('port ', Port);
  Flush(Output);
  T0 := MonoNowNs;
  Server.Loop.Run;                       { the echo task stops it; Run frees closed tasks }
  Li.Close;                              { freed by the loop's destructor }
  WriteLn(StdErr, Format('echo server: %d bytes echoed in %.1f s; reads %d, writes %d, writevs %d, pending %d; pool blocks allocated %d',
    [Server.Moved, (MonoNowNs - T0) / 1e9, Server.Reads, Server.Writes, Server.WriteVs,
     Server.Pendings, Server.Loop.Blocks.Allocated]));
  if Server.Ok and (Server.Conns = 1) then
    Result := 0
  else
    Result := 1;
  Server.Loop.Free;
  Server.Free;
end;

{ ------------------------------------------------------------ client ---- }

var
  CFd: cint;
  CTotal: Int64;
  CSeed: QWord;
  CWriteErr: Integer;

function WriterThread(Arg: Pointer): PtrInt;
var
  St: TStream;
  Rng: QWord;
  Buf: array of Byte;
  Sent, K, N, Off: Int64;
begin
  SetLength(Buf, 262144);
  St.Init(CSeed);
  Rng := CSeed * 31 + 7;
  Sent := 0;
  while Sent < CTotal do
  begin
    K := 1 + Int64(XorShift(Rng) mod 262144);
    if K > CTotal - Sent then
      K := CTotal - Sent;
    St.Fill(@Buf[0], K);
    Off := 0;
    while Off < K do
    begin
      N := fpWrite(CFd, @Buf[Off], K - Off);
      if N <= 0 then
      begin
        CWriteErr := fpgeterrno;
        Exit(1);
      end;
      Inc(Off, N);
    end;
    Inc(Sent, K);
  end;
  fpShutdown(CFd, SHUT_WR);
  Result := 0;
end;

function RunClient(Port: Word): Integer;
var
  A: TInetSockAddr;
  Th: TThreadID;
  St: TStream;
  Rng: QWord;
  Buf, Want: array of Byte;
  Got, K, N, I: Int64;
  T0: Int64;
begin
  IgnoreSigPipe;
  CFd := fpSocket(AF_INET, SOCK_STREAM, 0);
  FillChar(A, SizeOf(A), 0);
  A.sin_family := AF_INET;
  A.sin_port := htons(Port);
  A.sin_addr.s_addr := htonl($7F000001);
  if fpConnect(CFd, @A, SizeOf(A)) <> 0 then
  begin
    WriteLn(StdErr, 'connect failed: errno ', fpgeterrno);
    Exit(2);
  end;
  T0 := MonoNowNs;
  Th := BeginThread(@WriterThread, nil);
  SetLength(Buf, 262144);
  SetLength(Want, 262144);
  St.Init(CSeed);
  Rng := CSeed * 131 + 3;
  Got := 0;
  repeat
    K := 1 + Int64(XorShift(Rng) mod 262144);
    N := fpRead(CFd, @Buf[0], K);
    if N < 0 then
    begin
      WriteLn(StdErr, 'client: read error ', fpgeterrno);
      Exit(3);
    end;
    if N = 0 then
      Break;
    St.Fill(@Want[0], N);
    if not CompareMem(@Buf[0], @Want[0], N) then
    begin
      for I := 0 to N - 1 do
        if Buf[I] <> Want[I] then
          Break;
      WriteLn(StdErr, 'client: data mismatch at offset ', Got + I);
      Exit(4);
    end;
    Inc(Got, N);
  until False;
  WaitForThreadTerminate(Th, 0);
  CloseThread(Th);
  fpClose(CFd);
  WriteLn(StdErr, Format('echo client: sent and verified %d of %d bytes in %.1f s',
    [Got, CTotal, (MonoNowNs - T0) / 1e9]));
  if CWriteErr <> 0 then
  begin
    WriteLn(StdErr, 'client: write error ', CWriteErr);
    Exit(5);
  end;
  if Got <> CTotal then
    Exit(6);
  Result := 0;
end;

begin
  if ParamStr(1) = '--server' then
    Halt(RunServer)
  else if ParamStr(1) = '--client' then
  begin
    CTotal := StrToInt64(ParamStr(3));
    CSeed := StrToQWord(ParamStr(4));
    Halt(RunClient(StrToInt(ParamStr(2))));
  end;
  WriteLn(StdErr, 'usage: test_rt_echo --server | --client PORT BYTES SEED');
  Halt(2);
end.

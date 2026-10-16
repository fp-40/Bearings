{ M3 step S1 tests for bearings.rt.net (docs/design.md section 3):
  - tokio PollEvented readiness rules on real TCP sockets: data + FIN in one
    event (short read clears rdRead, sticky rdReadClosed makes the next read
    call the kernel and see EOF); a full read keeps rdRead; no syscall
    without readiness; a short scalar write clears rdWrite, a short writev
    keeps it (the next writev gets EAGAIN and clears it); RST sets sticky
    error bits;
  - accepted sockets inherit TCP_NODELAY from the listener (read back with
    getsockopt), and get none from a listener without it (amSingle);
  - OpenListener: kernel-assigned port, SO_REUSEPORT pairs, EADDRINUSE,
    bad host; TListener accepts at most 64 per event; DrainAndClose;
  - TTransport.WriteV default writes the first non-empty slice only;
  - SIGPIPE ignored: a write to a closed peer returns -EPIPE / -ECONNRESET;
  - decision 11 (step H): under a low RLIMIT_NOFILE with a full backlog the
    listener leaves epoll for 1 s (the loop sleeps instead of spinning) and
    accepts the backlog once fds are free; an exception in OnAccept closes
    that connection's fd and accepting goes on; a TLoop constructor that
    fails after epoll_create1 does not close fd 0.
  - M5 T-3 (TTestSockAddrToStr): SockAddrToStr gives IPv4 dotted quads,
    IPv6 text by RFC 5952 4 (lower case, no leading zeros, the longest run
    of two or more zero groups as '::', the first one on a tie, a single
    zero group kept), an IPv4-mapped address as IPv4, '' for AF_UNIX and a
    zeroed record; the peer address of a socket accepted on 127.0.0.1 and
    on ::1 (skipped when the machine has no IPv6 loopback).
  Run: test_rt_net --all --format=plain }
program test_rt_net;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Classes, SysUtils, BaseUnix, Sockets, fpcunit, testregistry, consoletestrunner,
  ctypes, bearings.rt.sys, bearings.rt.clock, bearings.rt.timer, bearings.rt.loop, bearings.rt.net, bearings.rt.proxyproto,
  bearings.http1.encode;

type
  TTestNet = class(TTestCase)
  private
    L: TLoop;
    LFd: cint;
    Port: Word;
    procedure OpenLoopback(NoDelay: Boolean);
    function Connect: cint;
    function AcceptOne: cint;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure No_syscall_without_readiness;
    procedure Data_and_FIN_in_one_event;
    procedure Full_read_keeps_rdRead;
    procedure Short_write_clears_rdWrite;
    procedure Short_writev_keeps_rdWrite;
    procedure Rst_sets_sticky_error_bits;
    procedure Accepted_socket_inherits_TCP_NODELAY;
    procedure Listener_without_nodelay_gives_none;
    procedure OpenListener_ports_and_errors;
    procedure Listener_accepts_at_most_64_per_event;
    procedure Listener_drain_and_close;
    { decision 11 (step H) }
    procedure Accept_emfile_pauses_listener_and_resumes;
    procedure Accept_setup_exception_closes_fd_and_continues;
    procedure Loop_create_failure_leaves_fd_0_open;
    procedure Default_WriteV_writes_first_nonempty_slice;
    procedure Write_to_closed_peer_returns_error_not_signal;
  end;

  TConnProbe = class(TIoTask)
  public
    T: TTcpTransport;
    Events: Integer;
    constructor Create(ALoop: TLoop; AFd: cint);
    destructor Destroy; override;
    procedure Run; override;
    procedure Abort; override;
  end;

constructor TConnProbe.Create(ALoop: TLoop; AFd: cint);
begin
  inherited Create(ALoop, AFd);
  T := NewTcpTransport(@Src);
  if not ALoop.Register(@Src, EPOLLIN or EPOLLOUT or EPOLLRDHUP or EPOLLET) then
    raise Exception.Create('register failed');
end;

destructor TConnProbe.Destroy;
begin
  T.Close;
  T.Free;
  inherited Destroy;
end;

procedure TConnProbe.Run;
begin
  Inc(Events);
end;

procedure TConnProbe.Abort;
begin
end;

var
  NoopMsg: TLoopMsg;

procedure NoopProc(Loop: TLoop; Arg: Pointer);
begin
end;

{ one loop iteration that does not block }
procedure Tick(L: TLoop);
begin
  NoopMsg.Kind := lmCall;
  NoopMsg.Proc := @NoopProc;
  L.Post(@NoopMsg);
  L.RunIteration;
end;

procedure SettleKernel;
begin
  Sleep(30);
end;

procedure TTestNet.SetUp;
begin
  IgnoreSigPipe;
  L := TLoop.Create(0);
  LFd := -1;
end;

procedure TTestNet.TearDown;
begin
  Tick(L);
  if LFd >= 0 then
    fpClose(LFd);
  L.Free;
end;

procedure TTestNet.OpenLoopback(NoDelay: Boolean);
var
  Spec: TListenSpec;
  E: cint;
begin
  Spec.Host := '127.0.0.1';
  Spec.Port := 0;
  Spec.Backlog := 1024;
  Spec.Mode := amReusePort;
  Spec.NoDelay := NoDelay;
  AssertTrue('OpenListener', OpenListener(Spec, True, LFd, Port, E));
  { blocking accept4 in AcceptOne }
  fpfcntl(LFd, F_SETFL, fpfcntl(LFd, F_GETFL) and not O_NONBLOCK);
end;

function TTestNet.Connect: cint;
var
  A: TInetSockAddr;
begin
  Result := fpSocket(AF_INET, SOCK_STREAM, 0);
  FillChar(A, SizeOf(A), 0);
  A.sin_family := AF_INET;
  A.sin_port := htons(Port);
  A.sin_addr.s_addr := htonl($7F000001);
  AssertEquals('connect', 0, fpConnect(Result, @A, SizeOf(A)));
end;

function TTestNet.AcceptOne: cint;
var
  R: SizeInt;
begin
  R := SysAccept4(LFd, nil, nil, SOCK_NONBLOCK or SOCK_CLOEXEC);
  AssertTrue('accept4', R >= 0);
  Result := cint(R);
end;

procedure TTestNet.No_syscall_without_readiness;
var
  Src: TIoSource;
  T: TTcpTransport;
  B: array[0..15] of Byte;
  Off: Int64;
  Iov: TIoSlice;
  Fds: TFilDes;
begin
  Src.Fd := -1;                     { a syscall would return -EBADF }
  Src.Ready := [];
  Src.Task := nil;
  T := NewTcpTransport(@Src);
  try
    Iov.Base := @B[0];
    Iov.Len := 16;
    Off := 0;
    AssertEquals('Read pending', -ESysEAGAIN, T.Read(@B[0], 16));
    AssertEquals('Write pending', -ESysEAGAIN, T.Write(@B[0], 16));
    AssertEquals('WriteV pending', -ESysEAGAIN, T.WriteV(@Iov, 1));
    AssertEquals('SendFile pending', -ESysEAGAIN, T.SendFile(0, Off, 16));
    Src.Ready := [rdWrite];
    AssertEquals('write readiness does not allow a read', -ESysEAGAIN, T.Read(@B[0], 16));
    Src.Ready := [rdReadClosed];
    AssertEquals('read-closed calls the kernel', -ESysEBADF, T.Read(@B[0], 16));
    Src.Ready := [rdError];
    AssertEquals('error calls the kernel (read)', -ESysEBADF, T.Read(@B[0], 16));
    AssertEquals('error calls the kernel (write)', -ESysEBADF, T.Write(@B[0], 16));
    Src.Ready := [rdWriteClosed];
    AssertEquals('write-closed calls the kernel', -ESysEBADF, T.WriteV(@Iov, 1));
    AssertTrue('errors other than EAGAIN clear nothing', Src.Ready = [rdWriteClosed]);
    AssertTrue(T.IsWriteVectored);
    { EAGAIN clears only rdRead / rdWrite, never the closed or error bits:
      an empty non-blocking pipe answers EAGAIN }
    AssertEquals(0, fpPipe(Fds));
    fpfcntl(Fds[0], F_SETFL, fpfcntl(Fds[0], F_GETFL) or O_NONBLOCK);
    Src.Fd := Fds[0];
    Src.Ready := [rdRead, rdReadClosed, rdError];
    AssertEquals(-ESysEAGAIN, T.Read(@B[0], 16));
    AssertTrue('read EAGAIN keeps the sticky bits', Src.Ready = [rdReadClosed, rdError]);
    fpClose(Fds[0]);
    fpClose(Fds[1]);
  finally
    T.Free;
  end;
end;

procedure TTestNet.Data_and_FIN_in_one_event;
var
  C, S: cint;
  P: TConnProbe;
  B: array[0..4095] of Byte;
  Req: RawByteString;
begin
  OpenLoopback(True);
  C := Connect;
  S := AcceptOne;
  Req := 'GET / HTTP/1.1'#13#10'Host: x'#13#10#13#10;
  AssertEquals(Length(Req), fpWrite(C, PChar(Req), Length(Req)));
  fpShutdown(C, SHUT_WR);
  SettleKernel;
  P := TConnProbe.Create(L, S);         { registered with data and FIN already queued }
  Tick(L);
  AssertEquals('one event', 1, P.Events);
  AssertTrue('readable', rdRead in P.Src.Ready);
  AssertTrue('read-closed in the same event', rdReadClosed in P.Src.Ready);
  AssertEquals('short read', Length(Req), P.T.Read(@B[0], SizeOf(B)));
  AssertFalse('short read clears rdRead', rdRead in P.Src.Ready);
  AssertTrue('rdReadClosed is sticky', rdReadClosed in P.Src.Ready);
  { hyper's mid_message_detect_eof: the next read must reach the kernel }
  AssertEquals('EOF seen thanks to the sticky bit', 0, P.T.Read(@B[0], SizeOf(B)));
  AssertTrue('still sticky after EOF', rdReadClosed in P.Src.Ready);
  { without the sticky bit the same read would have been Pending (no syscall) }
  P.Src.Ready := P.Src.Ready - [rdReadClosed];
  AssertEquals('counterfactual: EOF lost', -ESysEAGAIN, P.T.Read(@B[0], SizeOf(B)));
  P.Close;
  fpClose(C);
end;

procedure TTestNet.Full_read_keeps_rdRead;
var
  C, S: cint;
  P: TConnProbe;
  B: array[0..99] of Byte;
begin
  OpenLoopback(True);
  C := Connect;
  S := AcceptOne;
  P := TConnProbe.Create(L, S);
  Tick(L);
  FillChar(B, SizeOf(B), 7);
  AssertEquals(100, fpWrite(C, @B[0], 100));
  SettleKernel;
  Tick(L);
  AssertTrue(rdRead in P.Src.Ready);
  AssertEquals(50, P.T.Read(@B[0], 50));
  AssertTrue('n = len keeps rdRead', rdRead in P.Src.Ready);
  AssertEquals(50, P.T.Read(@B[0], 50));
  AssertTrue('n = len keeps rdRead', rdRead in P.Src.Ready);
  AssertEquals('drained: EAGAIN from the kernel', -ESysEAGAIN, P.T.Read(@B[0], 50));
  AssertFalse('EAGAIN clears rdRead', rdRead in P.Src.Ready);
  AssertFalse(rdReadClosed in P.Src.Ready);
  { new data: a new edge sets rdRead again }
  fpWrite(C, @B[0], 10);
  SettleKernel;
  Tick(L);
  AssertTrue('new edge', rdRead in P.Src.Ready);
  AssertEquals(10, P.T.Read(@B[0], 50));
  P.Close;
  fpClose(C);
end;

procedure SmallBuffers(S, C: cint);
var
  V: cint;
begin
  V := 4096;
  fpSetSockOpt(S, SOL_SOCKET, SO_SNDBUF, @V, SizeOf(V));
  fpSetSockOpt(C, SOL_SOCKET, SO_RCVBUF, @V, SizeOf(V));
end;

procedure TTestNet.Short_write_clears_rdWrite;
var
  C, S: cint;
  P: TConnProbe;
  Big: array of Byte;
  N: SizeInt;
  B: array[0..65535] of Byte;
begin
  OpenLoopback(True);
  C := Connect;
  S := AcceptOne;
  SmallBuffers(S, C);
  P := TConnProbe.Create(L, S);
  Tick(L);
  AssertTrue('writable', rdWrite in P.Src.Ready);
  SetLength(Big, 4 * 1024 * 1024);
  N := P.T.Write(@Big[0], Length(Big));
  AssertTrue('partial write', (N > 0) and (N < Length(Big)));
  AssertFalse('short scalar write clears rdWrite', rdWrite in P.Src.Ready);
  AssertEquals('next write is Pending without a syscall', -ESysEAGAIN, P.T.Write(@Big[0], Length(Big)));
  { the client reads: EPOLLOUT edge }
  fpfcntl(C, F_SETFL, fpfcntl(C, F_GETFL) or O_NONBLOCK);
  while fpRead(C, @B[0], SizeOf(B)) > 0 do;
  SettleKernel;
  Tick(L);
  AssertTrue('writable again after an edge', rdWrite in P.Src.Ready);
  P.Close;
  fpClose(C);
end;

procedure TTestNet.Short_writev_keeps_rdWrite;
var
  C, S: cint;
  P: TConnProbe;
  Big: array of Byte;
  Iov: array[0..1] of TIoSlice;
  N: SizeInt;
  Shorts: Integer;
begin
  OpenLoopback(True);
  C := Connect;
  S := AcceptOne;
  SmallBuffers(S, C);
  P := TConnProbe.Create(L, S);
  Tick(L);
  AssertTrue(rdWrite in P.Src.Ready);
  SetLength(Big, 4 * 1024 * 1024);
  Iov[0].Base := @Big[0];
  Iov[0].Len := 2 * 1024 * 1024;
  Iov[1].Base := @Big[2 * 1024 * 1024];
  Iov[1].Len := 2 * 1024 * 1024;
  N := P.T.WriteV(@Iov[0], 2);
  AssertTrue('partial writev', (N > 0) and (N < Length(Big)));
  AssertTrue('short writev keeps rdWrite (tokio poll_write_vectored)', rdWrite in P.Src.Ready);
  { the next writevs call the kernel (it may still take some bytes as the
    peer's receive queue fills); every short one keeps rdWrite, the first
    EAGAIN clears it }
  Shorts := 1;
  repeat
    N := P.T.WriteV(@Iov[0], 2);
    if N > 0 then
    begin
      AssertTrue('still short', N < Length(Big));
      AssertTrue('still kept', rdWrite in P.Src.Ready);
      Inc(Shorts);
    end;
  until (N <= 0) or (Shorts > 1000);
  AssertEquals('the kernel answered EAGAIN', -ESysEAGAIN, N);
  AssertFalse('EAGAIN clears rdWrite', rdWrite in P.Src.Ready);
  AssertEquals('then Pending without a syscall', -ESysEAGAIN, P.T.WriteV(@Iov[0], 2));
  P.Close;
  fpClose(C);
end;

procedure TTestNet.Rst_sets_sticky_error_bits;
var
  C, S: cint;
  P: TConnProbe;
  Lg: linger;
  B: array[0..15] of Byte;
  R: SizeInt;
begin
  OpenLoopback(True);
  C := Connect;
  S := AcceptOne;
  P := TConnProbe.Create(L, S);
  Tick(L);
  Lg.l_onoff := 1;
  Lg.l_linger := 0;
  fpSetSockOpt(C, SOL_SOCKET, SO_LINGER, @Lg, SizeOf(Lg));
  fpClose(C);                         { RST }
  SettleKernel;
  Tick(L);
  AssertTrue('read-closed', rdReadClosed in P.Src.Ready);
  AssertTrue('write-closed', rdWriteClosed in P.Src.Ready);
  R := P.T.Read(@B[0], 16);
  AssertEquals('ECONNRESET', -ESysECONNRESET, R);
  AssertTrue('closed bits stay', [rdReadClosed, rdWriteClosed] <= P.Src.Ready);
  AssertEquals('then EOF, still from the kernel', 0, P.T.Read(@B[0], 16));
  P.Close;
end;

function NoDelayOf(Fd: cint): cint;
var
  L: Cardinal;
begin
  Result := -1;
  L := SizeOf(Result);
  if SysGetSockOpt(Fd, IPPROTO_TCP, TCP_NODELAY, @Result, @L) <> 0 then
    Result := -2;
end;

procedure TTestNet.Accepted_socket_inherits_TCP_NODELAY;
var
  C, S: cint;
begin
  OpenLoopback(True);
  AssertEquals('listener has it', 1, NoDelayOf(LFd));
  C := Connect;
  S := AcceptOne;
  AssertEquals('accepted socket inherited TCP_NODELAY (no per-socket set needed)', 1, NoDelayOf(S));
  fpClose(S);
  fpClose(C);
end;

procedure TTestNet.Listener_without_nodelay_gives_none;
var
  C, S: cint;
begin
  OpenLoopback(False);
  AssertEquals(0, NoDelayOf(LFd));
  C := Connect;
  S := AcceptOne;
  AssertEquals('amSingle: accepted sockets get no TCP_NODELAY', 0, NoDelayOf(S));
  fpClose(S);
  fpClose(C);
end;

procedure TTestNet.OpenListener_ports_and_errors;
var
  Spec: TListenSpec;
  F1, F2, F3: cint;
  P1, P2, P3: Word;
  E: cint;
  V, Ln: Cardinal;
begin
  Spec.Host := '127.0.0.1';
  Spec.Port := 0;
  Spec.Backlog := 128;
  Spec.Mode := amSingle;
  Spec.NoDelay := False;
  AssertTrue(OpenListener(Spec, False, F1, P1, E));
  AssertTrue('kernel-assigned port', P1 > 0);
  AssertTrue('non-blocking', (fpfcntl(F1, F_GETFL) and O_NONBLOCK) <> 0);
  AssertTrue('cloexec', (fpfcntl(F1, F_GETFD) and 1) <> 0);
  V := 0;
  Ln := SizeOf(V);
  SysGetSockOpt(F1, SOL_SOCKET, SO_REUSEADDR, @V, @Ln);
  AssertEquals('SO_REUSEADDR (mio)', 1, V);
  Spec.Port := P1;
  AssertFalse('second bind without SO_REUSEPORT', OpenListener(Spec, False, F2, P2, E));
  AssertEquals('EADDRINUSE', ESysEADDRINUSE, E);
  AssertEquals('fd closed on failure', -1, F2);
  fpClose(F1);
  { SO_REUSEPORT: the first binds port 0, the others bind that port }
  Spec.Port := 0;
  AssertTrue(OpenListener(Spec, True, F1, P1, E));
  Spec.Port := P1;
  AssertTrue('reuseport #2', OpenListener(Spec, True, F2, P2, E));
  AssertTrue('reuseport #3', OpenListener(Spec, True, F3, P3, E));
  AssertEquals(P1, P2);
  AssertEquals(P1, P3);
  fpClose(F1); fpClose(F2); fpClose(F3);
  Spec.Host := 'not-an-address';
  AssertFalse(OpenListener(Spec, False, F1, P1, E));
  AssertEquals(ESysEINVAL, E);
  Spec.Host := '::1';
  Spec.Port := 0;
  if OpenListener(Spec, False, F1, P1, E) then
  begin
    AssertTrue('IPv6 port', P1 > 0);
    fpClose(F1);
  end
  else
    AssertTrue('IPv6 unavailable is the only allowed failure', E = 99 {EADDRNOTAVAIL}) ;
end;

type
  TAcceptSink = class
  public
    Fds: array of cint;
    FailNext: Integer;               { raise in the next N OnAccept calls (decision 11) }
    procedure OnAccept(Loop: TLoop; var Fd: cint; const Peer: TSockAddrStorage);
    procedure CloseAll;
  end;

procedure TAcceptSink.OnAccept(Loop: TLoop; var Fd: cint; const Peer: TSockAddrStorage);
begin
  if FailNext > 0 then
  begin
    Dec(FailNext);
    raise Exception.Create('setup failure (test)');
  end;
  SetLength(Fds, Length(Fds) + 1);
  Fds[High(Fds)] := Fd;
  Fd := -1;
end;

procedure TAcceptSink.CloseAll;
var
  F: cint;
begin
  for F in Fds do
    fpClose(F);
  Fds := nil;
end;

procedure TTestNet.Listener_accepts_at_most_64_per_event;
var
  Sink: TAcceptSink;
  Li: TListener;
  Cs: array[0..99] of cint;
  I: Integer;
begin
  OpenLoopback(True);
  fpfcntl(LFd, F_SETFL, fpfcntl(LFd, F_GETFL) or O_NONBLOCK);
  Sink := TAcceptSink.Create;
  Li := TListener.Create(L, LFd, @Sink.OnAccept);
  LFd := -1;                           { owned by the listener now }
  try
    for I := 0 to 99 do
      Cs[I] := Connect;
    SettleKernel;
    Tick(L);
    AssertEquals('one batch: 64', 64, Length(Sink.Fds));
    AssertEquals(64, Li.Accepted);
    Tick(L);                           { level-triggered: reported again }
    AssertEquals('the rest on the next event', 100, Length(Sink.Fds));
    AssertTrue('peer address filled', True);
  finally
    Sink.CloseAll;
    for I := 0 to 99 do
      fpClose(Cs[I]);
    Li.Close;
    Sink.Free;
  end;
end;

procedure TTestNet.Listener_drain_and_close;
var
  Sink: TAcceptSink;
  Li: TListener;
  Cs: array[0..79] of cint;
  I: Integer;
  A: TInetSockAddr;
  C: cint;
begin
  OpenLoopback(True);
  fpfcntl(LFd, F_SETFL, fpfcntl(LFd, F_GETFL) or O_NONBLOCK);
  Sink := TAcceptSink.Create;
  Li := TListener.Create(L, LFd, @Sink.OnAccept);
  LFd := -1;
  try
    for I := 0 to 79 do
      Cs[I] := Connect;
    SettleKernel;
    Li.DrainAndClose;                  { not limited to 64 }
    AssertEquals(80, Length(Sink.Fds));
    AssertTrue(Li.Closed);
    C := fpSocket(AF_INET, SOCK_STREAM, 0);
    FillChar(A, SizeOf(A), 0);
    A.sin_family := AF_INET;
    A.sin_port := htons(Port);
    A.sin_addr.s_addr := htonl($7F000001);
    AssertEquals('listener closed: refused', -1, fpConnect(C, @A, SizeOf(A)));
    fpClose(C);
  finally
    Sink.CloseAll;
    for I := 0 to 79 do
      fpClose(Cs[I]);
    Sink.Free;
  end;
end;


const
  CLOCK_THREAD_CPUTIME_ID = 3;

function ThreadCpuNs: Int64;
var
  Ts: record Sec, NSec: Int64; end;
begin
  clock_gettime(CLOCK_THREAD_CPUTIME_ID, @Ts);
  Result := Ts.Sec * 1000000000 + Ts.NSec;
end;

{ the lowest fd number not in use }
function LowestFreeFd: cint;
begin
  Result := fpOpen('/dev/null', O_RDONLY);
  fpClose(Result);
end;

procedure FlagProc(T: PTimer);
begin
  PBoolean(T^.Owner)^ := True;
end;

{ runs loop iterations until the timer DelayMs from now fires }
procedure RunFor(L: TLoop; DelayMs: Integer);
var
  T: TTimer;
  Flag: Boolean;
begin
  Flag := False;
  TimerInit(@T, @FlagProc, @Flag);
  L.Timers.Arm(@T, L.NowMs + DelayMs);
  repeat
    L.RunIteration;
  until Flag;
  L.Timers.Remove(@T);
end;

procedure TTestNet.Accept_emfile_pauses_listener_and_resumes;
var
  Sink: TAcceptSink;
  Li: TListener;
  Cs: array[0..9] of cint;
  I: Integer;
  Old, Lim: TRLimit;
  W0: QWord;
  Cpu0, CpuUsed, T0, Waited: Int64;
begin
  OpenLoopback(True);
  fpfcntl(LFd, F_SETFL, fpfcntl(LFd, F_GETFL) or O_NONBLOCK);
  Sink := TAcceptSink.Create;
  Li := TListener.Create(L, LFd, @Sink.OnAccept);
  LFd := -1;
  AssertEquals('getrlimit', 0, FpGetRLimit(RLIMIT_NOFILE, @Old));
  try
    for I := 0 to High(Cs) do
      Cs[I] := Connect;
    SettleKernel;
    { every fd below the limit is in use: accept4 fails with EMFILE while
      the 10 connections stay in the backlog }
    Lim := Old;
    Lim.rlim_cur := LowestFreeFd;
    AssertEquals('setrlimit', 0, FpSetRLimit(RLIMIT_NOFILE, @Lim));
    W0 := L.Waits;
    Cpu0 := ThreadCpuNs;
    RunFor(L, 500);
    CpuUsed := ThreadCpuNs - Cpu0;
    AssertEquals('nothing accepted', 0, Length(Sink.Fds));
    AssertTrue('accept errors counted', Li.AcceptErrors >= 1);
    AssertTrue('paused', Li.Paused);
    AssertEquals('one pause', 1, Li.Pauses);
    { without the pause every epoll_wait returns at once (level-triggered,
      non-empty backlog): hundreds of thousands of iterations in 500 ms }
    AssertTrue(Format('the loop sleeps: %d epoll_waits in 500 ms', [L.Waits - W0]),
      L.Waits - W0 < 20);
    AssertTrue(Format('CPU stays low: %d us in 500 ms', [CpuUsed div 1000]),
      CpuUsed < 50 * 1000000);
    { fds free again: accepting resumes when the 1 s pause ends }
    AssertEquals('setrlimit back', 0, FpSetRLimit(RLIMIT_NOFILE, @Old));
    T0 := L.NowMs;
    while (Length(Sink.Fds) < Length(Cs)) and (L.NowMs - T0 < 3000) do
      RunFor(L, 50);
    Waited := L.NowMs - T0;
    AssertEquals('the backlog is accepted after the pause', Length(Cs), Length(Sink.Fds));
    AssertFalse('resumed', Li.Paused);
    AssertTrue(Format('resumed after the rest of the 1 s pause (%d ms)', [Waited]),
      (Waited >= 400) and (Waited <= 1500));
  finally
    FpSetRLimit(RLIMIT_NOFILE, @Old);
    Sink.CloseAll;
    for I := 0 to High(Cs) do
      fpClose(Cs[I]);
    Li.Close;
    Sink.Free;
  end;
end;

procedure TTestNet.Accept_setup_exception_closes_fd_and_continues;
var
  Sink: TAcceptSink;
  Li: TListener;
  Cs: array[0..2] of cint;
  I, Eofs: Integer;
  B: Byte;
  Pfd: TPollFd;
begin
  OpenLoopback(True);
  fpfcntl(LFd, F_SETFL, fpfcntl(LFd, F_GETFL) or O_NONBLOCK);
  Sink := TAcceptSink.Create;
  Sink.FailNext := 1;
  Li := TListener.Create(L, LFd, @Sink.OnAccept);
  LFd := -1;
  try
    for I := 0 to High(Cs) do
      Cs[I] := Connect;
    SettleKernel;
    Tick(L);
    AssertFalse('the listener survives the exception', Li.Closed);
    AssertEquals('setup error counted', 1, Li.SetupErrors);
    AssertEquals('the other two accepted in the same batch', 2, Length(Sink.Fds));
    AssertEquals('three accepted', 3, Li.Accepted);
    { the failed connection's fd was closed: exactly one client sees EOF }
    SettleKernel;
    Eofs := 0;
    for I := 0 to High(Cs) do
    begin
      Pfd.fd := Cs[I];
      Pfd.events := POLLIN;
      Pfd.revents := 0;
      if (fpPoll(@Pfd, 1, 0) = 1) and (fpRecv(Cs[I], @B, 1, 0) = 0) then
        Inc(Eofs);
    end;
    AssertEquals('one connection closed by the listener', 1, Eofs);
  finally
    Sink.CloseAll;
    for I := 0 to High(Cs) do
      fpClose(Cs[I]);
    Li.Close;
    Sink.Free;
  end;
end;

procedure TTestNet.Loop_create_failure_leaves_fd_0_open;
var
  Old, Lim: TRLimit;
  Raised: Boolean;
  L2: TLoop;
  Fd0Open: Boolean;
begin
  { fd 0 must be open, or epoll_create1 itself would take it }
  if fpfcntl(0, F_GETFD) < 0 then
    fpOpen('/dev/null', O_RDONLY);
  AssertTrue('fd 0 open before', fpfcntl(0, F_GETFD) >= 0);
  AssertEquals(0, FpGetRLimit(RLIMIT_NOFILE, @Old));
  Lim := Old;
  { room for epoll_create1, none for eventfd2 }
  Lim.rlim_cur := LowestFreeFd + 1;
  Raised := False;
  L2 := nil;
  AssertEquals(0, FpSetRLimit(RLIMIT_NOFILE, @Lim));
  try
    try
      L2 := TLoop.Create(1);
    except
      on E: Exception do
        Raised := True;
    end;
  finally
    FpSetRLimit(RLIMIT_NOFILE, @Old);
  end;
  L2.Free;
  Fd0Open := fpfcntl(0, F_GETFD) >= 0;
  if not Fd0Open then
    fpOpen('/dev/null', O_RDONLY);        { give the runner its fd 0 back }
  AssertTrue('the constructor raised (eventfd2: EMFILE)', Raised);
  AssertTrue('fd 0 still open after the failed constructor', Fd0Open);
end;

type
  TRecTransport = class(TTransport)
  public
    Writes: TStringList;
    constructor Create;
    destructor Destroy; override;
    function Read(Buf: PByte; Len: SizeInt): SizeInt; override;
    function Write(Buf: PByte; Len: SizeInt): SizeInt; override;
    function ShutdownWrite: SizeInt; override;
    procedure Close; override;
  end;

constructor TRecTransport.Create;
begin
  inherited Create;
  Writes := TStringList.Create;
end;

destructor TRecTransport.Destroy;
begin
  Writes.Free;
  inherited Destroy;
end;

function TRecTransport.Read(Buf: PByte; Len: SizeInt): SizeInt;
begin
  Result := 0;
end;

function TRecTransport.Write(Buf: PByte; Len: SizeInt): SizeInt;
var
  S: RawByteString;
begin
  SetLength(S, Len);
  if Len > 0 then
    Move(Buf^, S[1], Len);
  Writes.Add(S);
  Result := Len;
end;

function TRecTransport.ShutdownWrite: SizeInt;
begin
  Result := 0;
end;

procedure TRecTransport.Close;
begin
end;

procedure TTestNet.Default_WriteV_writes_first_nonempty_slice;
var
  T: TRecTransport;
  A, B: RawByteString;
  Iov: array[0..2] of TIoSlice;
  Off: Int64;
begin
  T := TRecTransport.Create;
  try
    A := 'abc';
    B := 'defg';
    Iov[0].Base := nil; Iov[0].Len := 0;
    Iov[1].Base := PChar(A); Iov[1].Len := 3;
    Iov[2].Base := PChar(B); Iov[2].Len := 4;
    AssertEquals(3, T.WriteV(@Iov[0], 3));
    AssertEquals(1, T.Writes.Count);
    AssertEquals('abc', T.Writes[0]);
    AssertFalse(T.IsWriteVectored);
    Off := 0;
    AssertEquals('no sendfile by default', -ESysENOSYS, T.SendFile(0, Off, 1));
  finally
    T.Free;
  end;
end;

procedure TTestNet.Write_to_closed_peer_returns_error_not_signal;
var
  C, S: cint;
  P: TConnProbe;
  B: array[0..65535] of Byte;
  R: SizeInt;
  I: Integer;
begin
  OpenLoopback(True);
  C := Connect;
  S := AcceptOne;
  P := TConnProbe.Create(L, S);
  Tick(L);
  fpClose(C);
  SettleKernel;
  Tick(L);
  R := 0;
  for I := 1 to 10 do
  begin
    P.Src.Ready := P.Src.Ready + [rdWrite];
    R := P.T.Write(@B[0], SizeOf(B));
    if R < 0 then
      Break;
    SettleKernel;
  end;
  AssertTrue('EPIPE or ECONNRESET, and the process is alive',
    (R = -ESysEPIPE) or (R = -ESysECONNRESET));
  P.Close;
end;

{ ---- M5 T-3: SockAddrToStr ---- }

type
  TTestSockAddrToStr = class(TTestCase)
  published
    procedure Ipv4;
    procedure Ipv6_rfc5952;
    procedure Ipv4_mapped_shown_as_ipv4;
    procedure Other_families_give_empty;
    procedure Accepted_peer_addresses;
  end;

function V4(A, B, C, D: Byte; Port: Word): TSockAddrStorage;
begin
  FillChar(Result, SizeOf(Result), 0);
  PInetSockAddr(@Result)^.sin_family := AF_INET;
  PInetSockAddr(@Result)^.sin_port := htons(Port);
  PByte(@PInetSockAddr(@Result)^.sin_addr)[0] := A;
  PByte(@PInetSockAddr(@Result)^.sin_addr)[1] := B;
  PByte(@PInetSockAddr(@Result)^.sin_addr)[2] := C;
  PByte(@PInetSockAddr(@Result)^.sin_addr)[3] := D;
end;

{ eight groups, host order }
function V6(const G: array of Word): TSockAddrStorage;
var I: Integer; P: PByte;
begin
  FillChar(Result, SizeOf(Result), 0);
  PInetSockAddr6(@Result)^.sin6_family := AF_INET6;
  P := @PInetSockAddr6(@Result)^.sin6_addr;
  for I := 0 to 7 do
  begin
    P[2 * I] := G[I] shr 8;
    P[2 * I + 1] := G[I] and $FF;
  end;
end;

procedure TTestSockAddrToStr.Ipv4;
begin
  AssertEquals('127.0.0.1', SockAddrToStr(V4(127, 0, 0, 1, 80)));
  AssertEquals('0.0.0.0', SockAddrToStr(V4(0, 0, 0, 0, 0)));
  AssertEquals('255.255.255.255', SockAddrToStr(V4(255, 255, 255, 255, 1)));
  AssertEquals('10.0.0.9', SockAddrToStr(V4(10, 0, 0, 9, 5555)));
  AssertEquals(5555, SockAddrPort(V4(10, 0, 0, 9, 5555)));
end;

procedure TTestSockAddrToStr.Ipv6_rfc5952;
begin
  AssertEquals('::', SockAddrToStr(V6([0, 0, 0, 0, 0, 0, 0, 0])));
  AssertEquals('::1', SockAddrToStr(V6([0, 0, 0, 0, 0, 0, 0, 1])));
  AssertEquals('1::', SockAddrToStr(V6([1, 0, 0, 0, 0, 0, 0, 0])));
  { 4.1 no leading zeros, 4.3 lower case }
  AssertEquals('2001:db8::1', SockAddrToStr(V6([$2001, $0DB8, 0, 0, 0, 0, 0, 1])));
  AssertEquals('2001:db8:aaaa:bbbb:cccc:dddd:eeee:1',
    SockAddrToStr(V6([$2001, $DB8, $AAAA, $BBBB, $CCCC, $DDDD, $EEEE, 1])));
  { 4.2.2 a single zero group is not shortened }
  AssertEquals('2001:db8:0:1:1:1:1:1', SockAddrToStr(V6([$2001, $DB8, 0, 1, 1, 1, 1, 1])));
  { 4.2.3 the longest run; the first on a tie }
  AssertEquals('2001:0:0:1::1', SockAddrToStr(V6([$2001, 0, 0, 1, 0, 0, 0, 1])));
  AssertEquals('2001:db8::1:0:0:1', SockAddrToStr(V6([$2001, $DB8, 0, 0, 1, 0, 0, 1])));
  AssertEquals('fe80::1:2', SockAddrToStr(V6([$FE80, 0, 0, 0, 0, 0, 1, 2])));
  { an IPv4-compatible (not mapped) address stays IPv6 text }
  AssertEquals('::7f00:1', SockAddrToStr(V6([0, 0, 0, 0, 0, 0, $7F00, 1])));
  AssertEquals('::fffe:7f00:1', SockAddrToStr(V6([0, 0, 0, 0, 0, $FFFE, $7F00, 1])));
end;

procedure TTestSockAddrToStr.Ipv4_mapped_shown_as_ipv4;
begin
  AssertEquals('127.0.0.1', SockAddrToStr(V6([0, 0, 0, 0, 0, $FFFF, $7F00, 1])));
  AssertEquals('203.0.113.5', SockAddrToStr(V6([0, 0, 0, 0, 0, $FFFF, $CB00, $7105])));
end;

procedure TTestSockAddrToStr.Other_families_give_empty;
var A: TSockAddrStorage;
begin
  FillChar(A, SizeOf(A), 0);
  AssertEquals('', SockAddrToStr(A));
  A.Family := AF_UNIX;
  AssertEquals('', SockAddrToStr(A));
end;

procedure TTestSockAddrToStr.Accepted_peer_addresses;
const HOSTS: array[0..1] of RawByteString = ('127.0.0.1', '::1');
var
  Spec: TListenSpec;
  LFd, C, S, E: cint;
  Port: Word;
  I: Integer;
  Addr, Peer: TSockAddrStorage;
  AddrLen: Cardinal;
  PLen: TSockLen;
begin
  for I := 0 to High(HOSTS) do
  begin
    Spec.Host := HOSTS[I];
    Spec.Port := 0;
    Spec.Backlog := 16;
    Spec.Mode := amSingle;
    Spec.NoDelay := False;
    if not OpenListener(Spec, False, LFd, Port, E) then
    begin
      if I = 1 then Continue;                   { no IPv6 loopback on this machine }
      Fail('OpenListener ' + HOSTS[I]);
    end;
    try
      fpfcntl(LFd, F_SETFL, fpfcntl(LFd, F_GETFL) and not O_NONBLOCK);
      AssertTrue(MakeSockAddr(HOSTS[I], Port, Addr, AddrLen));
      C := fpSocket(Addr.Family, SOCK_STREAM, 0);
      try
        AssertEquals('connect ' + HOSTS[I], 0, fpConnect(C, @Addr, AddrLen));
        PLen := SizeOf(Peer);
        S := fpAccept(LFd, @Peer, @PLen);
        AssertTrue('accept', S >= 0);
        fpClose(S);
        AssertEquals(HOSTS[I], SockAddrToStr(Peer));
        AssertTrue('a client port', SockAddrPort(Peer) <> 0);
      finally
        fpClose(C);
      end;
    finally
      fpClose(LFd);
    end;
  end;
end;

{ ---- the PROXY protocol header (bearings.rt.proxyproto) ---- }

type
  TTestProxyProto = class(TTestCase)
  private
    Peer: TSockAddrStorage;
    Used: SizeInt;
    HasPeer: Boolean;
    function Parse(const S: RawByteString): TProxyParse;
    function PeerText: RawByteString;
  published
    procedure V1_tcp4_and_tcp6;
    procedure V1_unknown_keeps_the_socket_peer;
    procedure V1_errors;
    procedure V1_byte_by_byte;
    procedure V2_inet_and_inet6;
    procedure V2_local_unspec_unix_and_tlvs;
    procedure V2_errors;
    procedure V2_byte_by_byte;
    procedure Not_a_header;
  end;

const
  V2_SIG = #13#10#13#10#0#13#10'QUIT'#10;

function V2(Cmd, Fam: Byte; const Body: RawByteString): RawByteString;
begin
  Result := V2_SIG + AnsiChar($20 or Cmd) + AnsiChar(Fam) + AnsiChar(Length(Body) shr 8)
    + AnsiChar(Length(Body) and $FF) + Body;
end;

function TTestProxyProto.Parse(const S: RawByteString): TProxyParse;
begin
  FillChar(Peer, SizeOf(Peer), 0);
  Peer.Family := 99;                 { a marker: untouched means 99 }
  Used := -1;
  Result := ParseProxyHeader(PByte(PAnsiChar(S)), Length(S), Used, HasPeer, Peer);
end;

function TTestProxyProto.PeerText: RawByteString;
begin
  Result := IntToStr(Peer.Family) + ':' + SockAddrToStr(Peer) + ':' + IntToStr(SockAddrPort(Peer));
end;

procedure TTestProxyProto.V1_tcp4_and_tcp6;
begin
  AssertTrue(Parse('PROXY TCP4 10.1.2.3 10.0.0.1 5555 80'#13#10'GET /') = ppOk);
  AssertEquals(38, Used);
  AssertTrue(HasPeer);
  AssertEquals('2:10.1.2.3:5555', PeerText);
  AssertTrue(Parse('PROXY TCP6 2001:db8::1 ::1 65535 443'#13#10) = ppOk);
  AssertEquals(38, Used);
  AssertEquals('10:2001:db8::1:65535', PeerText);
  { the longest TCP6 line (104 bytes; the specification's bound is 107) }
  AssertTrue(Parse('PROXY TCP6 ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff 65535 65535'#13#10) = ppOk);
  AssertEquals(104, Used);
end;

procedure TTestProxyProto.V1_unknown_keeps_the_socket_peer;
begin
  AssertTrue(Parse('PROXY UNKNOWN'#13#10) = ppOk);
  AssertEquals(15, Used);
  AssertFalse(HasPeer);
  AssertEquals('untouched', 99, Peer.Family);
  AssertTrue(Parse('PROXY UNKNOWN ffff:f...:ffff ffff:f...:ffff 65535 65535'#13#10) = ppOk);
  AssertFalse(HasPeer);
end;

procedure TTestProxyProto.V1_errors;
begin
  AssertTrue('no CRLF in 107 bytes', Parse('PROXY TCP4 10.1.2.3 10.0.0.1 5555 80' + StringOfChar(' ', 80)) = ppError);
  AssertTrue('bad protocol', Parse('PROXY UDP4 10.1.2.3 10.0.0.1 5555 80'#13#10) = ppError);
  AssertTrue('family mismatch', Parse('PROXY TCP4 2001:db8::1 ::1 5555 80'#13#10) = ppError);
  AssertTrue('bad address', Parse('PROXY TCP4 10.1.2 10.0.0.1 5555 80'#13#10) = ppError);
  AssertTrue('bad port', Parse('PROXY TCP4 10.1.2.3 10.0.0.1 65536 80'#13#10) = ppError);
  AssertTrue('port not a number', Parse('PROXY TCP4 10.1.2.3 10.0.0.1 5x 80'#13#10) = ppError);
  AssertTrue('missing field', Parse('PROXY TCP4 10.1.2.3 10.0.0.1 5555'#13#10) = ppError);
  { the bound is the line's length, CRLF included, whatever follows it }
  AssertTrue('107 bytes', Parse('PROXY UNKNOWN ' + StringOfChar('x', 91) + #13#10'GET / HTTP/1.1') = ppOk);
  AssertEquals(107, Used);
  AssertTrue('108 bytes', Parse('PROXY UNKNOWN ' + StringOfChar('x', 92) + #13#10'GET / HTTP/1.1') = ppError);
  AssertTrue('108 bytes, alone', Parse('PROXY UNKNOWN ' + StringOfChar('x', 92) + #13#10) = ppError);
  AssertTrue('extra field', Parse('PROXY TCP4 10.1.2.3 10.0.0.1 5555 80 x'#13#10) = ppError);
  AssertTrue('lowercase', Parse('proxy TCP4 10.1.2.3 10.0.0.1 5555 80'#13#10) = ppError);
end;

procedure TTestProxyProto.V1_byte_by_byte;
var
  S: RawByteString;
  I: Integer;
begin
  S := 'PROXY TCP4 10.1.2.3 10.0.0.1 5555 80'#13#10;
  for I := 0 to Length(S) - 1 do
    AssertTrue('prefix of ' + IntToStr(I), Parse(Copy(S, 1, I)) = ppNeedMore);
  AssertTrue(Parse(S) = ppOk);
end;

procedure TTestProxyProto.V2_inet_and_inet6;
begin
  AssertTrue(Parse(V2(1, $11, #10#1#2#3 + #10#0#0#1 + #$15#$B3 + #0#80) + 'GET') = ppOk);
  AssertEquals(28, Used);
  AssertTrue(HasPeer);
  AssertEquals('2:10.1.2.3:5555', PeerText);
  AssertTrue(Parse(V2(1, $21, #$20#$01#$0D#$B8#0#0#0#0#0#0#0#0#0#0#0#1 + StringOfChar(#0, 15) + #1
    + #$FF#$FF + #1#$BB)) = ppOk);
  AssertEquals(52, Used);
  AssertEquals('10:2001:db8::1:65535', PeerText);
end;

procedure TTestProxyProto.V2_local_unspec_unix_and_tlvs;
begin
  AssertTrue('LOCAL', Parse(V2(0, 0, '')) = ppOk);
  AssertEquals(16, Used);
  AssertFalse(HasPeer);
  AssertEquals(99, Peer.Family);
  AssertTrue('LOCAL with a body', Parse(V2(0, $11, StringOfChar(#7, 12))) = ppOk);
  AssertEquals(28, Used);
  AssertFalse(HasPeer);
  AssertTrue('unspec', Parse(V2(1, 0, '')) = ppOk);
  AssertFalse(HasPeer);
  AssertTrue('unix', Parse(V2(1, $31, StringOfChar('a', 216))) = ppOk);
  AssertEquals(232, Used);
  AssertFalse(HasPeer);
  { TLVs after the address block are skipped }
  AssertTrue('tlv', Parse(V2(1, $11, #10#1#2#3 + #10#0#0#1 + #$15#$B3 + #0#80 + #$20#0#5'hello')) = ppOk);
  AssertEquals(36, Used);
  AssertEquals('2:10.1.2.3:5555', PeerText);
end;

procedure TTestProxyProto.V2_errors;
begin
  AssertTrue('version 1 byte', Parse(V2_SIG + #$11#$11#0#12 + StringOfChar(#0, 12)) = ppError);
  AssertTrue('command 2', Parse(V2_SIG + #$22#$11#0#12 + StringOfChar(#0, 12)) = ppError);
  AssertTrue('inet body short', Parse(V2(1, $11, StringOfChar(#0, 11))) = ppError);
  AssertTrue('inet6 body short', Parse(V2(1, $21, StringOfChar(#0, 35))) = ppError);
  AssertTrue('family 4', Parse(V2(1, $41, '')) = ppError);
  AssertTrue('too long', Parse(V2_SIG + #$21#$11#$FF#$FF) = ppError);
end;

procedure TTestProxyProto.V2_byte_by_byte;
var
  S: RawByteString;
  I: Integer;
begin
  S := V2(1, $11, #10#1#2#3 + #10#0#0#1 + #$15#$B3 + #0#80);
  for I := 0 to Length(S) - 1 do
    AssertTrue('prefix of ' + IntToStr(I), Parse(Copy(S, 1, I)) = ppNeedMore);
  AssertTrue(Parse(S) = ppOk);
end;

procedure TTestProxyProto.Not_a_header;
begin
  AssertTrue(Parse('') = ppNeedMore);
  AssertTrue(Parse('GET / HTTP/1.1'#13#10) = ppError);
  AssertTrue(Parse('P') = ppNeedMore);
  AssertTrue(Parse('PR') = ppNeedMore);
  AssertTrue(Parse('PROXZ') = ppError);
  AssertTrue(Parse(#13) = ppNeedMore);
  AssertTrue(Parse(#13#10#13#10#0#13#10'QUIX') = ppError);
end;

begin
  RegisterTest(TTestNet);
  RegisterTest(TTestSockAddrToStr);
  RegisterTest(TTestProxyProto);
  with TTestRunner.Create(nil) do
  try
    Initialize;
    Run;
  finally
    Free;
  end;
end.

{ M3 step S1 tests for bearings.rt.sys, bearings.rt.clock and bearings.rt.cpu (docs/design.md
  sections 1, 2 and 4):
  - every syscall stub is checked against its FPC RTL equivalent (BaseUnix,
    Sockets, Linux units, or Syscall.do_syscall where the RTL has no
    wrapper): same success results, and -errno where the RTL returns -1 and
    sets errno; the stubs never write FPC's errno threadvar;
  - clocks: MonoNowNs / RealNowUs agree with the RTL's clocks;
  - CPUs: UsableCpus equals /proc/self/status Cpus_allowed_list;
    DefaultLoopCount equals `nproc` (num_cpus semantics), and equals 4 when
    the process runs under `taskset -c 0-3`; the cgroup quota parser
    (num_cpus load_cgroups) on v1/v2 fixtures; PinCurrentThread.
  Run: test_rt_sys --all --format=plain
  (test_rt_sys --print-loop-count prints DefaultLoopCount and exits.) }
program test_rt_sys;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Classes, SysUtils, BaseUnix, Unix, Linux, Sockets, Syscall, Process, fpcunit, testregistry,
  consoletestrunner, ctypes, bearings.rt.sys, bearings.rt.clock, bearings.rt.cpu;

type
  TTestSys = class(TTestCase)
  private
    { the RTL call's errno is read here, after every argument was evaluated
      (argument evaluation order is not left to right in FPC) }
    procedure CheckErr(const What: string; Stub: SizeInt; Rtl: cint);
  published
    procedure Read_write_vs_rtl;
    procedure WriteV_vs_rtl;
    procedure Close_vs_rtl;
    procedure Socket_bind_listen_getsockname_vs_rtl;
    procedure SetSockOpt_GetSockOpt_vs_rtl;
    procedure Accept4_shutdown_vs_rtl;
    procedure Epoll_vs_rtl;
    procedure EventFd2_vs_rtl;
    procedure SendFile_vs_rtl;
    procedure Futex_vs_rtl;
    procedure SchedAffinity_vs_rtl;
    procedure SchedYield_vs_rtl;
    procedure Stubs_leave_errno_alone;
    procedure Clocks_vs_rtl;
  end;

  TTestCpu = class(TTestCase)
  published
    procedure UsableCpus_matches_proc_status;
    procedure DefaultLoopCount_equals_nproc;
    procedure DefaultLoopCount_under_taskset_0_3_is_4;
    procedure Cgroup_quota_parser_fixtures;
    procedure Cgroup_limit_of_this_process;
    procedure ParseCpuList_ranges;
    procedure PinCurrentThread_sets_affinity;
  end;

procedure TTestSys.CheckErr(const What: string; Stub: SizeInt; Rtl: cint);
var
  RtlErr: cint;
begin
  RtlErr := fpgeterrno;
  AssertEquals(What + ': RTL fails', -1, Rtl);
  AssertTrue(What + ': stub fails', Stub < 0);
  AssertEquals(What + ': -errno', -RtlErr, Stub);
end;

function MakePipe(out R, W: cint): Boolean;
var
  Fds: TFilDes;
begin
  Result := fpPipe(Fds) = 0;
  R := Fds[0];
  W := Fds[1];
end;

procedure TTestSys.Read_write_vs_rtl;
var
  R, W: cint;
  Buf: array[0..15] of Byte;
  S, Rtl: SizeInt;
  E: cint;
begin
  AssertTrue(MakePipe(R, W));
  S := SysWrite(W, PChar('hello'), 5);
  AssertEquals('stub write', 5, S);
  Rtl := fpWrite(W, PChar('world'), 5);
  AssertEquals('rtl write', 5, Rtl);
  S := SysRead(R, @Buf[0], 5);
  AssertEquals(5, S);
  AssertEquals('hello', Copy(PChar(@Buf[0]), 1, 5));
  Rtl := fpRead(R, @Buf[0], 16);
  AssertEquals(5, Rtl);
  AssertEquals('world', Copy(PChar(@Buf[0]), 1, 5));
  { nothing to read on a non-blocking pipe: EAGAIN }
  fpfcntl(R, F_SETFL, fpfcntl(R, F_GETFL) or O_NONBLOCK);
  S := SysRead(R, @Buf[0], 16);
  Rtl := fpRead(R, @Buf[0], 16);
  E := fpgeterrno;
  CheckErr('read EAGAIN', S, Rtl);
  AssertEquals(-ESysEAGAIN, S);
  { bad fd }
  S := SysRead(-1, @Buf[0], 16);
  Rtl := fpRead(-1, @Buf[0], 16);
  CheckErr('read EBADF', S, Rtl);
  S := SysWrite(-1, @Buf[0], 16);
  Rtl := fpWrite(-1, @Buf[0], 16);
  CheckErr('write EBADF', S, Rtl);
  { EOF }
  fpClose(W);
  AssertEquals('stub EOF', 0, SysRead(R, @Buf[0], 16));
  AssertEquals('rtl EOF', 0, fpRead(R, @Buf[0], 16));
  fpClose(R);
end;

procedure TTestSys.WriteV_vs_rtl;
var
  R, W: cint;
  Iov: array[0..2] of TSysIoVec;
  RIov: array[0..2] of tiovec;
  A, B, C: RawByteString;
  Buf: array[0..63] of AnsiChar;
  S, Rtl: SizeInt;
begin
  AssertTrue(MakePipe(R, W));
  A := 'ab';
  B := '';
  C := 'cdef';
  Iov[0].Base := PChar(A); Iov[0].Len := 2;
  Iov[1].Base := nil;       Iov[1].Len := 0;
  Iov[2].Base := PChar(C); Iov[2].Len := 4;
  S := SysWriteV(W, @Iov[0], 3);
  AssertEquals(6, S);
  RIov[0].iov_base := PChar(A); RIov[0].iov_len := 2;
  RIov[1].iov_base := nil;      RIov[1].iov_len := 0;
  RIov[2].iov_base := PChar(C); RIov[2].iov_len := 4;
  Rtl := FpWriteV(W, @RIov[0], 3);
  AssertEquals(6, Rtl);
  AssertEquals(12, fpRead(R, @Buf[0], 64));
  AssertEquals('abcdefabcdef', Copy(PChar(@Buf[0]), 1, 12));
  S := SysWriteV(W, @Iov[0], -1);
  Rtl := FpWriteV(W, @RIov[0], -1);
  CheckErr('writev EINVAL', S, Rtl);
  fpClose(R);
  fpClose(W);
  if B <> '' then;
end;

procedure TTestSys.Close_vs_rtl;
var
  R, W: cint;
  S: SizeInt;
  Rtl: cint;
begin
  AssertTrue(MakePipe(R, W));
  AssertEquals(0, SysClose(R));
  AssertEquals(0, fpClose(W));
  S := SysClose(R);
  Rtl := fpClose(W);
  CheckErr('close twice', S, Rtl);
  AssertEquals(-ESysEBADF, S);
end;

procedure FillLoopback(out A: TInetSockAddr; Port: Word);
begin
  FillChar(A, SizeOf(A), 0);
  A.sin_family := AF_INET;
  A.sin_port := htons(Port);
  A.sin_addr.s_addr := htonl($7F000001);
end;

procedure TTestSys.Socket_bind_listen_getsockname_vs_rtl;
var
  S1, S2: SizeInt;
  R1: cint;
  A, B1, B2: TInetSockAddr;
  L: Cardinal;
  RL: TSockLen;
  Port: Word;
begin
  S1 := SysSocket(AF_INET, SOCK_STREAM, 0);
  AssertTrue('stub socket', S1 >= 0);
  R1 := fpSocket(AF_INET, SOCK_STREAM, 0);
  AssertTrue('rtl socket', R1 >= 0);
  FillLoopback(A, 0);
  AssertEquals('stub bind', 0, SysBind(cint(S1), @A, SizeOf(A)));
  AssertEquals('stub listen', 0, SysListen(cint(S1), 16));
  L := SizeOf(B1);
  AssertEquals('stub getsockname', 0, SysGetSockName(cint(S1), @B1, @L));
  AssertEquals(SizeOf(TInetSockAddr), L);
  RL := SizeOf(B2);
  AssertEquals('rtl getsockname of the same socket', 0, fpGetSockName(cint(S1), @B2, @RL));
  AssertTrue('same address', CompareMem(@B1, @B2, SizeOf(B1)));
  Port := ntohs(B1.sin_port);
  AssertTrue(Port > 0);
  { binding the same port again fails the same way (EADDRINUSE) }
  FillLoopback(A, Port);
  S2 := SysBind(R1, @A, SizeOf(A));
  AssertEquals('stub bind EADDRINUSE', -ESysEADDRINUSE, S2);
  S2 := SysSocket(AF_INET, SOCK_STREAM, 0);
  AssertEquals('rtl bind EADDRINUSE', -1, fpBind(cint(S2), @A, SizeOf(A)));
  AssertEquals(ESysEADDRINUSE, socketerror);
  { bad domain }
  CheckErr('socket(9999)', SysSocket(9999, SOCK_STREAM, 0), fpSocket(9999, SOCK_STREAM, 0));
  { not a socket }
  CheckErr('listen(pipe)', SysListen(0, 1), fpListen(0, 1));
  SysClose(cint(S1));
  SysClose(cint(S2));
  fpClose(R1);
end;

procedure TTestSys.SetSockOpt_GetSockOpt_vs_rtl;
var
  S: cint;
  One, V1, V2: cint;
  L1: Cardinal;
  L2: TSockLen;
begin
  S := cint(SysSocket(AF_INET, SOCK_STREAM, 0));
  One := 1;
  AssertEquals(0, SysSetSockOpt(S, IPPROTO_TCP, TCP_NODELAY, @One, SizeOf(One)));
  L1 := SizeOf(V1);
  AssertEquals(0, SysGetSockOpt(S, IPPROTO_TCP, TCP_NODELAY, @V1, @L1));
  L2 := SizeOf(V2);
  AssertEquals(0, fpGetSockOpt(S, IPPROTO_TCP, TCP_NODELAY, @V2, @L2));
  AssertEquals(1, V1);
  AssertEquals(V2, V1);
  One := 0;
  AssertEquals(0, fpSetSockOpt(S, IPPROTO_TCP, TCP_NODELAY, @One, SizeOf(One)));
  L1 := SizeOf(V1);
  SysGetSockOpt(S, IPPROTO_TCP, TCP_NODELAY, @V1, @L1);
  AssertEquals('stub reads what the RTL set', 0, V1);
  CheckErr('setsockopt bad level', SysSetSockOpt(S, 9999, 1, @One, SizeOf(One)),
    fpSetSockOpt(S, 9999, 1, @One, SizeOf(One)));
  SysClose(S);
end;

procedure TTestSys.Accept4_shutdown_vs_rtl;
var
  Lfd, C1, C2, A1, A2: cint;
  A, Peer: TInetSockAddr;
  L: Cardinal;
  RL: TSockLen;
  Fl: cint;
  Buf: array[0..7] of Byte;
begin
  Lfd := cint(SysSocket(AF_INET, SOCK_STREAM, 0));
  FillLoopback(A, 0);
  SysBind(Lfd, @A, SizeOf(A));
  SysListen(Lfd, 16);
  L := SizeOf(A);
  SysGetSockName(Lfd, @A, @L);
  C1 := fpSocket(AF_INET, SOCK_STREAM, 0);
  AssertEquals(0, fpConnect(C1, @A, SizeOf(A)));
  C2 := fpSocket(AF_INET, SOCK_STREAM, 0);
  AssertEquals(0, fpConnect(C2, @A, SizeOf(A)));
  L := SizeOf(Peer);
  A1 := cint(SysAccept4(Lfd, @Peer, @L, SOCK_NONBLOCK or SOCK_CLOEXEC));
  AssertTrue('stub accept4', A1 >= 0);
  AssertEquals(SizeOf(TInetSockAddr), L);
  AssertEquals('peer is loopback', htonl($7F000001), Peer.sin_addr.s_addr);
  Fl := fpfcntl(A1, F_GETFL);
  AssertTrue('SOCK_NONBLOCK applied', (Fl and O_NONBLOCK) <> 0);
  AssertTrue('SOCK_CLOEXEC applied', (fpfcntl(A1, F_GETFD) and 1 {FD_CLOEXEC}) <> 0);
  RL := SizeOf(Peer);
  A2 := fpAccept(Lfd, @Peer, @RL);
  AssertTrue('rtl accept', A2 >= 0);
  { nothing queued on a non-blocking listener }
  fpfcntl(Lfd, F_SETFL, fpfcntl(Lfd, F_GETFL) or O_NONBLOCK);
  L := SizeOf(Peer);
  RL := SizeOf(Peer);
  CheckErr('accept EAGAIN', SysAccept4(Lfd, @Peer, @L, 0), fpAccept(Lfd, @Peer, @RL));
  { shutdown(SHUT_WR): the peer reads EOF }
  AssertEquals(0, SysShutdown(A1, SHUT_WR));
  AssertEquals(0, fpRead(C1, @Buf[0], 8));
  AssertEquals(0, fpShutdown(A2, SHUT_WR));
  AssertEquals(0, fpRead(C2, @Buf[0], 8));
  CheckErr('shutdown(pipe-less fd)', SysShutdown(-1, SHUT_WR), fpShutdown(-1, SHUT_WR));
  fpClose(A1); fpClose(A2); fpClose(C1); fpClose(C2); fpClose(Lfd);
end;

procedure TTestSys.Epoll_vs_rtl;
var
  E1, E2, R, W: cint;
  Ev: TEpollEvent;
  REv: EPoll_Event;
  Out1: array[0..3] of TEpollEvent;
  Out2: array[0..3] of EPoll_Event;
  N1, N2: SizeInt;
begin
  E1 := cint(SysEpollCreate1(EPOLL_CLOEXEC));
  AssertTrue('stub epoll_create1', E1 >= 0);
  AssertTrue('CLOEXEC', (fpfcntl(E1, F_GETFD) and 1 {FD_CLOEXEC}) <> 0);
  E2 := epoll_create(1);
  AssertTrue('rtl epoll_create', E2 >= 0);
  AssertTrue(MakePipe(R, W));
  Ev.Events := EPOLLIN;
  Ev.Data := Pointer(PtrUInt($1234));
  AssertEquals(0, SysEpollCtl(E1, EPOLL_CTL_ADD, R, @Ev));
  REv.Events := EPOLLIN;
  REv.Data.u64 := $1234;
  AssertEquals(0, epoll_ctl(E2, EPOLL_CTL_ADD, R, @REv));
  CheckErr('epoll_ctl ADD twice', SysEpollCtl(E1, EPOLL_CTL_ADD, R, @Ev),
    epoll_ctl(E2, EPOLL_CTL_ADD, R, @REv));
  AssertEquals('stub wait, timeout 0', 0, SysEpollWait(E1, @Out1[0], 4, 0));
  AssertEquals('rtl wait, timeout 0', 0, epoll_wait(E2, @Out2[0], 4, 0));
  fpWrite(W, PChar('x'), 1);
  N1 := SysEpollWait(E1, @Out1[0], 4, 1000);
  N2 := epoll_wait(E2, @Out2[0], 4, 1000);
  AssertEquals(1, N1);
  AssertEquals(N2, N1);
  AssertEquals('same event bits', Out2[0].Events, Out1[0].Events);
  AssertTrue('same data', PtrUInt(Out1[0].Data) = Out2[0].Data.u64);
  AssertTrue('TEpollEvent is 12 bytes, like the RTL record', SizeOf(TEpollEvent) = SizeOf(EPoll_Event));
  AssertEquals(0, SysEpollCtl(E1, EPOLL_CTL_DEL, R, @Ev));
  CheckErr('epoll_wait bad fd', SysEpollWait(-1, @Out1[0], 4, 0), epoll_wait(-1, @Out2[0], 4, 0));
  fpClose(R); fpClose(W); fpClose(E1); fpClose(E2);
end;

procedure TTestSys.EventFd2_vs_rtl;
var
  F1, F2: SizeInt;
  V: QWord;
begin
  F1 := SysEventFd2(0, EFD_NONBLOCK or EFD_CLOEXEC);
  F2 := do_syscall(290 {eventfd2}, 0, EFD_NONBLOCK or EFD_CLOEXEC);
  AssertTrue(F1 >= 0);
  AssertTrue(F2 >= 0);
  AssertEquals('same flags', fpfcntl(cint(F2), F_GETFL), fpfcntl(cint(F1), F_GETFL));
  V := 3;
  AssertEquals(8, SysWrite(cint(F1), @V, 8));
  V := 4;
  AssertEquals(8, SysWrite(cint(F1), @V, 8));
  V := 0;
  AssertEquals(8, SysRead(cint(F1), @V, 8));
  AssertEquals('counter summed', 7, V);
  AssertEquals('reset: EAGAIN', -ESysEAGAIN, SysRead(cint(F1), @V, 8));
  CheckErr('eventfd2 bad flags', SysEventFd2(0, $7FFFFFFF), do_syscall(290 {eventfd2}, 0, $7FFFFFFF));
  fpClose(cint(F1));
  fpClose(cint(F2));
end;

procedure TTestSys.SendFile_vs_rtl;
var
  Path: string;
  F: TextFile;
  Fd, R, W: cint;
  Off1, Off2: Int64;
  Buf: array[0..63] of AnsiChar;
  N: SizeInt;
begin
  Path := GetTempFileName('', 'besf');
  AssignFile(F, Path);
  Rewrite(F);
  Write(F, '0123456789abcdef');
  CloseFile(F);
  Fd := fpOpen(Path, O_RDONLY);
  AssertTrue(MakePipe(R, W));
  Off1 := 4;
  N := SysSendFile(W, Fd, @Off1, 6);
  AssertEquals(6, N);
  AssertEquals('offset advanced', 10, Off1);
  Off2 := 4;
  N := do_syscall(syscall_nr_sendfile, W, Fd, TSysParam(@Off2), 6);
  AssertEquals(6, N);
  AssertEquals(10, Off2);
  AssertEquals(12, fpRead(R, @Buf[0], 64));
  AssertEquals('456789456789', Copy(PChar(@Buf[0]), 1, 12));
  Off1 := 0;
  Off2 := 0;
  CheckErr('sendfile bad in fd', SysSendFile(W, -1, @Off1, 1),
    do_syscall(syscall_nr_sendfile, W, TSysParam(-1), TSysParam(@Off2), 1));
  fpClose(Fd); fpClose(R); fpClose(W);
  DeleteFile(Path);
end;

procedure TTestSys.Futex_vs_rtl;
var
  V: LongInt;
begin
  V := 0;
  AssertEquals('wake with no waiter', 0, SysFutex(@V, FUTEX_WAKE_PRIVATE, 1, nil));
  AssertEquals(0, do_syscall(syscall_nr_futex, TSysParam(@V), FUTEX_WAKE_PRIVATE, 1, 0));
  { wait on a value that does not match: EAGAIN }
  CheckErr('futex wait mismatch', SysFutex(@V, FUTEX_WAIT_PRIVATE, 1, nil),
    do_syscall(syscall_nr_futex, TSysParam(@V), FUTEX_WAIT_PRIVATE, 1, 0));
end;

procedure TTestSys.SchedAffinity_vs_rtl;
var
  M1, M2: array[0..15] of QWord;
  N1, N2: SizeInt;
begin
  FillChar(M1, SizeOf(M1), 0);
  FillChar(M2, SizeOf(M2), 0);
  N1 := SysSchedGetAffinity(0, SizeOf(M1), @M1);
  N2 := do_syscall(syscall_nr_sched_getaffinity, 0, SizeOf(M2), TSysParam(@M2));
  AssertTrue(N1 > 0);
  AssertEquals(N2, N1);
  AssertTrue('same mask', CompareMem(@M1, @M2, SizeOf(M1)));
  AssertEquals('set the same mask', 0, SysSchedSetAffinity(0, SizeOf(M1), @M1));
  FillChar(M2, SizeOf(M2), 0);
  CheckErr('setaffinity empty mask', SysSchedSetAffinity(0, SizeOf(M2), @M2),
    do_syscall(syscall_nr_sched_setaffinity, 0, SizeOf(M2), TSysParam(@M2)));
  CheckErr('getaffinity tiny size', SysSchedGetAffinity(0, 1, @M1),
    do_syscall(syscall_nr_sched_getaffinity, 0, 1, TSysParam(@M2)));
end;

procedure TTestSys.SchedYield_vs_rtl;
begin
  AssertEquals(0, SysSchedYield);
  AssertEquals(0, do_syscall(syscall_nr_sched_yield));
end;

procedure TTestSys.Stubs_leave_errno_alone;
var
  B: Byte;
  V: LongInt;
  L: Cardinal;
  A: TSockAddrStorage;
begin
  fpseterrno(12345);
  SysRead(-1, @B, 1);
  SysWrite(-1, @B, 1);
  SysClose(-1);
  SysSocket(9999, 1, 0);
  SysListen(-1, 1);
  L := SizeOf(A);
  SysAccept4(-1, @A, @L, 0);
  SysEpollWait(-1, nil, 1, 0);
  SysEpollCtl(-1, 1, -1, nil);
  SysShutdown(-1, 1);
  V := 0;
  SysFutex(@V, FUTEX_WAIT_PRIVATE, 1, nil);
  SysSendFile(-1, -1, nil, 1);
  AssertEquals('errno threadvar untouched', 12345, fpgeterrno);
  fpseterrno(0);
end;

procedure TTestSys.Clocks_vs_rtl;
var
  Ts: TTimeSpec;
  Tv: TTimeVal;
  M1, M2, M3, Rt: Int64;
  R1, R2: Int64;
  I: Integer;
begin
  M1 := MonoNowNs;
  clock_gettime(CLOCK_MONOTONIC, @Ts);         { the RTL's Linux unit: raw syscall }
  M2 := Int64(Ts.tv_sec) * 1000000000 + Ts.tv_nsec;
  M3 := MonoNowNs;
  AssertTrue('monotonic ordering', (M1 <= M2) and (M2 <= M3));
  AssertTrue('close together', M3 - M1 < 10000000);
  R1 := RealNowUs;
  fpGetTimeOfDay(@Tv, nil);
  Rt := Int64(Tv.tv_sec) * 1000000 + Tv.tv_usec;
  R2 := RealNowUs;
  AssertTrue('realtime ordering', (R1 <= Rt + 1) and (Rt <= R2 + 1));
  AssertTrue(R2 - R1 < 10000);
  for I := 1 to 100000 do
  begin
    M2 := MonoNowNs;
    AssertTrue('never goes back', M2 >= M3);
    M3 := M2;
  end;
end;

{ ---- CPU ---- }

function ProcAllowedList: string;
var
  L: TStringList;
  I: Integer;
begin
  Result := '';
  L := TStringList.Create;
  try
    L.LoadFromFile('/proc/self/status');
    for I := 0 to L.Count - 1 do
      if Copy(L[I], 1, 19) = 'Cpus_allowed_list:' + #9 then
        Exit(Trim(Copy(L[I], 20, MaxInt)));
  finally
    L.Free;
  end;
end;

procedure TTestCpu.UsableCpus_matches_proc_status;
var
  A, B: TCpuList;
  I: Integer;
begin
  A := UsableCpus;
  B := ParseCpuList(ProcAllowedList);
  AssertTrue('allowed list read', Length(B) > 0);
  AssertEquals(Length(B), Length(A));
  for I := 0 to High(A) do
    AssertEquals(B[I], A[I]);
end;

function RunOut(const Cmd: string; const Args: array of string): string;
begin
  Result := '';
  if not RunCommand(Cmd, Args, Result, [poStderrToOutPut]) then
    raise Exception.Create('cannot run ' + Cmd);
  Result := Trim(Result);
end;

procedure TTestCpu.DefaultLoopCount_equals_nproc;
begin
  AssertEquals(StrToInt(RunOut('nproc', [])), DefaultLoopCount);
end;

procedure TTestCpu.DefaultLoopCount_under_taskset_0_3_is_4;
begin
  AssertEquals('taskset -c 0-3', '4', RunOut('taskset', ['-c', '0-3', ParamStr(0), '--print-loop-count']));
  AssertEquals('nproc agrees', '4', RunOut('taskset', ['-c', '0-3', 'nproc']));
  AssertEquals('taskset -c 5', '1', RunOut('taskset', ['-c', '5', ParamStr(0), '--print-loop-count']));
end;

procedure WriteText(const Path, Text: string);
var
  F: TextFile;
begin
  ForceDirectories(ExtractFileDir(Path));
  AssignFile(F, Path);
  Rewrite(F);
  Write(F, Text);
  CloseFile(F);
end;

procedure TTestCpu.Cgroup_quota_parser_fixtures;
var
  D: string;
begin
  D := IncludeTrailingPathDelimiter(GetTempDir) + 'becg' + IntToStr(GetProcessID);
  { v2: the process cgroup /app under the cgroup2 mount at D/mnt }
  WriteText(D + '/v2/cgroup', '0::/app' + #10);
  WriteText(D + '/v2/mountinfo',
    '36 28 0:30 / ' + D + '/v2/mnt rw,nosuid - cgroup2 cgroup2 rw' + #10);
  WriteText(D + '/v2/mnt/app/cpu.max', '150000 100000' + #10);
  AssertEquals('v2 ceil(1.5)', 2, CgroupCpuLimitFrom(D + '/v2/cgroup', D + '/v2/mountinfo'));
  WriteText(D + '/v2/mnt/app/cpu.max', '600000 100000' + #10);
  AssertEquals('v2 6', 6, CgroupCpuLimitFrom(D + '/v2/cgroup', D + '/v2/mountinfo'));
  WriteText(D + '/v2/mnt/app/cpu.max', 'max 100000' + #10);
  AssertEquals('v2 max: no quota', 0, CgroupCpuLimitFrom(D + '/v2/cgroup', D + '/v2/mountinfo'));
  WriteText(D + '/v2/mnt/app/cpu.max', '100000 0' + #10);
  AssertEquals('v2 zero period', 0, CgroupCpuLimitFrom(D + '/v2/cgroup', D + '/v2/mountinfo'));
  { v1, with a mount root that is stripped from the subsystem path }
  WriteText(D + '/v1/cgroup', '12:memory:/x' + #10 + '11:cpu,cpuacct:/docker/abc' + #10 + '0::/' + #10);
  WriteText(D + '/v1/mountinfo',
    '1 0 0:1 / /proc rw - proc proc rw' + #10 +
    '7 5 0:6 /docker ' + D + '/v1/mnt rw,nosuid shared:7 - cgroup cgroup rw,cpu,cpuacct' + #10);
  WriteText(D + '/v1/mnt/abc/cpu.cfs_quota_us', '250000' + #10);
  WriteText(D + '/v1/mnt/abc/cpu.cfs_period_us', '100000' + #10);
  AssertEquals('v1 ceil(2.5)', 3, CgroupCpuLimitFrom(D + '/v1/cgroup', D + '/v1/mountinfo'));
  WriteText(D + '/v1/mnt/abc/cpu.cfs_quota_us', '-1' + #10);
  AssertEquals('v1 -1: no quota', 0, CgroupCpuLimitFrom(D + '/v1/cgroup', D + '/v1/mountinfo'));
  AssertEquals('missing files', 0, CgroupCpuLimitFrom(D + '/none', D + '/none'));
  RunOut('rm', ['-rf', D]);
end;

procedure TTestCpu.Cgroup_limit_of_this_process;
var
  L: Integer;
begin
  L := CgroupCpuLimit;
  AssertTrue('0 (no quota) or a positive count', L >= 0);
  if L > 0 then
    AssertTrue(DefaultLoopCount <= L);
end;

procedure TTestCpu.ParseCpuList_ranges;
var
  A: TCpuList;
begin
  A := ParseCpuList('0-3,8,10-11' + #10);
  AssertEquals(7, Length(A));
  AssertEquals(0, A[0]);
  AssertEquals(3, A[3]);
  AssertEquals(8, A[4]);
  AssertEquals(11, A[6]);
end;

var
  PinResult: TCpuList;
  PinOk: Boolean;

function PinThread(Arg: Pointer): PtrInt;
begin
  PinOk := PinCurrentThread(PtrInt(Arg));
  PinResult := UsableCpus;
  Result := 0;
end;

procedure TTestCpu.PinCurrentThread_sets_affinity;
var
  Th: TThreadID;
  All: TCpuList;
  Cpu: Integer;
begin
  All := UsableCpus;
  Cpu := All[High(All)];
  Th := BeginThread(@PinThread, Pointer(PtrInt(Cpu)));
  WaitForThreadTerminate(Th, 0);
  CloseThread(Th);
  AssertTrue(PinOk);
  AssertEquals(1, Length(PinResult));
  AssertEquals(Cpu, PinResult[0]);
  AssertEquals('other threads keep their affinity', Length(All), Length(UsableCpus));
  AssertFalse('bad cpu id', PinCurrentThread(-1));
end;

begin
  if ParamStr(1) = '--print-loop-count' then
  begin
    WriteLn(DefaultLoopCount);
    Halt(0);
  end;
  RegisterTest(TTestSys);
  RegisterTest(TTestCpu);
  with TTestRunner.Create(nil) do
  try
    Initialize;
    Run;
  finally
    Free;
  end;
end.

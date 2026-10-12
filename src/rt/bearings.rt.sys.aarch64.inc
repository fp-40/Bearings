{ bearings.rt.sys.aarch64.inc - the Linux aarch64 (ARM64) system call
  routines of bearings.rt.sys (included by it; see the unit header).

  The convention: x8 holds the system call number; the arguments go in x0
  to x5; `svc #0` enters the kernel; x0 returns the result (>= 0, or
  -errno). FPC's calling convention (the AAPCS64) passes the first eight
  arguments in x0 to x7, in order, so the arguments are already in place
  and a routine is `mov x8, #number; svc #0`.

  int arguments (cint, Cardinal) arrive in w0 to w5 with the upper 32 bits
  of the x register undefined. No sign extension is done: the arm64
  kernel's system call wrappers cast each register to the parameter's C
  type (int, unsigned int), which keeps only the low 32 bits. (The x86_64
  routines sign-extend because the x86_64 convention is the same there and
  the extension costs nothing on that side; see bearings.rt.sys.x86_64.inc.)

  The generic system call table has no epoll_wait: SysEpollWait calls
  epoll_pwait with a null signal mask (x4 = 0; x5 = the mask size, unused
  when the mask is null), which is what glibc does on ARM64 too.

  Not run on hardware yet: tests/unit/test_rt_sys checks every routine
  against the FPC RTL under qemu-aarch64 (README.md, "ARM64"). }

function SysRead(Fd: cint; Buf: Pointer; Count: SizeUInt): SizeInt; assembler; nostackframe;
asm
  mov  x8, #63
  svc  #0
end;

function SysWrite(Fd: cint; Buf: Pointer; Count: SizeUInt): SizeInt; assembler; nostackframe;
asm
  mov  x8, #64
  svc  #0
end;

function SysWriteV(Fd: cint; Iov: PSysIoVec; IovCnt: cint): SizeInt; assembler; nostackframe;
asm
  mov  x8, #66
  svc  #0
end;

function SysSendFile(OutFd, InFd: cint; Offset: PInt64; Count: SizeUInt): SizeInt; assembler; nostackframe;
asm
  mov  x8, #71
  svc  #0
end;

function SysAccept4(Fd: cint; Addr: PSockAddrStorage; AddrLen: PCardinal; Flags: cint): SizeInt; assembler; nostackframe;
asm
  mov  x8, #242
  svc  #0
end;

function SysEpollCreate1(Flags: cint): SizeInt; assembler; nostackframe;
asm
  mov  x8, #20
  svc  #0
end;

function SysEpollCtl(EpFd, Op, Fd: cint; Event: PEpollEvent): SizeInt; assembler; nostackframe;
asm
  mov  x8, #21
  svc  #0
end;

{ epoll_pwait(epfd, events, maxevents, timeout, sigmask = nil, sigsetsize) }
function SysEpollWait(EpFd: cint; Events: PEpollEvent; MaxEvents, TimeoutMs: cint): SizeInt; assembler; nostackframe;
asm
  mov  x4, #0
  mov  x5, #8
  mov  x8, #22
  svc  #0
end;

function SysEventFd2(InitVal: Cardinal; Flags: cint): SizeInt; assembler; nostackframe;
asm
  mov  x8, #19
  svc  #0
end;

function SysShutdown(Fd, How: cint): SizeInt; assembler; nostackframe;
asm
  mov  x8, #210
  svc  #0
end;

function SysClose(Fd: cint): SizeInt; assembler; nostackframe;
asm
  mov  x8, #57
  svc  #0
end;

function SysSetSockOpt(Fd, Level, OptName: cint; OptVal: Pointer; OptLen: Cardinal): SizeInt; assembler; nostackframe;
asm
  mov  x8, #208
  svc  #0
end;

function SysGetSockOpt(Fd, Level, OptName: cint; OptVal: Pointer; OptLen: PCardinal): SizeInt; assembler; nostackframe;
asm
  mov  x8, #209
  svc  #0
end;

function SysGetSockName(Fd: cint; Addr: PSockAddrStorage; AddrLen: PCardinal): SizeInt; assembler; nostackframe;
asm
  mov  x8, #204
  svc  #0
end;

function SysBind(Fd: cint; Addr: PSockAddrStorage; AddrLen: Cardinal): SizeInt; assembler; nostackframe;
asm
  mov  x8, #200
  svc  #0
end;

function SysListen(Fd, Backlog: cint): SizeInt; assembler; nostackframe;
asm
  mov  x8, #201
  svc  #0
end;

function SysSocket(Domain, SockType, Protocol: cint): SizeInt; assembler; nostackframe;
asm
  mov  x8, #198
  svc  #0
end;

{ futex(addr, op, val, timeout, addr2 = nil, val3 = 0) }
function SysFutex(Addr: PLongInt; Op: cint; Val: LongInt; TimeoutTs: Pointer): SizeInt; assembler; nostackframe;
asm
  mov  x4, #0
  mov  x5, #0
  mov  x8, #98
  svc  #0
end;

function SysSchedGetAffinity(Pid: cint; CpuSetSize: SizeUInt; Mask: Pointer): SizeInt; assembler; nostackframe;
asm
  mov  x8, #123
  svc  #0
end;

function SysSchedSetAffinity(Pid: cint; CpuSetSize: SizeUInt; Mask: Pointer): SizeInt; assembler; nostackframe;
asm
  mov  x8, #122
  svc  #0
end;

function SysSchedYield: SizeInt; assembler; nostackframe;
asm
  mov  x8, #124
  svc  #0
end;

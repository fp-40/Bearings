{ bearings.rt.sys - raw Linux x86_64 system calls and the constants they need.

  The rest of the runtime (event loop, sockets, workers, synchronization)
  calls the kernel through this unit instead of FPC's BaseUnix/Sockets
  units. Every Sys* routine is a small assembler routine that executes the
  `syscall` instruction directly. The Linux x86_64 convention is: rax holds
  the system call number; the arguments go in rdi, rsi, rdx, r10, r8, r9.
  The SysV calling convention that FPC uses passes the 4th argument in rcx,
  so the routines that take 4 or more arguments copy rcx to r10.

  Result convention: each routine returns the raw kernel value, >= 0 on
  success and -errno on failure (for example -ESysEAGAIN). The routines do
  not set FPC's errno (fpseterrno writes a threadvar) and do not touch the
  Sockets unit's socket-error threadvar, so they cost one system call and
  nothing more. Callers test `Result < 0` and compare -Result with the
  ESys* constants below.

  Threading: the routines have no state; any thread may call any of them.
  tests/unit/test_rt_sys.pas checks each routine against the FPC RTL
  equivalent. }
unit bearings.rt.sys;

{$mode objfpc}{$H+}

interface

uses
  ctypes;

const
  { errno values (asm-generic/errno-base.h, errno.h) }
  ESysEINTR = 4;
  ESysEBADF = 9;
  ESysEAGAIN = 11;
  ESysEFAULT = 14;
  ESysEINVAL = 22;
  ESysENFILE = 23;
  ESysEMFILE = 24;
  ESysEPIPE = 32;
  ESysENOSYS = 38;
  ESysENOTSOCK = 88;
  ESysEADDRINUSE = 98;
  ESysECONNABORTED = 103;
  ESysECONNRESET = 104;
  ESysECONNREFUSED = 111;
  ESysENOBUFS = 105;
  ESysENOMEM = 12;
  ESysETIMEDOUT = 110;

  { epoll(7) event bits and epoll_ctl operations. EPOLLIN/EPOLLOUT mean "the
    fd is readable/writable now". EPOLLRDHUP: the peer shut down its writing
    side. EPOLLET selects edge-triggered mode (report only changes of
    readiness); without it epoll is level-triggered (report the fd on every
    wait while it stays ready). EPOLLEXCLUSIVE: when several epoll instances
    wait on the same fd, wake only one of them instead of all. }
  EPOLLIN = $001;
  EPOLLPRI = $002;
  EPOLLOUT = $004;
  EPOLLERR = $008;
  EPOLLHUP = $010;
  EPOLLRDHUP = $2000;
  EPOLLEXCLUSIVE = 1 shl 28;
  EPOLLET = Cardinal(1) shl 31;
  EPOLL_CTL_ADD = 1;
  EPOLL_CTL_DEL = 2;
  EPOLL_CTL_MOD = 3;
  EPOLL_CLOEXEC = $80000;

  { eventfd }
  EFD_NONBLOCK = $800;
  EFD_CLOEXEC = $80000;

  { sockets }
  AF_INET = 2;
  AF_INET6 = 10;
  SOCK_STREAM = 1;
  SOCK_NONBLOCK = $800;
  SOCK_CLOEXEC = $80000;
  AF_UNIX = 1;
  SOL_SOCKET = 1;
  SO_REUSEADDR = 2;
  SO_ERROR = 4;
  SO_SNDBUF = 7;
  SO_RCVBUF = 8;
  SO_REUSEPORT = 15;
  IPPROTO_TCP = 6;
  TCP_NODELAY = 1;
  SHUT_RD = 0;
  SHUT_WR = 1;
  SHUT_RDWR = 2;

  { futex(2) operations. The _PRIVATE variants are for futexes used only by
    threads of this process, which lets the kernel skip shared-memory
    lookups. }
  FUTEX_WAIT_PRIVATE = 128;
  FUTEX_WAKE_PRIVATE = 129;

  { Size in bytes of the CPU mask passed to sched_getaffinity and
    sched_setaffinity: 1024 CPUs, the same as glibc's cpu_set_t. }
  CPU_SET_BYTES = 128;

  { x86_64 syscall numbers }
  SYS_READ = 0;
  SYS_WRITE = 1;
  SYS_CLOSE = 3;
  SYS_SCHED_YIELD = 24;
  SYS_WRITEV = 20;
  SYS_SENDFILE = 40;
  SYS_SOCKET = 41;
  SYS_SHUTDOWN = 48;
  SYS_BIND = 49;
  SYS_LISTEN = 50;
  SYS_GETSOCKNAME = 51;
  SYS_SETSOCKOPT = 54;
  SYS_GETSOCKOPT = 55;
  SYS_FUTEX = 202;
  SYS_SCHED_SETAFFINITY = 203;
  SYS_SCHED_GETAFFINITY = 204;
  SYS_EPOLL_WAIT = 232;
  SYS_EPOLL_CTL = 233;
  SYS_ACCEPT4 = 288;
  SYS_EVENTFD2 = 290;
  SYS_EPOLL_CREATE1 = 291;

type
  { struct sockaddr_storage (128 bytes): large enough for any socket address
    (IPv4 or IPv6); Family selects which. }
  TSockAddrStorage = record
    Family: Word;
    Data: array[0..125] of Byte;
  end;
  PSockAddrStorage = ^TSockAddrStorage;

  { struct epoll_event. The kernel declares it packed on x86_64 (12 bytes,
    no padding between Events and Data). Data is returned unchanged by
    epoll_wait; the event loop stores its own pointer there. }
  TEpollEvent = packed record
    Events: Cardinal;
    Data: Pointer;
  end;
  PEpollEvent = ^TEpollEvent;

  { struct iovec: one (address, length) piece for writev(2), which writes
    several separate buffers with a single system call. }
  TSysIoVec = record
    Base: Pointer;
    Len: SizeUInt;
  end;
  PSysIoVec = ^TSysIoVec;

{ Each returns the kernel result: >= 0 on success, -errno on failure. }
function SysRead(Fd: cint; Buf: Pointer; Count: SizeUInt): SizeInt;
function SysWrite(Fd: cint; Buf: Pointer; Count: SizeUInt): SizeInt;
function SysWriteV(Fd: cint; Iov: PSysIoVec; IovCnt: cint): SizeInt;
function SysSendFile(OutFd, InFd: cint; Offset: PInt64; Count: SizeUInt): SizeInt;
function SysAccept4(Fd: cint; Addr: PSockAddrStorage; AddrLen: PCardinal; Flags: cint): SizeInt;
function SysEpollCreate1(Flags: cint): SizeInt;
function SysEpollCtl(EpFd, Op, Fd: cint; Event: PEpollEvent): SizeInt;
function SysEpollWait(EpFd: cint; Events: PEpollEvent; MaxEvents, TimeoutMs: cint): SizeInt;
function SysEventFd2(InitVal: Cardinal; Flags: cint): SizeInt;
function SysShutdown(Fd, How: cint): SizeInt;
function SysClose(Fd: cint): SizeInt;
function SysSetSockOpt(Fd, Level, OptName: cint; OptVal: Pointer; OptLen: Cardinal): SizeInt;
function SysGetSockOpt(Fd, Level, OptName: cint; OptVal: Pointer; OptLen: PCardinal): SizeInt;
function SysGetSockName(Fd: cint; Addr: PSockAddrStorage; AddrLen: PCardinal): SizeInt;
function SysBind(Fd: cint; Addr: PSockAddrStorage; AddrLen: Cardinal): SizeInt;
function SysListen(Fd, Backlog: cint): SizeInt;
function SysSocket(Domain, SockType, Protocol: cint): SizeInt;
function SysFutex(Addr: PLongInt; Op: cint; Val: LongInt; TimeoutTs: Pointer): SizeInt;
function SysSchedGetAffinity(Pid: cint; CpuSetSize: SizeUInt; Mask: Pointer): SizeInt;
function SysSchedSetAffinity(Pid: cint; CpuSetSize: SizeUInt; Mask: Pointer): SizeInt;
function SysSchedYield: SizeInt;

implementation

{$asmmode att}

{ int arguments (cint) are sign-extended to 64 bits before the syscall; the
  kernel reads the low 32 bits either way. }

function SysRead(Fd: cint; Buf: Pointer; Count: SizeUInt): SizeInt; assembler; nostackframe;
asm
  movslq %edi, %rdi
  movl   $0, %eax
  syscall
end;

function SysWrite(Fd: cint; Buf: Pointer; Count: SizeUInt): SizeInt; assembler; nostackframe;
asm
  movslq %edi, %rdi
  movl   $1, %eax
  syscall
end;

function SysWriteV(Fd: cint; Iov: PSysIoVec; IovCnt: cint): SizeInt; assembler; nostackframe;
asm
  movslq %edi, %rdi
  movslq %edx, %rdx
  movl   $20, %eax
  syscall
end;

function SysSendFile(OutFd, InFd: cint; Offset: PInt64; Count: SizeUInt): SizeInt; assembler; nostackframe;
asm
  movslq %edi, %rdi
  movslq %esi, %rsi
  movq   %rcx, %r10
  movl   $40, %eax
  syscall
end;

function SysAccept4(Fd: cint; Addr: PSockAddrStorage; AddrLen: PCardinal; Flags: cint): SizeInt; assembler; nostackframe;
asm
  movslq %edi, %rdi
  movslq %ecx, %r10
  movl   $288, %eax
  syscall
end;

function SysEpollCreate1(Flags: cint): SizeInt; assembler; nostackframe;
asm
  movslq %edi, %rdi
  movl   $291, %eax
  syscall
end;

function SysEpollCtl(EpFd, Op, Fd: cint; Event: PEpollEvent): SizeInt; assembler; nostackframe;
asm
  movslq %edi, %rdi
  movslq %esi, %rsi
  movslq %edx, %rdx
  movq   %rcx, %r10
  movl   $233, %eax
  syscall
end;

function SysEpollWait(EpFd: cint; Events: PEpollEvent; MaxEvents, TimeoutMs: cint): SizeInt; assembler; nostackframe;
asm
  movslq %edi, %rdi
  movslq %edx, %rdx
  movslq %ecx, %r10
  movl   $232, %eax
  syscall
end;

function SysEventFd2(InitVal: Cardinal; Flags: cint): SizeInt; assembler; nostackframe;
asm
  movl   %edi, %edi
  movslq %esi, %rsi
  movl   $290, %eax
  syscall
end;

function SysShutdown(Fd, How: cint): SizeInt; assembler; nostackframe;
asm
  movslq %edi, %rdi
  movslq %esi, %rsi
  movl   $48, %eax
  syscall
end;

function SysClose(Fd: cint): SizeInt; assembler; nostackframe;
asm
  movslq %edi, %rdi
  movl   $3, %eax
  syscall
end;

function SysSetSockOpt(Fd, Level, OptName: cint; OptVal: Pointer; OptLen: Cardinal): SizeInt; assembler; nostackframe;
asm
  movslq %edi, %rdi
  movslq %esi, %rsi
  movslq %edx, %rdx
  movq   %rcx, %r10
  movl   %r8d, %r8d
  movl   $54, %eax
  syscall
end;

function SysGetSockOpt(Fd, Level, OptName: cint; OptVal: Pointer; OptLen: PCardinal): SizeInt; assembler; nostackframe;
asm
  movslq %edi, %rdi
  movslq %esi, %rsi
  movslq %edx, %rdx
  movq   %rcx, %r10
  movl   $55, %eax
  syscall
end;

function SysGetSockName(Fd: cint; Addr: PSockAddrStorage; AddrLen: PCardinal): SizeInt; assembler; nostackframe;
asm
  movslq %edi, %rdi
  movl   $51, %eax
  syscall
end;

function SysBind(Fd: cint; Addr: PSockAddrStorage; AddrLen: Cardinal): SizeInt; assembler; nostackframe;
asm
  movslq %edi, %rdi
  movl   %edx, %edx
  movl   $49, %eax
  syscall
end;

function SysListen(Fd, Backlog: cint): SizeInt; assembler; nostackframe;
asm
  movslq %edi, %rdi
  movslq %esi, %rsi
  movl   $50, %eax
  syscall
end;

function SysSocket(Domain, SockType, Protocol: cint): SizeInt; assembler; nostackframe;
asm
  movslq %edi, %rdi
  movslq %esi, %rsi
  movslq %edx, %rdx
  movl   $41, %eax
  syscall
end;

function SysFutex(Addr: PLongInt; Op: cint; Val: LongInt; TimeoutTs: Pointer): SizeInt; assembler; nostackframe;
asm
  movslq %esi, %rsi
  movslq %edx, %rdx
  movq   %rcx, %r10
  xorl   %r8d, %r8d
  xorl   %r9d, %r9d
  movl   $202, %eax
  syscall
end;

function SysSchedGetAffinity(Pid: cint; CpuSetSize: SizeUInt; Mask: Pointer): SizeInt; assembler; nostackframe;
asm
  movslq %edi, %rdi
  movl   $204, %eax
  syscall
end;

function SysSchedSetAffinity(Pid: cint; CpuSetSize: SizeUInt; Mask: Pointer): SizeInt; assembler; nostackframe;
asm
  movslq %edi, %rdi
  movl   $203, %eax
  syscall
end;

function SysSchedYield: SizeInt; assembler; nostackframe;
asm
  movl   $24, %eax
  syscall
end;

end.

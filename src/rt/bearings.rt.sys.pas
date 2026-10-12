{ bearings.rt.sys - raw Linux system calls and the constants they need
  (x86_64 and aarch64).

  The rest of the runtime (event loop, sockets, workers, synchronization)
  calls the kernel through this unit instead of FPC's BaseUnix/Sockets
  units. Every Sys* routine is a small assembler routine that executes the
  system call instruction directly: `syscall` on x86_64
  (bearings.rt.sys.x86_64.inc), `svc #0` on aarch64
  (bearings.rt.sys.aarch64.inc). The two include files hold the routines;
  this unit holds the declarations, the system call numbers of each
  architecture and the constants, which are the same on both (the errno
  values, the socket, epoll, eventfd and futex constants all come from the
  generic Linux headers on x86_64 and aarch64 alike).

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

  { System call numbers. x86_64: arch/x86/entry/syscalls/syscall_64.tbl;
    aarch64: the generic table (include/uapi/asm-generic/unistd.h), which
    has no epoll_wait (epoll_pwait with a null signal mask replaces it). }
  {$ifdef cpux86_64}
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
  {$endif}
  {$ifdef cpuaarch64}
  SYS_READ = 63;
  SYS_WRITE = 64;
  SYS_CLOSE = 57;
  SYS_SCHED_YIELD = 124;
  SYS_WRITEV = 66;
  SYS_SENDFILE = 71;
  SYS_SOCKET = 198;
  SYS_SHUTDOWN = 210;
  SYS_BIND = 200;
  SYS_LISTEN = 201;
  SYS_GETSOCKNAME = 204;
  SYS_SETSOCKOPT = 208;
  SYS_GETSOCKOPT = 209;
  SYS_FUTEX = 98;
  SYS_SCHED_SETAFFINITY = 122;
  SYS_SCHED_GETAFFINITY = 123;
  SYS_EPOLL_PWAIT = 22;
  SYS_EPOLL_CTL = 21;
  SYS_ACCEPT4 = 242;
  SYS_EVENTFD2 = 19;
  SYS_EPOLL_CREATE1 = 20;
  {$endif}

type
  { struct sockaddr_storage (128 bytes): large enough for any socket address
    (IPv4 or IPv6); Family selects which. }
  TSockAddrStorage = record
    Family: Word;
    Data: array[0..125] of Byte;
  end;
  PSockAddrStorage = ^TSockAddrStorage;

  { struct epoll_event. The kernel declares it packed on x86_64 (12 bytes,
    no padding between Events and Data) and with natural alignment
    everywhere else (16 bytes on aarch64: 4 bytes of padding after Events).
    Data is returned unchanged by epoll_wait; the event loop stores its own
    pointer there. }
  TEpollEvent = {$ifdef cpux86_64}packed{$endif} record
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

{$ifdef cpux86_64}
{$i bearings.rt.sys.x86_64.inc}
{$endif}
{$ifdef cpuaarch64}
{$i bearings.rt.sys.aarch64.inc}
{$endif}
{$if not defined(cpux86_64) and not defined(cpuaarch64)}
{$error bearings.rt.sys: no system call routines for this CPU (x86_64 and aarch64 only)}
{$endif}

end.

{ bearings.rt.sys.x86_64.inc - the Linux x86_64 system call routines of
  bearings.rt.sys (included by it; see the unit header). The convention: rax
  holds the system call number; the arguments go in rdi, rsi, rdx, r10, r8,
  r9. The SysV calling convention that FPC uses passes the 4th argument in
  rcx, so the routines that take 4 or more arguments copy rcx to r10. }

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

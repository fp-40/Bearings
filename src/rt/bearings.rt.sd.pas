{ bearings.rt.sd - what a service needs from systemd, without libsystemd:
  socket activation, readiness and status notifications, and the watchdog.

  Socket activation. With a .socket unit, systemd opens the listening
  sockets itself and starts the service with them already open as file
  descriptors 3, 4, ... It describes them in the environment: LISTEN_PID
  is the process id the descriptors were passed to (another process that
  inherits the environment must ignore them), LISTEN_FDS how many there
  are, and LISTEN_FDNAMES, optionally, a colon-separated name per
  descriptor (from the FileDescriptorName= setting). Because systemd keeps
  the sockets open while the service restarts, new connections wait in the
  kernel's accept queue during a restart instead of being refused.
  SdListenFds reads these variables and returns the descriptors, each set
  close-on-exec; it then removes the three variables from the environment,
  so a child process does not take the descriptors for its own.

  Notifications. A service with Type=notify tells systemd when it is ready
  by sending a datagram to the Unix socket named by NOTIFY_SOCKET (a path,
  or an abstract socket name when it starts with '@'). The datagram is a
  text of newline-separated assignments: READY=1 (started), STOPPING=1
  (shutting down), STATUS=text (a line systemctl shows), WATCHDOG=1 (the
  heartbeat). SdNotify sends one such datagram; it does nothing and
  returns False when NOTIFY_SOCKET is not set, so a program can call it
  whether it runs under systemd or not.

  Watchdog. With WatchdogSec= in the unit, systemd sets WATCHDOG_USEC (the
  interval in microseconds) and WATCHDOG_PID (which process must send the
  heartbeat), and restarts the service if no WATCHDOG=1 arrives within the
  interval. SdWatchdogUsec returns the interval when this process is the
  one meant, else 0. The service then sends WATCHDOG=1 about every half
  interval, but only while it is healthy (bearings.server does this for its
  loops).

  Threading: no shared state; every routine may be called from any thread.
  SdListenFds changes the environment and is meant to be called once, at
  start, before other threads exist. }
unit bearings.rt.sd;

{$mode objfpc}{$H+}

interface

uses
  ctypes;

const
  { the first descriptor systemd passes (SD_LISTEN_FDS_START) }
  SD_LISTEN_FDS_START = 3;

type
  TSdFds = array of cint;
  TSdNames = array of RawByteString;

{ The listening sockets systemd passed to this process: Fds[I] is
  descriptor SD_LISTEN_FDS_START + I, set close-on-exec, and Names[I] its
  name from LISTEN_FDNAMES ('' when there is none). Returns the count: 0
  when LISTEN_FDS is not set, is not a number, or LISTEN_PID is not this
  process. Removes LISTEN_PID, LISTEN_FDS and LISTEN_FDNAMES from the
  environment in every case. }
function SdListenFds(out Fds: TSdFds; out Names: TSdNames): Integer;

{ True when NOTIFY_SOCKET is set: systemd expects notifications. }
function SdNotifyEnabled: Boolean;

{ Sends State (for example 'READY=1', or 'STATUS=42 connections' + LF +
  'WATCHDOG=1') to the socket NOTIFY_SOCKET names. False when the variable
  is not set or the send failed. }
function SdNotify(const State: RawByteString): Boolean;

{ The watchdog interval in microseconds, when WATCHDOG_USEC is set and
  WATCHDOG_PID (if set) is this process; else 0. }
function SdWatchdogUsec: Int64;

implementation

uses
  SysUtils, BaseUnix, Sockets, bearings.rt.sys;

{ libc's environment, not the copy the FPC RTL took at start: a value set
  with setenv (a test, a launcher in the same process) is seen too }
function getenv(Name: PAnsiChar): PAnsiChar; cdecl; external 'c';
function unsetenv(Name: PAnsiChar): cint; cdecl; external 'c';

function EnvVar(const Name: RawByteString): RawByteString;
var
  P: PAnsiChar;
begin
  P := getenv(PAnsiChar(Name));
  if P = nil then
    Result := ''
  else
    Result := P;
end;

function SdListenFds(out Fds: TSdFds; out Names: TSdNames): Integer;
var
  PidS, NS, NamesS: RawByteString;
  Pid, N, I, Start, J: Integer;
begin
  Fds := nil;
  Names := nil;
  Result := 0;
  PidS := EnvVar('LISTEN_PID');
  NS := EnvVar('LISTEN_FDS');
  NamesS := EnvVar('LISTEN_FDNAMES');
  unsetenv('LISTEN_PID');
  unsetenv('LISTEN_FDS');
  unsetenv('LISTEN_FDNAMES');
  if (NS = '') or not TryStrToInt(NS, N) or (N <= 0) then
    Exit;
  if not TryStrToInt(PidS, Pid) or (Pid <> FpGetPid) then
    Exit;
  SetLength(Fds, N);
  SetLength(Names, N);
  for I := 0 to N - 1 do
  begin
    Fds[I] := SD_LISTEN_FDS_START + I;
    FpFcntl(Fds[I], F_SETFD, 1);      { FD_CLOEXEC }
  end;
  { names: one per descriptor, separated by ':' }
  Start := 1;
  I := 0;
  for J := 1 to Length(NamesS) + 1 do
    if (J > Length(NamesS)) or (NamesS[J] = ':') then
    begin
      if I < N then
        Names[I] := Copy(NamesS, Start, J - Start);
      Inc(I);
      Start := J + 1;
    end;
  Result := N;
end;

function SdNotifyEnabled: Boolean;
begin
  Result := EnvVar('NOTIFY_SOCKET') <> '';
end;

function SdNotify(const State: RawByteString): Boolean;
var
  Path: RawByteString;
  Addr: TSockAddrStorage;
  AddrLen: Cardinal;
  Fd: cint;
  R: SizeInt;
begin
  Result := False;
  Path := EnvVar('NOTIFY_SOCKET');
  if (Path = '') or (Length(Path) >= 108) or (State = '') then
    Exit;
  FillChar(Addr, SizeOf(Addr), 0);
  Addr.Family := AF_UNIX;
  Move(Path[1], Addr.Data[0], Length(Path));
  AddrLen := SizeOf(Word) + Cardinal(Length(Path));
  if Path[1] = '@' then
    Addr.Data[0] := 0                 { an abstract socket: a leading zero byte, no terminator }
  else
    Inc(AddrLen);                     { a path: zero-terminated }
  Fd := fpSocket(AF_UNIX, SOCK_DGRAM or SOCK_CLOEXEC, 0);
  if Fd < 0 then
    Exit;
  repeat
    R := fpSendTo(Fd, @State[1], Length(State), MSG_NOSIGNAL, @Addr, AddrLen);
  until (R >= 0) or (fpgeterrno <> ESysEINTR);
  fpClose(Fd);
  Result := R = Length(State);
end;

function SdWatchdogUsec: Int64;
var
  S: RawByteString;
  Pid: Integer;
begin
  Result := 0;
  S := EnvVar('WATCHDOG_USEC');
  if (S = '') or not TryStrToInt64(S, Result) or (Result <= 0) then
    Exit(0);
  S := EnvVar('WATCHDOG_PID');
  if (S <> '') and (not TryStrToInt(S, Pid) or (Pid <> FpGetPid)) then
    Exit(0);
end;

end.

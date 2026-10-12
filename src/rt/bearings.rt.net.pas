{ bearings.rt.net - listening sockets, the transport interface and the TCP
  transport.

  A web server keeps one listening socket per port. The kernel completes
  the TCP handshake for new clients and puts each new connection in the
  listening socket's accept queue (its length is the listen(2) backlog);
  accept4(2) takes one connection off the queue and returns a new socket
  for it. TListener does this: it is a loop task registered for EPOLLIN on
  the listening socket, and on each event it accepts up to ACCEPT_BATCH
  connections and hands each new socket to its OnAccept callback (the
  server creates the connection task there). OpenListener creates, binds
  and configures the listening socket.

  TTransport is the byte-stream interface the HTTP/1.1 code reads from and
  writes to: Read, Write, WriteV, SendFile, ShutdownWrite, Close. Every call
  is non-blocking and returns the raw result: > 0 bytes moved, 0 end of
  stream (Read), or -errno. -ESysEAGAIN means "not possible now, wait for
  the next readiness event". TTcpTransport is the implementation for a
  plain TCP socket. A transport may wrap another one (for example a test
  server's byte counter); see Wrapped.

  Readiness rules of TTcpTransport. Connection sockets are registered with
  epoll edge-triggered: epoll reports a socket only when its state changes
  (new data arrived, send-buffer space became free), not on every
  epoll_wait while it stays readable. So the loop remembers what epoll
  reported in TIoSource.Ready, and the transport keeps that set accurate:
    Read      calls read(2) only when Ready * [rdRead, rdReadClosed,
              rdError] <> []. On EAGAIN, or on a short read (0 < n < Len),
              it removes rdRead. A short read is taken to mean that the
              kernel's receive buffer is now empty: read(2) on a TCP socket
              returns all the bytes available, up to Len. The kernel does
              not promise this, but it is how Linux behaves, and new data
              raises a new epoll event anyway.
    Write     calls write(2) only when Ready * [rdWrite, rdWriteClosed,
              rdError] <> []. On EAGAIN or a short write (the send buffer is
              full) it removes rdWrite.
    WriteV    as Write, but only EAGAIN removes rdWrite; a short writev
              keeps it, so the caller tries again and gets EAGAIN if the
              buffer really is full.
    SendFile  as Write; only EAGAIN removes rdWrite.
  The closed and error bits are never removed: once the peer closed or the
  socket failed, every call goes to the kernel and returns the final result.
  When the needed bit is not set the call returns -ESysEAGAIN without a
  system call; the caller then waits until the next epoll event sets the bit
  again. An edge-triggered socket must be used until EAGAIN before waiting,
  or the next edge never comes; these rules guarantee that a missing bit
  always means the kernel said EAGAIN (or a short transfer) since the last
  event.

  Unix domain sockets. A listener can also be a Unix domain socket (a path
  in the file system) instead of a TCP port: TListenSpec.UnixPath selects
  it. A reverse proxy on the same machine connects to the path; no TCP is
  involved. OpenListener creates the socket file (removing a stale one
  left by an earlier run, if it is a socket), sets its permission bits
  (UnixMode) and, when UnixGroup is set, its group. SO_REUSEPORT and
  TCP_NODELAY do not apply to Unix sockets; several loops share one
  listening socket (amSharedExclusive in bearings.server). A connection
  accepted on a Unix socket has no IP address: its peer record has Family
  = AF_UNIX and nothing else, and SockAddrToStr gives ''. Reading, writing
  and sendfile work the same as on TCP sockets, so TTcpTransport serves
  both. RemoveSocketFile deletes the socket file when the server stops.

  Threading: TListener and TTcpTransport belong to one loop and are used
  only on that loop's thread. OpenListener, MakeSockAddr, MakeUnixSockAddr,
  RemoveSocketFile, LookupGroupId, SockAddrPort, SockAddrToStr and
  IgnoreSigPipe have no shared state and can be called from any thread. }
unit bearings.rt.net;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, ctypes, bearings.rt.sys, bearings.rt.timer, bearings.rt.loop;

const
  { At most this many accept4 calls per listener event, so that a flood of
    new connections cannot keep the loop from serving existing ones. The
    listener is level-triggered: if connections are left in the queue, the
    next epoll_wait reports it again. }
  ACCEPT_BATCH = 64;
  { How long the listener stays out of epoll after an accept error such as
    EMFILE (out of file descriptors); see TListener.Pause. }
  ACCEPT_PAUSE_MS = 1000;
  { Linux limit on the number of iovec entries in one writev(2) call. }
  IOV_MAX = 1024;
  { The size of sockaddr_un.sun_path: a Unix socket path holds at most
    UNIX_PATH_MAX - 1 bytes plus the terminating zero. }
  UNIX_PATH_MAX = 108;
  UNIX_MODE_DEFAULT = &660;

type
  { How the loops share the listening port (bearings.server sets them up):
      amReusePort        each loop has its own listening socket on the same
                         port (SO_REUSEPORT); the kernel spreads new
                         connections over the sockets.
      amSharedExclusive  one listening socket; each loop registers its own
                         dup of it with EPOLLEXCLUSIVE, so the kernel wakes
                         one waiting loop per new connection instead of all.
      amSingle           one listener on loop 0 only. }
  TAcceptMode = (amReusePort, amSharedExclusive, amSingle);
  TListenSpec = record
    Host: RawByteString;           { '0.0.0.0', '127.0.0.1', '::' }
    Port: Word;                    { 0 = kernel-assigned }
    Backlog: Integer;              { listen(2) backlog: length of the accept queue }
    Mode: TAcceptMode;
    { TCP_NODELAY: turn off Nagle's algorithm, which delays small writes to
      merge them. Set on the listening socket; Linux copies it to every
      accepted socket. }
    NoDelay: Boolean;
    { A non-empty path selects a Unix domain socket at that path; Host,
      Port and NoDelay are then ignored. The path must be shorter than
      UNIX_PATH_MAX bytes. }
    UnixPath: RawByteString;
    { The permission bits of the socket file (chmod after bind); 0 means
      the default, &660: the owner and the group can connect. }
    UnixMode: Cardinal;
    { A group name; when not empty the socket file's group is changed to
      it (chown), so that for example the reverse proxy's group can
      connect. The process needs to be a member of the group or root. }
    UnixGroup: RawByteString;
    { A listening socket that is already open, for example one systemd
      passed (bearings.rt.sd): a value > 0 makes the server use it instead
      of creating one; Host, Port and UnixPath are then ignored. }
    InheritedFd: cint;
  end;

  { Called on the loop thread for every accepted socket. Fd is non-blocking
    and close-on-exec. The handler sets Fd := -1 as soon as something else
    owns the socket (a task whose destruction closes it). If the handler
    raises, the listener closes Fd when it is still >= 0, counts the failure
    in SetupErrors, logs it at most once per second and keeps accepting; the
    handler must release whatever else it created. }
  TAcceptEvent = procedure(Loop: TLoop; var Fd: cint; const Peer: TSockAddrStorage) of object;

  TListener = class(TIoTask)
  private
    FOnAccept: TAcceptEvent;
    FEvents: Cardinal;
    FLastErrorLogNs, FLastSetupLogNs: Int64;
    FResume: TTimer;               { puts the listener back into epoll after a pause }
    FPaused: Boolean;
    procedure AcceptBatch(Max: Integer);
    procedure AcceptOne(Fd: cint; const Peer: TSockAddrStorage);
    procedure SetupFailed(E: Exception);
    procedure Pause;
    procedure StopResumeTimer;
    procedure CloseFd;
  public
    Accepted: QWord;               { statistics }
    AcceptErrors: QWord;           { accept4 errors other than EAGAIN / EINTR / connection errors }
    SetupErrors: QWord;            { OnAccept raised }
    Pauses: QWord;                 { times the listener was taken out of epoll }
    { Registers Fd with the loop's epoll set with Events: EPOLLIN
      (level-triggered: reported on every epoll_wait while the accept queue
      is not empty), or EPOLLIN or EPOLLEXCLUSIVE for amSharedExclusive.
      Raises when epoll_ctl fails. }
    constructor Create(ALoop: TLoop; Fd: cint; OnAccept: TAcceptEvent;
      Events: Cardinal = EPOLLIN);
    destructor Destroy; override;
    procedure OnIo(Events: Cardinal); override;   { accepts at most ACCEPT_BATCH connections }
    procedure Run; override;
    procedure Abort; override;
    { Server shutdown: accepts every connection already in the queue (until
      EAGAIN), so none of them is reset, then closes the listening socket. }
    procedure DrainAndClose;
    { Called by the loop's timer wheel ACCEPT_PAUSE_MS after Pause: puts the
      listener back into epoll. }
    procedure Resume;
    property Paused: Boolean read FPaused;
  end;

  { A non-blocking byte stream. Raw results: > 0 bytes, 0 end of stream,
    < 0 -errno; -ESysEAGAIN means "try again after the next readiness
    event". }
  TTransport = class
  public
    function Read(Buf: PByte; Len: SizeInt): SizeInt; virtual; abstract;
    function Write(Buf: PByte; Len: SizeInt): SizeInt; virtual; abstract;
    { Writes several buffers (gather write). This default writes only the
      first non-empty slice through Write; transports that can do a real
      writev(2) override it and return True from IsWriteVectored, so the
      caller knows whether merging buffers into one WriteV is worth it. }
    function WriteV(Iov: PSysIoVec; Count: Integer): SizeInt; virtual;
    function IsWriteVectored: Boolean; virtual;              { default False }
    { Copies Count bytes of the file InFd, starting at Offset, to the
      transport with sendfile(2): the kernel moves the data from the page
      cache to the socket without copying it through this process. Advances
      Offset. Default: -ESysENOSYS (not supported, for example a transport
      that must encrypt the bytes); the caller then reads and writes. }
    function SendFile(InFd: cint; var Offset: Int64; Count: SizeInt): SizeInt; virtual;
    function ShutdownWrite: SizeInt; virtual; abstract;      { shutdown(fd, SHUT_WR) }
    procedure Close; virtual; abstract;                      { close(2), no shutdown first }
    { A transport that wraps another one (for example a byte counter used in
      tests) returns the inner one; default nil. The upgrade hand-off
      (TUpgraded.CreateFrom in bearings.rt.stream) follows Wrapped down to the
      socket's readiness source and removes owned wrappers. }
    function Wrapped: TTransport; virtual;
    { The wrapper stops owning Wrapped (it is not freed or closed with the
      wrapper afterwards). Default: nothing. }
    procedure DisownWrapped; virtual;
  end;

  { The transport of a plain TCP socket; follows the readiness rules in the
    unit header. Src points to the TIoSource (fd and readiness bits) of the
    task that owns the socket. The class has no constructor of its own: an
    FPC constructor always gets an implicit exception frame, and
    tools/check-hot-asm.sh requires the TTcpTransport.* routines to have
    none. Create it with TTcpTransport.Create and then set Src
    (NewTcpTransport does both). }
  TTcpTransport = class(TTransport)
  public
    Src: PIoSource;
    function Read(Buf: PByte; Len: SizeInt): SizeInt; override;
    function Write(Buf: PByte; Len: SizeInt): SizeInt; override;
    function WriteV(Iov: PSysIoVec; Count: Integer): SizeInt; override;
    function IsWriteVectored: Boolean; override;             { True: WriteV uses writev(2) }
    function SendFile(InFd: cint; var Offset: Int64; Count: SizeInt): SizeInt; override;
    function ShutdownWrite: SizeInt; override;
    procedure Close; override;
  end;

{ Creates a non-blocking listening socket for Spec: socket, SO_REUSEPORT
  (when ReusePort), SO_REUSEADDR (allows binding the port again while old
  connections are in TIME_WAIT), TCP_NODELAY (when Spec.NoDelay), bind and
  listen. BoundPort is the port actually bound (useful with Port = 0). On
  failure returns False with Errno set and Fd = -1.
  With Spec.UnixPath set: a Unix domain socket. A file already at the path
  is removed first when it is a socket (left by an earlier run); any other
  kind of file makes the bind fail with EADDRINUSE. After the bind the
  file's mode is set to UnixMode (UNIX_MODE_DEFAULT when 0) and, when
  UnixGroup is set, its group to that group (an unknown group name fails
  with EINVAL). ReusePort is ignored and BoundPort is 0. }
function OpenListener(const Spec: TListenSpec; ReusePort: Boolean; out Fd: cint;
  out BoundPort: Word; out Errno: cint): Boolean;

{ Fills Addr with a sockaddr_un for Path; False when Path is empty or too
  long (UNIX_PATH_MAX - 1 bytes at most). }
function MakeUnixSockAddr(const Path: RawByteString; out Addr: TSockAddrStorage;
  out AddrLen: Cardinal): Boolean;
{ Deletes the file at Path when it is a Unix socket (lstat, S_IFSOCK).
  True when it was deleted or there was no file; False when something
  else is at the path (left alone) or the unlink failed. }
function RemoveSocketFile(const Path: RawByteString): Boolean;
{ The numeric id of the group called Name (getgrnam); False when there is
  no such group. }
function LookupGroupId(const Name: RawByteString; out Gid: Cardinal): Boolean;

{ TTcpTransport.Create with Src set. }
function NewTcpTransport(Src: PIoSource): TTcpTransport;

{ Fills Addr for Host:Port (IPv4 dotted quad or an IPv6 address); False when
  Host is not a numeric address. }
function MakeSockAddr(const Host: RawByteString; Port: Word; out Addr: TSockAddrStorage;
  out AddrLen: Cardinal): Boolean;
{ The port of a sockaddr_in / sockaddr_in6 (host order). }
function SockAddrPort(const Addr: TSockAddrStorage): Word;
{ The address of a sockaddr_in / sockaddr_in6 as text: IPv4 dotted quad;
  IPv6 in the RFC 5952 section 4 form (lower-case hex, no leading zeros,
  the longest run of two or more zero groups as '::', the first on a tie;
  no scope id); an IPv4-mapped address (::ffff:a.b.c.d) as the IPv4 dotted
  quad. '' for any other family (AF_UNIX, a zeroed record). }
function SockAddrToStr(const Addr: TSockAddrStorage): RawByteString;

{ Sets SIGPIPE to SIG_IGN for the whole process. Writing to a socket whose
  peer has closed raises SIGPIPE, which by default kills the process; with
  the signal ignored the write returns -EPIPE instead and only that
  connection ends. }
procedure IgnoreSigPipe;

implementation

uses
  BaseUnix, Sockets;

{ ---- TListener ---- }

procedure ListenerResumeProc(T: PTimer);
begin
  TListener(T^.Owner).Resume;
end;

constructor TListener.Create(ALoop: TLoop; Fd: cint; OnAccept: TAcceptEvent; Events: Cardinal);
begin
  inherited Create(ALoop, Fd);
  FOnAccept := OnAccept;
  FEvents := Events;
  TimerInit(@FResume, @ListenerResumeProc, Self);
  if not ALoop.Register(@Src, Events) then
    raise Exception.Create('TListener: epoll_ctl(ADD) failed');
end;

destructor TListener.Destroy;
begin
  StopResumeTimer;
  inherited Destroy;
end;

procedure TListener.StopResumeTimer;
begin
  if (Loop <> nil) and (FResume.Proc <> nil) then
    Loop.Timers.Remove(@FResume);
  FPaused := False;
end;

procedure TListener.Pause;
begin
  { After a resource error (EMFILE, ENFILE, ENOBUFS, ENOMEM) the accept
    queue stays non-empty, so a level-triggered listener would be reported
    by every epoll_wait and the loop would spin at 100 % CPU until
    descriptors are free again. Instead the listener is taken out of epoll
    for ACCEPT_PAUSE_MS; connections wait in the queue meanwhile. }
  if FPaused or (Src.Fd < 0) then
    Exit;
  FPaused := True;
  Inc(Pauses);
  Loop.Unregister(@Src);
  Loop.Timers.Arm(@FResume, Loop.NowMs + ACCEPT_PAUSE_MS);
end;

procedure TListener.Resume;
begin
  if not FPaused then
    Exit;
  FPaused := False;
  if Closed or (Src.Fd < 0) then
    Exit;
  if not Loop.Register(@Src, FEvents) then
  begin
    { try again later (the epoll registration itself needs memory) }
    Inc(AcceptErrors);
    FPaused := True;
    Loop.Timers.Arm(@FResume, Loop.NowMs + ACCEPT_PAUSE_MS);
  end;
  { level-triggered: the next epoll_wait reports a non-empty accept queue }
end;

procedure TListener.SetupFailed(E: Exception);
begin
  Inc(SetupErrors);
  if (FLastSetupLogNs = 0) or (Loop.NowNs - FLastSetupLogNs >= 1000000000) then
  begin
    FLastSetupLogNs := Loop.NowNs;
    WriteLn(StdErr, 'bearings.rt.net: connection setup failed: ', E.ClassName, ': ', E.Message);
  end;
end;

procedure TListener.AcceptOne(Fd: cint; const Peer: TSockAddrStorage);
begin
  { per connection, not per request: one try/except per accepted socket }
  try
    FOnAccept(Loop, Fd, Peer);
  except
    on E: Exception do
    begin
      if Fd >= 0 then
        SysClose(Fd);
      SetupFailed(E);
    end;
  end;
end;

procedure TListener.AcceptBatch(Max: Integer);
var
  I: Integer;
  R: SizeInt;
  Peer: TSockAddrStorage;
  AddrLen: Cardinal;
begin
  I := 0;
  while (Max < 0) or (I < Max) do
  begin
    { a Unix socket's accept4 fills only the family: the rest of the peer
      record must be zero, not stack garbage }
    FillChar(Peer, SizeOf(Peer), 0);
    AddrLen := SizeOf(Peer);
    R := SysAccept4(Src.Fd, @Peer, @AddrLen, SOCK_NONBLOCK or SOCK_CLOEXEC);
    if R >= 0 then
    begin
      Inc(I);
      Inc(Accepted);
      AcceptOne(cint(R), Peer);
      if Closed then
        Exit;
    end
    else if R = -ESysEAGAIN then
      Exit
    else if (R = -ESysEINTR) or (R = -ESysECONNABORTED) or (R = -ESysECONNRESET)
      or (R = -ESysECONNREFUSED) then
      { an interrupted call, or a connection that failed while it waited in
        the queue: only that connection is lost, take the next one }
      Continue
    else
    begin
      { EMFILE / ENFILE / ENOBUFS / ENOMEM, or any other error: log at most
        once per second and stop polling the listener for ACCEPT_PAUSE_MS.
        DrainAndClose (Max < 0) does not pause; it stops here and closes. }
      Inc(AcceptErrors);
      if (FLastErrorLogNs = 0) or (Loop.NowNs - FLastErrorLogNs >= 1000000000) then
      begin
        FLastErrorLogNs := Loop.NowNs;
        WriteLn(StdErr, 'bearings.rt.net: accept4 failed: errno ', -R, '; listener paused for ',
          ACCEPT_PAUSE_MS, ' ms');
      end;
      if Max >= 0 then
        Pause;
      Exit;
    end;
  end;
end;

procedure TListener.OnIo(Events: Cardinal);
begin
  if Closed then
    Exit;
  AcceptBatch(ACCEPT_BATCH);
end;

procedure TListener.Run;
begin
  AcceptBatch(ACCEPT_BATCH);
end;

procedure TListener.CloseFd;
begin
  { amSharedExclusive: every loop's listener is a dup of one socket, and an
    epoll registration belongs to the open file, not to the fd number, so
    closing this fd while the other dups stay open would leave the entry in
    this loop's epoll set. Remove it before the close (a paused listener is
    out of epoll already). }
  if Src.Fd >= 0 then
  begin
    if not FPaused then
      Loop.Unregister(@Src);
    SysClose(Src.Fd);
    Src.Fd := -1;
  end;
  StopResumeTimer;
end;

procedure TListener.Abort;
begin
  CloseFd;
end;

procedure TListener.DrainAndClose;
begin
  AcceptBatch(-1);
  CloseFd;
  Close;
end;

{ ---- TTransport ---- }

function TTransport.WriteV(Iov: PSysIoVec; Count: Integer): SizeInt;
var
  I: Integer;
begin
  for I := 0 to Count - 1 do
    if Iov[I].Len > 0 then
      Exit(Write(Iov[I].Base, SizeInt(Iov[I].Len)));
  Result := Write(nil, 0);
end;

function TTransport.IsWriteVectored: Boolean;
begin
  Result := False;
end;

function TTransport.SendFile(InFd: cint; var Offset: Int64; Count: SizeInt): SizeInt;
begin
  Result := -ESysENOSYS;
end;

function TTransport.Wrapped: TTransport;
begin
  Result := nil;
end;

procedure TTransport.DisownWrapped;
begin
end;

{ ---- TTcpTransport ---- }

function NewTcpTransport(Src: PIoSource): TTcpTransport;
begin
  Result := TTcpTransport.Create;
  Result.Src := Src;
end;

function TTcpTransport.Read(Buf: PByte; Len: SizeInt): SizeInt;
begin
  if Src^.Ready * [rdRead, rdReadClosed, rdError] = [] then
    Exit(-ESysEAGAIN);
  repeat
    Result := SysRead(Src^.Fd, Buf, SizeUInt(Len));
  until Result <> -ESysEINTR;
  if Result = -ESysEAGAIN then
    Exclude(Src^.Ready, rdRead)
  else if (Result > 0) and (Result < Len) then
    Exclude(Src^.Ready, rdRead);              { the socket buffer was drained }
end;

function TTcpTransport.Write(Buf: PByte; Len: SizeInt): SizeInt;
begin
  if Src^.Ready * [rdWrite, rdWriteClosed, rdError] = [] then
    Exit(-ESysEAGAIN);
  repeat
    Result := SysWrite(Src^.Fd, Buf, SizeUInt(Len));
  until Result <> -ESysEINTR;
  if Result = -ESysEAGAIN then
    Exclude(Src^.Ready, rdWrite)
  else if (Result > 0) and (Result < Len) then
    Exclude(Src^.Ready, rdWrite);
end;

function TTcpTransport.WriteV(Iov: PSysIoVec; Count: Integer): SizeInt;
begin
  if Src^.Ready * [rdWrite, rdWriteClosed, rdError] = [] then
    Exit(-ESysEAGAIN);
  if Count > IOV_MAX then
    Count := IOV_MAX;
  repeat
    Result := SysWriteV(Src^.Fd, Iov, Count);
  until Result <> -ESysEINTR;
  if Result = -ESysEAGAIN then
    Exclude(Src^.Ready, rdWrite);             { a short writev keeps rdWrite }
end;

function TTcpTransport.IsWriteVectored: Boolean;
begin
  Result := True;
end;

function TTcpTransport.SendFile(InFd: cint; var Offset: Int64; Count: SizeInt): SizeInt;
begin
  if Src^.Ready * [rdWrite, rdWriteClosed, rdError] = [] then
    Exit(-ESysEAGAIN);
  repeat
    Result := SysSendFile(Src^.Fd, InFd, @Offset, SizeUInt(Count));
  until Result <> -ESysEINTR;
  if Result = -ESysEAGAIN then
    Exclude(Src^.Ready, rdWrite);
end;

function TTcpTransport.ShutdownWrite: SizeInt;
begin
  Result := SysShutdown(Src^.Fd, SHUT_WR);
end;

procedure TTcpTransport.Close;
begin
  if Src^.Fd >= 0 then
  begin
    SysClose(Src^.Fd);
    Src^.Fd := -1;
  end;
end;

{ ---- listeners ---- }

function MakeSockAddr(const Host: RawByteString; Port: Word; out Addr: TSockAddrStorage;
  out AddrLen: Cardinal): Boolean;
var
  A4: in_addr;
  A6: in6_addr;
  S4: PInetSockAddr;
  S6: PInetSockAddr6;
begin
  FillChar(Addr, SizeOf(Addr), 0);
  AddrLen := 0;
  if Pos(':', Host) > 0 then
  begin
    A6 := StrToHostAddr6(Host);
    if (A6.u6_addr32[0] = 0) and (A6.u6_addr32[1] = 0) and (A6.u6_addr32[2] = 0)
      and (A6.u6_addr32[3] = 0) and (Host <> '::') and (Host <> '::0') then
      Exit(False);
    S6 := PInetSockAddr6(@Addr);
    S6^.sin6_family := AF_INET6;
    S6^.sin6_port := htons(Port);
    S6^.sin6_addr := A6;
    AddrLen := SizeOf(TInetSockAddr6);
  end
  else
  begin
    A4 := StrToHostAddr(Host);
    if (A4.s_addr = 0) and (Host <> '0.0.0.0') then
      Exit(False);
    S4 := PInetSockAddr(@Addr);
    S4^.sin_family := AF_INET;
    S4^.sin_port := htons(Port);
    S4^.sin_addr.s_addr := htonl(A4.s_addr);
    AddrLen := SizeOf(TInetSockAddr);
  end;
  Result := True;
end;

function SockAddrPort(const Addr: TSockAddrStorage): Word;
begin
  if Addr.Family = AF_INET6 then
    Result := ntohs(PInetSockAddr6(@Addr)^.sin6_port)
  else
    Result := ntohs(PInetSockAddr(@Addr)^.sin_port);
end;

function Ipv4Str(P: PByte): RawByteString;
begin
  Result := IntToStr(P[0]) + '.' + IntToStr(P[1]) + '.' + IntToStr(P[2]) + '.' + IntToStr(P[3]);
end;

function SockAddrToStr(const Addr: TSockAddrStorage): RawByteString;
var
  A: PByte;
  G: array[0..7] of Word;
  I, BestAt, BestLen, RunAt, RunLen: Integer;
begin
  if Addr.Family = AF_INET then
    Exit(Ipv4Str(@PInetSockAddr(@Addr)^.sin_addr));
  if Addr.Family <> AF_INET6 then
    Exit('');
  A := @PInetSockAddr6(@Addr)^.sin6_addr;
  for I := 0 to 7 do
    G[I] := (Word(A[2 * I]) shl 8) or A[2 * I + 1];
  { ::ffff:a.b.c.d }
  if (G[0] = 0) and (G[1] = 0) and (G[2] = 0) and (G[3] = 0) and (G[4] = 0) and (G[5] = $FFFF) then
    Exit(Ipv4Str(@A[12]));
  BestAt := -1;
  BestLen := 1;                    { a single zero group is not shortened }
  RunAt := -1;
  RunLen := 0;
  for I := 0 to 8 do
    if (I < 8) and (G[I] = 0) then
    begin
      if RunLen = 0 then
        RunAt := I;
      Inc(RunLen);
    end
    else
    begin
      if RunLen > BestLen then
      begin
        BestAt := RunAt;
        BestLen := RunLen;
      end;
      RunLen := 0;
    end;
  Result := '';
  I := 0;
  while I < 8 do
  begin
    if I = BestAt then
    begin
      Result := Result + '::';
      Inc(I, BestLen);
      Continue;
    end;
    if (I > 0) and (I <> BestAt + BestLen) then
      Result := Result + ':';
    Result := Result + LowerCase(IntToHex(G[I], 1));
    Inc(I);
  end;
end;

{ ---- Unix domain sockets ---- }

function MakeUnixSockAddr(const Path: RawByteString; out Addr: TSockAddrStorage;
  out AddrLen: Cardinal): Boolean;
begin
  FillChar(Addr, SizeOf(Addr), 0);
  AddrLen := 0;
  if (Path = '') or (Length(Path) >= UNIX_PATH_MAX) then
    Exit(False);
  Addr.Family := AF_UNIX;
  Move(Path[1], Addr.Data[0], Length(Path));          { sun_path follows the family; zero-terminated }
  AddrLen := SizeOf(Word) + Cardinal(Length(Path)) + 1;
  Result := True;
end;

function RemoveSocketFile(const Path: RawByteString): Boolean;
var
  St: Stat;
begin
  if FpLStat(PAnsiChar(Path), St) <> 0 then
    Exit(fpgeterrno = ESysENOENT);
  if not fpS_ISSOCK(St.st_mode) then
    Exit(False);
  Result := FpUnlink(PAnsiChar(Path)) = 0;
end;

{ libc's getgrnam; struct group is: char *gr_name; char *gr_passwd;
  gid_t gr_gid; char **gr_mem; so gr_gid is at byte offset 16 on x86_64 }
function getgrnam(Name: PAnsiChar): PByte; cdecl; external 'c';

function LookupGroupId(const Name: RawByteString; out Gid: Cardinal): Boolean;
var
  G: PByte;
begin
  Gid := 0;
  if Name = '' then
    Exit(False);
  G := getgrnam(PAnsiChar(Name));
  if G = nil then
    Exit(False);
  Gid := PCardinal(G + 16)^;
  Result := True;
end;

function OpenUnixListener(const Spec: TListenSpec; out Fd: cint; out Errno: cint): Boolean;
var
  Addr: TSockAddrStorage;
  AddrLen: Cardinal;
  R: SizeInt;
  Mode, Gid: Cardinal;

  function Fail(E: cint): Boolean;
  begin
    Errno := E;
    if Fd >= 0 then
      SysClose(Fd);
    Fd := -1;
    Result := False;
  end;

begin
  Fd := -1;
  Errno := 0;
  if not MakeUnixSockAddr(Spec.UnixPath, Addr, AddrLen) then
    Exit(Fail(ESysEINVAL));
  { the group is looked up before anything is created, so a bad name
    leaves no socket file behind }
  Gid := 0;
  if (Spec.UnixGroup <> '') and not LookupGroupId(Spec.UnixGroup, Gid) then
    Exit(Fail(ESysEINVAL));
  R := SysSocket(AF_UNIX, SOCK_STREAM or SOCK_NONBLOCK or SOCK_CLOEXEC, 0);
  if R < 0 then
    Exit(Fail(cint(-R)));
  Fd := cint(R);
  { a socket file left by an earlier run is removed; anything else at the
    path stays, and the bind then fails with EADDRINUSE }
  RemoveSocketFile(Spec.UnixPath);
  R := SysBind(Fd, @Addr, AddrLen);
  if R < 0 then
    Exit(Fail(cint(-R)));
  Mode := Spec.UnixMode;
  if Mode = 0 then
    Mode := UNIX_MODE_DEFAULT;
  if FpChmod(PAnsiChar(Spec.UnixPath), Mode) <> 0 then
  begin
    Errno := fpgeterrno;
    FpUnlink(PAnsiChar(Spec.UnixPath));
    Exit(Fail(Errno));
  end;
  if (Spec.UnixGroup <> '') and (FpChown(PAnsiChar(Spec.UnixPath), TUid(-1), Gid) <> 0) then
  begin
    Errno := fpgeterrno;
    FpUnlink(PAnsiChar(Spec.UnixPath));
    Exit(Fail(Errno));
  end;
  R := SysListen(Fd, Spec.Backlog);
  if R < 0 then
  begin
    FpUnlink(PAnsiChar(Spec.UnixPath));
    Exit(Fail(cint(-R)));
  end;
  Result := True;
end;

function OpenListener(const Spec: TListenSpec; ReusePort: Boolean; out Fd: cint;
  out BoundPort: Word; out Errno: cint): Boolean;
var
  Addr, Bound: TSockAddrStorage;
  AddrLen, BLen: Cardinal;
  One: cint;
  R: SizeInt;

  function Fail(E: SizeInt): Boolean;
  begin
    Errno := cint(-E);
    if Fd >= 0 then
      SysClose(Fd);
    Fd := -1;
    Result := False;
  end;

begin
  Fd := -1;
  BoundPort := 0;
  Errno := 0;
  if Spec.UnixPath <> '' then
    Exit(OpenUnixListener(Spec, Fd, Errno));
  if not MakeSockAddr(Spec.Host, Spec.Port, Addr, AddrLen) then
  begin
    Errno := ESysEINVAL;
    Exit(False);
  end;
  R := SysSocket(Addr.Family, SOCK_STREAM or SOCK_NONBLOCK or SOCK_CLOEXEC, 0);
  if R < 0 then
    Exit(Fail(R));
  Fd := cint(R);
  One := 1;
  { options before bind: SO_REUSEPORT must be set on every socket that
    shares the port before it binds }
  if ReusePort then
  begin
    R := SysSetSockOpt(Fd, SOL_SOCKET, SO_REUSEPORT, @One, SizeOf(One));
    if R < 0 then
      Exit(Fail(R));
  end;
  R := SysSetSockOpt(Fd, SOL_SOCKET, SO_REUSEADDR, @One, SizeOf(One));
  if R < 0 then
    Exit(Fail(R));
  if Spec.NoDelay then
  begin
    R := SysSetSockOpt(Fd, IPPROTO_TCP, TCP_NODELAY, @One, SizeOf(One));
    if R < 0 then
      Exit(Fail(R));
  end;
  R := SysBind(Fd, @Addr, AddrLen);
  if R < 0 then
    Exit(Fail(R));
  R := SysListen(Fd, Spec.Backlog);
  if R < 0 then
    Exit(Fail(R));
  BLen := SizeOf(Bound);
  R := SysGetSockName(Fd, @Bound, @BLen);
  if R < 0 then
    Exit(Fail(R));
  BoundPort := SockAddrPort(Bound);
  Result := True;
end;

procedure IgnoreSigPipe;
begin
  fpSignal(SIGPIPE, SignalHandler(SIG_IGN));
end;

end.

{ bearings.rt.stream - upgraded connections.

  An HTTP/1.1 client can ask to switch the connection to another protocol
  (the Upgrade header, RFC 9110 section 7.8; WebSocket is the common case).
  When the application accepts, the server sends the 101 response and from
  then on the socket carries the other protocol's bytes, which the HTTP code
  must not touch. TUpgraded is the object that takes over the connection at
  that point: the transport (the socket) plus the bytes the HTTP code had
  already read past the end of the upgrade request ("leftover" bytes: the
  client may send its first frames right after the request, and they land in
  the HTTP read buffer).

  Hand-off (CreateFrom). The HTTP connection task (the dispatcher) gives its
  transport and its leftover bytes to a new TUpgraded, which is a loop task
  of its own. The leftover bytes stay where they are, in a pinned view of
  the loop's pooled read-buffer block (bearings.rt.buf): no copy. An owned
  wrapping transport (TTransport.Wrapped, for example a test byte counter)
  is removed and freed, so the upgraded stream talks to the inner transport
  directly. When the innermost transport is the TTcpTransport that reads
  the dispatcher's readiness source, that source (fd and readiness bits)
  moves to the TUpgraded and the epoll registration is changed to point at
  it (EPOLL_CTL_MOD); the dispatcher's Src.Fd becomes -1, so freeing the
  dispatcher does not close the socket.

  Two ways to use the stream after the hand-off:
  - Attach(L): stay on the loop. On every socket event and every Wake the
    task calls L.Readable and then, if the stream is still open and
    attached, L.Writable. The callbacks call TryRead and TryWrite, which
    follow the transport's readiness rules (bearings.rt.net: -EAGAIN without a
    system call when the readiness bit is clear), so a callback with nothing
    to do costs no system call. TryRead returns the leftover bytes first,
    then reads the socket. Attach wakes the task once, so the leftover bytes
    and any readiness already seen are handled without waiting for a new
    event.
  - Detach: leave the loop for blocking use on another thread (for example
    a worker thread that runs a blocking WebSocket handler). Detach runs on
    the loop thread; on success the socket is removed from the loop's epoll
    set and made blocking, the leftover bytes are copied into Rest (a pinned
    view may only be released on the loop thread, so it goes back to the
    pool here), the transport objects are freed without closing the socket,
    and the task is closed. The caller then owns Fd, may use it on any
    thread, and must close it. Only a stream whose socket is its own (the
    innermost transport is the TTcpTransport reading this task's Src) can be
    detached; otherwise Detach returns False and changes nothing.

  Release notice (CloseProc). The server layer counts open connections; an
  upgraded connection still counts. Whoever hands the connection over sets
  CloseProc and CloseArg, and the stream calls CloseProc(CloseArg) once,
  when it is closed or detached (after Detach the caller owns the socket and
  the stream knows nothing more about it).

  Shutdown and abort. A server that stops keeps its upgraded connections
  in a TUpgradedList per loop (Track). At a graceful stop it calls
  Shutdown on each one: the listener's Shutdown method ends the protocol
  politely (for example a WebSocket close frame) and closes the stream
  later; the default closes it at once, since code that does not know the
  protocol cannot do better. When the stream is closed by force (Abort: an
  exception escaped a callback, or the stop's deadline passed), the
  listener's Aborted method runs first, so the listener can release what it
  holds; the stream is closed right after it. The list's OnEmpty runs when
  its last stream is closed or detached.

  Ownership: the upgrade handler owns U from the moment Upgraded(U) is
  called. If Upgraded raises while U is still open and not taken (Taken =
  False), bearings.http.exchange closes U before the exception goes on to the
  loop (which logs it and aborts the delivery task); once the handler
  attached, detached or closed U, an exception leaves U alone.

  Threading: everything here runs on the loop thread that owns the task,
  except what the caller does with the fd returned by Detach. }
unit bearings.rt.stream;

{$mode objfpc}{$H+}

interface

uses
  ctypes, bearings.rt.sys, bearings.rt.loop, bearings.rt.net, bearings.rt.buf;

type
  TUpgraded = class;
  TUpgradedCloseProc = procedure(Arg: Pointer);

  { The upgraded streams of one loop, a doubly linked list through the
    streams' own fields. Loop thread only. }
  PUpgradedList = ^TUpgradedList;
  TUpgradedList = record
    Head: TUpgraded;
    Count: Integer;
    OnEmpty: procedure(List: PUpgradedList) of object;   { called when Count drops to 0 }
  end;

  { Callbacks of an attached TUpgraded, called on the loop thread. Readable:
    the task ran (socket event or Wake); try TryRead. Writable: called after
    Readable; try TryWrite if there is pending output. The defaults do
    nothing.
    Shutdown(U): the server stops gracefully; end the protocol and close U
    when done. Default: U.Close.
    Aborted(U): U is being closed by force (TUpgraded.Abort); release what
    the listener holds and do not use U after it returns (U closes itself
    right after). Default: nothing. }
  TRawListener = class
  public
    procedure Readable(U: TUpgraded); virtual;
    procedure Writable(U: TUpgraded); virtual;
    procedure Shutdown(U: TUpgraded); virtual;
    procedure Aborted(U: TUpgraded); virtual;
  end;

  { The connection after an upgrade: the transport plus the leftover bytes
    read before the hand-off. }
  TUpgraded = class(TIoTask)
  private
    FTransport: TTransport;
    FRest: TBytesView;               { leftover bytes; pinned view into a pooled block }
    FListener: TRawListener;
    FOwnsTransport: Boolean;
    FList: PUpgradedList;            { Track's list; nil when not tracked }
    FPrevUp, FNextUp: TUpgraded;
    procedure NotifyClosed;
    procedure Untrack;
  public
    { called once, with CloseArg, when the stream is closed or detached (nil = none) }
    CloseProc: TUpgradedCloseProc;
    CloseArg: Pointer;
    { The dispatcher's hand-off: takes ATransport and ARest (a pinned view).
      When the innermost transport is a TTcpTransport reading FromSrc, the
      source (fd, readiness) moves to this task and the epoll entry points
      here (EPOLL_CTL_MOD); FromSrc^.Fd becomes -1. AOwnsTransport: this
      task frees the transport objects. }
    constructor CreateFrom(ALoop: TLoop; ATransport: TTransport; const ARest: TBytesView;
      FromSrc: PIoSource; AOwnsTransport: Boolean);
    property Transport: TTransport read FTransport;
    procedure Run; override;
    { closed by force: the listener's Aborted, then Close }
    procedure Abort; override;
    { Adds the stream to List (a server's per-loop list). Loop thread. }
    procedure Track(List: PUpgradedList);
    { the server stops gracefully: the listener's Shutdown, or Close when
      no listener is attached }
    procedure Shutdown;
    property NextTracked: TUpgraded read FNextUp;
    { The leftover bytes, in place (valid until consumed or the stream is
      closed or detached). }
    procedure Leftover(out P: PByte; out Len: SizeInt);
    { Drops the first N leftover bytes; releases the block when none are left. }
    procedure ConsumeLeftover(N: SizeInt);
    { Stay on the loop: L's callbacks run on every event. L = nil removes them. }
    procedure Attach(L: TRawListener);
    function TryRead(Buf: PByte; Max: SizeInt): SizeInt;   { > 0, 0 EOF, -errno }
    function TryWrite(Buf: PByte; Len: SizeInt): SizeInt;
    { Leave the loop: EPOLL_CTL_DEL, make the socket blocking, copy the
      leftover bytes to Rest (pinned views are loop-thread only), close the
      task and return the fd. The caller owns Fd. False (nothing changed)
      when the socket does not belong to this task. }
    function Detach(out Fd: cint; out Rest: RawByteString): Boolean;
    procedure Close;
    { True when the stream is attached to a listener, detached or closed:
      someone took responsibility for it. }
    function Taken: Boolean;
  end;

implementation

uses
  BaseUnix;

procedure TRawListener.Readable(U: TUpgraded);
begin
end;

procedure TRawListener.Writable(U: TUpgraded);
begin
end;

procedure TRawListener.Shutdown(U: TUpgraded);
begin
  U.Close;
end;

procedure TRawListener.Aborted(U: TUpgraded);
begin
end;

constructor TUpgraded.CreateFrom(ALoop: TLoop; ATransport: TTransport; const ARest: TBytesView;
  FromSrc: PIoSource; AOwnsTransport: Boolean);
var
  Ev: TEpollEvent;
  Inner, Tcp: TTransport;
begin
  inherited Create(ALoop, -1);
  { owned wrappers are removed: the upgraded stream uses the transport they
    wrap, so a wrapper's observation (for example byte counting) ends at
    the upgrade }
  if AOwnsTransport and (ATransport <> nil) then
    while ATransport.Wrapped <> nil do
    begin
      Inner := ATransport.Wrapped;
      ATransport.DisownWrapped;
      ATransport.Free;
      ATransport := Inner;
    end;
  FTransport := ATransport;
  FRest := ARest;
  FOwnsTransport := AOwnsTransport;
  { the socket's readiness source moves with the stream, also when a wrapper
    that is not owned stays in front of it }
  Tcp := ATransport;
  while (Tcp <> nil) and (Tcp.Wrapped <> nil) do
    Tcp := Tcp.Wrapped;
  if (Tcp is TTcpTransport) and (FromSrc <> nil)
    and (TTcpTransport(Tcp).Src = FromSrc) then
  begin
    Src.Fd := FromSrc^.Fd;
    Src.Ready := FromSrc^.Ready;
    FromSrc^.Fd := -1;
    TTcpTransport(Tcp).Src := @Src;
    if Src.Fd >= 0 then
    begin
      Ev.Events := EPOLLIN or EPOLLOUT or EPOLLRDHUP or EPOLLET;
      Ev.Data := @Src;
      SysEpollCtl(ALoop.EpFd, EPOLL_CTL_MOD, Src.Fd, @Ev);
    end;
  end;
end;

procedure TUpgraded.Run;
begin
  { a socket event or a Wake: both callbacks; each one tries its operation
    and stops at -EAGAIN (no syscall when the readiness bit is clear) }
  if (FListener = nil) or Closed then
    Exit;
  FListener.Readable(Self);
  if (FListener <> nil) and not Closed then
    FListener.Writable(Self);
end;

procedure TUpgraded.Abort;
var
  L: TRawListener;
begin
  L := FListener;
  FListener := nil;
  if L <> nil then
    L.Aborted(Self);
  Close;
end;

procedure TUpgraded.Track(List: PUpgradedList);
begin
  if (FList <> nil) or Closed then
    Exit;
  FList := List;
  FPrevUp := nil;
  FNextUp := List^.Head;
  if FNextUp <> nil then
    FNextUp.FPrevUp := Self;
  List^.Head := Self;
  Inc(List^.Count);
end;

procedure TUpgraded.Untrack;
var
  L: PUpgradedList;
begin
  L := FList;
  if L = nil then
    Exit;
  if FPrevUp <> nil then
    FPrevUp.FNextUp := FNextUp
  else
    L^.Head := FNextUp;
  if FNextUp <> nil then
    FNextUp.FPrevUp := FPrevUp;
  FPrevUp := nil;
  FNextUp := nil;
  FList := nil;
  Dec(L^.Count);
  if (L^.Count = 0) and Assigned(L^.OnEmpty) then
    L^.OnEmpty(L);
end;

procedure TUpgraded.Shutdown;
begin
  if Closed then
    Exit;
  if FListener <> nil then
    FListener.Shutdown(Self)
  else
    Close;
end;

procedure TUpgraded.Leftover(out P: PByte; out Len: SizeInt);
begin
  P := FRest.P;
  Len := FRest.Len;
end;

procedure TUpgraded.ConsumeLeftover(N: SizeInt);
begin
  if N > FRest.Len then
    N := FRest.Len;
  Inc(FRest.P, N);
  Dec(FRest.Len, N);
  if (FRest.Len = 0) and (FRest.Block <> nil) then
  begin
    FRest.Release;                 { unpin: the read-buffer block can be reused }
    FRest := Default(TBytesView);
  end;
end;

procedure TUpgraded.Attach(L: TRawListener);
begin
  { L = nil detaches the callbacks (the task then ignores events) }
  FListener := L;
  if (L <> nil) and not Closed then
    Wake;                          { one run now: leftover bytes, readiness already seen }
end;

function TUpgraded.TryRead(Buf: PByte; Max: SizeInt): SizeInt;
var
  N: SizeInt;
begin
  { the leftover bytes first, then the socket }
  if Max <= 0 then
    Exit(0);
  if FRest.Len > 0 then
  begin
    N := FRest.Len;
    if N > Max then
      N := Max;
    Move(FRest.P^, Buf^, N);
    ConsumeLeftover(N);
    Exit(N);
  end;
  if FTransport = nil then
    Exit(-ESysEBADF);
  Result := FTransport.Read(Buf, Max);
end;

function TUpgraded.TryWrite(Buf: PByte; Len: SizeInt): SizeInt;
begin
  if FTransport = nil then
    Exit(-ESysEBADF);
  Result := FTransport.Write(Buf, Len);
end;

function TUpgraded.Detach(out Fd: cint; out Rest: RawByteString): Boolean;
var
  Tcp, T, Inner: TTransport;
  Fl: cint;
begin
  Fd := -1;
  Rest := '';
  Result := False;
  if Closed or (FTransport = nil) or (Src.Fd < 0) then
    Exit;
  Tcp := FTransport;
  while Tcp.Wrapped <> nil do
    Tcp := Tcp.Wrapped;
  if not ((Tcp is TTcpTransport) and (TTcpTransport(Tcp).Src = @Src)) then
    Exit;
  Loop.Unregister(@Src);
  Fl := FpFcntl(Src.Fd, F_GETFL);
  if Fl >= 0 then
    FpFcntl(Src.Fd, F_SETFL, Fl and not O_NONBLOCK);
  if FRest.Len > 0 then
    SetString(Rest, PAnsiChar(FRest.P), FRest.Len);
  if FRest.Block <> nil then
    FRest.Release;
  FRest := Default(TBytesView);
  Fd := Src.Fd;
  Src.Fd := -1;                      { the transports below see a closed source }
  FListener := nil;
  { free the transport objects; none of them closes the socket now }
  T := FTransport;
  FTransport := nil;
  if FOwnsTransport then
    while T <> nil do
    begin
      Inner := T.Wrapped;
      T.DisownWrapped;
      T.Free;
      T := Inner;
    end;
  if not Closed then
    inherited Close;
  Untrack;
  NotifyClosed;
  Result := True;
end;

function TUpgraded.Taken: Boolean;
begin
  Result := Closed or (FListener <> nil);
end;

procedure TUpgraded.NotifyClosed;
var
  P: TUpgradedCloseProc;
begin
  P := CloseProc;
  CloseProc := nil;
  if P <> nil then
    P(CloseArg);
end;

procedure TUpgraded.Close;
var
  T: TTransport;
begin
  FListener := nil;
  if FRest.Block <> nil then
    FRest.Release;
  FRest := Default(TBytesView);
  T := FTransport;
  FTransport := nil;
  if T <> nil then
  begin
    T.Close;
    if FOwnsTransport then
      T.Free;
  end;
  if not Closed then
    inherited Close;
  Untrack;
  NotifyClosed;
end;

end.

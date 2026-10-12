{ bearings.server - the HTTP server: configuration, start, stop and graceful
  shutdown.

  A TServer runs N event loops (bearings.rt.loop), each on its own thread, and an
  optional pool of worker threads (bearings.rt.workers) for handlers that may
  block. Each loop has its own listening socket or a share of one (see the
  accept modes below), its own instance of the application's service (the
  TServiceFactory is called once per loop), its own exchange pool and the
  list of its open connections. A connection stays on the loop that
  accepted it: TServerLoop.OnAccept creates a TH1Dispatcher
  (bearings.http1.dispatch), the loop task that reads the requests from the
  socket, calls the service and writes the responses.

  Main types:
    TServerConfig   the options: listen address and accept mode, number of
                    loops, CPU pinning, the HTTP/1 connection options
                    (TH1Config), the worker pool, the grace period.
                    ProductionServerConfig and BenchmarkServerConfig return
                    the two presets.
    TServer         starts and stops the loops and the worker pool.
    TServerLoop     one loop thread and what it owns.

  Use: Create with a configuration and a service factory, Start (it returns
  once the sockets are bound and the threads run; Port gives the bound
  port), later Stop and Wait, then Free. RunUntilSignal does all of this
  for a program that should stop on SIGTERM or SIGINT.

  Accept modes (TListenSpec.Mode, see bearings.rt.net):
    amReusePort        one listening socket per loop, all bound to the same
                       port with SO_REUSEPORT; the kernel spreads the new
                       connections over them. With port 0 the first loop
                       binds a free port and the others bind the port it
                       got.
    amSingle           one listening socket, on loop 0, with the options of
                       the TListenSpec; loop 0 serves every connection.
    amSharedExclusive  one listening socket; every loop registers its own
                       dup of it with EPOLLIN or EPOLLEXCLUSIVE, so the
                       kernel wakes one waiting loop per new connection
                       instead of all of them. SO_REUSEPORT is not set.

  Graceful shutdown. Stop(GraceMs) posts a stop message to every loop and
  returns at once. Each loop then:
    1. accepts the connections still waiting in the listening socket's
       accept queue (accept4 until EAGAIN) and closes the listener. A
       connection that reaches the queue between the last accept4 and the
       close is reset by the kernel; this window cannot be removed.
    2. calls GracefulShutdown on every connection, the ones just accepted
       included: keep-alive is turned off, so an idle connection closes now
       and a connection in the middle of a request closes after its
       response.
    3. leaves its Run when its last connection closed, or when GraceMs
       passed. The connections still open then are aborted
       (TH1Dispatcher.Abort: closed without completion events).
  Wait joins the loop threads and then shuts the worker pool down (queued
  items still run, for up to WorkerWaitMs).

  Signals. RunUntilSignal blocks SIGTERM and SIGINT in the calling thread
  before Start. The loop and worker threads inherit that signal mask, so
  the signals stay pending until the calling thread takes them with
  sigtimedwait; then it calls Stop(Config.GraceMs) and Wait. A Stop from
  elsewhere (a handler, another thread) also ends the wait: it is checked
  every 200 ms, and the result is then 0.

  The worker pool. Start creates it (Config.Workers >= 0) before the
  services, so a service factory can read TServer.Workers.

  Destroy (after the loop threads exited): the connections still open are
  aborted (a worker parked in a body read or a stream write is woken and
  sees the cancel), the worker pool is shut down (queued items finish,
  waiting up to WorkerWaitMs), then the calling thread processes every
  loop's inbox until every exchange is back in its loop's pool and no
  other thread is inside TLoop.Post. Exchanges released by a worker, or by
  another thread that held a reference from TExchange.Share (for example a
  producer of server-sent events), return to their pool through these
  inbox messages. Only then are the loops and pools freed. If workers are
  still running, or exchanges are still held, after the wait, the loops
  and pools are not freed (they leak on purpose): another thread may still
  post to them.

  StartCallerRunsLoop0 / RunLoop0 run loop 0 on the calling thread instead
  of a new thread (the conformance server runs one loop on its main
  thread).

  TConnObserver and TConnParts are declared in bearings.http.exchange,
  TConnOutcome and OutcomeOf in bearings.http.error (declaring them here would
  make the unit references circular); the type names are re-exported here.

  Threading: Create, Start, StartCallerRunsLoop0, RunLoop0, Wait,
  RunUntilSignal and Destroy are called by the thread that owns the
  server. Stop may be called from any thread. GracefulShutdownConnections
  may be called from any thread except a loop thread (it waits until every
  loop has run it). The TServerLoop routines run on their loop thread,
  except AbortConnections and Destroy, which run after that thread
  exited. }
unit bearings.server;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, ctypes, bearings.rt.sys, bearings.rt.cpu, bearings.rt.timer, bearings.rt.loop, bearings.rt.net, bearings.rt.buf,
  bearings.rt.sync, bearings.rt.workers, bearings.http.error, bearings.http.exchange, bearings.http1.config, bearings.http1.dispatch;

type
  TConnOutcome = bearings.http.error.TConnOutcome;
  TConnParts = bearings.http.exchange.TConnParts;
  TConnObserver = bearings.http.exchange.TConnObserver;

  TServerConfig = record
    Listen: TListenSpec;
    Loops: Integer;                  { 0 = DefaultLoopCount }
    PinLoops: Boolean;
    H1: TH1Config;
    Workers: Integer;                { -1 = no pool; 0 = Min(32, cpus + 4) }
    WorkerQueueLimit: Integer;
    WorkerHooks: TWorkerHooks;       { nil = none; not owned }
    WorkerWaitMs: Integer;           { Wait / Destroy: wait for queued and running items (0 = 30 000) }
    GraceMs: Integer;                { the grace period RunUntilSignal passes to Stop }
  end;

  TServer = class;
  TServerEvent = procedure(Server: TServer) of object;

  { One loop thread and what it owns. }
  TServerLoop = class
  private
    FStopTimer: TTimer;
    {$ifdef WD_STALL}
    FStallTimer: TTimer;             { the stall detector's scan, once per second }
    {$endif}
    FGsMsg, FStopMsg: TLoopMsg;
    procedure OnAccept(ALoop: TLoop; var Fd: cint; const Peer: TSockAddrStorage);
    procedure ConnsEmpty(List: PConnList);
  public
    Server: TServer;
    Index: Integer;
    Cpu: Integer;
    Loop: TLoop;
    Listener: TListener;
    Service: THttpService;
    Pool: TExchangePool;
    Conns: TConnList;
    Thread: TThreadID;
    Running: Boolean;
    Stopping: Boolean;
    GraceMs: Integer;
    { the loop thread has exited: drop the connections still open (no completion events) }
    procedure AbortConnections;
    destructor Destroy; override;
  end;

  TServer = class
  private
    FPort: Word;
    FCfg: TServerConfig;
    FFactory: TServiceFactory;
    FObserver: TConnObserver;
    FLoops: array of TServerLoop;
    FStarted, FStopRequested: Boolean;
    FStopClaim: LongInt;           { 1 once a Stop call claimed the stop (any thread) }
    FCallerLoop0: Boolean;
    FGsPending: LongInt;
    FGsEvent: PRTLEvent;
    FGsLock: TRTLCriticalSection;
    FWorkers: TWorkerPool;
    procedure DoStart(CallerRunsLoop0: Boolean);
    function GetLoopCount: Integer;
    function GetLoop(I: Integer): TServerLoop;
  public
    constructor Create(const Cfg: TServerConfig; Factory: TServiceFactory;
      Observer: TConnObserver = nil);
    destructor Destroy; override;
    procedure Start;               { bind, start loops and workers; returns }
    { Start, except that loop 0 gets no thread: the caller runs it with RunLoop0 (the
      conformance server runs one loop on its main thread). Between the two calls the caller may
      register tasks on Loops[0].Loop (nothing runs it yet). }
    procedure StartCallerRunsLoop0;
    { Runs loop 0 on the calling thread until it stops (Stop), after StartCallerRunsLoop0. }
    procedure RunLoop0;
    procedure Wait;                { until every loop thread has exited; at once when not started }
    { GracefulShutdown on every connection open now, on every loop: each one closes after its
      current response (idle ones at once). The listeners keep accepting. Posts an lmCall
      message to each loop and returns after every loop ran it (a countdown and an RTL event).
      Not from a loop thread. }
    procedure GracefulShutdownConnections;
    { Starts the graceful shutdown described in the unit header, with a deadline of GraceMs.
      Returns at once; Wait then joins the loops and shuts the worker pool down. Any thread; a
      second call does nothing. RunUntilSignal calls it on SIGTERM or SIGINT. }
    procedure Stop(GraceMs: Integer);
    { Start, Started(Self) (for example to print Port), wait on this thread for SIGTERM or
      SIGINT, Stop(Config.GraceMs), Wait. Returns the signal number, or 0 when another Stop
      ended the wait. The two signals are blocked in the calling thread from the call on
      (threads started before the call keep their own mask); the previous mask is restored
      before it returns. }
    function RunUntilSignal(Started: TServerEvent = nil): cint;
    property Port: Word read FPort;
    { Start completed (a Start that raised leaves it False) }
    property Started: Boolean read FStarted;
    { the worker pool (Config.Workers >= 0), created by Start before the services; nil otherwise }
    property Workers: TWorkerPool read FWorkers;
    property Config: TServerConfig read FCfg;
    property LoopCount: Integer read GetLoopCount;
    property Loops[I: Integer]: TServerLoop read GetLoop;
  end;

  EServerError = class(Exception);

function ProductionServerConfig: TServerConfig;
function BenchmarkServerConfig: TServerConfig;   { benchmark options: no timer, PipelineFlush, amReusePort }

{$ifdef WD_STALL}
const
  STALL_MS = 60000;
var
  { The stall detector (soak test builds, -dWD_STALL) looks for connections
    the server forgot to wake. Each loop scans its connections once per
    second and reports on stderr, once per connection, every connection
    that is in the middle of a message, has not run for STALL_MS, and is
    waiting on the server rather than on the client
    (TH1Dispatcher.StallCandidate). StallReports counts the reports. }
  StallReports: LongInt = 0;
{$endif}

implementation

uses
  BaseUnix, bearings.rt.clock;

const
  F_DUPFD_CLOEXEC = 1030;

{ ---- TServerLoop ---- }

procedure TServerLoop.AbortConnections;
var
  D: TH1Dispatcher;
begin
  if Loop = nil then
    Exit;
  { the loop thread exited: the calling thread takes its place, so the
    loop-thread checks pass (and TLoop.ProcessInbox may run here later) }
  AtomicStoreThreadId(Loop.ThreadId, GetCurrentThreadId);
  Loop.Timers.Remove(@FStopTimer);
  {$ifdef WD_STALL}
  Loop.Timers.Remove(@FStallTimer);
  {$endif}
  Conns.OnEmpty := nil;
  while Conns.Head <> nil do
  begin
    D := Conns.Head;
    D.Abort;                         { unlinks }
    if not D.Closed then
      D.Close;
  end;
end;

destructor TServerLoop.Destroy;
var
  D: TH1Dispatcher;
begin
  { the loop thread has exited: drop what is left (no events) }
  if Loop <> nil then
  begin
    Loop.Timers.Remove(@FStopTimer);
    {$ifdef WD_STALL}
    Loop.Timers.Remove(@FStallTimer);
    {$endif}
    Conns.OnEmpty := nil;
    while Conns.Head <> nil do
    begin
      D := Conns.Head;
      D.Abort;                       { unlinks }
      if not D.Closed then
        D.Close;
    end;
    if Listener <> nil then
    begin
      Listener.Abort;                { closes the fd }
      if not Listener.Closed then
        Listener.Close;
      Listener := nil;
    end;
  end;
  FreeAndNil(Loop);                  { frees the deferred tasks (connections, listener) }
  FreeAndNil(Service);
  FreeAndNil(Pool);
  inherited Destroy;
end;

procedure TServerLoop.OnAccept(ALoop: TLoop; var Fd: cint; const Peer: TSockAddrStorage);
var
  D: TH1Dispatcher;
  T: TTcpTransport;
  Tr: TTransport;
  Id: QWord;
  Data: Pointer;
  Obs: TConnObserver;
  F: cint;
  SetUp_: Boolean;
begin
  { One connection task (TH1Dispatcher) per accepted socket. The socket is
    registered once, for EPOLLIN | EPOLLOUT | EPOLLRDHUP | EPOLLET, and the
    registration is never modified; epoll reports the socket's readiness
    at once, which runs the dispatcher the first time.
    An exception here affects this connection only: its objects are
    released and the exception goes on to the listener, which counts it,
    logs it at most once per second and keeps accepting. The dispatcher
    owns the fd from its constructor on (a constructor that raises runs
    TIoTask.Destroy, which closes it). }
  D := nil;
  T := nil;
  SetUp_ := False;
  F := Fd;
  Fd := -1;
  try
    Id := ALoop.NextConnId;
    D := TH1Dispatcher.Create(ALoop, F);
    D.Peer := Peer;
    T := NewTcpTransport(@D.Src);
    Tr := T;
    Data := nil;
    Obs := Server.FObserver;
    if Obs <> nil then
    begin
      Data := Obs.OnAccept(ALoop, Id, Peer);
      Tr := Obs.WrapTransport(T, Data);
    end;
    D.Setup(Tr, Service, Server.FCfg.H1, Obs, Id, Data);
    SetUp_ := True;
    D.LinkInto(@Conns);
    if not ALoop.Register(@D.Src, EPOLLIN or EPOLLOUT or EPOLLRDHUP or EPOLLET) then
      raise EServerError.Create('epoll_ctl(ADD) of a connection failed');
    if Stopping then
      D.GracefulShutdown;            { accepted while Stop drains the accept queue }
    { the observer's last call before the first Run (the conformance
      server can start a graceful shutdown of the connection here) }
    if Obs <> nil then
      Obs.OnStart(Id, Data, D);
  except
    if D <> nil then
    begin
      { a transport the dispatcher does not hold yet is freed here (Abort
        frees only Conn.Io.Io) }
      if (not SetUp_) and (T <> nil) then
        T.Free;
      D.Abort;
      if not D.Closed then
        D.Close;
    end;
    raise;
  end;
end;

procedure TServerLoop.ConnsEmpty(List: PConnList);
begin
  if Stopping then
    Loop.StopNow;
end;

{ ---- loop-thread messages ---- }

procedure GsProc(Loop: TLoop; Arg: Pointer);
var
  SL: TServerLoop;
  D: TH1Dispatcher;
begin
  SL := TServerLoop(Arg);
  D := SL.Conns.Head;
  while D <> nil do
  begin
    D.GracefulShutdown;
    D := D.NextConn;
  end;
  if InterlockedDecrement(SL.Server.FGsPending) = 0 then
    RTLEventSetEvent(SL.Server.FGsEvent);
end;

procedure StopTimerProc(T: PTimer);
var
  SL: TServerLoop;
  D: TH1Dispatcher;
begin
  { the grace period is over: abort the connections left (no completion
    events) and leave Run }
  SL := TServerLoop(T^.Owner);
  SL.Conns.OnEmpty := nil;
  while SL.Conns.Head <> nil do
  begin
    D := SL.Conns.Head;
    D.Abort;
    if not D.Closed then
      D.Close;
  end;
  SL.Loop.StopNow;
end;

{$ifdef WD_STALL}
procedure StallTimerProc(T: PTimer);
var
  SL: TServerLoop;
  D: TH1Dispatcher;
begin
  SL := TServerLoop(T^.Owner);
  D := SL.Conns.Head;
  while D <> nil do
  begin
    if (not D.StallReported) and D.StallCandidate(SL.Loop.NowMs, STALL_MS) then
    begin
      D.StallReported := True;
      InterlockedIncrement(StallReports);
      WriteLn(StdErr, 'bearings.server: STALL loop ', SL.Index, ' conn ', D.ConnId, ': mid-message, not run for ',
        SL.Loop.NowMs - D.LastRunMs, ' ms, ', D.StallReason, ' (reading ', Ord(D.Conn.State.Reading),
        ', writing ', Ord(D.Conn.State.Writing), ', buffered ', D.Conn.Io.ReadBuf.Len, ')');
    end;
    D := D.NextConn;
  end;
  SL.Loop.Timers.Arm(@SL.FStallTimer, SL.Loop.NowMs + 1000);
end;
{$endif}

procedure StopProc(Loop: TLoop; Arg: Pointer);
var
  SL: TServerLoop;
  D: TH1Dispatcher;
begin
  SL := TServerLoop(Arg);
  if SL.Stopping then
    Exit;
  SL.Stopping := True;
  if SL.Listener <> nil then
  begin
    { accept until EAGAIN, then close; the connections accepted here get
      GracefulShutdown in OnAccept }
    SL.Listener.DrainAndClose;
    SL.Listener := nil;
  end;
  D := SL.Conns.Head;
  while D <> nil do
  begin
    D.GracefulShutdown;
    D := D.NextConn;
  end;
  if SL.Conns.Count = 0 then
    Loop.StopNow
  else
  begin
    TimerInit(@SL.FStopTimer, @StopTimerProc, SL);
    Loop.Timers.Arm(@SL.FStopTimer, Loop.NowMs + SL.GraceMs);
  end;
end;

function LoopThreadMain(Arg: Pointer): PtrInt;
var
  SL: TServerLoop;
begin
  SL := TServerLoop(Arg);
  if SL.Server.FCfg.PinLoops and (SL.Cpu >= 0) then
    PinCurrentThread(SL.Cpu);
  SL.Loop.Run;
  Result := 0;
end;

{ ---- TServer ---- }

constructor TServer.Create(const Cfg: TServerConfig; Factory: TServiceFactory;
  Observer: TConnObserver);
begin
  inherited Create;
  FCfg := Cfg;
  FFactory := Factory;
  FObserver := Observer;
  FGsEvent := RTLEventCreate;
  InitCriticalSection(FGsLock);
end;

destructor TServer.Destroy;
var
  I, W, Out, Posts: Integer;
  Deadline: Int64;

  procedure LeakLoops;
  begin
    { a worker or a holder of a shared exchange may still post to a loop or
      touch an exchange of its pool: the loops, pools and worker pool are
      left allocated (leaked) instead of freed under them }
    FLoops := nil;
    FWorkers := nil;
    RTLEventDestroy(FGsEvent);
    DoneCriticalSection(FGsLock);
  end;

begin
  if FStarted then
  begin
    if not FStopRequested then
      Stop(0);
    Wait;
  end;
  W := FCfg.WorkerWaitMs;
  if W <= 0 then
    W := 30000;
  { the order described in the unit header }
  for I := 0 to High(FLoops) do
    if FLoops[I] <> nil then
      FLoops[I].AbortConnections;
  if FWorkers <> nil then
  begin
    FWorkers.Shutdown(W);
    if FWorkers.Alive > 0 then
    begin
      WriteLn(StdErr, 'bearings.server: ', FWorkers.Alive, ' worker(s) still running after ', W,
        ' ms; the loops are not freed');
      LeakLoops;
      inherited Destroy;
      Exit;
    end;
  end;
  { A reference that TExchange.Share gave to a thread outside the worker
    pool (for example a producer of server-sent events) may still be held.
    Its Release posts to the loop, and its exchange belongs to the loop's
    pool, so the loops are freed only when every exchange is back in its
    pool. This thread, which takes the loop threads' place, processes the
    inboxes until then, for at most W ms; after that the loops and pools
    are not freed.
    An exchange is back in its pool once its free message was handled, but
    the releasing thread may still be inside TLoop.Post (after the push it
    reads Sleeping and may write the eventfd). So the loops are also not
    freed while a thread is inside Post. A Post can only come from a holder
    (counted in Outstanding) or a worker (gone by now), so the count of
    posts in progress is read after Outstanding, per loop. }
  Deadline := MonoNowNs + Int64(W) * 1000000;
  repeat
    Out := 0;
    Posts := 0;
    for I := 0 to High(FLoops) do
      if (FLoops[I] <> nil) and (FLoops[I].Loop <> nil) then
      begin
        FLoops[I].Loop.ProcessInbox;
        if FLoops[I].Pool <> nil then
          Inc(Out, FLoops[I].Pool.Outstanding);
        Inc(Posts, FLoops[I].Loop.PostsInProgress);
      end;
    if (Out = 0) and (Posts = 0) then
      Break;
    if MonoNowNs > Deadline then
    begin
      WriteLn(StdErr, 'bearings.server: ', Out, ' exchange(s) still held and ', Posts,
        ' post(s) in progress after ', W, ' ms; the loops are not freed');
      if FWorkers <> nil then
        FreeAndNil(FWorkers);
      LeakLoops;
      inherited Destroy;
      Exit;
    end;
    Sleep(1);
  until False;
  if FWorkers <> nil then
    FreeAndNil(FWorkers);
  for I := 0 to High(FLoops) do
    FreeAndNil(FLoops[I]);
  FLoops := nil;
  RTLEventDestroy(FGsEvent);
  DoneCriticalSection(FGsLock);
  inherited Destroy;
end;

function TServer.GetLoopCount: Integer;
begin
  Result := Length(FLoops);
end;

function TServer.GetLoop(I: Integer): TServerLoop;
begin
  Result := FLoops[I];
end;

procedure TServer.Start;
begin
  DoStart(False);
end;

procedure TServer.StartCallerRunsLoop0;
begin
  DoStart(True);
end;

procedure TServer.RunLoop0;
var
  SL: TServerLoop;
begin
  if not (FStarted and FCallerLoop0) then
    raise EServerError.Create('TServer.RunLoop0: call StartCallerRunsLoop0 first');
  SL := FLoops[0];
  if not SL.Running then
    Exit;
  if FCfg.PinLoops and (SL.Cpu >= 0) then
    PinCurrentThread(SL.Cpu);
  SL.Loop.Run;
  SL.Running := False;
end;

procedure TServer.DoStart(CallerRunsLoop0: Boolean);
var
  N, I: Integer;
  Cpus: TCpuList;
  Spec: TListenSpec;
  Fd: cint;
  Bound: Word;
  E: cint;
  Msg: string;
  SL: TServerLoop;
  SharedFd: cint;
  ListenEvents: Cardinal;
begin
  if FStarted then
    raise EServerError.Create('TServer.Start: already started');
  if not ValidateH1Config(FCfg.H1, Msg) then
    raise EServerError.Create('TServer.Start: ' + Msg);
  if not Assigned(FFactory) then
    raise EServerError.Create('TServer.Start: no service factory');
  IgnoreSigPipe;
  N := FCfg.Loops;
  if N <= 0 then
    N := DefaultLoopCount;
  if (FCfg.Workers >= 0) and (FWorkers = nil) then
    FWorkers := TWorkerPool.Create(FCfg.Workers, FCfg.WorkerHooks, FCfg.WorkerQueueLimit);
  Cpus := UsableCpus;
  SetLength(FLoops, N);
  Spec := FCfg.Listen;
  SharedFd := -1;
  if Spec.Mode = amSharedExclusive then
    ListenEvents := EPOLLIN or EPOLLEXCLUSIVE
  else
    ListenEvents := EPOLLIN;
  for I := 0 to N - 1 do
  begin
    SL := TServerLoop.Create;
    FLoops[I] := SL;
    SL.Server := Self;
    SL.Index := I;
    if Length(Cpus) > 0 then
      SL.Cpu := Cpus[I mod Length(Cpus)]
    else
      SL.Cpu := -1;
    SL.GraceMs := FCfg.GraceMs;
    SL.Loop := TLoop.Create(I);
    SL.Pool := TExchangePool.Create;
    SL.Loop.Exchanges := SL.Pool;
    SL.Conns.OnEmpty := @SL.ConnsEmpty;
    SL.FGsMsg.Kind := lmCall;
    SL.FGsMsg.Proc := @GsProc;
    SL.FGsMsg.Arg := SL;
    SL.FStopMsg.Kind := lmCall;
    SL.FStopMsg.Proc := @StopProc;
    SL.FStopMsg.Arg := SL;
    SL.Service := FFactory(SL.Loop);
    {$ifdef WD_STALL}
    { before the loop thread starts: the wheel is the loop thread's from then on }
    TimerInit(@SL.FStallTimer, @StallTimerProc, SL);
    SL.Loop.Timers.Arm(@SL.FStallTimer, MonoNowNs div 1000000 + 1000);
    {$endif}
    if (Spec.Mode = amReusePort) or (I = 0) then
    begin
      if not OpenListener(Spec, Spec.Mode = amReusePort, Fd, Bound, E) then
        raise EServerError.CreateFmt('TServer.Start: listen on %s:%d failed: errno %d',
          [Spec.Host, Spec.Port, E]);
      if Spec.Port = 0 then
        Spec.Port := Bound;          { the first loop binds port 0, the others that port }
      FPort := Bound;
      if Spec.Mode = amSharedExclusive then
        SharedFd := Fd;
      SL.Listener := TListener.Create(SL.Loop, Fd, @SL.OnAccept, ListenEvents);
    end
    else if Spec.Mode = amSharedExclusive then
    begin
      { the same socket through a dup: each loop's TListener closes its own fd }
      Fd := FpFcntl(SharedFd, F_DUPFD_CLOEXEC, 0);
      if Fd < 0 then
        raise EServerError.CreateFmt('TServer.Start: dup of the listener failed: errno %d',
          [fpgeterrno]);
      SL.Listener := TListener.Create(SL.Loop, Fd, @SL.OnAccept, ListenEvents);
    end;
  end;
  FStarted := True;
  FCallerLoop0 := CallerRunsLoop0;
  for I := 0 to N - 1 do
  begin
    FLoops[I].Running := True;
    if (I > 0) or not CallerRunsLoop0 then
      FLoops[I].Thread := BeginThread(@LoopThreadMain, Pointer(FLoops[I]));
  end;
end;

procedure TServer.Wait;
var
  I, W: Integer;
begin
  { a server that never started, or whose Start raised (for example the
    port was in use), has no thread to wait for; a failed Start may have
    left some FLoops entries nil }
  if not FStarted then
    Exit;
  for I := 0 to High(FLoops) do
    if (FLoops[I] <> nil) and FLoops[I].Running and ((I > 0) or not FCallerLoop0) then
    begin
      WaitForThreadTerminate(FLoops[I].Thread, 0);
      CloseThread(FLoops[I].Thread);
      FLoops[I].Running := False;
    end;
  { after a Stop the worker pool is shut down once every loop has left
    Run (each left with no connection, or aborted the rest at the
    deadline, so no new item can be queued); Destroy calls Shutdown again,
    which then has no effect }
  if FStopRequested and (FWorkers <> nil) then
  begin
    for I := 0 to High(FLoops) do
      if (FLoops[I] <> nil) and FLoops[I].Running then
        Exit;
    W := FCfg.WorkerWaitMs;
    if W <= 0 then
      W := 30000;
    FWorkers.Shutdown(W);
  end;
end;

procedure TServer.GracefulShutdownConnections;
var
  I: Integer;
begin
  if not FStarted then
    Exit;
  EnterCriticalSection(FGsLock);
  try
    RTLEventResetEvent(FGsEvent);
    FGsPending := Length(FLoops);
    for I := 0 to High(FLoops) do
      FLoops[I].Loop.Post(@FLoops[I].FGsMsg);
    RTLEventWaitFor(FGsEvent);
  finally
    LeaveCriticalSection(FGsLock);
  end;
end;

procedure TServer.Stop(GraceMs: Integer);
var
  I: Integer;
begin
  { the claim is atomic: two threads calling Stop at once must not post the
    same FStopMsg twice (the message record is itself the inbox node, so a
    second push would corrupt the inbox list) }
  if not FStarted or (InterlockedExchange(FStopClaim, 1) <> 0) then
    Exit;
  FStopRequested := True;
  for I := 0 to High(FLoops) do
  begin
    FLoops[I].GraceMs := GraceMs;
    FLoops[I].Loop.Post(@FLoops[I].FStopMsg);
  end;
end;

function TServer.RunUntilSignal(Started: TServerEvent): cint;
var
  Sigs, Old: TSigSet;
  R: cint;
  Tick: TTimeSpec;
begin
  FpSigEmptySet(Sigs);
  FpSigAddSet(Sigs, SIGTERM);
  FpSigAddSet(Sigs, SIGINT);
  { blocked before Start: the threads Start creates inherit the mask, so the
    signals stay pending for this thread's sigtimedwait }
  FpSigProcMask(SIG_BLOCK, @Sigs, @Old);
  try
    Start;
    if Assigned(Started) then
      Started(Self);
    { a Stop from elsewhere (a handler, another thread) also ends the wait:
      checked every 200 ms; Result is then 0 }
    Tick.tv_sec := 0;
    Tick.tv_nsec := 200 * 1000 * 1000;
    repeat
      R := FpSigTimedWait(Sigs, nil, @Tick);
    until (R > 0) or (InterlockedCompareExchange(FStopClaim, 0, 0) <> 0);
    if R > 0 then
      Result := R
    else
      Result := 0;
    Stop(FCfg.GraceMs);
    Wait;
  finally
    FpSigProcMask(SIG_SETMASK, @Old, nil);
  end;
end;

{ ---- presets ---- }

function ProductionServerConfig: TServerConfig;
begin
  Result := Default(TServerConfig);
  Result.Listen.Host := '0.0.0.0';
  Result.Listen.Port := 8080;
  Result.Listen.Backlog := 4096;
  Result.Listen.Mode := amReusePort;
  Result.Listen.NoDelay := True;
  Result.Loops := 0;
  Result.PinLoops := False;
  Result.H1 := ProductionH1Config;
  Result.Workers := 0;
  Result.WorkerQueueLimit := 0;
  Result.GraceMs := 30000;
end;

function BenchmarkServerConfig: TServerConfig;
begin
  { the options for throughput benchmarks: the base HTTP/1 defaults with
    PipelineFlush, no timer (so no timeouts), upgrades not handed over
    (cmPlain), one SO_REUSEPORT listener per loop, TCP_NODELAY, backlog
    4096, no worker pool }
  Result := Default(TServerConfig);
  Result.Listen.Host := '0.0.0.0';
  Result.Listen.Port := 8080;
  Result.Listen.Backlog := 4096;
  Result.Listen.Mode := amReusePort;
  Result.Listen.NoDelay := True;
  Result.Loops := 0;
  Result.PinLoops := False;
  Result.H1 := ConformanceH1Config;
  Result.H1.PipelineFlush := True;
  Result.H1.Timer := False;
  Result.H1.Mode := cmPlain;
  Result.Workers := -1;
  Result.WorkerQueueLimit := 0;
  Result.GraceMs := 1000;
end;

end.

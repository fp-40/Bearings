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
  for a program that should stop on SIGTERM or SIGINT. The factory and the
  Started callback are methods (TServiceFactory, TServerEvent);
  CreateWithProc and RunUntilSignalProc take plain routines instead
  (TServiceProc, TServerProc), for a program without a holder object.

  The production preset starts a worker pool (Workers = 0). A service that
  answers every request inline never uses it: set Workers to
  NO_WORKER_POOL (-1) and no worker thread is started.

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

  Several listening sockets. Every loop listens on Listen and on each entry
  of AlsoListen (for example a TCP port and a Unix socket, or the sockets
  systemd passed): each entry is set up on its own, with its own accept
  mode. Port is the port of Listen (0 when Listen is a Unix socket).

  Unix domain socket. With Listen.UnixPath set the server listens on a Unix
  socket at that path instead of a TCP port (a reverse proxy on the same
  machine connects to the path). amReusePort cannot apply to a Unix socket
  (there is one path), so Start uses amSharedExclusive instead; amSingle
  works as for TCP. Port is 0. The socket file is created by Start with
  the mode and group of the TListenSpec and removed when loop 0 closes its
  listener during Stop (and by Destroy, should Start have failed after
  creating it). Connections accepted on it have a peer record with Family
  = AF_UNIX and no address (TExchange.PeerAddr; SockAddrToStr gives '');
  behind a proxy the client's address comes from forwarding headers.

  Connection limit. Config.MaxConnections (0 = none) caps the connections
  open at once, over all loops. The count is one atomic integer: each
  listener takes a slot before accept4 (bearings.rt.net) and the connection
  task gives it back when it has released everything (TConnHooks.ConnDone,
  from bearings.http1.dispatch). A connection handed to an upgrade handler
  keeps its slot until the upgraded stream is closed or detached. At the
  limit the listeners leave epoll and new clients wait in the accept queue
  (they are not refused); when a connection closes and the count is below
  the limit again, the closing loop resumes its own listeners and posts a
  message to the other loops to resume theirs. There is no per-IP limit:
  that policy belongs to the reverse proxy or the firewall (behind a
  proxy every connection has the proxy's address); an application that
  faces clients directly can close a connection in TConnObserver.OnAccept,
  which receives the peer address. With the limit off, the accept path
  tests one integer and the connection task one pointer.

  Access log and metrics (bearings.server.accesslog, bearings.server.metrics).
  Both are off by default and hang on the same per-connection hooks as the
  limit (TServerHooks): a request costs one pointer test when they are off,
  and when they are on the loop does the work itself, with no allocation
  and no atomic operation. Config.AccessLog.Enabled writes one line per
  completed request (JSON by default, or a console line) into the
  loop's buffer; a flusher thread writes the buffers to the sink (stdout
  unless the configuration names another). What a line needs from the
  request head (method, target, User-Agent, Referer) is copied when the
  head is read, into a block from the loop's pool, because the head may
  be released before the response is complete. Config.Metrics keeps per-loop
  counters (requests, responses by status class, bytes, a latency
  histogram, connections closed by outcome); TServer.Metrics adds the
  loops together into a TMetricsSnapshot, asking each running loop for its
  copy on its own thread, and PrometheusText renders it. Requests in flight
  are counted at snapshot time: the connections with a service call in
  progress or a response body being written.

  systemd (bearings.rt.sd). Socket activation: a TListenSpec with
  InheritedFd > 0 names a listening socket that is already open, such as
  one systemd passed (LISTEN_FDS); Start uses it instead of creating a
  socket (it sets it non-blocking and close-on-exec, reads its family and
  address with getsockname, and sets TCP_NODELAY when the spec asks for it).
  ApplySdListenFds fills a configuration from the sockets systemd passed:
  Listen gets the first, AlsoListen the others. An inherited Unix socket's
  file belongs to systemd and is not removed. Notifications: when
  NOTIFY_SOCKET is set, Start sends READY=1 once every listener is open
  and the loops run, and Stop sends STOPPING=1. Watchdog: when
  Config.Watchdog is set and WATCHDOG_USEC is in the environment, Start
  also starts a heartbeat thread that sends WATCHDOG=1 every half
  interval, but only while every loop is making progress: each round the
  thread posts a message to every loop and in the next round checks that
  each loop has handled it (a loop blocked in a handler, or stuck, does
  not, and systemd then restarts the service). An idle loop is woken by
  the message, so it counts as alive. The thread stops with Stop and is
  joined by Wait.

  Graceful shutdown. Stop(GraceMs) posts a stop message to every loop and
  returns at once. Each loop then:
    1. accepts the connections still waiting in the listening socket's
       accept queue (accept4 until EAGAIN) and closes the listener. A
       connection that reaches the queue between the last accept4 and the
       close is reset by the kernel; this window cannot be removed.
    2. calls GracefulShutdown on every connection, the ones just accepted
       included: keep-alive is turned off, so an idle connection closes now
       and a connection in the middle of a request closes after its
       response. Upgraded connections (TUpgraded, kept in the loop's
       Upgraded list from the hand-off on) get Shutdown: their listener
       ends its protocol (a WebSocket sends a close frame with 1001) and
       closes them; a stream without a listener is closed at once.
    3. leaves its Run when its last connection and its last upgraded
       connection closed, or when GraceMs passed. The connections still
       open then are aborted (TH1Dispatcher.Abort: closed without
       completion events; TUpgraded.Abort: the listener's Aborted, then
       the stream is closed).
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
  bearings.rt.sync, bearings.rt.workers, bearings.rt.sd, bearings.rt.stream, bearings.http.error, bearings.http.exchange, bearings.http1.config, bearings.http1.dispatch,
  bearings.server.metrics, bearings.server.accesslog;

type
  TConnOutcome = bearings.http.error.TConnOutcome;
  TConnParts = bearings.http.exchange.TConnParts;
  TConnObserver = bearings.http.exchange.TConnObserver;

  { The access log (bearings.server.accesslog). }
  TAccessLogConfig = record
    Enabled: Boolean;
    Format: TAccessLogFormat;        { alfJson (the default) or alfConsole }
    Sink: TLogSink;                  { nil = stdout; not owned }
    BufferBytes: Integer;            { per loop; 0 = 64 KiB }
    FlushMs: Integer;                { the flusher's period; 0 = 100 }
    UserAgent: Boolean;              { include the User-Agent header }
    Referer: Boolean;                { include the Referer header }
    Colors: Boolean;                 { alfConsole: the level in structlog's ANSI color }
    MinLevel: TLogLevel;             { the lines below it are dropped; llDebug (the default) = none }
  end;

  TServerConfig = record
    Listen: TListenSpec;
    { more places to listen on, besides Listen: every loop listens on all
      of them (a TCP port and a Unix socket; the sockets systemd passed) }
    AlsoListen: array of TListenSpec;
    Loops: Integer;                  { 0 = DefaultLoopCount }
    PinLoops: Boolean;
    H1: TH1Config;
    Workers: Integer;                { -1 (NO_WORKER_POOL) = no pool; 0 = Min(32, cpus + 4) }
    WorkerQueueLimit: Integer;
    WorkerHooks: TWorkerHooks;       { nil = none; not owned }
    WorkerWaitMs: Integer;           { Wait / Destroy: wait for queued and running items (0 = 30 000) }
    GraceMs: Integer;                { the grace period RunUntilSignal passes to Stop }
    MaxConnections: Integer;         { connections open at once, all loops; 0 = no limit }
    AccessLog: TAccessLogConfig;
    Metrics: Boolean;                { keep the counters of TServer.Metrics }
    { send the systemd watchdog heartbeat (WATCHDOG=1) while every loop
      makes progress; only when WATCHDOG_USEC is set (bearings.rt.sd) }
    Watchdog: Boolean;
  end;

  TServer = class;
  TServerHooks = class;
  TServerEvent = procedure(Server: TServer) of object;
  TServerProc = procedure(Server: TServer);     { TServerEvent as a plain procedure (RunUntilSignalProc) }

  { One loop thread and what it owns. }
  TServerLoop = class
  private
    FStopTimer: TTimer;
    {$ifdef WD_STALL}
    FStallTimer: TTimer;             { the stall detector's scan, once per second }
    {$endif}
    FGsMsg, FStopMsg: TLoopMsg;
    FWdMsg: TLoopMsg;                { the watchdog's ping (lmCall) }
    FWdTick: LongInt;                { the round number the ping carries (written before Post) }
    FWdSeen: LongInt;                { the last round this loop handled (loop thread writes, watchdog thread reads) }
    FWdPosted: LongInt;              { 1 while a ping is in the inbox }
    FLimitMsg: TLoopMsg;             { resume the listeners paused by the connection limit (lmCall) }
    FLimitPosted: LongInt;           { 1 while FLimitMsg is in the inbox }
    FMetricsMsg: TLoopMsg;           { copy this loop's metrics for a snapshot (lmCall) }
    procedure SnapshotMetrics(var M: TLoopMetrics);   { loop thread, or after the loop exited }
    procedure OnAccept(ALoop: TLoop; var Fd: cint; const Peer: TSockAddrStorage);
    procedure ResumeListeners;       { loop thread: ResumeFromLimit on every listener }
    procedure ConnsEmpty(List: PConnList);
    procedure UpgradedEmpty(List: PUpgradedList);
    procedure AbortUpgraded;
    function GetListener: TListener;
  public
    Server: TServer;
    Index: Integer;
    Cpu: Integer;
    Loop: TLoop;
    { one per listen spec (Listen, then AlsoListen); nil for a spec whose
      socket is on loop 0 only (amSingle) }
    Listeners: array of TListener;
    Service: THttpService;
    Pool: TExchangePool;
    Conns: TConnList;
    { the upgraded connections (for example WebSockets) of this loop: Stop
      asks them to shut down and waits for them like for Conns }
    Upgraded: TUpgradedList;
    Thread: TThreadID;
    Running: Boolean;
    Stopping: Boolean;
    GraceMs: Integer;
    { the loop thread has exited: drop the connections still open (no completion events) }
    procedure AbortConnections;
    destructor Destroy; override;
    property Listener: TListener read GetListener;   { Listeners[0], or nil }
  end;

  TServer = class
  private
    FPort: Word;
    FCfg: TServerConfig;
    FFactory: TServiceFactory;
    FFactoryProc: TServiceProc;    { CreateWithProc's factory; one of the two is assigned }
    FObserver: TConnObserver;
    FLoops: array of TServerLoop;
    FStarted, FStopRequested: Boolean;
    FStopClaim: LongInt;           { 1 once a Stop call claimed the stop (any thread) }
    FCallerLoop0: Boolean;
    FGsPending: LongInt;
    FGsEvent: PRTLEvent;
    FGsLock: TRTLCriticalSection;
    FWorkers: TWorkerPool;
    FUnixPaths: array of RawByteString;   { the socket files Start created; emptied once removed }
    FWdThread: TThreadID;
    FWdStop: PRTLEvent;
    FWdQuit: LongInt;              { 1: the watchdog thread must leave }
    FWdRunning: Boolean;
    FHooks: TServerHooks;          { nil unless a feature needs the per-connection hooks }
    FConnCount: LongInt;           { the connection limit's count (open connections, upgraded ones included) }
    FMetricsPending: LongInt;
    FMetricsEvent: PRTLEvent;
    FMetricsLock: TRTLCriticalSection;
    procedure DoStart(CallerRunsLoop0: Boolean);
    procedure ConnReleased;        { a slot of the connection limit went back; any loop thread }
    procedure RemoveUnixSocket;    { deletes the socket files Start created; idempotent }
    procedure StartWatchdog;
    procedure StopWatchdog;        { asks the thread to leave; JoinWatchdog waits for it }
    procedure JoinWatchdog;
    function DoRunUntilSignal(Started: TServerEvent; StartedProc: TServerProc): cint;
    function GetLoopCount: Integer;
    function GetLoop(I: Integer): TServerLoop;
  public
    constructor Create(const Cfg: TServerConfig; Factory: TServiceFactory;
      Observer: TConnObserver = nil);
    { Create with a plain function (not a method) as the service factory. A separate name
      because the compiler cannot tell the two pointer kinds apart in an overload. }
    constructor CreateWithProc(const Cfg: TServerConfig; Factory: TServiceProc;
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
    { RunUntilSignal with a plain procedure (not a method) as the Started callback }
    function RunUntilSignalProc(Started: TServerProc): cint;
    { the TCP port bound by Listen (Listen.Port, the port the kernel chose for port 0, or the
      inherited socket's port); 0 for a Unix socket }
    property Port: Word read FPort;
    { the watchdog heartbeat thread runs (Config.Watchdog and WATCHDOG_USEC set) }
    property WatchdogRunning: Boolean read FWdRunning;
    { The HTTP connections open now: the sum of the loops' connection lists
      (each written by its loop; the sum is a snapshot). Any thread. }
    function OpenConnections: Integer;
    { The connection limit's count: connections that hold a slot (upgraded
      ones included); 0 when MaxConnections is 0. Any thread. }
    function CountedConnections: Integer;
    { The metrics of every loop added together (Config.Metrics; zeros
      otherwise, with the gauges still filled). A running loop copies its
      counters on its own thread (a message and a wait); after Stop and
      Wait the copies are taken directly. Not from a loop thread. }
    procedure Metrics(out S: TMetricsSnapshot);
    { Metrics as the Prometheus text exposition (bearings.server.metrics). }
    function PrometheusText: RawByteString;
    { the access log, when enabled; nil otherwise }
    function AccessLog: TAccessLog;
    { Start completed (a Start that raised leaves it False) }
    property Started: Boolean read FStarted;
    { the worker pool (Config.Workers >= 0), created by Start before the services; nil otherwise }
    property Workers: TWorkerPool read FWorkers;
    property Config: TServerConfig read FCfg;
    property LoopCount: Integer read GetLoopCount;
    property Loops[I: Integer]: TServerLoop read GetLoop;
  end;

  { The per-connection hooks the server gives the connection tasks when a
    feature needs them (the connection limit): the slot goes back when the
    connection has released everything. }
  TServerHooks = class(TConnHooks)
  public
    Server: TServer;
    MetricsOn: Boolean;
    Metrics: array of TLoopMetrics;  { per loop; written by that loop only }
    Snap: array of TLoopMetrics;     { the copies a snapshot collects }
    Log: TAccessLog;                 { nil when the access log is off }
    LogUserAgent, LogReferer: Boolean;
    destructor Destroy; override;
    procedure RequestStarted(D: TH1Dispatcher); override;
    procedure RequestDone(D: TH1Dispatcher); override;
    procedure ConnDone(D: TH1Dispatcher; Outcome: TConnOutcome; Upgraded: Boolean); override;
    procedure UpgradedClosed; override;
  end;

  EServerError = class(Exception);

const
  { TServerConfig.Workers for a service that never offloads: no worker pool, no worker threads }
  NO_WORKER_POOL = -1;

function ProductionServerConfig: TServerConfig;
function BenchmarkServerConfig: TServerConfig;   { benchmark options: no timer, PipelineFlush, amReusePort }

{ systemd socket activation: when systemd passed listening sockets
  (SdListenFds; LISTEN_FDS), Cfg.Listen gets the first (InheritedFd) and
  Cfg.AlsoListen the others, each with the Backlog, Mode and NoDelay of
  Cfg.Listen; what AlsoListen held is dropped. Returns how many sockets were
  passed; 0 leaves Cfg unchanged (the program then listens as configured). }
function ApplySdListenFds(var Cfg: TServerConfig): Integer;

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
  SO_ACCEPTCONN = 30;
  LF = #10;

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
  AbortUpgraded;
end;

destructor TServerLoop.Destroy;
var
  D: TH1Dispatcher;
  I: Integer;
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
    AbortUpgraded;
    for I := 0 to High(Listeners) do
      if Listeners[I] <> nil then
      begin
        Listeners[I].Abort;          { closes the fd }
        if not Listeners[I].Closed then
          Listeners[I].Close;
        Listeners[I] := nil;
      end;
  end;
  FreeAndNil(Loop);                  { frees the deferred tasks (connections, listeners) }
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
    D.Hooks := Server.FHooks;      { first: an exception below must still release the slot }
    D.UpgradedList := @Upgraded;
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
        frees only Conn.Io.Io); Abort's release calls the hooks }
      if (not SetUp_) and (T <> nil) then
        T.Free;
      D.Abort;
      if not D.Closed then
        D.Close;
    end
    else if Server.FHooks <> nil then
      Server.FHooks.ConnDone(nil, coOther, False);   { no task was created: the slot goes back here }
    raise;
  end;
end;

procedure TServerLoop.ConnsEmpty(List: PConnList);
begin
  if Stopping and (Upgraded.Count = 0) then
    Loop.StopNow;
end;

procedure TServerLoop.UpgradedEmpty(List: PUpgradedList);
begin
  if Stopping and (Conns.Count = 0) then
    Loop.StopNow;
end;

{ closes the upgraded connections left, by force (their listeners' Aborted) }
procedure TServerLoop.AbortUpgraded;
begin
  Upgraded.OnEmpty := nil;
  while Upgraded.Head <> nil do
    Upgraded.Head.Abort;             { unlinks }
end;

procedure TServerLoop.ResumeListeners;
var
  I: Integer;
begin
  for I := 0 to High(Listeners) do
    if Listeners[I] <> nil then
      Listeners[I].ResumeFromLimit;
end;

{ ---- TServerHooks ---- }

type
  { What the access log keeps from the request head until the response is
    complete, in a block from the loop's pool: the lengths, then the bytes
    of the method, the target, the User-Agent and the Referer, one after
    the other (truncated to what the block holds). }
  PLogStage = ^TLogStage;
  TLogStage = record
    Block: PBufBlock;
    MethodLen, TargetLen, UALen, RefLen: SizeInt;
    HasUA, HasRef: Boolean;
    Bytes: array[0..0] of Byte;
  end;

const
  LOG_STAGE_BYTES = 4096;

destructor TServerHooks.Destroy;
begin
  Log.Free;
  inherited Destroy;
end;

{ copies at most Room bytes of P to Dst; returns how many }
function StageCopy(Dst: PByte; Room: SizeInt; P: PByte; Len: SizeInt): SizeInt;
begin
  if Len > Room then
    Len := Room;
  if Len > 0 then
    Move(P^, Dst^, Len);
  Result := Len;
end;

procedure TServerHooks.RequestStarted(D: TH1Dispatcher);
var
  B: PBufBlock;
  St: PLogStage;
  P, Dst: PByte;
  Room, N: SizeInt;
  M, T: TByteSlice;
begin
  if MetricsOn then
    Inc(Metrics[D.Loop.Index].Requests);
  if Log = nil then
    Exit;
  { the head may be gone before RequestDone: copy what the line needs }
  B := PBufBlock(D.HookData);
  if B = nil then
  begin
    B := BlockAlloc(@D.Loop.Blocks, LOG_STAGE_BYTES);
    D.HookData := B;
  end;
  St := PLogStage(B^.Data);
  St^.Block := B;
  Dst := @St^.Bytes[0];
  Room := B^.Size - (Dst - B^.Data);
  M := D.Ex.MethodBytes;
  St^.MethodLen := StageCopy(Dst, Room, M.P, M.Len);
  Inc(Dst, St^.MethodLen);
  Dec(Room, St^.MethodLen);
  T := D.Ex.Target;
  St^.TargetLen := StageCopy(Dst, Room, T.P, T.Len);
  Inc(Dst, St^.TargetLen);
  Dec(Room, St^.TargetLen);
  St^.UALen := 0;
  St^.HasUA := LogUserAgent and D.Ex.Head.Headers.Get('user-agent', P, N);
  if St^.HasUA then
  begin
    St^.UALen := StageCopy(Dst, Room, P, N);
    Inc(Dst, St^.UALen);
    Dec(Room, St^.UALen);
  end;
  St^.RefLen := 0;
  St^.HasRef := LogReferer and D.Ex.Head.Headers.Get('referer', P, N);
  if St^.HasRef then
    St^.RefLen := StageCopy(Dst, Room, P, N);
end;

procedure TServerHooks.RequestDone(D: TH1Dispatcher);
var
  Idx: Integer;
  Dur: Int64;
  St: PLogStage;
  R: TAccessRecord;
  P: PByte;
begin
  Idx := D.Loop.Index;
  Dur := D.Loop.NowNs - D.ReqStartNs;
  if MetricsOn then
    MetricsResponse(Metrics[Idx], D.Ex.Resp.Head.Status, Dur,
      QWord(D.ReqHeadBytes) + D.ReqBodyBytes, QWord(D.Conn.LastHeadBytes) + D.RespBodyBytes);
  if (Log = nil) or (D.HookData = nil) then
    Exit;
  St := PLogStage(PBufBlock(D.HookData)^.Data);
  R.TimeUs := RealNowUs;
  R.Peer := @D.Peer;
  P := @St^.Bytes[0];
  R.Method := P;
  R.MethodLen := St^.MethodLen;
  Inc(P, St^.MethodLen);
  R.Target := P;
  R.TargetLen := St^.TargetLen;
  Inc(P, St^.TargetLen);
  if St^.HasUA then
  begin
    R.UserAgent := P;
    R.UserAgentLen := St^.UALen;
    Inc(P, St^.UALen);
  end
  else
  begin
    R.UserAgent := nil;
    R.UserAgentLen := 0;
  end;
  if St^.HasRef then
  begin
    R.Referer := P;
    R.RefererLen := St^.RefLen;
  end
  else
  begin
    R.Referer := nil;
    R.RefererLen := 0;
  end;
  { the response head is still the exchange's: read in place, copied by Append }
  if not D.Ex.Resp.Head.Headers.Get('x-request-id', R.RequestId, R.RequestIdLen) then
    R.RequestId := nil;
  R.Status := D.Ex.Resp.Head.Status;
  R.BodyBytes := D.RespBodyBytes;
  R.DurationNs := Dur;
  Log.Buffer(Idx).Append(R);
  { the stage block goes back to the pool; the next request takes one again }
  BlockFree(St^.Block);
  D.HookData := nil;
end;

procedure TServerHooks.ConnDone(D: TH1Dispatcher; Outcome: TConnOutcome; Upgraded: Boolean);
begin
  if D <> nil then
  begin
    if MetricsOn then
      Inc(Metrics[D.Loop.Index].ConnectionsClosed[Outcome]);
    if D.HookData <> nil then
    begin
      { a request whose response never completed: its stage goes back }
      BlockFree(PBufBlock(D.HookData));
      D.HookData := nil;
    end;
  end;
  { an upgraded connection keeps its slot until UpgradedClosed }
  if not Upgraded then
    Server.ConnReleased;
end;

procedure TServerHooks.UpgradedClosed;
begin
  Server.ConnReleased;
end;

function TServerLoop.GetListener: TListener;
begin
  if Length(Listeners) > 0 then
    Result := Listeners[0]
  else
    Result := nil;
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
  if AtomicDec(SL.Server.FGsPending) = 0 then
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
  SL.AbortUpgraded;
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
      AtomicInc(StallReports);
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
  U, UNext: TUpgraded;
  I: Integer;
begin
  SL := TServerLoop(Arg);
  if SL.Stopping then
    Exit;
  SL.Stopping := True;
  for I := 0 to High(SL.Listeners) do
    if SL.Listeners[I] <> nil then
    begin
      { accept until EAGAIN, then close; the connections accepted here get
        GracefulShutdown in OnAccept }
      SL.Listeners[I].DrainAndClose;
      SL.Listeners[I] := nil;
    end;
  if SL.Index = 0 then
    SL.Server.RemoveUnixSocket;    { a Unix socket: the other loops hold dups of a closed path }
  D := SL.Conns.Head;
  while D <> nil do
  begin
    D.GracefulShutdown;
    D := D.NextConn;
  end;
  { the upgraded connections end their protocol (a WebSocket sends its
    close frame); a stream may close and unlink itself in the call }
  U := SL.Upgraded.Head;
  while U <> nil do
  begin
    UNext := U.NextTracked;
    U.Shutdown;
    U := UNext;
  end;
  if (SL.Conns.Count = 0) and (SL.Upgraded.Count = 0) then
    Loop.StopNow
  else
  begin
    TimerInit(@SL.FStopTimer, @StopTimerProc, SL);
    Loop.Timers.Arm(@SL.FStopTimer, Loop.NowMs + SL.GraceMs);
  end;
end;

{ a metrics snapshot: this loop copies its counters and gauges (lmCall) }
procedure MetricsProc(Loop: TLoop; Arg: Pointer);
var
  SL: TServerLoop;
begin
  SL := TServerLoop(Arg);
  SL.SnapshotMetrics(SL.Server.FHooks.Snap[SL.Index]);
  if AtomicDec(SL.Server.FMetricsPending) = 0 then
    RTLEventSetEvent(SL.Server.FMetricsEvent);
end;

procedure TServerLoop.SnapshotMetrics(var M: TLoopMetrics);
var
  D: TH1Dispatcher;
  I: Integer;
  H: TServerHooks;
begin
  H := Server.FHooks;
  if (H <> nil) and H.MetricsOn then
    M := H.Metrics[Index]
  else
    M := Default(TLoopMetrics);
  M.OpenConnections := Conns.Count;
  M.RequestsInFlight := 0;
  D := Conns.Head;
  while D <> nil do
  begin
    if (D.InFlight <> nil) or (D.BodyRx.Kind <> obNone) then
      Inc(M.RequestsInFlight);
    D := D.NextConn;
  end;
  M.PooledBufferBytes := Loop.Blocks.PooledBytes;
  M.ConnectionsAccepted := 0;
  M.ListenerErrorPauses := 0;
  M.ListenerLimitPauses := 0;
  for I := 0 to High(Listeners) do
    if Listeners[I] <> nil then
    begin
      Inc(M.ConnectionsAccepted, Listeners[I].Accepted);
      Inc(M.ListenerErrorPauses, Listeners[I].Pauses);
      Inc(M.ListenerLimitPauses, Listeners[I].LimitPauses);
    end;
  if (H <> nil) and (H.Log <> nil) then
    M.AccessLogDropped := H.Log.Buffer(Index).Dropped
  else
    M.AccessLogDropped := 0;
end;

{ the connection limit: a connection closed on another loop; this loop's
  listeners may accept again }
procedure LimitResumeProc(Loop: TLoop; Arg: Pointer);
var
  SL: TServerLoop;
begin
  SL := TServerLoop(Arg);
  AtomicStore(SL.FLimitPosted, 0);
  SL.ResumeListeners;
end;

{ the watchdog's ping, on the loop thread: this loop handled round FWdTick }
procedure WdPingProc(Loop: TLoop; Arg: Pointer);
var
  SL: TServerLoop;
begin
  SL := TServerLoop(Arg);
  AtomicStore(SL.FWdSeen, SL.FWdTick);
  AtomicStore(SL.FWdPosted, 0);
end;

function WatchdogThreadMain(Arg: Pointer): PtrInt;
var
  S: TServer;
  SL: TServerLoop;
  HalfMs: Int64;
  Tick: LongInt;
  I: Integer;
  Alive: Boolean;
begin
  S := TServer(Arg);
  HalfMs := SdWatchdogUsec div 2000;
  if HalfMs < 1 then
    HalfMs := 1;
  Tick := 0;
  while AtomicLoad(S.FWdQuit) = 0 do
  begin
    { the heartbeat goes out only when every loop handled the last round's
      ping (round 0 needs none: the loops have just started) }
    Alive := True;
    for I := 0 to High(S.FLoops) do
      if AtomicLoad(S.FLoops[I].FWdSeen) <> Tick then
        Alive := False;
    if Alive then
      SdNotify('WATCHDOG=1' + LF + 'STATUS=' + IntToStr(S.OpenConnections) + ' connection(s)');
    Inc(Tick);
    for I := 0 to High(S.FLoops) do
    begin
      SL := S.FLoops[I];
      { a ping still in the inbox (the loop has not run since) is not
        posted again: the message record is the inbox node }
      if AtomicXchg(SL.FWdPosted, 1) = 0 then
      begin
        SL.FWdTick := Tick;
        SL.Loop.Post(@SL.FWdMsg);
      end;
    end;
    RTLEventWaitFor(S.FWdStop, HalfMs);
  end;
  Result := 0;
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
  FWdStop := RTLEventCreate;
  FMetricsEvent := RTLEventCreate;
  InitCriticalSection(FGsLock);
  InitCriticalSection(FMetricsLock);
end;

constructor TServer.CreateWithProc(const Cfg: TServerConfig; Factory: TServiceProc;
  Observer: TConnObserver);
begin
  Create(Cfg, nil, Observer);
  FFactoryProc := Factory;
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
    FHooks := nil;                 { the leaked connection tasks may still call it }
    RTLEventDestroy(FGsEvent);
    RTLEventDestroy(FWdStop);
    RTLEventDestroy(FMetricsEvent);
    DoneCriticalSection(FGsLock);
    DoneCriticalSection(FMetricsLock);
  end;

begin
  if FStarted then
  begin
    if not FStopRequested then
      Stop(0);
    Wait;
  end;
  StopWatchdog;                    { a Start that failed after starting it }
  JoinWatchdog;
  RemoveUnixSocket;                { normally done by loop 0's stop; here after a failed Start }
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
  FreeAndNil(FHooks);
  RTLEventDestroy(FGsEvent);
  RTLEventDestroy(FWdStop);
  RTLEventDestroy(FMetricsEvent);
  DoneCriticalSection(FGsLock);
  DoneCriticalSection(FMetricsLock);
  inherited Destroy;
end;

function TServer.OpenConnections: Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to High(FLoops) do
    if FLoops[I] <> nil then
      Inc(Result, FLoops[I].Conns.Count);
end;

function TServer.CountedConnections: Integer;
begin
  Result := AtomicLoad(FConnCount);
end;

function TServer.AccessLog: TAccessLog;
begin
  if FHooks <> nil then
    Result := FHooks.Log
  else
    Result := nil;
end;

procedure TServer.Metrics(out S: TMetricsSnapshot);
var
  I, Posted: Integer;
  Own: array of TLoopMetrics;
begin
  S := Default(TMetricsSnapshot);
  S.Loops := Length(FLoops);
  if FWorkers <> nil then
  begin
    S.WorkerQueueLength := FWorkers.QueueLength;
    S.WorkerThreads := FWorkers.ThreadCount;
  end;
  S.CountedConnections := CountedConnections;
  if Length(FLoops) = 0 then
    Exit;
  EnterCriticalSection(FMetricsLock);
  try
    if FHooks <> nil then
      SetLength(FHooks.Snap, Length(FLoops))
    else
      SetLength(Own, Length(FLoops));
    { a running loop copies on its own thread; a loop that exited (after
      Stop and Wait) or never started is read here }
    RTLEventResetEvent(FMetricsEvent);
    Posted := 0;
    for I := 0 to High(FLoops) do
      if (FLoops[I] <> nil) and FLoops[I].Running and (FHooks <> nil) then
        Inc(Posted);
    FMetricsPending := Posted;
    for I := 0 to High(FLoops) do
      if FLoops[I] <> nil then
        if FLoops[I].Running and (FHooks <> nil) then
          FLoops[I].Loop.Post(@FLoops[I].FMetricsMsg)
        else if FHooks <> nil then
          FLoops[I].SnapshotMetrics(FHooks.Snap[I])
        else
          FLoops[I].SnapshotMetrics(Own[I]);
    if Posted > 0 then
      RTLEventWaitFor(FMetricsEvent);
    for I := 0 to High(FLoops) do
      if FLoops[I] <> nil then
        if FHooks <> nil then
          MetricsAdd(S.Total, FHooks.Snap[I])
        else
          MetricsAdd(S.Total, Own[I]);
  finally
    LeaveCriticalSection(FMetricsLock);
  end;
end;

function TServer.PrometheusText: RawByteString;
var
  S: TMetricsSnapshot;
begin
  Metrics(S);
  Result := MetricsToPrometheus(S);
end;

procedure TServer.ConnReleased;
var
  N: LongInt;
  I: Integer;
  SL: TServerLoop;
  Me: TThreadID;
begin
  N := AtomicDec(FConnCount);
  { the count just dropped below the limit: every loop's listeners may
    accept again. This loop's are resumed here; the others get a message
    (one in flight per loop: the record is the inbox node) }
  if (FCfg.MaxConnections <= 0) or (N <> FCfg.MaxConnections - 1) then
    Exit;
  Me := GetCurrentThreadId;
  for I := 0 to High(FLoops) do
  begin
    SL := FLoops[I];
    if (SL = nil) or (SL.Loop = nil) then
      Continue;
    if AtomicLoadThreadId(SL.Loop.ThreadId) = Me then
      SL.ResumeListeners
    else if AtomicXchg(SL.FLimitPosted, 1) = 0 then
      SL.Loop.Post(@SL.FLimitMsg);
  end;
end;

procedure TServer.RemoveUnixSocket;
var
  Paths: array of RawByteString;
  I: Integer;
begin
  { loop 0's thread (StopProc) or the owner thread (Destroy, after Wait):
    never both at once }
  Paths := FUnixPaths;
  FUnixPaths := nil;
  for I := 0 to High(Paths) do
    RemoveSocketFile(Paths[I]);
end;

procedure TServer.StartWatchdog;
begin
  if FWdRunning or not FCfg.Watchdog or (SdWatchdogUsec <= 0) then
    Exit;
  AtomicStore(FWdQuit, 0);
  RTLEventResetEvent(FWdStop);
  FWdRunning := True;
  FWdThread := BeginThread(@WatchdogThreadMain, Pointer(Self));
end;

procedure TServer.StopWatchdog;
begin
  if not FWdRunning then
    Exit;
  AtomicStore(FWdQuit, 1);
  RTLEventSetEvent(FWdStop);
end;

procedure TServer.JoinWatchdog;
begin
  if not FWdRunning then
    Exit;
  WaitForThreadTerminate(FWdThread, 0);
  CloseThread(FWdThread);
  FWdRunning := False;
end;

{ An inherited listening socket: non-blocking, close-on-exec, TCP_NODELAY
  when asked for; Bound gets its address. Raises when Fd is not a
  listening socket. }
procedure SetUpInheritedListener(Fd: cint; const Spec: TListenSpec; out Bound: TSockAddrStorage);
var
  Flags, One, Acc: cint;
  Len: Cardinal;
  R: SizeInt;
begin
  Acc := 0;
  Len := SizeOf(Acc);
  R := SysGetSockOpt(Fd, SOL_SOCKET, SO_ACCEPTCONN, @Acc, @Len);
  if (R < 0) or (Acc = 0) then
    raise EServerError.CreateFmt('TServer.Start: inherited descriptor %d is not a listening socket', [Fd]);
  Flags := FpFcntl(Fd, F_GETFL);
  if (Flags < 0) or (FpFcntl(Fd, F_SETFL, Flags or O_NONBLOCK) < 0) then
    raise EServerError.CreateFmt('TServer.Start: fcntl on inherited descriptor %d failed: errno %d',
      [Fd, fpgeterrno]);
  FpFcntl(Fd, F_SETFD, 1);                       { FD_CLOEXEC }
  FillChar(Bound, SizeOf(Bound), 0);
  Len := SizeOf(Bound);
  SysGetSockName(Fd, @Bound, @Len);
  if Spec.NoDelay and ((Bound.Family = AF_INET) or (Bound.Family = AF_INET6)) then
  begin
    One := 1;
    SysSetSockOpt(Fd, IPPROTO_TCP, TCP_NODELAY, @One, SizeOf(One));
  end;
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
  N, I, K: Integer;

  procedure SetListenerLimit(L: TListener);
  begin
    if FCfg.MaxConnections > 0 then
    begin
      L.Limit := @FConnCount;
      L.MaxConns := FCfg.MaxConnections;
    end;
  end;

var
  Cpus: TCpuList;
  Specs: array of TListenSpec;
  SharedFds: array of cint;
  Spec: TListenSpec;
  Fd: cint;
  Bound: Word;
  BoundAddr: TSockAddrStorage;
  E: cint;
  Msg: string;
  SL: TServerLoop;
  ListenEvents: Cardinal;
begin
  if FStarted then
    raise EServerError.Create('TServer.Start: already started');
  if not ValidateH1Config(FCfg.H1, Msg) then
    raise EServerError.Create('TServer.Start: ' + Msg);
  if not (Assigned(FFactory) or Assigned(FFactoryProc)) then
    raise EServerError.Create('TServer.Start: no service factory');
  IgnoreSigPipe;
  N := FCfg.Loops;
  if N <= 0 then
    N := DefaultLoopCount;
  if (FCfg.Workers >= 0) and (FWorkers = nil) then
    FWorkers := TWorkerPool.Create(FCfg.Workers, FCfg.WorkerHooks, FCfg.WorkerQueueLimit);
  Cpus := UsableCpus;
  SetLength(FLoops, N);
  if ((FCfg.MaxConnections > 0) or FCfg.Metrics or FCfg.AccessLog.Enabled) and (FHooks = nil) then
  begin
    FHooks := TServerHooks.Create;
    FHooks.Server := Self;
    FHooks.MetricsOn := FCfg.Metrics;
    SetLength(FHooks.Metrics, N);
    for I := 0 to N - 1 do
      FHooks.Metrics[I] := Default(TLoopMetrics);
    if FCfg.AccessLog.Enabled then
    begin
      FHooks.Log := TAccessLog.Create(N, FCfg.AccessLog.BufferBytes, FCfg.AccessLog.Format,
        FCfg.AccessLog.Colors, FCfg.AccessLog.Sink, FCfg.AccessLog.FlushMs);
      FHooks.Log.MinLevel := FCfg.AccessLog.MinLevel;
      FHooks.LogUserAgent := FCfg.AccessLog.UserAgent;
      FHooks.LogReferer := FCfg.AccessLog.Referer;
    end;
  end;
  { the listen specs: Listen, then AlsoListen. A Unix socket has one path
    and an inherited socket is one socket: their loops share it }
  SetLength(Specs, 1 + Length(FCfg.AlsoListen));
  Specs[0] := FCfg.Listen;
  for K := 1 to High(Specs) do
    Specs[K] := FCfg.AlsoListen[K - 1];
  for K := 0 to High(Specs) do
    if ((Specs[K].UnixPath <> '') or (Specs[K].InheritedFd > 0)) and (Specs[K].Mode = amReusePort) then
      Specs[K].Mode := amSharedExclusive;
  SetLength(SharedFds, Length(Specs));
  for K := 0 to High(SharedFds) do
    SharedFds[K] := -1;
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
    SL.Upgraded.OnEmpty := @SL.UpgradedEmpty;
    SL.FGsMsg.Kind := lmCall;
    SL.FGsMsg.Proc := @GsProc;
    SL.FGsMsg.Arg := SL;
    SL.FStopMsg.Kind := lmCall;
    SL.FStopMsg.Proc := @StopProc;
    SL.FStopMsg.Arg := SL;
    SL.FWdMsg.Kind := lmCall;
    SL.FWdMsg.Proc := @WdPingProc;
    SL.FWdMsg.Arg := SL;
    SL.FLimitMsg.Kind := lmCall;
    SL.FLimitMsg.Proc := @LimitResumeProc;
    SL.FLimitMsg.Arg := SL;
    SL.FMetricsMsg.Kind := lmCall;
    SL.FMetricsMsg.Proc := @MetricsProc;
    SL.FMetricsMsg.Arg := SL;
    if Assigned(FFactory) then
      SL.Service := FFactory(SL.Loop)
    else
      SL.Service := FFactoryProc(SL.Loop);
    {$ifdef WD_STALL}
    { before the loop thread starts: the wheel is the loop thread's from then on }
    TimerInit(@SL.FStallTimer, @StallTimerProc, SL);
    SL.Loop.Timers.Arm(@SL.FStallTimer, MonoNowNs div 1000000 + 1000);
    {$endif}
    SetLength(SL.Listeners, Length(Specs));
    for K := 0 to High(Specs) do
    begin
      Spec := Specs[K];
      if Spec.Mode = amSharedExclusive then
        ListenEvents := EPOLLIN or EPOLLEXCLUSIVE
      else
        ListenEvents := EPOLLIN;
      if (Spec.Mode = amReusePort) or (I = 0) then
      begin
        if Spec.InheritedFd > 0 then
        begin
          { a socket that is already open (systemd): used as it is }
          Fd := Spec.InheritedFd;
          SetUpInheritedListener(Fd, Spec, BoundAddr);
          if (BoundAddr.Family = AF_INET) or (BoundAddr.Family = AF_INET6) then
            Bound := SockAddrPort(BoundAddr)
          else
            Bound := 0;
        end
        else
        begin
          if not OpenListener(Spec, Spec.Mode = amReusePort, Fd, Bound, E) then
          begin
            if Spec.UnixPath <> '' then
              raise EServerError.CreateFmt('TServer.Start: listen on %s failed: errno %d',
                [Spec.UnixPath, E]);
            raise EServerError.CreateFmt('TServer.Start: listen on %s:%d failed: errno %d',
              [Spec.Host, Spec.Port, E]);
          end;
          if Spec.UnixPath <> '' then
          begin
            { removed when the server stops }
            SetLength(FUnixPaths, Length(FUnixPaths) + 1);
            FUnixPaths[High(FUnixPaths)] := Spec.UnixPath;
          end
          else if Spec.Port = 0 then
            Specs[K].Port := Bound;  { the first loop binds port 0, the others that port }
        end;
        if K = 0 then
          FPort := Bound;
        if Spec.Mode = amSharedExclusive then
          SharedFds[K] := Fd;
        SL.Listeners[K] := TListener.Create(SL.Loop, Fd, @SL.OnAccept, ListenEvents);
        SetListenerLimit(SL.Listeners[K]);
      end
      else if Spec.Mode = amSharedExclusive then
      begin
        { the same socket through a dup: each loop's TListener closes its own fd }
        Fd := FpFcntl(SharedFds[K], F_DUPFD_CLOEXEC, 0);
        if Fd < 0 then
          raise EServerError.CreateFmt('TServer.Start: dup of the listener failed: errno %d',
            [fpgeterrno]);
        SL.Listeners[K] := TListener.Create(SL.Loop, Fd, @SL.OnAccept, ListenEvents);
        SetListenerLimit(SL.Listeners[K]);
      end;
    end;
  end;
  FStarted := True;
  FCallerLoop0 := CallerRunsLoop0;
  if (FHooks <> nil) and (FHooks.Log <> nil) then
    FHooks.Log.Start;
  for I := 0 to N - 1 do
  begin
    FLoops[I].Running := True;
    if (I > 0) or not CallerRunsLoop0 then
      FLoops[I].Thread := BeginThread(@LoopThreadMain, Pointer(FLoops[I]));
  end;
  { systemd: the service is ready; then the heartbeat }
  if SdNotifyEnabled then
    SdNotify('READY=1' + LF + 'STATUS=listening, ' + IntToStr(N) + ' loop(s)');
  StartWatchdog;
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
  if FStopRequested then
  begin
    JoinWatchdog;
    { every loop has left Run: the last access log lines are flushed }
    for I := 0 to High(FLoops) do
      if (FLoops[I] <> nil) and FLoops[I].Running then
        Exit;
    if (FHooks <> nil) and (FHooks.Log <> nil) then
      FHooks.Log.Stop;
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
  if not FStarted or (AtomicXchg(FStopClaim, 1) <> 0) then
    Exit;
  FStopRequested := True;
  StopWatchdog;
  if SdNotifyEnabled then
    SdNotify('STOPPING=1');
  for I := 0 to High(FLoops) do
  begin
    FLoops[I].GraceMs := GraceMs;
    FLoops[I].Loop.Post(@FLoops[I].FStopMsg);
  end;
end;

function TServer.RunUntilSignal(Started: TServerEvent): cint;
begin
  Result := DoRunUntilSignal(Started, nil);
end;

function TServer.RunUntilSignalProc(Started: TServerProc): cint;
begin
  Result := DoRunUntilSignal(nil, Started);
end;

function TServer.DoRunUntilSignal(Started: TServerEvent; StartedProc: TServerProc): cint;
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
    if Assigned(StartedProc) then
      StartedProc(Self);
    { a Stop from elsewhere (a handler, another thread) also ends the wait:
      checked every 200 ms; Result is then 0 }
    Tick.tv_sec := 0;
    Tick.tv_nsec := 200 * 1000 * 1000;
    repeat
      R := FpSigTimedWait(Sigs, nil, @Tick);
    until (R > 0) or (AtomicCas(FStopClaim, 0, 0) <> 0);
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
  Result.Watchdog := True;
end;

function ApplySdListenFds(var Cfg: TServerConfig): Integer;
var
  Fds: TSdFds;
  Names: TSdNames;
  I: Integer;
begin
  Result := SdListenFds(Fds, Names);
  if Result = 0 then
    Exit;
  Cfg.Listen.InheritedFd := Fds[0];
  SetLength(Cfg.AlsoListen, Result - 1);
  for I := 1 to Result - 1 do
  begin
    Cfg.AlsoListen[I - 1] := Cfg.Listen;
    Cfg.AlsoListen[I - 1].InheritedFd := Fds[I];
  end;
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
  Result.Workers := NO_WORKER_POOL;
  Result.WorkerQueueLimit := 0;
  Result.GraceMs := 1000;
end;

end.

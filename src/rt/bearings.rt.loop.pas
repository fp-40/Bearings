{ bearings.rt.loop - the per-thread event loop: tasks, socket readiness, the run
  queue, timers and the inbox for messages from other threads.

  An event loop is one thread that serves many connections without blocking
  on any of them. Every socket is non-blocking: a read with no data, or a
  write into a full socket buffer, returns EAGAIN at once instead of waiting.
  The loop asks the kernel which sockets are ready (epoll_wait), runs the
  code of each ready connection until it would block again, and goes back to
  waiting. The server runs one TLoop per loop thread; a connection stays on
  the loop that accepted it for its whole life.

  Main types:
    TLoop       the loop: the epoll instance, the run queue, the timer wheel
                (bearings.rt.timer), the buffer block pool (bearings.rt.buf), the
                tick hook (LoopTickProc) with its per-loop storage (Ext), and
                the inbox.
    TLoopTask   anything the loop can run (a connection driver, an upgraded
                connection, a control task). Run does one step of its work
                and returns; it never blocks.
    TIoTask     a task that owns a file descriptor. Its TIoSource is what
                epoll reports (epoll_event.data.ptr points to it) and holds
                the readiness bits.
    TLoopMsg    a message another thread posts to the loop (Post).

  Readiness. Connection sockets are registered once, edge-triggered
  (EPOLLET): epoll reports a socket only when it changes state (new data
  arrived, buffer space became free), not again while it stays ready. So the
  loop records each report in Src.Ready (ReadyFromEpoll), and the transport
  (bearings.rt.net) clears a bit only when a read or write returns EAGAIN or a
  short count; until then the task may keep reading or writing. Listening
  sockets and the eventfd are registered level-triggered (reported on every
  epoll_wait while ready). The eventfd has data.ptr = nil.

  A socket event calls the task's OnIo, which runs the task at once. The run
  queue holds the other reasons to run: a task that yields, a wake from code
  on the loop thread, and wakes that other threads deliver through the
  inbox.

  One iteration (RunIteration): wait in epoll_wait (timeout 0 if work is
  already queued, else until the next timer), sample the clock, dispatch the
  socket events, handle the inbox messages, fire due timers, run up to
  RUN_QUEUE_BUDGET queued tasks, free the tasks closed in this iteration.

  The tick hook. A higher layer can keep per-loop state that must be
  refreshed from time to time (bearings.http.date keeps the formatted Date
  header, refreshed once per second). It assigns LoopTickProc and keeps its
  state in TLoop.Ext (LOOP_EXT_BYTES bytes, zeroed when the loop is
  created). The loop calls LoopTickProc once in Create and then in the
  iteration in which the delay that the last call returned has elapsed: one
  comparison per iteration, one indirect call per delay.

  Freeing after the batch: Close marks a task closed and puts it on the
  deferred-free list; it is freed at the end of the iteration, after every
  event of the batch was dispatched. A later event in the same batch can
  still carry a pointer to the closed task; it is skipped instead of
  touching freed memory. A closed task still in the run queue is kept until
  it leaves the queue.

  Exceptions: Run holds one try/except around the iteration loop. An
  exception that escapes a task aborts that task (Abort, then Close) and the
  loop resumes the interrupted event batch at FEventPos without another
  epoll_wait. Inbox messages already taken are kept in FMsgHead, so they are
  not lost either.

  Threading: everything here runs on the loop thread, except Post,
  RequestStop and PostsInProgress, which any thread may call. Another
  thread that wants a task woken or code run on the loop posts a TLoopMsg. }
unit bearings.rt.loop;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

uses
  SysUtils, ctypes, bearings.rt.sys, bearings.rt.clock, bearings.rt.sync, bearings.rt.timer, bearings.rt.buf;

const
  RUN_QUEUE_BUDGET = 61;          { queued tasks run per iteration before epoll is polled again }
  MAX_EVENTS = 1024;
  IDLE_TRIM_NS = 1000000000;      { Blocks.Trim after 1 s without events }
  LOOP_EXT_BYTES = 64;            { size of TLoop.Ext }

type
  TLoop = class;
  TIoTask = class;

  { What a socket is ready for, as last reported by epoll (see ReadyFromEpoll).
    rdReadClosed: the peer shut down its sending side (no more data after what
    is buffered). rdWriteClosed: writing can no longer succeed. rdError: the
    socket has a pending error. }
  TReadyBit = (rdRead, rdWrite, rdReadClosed, rdWriteClosed, rdError);
  TReadySet = set of TReadyBit;

  PIoSource = ^TIoSource;
  TIoSource = record          { first field of every fd-owning task; epoll data.ptr points here }
    Fd: cint;
    Ready: TReadySet;
    Task: TIoTask;
  end;

  { Anything the loop can run: a connection driver, an upgrade task, the control task. }
  TLoopTask = class
  private
    FRunNext: TLoopTask;           { intrusive run-queue link }
    FQueued: Boolean;              { in the run queue }
    FRunning: Boolean;             { inside Run / OnIo }
    FNotified: Boolean;            { woken while running: re-queue at the back afterwards }
    FClosed: Boolean;              { closed in this batch: no more runs, freed after the batch }
    FFreeNext: TLoopTask;
  public
    Loop: TLoop;
    { Does as much work as possible without blocking, then returns. Loop thread only. }
    procedure Run; virtual; abstract;
    { Called instead of further Runs when Run raised an exception, or at the
      shutdown deadline. Releases everything and closes the fd without sending
      anything more to the peer. }
    procedure Abort; virtual; abstract;
    { Loop thread only: asks for one more Run. Appends the task to the run queue
      unless it is already queued or closed; while the task is running, only sets
      FNotified (the loop queues it after Run returns, so it runs once more). }
    procedure Wake; inline;
    { FClosed := True and Loop.DeferFree(Self): the task gets no more Runs and is
      freed at the end of the current iteration. }
    procedure Close;
    property Closed: Boolean read FClosed;
    property Queued: Boolean read FQueued;
    property Running: Boolean read FRunning;
    { woken while running (queued again after Run returns); read by a debug
      check in the HTTP/1 dispatcher }
    property Notified: Boolean read FNotified;
  end;

  TIoTask = class(TLoopTask)
  public
    Src: TIoSource;
    constructor Create(ALoop: TLoop; AFd: cint);
    { Closes Src.Fd if it is still open (normally the transport has closed it already). }
    destructor Destroy; override;
    { Socket event: Src.Ready := Src.Ready + ReadyFromEpoll(Events); then, unless the task is
      queued (it will run from the queue anyway) or closed, call Run at once. }
    procedure OnIo(Events: Cardinal); virtual;
  end;

  TLoopMsgKind = (lmWakeExchange, lmFreeExchange, lmCall);
  PLoopMsg = ^TLoopMsg;
  TLoopMsgProc = procedure(Loop: TLoop; Arg: Pointer);
  { A message for the loop's inbox. lmWakeExchange / lmFreeExchange are handled
    by LoopMsgHandlers (set by bearings.http.exchange); lmCall runs Proc(Loop, Arg). }
  TLoopMsg = record               { embedded in its sender: posting allocates nothing }
    Node: TMpscNode;              { first field: the inbox link (bearings.rt.sync) }
    Kind: TLoopMsgKind;
    Proc: TLoopMsgProc;           { lmCall }
    Arg: Pointer;                 { the exchange (lmWake*/lmFree*), or Proc's argument }
  end;

  TLoopErrorProc = procedure(Loop: TLoop; Task: TLoopTask; E: Exception);
  { The tick hook (see the unit header): refreshes the caller's state in
    Loop.Ext and returns the delay in nanoseconds until the next call. }
  TLoopTickProc = function(Loop: TLoop): Int64;

  TLoop = class
  private
    FCurrent: TLoopTask;
    FEvents: array[0..MAX_EVENTS - 1] of TEpollEvent;
    FEventPos, FEventCount: Integer;
    FRunHead, FRunTail: TLoopTask;
    FFreeList: TLoopTask;
    FStopped: Boolean;
    FNextTickNs: Int64;
    FMsgHead: PMpscNode;          { inbox messages taken but not yet dispatched (kept across an exception) }
    FLastBusyNs: Int64;
    FThread: TThreadID;
    FStarted: Boolean;
    FStopMsg: TLoopMsg;           { posted once by RequestStop }
    FStopPosted: LongInt;         { 1 once FStopMsg was posted }
    procedure AbortCurrent(E: Exception);
    procedure PushRun(T: TLoopTask); inline;
    procedure RunTask(T: TLoopTask); inline;
    procedure DrainInbox;
    procedure FreeDeferred;
    procedure Tick;
  public
    Index: Integer;
    ThreadId: TThreadID;          { the thread acting as the loop thread }
    EpFd, WakeFd: cint;
    NowNs, NowMs: Int64;          { CLOCK_MONOTONIC, sampled after epoll_wait }
    { storage for the state of the tick hook (no managed types); zeroed by
      Create. bearings.http.date keeps the Date header cache here }
    Ext: array[0..LOOP_EXT_BYTES - 1] of Byte;
    Timers: TTimerWheel;
    Blocks: TBlockPool;
    Exchanges: Pointer;           { the loop's TExchangePool; the type lives in bearings.http.exchange }
    NextConnSeq: QWord;
    Sleeping: LongInt;            { 1 while the loop may be blocked in epoll_wait (see Post) }
    Inbox: TMpscStack;            { messages from any thread; lock-free, many producers, one consumer }
    { statistics (loop thread writes; tests read after the loop stopped) }
    Waits: QWord;                 { epoll_wait calls }
    WakeWrites: QWord;            { eventfd writes by Post (any thread; atomic increments) }
    { Post calls in progress (any thread; interlocked). Post still reads and
      writes the loop after its push (Sleeping, the eventfd, WakeWrites), so
      a thread that frees the loop after the message was handled waits for
      0 first (TServer.Destroy) }
    Posting: LongInt;
    Aborts: QWord;                { tasks aborted by an exception }
    Trims: QWord;                 { idle Blocks.Trim calls }
    constructor Create(AIndex: Integer);
    destructor Destroy; override;
    procedure Run;                { thread body: while not Stopped do try RunIteration except ... }
    procedure RunIteration;
    { Any thread: appends M to the inbox and wakes the loop if it may be blocked
      in epoll_wait. M must stay valid and unchanged until the loop has
      dispatched it. }
    procedure Post(M: PLoopMsg);
    { Post calls in progress; 0 means no thread is inside Post (the caller
      knows no new Post can start: TServer.Destroy, after every exchange is
      back in its pool and the workers are gone) }
    function PostsInProgress: LongInt;
    { Dispatches the messages in the inbox now. Used by TServer after the loop thread
      exited, so the exchanges that workers released are recycled before the pools are
      freed. The calling thread becomes the loop thread (ThreadId). }
    procedure ProcessInbox;
    function Register(Src: PIoSource; Events: Cardinal): Boolean;   { EPOLL_CTL_ADD }
    procedure Unregister(Src: PIoSource);                           { EPOLL_CTL_DEL (used when an upgraded connection is detached) }
    procedure DeferFree(T: TLoopTask);
    { Runs Run on a new thread (BeginThread). }
    procedure Start;
    { Any thread: posts a stop message; the loop leaves Run after the iteration that handles it. }
    procedure RequestStop;
    { Loop thread (from a task or message): same as RequestStop. }
    procedure StopNow;
    { Waits for the thread started by Start. }
    procedure WaitFor;
    function NextConnId: QWord; inline;      { QWord(Index) shl 48 or NextConnSeq: unique per server }
    property Current: TLoopTask read FCurrent;   { task being run; aborted if an exception escapes }
    property Stopped: Boolean read FStopped;
  end;

var
  { lmWakeExchange / lmFreeExchange handlers; assigned by bearings.http.exchange. }
  LoopMsgHandlers: array[TLoopMsgKind] of TLoopMsgProc;
  { Called for every exception that aborts a task (or escapes a timer proc or
    a message); default: one line on stderr. }
  LoopErrorProc: TLoopErrorProc;
  { The tick hook (see the unit header); nil = none. Assigned by
    bearings.http.date's initialization. Set it before creating any loop. }
  LoopTickProc: TLoopTickProc;
{$ifopt C+}
  { tests (builds with assertions only): called by Post right after its push,
    while Posting counts the call: the window in which the message can be
    handled before Post returned }
  PostAfterPushHook: procedure(Loop: TLoop) = nil;
  { tests (builds with assertions only): called by Post right before its
    push; Posting must already count the call there }
  PostBeforePushHook: procedure(Loop: TLoop) = nil;
{$endif}

{ epoll event bits -> readiness. EPOLLRDHUP means the peer shut down its
  sending side; EPOLLHUP means both directions are closed; EPOLLERR means the
  socket has an error (EPOLLHUP and EPOLLERR are always reported, even when
  not requested). The "closed" and error bits are sticky: once set they stay
  in Src.Ready, because the condition cannot go away.
    EPOLLIN (or EPOLLPRI)                     -> rdRead
    EPOLLOUT                                  -> rdWrite
    EPOLLHUP, or (EPOLLIN and EPOLLRDHUP)     -> rdReadClosed   (sticky)
    EPOLLHUP, or (EPOLLOUT and EPOLLERR),
      or exactly EPOLLERR                     -> rdWriteClosed  (sticky)
    EPOLLERR                                  -> rdError        (sticky) }
function ReadyFromEpoll(Events: Cardinal): TReadySet; inline;

implementation

function ReadyFromEpoll(Events: Cardinal): TReadySet;
begin
  Result := [];
  if (Events and (EPOLLIN or EPOLLPRI)) <> 0 then
    Include(Result, rdRead);
  if (Events and EPOLLOUT) <> 0 then
    Include(Result, rdWrite);
  if ((Events and EPOLLHUP) <> 0)
    or (((Events and EPOLLIN) <> 0) and ((Events and EPOLLRDHUP) <> 0)) then
    Include(Result, rdReadClosed);
  if ((Events and EPOLLHUP) <> 0)
    or (((Events and EPOLLOUT) <> 0) and ((Events and EPOLLERR) <> 0))
    or (Events = EPOLLERR) then
    Include(Result, rdWriteClosed);
  if (Events and EPOLLERR) <> 0 then
    Include(Result, rdError);
end;

procedure DefaultLoopError(Loop: TLoop; Task: TLoopTask; E: Exception);
var
  TaskName: string;
begin
  if Task <> nil then
    TaskName := Task.ClassName
  else
    TaskName := '(none)';
  WriteLn(StdErr, 'bearings.rt.loop: loop ', Loop.Index, ': ', E.ClassName, ': ', E.Message,
    ' (task ', TaskName, ' aborted)');
end;

{ ---- TLoopTask ---- }

procedure TLoopTask.Wake;
begin
  if FQueued or FClosed then
    Exit;
  if FRunning then
    FNotified := True
  else
    Loop.PushRun(Self);
end;

procedure TLoopTask.Close;
begin
  if FClosed then
    Exit;
  FClosed := True;
  FNotified := False;
  Loop.DeferFree(Self);
end;

{ ---- TIoTask ---- }

constructor TIoTask.Create(ALoop: TLoop; AFd: cint);
begin
  inherited Create;
  Loop := ALoop;
  Src.Fd := AFd;
  Src.Ready := [];
  Src.Task := Self;
end;

destructor TIoTask.Destroy;
begin
  if Src.Fd >= 0 then
  begin
    SysClose(Src.Fd);
    Src.Fd := -1;
  end;
  inherited Destroy;
end;

procedure TIoTask.OnIo(Events: Cardinal);
begin
  Src.Ready := Src.Ready + ReadyFromEpoll(Events);
  if FQueued or FClosed then
    Exit;
  Loop.RunTask(Self);
end;

{ ---- TLoop ---- }

procedure StopProc(Loop: TLoop; Arg: Pointer);
begin
  Loop.FStopped := True;
end;

constructor TLoop.Create(AIndex: Integer);
var
  Ev: TEpollEvent;
  R: SizeInt;
begin
  inherited Create;
  { a constructor that raises runs Destroy, which closes the fds >= 0;
    zero-initialized fields would close fd 0 }
  EpFd := -1;
  WakeFd := -1;
  Index := AIndex;
  { the creating thread until Run sets the loop thread (tests drive RunIteration on the
    creating thread; bearings.http.exchange compares it to tell calls made on the loop thread) }
  ThreadId := GetCurrentThreadId;
  R := SysEpollCreate1(EPOLL_CLOEXEC);
  if R < 0 then
    raise Exception.CreateFmt('epoll_create1 failed: errno %d', [-R]);
  EpFd := cint(R);
  R := SysEventFd2(0, EFD_NONBLOCK or EFD_CLOEXEC);
  if R < 0 then
    raise Exception.CreateFmt('eventfd2 failed: errno %d', [-R]);
  WakeFd := cint(R);
  { the eventfd that other threads write to wake the loop (Post); level-triggered,
    data.ptr = nil marks it in the event batch }
  Ev.Events := EPOLLIN;
  Ev.Data := nil;
  R := SysEpollCtl(EpFd, EPOLL_CTL_ADD, WakeFd, @Ev);
  if R < 0 then
    raise Exception.CreateFmt('epoll_ctl(eventfd) failed: errno %d', [-R]);
  NowNs := MonoNowNs;
  NowMs := NowNs div 1000000;
  FLastBusyNs := NowNs;
  Timers.Init(NowMs);
  Blocks.Init(POOL_DEFAULT_MAX_BYTES);
  FNextTickNs := 0;
  Tick;
  NextConnSeq := 0;
  Sleeping := 0;
  Posting := 0;
  Inbox.Head := nil;
  FStopMsg.Kind := lmCall;
  FStopMsg.Proc := @StopProc;
  FStopMsg.Arg := nil;
end;

destructor TLoop.Destroy;
var
  T: TLoopTask;
begin
  { tasks still queued are not owned by the loop; only the deferred ones }
  while FRunHead <> nil do
  begin
    T := FRunHead;
    FRunHead := T.FRunNext;
    T.FQueued := False;
    T.FRunNext := nil;
  end;
  FRunTail := nil;
  FreeDeferred;
  Assert(AtomicLoad(Posting) = 0, 'TLoop.Destroy: a thread is still inside Post');
  if WakeFd >= 0 then
    SysClose(WakeFd);
  if EpFd >= 0 then
    SysClose(EpFd);
  Blocks.Done;
  inherited Destroy;
end;

function TLoop.NextConnId: QWord;
begin
  Inc(NextConnSeq);
  Result := (QWord(Index) shl 48) or NextConnSeq;
end;

procedure TLoop.PushRun(T: TLoopTask);
begin
  T.FQueued := True;
  T.FRunNext := nil;
  if FRunTail <> nil then
    FRunTail.FRunNext := T
  else
    FRunHead := T;
  FRunTail := T;
end;

{ Runs T once; a Wake during the run queues it again afterwards. }
procedure TLoop.RunTask(T: TLoopTask);
begin
  FCurrent := T;
  T.FRunning := True;
  T.Run;
  T.FRunning := False;
  FCurrent := nil;
  if T.FNotified then
  begin
    T.FNotified := False;
    if not T.FClosed then
      PushRun(T);
  end;
end;

procedure TLoop.DeferFree(T: TLoopTask);
begin
  T.FFreeNext := FFreeList;
  FFreeList := T;
end;

procedure TLoop.FreeDeferred;
var
  L, Nx: TLoopTask;
begin
  L := FFreeList;
  FFreeList := nil;
  while L <> nil do
  begin
    Nx := L.FFreeNext;
    if L.FQueued then
      DeferFree(L)          { still linked in the run queue: freed once it left it }
    else
      L.Free;
    L := Nx;
  end;
end;

procedure TLoop.Tick;
begin
  if Assigned(LoopTickProc) then
    FNextTickNs := NowNs + LoopTickProc(Self)
  else
    FNextTickNs := High(Int64);
end;

{ Takes every message from the inbox (in posting order), appends them to
  FMsgHead and dispatches them. If a handler raises, the rest stay in FMsgHead
  and the next call dispatches them first. }
procedure TLoop.DrainInbox;
var
  M: PLoopMsg;
  Proc: TLoopMsgProc;
  Arg: Pointer;
  Kind: TLoopMsgKind;
  Batch, Tail: PMpscNode;
begin
  Batch := Inbox.TakeAll;
  if Batch <> nil then
  begin
    if FMsgHead = nil then
      FMsgHead := Batch
    else
    begin
      Tail := FMsgHead;
      while Tail^.Next <> nil do
        Tail := Tail^.Next;
      Tail^.Next := Batch;
    end;
  end;
  while FMsgHead <> nil do
  begin
    M := PLoopMsg(FMsgHead);
    FMsgHead := M^.Node.Next;
    { the sender may reuse M as soon as it is dispatched: read it first }
    Kind := M^.Kind;
    Proc := M^.Proc;
    Arg := M^.Arg;
    M^.Node.Next := nil;
    case Kind of
      lmCall:
        Proc(Self, Arg);
    else
      if LoopMsgHandlers[Kind] <> nil then
        LoopMsgHandlers[Kind](Self, Arg);
    end;
  end;
end;

procedure TLoop.ProcessInbox;
begin
  { the loop thread is gone (or this is it): the caller takes its place, so
    loop-thread checks (TExchange.OnOwnLoop) hold for the handlers }
  AtomicStoreThreadId(ThreadId, GetCurrentThreadId);
  if (FMsgHead <> nil) or not Inbox.IsEmpty then
    DrainInbox;
end;

procedure TLoop.RunIteration;
var
  Timeout, Budget: Integer;
  N: SizeInt;
  P: PIoSource;
  T: TLoopTask;
  Ev: Cardinal;
  Cnt: QWord;
begin
  { 1. if an exception interrupted the event batch, resume it without waiting }
  if FEventPos >= FEventCount then
  begin
    { 2. wait: do not block (timeout 0) if work is queued; else block until
      the next timer, or without limit when there is none }
    if (FRunHead <> nil) or (FMsgHead <> nil) or not Inbox.IsEmpty then
      Timeout := 0
    else
    begin
      if Timers.IsEmpty then
        Timeout := -1
      else
        Timeout := Timers.NextTimeoutMs(MonoNowNs);
      { pooled blocks: wake after 1 s idle to give unused ones back to the heap }
      if (Blocks.PooledBytes > 0) and ((Timeout < 0) or (Timeout > 1000)) then
        Timeout := 1000;
    end;
    { Sleeping := 1 and then a last inbox check: a Post that pushed before the
      store is seen here; one that pushes after it sees Sleeping = 1 and writes
      the eventfd (AtomicXchg is a full barrier) }
    if Timeout <> 0 then
    begin
      AtomicXchg(Sleeping, 1);
      if not Inbox.IsEmpty then
        Timeout := 0;
    end;
    N := SysEpollWait(EpFd, @FEvents[0], MAX_EVENTS, Timeout);
    AtomicStore(Sleeping, 0);
    Inc(Waits);
    if N < 0 then
      N := 0;                                { EINTR: a signal interrupted the wait }
    FEventCount := Integer(N);
    FEventPos := 0;
    { 3. clock, tick hook, idle trim of the block pool }
    NowNs := MonoNowNs;
    NowMs := NowNs div 1000000;
    if NowNs >= FNextTickNs then
      Tick;
    if N > 0 then
      FLastBusyNs := NowNs
    else if (Timeout <> 0) and (NowNs - FLastBusyNs >= IDLE_TRIM_NS) then
    begin
      Blocks.Trim;
      Inc(Trims);
      FLastBusyNs := NowNs;
    end;
  end;
  { 4. the event batch, then the inbox }
  while FEventPos < FEventCount do
  begin
    P := PIoSource(FEvents[FEventPos].Data);
    Ev := FEvents[FEventPos].Events;
    Inc(FEventPos);
    if P = nil then
      SysRead(WakeFd, @Cnt, SizeOf(Cnt))     { reading resets the eventfd counter to 0, so it stops being reported; the inbox is drained below }
    else
    begin
      T := P^.Task;
      if not T.FClosed then
      begin
        FCurrent := T;
        TIoTask(T).OnIo(Ev);
        FCurrent := nil;
      end;
    end;
  end;
  if (FMsgHead <> nil) or not Inbox.IsEmpty then
    DrainInbox;
  { 5. timers due at NowMs }
  Timers.Advance(NowMs);
  { 6. run queue, at most RUN_QUEUE_BUDGET tasks, so a task that keeps waking
    itself cannot delay socket events; the rest run next iteration (epoll_wait
    gets timeout 0 then) }
  Budget := RUN_QUEUE_BUDGET;
  while (Budget > 0) and (FRunHead <> nil) do
  begin
    T := FRunHead;
    FRunHead := T.FRunNext;
    if FRunHead = nil then
      FRunTail := nil;
    T.FRunNext := nil;
    T.FQueued := False;
    if T.FClosed then
      Continue;
    RunTask(T);
    Dec(Budget);
  end;
  { 7. free the tasks closed in this iteration }
  FCurrent := nil;
  if FFreeList <> nil then
    FreeDeferred;
end;

{ Called with the exception that escaped RunIteration: reports it, then aborts
  and closes the task that was running (if any). }
procedure TLoop.AbortCurrent(E: Exception);
var
  T: TLoopTask;
begin
  T := FCurrent;
  FCurrent := nil;
  if LoopErrorProc <> nil then
    LoopErrorProc(Self, T, E);
  if T = nil then
    Exit;
  Inc(Aborts);
  T.FRunning := False;
  T.FNotified := False;
  if not T.FClosed then
  begin
    try
      T.Abort;
    except
      on E2: Exception do
        if LoopErrorProc <> nil then
          LoopErrorProc(Self, T, E2);
    end;
    T.Close;
  end;
end;

procedure TLoop.Run;
begin
  AtomicStoreThreadId(ThreadId, GetCurrentThreadId);
  { one try/except (one setjmp) for many iterations: re-entered only after an
    exception, which aborts the task that raised it }
  while not FStopped do
    try
      repeat
        RunIteration;
      until FStopped;
    except
      on E: Exception do
        AbortCurrent(E);
    end;
  FreeDeferred;
end;

procedure TLoop.Post(M: PLoopMsg);
var
  One: QWord;
  First: Boolean;
begin
  { the message may be handled (and, for an exchange's last FreeMsg, the
    exchange given back to its pool) as soon as it is pushed, while this
    call still uses the loop below: Posting tells a thread that frees the
    loop to wait. The increment comes before the push (both are locked
    instructions: a thread that saw the message handled sees the count) }
  AtomicInc(Posting);
  {$ifopt C+}
  if Assigned(PostBeforePushHook) then
    PostBeforePushHook(Self);
  {$endif}
  First := Inbox.Push(@M^.Node);
  {$ifopt C+}
  if Assigned(PostAfterPushHook) then
    PostAfterPushHook(Self);
  {$endif}
  { only the push that made the inbox non-empty may need to wake the loop
    (later pushes find a wakeup already on its way); the eventfd write is a
    system call, so it is skipped when the loop is not blocked in epoll_wait }
  if First and (AtomicXchg(Sleeping, 0) = 1) then
  begin
    One := 1;
    SysWrite(WakeFd, @One, SizeOf(One));
    AtomicInc64(Int64(WakeWrites));
  end;
  { the last access of this call to the loop; HappensBefore/HappensAfter are
    annotations for the DRD race checker (empty in normal builds) }
  HappensBefore(@Posting);
  AtomicDec(Posting);
end;

function TLoop.PostsInProgress: LongInt;
begin
  Result := AtomicLoad(Posting);
  if Result = 0 then
    HappensAfter(@Posting);
end;

function TLoop.Register(Src: PIoSource; Events: Cardinal): Boolean;
var
  Ev: TEpollEvent;
begin
  Ev.Events := Events;
  Ev.Data := Src;
  Result := SysEpollCtl(EpFd, EPOLL_CTL_ADD, Src^.Fd, @Ev) = 0;
end;

procedure TLoop.Unregister(Src: PIoSource);
var
  Ev: TEpollEvent;
begin
  Ev.Events := 0;
  Ev.Data := nil;
  SysEpollCtl(EpFd, EPOLL_CTL_DEL, Src^.Fd, @Ev);
end;

function LoopThreadMain(Arg: Pointer): PtrInt;
begin
  TLoop(Arg).Run;
  Result := 0;
end;

procedure TLoop.Start;
begin
  FStarted := True;
  FThread := BeginThread(@LoopThreadMain, Pointer(Self));
end;

procedure TLoop.RequestStop;
begin
  if InterlockedExchange(FStopPosted, 1) = 0 then
    Post(@FStopMsg);
end;

procedure TLoop.StopNow;
begin
  FStopped := True;
end;

procedure TLoop.WaitFor;
begin
  if FStarted then
  begin
    WaitForThreadTerminate(FThread, 0);
    CloseThread(FThread);
    FStarted := False;
  end;
end;

initialization
  LoopErrorProc := @DefaultLoopError;
end.

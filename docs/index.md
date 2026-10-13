# Bearings tutorial

Bearings is an HTTP/1.1 server library for Free Pascal. It runs one event
loop per CPU, keeps a pool of worker threads for code that blocks, and
hands your program one `TExchange` per request: the parsed request and the
response to fill in. It runs on Linux only, because it calls epoll,
eventfd, accept4, sendfile and writev directly.

This tutorial takes you through the library step by step, from a server
that answers "Hello" to a small key-value store that reads request bodies,
streams responses, and serves a WebSocket chat. Each chapter builds on the
one before it and ends with a program you can compile and try with curl.

## Bearings' role in your program

A network server has to serve many connections at once while most of them
are idle. The usual Free Pascal answer is a thread per connection, which
works until the connection count grows, and which spends its time in
`Sleep`, blocking reads and lock contention. Bearings takes the other
approach: a fixed number of threads, each running an event loop that asks
the kernel which sockets are ready and runs the code of those sockets
only. Your code is called when there is something to do and must return
quickly.

Bearings gives you:

- The event loops, with timers, a buffer pool and a message inbox per
  loop, so that per-loop state needs no locks.
- An HTTP/1.1 parser, encoder and body codec that handle keep-alive,
  pipelining, chunked bodies, trailers, `Expect: 100-continue` and
  connection upgrades.
- A worker pool for code that blocks, with backpressure between a worker
  and the loop that owns the connection.
- A WebSocket implementation (RFC 6455) with pub/sub topics.
- A `TServer` that ties them together: listeners, signals, graceful
  shutdown, a connection limit, an access log, metrics, and systemd socket
  activation and watchdog notifications.

It has no TLS and no HTTP/2. Put a reverse proxy such as nginx in front of
it for both, and turn on the PROXY protocol so the client's address is
still known behind the proxy.

## Advantages

- The path for a request answered on the loop thread allocates nothing
  and touches no atomic instruction. On the plaintext benchmark the library
  runs at 0.85 to 0.98 of hyper, the Rust HTTP library
  (`docs/perf-report.md`).
- A connection is accepted by one loop and stays there, and every queue
  in the library is bounded: a slow client slows its producer down instead
  of making the server buffer everything.
- There is no build step and no dependency beyond the Free Pascal RTL. A
  program puts five directories on its unit path and compiles.
- Every public routine has a documented threading rule (`docs/api.md`,
  section 14), and a build with assertions checks the rules at run time.

## When not to use Bearings

- You need TLS or HTTP/2 in the process. Bearings speaks plain HTTP/1.1.
  A reverse proxy covers both, but if you cannot run one, Bearings is not
  the right choice.
- You want a web framework. Bearings has no router, no templates and no
  sessions. It is the layer a framework would be built on.
- Your program runs on Windows, macOS or BSD. The library calls Linux
  system calls directly.
- Your handlers are CPU-bound. The worker pool keeps blocking code off
  the loops, but a server whose work is long computation is better served
  by a thread per CPU and a plain blocking socket library.

## Getting help

`docs/api.md` is the API guide, organized by what a program does.
`docs/design.md` explains the decisions behind the library and the
invariants a contributor must respect. The header comment of every unit
under `src/` describes that unit. The programs under `examples/` are complete
and commented; four of them are the ones this tutorial writes.

---

## 1. Setup

You need Free Pascal 3.2.2 on Linux x86_64 (an ARM64 build exists but has
only run under emulation; see `README.md`, section "ARM64"). Check the
compiler:

```sh
fpc -iV
```

Get the library and make a directory for the programs of this tutorial:

```sh
git clone <bearings repository> bearings
cd bearings
mkdir -p build/tutorial/units
```

Every program in this tutorial compiles with the same command, run from
the repository root:

```sh
fpc -Mobjfpc -Sh -O2 -Fusrc/rt -Fusrc/http -Fusrc/http1 -Fusrc/server -Fusrc/ws \
    -FUbuild/tutorial/units -FEbuild/tutorial <program>.pas
```

`-Mobjfpc -Sh` select the Object Pascal mode with long strings, which every
unit of the library uses. The five `-Fu` options are the library's unit
directories; `-FU` is where compiled units go and `-FE` where the
executable goes. If you install the units as a package
(`tools/install-package.sh`), the `-Fu` options go away.

You will also want `curl`, and for the WebSocket chapter a client such as
`websocat`.

## 2. Hello Bearings

We start with the smallest server: one service that answers "Hello" to
every request.

### The code

Write this to `hello.pas` (it is also `examples/hello.pas`, with more
comments):

```pascal
program hello;

{$mode objfpc}{$H+}

uses
  cthreads, SysUtils, bearings.rt.loop, bearings.rt.buf, bearings.http.headers,
  bearings.http.exchange, bearings.server;

const
  GREETING: array[0..5] of AnsiChar = 'Hello'#10;

type
  THelloCall = class(TServiceCall)
  public
    function Poll(Ex: TExchange): TCallPoll; override;
  end;

  THelloService = class(THttpService)
  private
    FCall: THelloCall;
  public
    constructor Create;
    destructor Destroy; override;
    function Call(Ex: TExchange): TServiceCall; override;
  end;

function THelloCall.Poll(Ex: TExchange): TCallPoll;
begin
  Ex.ResponseHeaders.Add('content-type', 'text/plain');
  Ex.Respond(BodyStatic(@GREETING[0], Length(GREETING)));
  Result := cpReady;
end;

constructor THelloService.Create;
begin
  inherited Create;
  FCall := THelloCall.Create;
end;

destructor THelloService.Destroy;
begin
  FCall.Free;
  inherited Destroy;
end;

function THelloService.Call(Ex: TExchange): TServiceCall;
begin
  Result := FCall;
end;

function NewService(Loop: TLoop): THttpService;
begin
  Result := THelloService.Create;
end;

procedure Started(Server: TServer);
begin
  WriteLn(StdErr, 'hello: listening on port ', Server.Port, ' with ', Server.LoopCount, ' loops');
end;

var
  Cfg: TServerConfig;
  Srv: TServer;
  Sig: Integer;
begin
  Cfg := ProductionServerConfig;
  Cfg.Workers := NO_WORKER_POOL;     { answers inline: no worker threads }
  Cfg.Listen.Port := StrToIntDef(ParamStr(1), 8080);
  ApplySdListenFds(Cfg);             { under systemd: the passed socket }
  Srv := TServer.CreateWithProc(Cfg, @NewService);
  Sig := Srv.RunUntilSignalProc(@Started);   { until SIGTERM or SIGINT }
  WriteLn(StdErr, 'hello: stopped (signal ', Sig, ')');
  Srv.Free;
end.
```

Compile and run it:

```sh
fpc -Mobjfpc -Sh -O2 -Fusrc/rt -Fusrc/http -Fusrc/http1 -Fusrc/server -Fusrc/ws \
    -FUbuild/tutorial/units -FEbuild/tutorial hello.pas
build/tutorial/hello 8080
```

In another terminal:

```sh
$ curl -i http://127.0.0.1:8080/
HTTP/1.1 200 OK
content-type: text/plain
content-length: 6
date: Tue, 13 Oct 2026 00:01:21 GMT

Hello
```

Stop the server with Ctrl-C. It prints `hello: stopped (signal 2)` and
exits.

### Breaking it down

Three things happen in this program: a server is configured and started,
a service is created for each event loop, and a call answers each request.

#### The server

```pascal
Cfg := ProductionServerConfig;
Cfg.Workers := NO_WORKER_POOL;
Cfg.Listen.Port := StrToIntDef(ParamStr(1), 8080);
```

`TServerConfig` is a plain record. `ProductionServerConfig` is a preset:
listen on `0.0.0.0:8080` with a backlog of 4096, one event loop per CPU,
a 30 second timeout for a client that does not send a complete request
head, a worker pool, and a 30 second grace period at shutdown. The program
changes two fields: the port, and `Workers`, which it sets to
`NO_WORKER_POOL` because this service answers every request on the loop
thread and would never use the pool. With the default, the server would
start a pool of threads that sit idle.

```pascal
Srv := TServer.CreateWithProc(Cfg, @NewService);
Sig := Srv.RunUntilSignalProc(@Started);
```

`CreateWithProc` stores the configuration and the service factory. Nothing
runs yet. `RunUntilSignalProc` does the rest: it validates the
configuration, binds the port, starts one event loop thread per CPU, calls
the factory once per loop, calls `Started`, and then waits on the calling
thread for SIGTERM or SIGINT. On the signal it stops the server
gracefully, which means open connections finish the response they are
writing, then joins every thread and returns the signal number.

There are two forms of each of these calls. `CreateWithProc` and
`RunUntilSignalProc` take plain routines. `Create` and `RunUntilSignal`
take methods of an object, for a program that keeps state (the later
chapters use them). The compiler cannot tell the two pointer kinds apart
in an overload, hence the separate names.

#### The service

```pascal
function NewService(Loop: TLoop): THttpService;
begin
  Result := THelloService.Create;
end;
```

The factory is called once per event loop, on the thread that owns the
server, before the loops start. So there is one `THelloService` instance
per loop, and each loop only ever touches its own. This is the library's
answer to shared state: there is none by default. Chapter 4 is about what
to do when you need some.

For every request a loop parses, it calls `THelloService.Call` with the
exchange. `Call` runs on the loop thread and does one thing: it picks the
call object that will handle the request. It must not answer the request
or read the body, and a build with assertions (`-Sa`) checks that. Here
the service returns the same `THelloCall` for every request, because the
call keeps no state and one instance serves all of them.

#### The call

```pascal
function THelloCall.Poll(Ex: TExchange): TCallPoll;
begin
  Ex.ResponseHeaders.Add('content-type', 'text/plain');
  Ex.Respond(BodyStatic(@GREETING[0], Length(GREETING)));
  Result := cpReady;
end;
```

`Poll` is where the request is handled. The loop calls it, on the loop
thread, every time the connection runs while the call is in flight. Our
call answers at once: it adds one response header, makes the **terminal
call** `Respond` with a body, and returns `cpReady`.

The terminal call is the central idea of the exchange. Every request gets
exactly one: `Respond` for a body of known length, `BeginStream` for a
body produced piece by piece, `RespondStream` for a body source of your
own, or `Fail` when nothing sensible can be sent. `Poll` returns `cpReady`
after it was made, or `cpPending` when the answer is not ready yet.
Returning `cpReady` without a terminal call is a program error: the
connection closes and a counter is incremented.

`BodyStatic` wraps memory that outlives the write, here a constant, so
nothing is allocated per request. The encoder writes the `Content-Length`
header itself from the body's length, and adds a `Date` header. You never
set either.

#### What is an event loop?

The server has one thread per CPU. Each thread runs a loop: it asks the
kernel which of its sockets are ready (`epoll_wait`), runs the code of
each ready connection until that connection would block again, and goes
back to waiting. Every socket is non-blocking. A connection is accepted by
one loop and stays on that loop for its whole life.

One loop thread serves thousands of connections, so **code on a loop
thread must never block**: no `Sleep`, no blocking file or socket call,
no waiting on a lock that another thread holds for long. A blocked loop
thread stalls every connection on that loop. Chapter 5 shows what to do
with code that has to block.

If you know Rust's `Future::poll`, `TServiceCall.Poll` is the same shape:
a method called repeatedly, returning "ready" or "pending", with a wake-up
mechanism for the pending case. Chapter 8 looks at that mechanism.

#### `cthreads`

The `uses` clause starts with `cthreads`. It has to: the server creates
threads, and on Linux the RTL's thread support is in that unit, which must
be the first unit initialized. A program that forgets it fails at the
first thread creation.

## 3. Handling requests

We are going to build a key-value store over HTTP. `GET /kv/<key>` returns
the value and `PUT /kv/<key>` sets it. For now the value travels in the
query string, `PUT /kv/hello?world`; reading a request body is chapter 6.

### The request head

The exchange gives you the request head as byte slices into the
connection's read buffer: `Method` (an enumeration, `hmGet`, `hmPut` and
so on from unit `bearings.http1.role`), `Path`, `Query`, `Headers`, and
`Header(Name, out V)` for one header. A `TByteSlice` is a pointer and a
length. The bytes are not copied, and they are valid only until the
request is released, which happens at the latest when the call completes.
To keep a value, copy it: `SliceToStr(S)` makes a `RawByteString`.
`SliceEquals(S, Text)` compares without copying, and `PathIs(Ex, Text)`
compares the path.

### The code

Write this to `kv1.pas` (it is also `examples/kv1.pas`):

```pascal
program kv1;

{$mode objfpc}{$H+}

uses
  cthreads, SysUtils, fgl, bearings.rt.loop, bearings.http1.role,
  bearings.http.exchange, bearings.server;

type
  TStore = specialize TFPGMap<RawByteString, RawByteString>;

  TKvCall = class(TServiceCall)
  private
    FStore: TStore;
    FLoopIndex: Integer;
  public
    constructor Create(Loop: TLoop);
    destructor Destroy; override;
    function Poll(Ex: TExchange): TCallPoll; override;
  end;

  TKvService = class(THttpService)
  private
    FCall: TKvCall;
  public
    constructor Create(Loop: TLoop);
    destructor Destroy; override;
    function Call(Ex: TExchange): TServiceCall; override;
  end;

constructor TKvCall.Create(Loop: TLoop);
begin
  inherited Create;
  FStore := TStore.Create;
  FLoopIndex := Loop.Index;
end;

destructor TKvCall.Destroy;
begin
  FStore.Free;
  inherited Destroy;
end;

function TKvCall.Poll(Ex: TExchange): TCallPoll;
var
  Path, Key, Value: RawByteString;
  Q: TByteSlice;
begin
  Result := cpReady;
  Ex.ResponseHeaders.Add('x-loop', IntToStr(FLoopIndex));
  Path := SliceToStr(Ex.Path);
  if Copy(Path, 1, 4) <> '/kv/' then
  begin
    Ex.RespondText(404, 'not found'#10);
    Exit;
  end;
  Key := Copy(Path, 5, MaxInt);
  case Ex.Method of
    hmGet:
      if FStore.TryGetData(Key, Value) then
        Ex.RespondText(200, Value + #10)
      else
        Ex.RespondText(404, 'no such key'#10);
    hmPut:
      begin
        if Ex.Query(Q) then
          Value := SliceToStr(Q)
        else
          Value := '';
        FStore[Key] := Value;
        Ex.RespondText(200, 'stored'#10);
      end;
  else
    Ex.RespondText(405, 'method not allowed'#10);
  end;
end;

constructor TKvService.Create(Loop: TLoop);
begin
  inherited Create;
  FCall := TKvCall.Create(Loop);
end;

destructor TKvService.Destroy;
begin
  FCall.Free;
  inherited Destroy;
end;

function TKvService.Call(Ex: TExchange): TServiceCall;
begin
  Result := FCall;
end;

function NewService(Loop: TLoop): THttpService;
begin
  Result := TKvService.Create(Loop);
end;

var
  Cfg: TServerConfig;
  Srv: TServer;
begin
  Cfg := ProductionServerConfig;
  Cfg.Workers := NO_WORKER_POOL;
  Cfg.Listen.Port := StrToIntDef(ParamStr(1), 8080);
  Cfg.Loops := StrToIntDef(ParamStr(2), 0);
  Srv := TServer.CreateWithProc(Cfg, @NewService);
  Srv.RunUntilSignalProc(nil);
  Srv.Free;
end.
```

New here:

- `RespondText(Status, Text)` sets the status, sets the `Content-Type`
  header (`text/plain; charset=utf-8` by default) and responds with the
  text, in one call. It is the right tool for error answers and for
  handlers that build a string anyway.
- The call object now has state, a map, so there is one per loop, created
  with the service. The factory receives the `TLoop`, and `Loop.Index` is
  the loop's number, which the program reports in an `x-loop` header so we
  can see which loop answered.
- `Cfg.Loops` is the number of event loops; 0 means one per CPU. The
  program takes it from the command line so we can experiment.

### Running it

Start the server with four loops:

```sh
build/tutorial/kv1 8080 4
```

Store a value and read it back a few times:

```sh
$ curl -s -X PUT 'http://127.0.0.1:8080/kv/hello?world'
stored
$ for i in 1 2 3 4 5 6; do curl -si http://127.0.0.1:8080/kv/hello | grep -E 'x-loop|world|no such'; done
x-loop: 2
world
x-loop: 1
no such key
x-loop: 1
no such key
x-loop: 3
no such key
x-loop: 0
no such key
x-loop: 2
world
```

Only one loop has the value. Each `curl` opens a new connection, the
kernel spreads new connections over the four loops, and only the loop that
served the `PUT` has the key. The other three have their own empty map.
Our server has four stores, one per loop, which is what the code asked
for: per-loop state needs no lock, and the library does not share anything
across loops on its own.

Sometimes that is what you want: a cache per loop, a counter per loop
added up at reporting time. For a key-value store it is not. The next
chapter shares the map.

## 4. Shared state

To share the map, we keep one `TStore` for the whole server and protect
it with a lock. Every loop reaches it through the same object.

### The code

`kv2.pas` (also `examples/kv2.pas`) is `kv1.pas` with the store pulled out of the call:

```pascal
program kv2;

{$mode objfpc}{$H+}

uses
  cthreads, SysUtils, fgl, syncobjs, bearings.rt.loop, bearings.http1.role,
  bearings.http.exchange, bearings.server;

type
  TMap = specialize TFPGMap<RawByteString, RawByteString>;

  { one for the whole server; every loop uses it under the lock }
  TStore = class
  private
    FLock: TCriticalSection;
    FMap: TMap;
  public
    constructor Create;
    destructor Destroy; override;
    function Get(const Key: RawByteString; out Value: RawByteString): Boolean;
    procedure Put(const Key, Value: RawByteString);
  end;

  TKvCall = class(TServiceCall)
  private
    FStore: TStore;
  public
    constructor Create(Store: TStore);
    function Poll(Ex: TExchange): TCallPoll; override;
  end;

  TKvService = class(THttpService)
  private
    FCall: TKvCall;
  public
    constructor Create(Store: TStore);
    destructor Destroy; override;
    function Call(Ex: TExchange): TServiceCall; override;
  end;

  TApp = class
    Store: TStore;
    function NewService(Loop: TLoop): THttpService;
  end;

constructor TStore.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FMap := TMap.Create;
end;

destructor TStore.Destroy;
begin
  FMap.Free;
  FLock.Free;
  inherited Destroy;
end;

function TStore.Get(const Key: RawByteString; out Value: RawByteString): Boolean;
begin
  FLock.Enter;
  try
    Result := FMap.TryGetData(Key, Value);
  finally
    FLock.Leave;
  end;
end;

procedure TStore.Put(const Key, Value: RawByteString);
begin
  FLock.Enter;
  try
    FMap[Key] := Value;
  finally
    FLock.Leave;
  end;
end;

constructor TKvCall.Create(Store: TStore);
begin
  inherited Create;
  FStore := Store;
end;

function TKvCall.Poll(Ex: TExchange): TCallPoll;
var
  Path, Key, Value: RawByteString;
  Q: TByteSlice;
begin
  Result := cpReady;
  Path := SliceToStr(Ex.Path);
  if Copy(Path, 1, 4) <> '/kv/' then
  begin
    Ex.RespondText(404, 'not found'#10);
    Exit;
  end;
  Key := Copy(Path, 5, MaxInt);
  case Ex.Method of
    hmGet:
      if FStore.Get(Key, Value) then
        Ex.RespondText(200, Value + #10)
      else
        Ex.RespondText(404, 'no such key'#10);
    hmPut:
      begin
        if Ex.Query(Q) then
          Value := SliceToStr(Q)
        else
          Value := '';
        FStore.Put(Key, Value);
        Ex.RespondText(200, 'stored'#10);
      end;
  else
    Ex.RespondText(405, 'method not allowed'#10);
  end;
end;

constructor TKvService.Create(Store: TStore);
begin
  inherited Create;
  FCall := TKvCall.Create(Store);
end;

destructor TKvService.Destroy;
begin
  FCall.Free;
  inherited Destroy;
end;

function TKvService.Call(Ex: TExchange): TServiceCall;
begin
  Result := FCall;
end;

function TApp.NewService(Loop: TLoop): THttpService;
begin
  Result := TKvService.Create(Store);
end;

var
  Cfg: TServerConfig;
  App: TApp;
  Srv: TServer;
begin
  Cfg := ProductionServerConfig;
  Cfg.Workers := NO_WORKER_POOL;
  Cfg.Listen.Port := StrToIntDef(ParamStr(1), 8080);
  App := TApp.Create;
  App.Store := TStore.Create;
  Srv := TServer.Create(Cfg, @App.NewService);
  Srv.RunUntilSignal(nil);
  Srv.Free;
  App.Store.Free;
  App.Free;
end.
```

The factory is now a method, `TApp.NewService`, because it has to reach
the store, so the program uses `TServer.Create` and `RunUntilSignal`
instead of the `Proc` forms. The store is freed after the server, when no
loop can touch it any more.

```sh
$ build/tutorial/kv2 8080 &
$ curl -s -X PUT 'http://127.0.0.1:8080/kv/hello?world'
stored
$ for i in 1 2 3 4; do curl -s http://127.0.0.1:8080/kv/hello; done
world
world
world
world
```

### Locks on the loop thread

The rule from chapter 2 was that a loop thread must never block. A lock
blocks when another thread holds it. So a lock is acceptable on the loop
thread only when every holder keeps it for a few instructions: a map
lookup, an increment, a copy. Our `TStore` does that: the string copy
happens inside the lock, and nothing else.

What must not happen under the lock: I/O, `Sleep`, a call into code that
may take another lock, or anything that waits on a worker. If the work
under the lock is long, it belongs on a worker thread (chapter 5), where
blocking is allowed.

With many loops hammering one lock, the lock itself becomes the limit.
Two ways out, both outside the library:

- **Shard.** Keep N stores, each with its own lock, and pick one by a
  hash of the key. Contention drops by N.
- **Keep the state per loop and send messages.** Every loop has an inbox
  (`TLoop.Post`); a thread can post a message that runs a procedure on
  the loop, and the loop handles it between its sockets. The WebSocket
  pub/sub of chapter 9 is built this way: one publish becomes one message
  per loop, and each loop delivers to its own connections with no lock on
  the connection list.

## 5. Blocking code: the worker pool

So far every request was answered inside `Poll`, on the loop thread, in
microseconds. Real handlers query databases, read files, call other
services. That code blocks, and it cannot run on a loop.

Bearings keeps a pool of worker threads for it. A request is handed to
the pool, a worker runs your handler, and the handler may block as long
as it likes: the loop goes on serving its other connections meanwhile.
When the handler answers, the loop is woken and writes the response.

### The code

`kv3.pas` (also `examples/kv3.pas`) moves the key-value store to the worker pool, and while it is
there, `PUT` now takes the value from the request body, where it belongs:

```pascal
program kv3;

{$mode objfpc}{$H+}

uses
  cthreads, SysUtils, fgl, syncobjs, bearings.rt.loop, bearings.http1.role,
  bearings.http.exchange, bearings.server;

const
  VALUE_LIMIT = 64 * 1024;          { ReadAll refuses a larger body }

type
  TMap = specialize TFPGMap<RawByteString, RawByteString>;

  TStore = class
  private
    FLock: TCriticalSection;
    FMap: TMap;
  public
    constructor Create;
    destructor Destroy; override;
    function Get(const Key: RawByteString; out Value: RawByteString): Boolean;
    procedure Put(const Key, Value: RawByteString);
  end;

  { runs on a worker thread; may block }
  TKvHandler = class(TBlockingHandler)
  private
    FStore: TStore;
  public
    constructor Create(Store: TStore);
    procedure Run(Ex: TExchange); override;
  end;

  TKvService = class(THttpService)
  private
    FCall: TOffloadCall;
  public
    constructor Create(Srv: TServer; H: TBlockingHandler);
    destructor Destroy; override;
    function Call(Ex: TExchange): TServiceCall; override;
  end;

  TApp = class
    Srv: TServer;
    Store: TStore;
    Handler: TKvHandler;
    function NewService(Loop: TLoop): THttpService;
  end;

{ TStore is the same as in kv2.pas }

constructor TKvHandler.Create(Store: TStore);
begin
  inherited Create;
  FStore := Store;
end;

procedure TKvHandler.Run(Ex: TExchange);
var
  Path, Key, Value: RawByteString;
  Body: TBytes;
  N: SizeInt;
begin
  Path := SliceToStr(Ex.Path);
  if Copy(Path, 1, 4) <> '/kv/' then
  begin
    Ex.RespondText(404, 'not found'#10);
    Exit;
  end;
  Key := Copy(Path, 5, MaxInt);
  case Ex.Method of
    hmGet:
      if FStore.Get(Key, Value) then
        Ex.RespondText(200, Value + #10)
      else
        Ex.RespondText(404, 'no such key'#10);
    hmPut:
      begin
        try
          N := Ex.ReadAll(Body, VALUE_LIMIT);     { blocks until the body ended }
        except
          on EBodyTooLarge do
          begin
            Ex.RespondText(413, 'value too large'#10);
            Exit;
          end;
          on E: EBodyError do
          begin
            Ex.RespondText(400, 'bad request body: ' + Ex.BodyErrorMessage + #10);
            Exit;
          end;
          on EClientGone do
            Exit;                                 { nobody to answer }
        end;
        SetString(Value, PAnsiChar(Body), N);
        FStore.Put(Key, Value);
        Ex.RespondText(200, 'stored'#10);
      end;
  else
    Ex.RespondText(405, 'method not allowed'#10);
  end;
end;

constructor TKvService.Create(Srv: TServer; H: TBlockingHandler);
begin
  inherited Create;
  FCall := TOffloadCall.Create;
  FCall.Pool := Srv.Workers;        { the pool exists before the services are created }
  FCall.Handler := H;
end;

destructor TKvService.Destroy;
begin
  FCall.Free;
  inherited Destroy;
end;

function TKvService.Call(Ex: TExchange): TServiceCall;
begin
  Result := FCall;
end;

function TApp.NewService(Loop: TLoop): THttpService;
begin
  Result := TKvService.Create(Srv, Handler);
end;

var
  Cfg: TServerConfig;
  App: TApp;
begin
  Cfg := ProductionServerConfig;    { Workers = 0: a pool of Min(32, cpus + 4) threads }
  Cfg.Listen.Port := StrToIntDef(ParamStr(1), 8080);
  App := TApp.Create;
  App.Store := TStore.Create;
  App.Handler := TKvHandler.Create(App.Store);
  App.Srv := TServer.Create(Cfg, @App.NewService);
  App.Srv.RunUntilSignal(nil);
  App.Srv.Free;                     { after this no worker runs the handler }
  App.Handler.Free;
  App.Store.Free;
  App.Free;
end.
```

```sh
$ build/tutorial/kv3 8080 &
$ curl -s -X PUT --data-binary 'world from the body' http://127.0.0.1:8080/kv/hello
stored
$ curl -s http://127.0.0.1:8080/kv/hello
world from the body
$ head -c 100000 /dev/zero | curl -si -X PUT --data-binary @- http://127.0.0.1:8080/kv/big | head -1
HTTP/1.1 413 Payload Too Large
```

### Breaking it down

The handler is a `TBlockingHandler`. Its `Run` method runs on a worker
thread and must make exactly one terminal call, the same rule as `Poll`.
The service returns a `TOffloadCall`, a ready-made call object: its first
`Poll` hands the exchange to the pool and returns `cpPending`; the worker
runs `Run`; the worker's terminal call wakes the connection; the next
`Poll` sees the exchange answered and returns `cpReady`.

One `TOffloadCall` serves every request of a loop, and one `TKvHandler`
serves every worker, because neither has per-request state. The handler
reads the store through the same lock as before. A worker may block on
the lock, but a short critical section is still the right design: a loop
thread could also be waiting on it.

`Cfg.Workers` is left at the production default, 0, which means a pool of
`Min(32, cpus + 4)` threads. The pool is created in `Start` before the
services, so the factory can read `Srv.Workers`.

`ReadAll` blocks until the whole body arrived, appends it to a `TBytes`
and returns the byte count. It raises `EBodyTooLarge` when the body is
over the limit, `EBodyError` when the body could not be read (a malformed
chunked encoding, the body timeout, a connection failure), and
`EClientGone` when the client disconnected: nothing can be sent then, and
the handler just returns. Chapter 6 has the other ways to read a body.

### When a request should not be offloaded

Each offloaded request costs a thread hand-off, about 2.5 microseconds on
the benchmark machine, plus a few atomic operations. A handler that only
looks at the head and answers from memory is better off inline, as in
chapters 2 to 4. A service can mix the two: `Call` sees the request head
and returns an inline call for some paths and the `TOffloadCall` for
others.

`TOffloadCall.SaturatedStatus` is for a pool that cannot keep up. With
`Cfg.WorkerQueueLimit` set and `SaturatedStatus := 503`, a request that
finds the queue at its limit is answered on the loop thread at once, with
a `Retry-After: 1` header, and the handler never runs for it.

### Your own threads

`Offload` is built on three calls you can use directly. `Ex.Share` (on the
loop thread, for example inside `Poll`) switches the exchange to shared
mode and gives you a reference you may use from any thread. `Ex.Release`
gives it back. `Ex.Wake` runs the connection again so that `Poll` is
called. A producer of server-sent events on a thread of its own works this
way: `Share` and `BeginStream` in `Poll`, return `cpPending`; the thread
writes and finally calls `Finish` and `Release`.

## 6. Request bodies

The connection decodes the request body (`Content-Length` or chunked) and
passes it to your handler one chunk at a time. The next chunk is read from
the socket only after the handler took the previous one, so a slow handler
slows the client down instead of making the server buffer the body. A
chunk is a view into the read buffer, valid until the next body call.

### What the head tells you

`Ex.ContentLength` is the declared length: 0 for no body, -1 for a chunked
body. `Ex.ExpectsContinue` is True when the client sent `Expect:
100-continue` and waits for `100 Continue` before uploading. The server
sends that interim response when your handler first reads the body, so a
handler that rejects the request without reading spares the client the
upload. To say "I do not want the rest", call `Ex.DiscardBody`: the
connection reads and discards it, or closes.

### On a worker thread

Four blocking reads, all of which park the worker until data arrives:

- `ReadAll(var Dst: TBytes; Limit)`: the whole body, with a size limit.
  The simplest, and the one `kv3.pas` uses.
- `Read(Buf, Max)`: copies up to `Max` bytes; 0 at the end.
- `ReadChunk(out Chunk)`: the next chunk without a copy; False at the end.
- `ReadFrame(out Chunk)`: like `ReadChunk` but also reports the trailers.

A handler that processes a large upload chunk by chunk, writing each to a
file, uses `ReadChunk` and never holds more than one chunk in memory.

### On the loop thread

`TryRead(out Chunk)` never blocks. It returns `brData` with a chunk,
`brEnd` when the body ended, `brPending` when nothing has arrived yet, or
`brError` and `brCanceled`. On `brPending` the call returns `cpPending`
and is polled again when data arrives. The call object has to remember
where it was in the body between polls: `Ex.Tag` (a `PtrInt`) and
`Ex.User` (a `TObject`) are per-request fields reserved for that, reset
at every request. Reading a body inline is more work than on a worker; do
it when you have measured that the hand-off matters.

## 7. Response bodies

### A body of known length

`Respond(Body)` sends the head and a body with a `Content-Length`. The body
is a `TBodyData` record built by one of the constructors of unit
`bearings.rt.buf`:

| Constructor | Memory | Released how |
| --- | --- | --- |
| `BodyEmpty` | none | nothing to do |
| `BodyStatic(P, Len)` | memory that outlives the write (a constant, a global) | nothing to do |
| `BodyString(S)` | the bytes of a `RawByteString`, no copy | one reference held until written |
| `BodyHeap(P, Len)` | memory from `GetMem` | `FreeMem` after the write |
| `BodyCopy(Ex, P, Len)` | a copy, in a pooled block | the block goes back after the write |
| `BodyFile(Fd, Offset, Len, CloseAfter)` | a range of an open file | sent with `sendfile`; `Fd` closed after the last byte when `CloseAfter` |

`RespondText` is `Respond(BodyString(Text))` with the status and the
`Content-Type` set first.

### A file

`BodyFile` makes the kernel copy the file to the socket. The handler
opens the file, reads its size and hands the descriptor over; the server
owns it from then on (from `examples/stream.pas`):

```pascal
procedure TStreamHandler.ServeFile(Ex: TExchange);
var
  Fd: cint;
  St: Stat;
begin
  Fd := FpOpen(FileName, O_RDONLY or O_CLOEXEC);
  if Fd < 0 then
  begin
    Ex.RespondText(404, 'cannot open ' + FileName + #10);
    Exit;
  end;
  if FpFStat(Fd, St) <> 0 then
  begin
    FpClose(Fd);
    Ex.RespondText(500, 'fstat failed'#10);
    Exit;
  end;
  Ex.ResponseHeaders.Add('content-type', 'text/plain');
  Ex.Respond(BodyFile(Fd, 0, St.st_size, True));
end;
```

`open` may block on a slow disk, which is why this handler runs on a
worker.

### A body of unknown length

When the length is not known when the head goes out, `BeginStream` is the
terminal call. The head is sent at once with `Transfer-Encoding: chunked`,
and then the handler writes pieces with `Write` and ends the body with
`Finish`. Ten lines, one per 100 ms, from a worker (also from
`examples/stream.pas`):

```pascal
procedure TStreamHandler.ServeLines(Ex: TExchange);
var
  I: Integer;
  Line: RawByteString;
begin
  Ex.ResponseHeaders.Add('content-type', 'text/plain');
  if not Ex.BeginStream then                  { the head goes out now, chunked }
    Exit;                                     { canceled or already answered }
  for I := 1 to 10 do
  begin
    Sleep(100);                               { a worker may block }
    Line := 'line ' + IntToStr(I) + #10;
    if Ex.Write(PByte(Line), Length(Line)) = wrCanceled then
    begin
      WriteLn(StdErr, 'stream: client gone after ', I - 1, ' lines');
      Exit;                                   { the exchange ends the body itself }
    end;
  end;
  Ex.Finish;                                  { the last chunk; no trailers }
end;
```

`Write` copies the bytes into a bounded queue. On a worker it parks while
about `HighWater` bytes (64 KiB by default) are queued and the client has
not read them: a slow client slows the producer down. On the loop thread
it cannot park and returns `wrWouldBlock` instead. `wrCanceled` means the
client went away; the producer stops, and the exchange cleans up.

```sh
$ build/examples/stream 8080 /etc/os-release &
$ curl -N http://127.0.0.1:8080/          # one line per 100 ms
$ curl -i http://127.0.0.1:8080/file      # the file, with its Content-Length
```

A streaming producer that lives on the loop thread is better written as a
`TBodySource`, a class the connection polls for the next frame only while
the socket can take more (`docs/api.md`, section 5).

## 8. Loops in depth

### Pending and wake

When `Poll` returns `cpPending`, the connection task stops running and the
loop goes back to its other sockets. Nothing polls the call again until
something wakes the connection. The sources of a wake are:

- body data arriving after a `TryRead` returned `brPending`;
- a `TWakeTimer` the call armed;
- a worker's terminal call, which is how `TOffloadCall` works;
- `Ex.Wake` from any thread holding a `Share` reference.

A call that returns `cpPending` without arranging one of these stays
pending until the connection times out. A build with `-dWD_DEBUG` checks
that a wake source exists at the end of every pending run.

### A timer

This program answers `/delay` one second after the request, without a
worker thread, using `TWakeTimer` (also `examples/delay.pas`):

```pascal
program delay;

{$mode objfpc}{$H+}

uses
  cthreads, SysUtils, bearings.rt.loop, bearings.http.exchange, bearings.server;

type
  { one object per request: it owns the timer that wakes the connection }
  TDelayCall = class(TServiceCall)
  private
    FTimer: TWakeTimer;
  public
    function Poll(Ex: TExchange): TCallPoll; override;
    procedure Drop(Ex: TExchange; Completed: Boolean); override;
  end;

  TNotFoundCall = class(TServiceCall)
  public
    function Poll(Ex: TExchange): TCallPoll; override;
  end;

  TDelayService = class(THttpService)
  private
    FNotFound: TNotFoundCall;
  public
    constructor Create;
    destructor Destroy; override;
    function Call(Ex: TExchange): TServiceCall; override;
  end;

function TDelayCall.Poll(Ex: TExchange): TCallPoll;
begin
  if FTimer.Target = nil then
  begin
    FTimer.Arm(Ex, 1000);             { the loop polls us again in one second }
    Exit(cpPending);
  end;
  if not FTimer.Fired then
    Exit(cpPending);                  { woken for another reason; keep waiting }
  Ex.RespondText(200, 'you waited one second'#10);
  Result := cpReady;
end;

procedure TDelayCall.Drop(Ex: TExchange; Completed: Boolean);
begin
  FTimer.Cancel(Ex);                  { the client may have left before the timer fired }
  Free;
end;

function TNotFoundCall.Poll(Ex: TExchange): TCallPoll;
begin
  Ex.RespondText(404, 'not found'#10);
  Result := cpReady;
end;

constructor TDelayService.Create;
begin
  inherited Create;
  FNotFound := TNotFoundCall.Create;
end;

destructor TDelayService.Destroy;
begin
  FNotFound.Free;
  inherited Destroy;
end;

function TDelayService.Call(Ex: TExchange): TServiceCall;
begin
  if PathIs(Ex, '/delay') then
    Result := TDelayCall.Create       { freed in its Drop }
  else
    Result := FNotFound;
end;

function NewService(Loop: TLoop): THttpService;
begin
  Result := TDelayService.Create;
end;

var
  Cfg: TServerConfig;
  Srv: TServer;
begin
  Cfg := ProductionServerConfig;
  Cfg.Workers := NO_WORKER_POOL;
  Cfg.Listen.Port := StrToIntDef(ParamStr(1), 8080);
  Srv := TServer.CreateWithProc(Cfg, @NewService);
  Srv.RunUntilSignalProc(nil);
  Srv.Free;
end.
```

```sh
$ build/tutorial/delay 8080 &
$ time curl -s http://127.0.0.1:8080/delay
you waited one second

real    0m1.007s
```

`Call` now looks at the request and returns different call objects for
different paths. The delay call has per-request state, the timer, so the
service creates one per request and the call frees itself in `Drop`.

`Drop(Ex, Completed)` is called exactly once at the end of every call, on
the loop thread. `Completed` is True right after `Poll` returned
`cpReady`, and False when the connection abandoned the call: the client
closed, the connection failed, or the shutdown deadline passed. Either way
the timer is cancelled, which is harmless if it already fired, and the
object is freed. A call that is pooled rather than allocated per request
returns itself to its pool here.

The first `Poll` arms the timer and returns `cpPending`. One second later
the timer wakes the connection, `Poll` runs again, sees `Fired` and
answers. The `Fired` check matters: a wake can come from elsewhere, and a
call must treat every poll as a question, not as a notification that its
own event happened.

A `TWakeTimer` is a record that must not move while armed, which is one
reason it lives in a heap object. It checks the exchange's generation when
it fires, so a timer armed for one request never wakes a later request on
the same connection.

### Keep-alive, pipelining and cancellation

Each request on a keep-alive connection is a new call on the same exchange
object; `Ex.RequestNo` counts them and `Ex.ConnId` identifies the
connection. The connection keeps one call in flight at a time: a pipelined
request waits in the read buffer until the current call completed, so a
slow handler delays the later requests of its own connection and no one
else's.

When the client disconnects while a call is in flight, the exchange is
canceled: terminal calls return False and send nothing, `TryRead` returns
`brCanceled`, the blocking reads raise `EClientGone`, stream writes return
`wrCanceled`, and a worker parked in a read or a write is woken. A long
handler that is between body calls checks `Ex.IsCanceled` now and then.
Nothing is ever sent to a client that is gone, so a handler may simply
return.

## 9. WebSocket

A WebSocket starts as an HTTP request that asks to upgrade the connection.
Bearings handles the handshake and hands the socket to a `TWebSocket` that
runs on the loop and calls your handler for each message. It needs the
connection mode `cmWithUpgrades`, which `ProductionServerConfig` sets.

### Echo

The service's call sees `Ex.WantsUpgrade`, checks the handshake and
accepts it with a handler (from `README.md`; `examples/ws_echo.pas` is the
full program, with backpressure handling):

```pascal
uses ..., bearings.ws.frame, bearings.ws.handshake, bearings.ws.conn;

type
  TChat = class(TWebSocketHandler)
  public
    procedure OnText(WS: TWebSocket; P: PByte; Len: SizeInt); override;
    procedure OnClose(WS: TWebSocket; Code: Word; const Reason: RawByteString); override;
  end;

procedure TChat.OnText(WS: TWebSocket; P: PByte; Len: SizeInt);
begin
  WS.SendText(P, Len);               { wsOk, wsFull (wait for OnWritable) or wsClosed }
end;

procedure TChat.OnClose(WS: TWebSocket; Code: Word; const Reason: RawByteString);
begin
  { the last call; WS and this handler are freed after it }
end;

function TMyCall.Poll(Ex: TExchange): TCallPoll;
var
  R: TWsHandshake;
begin
  if Ex.WantsUpgrade and PathIs(Ex, '/chat') then
  begin
    R := CheckRequest(Ex, ['chat.v1']);        { the subprotocols it supports }
    if R.Ok then
      AcceptWebSocket(Ex, R, TChat.Create, DefaultWsConfig)
    else
      RespondHandshakeError(Ex, R);            { 400, or 426 for a wrong version }
  end
  else
    Ex.RespondText(404, 'not found');
  Result := cpReady;
end;
```

The handler's methods run on the loop thread, one event at a time per
connection: `OnOpen`, `OnText` and `OnBinary` (a complete message; the
bytes are valid during the call only), `OnPong`, `OnWritable`, `OnError`
and `OnClose`, which is always the last. `AcceptWebSocket` owns the
handler from the call on and frees it after `OnClose`.

A send returns `wsFull` when the connection's output queue holds
`SendHighWater` bytes (1 MiB by default), which means the client is not
reading. Nothing was queued; the handler keeps the message and sends it
from `OnWritable`, which runs when the queue went down. The connection
also stops reading while the queue is full, so a client that does not
read cannot make the server buffer without bound.

`DefaultWsConfig` allows messages up to 16 MiB, pings every 25 seconds,
closes an idle connection after 60 seconds (the pongs keep a live client
from reaching it), and waits 5 seconds for the close handshake.

### A handler that blocks

A handler that queries a database per message derives from
`TWsWorkerHandler` instead and is accepted with the server's pool:

```pascal
type
  TStore = class(TWsWorkerHandler)
  public
    procedure OnText(WS: TWebSocket; const Msg: RawByteString); override;
  end;

procedure TStore.OnText(WS: TWebSocket; const Msg: RawByteString);
begin
  Db.Insert(Msg);                    { blocks: this runs on a worker thread }
  WS.PostText('stored');             { sends from any thread }
end;

  ...
  AcceptWebSocket(Ex, R, TStore.Create, Server.Workers, DefaultWsConfig);
```

Its events run on a worker, one at a time per connection and in order,
and an idle connection holds no thread. `Msg` is the handler's own copy.
From a worker the handler sends with `PostText` and `PostBinary`, never
`SendText`, which is a loop-thread call.

### Pub/sub: a chat with rooms

To send one message to every connection interested in something, the
application keeps no list of connections. It creates one `TWsTopics` for
the server, subscribes connections to topics and publishes to a topic:

```pascal
Topics := TWsTopics.Create;                    { the application creates and frees it }
Topics.Subscribe(WS, 'chat/room1');            { in OnOpen or OnText; from a worker handler too }
Topics.Subscribe(WS, 'sensors/+/temp');        { + matches one level, # the rest }
Topics.Publish('chat/room1', 'hola');          { any thread }
Topics.Publish('chat/room1', 'hola', WS);      { everyone but WS }
Topics.Unsubscribe(WS, 'chat/room1');
```

A publish encodes the message once and posts one message to each loop;
each loop sends the frame to its own subscribers. This is the per-loop
state with messages design from chapter 4: no lock on any connection
list, and a connection's subscriptions go away with it. A subscriber
whose output queue is full misses the message (counted in
`TWebSocket.DroppedMessages`); with `Topics.CloseOnBackpressure := True`
it is disconnected instead. Nothing is queued without a bound, and nothing
is retained for late subscribers.

`examples/ws_chat.pas` is a chat with rooms on it. Its handler subscribes
in `OnOpen` to the room named in the path, and `OnText` publishes to that
room with the sender excluded:

```pascal
procedure TChatHandler.OnText(WS: TWebSocket; P: PByte; Len: SizeInt);
var
  Msg: RawByteString;
begin
  SetString(Msg, PAnsiChar(P), Len);
  if Copy(Msg, 1, 5) = 'join ' then
    Join(WS, Copy(Msg, 6, MaxInt))
  else if Msg = 'leave' then
    Join(WS, '')
  else if FRoom = '' then
    WS.SendText('join a room first: join <name>')
  else if not WsTopicValid(FRoom) then
    WS.SendText('not a valid room name')
  else
    Topics.Publish('chat/' + FRoom, Msg, WS);   { everyone in the room but the sender }
end;
```

Try it with two terminals:

```sh
$ build/examples/ws_chat 9002 &
$ websocat ws://127.0.0.1:9002/room/general   # what one terminal types, the other sees
```

## 10. Graceful shutdown

A server that is told to stop should finish what it is doing, and not
leave clients with half a response. Bearings does this in `Stop`:

1. Each loop accepts what is still in its accept queue and closes its
   listener.
2. Keep-alive is turned off on every connection. Idle connections close
   now; a connection in the middle of a request closes after its response.
   Each WebSocket gets a close frame with code 1001.
3. A loop exits when its last connection closed, or when the grace period
   (`Cfg.GraceMs`, 30 seconds in the production preset) passed. The
   connections still open then are aborted; their calls get
   `Drop(Ex, False)`.

`RunUntilSignal` wires this to SIGTERM and SIGINT, which is why every
program in this tutorial stops cleanly on Ctrl-C and under `systemctl
stop`. A program that drives the lifecycle itself calls `Start`, later
`Stop(GraceMs)` from any thread (a handler, an admin endpoint), then
`Wait` to join the threads. `Destroy` stops and waits if the program did
not.

A worker in the middle of a handler at shutdown finishes it: `Wait` shuts
the pool down after the loops stopped and gives queued and running items
up to `WorkerWaitMs` (30 seconds by default).

### Under systemd

Bearings talks to systemd without libsystemd. With a `.socket` unit,
systemd opens the listening socket and passes it to the service;
`ApplySdListenFds(Cfg)` before `Start` makes the server use it instead of
binding a port, so connections that arrive during a restart wait in the
accept queue instead of being refused. With `Type=notify`, `Start` sends
`READY=1` once every listener is open, and with `WatchdogSec=` the server
sends a heartbeat every half interval, but only while every event loop is
making progress: a loop stuck in a handler stops the heartbeat and systemd
restarts the service. `README.md`, section "Running under systemd", has
the sample units.

## 11. Next steps

The tutorial covered the shape of the library: a server, a service per
loop, a call per request, one terminal call per exchange, workers for code
that blocks, and bounded queues everywhere. Where to go next:

- `docs/api.md` covers what this tutorial left out: the connection
  observer, the access log and metrics, the connection limit, the PROXY
  protocol, `TBodySource`, trailers, upgrades to protocols other than
  WebSocket, the debug build flags, and a reference table of every public
  routine with its threading rule.
- `docs/api.md`, section 13, has the performance rules for an inline
  handler that wants the benchmark's speed: a stateless call object,
  `BodyStatic` for constant bodies, no string building per request, and
  no managed locals in `Poll` (the compiler adds an exception frame to a
  routine that has them). The key-value store in this tutorial breaks
  every one of those rules on purpose, to stay readable; a program that
  needs the speed looks at `bench/plaintext.pas`.
- `docs/design.md` explains why the library is built the way it is, and
  lists the invariants that the code relies on.
- Compile with `-Sa` during development. The threading rules of every
  routine are then checked at run time, and a call that completes without
  a terminal call raises an assertion that names the request.

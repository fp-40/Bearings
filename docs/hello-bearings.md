# Hello Bearings

We start with the smallest server: one service that answers "Hello" to
every request.

## The code

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
fpc -Mobjfpc -Sh -O2 hello.pas
./hello 8080
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

## Breaking it down

Three things happen in this program: a server is configured and started,
a service is created for each event loop, and a call answers each request.

### The server

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

### The service

```pascal
function NewService(Loop: TLoop): THttpService;
begin
  Result := THelloService.Create;
end;
```

The factory is called once per event loop, on the thread that owns the
server, before the loops start. So there is one `THelloService` instance
per loop, and each loop only ever touches its own. This is the library's
answer to shared state: there is none by default. [Shared state](shared-state.md) covers what to
do when you need some.

For every request a loop parses, it calls `THelloService.Call` with the
exchange. `Call` runs on the loop thread and does one thing: it picks the
call object that will handle the request. It must not answer the request
or read the body, and a build with assertions (`-Sa`) checks that. Here
the service returns the same `THelloCall` for every request, because the
call keeps no state and one instance serves all of them.

### The call

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

### What is an event loop?

The server has one thread per CPU. Each thread runs a loop: it asks the
kernel which of its sockets are ready (`epoll_wait`), runs the code of
each ready connection until that connection would block again, and goes
back to waiting. Every socket is non-blocking. A connection is accepted by
one loop and stays on that loop for its whole life.

One loop thread serves thousands of connections, so **code on a loop
thread must never block**: no `Sleep`, no blocking file or socket call,
no waiting on a lock that another thread holds for long. A blocked loop
thread stalls every connection on that loop. [Blocking code: the worker pool](workers.md) shows what to do
with code that has to block.

If you know Rust's `Future::poll`, `TServiceCall.Poll` is the same shape:
a method called repeatedly, returning "ready" or "pending", with a wake-up
mechanism for the pending case. [Loops in depth](loops-in-depth.md) looks at that mechanism.

### `cthreads`

The `uses` clause starts with `cthreads`. It has to: the server creates
threads, and on Linux the RTL's thread support is in that unit, which must
be the first unit initialized. A program that forgets it fails at the
first thread creation.

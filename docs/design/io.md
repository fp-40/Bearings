# 3. Readiness and I/O

## Registration

A connection socket is added to the loop's epoll set once, with `EPOLLIN or EPOLLOUT or EPOLLRDHUP or EPOLLET` and `data.ptr` pointing at the task's `TIoSource` (`TLoop.Register`), and the HTTP/1 task never modifies the registration; backpressure is simply not calling `read` or `write`.

The upgrade hand-off points it at the `TUpgraded`'s source with one `EPOLL_CTL_MOD` (same event bits). Removal is implicit at `close`, except for a detached upgraded connection (`TLoop.Unregister`). Level-triggered epoll was rejected: it reports a socket on every `epoll_wait` while its connection waits for the application, and toggling `EPOLLOUT` costs an `epoll_ctl` per blocked write. Listening sockets and the eventfd are level-triggered (`data.ptr = nil` for the eventfd).

## Readiness bits (`TReadyBit`, `ReadyFromEpoll`)

`EPOLLIN` or `EPOLLPRI` sets `rdRead`; `EPOLLOUT` sets `rdWrite`; `EPOLLHUP`, or `EPOLLIN` together with `EPOLLRDHUP`, sets `rdReadClosed`; `EPOLLHUP`, `EPOLLOUT` with `EPOLLERR`, or an event that is exactly `EPOLLERR`, sets `rdWriteClosed`; `EPOLLERR` sets `rdError`.

The closed and error bits are sticky: once set they stay, because the condition cannot go away.

## The transport rules (`TTcpTransport`, `bearings.rt.net`)

`Read` calls `read(2)` only when one of `rdRead`, `rdReadClosed`, `rdError` is set; on `EAGAIN` or a short read (fewer bytes than asked) it clears `rdRead`.

A short read is taken to mean that the kernel's receive buffer is empty, which is how Linux behaves for TCP.

`Write` calls `write(2)` only when one of `rdWrite`, `rdWriteClosed`, `rdError` is set; `EAGAIN` or a short write clears `rdWrite`. `WriteV` and `SendFile` clear `rdWrite` only on `EAGAIN`: a short `writev` or `sendfile` keeps the bit, so the caller tries again and gets the `EAGAIN` if the buffer really is full.

When the needed bit is clear the call returns `-EAGAIN` without a system call. An edge-triggered socket must be used until `EAGAIN` before the task waits, or the next edge never comes; these rules guarantee that a missing bit always means the kernel said `EAGAIN` (or gave a short transfer) since the last event.

Why the sticky bits matter: when a client writes a request and closes, the data and the FIN often arrive in one event. The head read is short, so `rdRead` is cleared; without a sticky `rdReadClosed` the next read (the one that detects the client's EOF while the response is in progress, section 5) would return `-EAGAIN` without a system call and the EOF would be lost. With the sticky bit the read calls the kernel, gets 0, and the connection ends.

## The transport interface (`TTransport`)

`Read`, `Write`, `WriteV`, `SendFile`, `ShutdownWrite`, `Close`, each non-blocking and returning the raw result (bytes, 0 for EOF, `-errno`). A transport may wrap another (`Wrapped`, `DisownWrapped`): the conformance server counts bytes that way, and the upgrade hand-off follows the chain down to the socket.

The default `WriteV` writes the first non-empty slice only and reports `IsWriteVectored = False`; the default `SendFile` returns `-ENOSYS`, which a future TLS transport would do too.

## Accepting (`TListener`, a level-triggered `TIoTask`)

On each event `accept4` with `SOCK_NONBLOCK or SOCK_CLOEXEC`, at most 64 times or until `EAGAIN`. `EINTR`, `ECONNABORTED`, `ECONNRESET` and `ECONNREFUSED` lose only that connection and the loop takes the next one.

Any other error (`EMFILE`, `ENFILE`, `ENOBUFS`, `ENOMEM`, ...) is counted, logged at most once per second, and the listener leaves the epoll set for `ACCEPT_PAUSE_MS` (1 s, through a loop timer); a level-triggered listener with a non-empty accept queue would otherwise be reported by every `epoll_wait` and the loop would spin until descriptors are free.

Connections wait in the kernel's queue meanwhile. An exception from per-connection setup in `OnAccept` is caught by the listener for that connection: the socket is closed, `SetupErrors` counted, the error logged at most once per second, and accepting goes on.

`TLoop.Create` sets its descriptors to -1 before any system call, so a constructor that fails part-way closes only what it opened. Connection ids are `QWord(LoopIndex) shl 48 or NextConnSeq`, unique per server without an atomic.

## Three accept modes (`TAcceptMode`, set up by `bearings.server`)

`amReusePort` (production default): one listening socket per loop, all bound to the same port with `SO_REUSEPORT`; the kernel spreads new connections over them; with port 0 the first loop binds a free port and the others bind that port. 

`amSharedExclusive`: one listening socket; every loop registers its own `dup` (`F_DUPFD_CLOEXEC`) with `EPOLLIN or EPOLLEXCLUSIVE`, so the kernel wakes one waiting loop per connection; each loop takes its dup out of its epoll set before closing it, because an epoll entry lives as long as the open file, not the descriptor.

`amSingle`: one listener on loop 0. The listening socket gets `SO_REUSEADDR`, the configured backlog (4096 in the production preset) and `TCP_NODELAY` when `NoDelay` is set; Linux copies `TCP_NODELAY` to every accepted socket. A Unix domain socket (`TListenSpec.UnixPath`) replaces `amReusePort` by `amSharedExclusive` (there is one path); a listening socket passed in by systemd (`InheritedFd`) is shared the same way.

## Connection limit (`TServerConfig.MaxConnections`)

The connection limit is one atomic counter shared by all loops; a listener takes a slot before each `accept4` and, at the limit, leaves epoll (`PauseForLimit`) instead of refusing: new clients wait in the accept queue.

The closing connection gives the slot back (`TConnHooks.ConnDone`), resumes its own loop's listeners and posts a message to the other loops to resume theirs; a 1 s timer is the fallback.

An upgraded connection keeps its slot until the upgraded stream is closed or detached (`TConnHooks.UpgradedClosed`). With the limit off the accept path tests one integer.

`SIGPIPE` is ignored process-wide at `Start` (`IgnoreSigPipe`): a write to a reset socket then returns `-EPIPE`, which ends that connection only.

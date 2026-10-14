# 4. Timers and the clock

## The clock (`bearings.rt.clock`)

The clock is libc's `clock_gettime`, which runs in the vDSO (about 11 ns; FPC's own wrapper makes a system call, about 89 ns). The loop samples `CLOCK_MONOTONIC` once per iteration, right after `epoll_wait` returns (`TLoop.NowNs`, `NowMs`; a wait with a timer armed also reads it once before, to compute its timeout), and every timeout, deadline and duration in the library is measured with that value: no connection reads the clock itself.

A consequence: a request answered in the iteration that read it has a measured duration of 0 (access log, metrics), and a timer armed late in a long iteration is measured from the iteration's start. `CLOCK_REALTIME` is read only for the Date header and for the access log's timestamp of each logged request.

## The timer wheel (`TTimerWheel`, `bearings.rt.timer`)

Six levels of 64 slots at 1 ms resolution (level L covers 64^L ms per slot), one per loop, loop thread only.

A wheel, not a heap, because a server arms a timer per request of every keep-alive connection and cancels nearly all of them before they expire: arm, cancel and move are O(1), and the next expiry is found with bit operations over the occupancy masks.

Lazy arm: moving a deadline later only stores the new deadline (the entry is filed again when its slot expires); lazy cancel sets the deadline to 0 and the entry is dropped when its slot expires. So the header-read timer of a keep-alive connection costs two stores per request.

Every timer of the library is armed at `NowMs + DelayMs`, with `NowMs` rounded down to the millisecond, and fires once `NowMs` reaches that deadline: never early in loop time, but up to 1 ms short of `DelayMs` measured from the true instant of arming. (`DeadlineToTick` and `InstantToTick` round a nanosecond deadline up and an instant down; only the tests use them).

Timers are `TTimer` records embedded in their owners (no allocation); `Remove` unlinks one before its owner is freed.

Users: the header read timer and the body timer of a connection, the listener's resume timer (also the 1 s fallback of the connection-limit pause), the stop deadline of a loop, the idle, ping and close timers of a WebSocket, the application's `TWakeTimer`, and, in `-dWD_STALL` builds, the stall detector's scan. 

Pings are on by default, so a loop with an open WebSocket always has a timer armed.

## The Date header (`bearings.http.date`)

The Date header is formatted once per second per loop. `src/rt` does not depend on the HTTP units, so the loop offers one generic hook: `LoopTickProc`, a procedure the loop calls once at creation and again when the delay the last call returned has elapsed (one comparison per iteration), with per-loop storage in `TLoop.Ext` (`LOOP_EXT_BYTES`, 64 bytes, zeroed).

`bearings.http.date` assigns the hook in its initialization and keeps the `TDateCache` in `Ext`; the response encoder copies the 29 bytes from `LoopDate(Loop)`, so no threadvar is read on the request path. Code outside a loop uses the threadvar cache (`DateBuffer`).

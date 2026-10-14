# 12. Debug build flags

The library has no build step; the flags are `-d` defines (and `-Sa`) of
the program that compiles it. They keep the `WD_` prefix.

- `-Sa` (assertions): the threading rules are checked (an unshared
  exchange is used only on its loop thread; the response head is written
  only by the thread that makes the terminal call; `THttpService.Call`
  neither answers nor reads the body; a recycled exchange is never woken),
  the encoders assert every header name and value they write, and a
  released request head is overwritten with `$DD` bytes so code that reads
  it late sees that pattern. A call that completes (`Poll` returned
  `cpReady`) or a worker handler that returns without a terminal call
  raises `EAssertionFailed` naming the request (method and path), after
  the exchange was left consistent: on the loop the exception leaves
  `TExchange.CompleteCall` inside the connection task's run, so the loop
  aborts and closes the connection (no response, nothing leaks); on a
  worker it leaves the job after its `Fail` answer and ends in the pool's
  safety net. Every build counts these in `NoResponseFailures`
  (`bearings.http.exchange`, atomic) and closes the connection with a user
  error; only the raise needs `-Sa` (it is not tied to `WD_DEBUG`). A test
  that drives this path on purpose calls `Ex.NoResponseIsExpected` before
  the completion; the opt-out is per request. Release builds contain none
  of these checks
  (`tools/check-hot-asm.sh --s7` verifies that no `Dbg*` routine and no
  assertion call is in a production build of `bearings.http.exchange`).
- `-dWD_DEBUG`: the connection task checks, at the end of every run that
  returns "pending", that a wake source is armed (a socket wait, a timer, a
  pending call or body source, or a body channel waiting for its
  receiver); a failure increments `WakeAssertFailures`
  (`bearings.http1.dispatch`) and raises with `-Sa`. A pending connection
  without a wake source would stay stuck until a timeout. Also, freed
  buffer-pool blocks are filled with `$DD` (`bearings.rt.buf`), so a use
  after release shows up.
- `-dWD_STALL` (requires `WD_DEBUG`): the stall detector of
  `bearings.server`. Each loop scans its connections once per second and
  reports on stderr, once per connection, every connection that is in the
  middle of a message, has not run for `STALL_MS` (60 000 ms) and waits on
  the server rather than on the client. `StallReports` counts the reports.
  For soak tests.
- `-dWD_DRD`: builds for valgrind's `drd` race detector
  (`bearings.rt.sync`). The spin locks, parkers and atomic accessors get
  happens-before annotations through valgrind client requests and are not
  inlined, so `tools/drd.supp` can suppress the reports on the
  synchronization words themselves. `tests/unit/run_all.sh` runs the
  worker tests this way.

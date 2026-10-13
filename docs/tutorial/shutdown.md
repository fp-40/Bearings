# Graceful shutdown

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

## Under systemd

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

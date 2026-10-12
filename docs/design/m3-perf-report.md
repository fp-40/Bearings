# M3 performance report (step S10)

> Written while this code was part of wd-40 (where "wd-40" in the text means the project of that time). The unit names were changed to `bearings.*` when the transport moved to this repository; commit hashes refer to the wd-40 history.

Date: 2026-10-10. Tree: HEAD 094152c (no source change in S10). Machine: Intel i5-14400 (CPUs 0-11 =
6 P-cores with SMT, 12-15 = 4 E-cores), kernel 7.0.0, FPC 3.2.2. Design: `docs/design.md` section 9
(method and gate; only the throughput ratio is a hard gate). Raw outputs:
`build/m3/S10/` (not checked in): `gateB/`, `gateA/`, `p99/`, `idle/`, `syscalls/`, `micro/`, `prof/`,
`web_gate/`, and the driver `drive.sh` / `drive.log`.

## 1. Summary

| measurement | target (7.6) | wd-40 | hyper 1.12 | result |
|---|---|---|---|---|
| req/s, configuration B, c256 d1 | >= 0.80 x hyper (hard) | 653 841 | 682 065 | **0.959** met |
| req/s, configuration B, c256 d16 | >= 0.80 x hyper (hard) | 2 645 010 | 3 097 022 | **0.854** met |
| req/s, configuration B, c1024 d1 | >= 0.80 x hyper (hard) | 630 033 | 640 472 | **0.984** met |
| req/s, configuration B, c1024 d16 | >= 0.80 x hyper (hard) | 2 572 559 | 2 922 432 | **0.880** met |
| req/s, configuration A, c256 d16 | reported | 5 293 645 | 6 086 191 | 0.870 |
| req/s, configuration A, c1024 d16 | reported | 5 105 209 | 5 691 598 | 0.897 |
| req/s, configuration A, depth 1 (both cells) | reported | client-bound | client-bound | no valid run (section 3) |
| depth-1 p99 (wrk, at maximum load), c256 / c1024 | <= 1.25 x hyper (goal, for the user to confirm) | 0.444 / 1.73 ms | 0.440 / 1.76 ms | 1.01 / 0.98 x met |
| depth-1 p99 (wrk2, 50 % of hyper's max), c256 / c1024 | reported (goal above) | 2.25 / 1.93 ms | 2.23 / 1.93 ms | 1.01 / 1.00 x |
| depth-1 p99 (wrk2, 80 % of hyper's max), c256 / c1024 | reported (goal above) | 3.10 / 2.36 ms | 11.92 / 2.37 ms | 0.26 / 1.00 x (c256: noisy, section 4) |
| idle keep-alive connection, 10 000 connections | <= 2 KB (goal, for the user to confirm) | 1 305 B | 10 703 B | met |
| RSS under load (VmHWM over the configuration B gate) | <= hyper (goal, for the user to confirm) | 5 324 KB | 22 556 KB | met |
| system calls per request, depth 1 | 1 read + 1 write + a share of `epoll_wait` | 1.0004 + 1.0002 + 0.0166 | 1.0004 + 1.0002 + 0.0166 | met (equal to hyper) |
| system calls per request, depth 16 | 1 read + 1 write per 16 requests | 0.0625 + 0.0625 + 0.0010 | 0.0625 + 0.0625 + 0.0011 | met (equal to hyper) |
| `bench_role` parse / encode | <= 152 / 121 ns (+10 %) | 138 / 83 ns | | met |
| `bench_dispatch` depth 16 | <= prototype + 420 ns | 583.3 <= 367.2 + 420 = 787.2 ns | | met (216 ns over the prototype) |
| web framework, inline vs bare transport, depth 1 / depth 16 | >= 0.90 / >= 0.75 (user, 2026-10-09) | 0.918, 0.920 / 0.753, 0.756 | | met (c256 d16 by 0.0035) |
| web framework, worker vs `OFFLOAD=1`, depth 1 | >= 0.95 (user) | 0.960, 0.978 | | met |

**Every gate of 7.6 is met**: the hard gate (>= 0.80 x hyper per cell in configuration B) and the three
goals of decision 2 (depth-1 p99, idle memory, RSS under load). The goals were set in decision 2 under
the user's delegation; S10's exit says "as confirmed by the user", so they are marked "for the user to
confirm".

Nothing missed its target. Reported, not misses:

- The two depth-16 cells are below 1.00 (0.854 and 0.880 in configuration B, 0.870 and 0.897 in A).
  7.6 asks for a profile of cells below 1.00: section 8. The instruction count per request is the same as
  hyper's within 3 %; the difference is CPU time per instruction, which the counters this machine
  allows cannot break down further.
- Configuration A at depth 1 has no valid run: wrk on CPUs 8-15 is 99.8-99.9 % busy in every run, so
  7.6's validity rule leaves all of them out (the design already says A is client-bound at depth 1).
- The web inline c256 d16 cell holds its 0.75 budget by 0.0035 (0.7535).
- Two micro-benchmarks that 7.6 lists do not exist in the tree: `TReadBuf`/`TByteVec` operations and the
  exchange inline path (no step wrote them). The listed ones are not run by `tests/unit/run_all.sh`
  ("in CI" in 7.6): they are run by hand.

## 2. Method

Common to every block:

- Servers: `bench/hyper-tfb` (hyper 1.12.0 rev 7f67699, tokio 1.53.2, TFB configuration, LTO) and
  `bench/plaintext.pas` (`SERVER=hyper`, so the response bytes are equal), built by
  `bench/run_gate.sh` (FPC `-O3 -CX -XX -Xs`, cargo `--release --offline`). The response bytes of the two
  servers were compared with `cmp` before both gate runs: identical (2 185 bytes over 5 cases).
- Load: `build/tools/bin/wrk` (wg/wrk a211dd5) with TFB's headers and `pipeline.lua`; fixed-rate load
  with `build/tools/bin/wrk2` (giltene/wrk2 44a94c1, rebuilt in S10, section 4).
- Idle machine: `build/m3/S10/drive.sh` waited before each block until the one-minute load average was
  below 1.0 (load before each block: 0.71 / 0.99 / 0.95 / 0.88 / 0.94 (micro) / 0.94 / 0.97). Nothing
  else heavy ran during the measurements. The load rises during a block because of the block itself
  (servers plus wrk on 16 CPUs).
- Governor: `powersave` (intel_pstate). It could **not** be set to `performance`: the sysfs file is
  root-owned and `sudo` needs a password. Every comparison alternates the two servers run by run, so
  frequency drift affects both.
- Throughput (`bench/run_gate.sh` -> `bench/compare.py`): per cell a 10 s warm-up per server
  (discarded), then 5 runs of 30 s per server, alternating which server goes first; median of the runs
  whose wrk CPUs were at most 90 % busy (7.6 validity rule); requests per server CPU-second from
  `/proc/<pid>/stat`. VmRSS of both servers every second and VmHWM at the end.
- Configuration B (gate): each server 4 threads/loops pinned to CPUs 0-3; wrk 12 threads on CPUs 4-15.
- Configuration A (reported): each server 8 threads/loops on CPUs 0-7; wrk 8 threads on CPUs 8-15.
  `run_gate.sh` got environment variables for the CPU split in S10 (`SERVER_CPUS`, `SERVER_THREADS`,
  `WRK_CPUS`, `WRK_THREADS`; defaults = configuration B, unchanged behaviour).

## 3. Throughput matrix

### 3.1 Configuration B (gate) - `build/m3/S10/gateB/`, 2026-10-10 08:24-08:46

| cell | hyper median req/s | wd-40 median req/s | wd-40 / hyper | hyper req/CPU-s | wd-40 req/CPU-s | ratio per CPU-s | gate 0.80 |
|---|---:|---:|---:|---:|---:|---:|---|
| c256 d1 | 682 065 | 653 841 | **0.9586** | 169 851 | 162 844 | 0.9587 | met |
| c256 d16 | 3 097 022 | 2 645 010 | **0.8540** | 771 491 | 658 618 | 0.8537 | met |
| c1024 d1 | 640 472 | 630 033 | **0.9837** | 160 065 | 157 482 | 0.9839 | met |
| c1024 d16 | 2 922 432 | 2 572 559 | **0.8803** | 728 907 | 640 843 | 0.8792 | met |

No run was client-bound (wrk CPUs 16.6-45.6 % busy; server CPUs 99.4-100 % busy). Run-to-run spread
within a server: at most 0.6 % (depth 1) and 1.3 % (hyper c1024 d16). The ratios repeat the earlier
gate runs: UB (2026-10-10) 0.959 / 0.853 / 0.986 / 0.886, S8 0.939 / 0.839 / 0.952 / 0.861, T1 0.938 /
0.838 / 0.961 / 0.869.

### 3.2 Configuration A (reported) - `build/m3/S10/gateA/`, 09:10-09:32

| cell | hyper median req/s | wd-40 median req/s | wd-40 / hyper | hyper req/CPU-s | wd-40 req/CPU-s | ratio per CPU-s | client-bound runs |
|---|---:|---:|---:|---:|---:|---:|---|
| c256 d1 | (1 134 477) | (1 137 118) | (1.002) | (163 218) | (158 145) | (0.969) | 10 of 10 |
| c256 d16 | 6 086 191 | 5 293 645 | 0.8698 | 759 207 | 659 617 | 0.8688 | 0 |
| c1024 d1 | (1 096 578) | (1 110 872) | (1.013) | (160 052) | (156 365) | (0.977) | 10 of 10 |
| c1024 d16 | 5 691 598 | 5 105 209 | 0.8970 | 711 509 | 638 231 | 0.8970 | 0 |

At depth 1 every run had wrk's 8 CPUs at 99.8-99.9 % busy while the servers' CPUs were 87-92 % busy:
wrk is the bottleneck, so compare.py leaves the runs out and `run_gate.sh` exits 1 ("no median"). The
numbers in parentheses are the medians of those client-bound runs, for information only; they measure
wrk, not the servers. Configuration A at depth 1 cannot be measured on this single machine: a server on 8
CPUs needs more than the other 8 CPUs (4 of them E-cores) to load it. At depth 16 A is valid and the
ratios are close to configuration B's (0.870 vs 0.854; 0.897 vs 0.880).

## 4. Latency

### 4.1 wrk2: fixing the Lua PANIC

`build/tools/bin/wrk2` stopped at start with `PANIC: unprotected error in call to Lua API (attempt to
index a nil value)`, with or without a script. Cause: wrk2's Makefile turns `src/wrk.lua` into an ELF
object with its bundled LuaJIT 2.0 (`luajit -b wrk.lua obj/bytecode.o`); the current linker reads that
object as corrupt (`wrk2.build.log`: "obj/bytecode.o: string table [3] is corrupt") and links it without
the bytecode, so the `wrk` Lua module is missing. Fix (no download; the source is the local checkout in
`build/tools/src/wrk2`): emit the bytecode as C source (`luajit -b src/wrk.lua obj/bytecode.c`), compile
it with `cc`, link again. `tools/get-tools.sh` does this now (stamp `<commit>+bytecode.c`, and it checks
that the binary no longer prints PANIC); `build/tools/bin/wrk2` was rebuilt with it. So the design's
method (wrk2 at fixed rates) is used, not a substitute.

### 4.2 Fixed-rate p99 (wrk2) - `bench/p99.sh`, `build/m3/S10/p99/`, 08:47-09:05

Method: configuration B servers; wrk2 12 threads on CPUs 4-15, TFB headers, depth 1 (the design's p99
goal is for depth 1; wrk2's rate control counts one `request()` call as one request, so a pipelined
batch of 16 would not give per-request latencies). Rates: 50 % and 80 % of hyper's median maximum from
the configuration B gate (c256: 682 065, c1024: 640 472). Per cell and rate 3 runs of 40 s per server,
alternating; wrk2 leaves its first 10 s (calibration) out of the histogram; medians of the 3 runs.

| cell | rate (req/s, x hyper max) | server | achieved req/s | p50 ms | p99 ms | p99.9 ms | p99 wd-40 / hyper |
|---|---|---|---:|---:|---:|---:|---:|
| c256 d1 | 341 032 (0.50) | hyper | 340 597 | 0.99 | 2.23 | 2.62 | |
| c256 d1 | 341 032 (0.50) | wd-40 | 340 599 | 1.00 | 2.25 | 2.65 | 1.01 |
| c256 d1 | 545 652 (0.80) | hyper | 544 948 | 1.01 | 11.92 | 66.11 | |
| c256 d1 | 545 652 (0.80) | wd-40 | 544 952 | 0.99 | 3.10 | 23.28 | 0.26 |
| c1024 d1 | 320 236 (0.50) | hyper | 318 558 | 0.94 | 1.93 | 2.26 | |
| c1024 d1 | 320 236 (0.50) | wd-40 | 318 560 | 0.94 | 1.93 | 2.26 | 1.00 |
| c1024 d1 | 512 377 (0.80) | hyper | 509 681 | 1.08 | 2.37 | 2.85 | |
| c1024 d1 | 512 377 (0.80) | wd-40 | 508 838 | 1.08 | 2.36 | 2.86 | 1.00 |

Both servers reached the requested rate in every run. The c256 80 % cell is noisy for both servers:
per-run p99 hyper 3.01 / 17.82 / 11.92 ms, wd-40 10.27 / 3.10 / 2.86 ms (p99.9 16.6-99.5 ms). At 545 652
req/s hyper runs at 80 % and wd-40 at 83 % of its own maximum; occasional stalls of tens of milliseconds
appear in some runs of either server, so 3 runs do not give a stable p99 for that cell. The other three
cells repeat within 0.05 ms from run to run.

### 4.3 p50/p99 from wrk at maximum load (configuration B gate runs)

Medians of the 5 runs per cell (`gateB/compare.txt`):

| cell | hyper p99 | wd-40 p99 | wd-40 / hyper | goal <= 1.25 |
|---|---:|---:|---:|---|
| c256 d1 | 440 us | 444 us | 1.01 | met |
| c1024 d1 | 1.76 ms | 1.73 ms | 0.98 | met |
| c256 d16 (unreliable, 7.6) | 1.47 ms | 1.67 ms | 1.14 | not a target |
| c1024 d16 (unreliable, 7.6) | 5.91 ms (4 runs; one run printed 0.00 us) | 7.02 ms | 1.19 | not a target |

7.6 notes that wrk's histogram is unreliable when one write carries 16 requests (one hyper run reported
a p99 of 0.00 us); the depth-16 rows are listed only for completeness.

## 5. Memory

### 5.1 Idle keep-alive connections - `bench/idle_rss.sh`, `build/m3/S10/idle/`

Method: the server as in configuration B (4 threads, CPUs 0-3); `bench/idle.py` on CPUs 4-15 opens
10 000 keep-alive connections, sends one request on each, reads each response, then keeps them open.
VmRSS before, and 2 s and 5 s after the last response (wd-40 gives pooled blocks back after 2 s idle);
3 runs per server, alternating; per connection = (with - before) / 10 000.

| server | RSS before | RSS with 10 000 idle connections | bytes per connection (median of 3, at 2 s and 5 s) | goal <= 2 KB |
|---|---:|---:|---:|---|
| hyper | 3 128-3 220 KB | 107 616-107 844 KB | 10 703 | |
| wd-40 | 2 524 KB | 15 272 KB | 1 305 | met |

The three wd-40 runs gave exactly the same numbers. Earlier measurements: 1 206 B before T1, 1 178 B
after T1 (S5-8: 1 208 B). The 100-130 B more now came with the steps after T1 (S8 to UB2); where
exactly was not investigated (S10 does not tune).

### 5.2 RSS under load

| run | hyper VmHWM | wd-40 VmHWM | max VmRSS (1 s samples) hyper / wd-40 | goal: wd-40 <= hyper |
|---|---:|---:|---:|---|
| configuration B gate (all 4 cells, c1024 included) | 22 556 KB | 5 324 KB | 22 676 / 5 324 KB | met |
| configuration A gate | 23 488 KB | 5 724 KB | 23 780 / 5 724 KB | met |

## 6. System calls per request - `bench/syscalls.sh`, `build/m3/S10/syscalls/`

Method differs from 7.6: 7.6 names `perf stat -e 'syscalls:sys_enter_*'`, but `kernel.perf_event_paranoid`
is 4 and tracefs is root-only here, and `kernel.yama.ptrace_scope` is 1 (only descendants can be traced).
So `strace -c -f` starts each server (configuration B pinning; strace itself on CPUs 4-15); one run under
strace without load (2 + 10 + 1 s: start-up, idle timers, exit) is the baseline, one run with a 10 s wrk
load (12 threads, c256) starting after 2 s is the measurement; per request = (loaded - baseline) / wrk's
request count. Limits: strace stops a thread at every system call, so the servers ran at 136-137 k req/s
(depth 1) and 1.36-1.46 M req/s (depth 16) instead of 0.65 M and 2.6-3.1 M. The calls per request are
exact for those runs; the share of `epoll_wait` (how many ready connections one wait returns) depends on
speed and is not that of an untraced run.

| cell | server | requests | read / recvfrom | write / sendto | epoll_wait | other (accept4, epoll_ctl, close, shutdown, mprotect, mmap) | total per request |
|---|---|---:|---:|---:|---:|---:|---:|
| c256 d1 | hyper | 1 386 090 | 1.0004 | 1.0002 | 0.0166 | 0.0013 | 2.0184 |
| c256 d1 | wd-40 | 1 373 528 | 1.0004 | 1.0002 | 0.0166 | 0.0008 | 2.0179 |
| c256 d16 | hyper | 14 757 760 | 0.0625 | 0.0625 | 0.0011 | 0.0001 | 0.1262 |
| c256 d16 | wd-40 | 13 765 056 | 0.0625 | 0.0625 | 0.0010 | 0.0000 | 0.1262 |

Both servers do what 7.6 expects: at depth 1 one read and one write per request plus a share of
`epoll_wait`; at depth 16 one read and one write per 16 requests (0.0625 = 1/16). No `futex` and no
`clock_gettime` system call under load in either server. Per connection, hyper makes 2 `epoll_ctl` calls
(add, and one more at close) and `mprotect` calls; wd-40 makes 1 `epoll_ctl`. hyper uses
`recvfrom`/`sendto`, wd-40 `read`/`write`.

## 7. Micro-benchmarks - `build/m3/S10/micro/`

Built with `fpc -Mobjfpc -Sh -O3 -CX -XX -Xs` (the 7.6 flags), run with `taskset -c 2` on the idle
machine.

`bench_role` (3 program runs; each line is the median of 7 rounds of 5 000 000 operations; the three
medians shown):

| operation | budget (7.6, S0) | result | |
|---|---:|---:|---|
| parse (`ServerParse`, TFB request) | 152 ns +10 % | 137.5 / 138.5 / 138.4 ns | met |
| encode (`ServerEncode`, TBytes, 200 with 2 headers, content-length, date) | 121 ns +10 % | 83.4 / 82.9 / 83.2 ns | met |
| encode, `TByteVec` overload (the one the connection uses) | | 77.2-77.3 ns | |
| encode without headers (TBytes / TByteVec) | | 46.6-46.8 / 40.2-40.4 ns | |
| headers: Clear + 2 x `AddTrusted` / 2 x validating `Add` | | 17.1-17.5 / 42.4-44.0 ns | |

Both are faster than the S0 budgets (parse 9 % under, encode 31 % under); the budget is an upper bound
(S0 exit: "parse <= 152 ns and encode <= 121 ns +10 %").

`bench_dispatch` (4 000 000 requests, 5 runs, medians):

| depth | prototype (`rawsrv` work) | dispatcher (whole engine) | difference | budget |
|---|---:|---:|---:|---|
| 1 | 384.3 ns | 714.3 ns | 330.1 ns | (none at depth 1) |
| 16 | 367.2 ns | 583.3 ns | 216.1 ns | <= 420 ns: met |

T1 measured 701 ns per request at depth 16 for the dispatcher (its prototype number is not recorded);
the drop to 583 ns is not explained by S10 (no source change; possibly CPU 2's frequency under
`powersave`); both numbers are within the budget.

`bench_conn` (connection layer only, no dispatcher or exchange; no budget of its own, part of the 420 ns):
405.8 ns per request at depth 16 (625 000 writes, 130 bytes per response), 451.6 ns at depth 1.

Not present: the `TReadBuf`/`TByteVec` operations benchmark and the exchange inline path benchmark that
7.6 lists. No step created them; the dispatcher benchmark covers both inside the whole engine.

## 8. Profile of the cells below 1.00 (depth 16) - `build/m3/S10/prof/`

7.6: "cells below 1.00 are reported with a profile". Hardware counters (`perf`) are not available
(paranoid 4), so the profile is callgrind (instructions, user space): each server with 1 thread under
`build/tools/bin/valgrind --tool=callgrind` on CPU 8, wrk 4 threads, c64, depth 16, 10 s on CPUs 9-15;
plaintext built with the gate flags plus `-gl` (symbols, same code). Instructions per request include
start-up (under 0.5 %).

| server | requests | instructions | per request |
|---|---:|---:|---:|
| hyper | 642 880 | 3 422 920 562 | 5 324 |
| wd-40 | 390 272 | 2 129 245 986 | 5 456 |

wd-40 executes 2.5 % more user-space instructions per request than hyper, and makes the same system calls
(section 6), but uses 17 % more CPU time per request at depth 16 (configuration B: 1.518 us vs 1.296 us per
request, from req/CPU-s). The gap is in time per instruction (cache, branch prediction, code layout,
FPC's code generation), which needs hardware counters to break down; none are available to this user.

Where wd-40's 5 456 instructions go (inclusive, per request): `PollWrite` 3 485, of which
`WriteHead`/`EncodeHead` 1 893 (`ServerEncode` 1 706: `EncodeHead` self 446, `TNameWriter.WriteName` 364);
`PollRead` 1 762 (`TH1Io.Parse` 1 339, `ServerParse` 1 226, `ParseRequest` self 221, `ParseHeaderBlock`
184); `PollMsg` 805; the plaintext service's `Poll` 719. Largest self costs:
`System.Move` 637 (11.7 %), `EncodeHead` 446, `WriteName` 364, `ParseRequest` 221, `THttpHeaders.AddTrusted` 219 (all callers),
`ParseHeaderBlock` 184, `ClassifyName` 173, `ServerParseSlots` 168. hyper's largest self costs:
`Conn::poll_*` 740, `Server::parse` 596, the dispatcher 543, `HeaderMap::try_append2` 496, `memcpy` 357,
`malloc`/`free` 321.

## 9. The web framework on top - `bench/web_gate.sh`, `build/m3/S10/web_gate/`, 09:34-09:47

Method (unchanged script, run once): the M3 gate method (configuration B, compare.py), RUNS=3, DUR=20,
WARM=5. Inline: `bench/web_hello` (an `OnLoop` route whose action calls `Render`) vs `bench/plaintext`
(bare transport). Worker: `web_hello WORKER=1` (the route on the worker pool, 8 workers) vs `plaintext
OFFLOAD=1` (a raw `TBlockingHandler`). Budgets: the user's decision of 2026-10-09 (`m5-report.md` 7 and
8.5). Load average 0.97 before the inline part; the worker part starts right after it (6.17), as the
script is written. No run was client-bound.

| cell | bare req/s | framework req/s | ratio | ratio per CPU-s | budget | FQ (2026-10-09) | |
|---|---:|---:|---:|---:|---:|---:|---|
| inline c256 d1 | 654 157 | 600 737 | 0.918 | 0.919 | 0.90 | 0.929 | met |
| inline c256 d16 | 2 645 327 | 1 993 138 | 0.7535 | 0.753 | 0.75 | 0.774 | met (by 0.0035) |
| inline c1024 d1 | 630 710 | 580 206 | 0.920 | 0.920 | 0.90 | 0.928 | met |
| inline c1024 d16 | 2 576 210 | 1 948 607 | 0.756 | 0.757 | 0.75 | 0.776 | met |
| worker c256 d1 | 453 159 | 435 033 | 0.960 | 0.960 | 0.95 | 0.967 | met |
| worker c1024 d1 | 420 780 | 411 369 | 0.978 | 0.977 | 0.95 | 0.973 | met |

The inline ratios are 0.01-0.02 lower than after FQ (FQ ran at round r7; r8 added 135 instructions per
request, and UB/UB2 changed the framework's request path since). Against hyper (configuration B, section
3.1), the framework's inline route reaches 600 737 / 682 065 = 0.88 x hyper at c256 d1 and
1 993 138 / 3 097 022 = 0.64 x at c256 d16.

## 10. Files written in S10

- `bench/run_gate.sh`: CPU split from the environment (`SERVER_CPUS`, `SERVER_THREADS`, `WRK_CPUS`,
  `WRK_THREADS`; defaults = configuration B).
- `bench/p99.sh` (wrk2 fixed-rate latency), `bench/idle_rss.sh` (idle connection memory),
  `bench/syscalls.sh` (strace counts per request).
- `tools/get-tools.sh`: the wrk2 bytecode fix (section 4.1).
- This report.

## 11. Open questions for the user

1. The p99, idle-memory and RSS targets of 7.6 are goals from decision 2 (taken under your delegation);
   S10's exit says "as confirmed by the user". All three are met with the numbers above; please confirm
   them as the targets (depth-1 p99 <= 1.25 x hyper, idle <= 2 KB per connection, RSS under load <=
   hyper's).
2. Configuration A at depth 1 cannot be measured here (wrk is the bottleneck); accept configuration A as
   reported for depth 16 only, or name a second machine for the load generator.
3. The governor stayed `powersave` (setting `performance` needs root). If you want the matrix under
   `performance`, run `sudo cpupower frequency-set -g performance` and re-run `bench/run_gate.sh`.
4. The depth-16 gap (0.854 / 0.880 x hyper) comes from time per instruction, not instruction count
   (section 8). Closing it needs hardware-counter profiles (`perf stat`/`perf record`, which need
   `kernel.perf_event_paranoid` <= 2) and is a tuning step, not part of S10.

## User decisions (2026-10-10)

1. The three goals of decision 2 are confirmed as the targets: depth-1 p99 <= 1.25 x hyper, idle
   keep-alive connection <= 2 KB, RSS under load <= hyper. All are met (section 1).
2. Configuration A at depth 1 is not measured (it needs a second machine for the load generator);
   configuration A is reported at depth 16 only.
3. The matrix is not re-run under the `performance` governor.
4. No tuning step for the depth-16 gap (it would need hardware counters, perf_event_paranoid <= 2).

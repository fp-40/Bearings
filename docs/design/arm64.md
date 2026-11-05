# 12. ARM64

The library compiles for aarch64-linux (ARM64) as well as x86_64-linux.
Two units know the architecture: `bearings.rt.sys` (the system call
stubs: `syscall` with the x86_64 call numbers in
`bearings.rt.sys.x86_64.inc`, `svc #0` with the generic call numbers in
`bearings.rt.sys.aarch64.inc`, where `epoll_pwait` stands in for the
missing `epoll_wait`; and `struct epoll_event`, packed on x86_64 only) and
`bearings.rt.sync` (the spin-wait hint, the valgrind client request for
drd builds, and the memory ordering below). Everything else is the same
source.

## Memory ordering

The lock-free code (`bearings.rt.sync`, `TLoop.Post`, the exchange's
state, counters and claims, the WebSocket's references) was written
against the x86-64 model: locked instructions are full barriers, and plain
aligned loads and stores keep program order among themselves. ARM64 is
weaker, and FPC 3.2.2's `Interlocked*` routines on ARM64 are plain
`ldxr`/`stxr` loops with no barrier at all. So every shared-word access of
the library goes through the `Atomic*` wrappers of `bearings.rt.sync`,
never through `Interlocked*` directly, and on ARM64 the wrappers add the
barriers that give each access the x86-64 guarantee: a load barrier after
an `AtomicLoad*`, a full barrier before an `AtomicStore*`, and a full
barrier on both sides of each read-modify-write (`AtomicXchg`,
`AtomicCas`, `AtomicInc`, ...). This is deliberately conservative: correct
by construction, with more barriers than a per-site acquire/release
analysis would need. On x86_64 the wrappers add no barrier.

## Status

Not verified on hardware. The ARM64 build has been exercised only under
`qemu-aarch64` on an x86_64 host, which runs the ARM64 instructions on a
strongly ordered CPU and so cannot show a missing barrier (section 11).
What that run checks: the system call stubs (`test_rt_sys` compares each
one with the FPC RTL), the record layouts, and every unit suite with its
heaptrc run. What it does not check: the memory ordering argument above,
and the test programs' own direct `Interlocked*` calls (relaxed on ARM64;
they are counters checked after a join, but they have not been reviewed).
The first run on an ARM64 machine should be `TARGET=aarch64` with `RUN=`
empty and `FPC=fpc` on that machine, then `tools/s7-stress.sh`.

The `arm64` workflow (`.github/workflows/arm64.yml`) does that on GitHub's
ARM64 runner (`ubuntu-24.04-arm`): the unit suites with their heaptrc runs,
the worker stress without its drd part (`DRD_RUNS=0`: drd runs one thread
at a time, which shows nothing about the memory ordering) and the
pybearings tests. It does not run on a push: it is started by hand from
the Actions tab, and `upload-to-pypi.yml` calls it before it builds the
wheels. It has not run yet. One passing run is not the verification: a
missing barrier fails only now and then, so the status above changes after
several passing runs of the stress, not after the first.

## Cross-building on x86_64

On Ubuntu or Debian, install `binutils-aarch64-linux-gnu`,
`libc6-arm64-cross` and `qemu-user`, then run `tools/get-cross-aarch64.sh`.
It builds the FPC 3.2.2 cross compiler, RTL and packages from the FPC
source (fetched and checked by hash) into `build/tools/fpc-aarch64/`, with
one patch to the C start-up code for glibc 2.34 and later, fetches the
ARM64 `libgcc_s` package without installing it, and writes two wrappers:
`build/tools/bin/fpc-aarch64` (fpc for the cross target) and
`build/tools/bin/run-aarch64` (runs an ARM64 binary under qemu).

`TARGET=aarch64 uv run --project python pytest -m fast` then builds and runs the unit
suites and their heaptrc runs in `build/unit-aarch64/`; the valgrind, drd,
stress, echo, split-fuzz, golden, hot-asm and conformance tests are x86_64-only and skipped.
`FPC=build/tools/bin/fpc-aarch64 tools/compile-each-unit.sh` compiles
every unit on its own for ARM64. `tools/install-package.sh aarch64`
installs the cross-built units as a package.

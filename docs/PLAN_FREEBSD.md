# Plan: Bearings on FreeBSD

Status: planned, not started. Written 2026-10-25 from a reading of the
runtime, the build files, the tests and the CI. Nothing here is
implemented.

## Decisions

Taken on 2026-10-25:

1. **FreeBSD 14.x** is the floor. It gives `SO_REUSEPORT_LB`, `eventfd`,
   the 64-bit `kevent`, `accept4` and the 1024-CPU `cpuset_t` without
   version conditionals. Older releases are not a target.
2. **The shared-exclusive listener mode falls back to a single accepting
   loop** on FreeBSD. kqueue has no `EPOLLEXCLUSIVE`; waking every loop
   per connection is the alternative, and it was rejected.
3. **Testing happens in a FreeBSD 14 guest under qemu on the development
   machine** (qemu with KVM is installed). Cross-compilation from Linux
   proves that the code compiles; only the guest proves that it runs.
4. **No FreeBSD job in CI** for now. GitHub has no FreeBSD runners; a VM
   action would add minutes of boot time to every push. FreeBSD stays a
   locally tested platform until that changes.
5. **Wheels go to the GitHub release as assets, for every platform**:
   the Linux x86_64 and ARM64 wheels and the sdist that CI builds, and
   the FreeBSD wheel built in the guest. PyPI accepts no FreeBSD platform
   tag, so the release page is the only place a FreeBSD wheel can live.
   The Linux wheels keep going to PyPI as well.

## Where the Linux dependence is

The layers above the runtime (`src/http`, `src/http1`, `src/ws`,
`src/server` except the listener setup, `src/capi`) call the kernel only
through `bearings.rt.*`. The Linux dependence is in the runtime:

Unit | Linux dependence
---- | ----------------
`bearings.rt.sys` | hand-written system call stubs (`syscall`, `svc #0`) with Linux call numbers; Linux errno values; epoll, eventfd, socket and futex constants; `struct epoll_event`
`bearings.rt.loop` | epoll (create, ctl, wait), eventfd as the wake-up, `ReadyFromEpoll` maps epoll bits to `TReadySet`, `OnIo` and `Register` take raw epoll bits
`bearings.rt.net` | `accept4` flags, `SO_REUSEPORT`, Linux `sockaddr` layout (16-bit family), `sun_path` of 108 bytes, `IOV_MAX`, the Linux `sendfile` contract
`bearings.rt.stream` | `EPOLL_CTL_MOD` when an upgraded connection takes over a socket
`bearings.rt.sync` | `futex` wait and wake (`TParker`, `TEventCount`)
`bearings.rt.cpu` | `sched_getaffinity`, `sched_setaffinity`, cgroup v1/v2 quota from `/proc`, `/sys/devices/system/cpu/online`
`bearings.rt.clock` | `CLOCK_MONOTONIC = 1` (libc `clock_gettime` itself is portable)
`bearings.server` | `EPOLLEXCLUSIVE` for the shared-exclusive mode; `EPOLLIN or EPOLLOUT or EPOLLRDHUP or EPOLLET` for connections
`bearings.rt.sd` | no change: systemd is never present, but the unit only reads the environment and sends on a datagram socket through portable RTL calls

The HTTP date, access log, C API and stream units use `BaseUnix` for
`FpFcntl`, `FpChmod`, `FpChown`, `FpUnlink`, `FpLStat`, `FpClose` and the
signal routines. All of these exist on FreeBSD through the same RTL units.

## The work, by area

### 1. System calls (`bearings.rt.sys`)

- New include file `bearings.rt.sys.freebsd.x86_64.inc` with the FreeBSD
  call numbers. The error convention differs: Linux returns `-errno` in
  the result register; FreeBSD returns `errno` as a positive value and
  sets the carry flag. Each stub needs a `jnc` or `jc` and a negation so
  that the routines keep the "`>= 0` or `-errno`" contract the rest of the
  runtime tests against.
- The errno constants become OS-selected. On FreeBSD: `EAGAIN 35`,
  `ENOTSOCK 38`, `EADDRINUSE 48`, `ECONNABORTED 53`, `ECONNRESET 54`,
  `ENOBUFS 55`, `ETIMEDOUT 60`, `ECONNREFUSED 61`, `ENOSYS 78`. `EINTR`,
  `EBADF`, `ENOMEM`, `EFAULT`, `EINVAL`, `ENFILE`, `EMFILE` and `EPIPE`
  are the same on both.
- The socket constants become OS-selected. On FreeBSD: `AF_INET6 28`,
  `SOL_SOCKET $ffff`, `SO_REUSEADDR 4`, `SO_REUSEPORT $200`,
  `SO_REUSEPORT_LB $10000`, `SO_ERROR $1007`, `SO_SNDBUF $1001`,
  `SO_RCVBUF $1002`, `SOCK_NONBLOCK $20000000`, `SOCK_CLOEXEC $10000000`.
  `TCP_NODELAY`, `IPPROTO_TCP`, `SOCK_STREAM`, `AF_INET`, `AF_UNIX` and
  the `SHUT_*` values are the same.
- New routines for FreeBSD: `SysKqueue`, `SysKevent`, `SysUmtxOp`,
  `SysCpusetGetAffinity`, `SysCpusetSetAffinity`, and a FreeBSD
  `SysSendFile` (section 5). The epoll, eventfd, futex and `sched_*`
  routines are compiled on Linux only.
- `struct kevent` (64 bytes on FreeBSD 14: `ident`, `filter`, `flags`,
  `fflags`, `data`, `udata`, `ext[4]`) replaces `TEpollEvent` on FreeBSD.
- The Linux include files and constants do not change. `test_rt_sys`
  gets a FreeBSD variant that compares each routine with the FPC RTL, as
  it does on Linux.

### 2. The event loop: epoll to kqueue (`bearings.rt.loop`, `bearings.rt.stream`, `bearings.server`)

This is the substantive port, and the one that touches Linux code.

- **A platform-neutral poller interface** inside `TLoop`: register a
  source for read, write, or both, edge- or level-triggered; unregister;
  move a registration to another source (the upgrade hand-off in
  `bearings.rt.stream`); wait with a timeout; wake from another thread.
  On Linux it is the epoll code that exists today. On FreeBSD it is
  kqueue.
- **Event bits become neutral.** `TIoTask.OnIo(Events: Cardinal)` and
  `TLoop.Register(Src, Events)` take epoll bits today. They take a
  `TReadySet` (already defined) and a small set of registration flags
  instead. `ReadyFromEpoll` stays on Linux as the translation; FreeBSD
  gets `ReadyFromKevent`. The three callers of `Register`
  (`bearings.server` for connections, `TListener.Register`,
  `TUpgraded.CreateFrom`) change their arguments.
- **Two events per socket.** kqueue reports `EVFILT_READ` and
  `EVFILT_WRITE` as separate entries, where epoll delivers one combined
  bit set. The loop coalesces entries of the same `udata` in one batch
  before calling `OnIo`, so a task sees one call per iteration as it
  does now. The dispatcher's wake-source check (`-dWD_DEBUG` in
  `test_h1_dispatch`) depends on that.
- **Readiness mapping for kqueue.** There is no `EPOLLERR`, `EPOLLHUP`
  or `EPOLLRDHUP`. Peer shutdown and errors arrive as `EV_EOF` on the
  filter, with the errno in `fflags`. The mapping:
  - `EVFILT_READ` -> `rdRead`; with `EV_EOF` also `rdReadClosed`
  - `EVFILT_WRITE` -> `rdWrite`; with `EV_EOF` also `rdWriteClosed`
  - `EV_EOF` with `fflags <> 0` on either filter -> `rdError`
  - `EV_ERROR` in the batch is a registration failure, not a socket
    error; it is handled where `Register` returns
  This is checked by `test_rt_loop` and the dispatcher and connection
  suites. Expect iterations here: the sticky-bit rules of `ReadyFromEpoll`
  were derived from Linux behaviour, and some of them (for example
  "exactly `EPOLLERR`" meaning the write side is gone) have no direct
  kqueue counterpart.
- **Edge-triggered connections** use `EV_CLEAR`. **Level-triggered
  listeners** and the wake-up register without it.
- **The wake-up** is `EVFILT_USER` on FreeBSD: `Post` triggers it with
  `NOTE_TRIGGER` (one `kevent` call, like the one `write` to the eventfd
  today), and the loop sees it in the batch with `udata = nil`. No
  descriptor and no `read` to reset it. `WakeFd` and the eventfd stay on
  Linux. `WakeWrites` keeps its meaning (wake-ups sent).
- **The upgrade hand-off** (`TUpgraded.CreateFrom`) re-registers both
  filters with the new `udata` instead of `EPOLL_CTL_MOD`.
- **Closing a socket** removes it from a kqueue as it does from epoll,
  so the "close without unregister" paths stay as they are.

### 3. Listener modes (`bearings.server`, `bearings.rt.net`)

- `amReusePort` sets `SO_REUSEPORT_LB` on FreeBSD. Plain `SO_REUSEPORT`
  there lets several sockets bind the port but sends every connection to
  one of them.
- `amSharedExclusive` (Unix sockets, inherited descriptors) becomes
  `amSingle` on FreeBSD at `Start`, where the mode is already rewritten
  for those cases on Linux. The metrics and the docs say so.
- `amSingle` is unchanged.

### 4. Sockets and addresses (`bearings.rt.net`)

- BSD `sockaddr` starts with a length byte and a family byte; Linux has
  a 16-bit family. `TSockAddrStorage.Family: Word` and the code that
  builds `sockaddr_in`, `sockaddr_in6` and `sockaddr_un` and reads the
  peer's address (`SockAddrToStr`, the PROXY protocol's peer, the access
  log's `client`) get an OS-selected layout. `sa_len` is set on FreeBSD
  (the kernel accepts zero for `bind`, but `getsockname` and `accept4`
  fill it, and it must not be read as part of the family).
- `UNIX_PATH_MAX` is 104 on FreeBSD.
- `accept4` exists with the same shape; only the flag values differ.
- `TCP_NODELAY` on the listening socket: Linux copies it to accepted
  sockets. FreeBSD's syncache appears to inherit `TF_NODELAY` from the
  listener as well. Verify in the guest; if not, set it per accepted
  socket on FreeBSD.
- `IOV_MAX` is 1024 on both.

### 5. sendfile (`bearings.rt.net`, `bearings.http1.io`)

FreeBSD's `sendfile(fd, s, offset, nbytes, hdtr, *sbytes, flags)` returns
0 or -1 and the bytes sent through `sbytes`; it can return `EAGAIN` after
a partial send, and `EBUSY` when the pages are busy. The FreeBSD
`SysSendFile` folds this into the contract `bearings.http1.io` relies on:
bytes sent when more than zero were sent, even with `EAGAIN`; `-EAGAIN`
when nothing was; `-errno` otherwise. `EBUSY` is treated as `EAGAIN`.
`SENDFILE_MAX_CHUNK` stays (harmless on FreeBSD).

### 6. Synchronization (`bearings.rt.sync`)

- `TParker.Park` and `Unpark`, `TEventCount.Wait` and `NotifyAll` call
  `_umtx_op` on FreeBSD: `UMTX_OP_WAIT_UINT_PRIVATE` and
  `UMTX_OP_WAKE_PRIVATE`. The timed wait passes a relative `timespec`
  (`uaddr1 = sizeof(timespec)`, `uaddr2 = @ts`); the return codes to
  check are `ETIMEDOUT`, `EINTR` and `EAGAIN`-like early returns, which
  the loop in `Park` already treats as "check the state and sleep again".
- The spin lock, the atomics and the drd annotations do not change.
- The Linux futex code does not change.

### 7. CPUs (`bearings.rt.cpu`)

- `UsableCpus`: `cpuset_getaffinity(CPU_LEVEL_WHICH, CPU_WHICH_TID, -1,
  size, mask)`. `cpuset_t` is 1024 bits on FreeBSD 14 (`CPU_SET_BYTES`
  stays 128). Verify in the guest that the kernel accepts that size.
- `PinCurrentThread`: `cpuset_setaffinity` with the same selectors.
- `CgroupCpuLimit` returns 0 on FreeBSD (no cgroups; a jail's `rctl`
  limits are not a CPU count). The `/proc` parsing compiles on both but
  is called on Linux only.
- The `/sys/devices/system/cpu/online` fallback becomes
  `sysctl hw.ncpu` on FreeBSD.

### 8. Clock (`bearings.rt.clock`)

`CLOCK_MONOTONIC` is 4 on FreeBSD. `clock_gettime` from libc is fast on
FreeBSD too (the shared page); nothing else changes.

### 9. Build

- `fpmake.pp`: `P.OSes := [linux, freebsd]`. The FreeBSD port of FPC
  3.2.2 (`lang/fpc`) is x86_64 only, so FreeBSD ARM64 is out of scope
  until the project moves to a newer compiler.
- `tools/install-package.sh`, `tools/compile-each-unit.sh` and
  `tools/check-version.sh`: no OS assumption beyond `fpc` in the path;
  check them in the guest.
- `python/hatch_build.py`:
  - drop the "runs only on Linux" check; accept `fpc -iTO` in
    `linux`, `freebsd`;
  - the output is `libbearings.so` on both (FreeBSD uses the same
    suffix);
  - the wheel tag: `manylinux_X_Y_<cpu>` from the glibc symbols on Linux
    as today; on FreeBSD, the tag `sysconfig.get_platform()` gives,
    normalized (for example `freebsd_14_1_RELEASE_p3_amd64`). That tag
    names the exact release and patch level the wheel was built on, and
    pip installs a wheel only when the tag matches, so a FreeBSD wheel
    serves one release; other machines build the sdist. State this in
    the release notes and in `python/README.md`;
  - `objdump` is in FreeBSD's base system (binutils) as well; the glibc
    scan is skipped there.
- `python/pyproject.toml`: the `Operating System :: POSIX :: BSD ::
  FreeBSD` classifier; nothing else.
- Python on FreeBSD: uv cannot download a managed CPython there (there
  are no FreeBSD builds of python-build-standalone). The guest uses the
  ports interpreter (`lang/python314` or newer) with
  `uv sync --python /usr/local/bin/python3.14`. Whether a free-threaded
  build is in ports is to be checked; pybearings must work on the GIL
  build regardless, since the library has no free-threading requirement,
  only the tests' tox list names `3.14t`.

### 10. Tests

- `tests/unit/run_all.sh` on FreeBSD: `timeout` is `gtimeout` from
  `sysutils/coreutils`; the drd, stress, memcheck, split-fuzz and hot-asm
  steps are host-only and skipped, as for `TARGET=aarch64`. A `TARGET=
  freebsd` or a detection on `uname` picks this.
- `test_rt_sys` uses `taskset` for the affinity cases; FreeBSD has
  `cpuset -l`. The FreeBSD variant of the suite compares the new
  routines with the RTL.
- `test_rt_loop`, `test_h1_dispatch`, `test_h1_conn`, `test_server`,
  `test_server_ops`, `test_ws_echo`, `test_capi`: real sockets; they are
  the verification of the kqueue mapping. Cases that assert Linux-only
  behaviour (the exact epoll bit combinations, the shared-exclusive
  listener spreading connections over loops) get FreeBSD expectations or
  are skipped there with the reason written down.
- The Python tests run unchanged on the ports interpreter.
- `tools/check-hot-asm.sh` stays a Linux x86_64 check. Run it on the
  Linux build after the loop changes: that is the gate that the neutral
  poller interface did not cost the hot path anything.

### 11. The guest

- FreeBSD 14 `amd64` VM image (the official `qcow2`), qemu with KVM,
  `virtio` disk and network, ssh with port forwarding, the repository
  mounted with `virtio-9p` or synced with `rsync`.
- Packages: `lang/fpc`, `lang/python314`, `devel/git`,
  `sysutils/coreutils`, `devel/py-pip` or uv (`pipx install uv` or the
  release binary; uv runs on FreeBSD, it only cannot fetch Pythons).
- A `tools/freebsd-vm.sh` that downloads the image once, starts the
  guest, and runs a command over ssh (`tools/freebsd-vm.sh make test`),
  so the FreeBSD run is one command from Linux. The image and its disk
  live under `build/` and are not committed.
- The first run in the guest is `test_rt_sys`, then the loop suite,
  then the rest of the fast tier, then the Python tests.

### 12. Release: wheels as GitHub release assets

Today `tools/release.sh` creates the release with `gh release create`,
which triggers `.github/workflows/upload-to-pypi.yml`: CI builds the
Linux x86_64 wheel and the sdist on `ubuntu-24.04`, the ARM64 wheel on
`ubuntu-24.04-arm`, and publishes them to PyPI.

The change:

- `upload-to-pypi.yml` gets a job after `upload` (or a step in it) that
  attaches every file of `dist/` to the release:
  `gh release upload "$TAG" dist/* --clobber`, with `contents: write`
  and `GH_TOKEN`. The tag is `github.event.release.tag_name` (the
  workflow runs on `release: released`; the manual `workflow_dispatch`
  path needs the tag as an input or is left PyPI-only).
- The FreeBSD wheel is built in the guest after the release exists:
  `tools/freebsd-vm.sh 'cd python && uv build --wheel'`, then
  `gh release upload X.Y.Z python/dist/pybearings-X.Y.Z-py3-none-freebsd_*.whl`
  from the host. `tools/release.sh` gets this as a final step, after the
  release is created, with a clear message if the guest is not
  available (the release is still complete without it; the FreeBSD
  wheel can be added later with the same command).
- The release notes (`--generate-notes` today) get a fixed paragraph on
  the assets: the Linux wheels are the PyPI ones; the FreeBSD wheel
  installs with `pip install <url>` on the release it was built on, and
  `pip install pybearings` builds from the sdist elsewhere (needs `fpc`).
- `python/README.md` and `docs/setup.md` document the FreeBSD install
  paths.

### 13. Docs

- `README.md`: "runs natively only on Linux" becomes Linux and FreeBSD
  (x86_64; ARM64 on Linux only), with the FreeBSD differences listed:
  no cgroup quota, `amSharedExclusive` falls back to one accepting loop,
  wheels from the GitHub release.
- `docs/setup.md`, `docs/overview.md`, `docs/design/io.md`,
  `docs/design/limits.md`, `docs/design/purpose.md`: the epoll, futex,
  eventfd and sendfile passages name the kqueue, `_umtx_op`,
  `EVFILT_USER` and FreeBSD `sendfile` counterparts.
- A `docs/design/freebsd.md` modelled on `docs/design/arm64.md`: what
  differs, what was verified in the guest, what was not.
- `docs/api/server.md`: the `Mode` field's FreeBSD note.
- `CHANGELOG.md`.

## Effect on the Linux build

- **Unchanged:** the Linux system call stubs, call numbers and
  constants; the futex, cgroup and sendfile code; the systemd unit; the
  C header; the Python package's Linux build and its PyPI upload.
- **Changed, shared:** `TLoop`'s registration, wait and readiness
  mapping move behind the poller interface, and `OnIo` and `Register`
  take neutral flags. The epoll calls themselves stay. Guard: the fast
  and full tiers (drd included) and `tools/check-hot-asm.sh` on Linux,
  run before the branch is merged, plus the benchmark gate
  (`make benchmark`) once at the end for the throughput number.
- **Changed, additive:** `hatch_build.py` gains an OS branch; the
  release workflow gains the assets step. Neither alters the Linux
  wheel's contents or tag.

## Order of work

1. The guest (section 11), so that every later step can be run there.
2. `bearings.rt.sys` for FreeBSD and `test_rt_sys` (section 1). Pure
   addition; compile-checked from Linux with `fpc -Tfreebsd` if the
   cross units are at hand, else in the guest.
3. The clock, CPU and sync units (sections 6 to 8). Each has a unit
   test.
4. The poller interface in `TLoop` on Linux first, with the Linux tiers
   and the hot-asm check green, committed on its own (section 2, first
   half). This is the step that touches Linux and it is verified alone.
5. The kqueue poller, the readiness mapping, the wake-up (section 2,
   second half). `test_rt_loop` in the guest.
6. Sockets, addresses, listener modes, sendfile (sections 3 to 5).
   `test_rt_net`, `test_server`, `test_server_ops` in the guest.
7. The rest of the fast tier in the guest; the C API suite; the Python
   package and its tests on the ports interpreter (sections 9 and 10).
8. Release flow and docs (sections 12 and 13).

## To verify in the guest before relying on it

- `cpuset_getaffinity` with a 128-byte mask on FreeBSD 14.
- `TCP_NODELAY` inheritance from the listening socket.
- `EV_EOF` and `fflags` on `EVFILT_WRITE` after a reset, against the
  `rdWriteClosed` and `rdError` cases `test_rt_loop` expects.
- `sendfile` partial-send plus `EAGAIN` behaviour on a non-blocking
  socket with a full send buffer.
- `_umtx_op` timed wait return codes.
- Whether a free-threaded Python 3.14 is in ports; the GIL build is the
  baseline either way.
- The exact wheel platform tag `sysconfig.get_platform()` gives, and
  that pip accepts it on the same release.

# Compatibility policy

**Status: draft.** Nothing here is in force. It is the text proposed for
version 1.0.0.

This document says what a program that uses Bearings can rely on from one
version to the next, and what it cannot.

## Versions

Bearings and pybearings have one version, `X.Y.Z`
(`bearings.version.BEARINGS_VERSION`, `bearings_version()`,
`bearings.VERSION`).

From 1.0.0 on:

- **Z (patch)** changes when a release only fixes defects. Nothing covered
  by this document changes, with the exception of security fixes (below).
- **Y (minor)** changes when a release adds something: a routine, an
  option, a field at the end of a record, a metric, a key in the access
  log. A program written for `X.Y` works with `X.(Y+1)` without changes.
- **X (major)** changes when a release removes or changes something this
  document covers.

Before 1.0.0, a minor release (`0.Y`) may change anything, and the
changelog says what a program must change. A patch release (`0.Y.Z`) keeps
the rules of a patch release.

## What is covered

### The Pascal API

The types and routines in the reference tables of
[`docs/api/reference.md`](api/reference.md) that are not marked
"internal".

Compatibility is at the source level: a program that compiles against
`X.Y` compiles against a later `X` and behaves the same. It is not at the
binary level: the units are compiled with the program, by the same
compiler.

A minor release may add routines, add fields to the configuration records
and add values at the end of an enumerated type. So that these additions
do not break it, a program:

- starts a configuration record from a preset (`ProductionServerConfig`,
  `ProductionH1Config`, ...) or from `Default(...)` and assigns the fields
  it needs by name, and does not write the record as a typed constant
  with every field;
- gives a `case` over an enumerated type of the library (an error kind, a
  connection outcome) an `else` branch.

### The C interface

What [`src/capi/bearings.h`](../src/capi/bearings.h) declares, at the
binary level: a program built against the header of `X.Y` runs with the
`libbearings.so` of a later `X` without being rebuilt.

- A routine keeps its name, its parameters and the meaning of its results.
- `bearings_config` only grows at its end. Its `size` field tells the
  library which fields the program has ([API guide, section 15](api/capi.md)).
- The callbacks keep their parameters. The request head keeps its layout:
  the six fixed fields, then a name and a value per header.
- The result codes and the WebSocket event numbers keep their meaning. A
  minor release may add an event number: a WebSocket callback ignores the
  numbers it does not know.

The library's name carries no version (`libbearings.so`, also its
soname). A versioned name (`libbearings.so.1`) serves a library installed
for the whole system, where several programs find it by name. That is not
how this one is distributed: the pybearings wheel holds its own copy and
loads it by its path, and a C program builds the library with its own
build. A program that loads a `libbearings.so` it did not build compares
`bearings_version()` with the version it was written for. If Bearings
ever gets a system-wide install or a distribution package, the name gets
the major version then.

### The Python package

- The names in `bearings.__all__`.
- The keyword arguments of `Server` and `serve`, and the methods and
  properties of `Server`. All options are keyword-only, so a new one is an
  addition.
- The methods a `WebSocketHandler` may define and the arguments they get.
- The WSGI environ the server builds, and the arguments of a raw handler
  (`raw=True`).

Everything else in the package (`bearings._ffi`, the modules' other names)
is internal.

### Behaviour on the wire

What a client or a proxy can observe: which requests are accepted and
which are refused, the framing of responses, the automatic responses,
keep-alive, pipelining, timeouts, the WebSocket rules.
[`docs/design/deviations.md`](design/deviations.md) lists the places where
this is not what RFC 9110, RFC 9112 or RFC 6455 would lead a reader to
expect.

A change a client can observe needs a minor release and its own changelog
entry. A change that makes a compliant client fail needs a major release.
The exception is security (below).

Not covered: how the bytes of a response are split into TCP segments, and
timing in general.

### Defaults

The values of the configuration presets and of the C and Python defaults.
A changed default needs a minor release and its own changelog entry.

### What the server writes for other programs

- The names, types and labels of the Prometheus metrics.
- The keys of the JSON access log and the meaning of their values.

A minor release may add a metric, a label value or a key. A removal or a
rename needs a major release.

## What is not covered

- Units, types and members that the reference tables mark "internal" or
  leave out: the members whose names start with `Dbg`, the test hooks, and
  the units a program does not use directly (the parser, the connection
  state machine, the dispatcher, `bearings.rt.sys`).
- The texts of errors and of log messages. A program decides on the error
  kind (`TH1ErrorKind`, `TDecodeError`, the C result codes, the Python
  exception classes), not on the text.
- The console format of the access log, which is written for people.
- Performance, memory use, the number of system calls.
- The debug build flags (`-dWD_DEBUG`, `-dWD_STALL`, `-dWD_DRD`) and what
  they check.
- `tests/`, `conformance/`, `bench/`, `tools/` and `examples/`.
- Behaviour that the documentation describes as a defect or that
  contradicts it: fixing it is a patch.

## Security fixes

When the behaviour a program relies on is itself the vulnerability (for
example a request the parser accepted that lets a proxy and the server
disagree on where a request ends), the fix may come in a patch release
even though it changes what is covered. Its changelog entry says what
changed and which clients are affected.

Security fixes go to the latest minor release only. A program on an
older minor gets the fix by moving to the latest one, which the rules
above make possible without changes.

A vulnerability is reported in private, through GitHub
([`SECURITY.md`](../SECURITY.md)).

## Platforms and tools

| | Covered |
|---|---|
| Linux x86_64 | yes; every release passes the fast and the full test tiers on it |
| Linux ARM64 | experimental, and outside this policy, until the unit suites and the worker stress have run on ARM64 hardware. The library builds for it and passes the unit suites under qemu on x86_64, which cannot show an error in the memory-ordering code ([`docs/design/arm64.md`](design/arm64.md)) |
| Linux kernel | 4.5 or later. It is the newest kernel feature the runtime uses: `EPOLLEXCLUSIVE`, for a Unix socket, a socket inherited from systemd and the `amSharedExclusive` accept mode. The default TCP mode alone needs 3.9 (`SO_REUSEPORT`). The number comes from the system calls and flags in the code ([`docs/design/purpose.md`](design/purpose.md)); no kernel that old is part of the tests, which run on the kernels of the development machine and of CI |
| Free Pascal | 3.2.2, the version the tests run with. Support for a later version is added in a minor release; dropping a version needs a major release |
| Python | the versions `requires-python` of `python/pyproject.toml` allows (3.14 and later today), tested in CI with the free-threaded builds of 3.14 and 3.15. When a Python version reaches its end of life, a minor release may raise `requires-python` past it: `pip` on the older Python keeps installing the last release that allows it, so no installed program breaks |
| glibc | the version in the wheel's `manylinux` tag (2.34 today) |

## Removing something

Before a major release removes or renames something covered, a minor
release of the previous major marks it as deprecated: in the changelog, in
the documentation, and for Pascal routines with the `deprecated`
directive, so that the compiler warns. It keeps working until the major
release.

## The changelog

Every change to something covered has its own entry in `CHANGELOG.md`. An
entry for an incompatible change says what a program must change.

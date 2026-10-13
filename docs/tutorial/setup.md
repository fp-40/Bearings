# Setup

You need Free Pascal 3.2.2 on Linux x86_64 (an ARM64 build exists but has
only run under emulation; see `README.md`, section "ARM64"). Check the
compiler:

```sh
fpc -iV
```

Get the library:

```sh
git clone <bearings repository> bearings
cd bearings
```

## Install the units as a package

Bearings has no build step of its own, but a program has to find its
units. The simplest way is to install them once with fpmake, FPC's own
package tool. `fpmake.pp` at the repository root declares the package and
its units; `tools/install-package.sh` compiles it and runs its `install`
command:

```sh
tools/install-package.sh
```

It prints where the units went: `~/.fppkg/lib/fpc/3.2.2/units/x86_64-linux/bearings/`,
a directory that `/etc/fpc.cfg` already searches. From then on a program
that uses the library compiles with no paths, from any directory:

```sh
fpc -Mobjfpc -Sh -O2 hello.pas
./hello 8080
```

`-Mobjfpc -Sh` select the Object Pascal mode with long strings, which every
unit of the library uses. Every program in this tutorial is compiled this
way.

The installed units are a copy. After changing the library, run the
script again. `PREFIX` overrides `~/.fppkg`, and `tools/install-package.sh
aarch64` installs the ARM64 cross build.

## Without installing

A program can compile against the source tree instead, with the five
unit directories on its path. From the repository root:

```sh
mkdir -p build/tutorial/units
fpc -Mobjfpc -Sh -O2 -Fusrc/rt -Fusrc/http -Fusrc/http1 -Fusrc/server -Fusrc/ws \
    -FUbuild/tutorial/units -FEbuild/tutorial hello.pas
```

`-FU` is where compiled units go and `-FE` where the executable goes;
both directories must exist. `examples/README.md` builds the example
programs this way.

## Tools

You will also want `curl`, and for the WebSocket chapter a client such as
`websocat`.

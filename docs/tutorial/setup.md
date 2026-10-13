# Setup

You need Free Pascal 3.2.2 on Linux x86_64 (an ARM64 build exists but has
only run under emulation; see `README.md`, section "ARM64"). Check the
compiler:

```sh
fpc -iV
```

Get the library and make a directory for the programs of this tutorial:

```sh
git clone <bearings repository> bearings
cd bearings
mkdir -p build/tutorial/units
```

Every program in this tutorial compiles with the same command, run from
the repository root:

```sh
fpc -Mobjfpc -Sh -O2 -Fusrc/rt -Fusrc/http -Fusrc/http1 -Fusrc/server -Fusrc/ws \
    -FUbuild/tutorial/units -FEbuild/tutorial <program>.pas
```

`-Mobjfpc -Sh` select the Object Pascal mode with long strings, which every
unit of the library uses. The five `-Fu` options are the library's unit
directories; `-FU` is where compiled units go and `-FE` where the
executable goes. If you install the units as a package
(`tools/install-package.sh`), the `-Fu` options go away.

You will also want `curl`, and for the WebSocket chapter a client such as
`websocat`.

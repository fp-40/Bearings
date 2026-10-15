"""Compiles libbearings.so with Free Pascal.

An editable install gets it next to the package's modules (for this
machine). A wheel gets it from a directory of its own per CPU, so a wheel
for another CPU leaves the editable install alone: `PYBEARINGS_FPC` names
the compiler, for example the ARM64 cross compiler of
tools/get-cross-aarch64.sh, and the wheel is tagged for the CPU that
compiler targets (`fpc -iTP`).

    PYBEARINGS_FPC=../build/tools/bin/fpc-aarch64 uv build --wheel
"""

import os
import shutil
import subprocess
import sys
from pathlib import Path

from hatchling.builders.hooks.plugin.interface import BuildHookInterface


# the oldest glibc whose symbols libbearings.so uses (objdump -T), on
# x86_64 and aarch64 alike
MANYLINUX = "manylinux_2_34"
UNITS = ("rt", "http", "http1", "server", "ws", "capi")

# fpc -iTP -> the wheel's platform tag
CPUS = {
    "x86_64": "x86_64",
    "aarch64": "aarch64",
}


class CustomBuildHook(BuildHookInterface):
    def initialize(self, version: str, build_data: dict) -> None:
        if not sys.platform.startswith("linux"):
            raise RuntimeError("Bearings runs only on Linux")

        fpc = os.environ.get("PYBEARINGS_FPC") or shutil.which("fpc")
        if not fpc:
            raise RuntimeError("building pybearings needs Free Pascal >= 3.2.2 (fpc)")

        fpc = str(Path(fpc).resolve()) if os.sep in fpc else fpc
        cpu = subprocess.run([fpc, "-iTP"], check=True, capture_output=True, text=True).stdout.strip()

        if cpu not in CPUS:
            raise RuntimeError(f"pybearings builds for {', '.join(CPUS)}, not {cpu}")

        root = Path(self.root).parent  # the repository
        src = root / "src"
        if version == "editable":
            out = Path(self.root) / "src" / "bearings"  # imported from here
        else:
            out = root / "build" / f"python-{cpu}"

        units = root / "build" / f"python-units-{cpu}"
        for directory in (out, units):
            directory.mkdir(parents=True, exist_ok=True)

        command = [
            fpc,
            "-Mobjfpc",
            "-Sh",
            "-O2",
            "-fPIC",
            "-vew",
            *(f"-Fu{src / unit}" for unit in UNITS),
            f"-Fi{src / 'rt'}",
            f"-FU{units}",
            f"-o{out / 'libbearings.so'}",
            str(src / "capi" / "libbearings.pas"),
        ]
        subprocess.run(command, check=True)
        shutil.copyfile(src / "capi" / "bearings.h", out / "bearings.h")

        if version != "editable":
            build_data["force_include"][str(out / "libbearings.so")] = (
                "bearings/libbearings.so"
            )
            build_data["force_include"][str(out / "bearings.h")] = "bearings/bearings.h"

        build_data["pure_python"] = False
        build_data["tag"] = f"py3-none-{MANYLINUX}_{CPUS[cpu]}"

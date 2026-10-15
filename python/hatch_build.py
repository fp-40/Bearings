"""Compiles libbearings.so with Free Pascal.

An editable install gets it next to the package's modules (for this
machine). A wheel gets it from a directory of its own per CPU, so a wheel
for another CPU leaves the editable install alone: `PYBEARINGS_FPC` names
the compiler, for example the ARM64 cross compiler of
tools/get-cross-aarch64.sh, and the wheel is tagged for the CPU that
compiler targets (`fpc -iTP`), and for the newest glibc symbol version
libbearings.so needs (`objdump -T`).

    PYBEARINGS_FPC=../build/tools/bin/fpc-aarch64 uv build --wheel

The Pascal sources are in src/ of the repository, or in pascal/ of an
unpacked sdist (force-include in pyproject.toml).
"""

import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

from hatchling.builders.hooks.plugin.interface import BuildHookInterface


UNITS = ("rt", "http", "http1", "server", "ws", "capi")

# fpc -iTP -> the wheel's platform tag
CPUS = {
    "x86_64": "x86_64",
    "aarch64": "aarch64",
}


def manylinux(library: Path) -> str:
    """The manylinux tag for `library`: the newest glibc symbol version it
    needs, which is the oldest glibc that loads it."""
    objdump = shutil.which("objdump")
    if not objdump:
        raise RuntimeError("tagging the pybearings wheel needs objdump (binutils)")

    symbols = subprocess.run(
        [objdump, "-T", str(library)], check=True, capture_output=True, text=True
    ).stdout
    versions = {
        tuple(int(n) for n in v.split("."))
        for v in re.findall(r"\bGLIBC_(\d+(?:\.\d+)+)\b", symbols)
    }
    if not versions:
        raise RuntimeError(f"no glibc symbol in {library}: is it linked against glibc?")

    major, minor = max(versions)[:2]
    return f"manylinux_{major}_{minor}"


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

        if (Path(self.root) / "pascal").is_dir():  # an unpacked sdist
            root = Path(self.root)
            src = root / "pascal"
        else:  # python/ of the repository
            root = Path(self.root).parent
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
        build_data["tag"] = f"py3-none-{manylinux(out / 'libbearings.so')}_{CPUS[cpu]}"

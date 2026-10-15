"""Compiles libbearings.so with Free Pascal, next to the package's modules,
for the wheel and for an editable install alike."""
import shutil
import subprocess
import sys
import sysconfig
from pathlib import Path

from hatchling.builders.hooks.plugin.interface import BuildHookInterface


# the oldest glibc whose symbols libbearings.so uses (objdump -T)
MANYLINUX = "manylinux_2_34"
UNITS = ("rt", "http", "http1", "server", "ws", "capi")


class CustomBuildHook(BuildHookInterface):
    def initialize(self, version: str, build_data: dict) -> None:
        if not sys.platform.startswith("linux"):
            raise RuntimeError("Bearings runs only on Linux")
        root = Path(self.root).parent  # the repository
        src = root / "src"
        out = Path(self.root) / "src" / "bearings"
        units = root / "build" / "python-units"
        units.mkdir(parents=True, exist_ok=True)
        fpc = shutil.which("fpc")
        if fpc is None:
            raise RuntimeError("building pybearings needs Free Pascal 3.2.2 (fpc)")
        command = [
            fpc, "-Mobjfpc", "-Sh", "-O2", "-fPIC", "-vew",
            *(f"-Fu{src / unit}" for unit in UNITS),
            f"-Fi{src / 'rt'}",
            f"-FU{units}",
            f"-o{out / 'libbearings.so'}",
            str(src / "capi" / "libbearings.pas"),
        ]
        subprocess.run(command, check=True)
        shutil.copyfile(src / "capi" / "bearings.h", out / "bearings.h")

        build_data["pure_python"] = False
        machine = sysconfig.get_platform().split("-", 1)[1]  # x86_64, aarch64
        build_data["tag"] = f"py3-none-{MANYLINUX}_{machine}"

"""The static checks of the fast tier: every place that names the version
names the same one (tools/check-version.sh), and no hot-path routine has an
implicit exception frame (tools/check-hot-asm.sh, docs/design.md 7.4;
HOT_ASM_ARGS overrides its arguments, default --s7)."""

import os
import shlex

import pytest
from harness import OUT, run_script


pytestmark = [pytest.mark.fast]


def test_version_consistent():
    proc = run_script("tools/check-version.sh", timeout=60)
    assert proc.returncode == 0, proc.stdout


@pytest.mark.hostonly
def test_hot_path_asm():
    log = OUT / "check-hot-asm" / "check-hot-asm.log"
    proc = run_script("tools/check-hot-asm.sh", shlex.split(os.environ.get("HOT_ASM_ARGS", "--s7")),
                      log=log, env={"OUT_DIR": str(OUT / "check-hot-asm")}, timeout=1800)
    assert proc.returncode == 0, f"check-hot-asm failed (see {log}):\n" \
        + "\n".join(proc.stdout.splitlines()[-20:])

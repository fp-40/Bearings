"""The fpcunit suites (docs/design/verification.md section 9), built with the
unit-test flags, every test method reported as a subtest; then the suites
that own memory across threads once more linked with heaptrc (-gh, the
same unit files), which must report 0 unfreed blocks.

    pytest -k h1_conn                              one suite
    pytest -k h1_conn --fpc-suite=TTestConnState   one suite class
    pytest -m "unit and not heaptrc"               the plain runs only
"""

import pytest
from harness import (
    OUT,
    ROOT,
    RUN,
    TEST_FLAGS,
    fpc_build,
    heaptrc_unfreed,
    report_fpcunit,
    run_fpcunit,
)

# suite -> extra compiler defines. test_h1_dispatch is built with -dWD_DEBUG
# (the wake-source check of docs/design/state-machine.md 5.10 runs in every test) and
# -dWD_STALL (TTestDispatchStall); the define changes bearings.http1.dispatch's
# fields, so it gets a unit directory of its own.
SUITES = {
    "test_parser": [],
    "test_codec": [],
    "test_role": [],
    "test_headers_validate": [],
    "test_rt_sys": [],
    "test_rt_timer": [],
    "test_rt_loop": [],
    "test_rt_net": [],
    "test_rt_readbuf": [],
    "test_h1_io": [],
    "test_h1_conn": [],
    "test_body_chan": [],
    "test_exchange": [],
    "test_h1_dispatch": ["-dWD_DEBUG", "-dWD_STALL"],
    "test_workers": [],
    "test_server": [],
    "test_server_ops": [],
    "test_ws_frame": [],
    "test_ws_handshake": [],
    "test_ws_conn": [],
    "test_ws_echo": [],
    "test_capi": [],
}
HEAPTRC_SUITES = [
    "test_h1_conn",
    "test_body_chan",
    "test_exchange",
    "test_h1_dispatch",
    "test_workers",
    "test_server",
    "test_server_ops",
    "test_ws_conn",
    "test_ws_echo",
    "test_capi",
]


def flags(suite: str, *extra: str) -> list[str]:
    return [*TEST_FLAGS, *extra, *SUITES[suite]]


@pytest.mark.fast
@pytest.mark.unit
@pytest.mark.parametrize("suite", list(SUITES), ids=list(SUITES))
def test_suite(suite, subtests, fpc_suite):
    unit_dir = OUT / "dispatch" if suite == "test_h1_dispatch" else OUT
    binary = fpc_build(
        ROOT / "tests/unit" / f"{suite}.pas", OUT, unit_dir, flags(suite)
    )
    # test_rt_sys starts the binary again through taskset: via the runner
    env = {"BEARINGS_RUNNER": " ".join(RUN)} if RUN else {}
    r = run_fpcunit(binary, OUT / f"{suite}.out", suite=fpc_suite, env=env)
    report_fpcunit(subtests, r, suite)


@pytest.mark.fast
@pytest.mark.unit
@pytest.mark.heaptrc
@pytest.mark.parametrize("suite", HEAPTRC_SUITES, ids=HEAPTRC_SUITES)
def test_suite_heaptrc(suite, subtests, fpc_suite):
    """S4 exit criterion: heaptrc clean. The summary goes to a log file
    (HEAPTRC=log=...): the console test runner leaves no stdout for it."""
    out = OUT / "heaptrc"
    # -gh only changes the program (it adds heaptrc to its uses clause): the
    # units are the plain run's, nothing is compiled again
    unit_dir = OUT / "dispatch" if suite == "test_h1_dispatch" else OUT
    binary = fpc_build(
        ROOT / "tests/unit" / f"{suite}.pas", out, unit_dir, flags(suite, "-gh")
    )
    heap = out / f"{suite}.heap"
    heap.unlink(missing_ok=True)
    env = {"HEAPTRC": f"log={heap}"}
    if RUN:
        # as in test_suite: the tests that start the binary again need the runner
        env["BEARINGS_RUNNER"] = " ".join(RUN)
    r = run_fpcunit(binary, out / f"{suite}.out", suite=fpc_suite, env=env)
    report_fpcunit(subtests, r, f"{suite} (heaptrc)")
    unfreed = heaptrc_unfreed(heap)
    assert unfreed == 0, f"{suite} (heaptrc): unfreed blocks: {unfreed} (see {heap})"

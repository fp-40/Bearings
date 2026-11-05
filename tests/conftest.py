"""pytest hooks and fixtures of the repository's test runner (see harness.py
for the environment variables and the helpers)."""

from pathlib import Path

import pytest
from harness import ROOT, TARGET


def pytest_addoption(parser):
    parser.addoption("--fpc-suite", default=None,
                     help="run only this fpcunit suite class or Class.Method")


def pytest_collection_modifyitems(config, items):
    """The pybearings tests are part of the fast tier; host-only tests are
    skipped when cross-compiling."""
    python_tests = ROOT / "python" / "tests"
    for item in items:
        if python_tests in Path(str(item.fspath)).parents:
            item.add_marker(pytest.mark.fast)
            item.add_marker(pytest.mark.python)
        if TARGET != "x86_64" and item.get_closest_marker("hostonly"):
            item.add_marker(pytest.mark.skip(reason=f"host-only step (TARGET={TARGET})"))


@pytest.fixture
def fpc_suite(request) -> str | None:
    return request.config.getoption("--fpc-suite")

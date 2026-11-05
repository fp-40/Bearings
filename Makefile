# The test tiers, the benchmark and the release. Every test runs through
# pytest (pytest.ini, tests/*.py, python/tests); the tiers are marks.
#
#   make test           the fast tier (pytest -m fast): the version check,
#                       the Pascal unit suites with heaptrc, a short split
#                       fuzz, the expected-value tests, the hot-path asm
#                       check and the pybearings tests (CI runs this on
#                       every push)
#   make test-full      the full tier (pytest -m full): drd, the worker
#                       stress, the echo under memcheck, the long split fuzz
#                       and the wire conformance gate; needs tools/get-tools.sh
#   make test-autobahn  the Autobahn WebSocket suite (Docker)
#   make benchmark      the throughput gate against hyper (bench/run_gate.sh)
#   make release BUMP=patch|minor|major|X.Y.Z
#                       full and conformance, then one version for Bearings
#                       and pybearings, tag and GitHub release (PyPI);
#                       tools/release.sh
#
# pytest runs in the python/ project environment (uv), which also builds
# libbearings.so for the pybearings tests. Any pytest selection works the
# same way, e.g. `$(PYTEST) -k h1_conn`, `$(PYTEST) -m golden`,
# `$(PYTEST) -m "full and not drd"` (README.md, "Building and testing").

PYTEST = uv run --project python --quiet pytest

.PHONY: test test-pascal test-python test-full test-autobahn benchmark release

test:
	$(PYTEST) -m fast -x -v

test-pascal:
	$(PYTEST) -m "fast and not python" -x -v

test-python:
	$(PYTEST) -m python -x -v

test-full:
	$(PYTEST) -m full -x -v

test-autobahn:
	conformance/autobahn/run.sh

benchmark:
	bench/run_gate.sh

release:
	@[ -n "$(BUMP)" ] || { echo "make release BUMP=patch|minor|major|X.Y.Z"; exit 1; }
	tools/release.sh $(BUMP)

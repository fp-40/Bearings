# The test tiers, the benchmark and the release.
#
#   make test           the fast tier: the version check, the Pascal unit
#                       suites with heaptrc, a short split fuzz, the hot-path
#                       asm check, then the Python tests (CI runs this on
#                       every push)
#   make test-full      the full tier (drd, stress, echo under memcheck,
#                       the long split fuzz) and conformance (the diffs
#                       against httparse and hyper, the wire gate); needs
#                       tools/get-tools.sh and cargo
#   make test-autobahn  the Autobahn WebSocket suite (Docker)
#   make benchmark      the throughput gate against hyper (bench/run_gate.sh)
#   make release BUMP=patch|minor|major|X.Y.Z
#                       full and conformance, then one version for Bearings
#                       and pybearings, tag and GitHub release (PyPI);
#                       tools/release.sh

.PHONY: test test-pascal test-python test-full test-autobahn benchmark release

# Each step runs even when one before it failed (a version mismatch does
# not hide the test results); the target fails at the end if any did.
test:
	@status=0; $(MAKE) test-pascal || status=1; $(MAKE) test-python || status=1; exit $$status

test-pascal:
	@status=0; tools/check-version.sh || status=1; \
	TIER=fast tests/unit/run_all.sh || status=1; exit $$status

# --reinstall-package: the editable install keeps the libbearings.so it
# compiled; this compiles it again from the Pascal sources of the tree
test-python:
	cd python && uv sync --quiet --group dev --reinstall-package pybearings
	$(MAKE) -C python test

test-full:
	TIER=full tests/unit/run_all.sh
	tests/conformance.sh

test-autobahn:
	conformance/autobahn/run.sh

benchmark:
	bench/run_gate.sh

release:
	@[ -n "$(BUMP)" ] || { echo "make release BUMP=patch|minor|major|X.Y.Z"; exit 1; }
	tools/release.sh $(BUMP)

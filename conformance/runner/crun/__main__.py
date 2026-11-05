"""`python3 conformance/runner/crun ...` (the directory) or `python3 -m crun ...`."""

import os
import sys


if __package__ in (None, ""):
    sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    from crun.cli import main
else:
    from .cli import main

sys.exit(main())

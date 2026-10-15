"""Loads libbearings.so with cffi, declared by its own C header."""
from pathlib import Path

from cffi import FFI


HERE = Path(__file__).parent

ffi = FFI()
# cffi parses no preprocessor directive: the header's include guard goes
ffi.cdef(
    "\n".join(
        line
        for line in (HERE / "bearings.h").read_text().splitlines()
        if not line.startswith("#")
    )
)
lib = ffi.dlopen(str(HERE / "libbearings.so"))

OK = 0
CANCELED = 1
BAD_HEADER = -1
BAD_BODY = -1
INVALID = -1
CLIENT_GONE = -2

VERSION = ffi.string(lib.bearings_version()).decode()

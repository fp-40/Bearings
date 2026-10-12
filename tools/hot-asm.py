"""Finds implicit exception frames in hot routines (M3 design 4.4).

FPC 3.2.2 on x86_64-linux gives a routine with managed locals, managed
temporaries or a try block a frame: a call to fpc_pushexceptaddr and
fpc_setjmp on every call (12-20 ns). This script reads the .s files FPC
wrote with -al, cuts them into routines (from `.type NAME,@function` to
`.size NAME`), and reports every routine that matches a pattern and calls
fpc_pushexceptaddr or fpc_setjmp.

Patterns: `Name` (a plain routine, every overload), `Name*` (prefix),
`TType.Method`, `TType.*` (every method of the type). Case-insensitive.
Routines nested in a matched routine are checked too (reported as
`Parent.Nested`), since they run inside it.

Usage: python3 -I tools/hot-asm.py <asm_dir> <pattern> [<pattern> ...]
Exit status 1 if a matched routine has a frame or a pattern matches no
routine (a typo must not pass silently).
"""
import fnmatch
import os
import re
import sys

FRAME_CALLS = ("fpc_pushexceptaddr", "fpc_setjmp")


def routines(path):
    """Yields (mangled_name, body_lines) for every function in an .s file."""
    cur = None
    body = []
    with open(path, encoding="latin-1") as f:
        for line in f:
            m = re.match(r"\s*\.type\s+(\S+),@function", line)
            if m:
                cur = m.group(1)
                body = []
                continue
            if cur is not None:
                if re.match(r"\s*\.size\s+" + re.escape(cur) + r",", line):
                    yield cur, body
                    cur = None
                else:
                    body.append(line)


def readable(mangled):
    """UNIT_$$_NAME$args            -> (None, NAME)
       UNIT$_$TYPE_$__$$_NAME$args  -> (TYPE, NAME)
       UNIT$_$PARENT$crc.._$$_NAME  -> ('PARENT', NAME) marked nested"""
    m = re.match(r"^(?P<unit>[^$]+)\$_\$(?P<owner>[A-Z0-9_]+)_\$__\$\$_(?P<name>[A-Z0-9_]+)", mangled)
    if m:
        return m.group("owner"), m.group("name"), False
    m = re.match(r"^(?P<unit>[^$]+)\$_\$(?P<owner>[A-Z0-9_]+)(\$crc[0-9A-F]+|\$[^_]\S*?)?_\$\$_(?P<name>[A-Z0-9_]+)",
                 mangled)
    if m:
        return m.group("owner"), m.group("name"), True
    m = re.match(r"^(?P<unit>[^$]+)_\$\$_(?P<name>[A-Z0-9_]+)", mangled)
    if m:
        return None, m.group("name"), False
    return None, None, False


def matches(pattern, owner, name, nested):
    p = pattern.upper()
    if nested:
        # a nested routine is checked when its parent routine is
        return fnmatch.fnmatchcase(owner, p) and "." not in p
    if "." in p:
        po, pn = p.split(".", 1)
        return owner is not None and fnmatch.fnmatchcase(owner, po) and fnmatch.fnmatchcase(name, pn)
    return owner is None and fnmatch.fnmatchcase(name, p)


def main(asm_dir, patterns):
    found = {p: [] for p in patterns}
    bad = []
    for fn in sorted(os.listdir(asm_dir)):
        if not fn.endswith(".s"):
            continue
        for mangled, body in routines(os.path.join(asm_dir, fn)):
            owner, name, nested = readable(mangled)
            if name is None:
                continue
            for p in patterns:
                if matches(p, owner, name, nested):
                    label = ("%s.%s" % (owner, name)) if owner else name
                    frame = any(c in line for line in body for c in FRAME_CALLS)
                    found[p].append((label, frame, mangled))
                    if frame:
                        bad.append((p, label, mangled))
    status = 0
    for p in patterns:
        hits = found[p]
        if not hits:
            print("MISSING  %-34s no routine matches" % p)
            status = 1
            continue
        nf = sum(1 for _, f, _ in hits if f)
        print("%-8s %-34s %d routine(s)%s" % ("FRAME" if nf else "ok", p, len(hits),
                                              (", %d with a frame" % nf) if nf else ""))
    for p, label, mangled in bad:
        print("  frame in %s  (%s)" % (label, mangled))
        status = 1
    return status


if __name__ == "__main__":
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(2)
    sys.exit(main(sys.argv[1], sys.argv[2:]))

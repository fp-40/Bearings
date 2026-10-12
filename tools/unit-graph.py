"""Interface uses graph of the bearings units (the layer rules of README.md).

Reads the `uses` clause of each unit's interface section (implementation
uses cannot create a circular unit reference in FPC), prints each unit with
its project dependencies, and checks the graph with a topological sort.
Exit status 1 on a cycle.

Usage: python3 -I tools/unit-graph.py <dir> [<dir> ...]
"""
import os
import re
import sys


def strip_comments(src):
    src = re.sub(r"\{[^}]*\}", " ", src)
    src = re.sub(r"\(\*.*?\*\)", " ", src, flags=re.S)
    src = re.sub(r"//[^\n]*", " ", src)
    return src


def interface_uses(path):
    src = strip_comments(open(path, encoding="latin-1").read())
    m = re.search(r"\binterface\b(.*?)\bimplementation\b", src, flags=re.S | re.I)
    if not m:
        return []
    part = m.group(1)
    u = re.search(r"\buses\b(.*?);", part, flags=re.S | re.I)
    if not u:
        return []
    names = []
    for item in u.group(1).split(","):
        item = re.sub(r"\s+in\s+'.*'", "", item.strip(), flags=re.I)
        if item:
            names.append(item.strip().lower())
    return names


def main(dirs):
    units = {}
    for d in dirs:
        for root, _, files in os.walk(d):
            for f in files:
                if f.endswith(".pas"):
                    units[f[:-4].lower()] = os.path.join(root, f)
    graph = {}
    for name, path in sorted(units.items()):
        graph[name] = [u for u in interface_uses(path) if u in units]
    for name in sorted(graph):
        print("  %-26s -> %s" % (name, ", ".join(graph[name]) or "(none)"))
    # Kahn's algorithm
    indeg = {n: 0 for n in graph}
    for n, deps in graph.items():
        for d in deps:
            indeg[n] += 1
    users = {n: [] for n in graph}
    for n, deps in graph.items():
        for d in deps:
            users[d].append(n)
    ready = sorted(n for n, k in indeg.items() if k == 0)
    order = []
    while ready:
        n = ready.pop(0)
        order.append(n)
        for u in sorted(users[n]):
            indeg[u] -= 1
            if indeg[u] == 0:
                ready.append(u)
    if len(order) != len(graph):
        print("CYCLE among: " + ", ".join(sorted(n for n in graph if n not in order)))
        return 1
    print("interface uses graph: %d units, acyclic; one valid order:" % len(order))
    print("  " + " < ".join(order))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

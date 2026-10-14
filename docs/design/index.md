# The design of Bearings

These documents explains how bearings is built and why: the decisions, the
invariants a contributor must respect, and the places where it behaves
differently from what an HTTP library usually does. It names the units,
types and routines that implement each part; the header comment of each unit
under `src/` describes that unit in more detail, and the [API guide](../api/index.md) says how a
program uses the library. Where this document and the code disagree, the code
is right.

Contents:

1. [Purpose and scope](purpose.md)
2. [Threading model](threading.md)
3. [Readiness and I/O](io.md)
4. [Timers and the clock](timers.md)
5. [Connection state machine and the request path](state-machine.md)
6. [The exchange and the service API](exchange.md)
7. [Memory](memory.md)
8. [Header validation](header.md)
9. [Verification](verification.md)
10. [Deviations register](deviations.md)
11. [Risks and known limits](limits.md)
12. [ARM64](arm64.md)

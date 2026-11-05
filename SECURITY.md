# Security policy

## Supported versions

Security fixes are released for the latest minor version only. A fix may
change behaviour in a patch release when the old behaviour is the
vulnerability; the changelog entry says what changed.

## Reporting a vulnerability

Report it in private, through GitHub: "Report a vulnerability" in the
repository's Security tab, or
<https://github.com/fp-40/Bearings/security/advisories/new>.

Do not open a public issue or a pull request for it.

Please include:

- the version (`BEARINGS_VERSION`, `bearings_version()` or
  `bearings.VERSION`), the CPU architecture, and whether the program is
  Pascal, C or Python;
- the server's configuration, and what is in front of it (which proxy or
  load balancer, if any);
- the exact bytes the client sends, or a script that sends them;
- what happened, and what you expected.

## What is a vulnerability here

For example:

- a request that Bearings and a proxy in front of it can read as ending at
  different places (request smuggling);
- memory read or written outside its bounds;
- a crash, or an event loop that stops serving its connections, caused by
  what a client sends;
- a client that makes the server hold memory or connections without a
  bound;
- a WebSocket handshake that passes the Origin check when it should not.

These are decisions of the design, not vulnerabilities: there is no TLS
and no limit per client address, because both belong to the proxy in
front of the server
([`docs/design/limits.md`](docs/design/limits.md),
[`docs/design/deviations.md`](docs/design/deviations.md)).

## What happens next

The report is answered in the advisory's own thread. A confirmed
vulnerability is fixed in a new release, its changelog entry describes
it, and the advisory is published, naming the reporter unless they ask
not to be named.

# Changelog

All notable changes to Bearings are documented in this file.

# Unreleased

Two request smuggling fixes, found by checking Bearings against the CVEs of the last five years.

- **A bare LF in the trailer section of a chunked request body is refused.** Before, after `0` CRLF LF, or after a trailer line that ended with LF, the decoder read on to the next CRLF CRLF while the trailer parser stopped at the LF, so the bytes in between were dropped without an error. Behind a proxy that ends the body at the bare LF (RFC 9112 2.2 lets a recipient take a bare LF as a line end), the next request on the connection was swallowed and the proxy's responses were matched to the wrong requests (the class of CVE-2025-43859). The decoder now fails the body with `deTrailerBareLf` ("Invalid trailer line: LF without CR"), and the connection closes after the response. hyper behaves as Bearings did before.
- **An HTTP/1.1 request without `Host`, or any request with two `Host` lines, gets 400** (RFC 9112 3.2). With two lines, the server and a proxy could each use a different one. The handler is not called. HTTP/1.0 requests may still omit `Host`. The new parse error is `h1peHeaderHost` ("missing or duplicate host header"). Clients that send HTTP/1.1 without `Host` (hand-written test scripts, some health checks) must add it.

- **`cmWithoutShutdown` is gone**, with `TConnParts` and `TConnObserver.OnParts`. The mode handed the socket and the unread bytes back to the observer when the connection ended; it existed for the tests ported from hyper's `without_shutdown()` API, and no program used it. `TH1ConnMode` is `cmPlain` or `cmWithUpgrades`. The conformance cases that only exercised the hand-off are gone (`upgrades` and `http_connect`, whose upgrades `upgrades_new` and `http_connect_new` cover with `with_upgrades`, and the extra case `without_shutdown_parse_error`); the three header-timeout cases that used the mode run in `plain` mode. (A bug of that mode, the automatic 400 dropped when the socket did not take it at once, was found and fixed on the way; the fix went with the mode.)

Development:

- The unit tests and the conformance cases send `Host` in their HTTP/1.1 requests. Tests that counted header lines, or compared head lengths, count the `Host` line.
- `python/tests/test_raw.py` sends the smuggling attempts and the requests with a missing or repeated `Host` to a running server.
- **The differential tests against hyper and httparse are replaced by expected-value tests.** `tests/unit/test_golden.sh` (in `make test`) runs the parser, the request head rules and the body decoder over frozen cases and compares each result with `tests/golden`. The values were taken from httparse 1.10.1 and hyper v1.12.0 on 2026-11-04, with the two rules above applied after every difference was checked. `UPDATE=1` lists the lines that change and rewrites the files. The cases are fewer than the differential tests generated (role 41 000 instead of 200 000, decode 10 000 instead of 100 000, 50 000 random parser inputs instead of 200 000), so that the files stay at 2.8 MB.
- Removed with them: `tests/unit/test_{parser,role,codec}_diff.sh` and their Rust crates, `test_parser_extra_check.py`, `test_parser_gen.py`, hyper's reference server and the differential stream fuzz (`conformance/fuzz-diff`). The conformance gate already checked the cases in assertion mode; it no longer runs the reference server for a diff report, and `gate_worker.sh` no longer runs the worker probe against it. hyper stays only in `bench/`, for the benchmark.
- **The conformance case runner is a Pascal program** (`conformance/runner/`, built by `conformance/runner/build.sh`), and so is the dumb server; the Cargo workspace is gone, and `make test-full` no longer needs cargo. The runner uses no Bearings unit. It reads JSON with fpjson; a `\u0000` escape is refused (fpjson drops it: a NUL byte is a `{"hex": "00"}` part). Before the Rust runner was removed, the Pascal one gave the same outcome, and the same failing step for failing cases, on every case against `beconf` (inline, worker executor, four loops) and against the dumb server.
- **The cases have no regular expressions.** The 23 `regex` / `not_regex` assertions (Rust's `regex::bytes` dialect) were replaced by byte assertions that state what each one checked, and by a new `utf8` assertion (11 of them checked that a response is valid UTF-8). `runner selftest` checks the runner's own parts; each rewritten assertion was checked to fail when its expected value is wrong. The `diff` mode (two servers' transcripts) and `$regex` event patterns are gone.
- The split fuzz corpus no longer adds httparse's test inputs when their source is in the cargo registry, so it is the same on every machine.

# 0.4.1

- **Raising the descriptor limit is now a choice: `TServerConfig.RaiseFdLimit`.** 0.4.0 raised the process's soft limit on open file descriptors to the hard limit at every `Start`. That was wrong for a library: the limit belongs to the whole process, `select()` cannot take a descriptor >= 1024 (the reason systemd leaves the soft limit there), and child processes inherit the raised limit. `ProductionServerConfig` and `BenchmarkServerConfig` set the option; `Default(TServerConfig)` does not.
- **C API and Python**: `bearings_config_t` has `raise_fd_limit` after `metrics`, and `Server` takes `raise_fd_limit=False`; both are off by default because the host program owns the process. Programs built against the 0.4.0 header must be rebuilt.
- **test_server**: the load client of the stop-under-load tests retries a connect that ends in `ECONNRESET`, the result Linux gives when the closing listener resets a connection before `connect` returns; the test failed once in CI for that.

# 0.4.0

The access log was reworked. Its lines have the keys of structlog's lines, so a log collector reads the server's lines and a Python application's the same way.

- **The JSON lines use structlog's keys**: `timestamp` (RFC 3339 UTC, microseconds), `level`, `logger` (`"bearings"`), `event` (the method and the path, `"GET /x"`), `request_id`, `method`, `path`, `query`, `status`, `size`, `duration`, `client`, `user_agent`, `referer`. They replace the OpenTelemetry names (`time`, `client.address`, `http.request.method`, `url.path`, `url.query`, `http.response.status_code`, `http.response.body.size`, `http.server.request.duration`, `http.response.header.x-request-id`, `user_agent.original`). `network.protocol.version` is gone: the server only speaks HTTP/1.x.
- **The JSON lines have the response's X-Request-ID**, as `request_id`, when the response has the header. An application or a proxy behind the server sets it to find the request in its own logs; the key is absent when the header is.
- **Each line has a level, and a minimum level filters the log.** A line has the level of its status: `error` for a 4xx or a 5xx, `info` for the others. `AccessLog.MinLevel` (`access_log_level` in the C API and in Python) drops the lines below it, so `warning` or `error` keeps only the requests that failed. The default keeps every line.
- **A console format replaces the Combined Log Format.** `alfConsole` (`"console"` in Python, `BEARINGS_ACCESS_LOG_CONSOLE` in C) writes one short line for people: `02:25:45.698455Z [info]  200 GET /projects/1  (153.186ms; 15.69 KB)`. `Colors` (`access_log_colors`) gives the level structlog's ANSI color; Python turns colors on by default when stdout is a terminal. `alfCombined`, `"combined"` and `BEARINGS_ACCESS_LOG_COMBINED` are gone.
- **User-Agent and Referer are written only when asked.** `UserAgent` and the new `Referer` (`access_log_user_agent`, `access_log_referer`) add the headers to the lines in both formats; both are off by default. The Combined format wrote them always.
- **C API**: `bearings_config_t` has four new fields after `access_log`: `access_log_level`, `access_log_user_agent`, `access_log_referer` and `access_log_colors`. Programs built against the old header must be rebuilt.
- **`Start` raises the soft limit on open file descriptors to the hard limit** (`RaiseFdLimit` in `bearings.rt.net`). Every connection is a descriptor, and the soft limit is often 1024 where the hard limit is 524288 (systemd's defaults); a server that reached it could accept nothing more and paused its listeners. Only `LimitNOFILE=` or `ulimit -Hn` bounds the connections now.
- **Pascal API**: `TAccessLogConfig` has `Referer`, `Colors` and `MinLevel: TLogLevel`. `bearings.server.accesslog` adds `TLogLevel`, `LOG_LEVEL_NAMES` and `AccessLevel`; `TAccessLog.Create` and `FormatAccessLine` take `Colors` where they took `UserAgent`; `TAccessRecord` lost `Version`.

Development:

- **CI runs on Node 24 actions**: `actions/checkout` v7, `upload-artifact` v7, `download-artifact` v8 and `setup-uv` v10.3.0. The v4/v5 ones ran on Node 20, which GitHub deprecated.
- **The editable Python install rebuilds `libbearings.so` when the Pascal sources change.** `python/pyproject.toml` lists them, and the build hook, as uv cache keys, so `make test-python` no longer forces a reinstall. The Python tests run without `-x`, so one failure no longer hides the results of the others.

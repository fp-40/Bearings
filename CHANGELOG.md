# Changelog

All notable changes to Bearings are documented in this file.

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

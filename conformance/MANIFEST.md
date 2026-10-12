# M1 manifest: hyper HTTP/1 tests to conformance cases

Status of the 105 hyper v1.12.0 tests (commit `7f67699ce32d717081deb7018b4da7d679277ac0`) that
milestone M1 ports. Each test maps to exactly one case in `cases/h1/`. The case id is
`<file stem>::<case name>`, as printed by `runner run`.

## Summary

| status | count |
|---|---|
| passing (against `reference-server`) | 104 |
| pending | 1 |
| excluded | 0 |
| failing | 0 |
| missing (no case) | 0 |

Missing: none. All 105 `(name, source)` pairs in the M1 list match a case's `name` and `source`
exactly. Each `source` line in the hyper checkout is the named test function. No case falls outside
the list.

## How this was verified (2026-10-07)

All commands run from `conformance/` after `cargo build --release`.

1. **Determinism.** `target/release/runner run cases/h1` was run 3 times in a row. Each run gave
   `SUMMARY passed=104 failed=0 pending=1 total=105`, and every case had the same outcome in all
   3 runs (column "3 runs"). 4 further full runs at the same time (load check) gave the same
   summary. No case was flaky, so no timing was changed for flakiness.
2. **Diff stability.** `target/release/runner diff --a target/release/reference-server --b
   target/release/reference-server cases/h1` gave `same=104 different=0 pending=1 invalid=0` in
   4 runs (3 before the `http1_allow_half_close` change below, 1 after it). As a check that diff
   mode detects differences, reference vs `dumb-server --events` gave `different=104`.
3. **Mutation check (weak assertions).** `dumb-server/` is a workspace binary that implements
   the process protocol (SPEC section 3: `LISTENING`, control acks, `exit`) and ignores the
   server spec. For each `\r\n\r\n` it receives, it writes `HTTP/1.1 200 OK\r\ncontent-length:
   0\r\n\r\n`, and it closes on client EOF. By default it emits no events except control acks.
   With `--events` it also emits generic `conn_open`, `request` (fields split naively from the
   head) and `conn_close` outcome `ok` events. That mode shows which cases are caught only by
   their wire assertions and which only by their event assertions.

   ```sh
   target/release/runner run --server target/release/dumb-server cases/h1
   target/release/runner run --server 'target/release/dumb-server --events' cases/h1
   ```

   Final results: plain mode 1 passed / 103 failed; `--events` mode 4 passed / 100 failed
   (column "dumb / dumb --events").

### Cases that pass against the dumb server

Before the fix, 5 cases passed in `--events` mode (1 in plain mode). Each was compared with the
hyper test:

| case | dumb result | judgement |
|---|---|---|
| `chunk3::http1_allow_half_close` | passed `--events` | **Strengthened.** hyper asserts only that the response starts with `HTTP/1.1 200 OK\r\n` and that `serve_connection` returns Ok. In hyper the service's 500 ms sleep is test code, so the client's FIN always reaches the server while the request is in progress, which is the situation `half_close(true)` is about. In the port the sleep is the server's `delay_ms`, which the dumb server ignores: it answered before the FIN mattered and passed. The read step now has a timing window of 425..1000 ms after connect (SPEC 13 port decision, recorded in the case notes). The dumb server now fails with `completed 0 ms after connect, expected >= 425 ms`. The reference server passed 5 of 5 single runs and all full runs after the change. |
| `chunk2::pipeline_disabled` | passes both modes | **Justified.** hyper asserts only that the first `read()` returns n != 0 and that the conditional second `read()` does not return `Ok(0)`. It does not check the response bytes (the test comment calls it "wishy-washy"). Two 200 responses to two pipelined requests satisfy exactly that. Response content for pipelined requests is covered by `pipeline_enabled`, which the dumb server fails. Adding byte checks here would assert more than hyper does (SPEC 14). |
| `chunk3::upgrades_ignored` | passes `--events` | **Justified.** hyper asserts that the service sees `upgrade: yolo` and that both responses are status 200. Ignoring the upgrade and answering 200 is the behavior under test. Fails in plain mode (no `request` / `conn_close` events). |
| `chunk5::conn_reads_partial_request_head` | passes `--events` | **Justified.** The unit test asserts only Pending after `GET / HTTP` and Ready after the rest. Buffering until `\r\n\r\n`, writing nothing, keeping the connection open and then answering is that behavior. The case already checks the parsed head fields in the `request` event. |
| `chunk5::conn_accepts_eof_when_idle` | passes `--events` | **Justified.** The unit test asserts that EOF while idle ends the connection without error (`Ready(None)`). Closing on EOF without writing, with outcome `ok`, is that behavior. |

### Cases that fail the dumb server only on events

These 20 cases fail in `--events` mode only on `expect_events`, so a fixed 200 satisfies their
wire steps. For `get_1` this holds only for the via-proxy run; the direct run fails a wire step.
The other integration.rs tests listed here are affected in both runs. Each of those events encodes a hyper assertion, not a port
addition: `server.body()` / `server.body_err()` (`get_should_ignore_body`, `get_with_body`,
`post_with_content_length_body`, `post_with_chunked_body`, `post_with_chunked_overflow`), the
t! macro service's `assert_eq!(body, sbody, "client body")` (tests/support/mod.rs:377-379;
`get_1 [run3 h1 via proxy]`, `get_implicit_path`, `get_allow_te_trailers_header`, `post_outgoing_length`,
`post_chunked`, `get_2`, direct and via proxy), the service panic "response future should have
been dropped" (`disconnect_after_reading_request_before_responding`), `body ==
DecodedLength::ZERO` (`conn_reads_request_head`), `is_incomplete_message()`
(`conn_rejects_eof_during_partial_head`) and the 5-byte body read
(`conn_reads_body_and_reports_end`). No change needed.

All other cases fail in at least one wire step against the dumb server.

## Pending and excluded

- **Pending (1):** `chunk1::response_body_lengths::chunked_response_trumps_length`. The test is
  `#[ignore]` upstream (tests/server.rs:258-262: "This used to be the case, but providing this
  functionality got in the way of performance."). The case encodes the intended assertions
  (chunked response, content-length stripped). With `pending` removed, hyper v1.12.0 writes 0
  bytes and closes; `conn_close` outcome `user`, detail `user sent unexpected header` (role.rs
  encode_headers). It stays pending until the expected behavior is decided for bearings.
- **Excluded (0).** The integration.rs `[run1 h1 direct]` and `[run3 h1 via proxy]` runs are both
  ported. The HTTP/2 runs of integration.rs are not in the M1 list.

## Per-test table

Columns: hyper test name, hyper source, case id, status, the outcome in each of the 3 sequential
reference runs, the outcome against `dumb-server` / `dumb-server --events`, and the reference-vs-
reference diff result.

| hyper test | source | case id | status | 3 runs | dumb / dumb --events | self-diff |
|---|---|---|---|---|---|---|
| `get_should_ignore_body` | `tests/server.rs:38` | `chunk1::get_should_ignore_body` | passing | PASS/PASS/PASS | FAIL / FAIL | SAME |
| `get_with_body` | `tests/server.rs:59` | `chunk1::get_with_body` | passing | PASS/PASS/PASS | FAIL / FAIL | SAME |
| `response_body_lengths::fixed_response_known` | `tests/server.rs:181` | `chunk1::response_body_lengths::fixed_response_known` | passing | PASS/PASS/PASS | FAIL / FAIL | SAME |
| `response_body_lengths::fixed_response_unknown` | `tests/server.rs:192` | `chunk1::response_body_lengths::fixed_response_unknown` | passing | PASS/PASS/PASS | FAIL / FAIL | SAME |
| `response_body_lengths::fixed_response_known_empty` | `tests/server.rs:203` | `chunk1::response_body_lengths::fixed_response_known_empty` | passing | PASS/PASS/PASS | FAIL / FAIL | SAME |
| `response_body_lengths::chunked_response_known` | `tests/server.rs:214` | `chunk1::response_body_lengths::chunked_response_known` | passing | PASS/PASS/PASS | FAIL / FAIL | SAME |
| `response_body_lengths::chunked_response_known_empty` | `tests/server.rs:226` | `chunk1::response_body_lengths::chunked_response_known_empty` | passing | PASS/PASS/PASS | FAIL / FAIL | SAME |
| `response_body_lengths::chunked_response_unknown` | `tests/server.rs:237` | `chunk1::response_body_lengths::chunked_response_unknown` | passing | PASS/PASS/PASS | FAIL / FAIL | SAME |
| `response_body_lengths::te_response_adds_chunked` | `tests/server.rs:248` | `chunk1::response_body_lengths::te_response_adds_chunked` | passing | PASS/PASS/PASS | FAIL / FAIL | SAME |
| `response_body_lengths::chunked_response_trumps_length` | `tests/server.rs:263` | `chunk1::response_body_lengths::chunked_response_trumps_length` | pending: #[ignore] upstream (tests/server.rs:258-262): 'This used to be the case, but providing this functionality got in the way of performance.' hyper v1.12.0 does not pass it. | PEND/PEND/PEND | PEND / PEND | PEND |
| `response_body_lengths::auto_response_with_unknown_length` | `tests/server.rs:278` | `chunk1::response_body_lengths::auto_response_with_unknown_length` | passing | PASS/PASS/PASS | FAIL / FAIL | SAME |
| `response_body_lengths::auto_response_with_known_length` | `tests/server.rs:290` | `chunk1::response_body_lengths::auto_response_with_known_length` | passing | PASS/PASS/PASS | FAIL / FAIL | SAME |
| `response_body_lengths::auto_response_known_empty` | `tests/server.rs:302` | `chunk1::response_body_lengths::auto_response_known_empty` | passing | PASS/PASS/PASS | FAIL / FAIL | SAME |
| `response_body_lengths::http10_auto_response_with_unknown_length` | `tests/server.rs:314` | `chunk1::response_body_lengths::http10_auto_response_with_unknown_length` | passing | PASS/PASS/PASS | FAIL / FAIL | SAME |
| `response_body_lengths::http10_chunked_response` | `tests/server.rs:326` | `chunk1::response_body_lengths::http10_chunked_response` | passing | PASS/PASS/PASS | FAIL / FAIL | SAME |
| `get_response_custom_reason_phrase` | `tests/server.rs:391` | `chunk1::get_response_custom_reason_phrase` | passing | PASS/PASS/PASS | FAIL / FAIL | SAME |
| `get_chunked_response_with_ka` | `tests/server.rs:418` | `chunk1::get_chunked_response_with_ka` | passing | PASS/PASS/PASS | FAIL / FAIL | SAME |
| `post_with_content_length_body` | `tests/server.rs:460` | `chunk1::post_with_content_length_body` | passing | PASS/PASS/PASS | FAIL / FAIL | SAME |
| `post_with_invalid_prefix_content_length` | `tests/server.rs:478` | `chunk1::post_with_invalid_prefix_content_length` | passing | PASS/PASS/PASS | FAIL / FAIL | SAME |
| `post_with_chunked_body` | `tests/server.rs:498` | `chunk2::post_with_chunked_body` | passing | PASS/PASS/PASS | FAIL / FAIL | SAME |
| `post_with_chunked_overflow` | `tests/server.rs:524` | `chunk2::post_with_chunked_overflow` | passing | PASS/PASS/PASS | FAIL / FAIL | SAME |
| `post_with_incomplete_body` | `tests/server.rs:554` | `chunk2::post_with_incomplete_body` | passing | PASS/PASS/PASS | FAIL / FAIL | SAME |
| `post_with_chunked_missing_final_digit` | `tests/server.rs:576` | `chunk2::post_with_chunked_missing_final_digit` | passing | PASS/PASS/PASS | FAIL / FAIL | SAME |
| `head_response_can_send_content_length` | `tests/server.rs:599` | `chunk2::head_response_can_send_content_length` | passing | PASS/PASS/PASS | FAIL / FAIL | SAME |
| `head_response_doesnt_send_body` | `tests/server.rs:628` | `chunk2::head_response_doesnt_send_body` | passing | PASS/PASS/PASS | FAIL / FAIL | SAME |
| `response_does_not_set_chunked_if_body_not_allowed` | `tests/server.rs:658` | `chunk2::response_does_not_set_chunked_if_body_not_allowed` | passing | PASS/PASS/PASS | FAIL / FAIL | SAME |
| `keep_alive` | `tests/server.rs:691` | `chunk2::keep_alive` | passing | PASS/PASS/PASS | FAIL / FAIL | SAME |
| `http_10_keep_alive` | `tests/server.rs:731` | `chunk2::http_10_keep_alive` | passing | PASS/PASS/PASS | FAIL / FAIL | SAME |
| `http_10_close_on_no_ka` | `tests/server.rs:780` | `chunk2::http_10_close_on_no_ka` | passing | PASS/PASS/PASS | FAIL / FAIL | SAME |
| `disable_keep_alive` | `tests/server.rs:818` | `chunk2::disable_keep_alive` | passing | PASS/PASS/PASS | FAIL / FAIL | SAME |
| `header_connection_close` | `tests/server.rs:844` | `chunk2::header_connection_close` | passing | PASS/PASS/PASS | FAIL / FAIL | SAME |
| `expect_continue_sends_100` | `tests/server.rs:877` | `chunk2::expect_continue_sends_100` | passing | PASS/PASS/PASS | FAIL / FAIL | SAME |
| `expect_continue_accepts_upper_cased_expectation` | `tests/server.rs:910` | `chunk2::expect_continue_accepts_upper_cased_expectation` | passing | PASS/PASS/PASS | FAIL / FAIL | SAME |
| `expect_continue_but_http_10_is_ignored` | `tests/server.rs:943` | `chunk2::expect_continue_but_http_10_is_ignored` | passing | PASS/PASS/PASS | FAIL / FAIL | SAME |
| `expect_continue_but_no_body_is_ignored` | `tests/server.rs:976` | `chunk2::expect_continue_but_no_body_is_ignored` | passing | PASS/PASS/PASS | FAIL / FAIL | SAME |
| `expect_continue_waits_for_body_poll` | `tests/server.rs:1023` | `chunk2::expect_continue_waits_for_body_poll` | passing | PASS/PASS/PASS | FAIL / FAIL | SAME |
| `pipeline_disabled` | `tests/server.rs:1072` | `chunk2::pipeline_disabled` | passing | PASS/PASS/PASS | PASS / PASS | SAME |
| `pipeline_enabled` | `tests/server.rs:1116` | `chunk2::pipeline_enabled` | passing | PASS/PASS/PASS | FAIL / FAIL | SAME |
| `http_10_request_receives_http_10_response` | `tests/server.rs:1169` | `chunk3::http_10_request_receives_http_10_response` | passing | PASS/PASS/PASS | FAIL / FAIL | SAME |
| `http_11_uri_too_long` | `tests/server.rs:1189` | `chunk3::http_11_uri_too_long` | passing | PASS/PASS/PASS | FAIL / FAIL | SAME |
| `disable_keep_alive_mid_request` | `tests/server.rs:1206` | `chunk3::disable_keep_alive_mid_request` | passing | PASS/PASS/PASS | FAIL / FAIL | SAME |
| `disable_keep_alive_post_request` | `tests/server.rs:1260` | `chunk3::disable_keep_alive_post_request` | passing | PASS/PASS/PASS | FAIL / FAIL | SAME |
| `http1_allow_half_close` | `tests/server.rs:1403` | `chunk3::http1_allow_half_close` | passing | PASS/PASS/PASS | FAIL / FAIL | SAME |
| `disconnect_after_reading_request_before_responding` | `tests/server.rs:1437` | `chunk3::disconnect_after_reading_request_before_responding` | passing | PASS/PASS/PASS | FAIL / FAIL | SAME |
| `returning_1xx_response_is_error` | `tests/server.rs:1464` | `chunk3::returning_1xx_response_is_error` | passing | PASS/PASS/PASS | FAIL / FAIL | SAME |
| `header_name_too_long` | `tests/server.rs:1496` | `chunk3::header_name_too_long` | passing | PASS/PASS/PASS | FAIL / FAIL | SAME |
| `header_read_timeout_slow_writes` | `tests/server.rs:1513` | `chunk3::header_read_timeout_slow_writes` | passing | PASS/PASS/PASS | FAIL / FAIL | SAME |
| `header_read_timeout_starts_immediately` | `tests/server.rs:1560` | `chunk3::header_read_timeout_starts_immediately` | passing | PASS/PASS/PASS | FAIL / FAIL | SAME |
| `header_read_timeout_slow_writes_multiple_requests` | `tests/server.rs:1581` | `chunk3::header_read_timeout_slow_writes_multiple_requests` | passing | PASS/PASS/PASS | FAIL / FAIL | SAME |
| `header_read_timeout_as_idle_timeout` | `tests/server.rs:1657` | `chunk3::header_read_timeout_as_idle_timeout` | passing | PASS/PASS/PASS | FAIL / FAIL | SAME |
| `upgrades` | `tests/server.rs:1701` | `chunk3::upgrades` | passing | PASS/PASS/PASS | FAIL / FAIL | SAME |
| `http_connect` | `tests/server.rs:1757` | `chunk3::http_connect` | passing | PASS/PASS/PASS | FAIL / FAIL | SAME |
| `upgrades_new` | `tests/server.rs:1810` | `chunk3::upgrades_new` | passing | PASS/PASS/PASS | FAIL / FAIL | SAME |
| `upgrades_ignored` | `tests/server.rs:1879` | `chunk3::upgrades_ignored` | passing | PASS/PASS/PASS | FAIL / PASS | SAME |
| `http_connect_new` | `tests/server.rs:1922` | `chunk3::http_connect_new` | passing | PASS/PASS/PASS | FAIL / FAIL | SAME |
| `parse_errors_send_4xx_response` | `tests/server.rs:2669` | `chunk3::parse_errors_send_4xx_response` | passing | PASS/PASS/PASS | FAIL / FAIL | SAME |
| `illegal_request_length_returns_400_response` | `tests/server.rs:2691` | `chunk3::illegal_request_length_returns_400_response` | passing | PASS/PASS/PASS | FAIL / FAIL | SAME |
| `max_buf_size` | `tests/server.rs:2730` | `chunk4::max_buf_size` | passing | PASS/PASS/PASS | FAIL / FAIL | SAME |
| `max_buf_size_split_header_boundary` | `tests/server.rs:2757` | `chunk4::max_buf_size_split_header_boundary` | passing | PASS/PASS/PASS | FAIL / FAIL | SAME |
| `max_header_size_exceeded` | `tests/server.rs:2789` | `chunk4::max_header_size_exceeded` | passing | PASS/PASS/PASS | FAIL / FAIL | SAME |
| `max_header_size_accepted` | `tests/server.rs:2818` | `chunk4::max_header_size_accepted` | passing | PASS/PASS/PASS | FAIL / FAIL | SAME |
| `max_header_size_with_large_max_buf_size` | `tests/server.rs:2845` | `chunk4::max_header_size_with_large_max_buf_size` | passing | PASS/PASS/PASS | FAIL / FAIL | SAME |
| `graceful_shutdown_before_first_request_no_block` | `tests/server.rs:2876` | `chunk4::graceful_shutdown_before_first_request_no_block` | passing | PASS/PASS/PASS | FAIL / FAIL | SAME |
| `streaming_body` | `tests/server.rs:2901` | `chunk4::streaming_body` | passing | PASS/PASS/PASS | FAIL / FAIL | SAME |
| `http1_only` | `tests/server.rs:2943` | `chunk4::http1_only` | passing | PASS/PASS/PASS | FAIL / FAIL | SAME |
| `skips_content_length_for_304_responses` | `tests/server.rs:3019` | `chunk4::skips_content_length_for_304_responses` | passing | PASS/PASS/PASS | FAIL / FAIL | SAME |
| `skips_content_length_and_body_for_304_responses` | `tests/server.rs:3042` | `chunk4::skips_content_length_and_body_for_304_responses` | passing | PASS/PASS/PASS | FAIL / FAIL | SAME |
| `no_implicit_zero_content_length_for_head_responses` | `tests/server.rs:3071` | `chunk4::no_implicit_zero_content_length_for_head_responses` | passing | PASS/PASS/PASS | FAIL / FAIL | SAME |
| `http1_trailer_send_fields` | `tests/server.rs:3293` | `chunk4::http1_trailer_send_fields` | passing | PASS/PASS/PASS | FAIL / FAIL | SAME |
| `http1_trailer_send_fields_titlecase` | `tests/server.rs:3338` | `chunk4::http1_trailer_send_fields_titlecase` | passing | PASS/PASS/PASS | FAIL / FAIL | SAME |
| `http1_trailer_fields_not_allowed` | `tests/server.rs:3383` | `chunk4::http1_trailer_fields_not_allowed` | passing | PASS/PASS/PASS | FAIL / FAIL | SAME |
| `http1_trailer_fields_allowed_with_comma_separated_te` | `tests/server.rs:3426` | `chunk4::http1_trailer_fields_allowed_with_comma_separated_te` | passing | PASS/PASS/PASS | FAIL / FAIL | SAME |
| `http1_trailer_fields_allowed_with_multiple_te_headers` | `tests/server.rs:3462` | `chunk4::http1_trailer_fields_allowed_with_multiple_te_headers` | passing | PASS/PASS/PASS | FAIL / FAIL | SAME |
| `http1_trailer_recv_keep_alive` | `tests/server.rs:3528` | `chunk4::http1_trailer_recv_keep_alive` | passing | PASS/PASS/PASS | FAIL / FAIL | SAME |
| `get_1 [run1 h1 direct]` | `tests/integration.rs:6` | `chunk5::get_1 [run1 h1 direct]` | passing | PASS/PASS/PASS | FAIL / FAIL | SAME |
| `get_1 [run3 h1 via proxy]` | `tests/integration.rs:6` | `chunk5::get_1 [run3 h1 via proxy]` | passing | PASS/PASS/PASS | FAIL / FAIL | SAME |
| `get_implicit_path [run1 h1 direct]` | `tests/integration.rs:26` | `chunk5::get_implicit_path [run1 h1 direct]` | passing | PASS/PASS/PASS | FAIL / FAIL | SAME |
| `get_implicit_path [run3 h1 via proxy]` | `tests/integration.rs:26` | `chunk5::get_implicit_path [run3 h1 via proxy]` | passing | PASS/PASS/PASS | FAIL / FAIL | SAME |
| `date_isnt_overwritten [run1 h1 direct]` | `tests/integration.rs:43` | `chunk5::date_isnt_overwritten [run1 h1 direct]` | passing | PASS/PASS/PASS | FAIL / FAIL | SAME |
| `date_isnt_overwritten [run3 h1 via proxy]` | `tests/integration.rs:43` | `chunk5::date_isnt_overwritten [run3 h1 via proxy]` | passing | PASS/PASS/PASS | FAIL / FAIL | SAME |
| `get_body [run1 h1 direct]` | `tests/integration.rs:64` | `chunk5::get_body [run1 h1 direct]` | passing | PASS/PASS/PASS | FAIL / FAIL | SAME |
| `get_body [run3 h1 via proxy]` | `tests/integration.rs:64` | `chunk5::get_body [run3 h1 via proxy]` | passing | PASS/PASS/PASS | FAIL / FAIL | SAME |
| `get_body_2_keeps_alive [run1 h1 direct]` | `tests/integration.rs:89` | `chunk5::get_body_2_keeps_alive [run1 h1 direct]` | passing | PASS/PASS/PASS | FAIL / FAIL | SAME |
| `get_body_2_keeps_alive [run3 h1 via proxy]` | `tests/integration.rs:89` | `chunk5::get_body_2_keeps_alive [run3 h1 via proxy]` | passing | PASS/PASS/PASS | FAIL / FAIL | SAME |
| `get_strip_connection_header [run1 h1 direct]` | `tests/integration.rs:133` | `chunk5::get_strip_connection_header [run1 h1 direct]` | passing | PASS/PASS/PASS | FAIL / FAIL | SAME |
| `get_strip_connection_header [run3 h1 via proxy]` | `tests/integration.rs:133` | `chunk5::get_strip_connection_header [run3 h1 via proxy]` | passing | PASS/PASS/PASS | FAIL / FAIL | SAME |
| `get_strip_keep_alive_header [run1 h1 direct]` | `tests/integration.rs:159` | `chunk5::get_strip_keep_alive_header [run1 h1 direct]` | passing | PASS/PASS/PASS | FAIL / FAIL | SAME |
| `get_strip_keep_alive_header [run3 h1 via proxy]` | `tests/integration.rs:159` | `chunk5::get_strip_keep_alive_header [run3 h1 via proxy]` | passing | PASS/PASS/PASS | FAIL / FAIL | SAME |
| `get_strip_upgrade_header [run1 h1 direct]` | `tests/integration.rs:185` | `chunk5::get_strip_upgrade_header [run1 h1 direct]` | passing | PASS/PASS/PASS | FAIL / FAIL | SAME |
| `get_strip_upgrade_header [run3 h1 via proxy]` | `tests/integration.rs:185` | `chunk5::get_strip_upgrade_header [run3 h1 via proxy]` | passing | PASS/PASS/PASS | FAIL / FAIL | SAME |
| `get_allow_te_trailers_header [run1 h1 direct]` | `tests/integration.rs:211` | `chunk5::get_allow_te_trailers_header [run1 h1 direct]` | passing | PASS/PASS/PASS | FAIL / FAIL | SAME |
| `get_allow_te_trailers_header [run3 h1 via proxy]` | `tests/integration.rs:211` | `chunk5::get_allow_te_trailers_header [run3 h1 via proxy]` | passing | PASS/PASS/PASS | FAIL / FAIL | SAME |
| `get_body_chunked [run1 h1 direct]` | `tests/integration.rs:235` | `chunk5::get_body_chunked [run1 h1 direct]` | passing | PASS/PASS/PASS | FAIL / FAIL | SAME |
| `get_body_chunked [run3 h1 via proxy]` | `tests/integration.rs:235` | `chunk5::get_body_chunked [run3 h1 via proxy]` | passing | PASS/PASS/PASS | FAIL / FAIL | SAME |
| `post_outgoing_length [run1 h1 direct]` | `tests/integration.rs:261` | `chunk5::post_outgoing_length [run1 h1 direct]` | passing | PASS/PASS/PASS | FAIL / FAIL | SAME |
| `post_outgoing_length [run3 h1 via proxy]` | `tests/integration.rs:261` | `chunk5::post_outgoing_length [run3 h1 via proxy]` | passing | PASS/PASS/PASS | FAIL / FAIL | SAME |
| `post_chunked [run1 h1 direct]` | `tests/integration.rs:284` | `chunk5::post_chunked [run1 h1 direct]` | passing | PASS/PASS/PASS | FAIL / FAIL | SAME |
| `post_chunked [run3 h1 via proxy]` | `tests/integration.rs:284` | `chunk5::post_chunked [run3 h1 via proxy]` | passing | PASS/PASS/PASS | FAIL / FAIL | SAME |
| `get_2 [run1 h1 direct]` | `tests/integration.rs:308` | `chunk5::get_2 [run1 h1 direct]` | passing | PASS/PASS/PASS | FAIL / FAIL | SAME |
| `get_2 [run3 h1 via proxy]` | `tests/integration.rs:308` | `chunk5::get_2 [run3 h1 via proxy]` | passing | PASS/PASS/PASS | FAIL / FAIL | SAME |
| `conn_reads_request_head` | `src/proto/h1/conn.rs:1316` | `chunk5::conn_reads_request_head` | passing | PASS/PASS/PASS | FAIL / FAIL | SAME |
| `conn_reads_partial_request_head` | `src/proto/h1/conn.rs:1331` | `chunk5::conn_reads_partial_request_head` | passing | PASS/PASS/PASS | FAIL / PASS | SAME |
| `conn_accepts_eof_when_idle` | `src/proto/h1/conn.rs:1344` | `chunk5::conn_accepts_eof_when_idle` | passing | PASS/PASS/PASS | FAIL / PASS | SAME |
| `conn_rejects_eof_during_partial_head` | `src/proto/h1/conn.rs:1353` | `chunk5::conn_rejects_eof_during_partial_head` | passing | PASS/PASS/PASS | FAIL / FAIL | SAME |
| `conn_reads_body_and_reports_end` | `src/proto/h1/conn.rs:1404` | `chunk5::conn_reads_body_and_reports_end` | passing | PASS/PASS/PASS | FAIL / FAIL | SAME |

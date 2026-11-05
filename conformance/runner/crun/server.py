"""The server process of one case (SPEC.md section 3): starts
`sh -c 'exec <cmd> "$@"' sh --config <file>`, waits for its first stdout
line "LISTENING <port>", reads every later stdout line as a JSON event (a
line that is not JSON becomes an invalid_line event with the line), keeps
stderr, sends control lines on stdin, and stops it ("exit", then SIGKILL
after 500 ms).

The child gets only descriptors 0, 1 and 2 (close_fds), so a server never
holds a socket or a pipe of a case that runs in parallel.

Test tooling only."""

import json
import os
import subprocess
import tempfile
import threading

from .bytestr import CaseError, json_str, json_text
from .conn import now_us, sleep_ms


class EventLog:
    """The events of one server, appended by its stdout reader."""

    def __init__(self):
        self.cond = threading.Condition()
        self.events = []

    def add(self, ev) -> None:
        with self.cond:
            self.events.append(ev)
            self.cond.notify_all()

    def count(self) -> int:
        with self.cond:
            return len(self.events)

    def snapshot(self) -> list:
        with self.cond:
            return list(self.events)

    def wait_for(self, deadline_us: int, found):
        """Calls found(events) until it is true or the deadline has passed,
        and returns its last result. The log stays locked from the check to
        the wait, so an event added right after a check that found nothing
        still ends the wait (the reader cannot add it in between)."""
        with self.cond:
            while True:
                r = found(self.events)
                left_us = deadline_us - now_us()
                if r or left_us <= 0:
                    return r
                self.cond.wait(left_us / 1_000_000)


class ServerProc:
    def __init__(self, cmd: str, spec):
        self.events = EventLog()
        self.port = None
        self._err_lock = threading.Lock()
        self._err = []
        self._proc = None
        self._first = None  # (ok: bool, port or error text) once the first line is read
        self._first_ready = threading.Event()
        fd, self.config_path = tempfile.mkstemp(
            prefix="bearings-conformance-", suffix=".json"
        )
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                f.write(json_text(spec))
        except OSError as e:
            raise CaseError(f"cannot write {self.config_path}: {e}") from None
        try:
            self._proc = subprocess.Popen(
                [
                    "sh",
                    "-c",
                    "exec " + cmd + ' "$@"',
                    "sh",
                    "--config",
                    self.config_path,
                ],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                close_fds=True,
                restore_signals=True,
            )
        except OSError as e:
            raise CaseError(f"cannot spawn server {json_str(cmd)}: {e}") from None
        self._out_thread = threading.Thread(target=self._read_stdout, daemon=True)
        self._err_thread = threading.Thread(target=self._read_stderr, daemon=True)
        self._out_thread.start()
        self._err_thread.start()
        if not self._first_ready.wait(10):
            self.destroy()
            raise CaseError("server did not print LISTENING within 10 s")
        ok, value = self._first
        if ok:
            self.port = value
            return
        sleep_ms(100)
        err = self.stderr_text().decode("utf-8", "replace")
        self.destroy()
        raise CaseError(f"{value}; server stderr:\n{err}")

    # ---- readers ----

    def _read_stderr(self):
        err = self._proc.stderr
        while True:
            chunk = err.read1(4096)
            if not chunk:
                break
            with self._err_lock:
                self._err.append(chunk)

    def _read_stdout(self):
        out = self._proc.stdout
        first = True
        pending = b""
        while True:
            chunk = out.read1(65536)
            if not chunk:
                break
            pending += chunk
            while True:
                nl = pending.find(b"\n")
                if nl < 0:
                    break
                line = pending[:nl]
                pending = pending[nl + 1 :]
                if first:
                    first = False
                    text = line.rstrip(bytes(range(33)))
                    port = None
                    if text.startswith(b"LISTENING "):
                        rest = text[10:].strip(bytes(range(33)))
                        if rest.isdigit() and int(rest) <= 65535:
                            port = int(rest)
                    if port is None:
                        self._first = (
                            False,
                            'first stdout line must be "LISTENING <port>", got '
                            + json_str(line.decode("utf-8", "replace") + "\n"),
                        )
                        self._first_ready.set()
                        return
                    self._first = (True, port)
                    self._first_ready.set()
                    continue
                text = line.rstrip(bytes(range(33)))
                if not text:
                    continue
                try:
                    ev = json.loads(text.decode("utf-8"))
                except (ValueError, UnicodeDecodeError):
                    ev = {
                        "event": "invalid_line",
                        "line": text.decode("utf-8", "replace"),
                    }
                self.events.add(ev)
        if first:
            self._first = (False, "server closed stdout before LISTENING")
            self._first_ready.set()

    # ---- control ----

    def stderr_text(self) -> bytes:
        with self._err_lock:
            return b"".join(self._err)

    def send_line(self, line: str) -> None:
        stdin = self._proc.stdin
        if stdin is None or stdin.closed:
            raise CaseError("server stdin is closed")
        try:
            stdin.write(line.encode("utf-8") + b"\n")
            stdin.flush()
        except OSError as e:
            raise CaseError(f"cannot write to server stdin: {e.strerror}") from None

    def exited(self) -> str:
        """The exit status text when the process has exited, else ''."""
        rc = self._proc.poll()
        if rc is None:
            return ""
        if rc < 0:
            return f"signal: {-rc}"
        return f"exit status: {rc}"

    def stop(self) -> None:
        if self._proc is None:
            return
        try:
            self.send_line("exit")
        except CaseError:
            pass
        try:
            self._proc.stdin.close()
        except OSError:
            pass
        deadline = now_us() + 500_000
        while self._proc.poll() is None and now_us() < deadline:
            sleep_ms(10)
        if self._proc.poll() is None:
            self._proc.kill()
            self._proc.wait()
        # stdout ends when the process is gone (it was started with exec),
        # so the reader has logged every line once it ends
        self._out_thread.join()
        self._err_thread.join()
        self._proc.stdout.close()
        self._proc.stderr.close()

    def destroy(self) -> None:
        if self._proc is not None:
            if self._proc.poll() is None:
                self._proc.kill()
            self.stop()
        try:
            os.unlink(self.config_path)
        except OSError:
            pass

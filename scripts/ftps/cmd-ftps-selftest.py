#!/usr/bin/env python3
"""Run `cmd/ftps plain` against a mock FTP server, with no Docker involved.

Usage: cmd-ftps-selftest.py CMD_FTPS_ROOT
       # ^ the repository root, i.e. where `moon run cmd/ftps` resolves

`cmd/ftps` is only ever exercised by `scripts/ci.sh` against real containers,
which is a late and expensive place to find out that the program itself is
broken. It is also where the last failure hid: on the FTPS block's `plain`
leg the binary printed its `RETR` line and then died with

    Dead lock detected. Tasks spawned at the following locations are still
    alive: ["cmd/ftps/main.mbt:202:30-202:70@PaiGack/ftp"]

The location named the `@io.MemoryReader` argument of the `STOR` call. Built
inline as a temporary, the reader's background producer task has no owner that
closes it, so when `stor` *fails* the reader is never drained and never closed,
and the event loop ends with a live task and no work left to do. The server's
real error -- the whole point of the call -- was replaced by a panic, and the
`250`-line container log the pipeline printed afterwards pointed at nothing.

Every assertion here is about that shape, and every one runs the real binary:

  * a server that answers `LIST` / `RETR` / `STOR` / `DELE` -> exit 0
  * a server that *refuses* `STOR` -> exit 1 with the server's own message, and
    **no deadlock**. This is the regression guard: with the reader left
    unclosed this case panics instead of reporting the `550`.
  * `QUIT` still reaches the server -> the run tears the session down cleanly
    rather than bailing out of the event loop.

The mock binds ephemeral ports, so nothing here needs Docker, root or a fixed
port, and it can run before any image is pulled.
"""

import socket
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

ROOT = Path(sys.argv[1]).resolve()
MOCK = Path(__file__).parent / "ftp_mock.py"
CREATE = "drwxr-xr-x    2 0        0            4096 Jan 01 00:00 sub\r\n"
PLAIN = "-rw-r--r--    1 0        0              12 Jan 01 00:00 hello.txt\r\n"


def free_port():
    """Bind and release a port, so the mock can claim it immediately after."""
    sock = socket.socket()
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
    sock.close()
    return port


class Mock:
    """A `scripts/ftps/ftp_mock.py` on ephemeral ports, stopped on exit."""

    def __init__(self, stor_refused):
        self.port = free_port()
        self.data_port = free_port()
        # The raw body the mock sends for `LIST`, written to a file so the
        # `\r\n` line endings survive being passed through a command line.
        self.listing = Path(tempfile.mkdtemp()) / "listing"
        self.listing.write_bytes(CREATE.encode() + PLAIN.encode())
        args = [
            sys.executable, str(MOCK), "127.0.0.1",
            str(self.port), str(self.data_port), str(self.listing),
        ]
        if stor_refused:
            args.append("--stor-refused")
        self.transcript = tempfile.NamedTemporaryFile(delete=False)
        self.proc = subprocess.Popen(
            args, stdout=self.transcript, stderr=subprocess.STDOUT,
        )
        self._wait_ready()

    def _wait_ready(self):
        deadline = time.time() + 10
        while time.time() < deadline:
            if b"mock ready" in Path(self.transcript.name).read_bytes():
                return
            if self.proc.poll() is not None:
                raise RuntimeError(
                    "ftp_mock.py exited during startup: "
                    + Path(self.transcript.name).read_text()
                )
            time.sleep(0.05)
        raise RuntimeError("ftp_mock.py never reported itself ready")

    def saw(self, needle):
        return needle in Path(self.transcript.name).read_text()

    def stop(self):
        self.proc.terminate()
        try:
            self.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.proc.kill()


def run_plain(mock):
    """Run the real `cmd/ftps plain` against `mock`; return (rc, output)."""
    env = {
        "PATH": "/usr/bin:/bin:/usr/local/bin:" + str(Path.home() / ".moon/bin"),
        "HOME": str(Path.home()),
        "FTP_TLS_HOST": "127.0.0.1",
        "FTP_TLS_USER": "test",
        "FTP_TLS_PASS": "test",
        # `plain` reads only the port from here; the CA and the FTPS port are
        # required by `explicit`, which this test does not run.
        "FTP_PLAIN_PORT": str(mock.port),
        "FTP_TLS_PORT": str(mock.port),
        "FTP_TLS_CA": "/nonexistent-on-purpose",
    }
    proc = subprocess.run(
        ["moon", "run", "cmd/ftps", "--target", "native", "--", "plain"],
        cwd=ROOT, env=env, capture_output=True, text=True, timeout=180,
    )
    return proc.returncode, proc.stdout + proc.stderr


def main():
    failures = []

    def check(name, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {name}")
        if not ok:
            failures.append(f"{name}: {detail}")

    print("cmd/ftps self-test")

    # 1. The happy path: the whole smoke test has to still pass end to end.
    mock = Mock(stor_refused=False)
    try:
        rc, out = run_plain(mock)
        check("a mock that serves every transfer completes", rc == 0,
              f"rc={rc} output={out.strip()!r}")
        check("the run reaches STOR and DELE",
              mock.saw("CMD STOR") and mock.saw("CMD DELE"),
              "the mock never saw a STOR / DELE")
        check("the session is torn down with QUIT", mock.saw("CMD QUIT"),
              "the mock never saw a QUIT")
    finally:
        mock.stop()

    # 2. The regression: a refused STOR must be reported as a 550, not as a
    #    deadlock. The deadlock is what the pipeline used to print, and it
    #    named a task at the `MemoryReader` argument of the STOR call.
    mock = Mock(stor_refused=True)
    try:
        rc, out = run_plain(mock)
        check("a refused STOR fails the run", rc != 0,
              f"rc={rc} output={out.strip()!r}")
        check("no deadlock is reported",
              "Dead lock" not in out and "still alive" not in out,
              f"output={out.strip()!r}")
        # The message names STOR and the failing step: the run has to say what
        # broke, not die silently in the event loop.
        check("the failure names STOR and the step",
              "STOR failed" in out, f"output={out.strip()!r}")
    finally:
        mock.stop()

    if failures:
        print("\ncmd/ftps self-test FAILED:", file=sys.stderr)
        for failure in failures:
            print(f"  - {failure}", file=sys.stderr)
        return 1
    print("cmd/ftps self-test: all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())

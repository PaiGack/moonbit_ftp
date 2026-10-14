#!/usr/bin/env python3
"""Drive `scripts/probe-ftp.py` against a mock vsftpd, with no Docker.

Usage: probe-ftp-selftest.py REPO_ROOT

`probe-ftp.py` is what `scripts/start-ftp.sh` and `scripts/ensure-ftp.sh`
decide "the container is healthy" with, and it is the only thing standing
between a dead plaintext container and four clients reporting it in four
different vocabularies. So its own bugs are expensive in a way no container
ever shows: a probe that says "healthy" about a dead server makes `ensure-ftp.sh`
skip the restart, and a probe that says "unhealthy" about a healthy one makes it
restart the container underneath the client that is about to use it.

Two of its properties are therefore asserted here, both invisible against a real
vsftpd, which is up and answers everything:

  * **Every session ends with `QUIT`.** A probe that just closes the control
    socket leaves vsftpd's data-channel slot for that login held until its own
    `idle_session_timeout` reclaims it, and `scripts/ensure-ftp.sh` now probes
    the container before *every* plaintext client -- one slot per call. The mock
    counts how many of its sessions reached `QUIT`, so the leak is a number here
    instead of a downstream `421` nobody can attribute.

  * **The failure path still says goodbye, and still reports the server's
    reply.** A `PASV` that is refused, a `LIST` that never earns its `150` --
    the probe has to `QUIT` there too (same leak, reached by the retry loop) and
    it has to fail *with the reply it got*, since that message is the only thing
    the operator sees.

The mock is deliberately tiny and separate from `ftps/ftp_mock.py`: that one
serves `cmd/ftps`'s slice of FTP and logs a different set of things. What is
being modelled here is only the session lifecycle -- banner, login, `PASV` with a
real listener, `LIST`, `226`, `QUIT` -- plus a switch for each way it can go
wrong. Ports are ephemeral, so this runs before any image is pulled.
"""

import importlib.util
import re
import socket
import sys
import tempfile
import threading
import time
from pathlib import Path

ROOT = Path(sys.argv[1]).resolve()
PROBE = ROOT / "scripts" / "probe-ftp.py"

failures = []


def check(name, ok, detail=""):
    print(f"  {'ok  ' if ok else 'FAIL'} {name}")
    if not ok:
        failures.append(f"{name}{': ' + detail if detail else ''}")


def load_probe():
    """Import `probe-ftp.py` as a module instead of running it.

    `probe-ftp.py` is a script: importing it would execute the retry loop
    against `sys.argv`. Loading it under a private name still parses it, which
    is the point -- a syntax error or a missing `attempt()` must fail here, not
    in the middle of CI's Docker block.
    """
    saved = sys.argv
    # The probe reads its arguments at *module* level, and its retry loop is
    # module level too -- so the import below runs the whole script once
    # against a port nobody is listening on. That is the cheapest way to get
    # at `attempt()`, and the run also has to be harmless: point it at a
    # discarded port with a zero deadline so it exits immediately, and treat
    # its `SystemExit` as the successful end of that load-time run rather than
    # as a failure to load.
    sys.argv = [str(PROBE), "127.0.0.1", str(MockVsftpd._free_port()),
                "test", "test", "0"]
    try:
        spec = importlib.util.spec_from_file_location("probe_ftp_under_test",
                                                      PROBE)
        module = importlib.util.module_from_spec(spec)
        try:
            spec.loader.exec_module(module)
        except SystemExit:
            pass
    finally:
        sys.argv = saved
    return module


class MockVsftpd:
    """A vsftpd-shaped session lifecycle, with a switch per failure mode.

    `refuse_pasv` answers `500` to `PASV`; `refuse_list` accepts the passive
    connection but answers `425` instead of `150`. Both are shapes the real
    server produces (vsftpd answers `500` when passive mode is off), and both
    are the paths where a missing `QUIT` would otherwise go unnoticed -- the
    connection is *closed* by the probe either way, so only a server that counts
    sessions can tell the two apart.
    """

    def __init__(self, refuse_pasv=False, refuse_list=False):
        self.refuse_pasv = refuse_pasv
        self.refuse_list = refuse_list
        self.sessions = []  # one entry per control connection, see `session`
        self.quits = 0
        self._lock = threading.Lock()
        self.port = self._free_port()
        self._server = socket.socket()
        self._server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._server.bind(("127.0.0.1", self.port))
        self._server.listen(8)
        self._thread = threading.Thread(target=self._accept_loop, daemon=True)
        self._thread.start()

    @staticmethod
    def _free_port():
        sock = socket.socket()
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
        sock.close()
        return port

    def _accept_loop(self):
        while True:
            try:
                conn, _ = self._server.accept()
            except OSError:
                return
            with self._lock:
                self.sessions.append([])
                index = len(self.sessions) - 1
            threading.Thread(
                target=self._session, args=(conn, index), daemon=True
            ).start()

    def _session(self, conn, index):
        buffer = [b""]
        data_listener = None

        def send(text):
            conn.sendall((text + "\r\n").encode())

        def readline():
            while b"\r\n" not in buffer[0]:
                chunk = conn.recv(4096)
                if not chunk:
                    return None
                buffer[0] += chunk
            line, _, rest = buffer[0].partition(b"\r\n")
            buffer[0] = rest
            return line.decode(errors="replace")

        send("220 mock vsftpd ready")
        try:
            while True:
                line = readline()
                if line is None:
                    return
                with self._lock:
                    self.sessions[index].append(line)
                command, _, _ = line.partition(" ")
                command = command.upper()
                if command == "USER":
                    send("331 need password")
                elif command == "PASS":
                    send("230 logged in")
                elif command == "PASV":
                    if self.refuse_pasv:
                        send("500 PASV not allowed")
                        continue
                    data_listener = socket.socket()
                    data_listener.setsockopt(socket.SOL_SOCKET,
                                             socket.SO_REUSEADDR, 1)
                    data_listener.bind(("127.0.0.1", 0))
                    data_listener.listen(1)
                    data_listener.settimeout(10)
                    port = data_listener.getsockname()[1]
                    send(f"227 Entering Passive Mode "
                         f"(127,0,0,1,{port // 256},{port % 256})")
                elif command == "LIST":
                    if self.refuse_list:
                        send("425 cannot open data connection")
                        continue
                    send("150 opening data connection")
                    try:
                        data, _ = data_listener.accept()
                    except (socket.timeout, TimeoutError, OSError):
                        continue
                    data.sendall(b"-rw-r--r-- 1 0 0 12 Jan 01 00:00 hello\r\n")
                    data.close()
                    send("226 transfer complete")
                elif command == "QUIT":
                    with self._lock:
                        self.quits += 1
                    send("221 goodbye")
                    return
                else:
                    send("200 ok")
        finally:
            if data_listener is not None:
                data_listener.close()
            conn.close()

    def stop(self):
        self._server.close()
        # Give the per-session threads a moment to record their last command,
        # so `saw_quit()` reads a settled file rather than a race.
        time.sleep(0.2)


def run_probe(mock, timeout="3"):
    """Run the real `probe-ftp.py` against `mock`; return (rc, output)."""
    env_path = Path(tempfile.mkdtemp()) / "out"
    import subprocess

    proc = subprocess.run(
        [sys.executable, str(PROBE), "127.0.0.1", str(mock.port),
         "test", "test", timeout],
        capture_output=True, text=True, timeout=120,
    )
    env_path.write_text(proc.stdout + proc.stderr)
    return proc.returncode, proc.stdout + proc.stderr


print("probe-ftp.py self-test")

# 0. The module parses and defines the retry loop's one unit of work. A typo in
#    the probe otherwise only shows up as "the container is unhealthy" inside
#    CI's Docker block, which is the exact confusion this script exists to
#    remove.
try:
    probe_module = load_probe()
    check("probe-ftp.py imports and defines attempt()",
          callable(getattr(probe_module, "attempt", None)))
except Exception as exc:  # noqa: BLE001 - any load failure is the finding
    check("probe-ftp.py imports and defines attempt()", False, repr(exc))

# 1. The happy path, and the session it leaves behind. `QUIT` is the assertion:
#    with `ensure-ftp.sh` in front of every plaintext client, a probe that skips
#    it hands the next client one fewer data-channel slot than the server has.
mock = MockVsftpd()
rc, out = run_probe(mock)
calls = [line for session in mock.sessions for line in session]
mock.stop()
check("a healthy server passes", rc == 0, out.strip())
check("the probe logged in and transferred",
      any(line.startswith("PASS ") for line in calls)
      and any(line.startswith("LIST") for line in calls), str(calls))
check("the probe quit the session it opened", mock.quits == 1,
      f"sessions that reached QUIT: {mock.quits}, calls: {calls}")

# 2. A refused `PASV`. The probe must fail -- and still `QUIT`, because the
#    failure is retried until the deadline and every attempt leaks otherwise.
mock = MockVsftpd(refuse_pasv=True)
rc, out = run_probe(mock, timeout="2")
mock.stop()
check("a server that refuses PASV fails the probe", rc != 0, out.strip())
check("the refusal is reported from the server's own reply",
      "500" in out or "PASV" in out, out.strip())
check("the probe quit the session even though PASV was refused",
      mock.quits >= 1, f"QUIT count: {mock.quits}")

# 3. A `LIST` that never earns its 150. Same requirement, different exit from
#    the same `try`.
mock = MockVsftpd(refuse_list=True)
rc, out = run_probe(mock, timeout="2")
mock.stop()
check("a server that refuses LIST fails the probe", rc != 0, out.strip())
check("the probe quit the session even though LIST was refused",
      mock.quits >= 1, f"QUIT count: {mock.quits}")

# 4. Nothing listening at all: the failure has to be reported, not crash the
#    caller with a traceback. `ensure-ftp.sh` reads the exit code, so an
#    uncaught exception that still exits non-zero would pass -- what is checked
#    is the message.
dead_port = MockVsftpd._free_port()
import subprocess  # noqa: E402 - kept next to its only use

dead = subprocess.run(
    [sys.executable, str(PROBE), "127.0.0.1", str(dead_port), "test", "test", "1"],
    capture_output=True, text=True, timeout=60,
)
check("a server that is not listening fails the probe",
      dead.returncode != 0, str(dead.returncode))
check("the connect failure is named in the probe's own message",
      "gave up after" in dead.stderr and "no attempt was made" not in dead.stderr,
      dead.stderr.strip())

# 5. The mock itself: the session-count assertions above are only worth
#    something if a probe that *did not* quit would be caught. Simulate that by
#    talking to the same mock without the final QUIT.
mock = MockVsftpd()
import socket as _socket  # noqa: E402

control = _socket.create_connection(("127.0.0.1", mock.port), 2)
control.recv(4096)
for line in (b"USER test\r\n", b"PASS test\r\n", b"PASV\r\n"):
    control.sendall(line)
    control.recv(4096)
control.close()
time.sleep(0.2)
mock.stop()
check("a session closed without QUIT is counted as such", mock.quits == 0,
      f"QUIT count: {mock.quits} (the assertion above would be vacuous)")

if failures:
    print("\nprobe-ftp.py self-test FAILED:")
    for failure in failures:
        print(f"  - {failure}")
    sys.exit(1)

print("probe-ftp.py self-test: all checks passed")

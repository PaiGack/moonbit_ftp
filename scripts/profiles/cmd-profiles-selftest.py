#!/usr/bin/env python3
"""Run `cmd/profiles` against a mock FTP server, with no Docker involved.

Usage: cmd-profiles-selftest.py REPO_ROOT

`cmd/profiles` is the four-capability-profile end-to-end test, and each profile
is a claim about *which protocol command the client chose*: `no-mlst` must
parse `LIST` rather than `MLSD`, `no-epsv` must transfer over `PASV` rather
than `EPSV`, `no-time` must refuse to write a timestamp rather than pretend it
did. Those claims are exactly what a real vsftpd will not tell you -- it just
serves whatever it is asked for -- so they have to be read off the wire.

That is what this file does. It runs the real binary against
`ftp_profile_mock.py` (a filesystem-backed mock, so the effect assertions the
program makes are real) and then reads the mock's transcript per profile:

  * every profile reaches `NLST` and both `MDTM` forms (`QUIT` included)
  * `full` uses `MLSD` + `EPSV`, and *writes* a timestamp
  * `no-mlst` uses `LIST` and never `MLSD`
  * `no-epsv` uses `PASV` and never `EPSV`
  * `no-time` reads a timestamp but never writes one

One shape is the *server's* choice rather than the client's, and it has to be
asserted separately: `NLST <dir>` is answered with the full path of each entry
by vsftpd and with the bare name by most others, and the profiles are judged
against whichever the mock picked. `check_nlst_shape` asks the mock directly,
so the mock cannot silently drift to the shape that makes the profiles pass.

The protocol-choice checks are the ones a real-server-only test cannot see:
both `EPSV` and `PASV` work against the container, so "the fallback happened"
is invisible in the program's output and only the server's command log can
prove it.

The mock binds an ephemeral port, so nothing here needs Docker, root or a fixed
port, and it runs in `scripts/ci.sh` before any image is pulled.
"""

import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(sys.argv[1]).resolve()
MOCK = Path(__file__).parent / "ftp_profile_mock.py"
PROFILES = ["full", "no-mlst", "no-time", "no-epsv"]


def free_port():
    """Bind and release a port, so the mock can claim it immediately after."""
    sock = socket.socket()
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
    sock.close()
    return port


class Mock:
    """`ftp_profile_mock.py` on an ephemeral port, over its own fixture copy."""

    def __init__(self):
        self.port = free_port()
        # A private copy of the fixture, for the same reason the containers get
        # one: the program uploads into its root, so the checked-in tree must
        # not be the thing that changes.
        self.root = Path(tempfile.mkdtemp()) / "root"
        shutil.copytree(ROOT / "testdata" / "ftp" / "fixture", self.root)
        self.transcript = Path(tempfile.mkdtemp()) / "transcript"
        self.handle = self.transcript.open("w")
        self.proc = subprocess.Popen(
            [sys.executable, str(MOCK), "127.0.0.1",
             str(self.port), str(self.root)],
            stdout=self.handle, stderr=subprocess.STDOUT,
        )
        self._wait_ready()

    def _wait_ready(self):
        deadline = time.time() + 10
        while time.time() < deadline:
            if "mock ready" in self.transcript.read_text():
                return
            if self.proc.poll() is not None:
                raise RuntimeError(
                    "ftp_profile_mock.py exited during startup: "
                    + self.transcript.read_text()
                )
            time.sleep(0.05)
        raise RuntimeError("ftp_profile_mock.py never reported itself ready")

    def sessions(self):
        """The mock's transcript, split into one command list per connection."""
        lines = [
            line.strip()
            for line in self.transcript.read_text().splitlines()
            if line.startswith("CMD ")
        ]
        groups, current = [], []
        for line in lines:
            if line == "CMD USER test" and "CMD QUIT" in current:
                groups.append(current)
                current = []
            current.append(line)
        if current:
            groups.append(current)
        return groups

    def stop(self):
        self.proc.terminate()
        try:
            self.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.proc.kill()
        self.handle.close()


def run_profiles(mock):
    """Run the real `cmd/profiles` against `mock`; return (rc, output)."""
    env = {
        "PATH": "/usr/bin:/bin:/usr/local/bin:" + str(Path.home() / ".moon/bin"),
        "HOME": str(Path.home()),
        "FTP_TEST_HOST": "127.0.0.1",
        "FTP_TEST_PORT": str(mock.port),
        "FTP_TEST_USER": "test",
        "FTP_TEST_PASS": "test",
    }
    proc = subprocess.run(
        ["moon", "run", "cmd/profiles", "--target", "native"],
        cwd=ROOT, env=env, capture_output=True, text=True, timeout=600,
    )
    return proc.returncode, proc.stdout + proc.stderr


def count(session, command):
    """How many times `command` was sent on one connection."""
    return sum(
        1 for line in session
        if line == f"CMD {command}" or line.startswith(f"CMD {command} ")
    )


def writes_time(session):
    """Whether the session sent the *write* form, `MDTM <14 digits> <path>`.

    Both forms share one command name, so counting `MDTM` cannot tell a read
    from a write; the profile that matters is precisely the one that must read
    without ever writing.
    """
    prefix = "CMD MDTM "
    for line in session:
        if not line.startswith(prefix):
            continue
        stamp = line[len(prefix):].split(" ", 1)[0]
        if len(stamp) == 14 and stamp.isdigit():
            return True
    return False


def check_nlst_shape(mock):
    """Probe `NLST` on the mock and report whether it answers full paths.

    `cmd/profiles` asserts on the entry it looked for, so it passes against a
    mock that answers bare names and fails against vsftpd, which answers full
    paths -- which is precisely how a green self-test shipped a red pipeline.
    Asking the mock directly is the only way to see which of the two shapes the
    profiles are being judged against, so that mismatch is caught here.
    """
    control = socket.create_connection(("127.0.0.1", mock.port), timeout=10)
    control.settimeout(10)
    try:
        def expect(prefix):
            line = control.recv(4096).decode(errors="replace").strip()
            assert line.startswith(prefix), f"expected {prefix}, got {line!r}"
            return line

        def send(command):
            control.sendall(f"{command}\r\n".encode())

        expect("220")
        send("USER test")
        expect("331")
        send("PASS test")
        expect("230")

        send("EPSV")
        reply = expect("229")
        port = int(reply.rsplit("|||", 2)[1].split("|")[0])

        data = socket.create_connection(("127.0.0.1", port), timeout=10)
        send("NLST /")
        expect("150")
        payload = b""
        while True:
            chunk = data.recv(4096)
            if not chunk:
                break
            payload += chunk
        data.close()
        expect("226")
        names = [line for line in payload.decode().splitlines() if line.strip()]
        return bool(names) and all(name.startswith("/") for name in names)
    finally:
        control.close()


def main():
    failures = []

    def check(name, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {name}")
        if not ok:
            failures.append(f"{name}: {detail}")

    print("cmd/profiles self-test")

    mock = Mock()
    try:
        rc, out = run_profiles(mock)
        check("all four profiles complete", rc == 0,
              f"rc={rc} output={out.strip()!r}")
        for profile in PROFILES:
            check(f"the run reports profile {profile}",
                  f"profile {profile}: OK" in out,
                  f"output={out.strip()!r}")

        sessions = mock.sessions()
        check("one session per profile", len(sessions) == len(PROFILES),
              f"got {len(sessions)}: {[s[0] for s in sessions]}")

        if len(sessions) != len(PROFILES):
            raise SystemExit(1)

        by_name = dict(zip(PROFILES, sessions))
        for profile, session in by_name.items():
            check(f"{profile}: exercises NLST", count(session, "NLST") >= 1,
                  "NLST never reached the server")
            check(f"{profile}: exercises MDTM", count(session, "MDTM") >= 1,
                  "MDTM never reached the server")
            check(f"{profile}: exercises STOR / RETR / MKD / RMD / DELE",
                  all(count(session, cmd) >= 1 for cmd in
                      ("STOR", "RETR", "MKD", "RMD", "DELE")),
                  f"commands seen: {session}")
            check(f"{profile}: quits cleanly", count(session, "QUIT") == 1,
                  "the session was not torn down with QUIT")

        # The transport claims -- invisible against a real server, where both
        # passive commands work and the client's choice leaves no trace.
        full = by_name["full"]
        check("full: lists with MLSD", count(full, "MLSD") >= 1)
        check("full: transfers over EPSV", count(full, "EPSV") >= 1)
        check("full: never falls back to PASV", count(full, "PASV") == 0)
        check("full: writes a timestamp through MDTM", writes_time(full),
              "expected the MDTM <time> <path> write quirk")
        check("full: also reads it back",
              count(full, "MDTM") >= 3,
              "expected a read, the write, and the read-back assertion")

        no_mlst = by_name["no-mlst"]
        check("no-mlst: lists with LIST", count(no_mlst, "LIST") >= 1)
        check("no-mlst: never sends MLSD", count(no_mlst, "MLSD") == 0,
              "disable_mlsd did not suppress MLSD")

        no_epsv = by_name["no-epsv"]
        check("no-epsv: transfers over PASV", count(no_epsv, "PASV") >= 1)
        check("no-epsv: never sends EPSV", count(no_epsv, "EPSV") == 0,
              "disable_epsv did not suppress EPSV")

        no_time = by_name["no-time"]
        check("no-time: still reads a timestamp", count(no_time, "MDTM") >= 1,
              "the read path must stay available")
        check("no-time: never writes a timestamp", not writes_time(no_time),
              "set_file_time must refuse rather than send MDTM <time> <path>")
        check("no-time: never sends MFMT", count(no_time, "MFMT") == 0,
              "the mock does not advertise MFMT, so it must not be sent")

        # The mock's own `NLST` shape, probed straight over a socket rather
        # than inferred from the program's log. See `check_nlst_shape`.
        check("the mock answers NLST with full paths, like vsftpd",
              check_nlst_shape(mock), "the mock must match the container")

        # And the effect-level statement the program itself makes: the scratch
        # tree is gone, so the fixture is all that is left.
        leftovers = sorted(
            p.relative_to(mock.root).as_posix()
            for p in mock.root.rglob("*")
        )
        check("no scratch file survives the run",
              not any(item.startswith("profiles_") for item in leftovers),
              f"leftovers: {leftovers}")
    finally:
        mock.stop()

    if failures:
        print("\ncmd/profiles self-test FAILED:", file=sys.stderr)
        for failure in failures:
            print(f"  - {failure}", file=sys.stderr)
        return 1
    print("cmd/profiles self-test: all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Exercise `probe-ftps.sh` against a mock server, with no Docker involved.

Usage: probe-ftps-selftest.py PROBE CA_FILE

`probe-ftps.sh` is a readiness gate: `start-ftps.sh` only writes
`.ftp-tls.env` once it exits 0, and both `cmd/ftps/run.sh` invocations depend on
that file. A gate that says "unhealthy" about a healthy server therefore fails
the whole FTPS block of `scripts/ci.sh`, and does it from inside a retry loop
where the real cause is invisible.

That is not hypothetical. The probe used to pipe three commands into
`openssl s_client` and rely on the pipeline exiting; `s_client` never exits on
its own, so a *successful* login looked like a timeout, and `-quiet` put the
`230` reply on stderr where the `grep '^230 '` could not see it. Both bugs are
invisible to `bash -n` and to any test that only runs against a real server,
because they make the probe fail on success rather than on failure.

So: a mock that speaks the same `AUTH TLS` -> TLS upgrade -> `USER` / `PASS`
conversation as `bfren/ftps`, run against the real `probe-ftps.sh`. The
assertions are deliberately about *outcomes*:

  * a mock that logs the user in        -> probe exits 0
  * a mock that rejects the password    -> probe exits non-zero, mentions 530
  * nothing listening at all            -> probe exits non-zero
  * an unknown CA                       -> probe exits non-zero

The mock binds an ephemeral port and is told to accept a single connection per
attempt, so nothing here needs Docker, root or a fixed port.
"""

import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

PROBE = sys.argv[1]
# Optional. When omitted, every check uses the CA `gen-cert.sh` just minted --
# which is the right default, since that is the certificate the mocks present.
CA = sys.argv[2] if len(sys.argv) > 2 else None
TIMEOUT = "5"


def line(sock, buffer, deadline):
    """Read one CRLF-terminated command line, or None on timeout/EOF."""
    while b"\r\n" not in buffer[0]:
        remaining = deadline - time.time()
        if remaining <= 0:
            return None
        sock.settimeout(remaining)
        try:
            chunk = sock.recv(4096)
        except (socket.timeout, TimeoutError, OSError):
            return None
        if not chunk:
            return None
        buffer[0] += chunk
    found, _, rest = buffer[0].partition(b"\r\n")
    buffer[0] = rest
    return found


def serve_one(conn, ctx, password_ok):
    """Speak just enough FTP to answer `AUTH TLS` + `USER` / `PASS`.

    The replies mirror the ones `bfren/ftps` sends, because what is under test
    is the probe's reading of them, not the mock's FTP implementation.
    """
    buffer = [b""]
    deadline = time.time() + 5
    try:
        conn.sendall(b"220 Welcome to the FTPS server.\r\n")
        command = line(conn, buffer, deadline)
        if command is None or command.upper() != b"AUTH TLS":
            conn.sendall(b"500 Unknown command.\r\n")
            return
        conn.sendall(b"234 Proceed with negotiation.\r\n")
        tls = ctx.wrap_socket(conn, server_side=True)
        tls.sendall(b"220 Ready to negotiate.\r\n")
        try:
            for reply in (b"331 Please specify the password.\r\n",
                          b"230 Login successful.\r\n" if password_ok
                          else b"530 Login incorrect.\r\n"):
                if line(tls, buffer, deadline) is None:
                    return
                tls.sendall(reply)
        finally:
            # Hold the socket open briefly: closing it as soon as the last reply
            # is written races the probe's read of that reply.
            time.sleep(0.3)
            tls.close()
    except (OSError, ssl.SSLError):
        pass
    finally:
        try:
            conn.close()
        except OSError:
            pass


def start_mock(cert, password_ok=True):
    """Return (port, stop) for a mock that answers exactly one connection."""
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(cert)
    server = socket.socket()
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("127.0.0.1", 0))
    server.listen(8)
    port = server.getsockname()[1]
    stopped = threading.Event()

    def loop():
        while not stopped.is_set():
            server.settimeout(0.2)
            try:
                conn, _ = server.accept()
            except (socket.timeout, TimeoutError):
                continue
            except OSError:
                return
            threading.Thread(
                target=serve_one, args=(conn, ctx, password_ok), daemon=True
            ).start()

    threading.Thread(target=loop, daemon=True).start()

    def stop():
        stopped.set()
        server.close()

    return port, stop


def run_probe(port, ca_file):
    """Run the probe under test; return (returncode, stdout+stderr)."""
    proc = subprocess.run(
        ["bash", PROBE, "127.0.0.1", str(port), "test", "test", ca_file, TIMEOUT],
        capture_output=True,
        text=True,
        timeout=90,
    )
    return proc.returncode, proc.stdout + proc.stderr


def main():
    failures = []

    def check(name, ok, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'} {name}")
        if not ok:
            failures.append(f"{name}: {detail}")

    workdir = Path(tempfile.mkdtemp())
    cert = workdir / "vsftpd.pem"
    # One certificate for every mock; the probe is given the CA that signed it.
    subprocess.run(["bash", str(Path(PROBE).parent / "gen-cert.sh"), str(workdir)],
                   check=True, capture_output=True)
    assert cert.exists(), "gen-cert.sh did not write vsftpd.pem"
    # `gen-cert.sh` writes `ca.pem` next to the leaf it signs, so the default
    # trust anchor is the one that actually signed the certificate on offer.
    default_ca = CA or str(workdir / "ca.pem")

    print("probe-ftps.sh self-test")

    port, stop = start_mock(cert, password_ok=True)
    try:
        rc, out = run_probe(port, default_ca)
        check("accepts a server that logs the user in", rc == 0,
              f"rc={rc} output={out.strip()!r}")
    finally:
        stop()

    port, stop = start_mock(cert, password_ok=False)
    try:
        rc, out = run_probe(port, default_ca)
        check("rejects a server that refuses the password",
              rc != 0 and "530" in out, f"rc={rc} output={out.strip()!r}")
    finally:
        stop()

    # A closed port: bind and immediately release, so the port is free.
    probe_sock = socket.socket()
    probe_sock.bind(("127.0.0.1", 0))
    free_port = probe_sock.getsockname()[1]
    probe_sock.close()
    rc, out = run_probe(free_port, default_ca)
    check("fails when nothing is listening", rc != 0,
          f"rc={rc} output={out.strip()!r}")

    # The verification half: the probe must not accept a certificate it cannot
    # chain. Signed by a *second* CA, presented as if it were the trusted one.
    other = Path(tempfile.mkdtemp())
    subprocess.run(["bash", str(Path(PROBE).parent / "gen-cert.sh"), str(other)],
                   check=True, capture_output=True)
    port, stop = start_mock(cert, password_ok=True)
    try:
        rc, out = run_probe(port, ca_file=str(other / "ca.pem"))
        check("rejects a server whose certificate the CA did not sign",
              rc != 0, f"rc={rc} output={out.strip()!r}")
    finally:
        stop()

    if failures:
        print("\nprobe-ftps.sh self-test FAILED:", file=sys.stderr)
        for failure in failures:
            print(f"  - {failure}", file=sys.stderr)
        return 1
    print("probe-ftps.sh self-test: all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())

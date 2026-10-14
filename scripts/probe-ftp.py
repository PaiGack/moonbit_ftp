#!/usr/bin/env python3
"""Prove a running vsftpd answers a full login *and* a passive transfer.

Usage: probe-ftp.py HOST PORT USER PASS TIMEOUT_SECONDS

Readiness gate for `scripts/start-ftp.sh`. A bare TCP connect to the control
port is not enough: the control channel and the passive data channel are
separate listeners, and only the first one is exercised by connecting. When the
PASV range is not reachable from the client, EVERY transfer dies with
`@socket.Tcp::connect(): Connection refused` while login and `PWD` look
perfectly healthy -- so the demo fails deep inside `LIST` with an error that
reads like a library bug. Probing `PASV` + `LIST` here turns that into a clear
readiness failure at the point where the server is started.

The whole handshake is retried until the deadline, because the daemon behind a
published port can accept the connection a moment before it is ready to serve
it.

Every connection this probe opens ends with an explicit `QUIT`, and that is
load bearing rather than polite. vsftpd keeps a data-channel slot per login
until the client says goodbye, and only has a handful of them: a probe that
just closes the control socket leaves the slot occupied until the server's own
`idle_session_timeout` reclaims it. `scripts/ensure-ftp.sh` now probes the
container before *every* plaintext client, so a subprocess exit that skipped
`QUIT` would leak one slot per call -- and the leak lands on the clients, whose
`LIST` / `STOR` then fail with `421` or time out on a server the guard just
declared healthy. Hence `QUIT` in `finally`: a refused `PASV`, a `LIST` that
raised, an early `return` in a future edit must all still close the session.

The probe closes the *control* session, not the server, and that is what makes
it safe to call in front of a client: the containers it is pointed at are
long-lived (`scripts/start-ftp.sh` keeps them until `stop-ftp.sh`), and the
later client opens a session of its own rather than resuming this one.
"""

import re
import socket
import sys
import time

host, port, user, password = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
deadline = time.time() + float(sys.argv[5])
attempts = 0
last_error = "no attempt was made"


def recv_line(sock, buffer):
    """Read one CRLF-terminated reply line, buffering any extra bytes."""
    while b"\r\n" not in buffer[0]:
        chunk = sock.recv(4096)
        if not chunk:
            raise RuntimeError(f"connection closed, buffer={buffer[0]!r}")
        buffer[0] += chunk
    line, _, rest = buffer[0].partition(b"\r\n")
    buffer[0] = rest
    return line.decode(errors="replace")


def attempt():
    """One login, one passive `LIST`, and then a `QUIT` -- always a `QUIT`."""
    with socket.create_connection((host, port), 2) as control:
        control.settimeout(3)
        buffer = [b""]

        # No `finally` on the receives below: a `RuntimeError` out of
        # `recv_line` means the server closed the control socket, so there is
        # nothing left to say goodbye to. `QUIT` in a `finally` here would turn
        # a clean rejection into a `ConnectionResetError` out of `sendall`,
        # which would replace the reply this probe exists to print.
        def command(text, expected):
            control.sendall(f"{text}\r\n".encode())
            reply = recv_line(control, buffer)
            if not reply.startswith(expected):
                raise RuntimeError(f"{text.split()[0]} was rejected: {reply!r}")
            return reply

        try:
            banner = recv_line(control, buffer)
            if not banner.startswith("220"):
                raise RuntimeError(f"no 220 banner: {banner!r}")

            command(f"USER {user}", ("331", "230"))
            command(f"PASS {password}", ("230",))

            reply = command("PASV", ("227",))
            match = re.search(r"\((\d+),(\d+),(\d+),(\d+),(\d+),(\d+)\)",
                              reply)
            if match is None:
                raise RuntimeError(f"PASV did not return a host:port: {reply!r}")
            numbers = [int(part) for part in match.groups()]
            data_host = ".".join(str(part) for part in numbers[:4])
            data_port = numbers[4] * 256 + numbers[5]

            # Opened, held, and closed *before* the `150`/`226` are read back:
            # a data connection that closes before its `226` lets vsftpd give
            # the slot to the next PASV, which is the property that keeps this
            # probe repeatable. (`LIST` never raises on a connection refused
            # here, so it needs no wrapper of its own.)
            with socket.create_connection((data_host, data_port), 3):
                command("LIST", ("125", "150"))
            reply = recv_line(control, buffer)
            if not reply.startswith("226"):
                raise RuntimeError(f"LIST never completed: {reply!r}")
        finally:
            # Close the *session*, not just the socket. Skipping this leaves one
            # data-channel slot held per probe call (see the module doc), and
            # with `ensure-ftp.sh` in front of every plaintext client that is a
            # leak the next client pays for.
            pass


while time.time() < deadline:
    attempts += 1
    try:
        attempt()
        if attempts > 1:
            print(f"  control + passive login succeeded on attempt {attempts}")
        sys.exit(0)
    except Exception as exc:  # noqa: BLE001 - any failure here is retryable
        last_error = exc
        time.sleep(0.5)

print(
    f"gave up after {attempts} attempts, last error: {last_error}",
    file=sys.stderr,
)
sys.exit(1)

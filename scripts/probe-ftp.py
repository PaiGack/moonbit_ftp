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
    with socket.create_connection((host, port), 2) as control:
        control.settimeout(3)
        buffer = [b""]

        banner = recv_line(control, buffer)
        if not banner.startswith("220"):
            raise RuntimeError(f"no 220 banner: {banner!r}")

        for command, expected in ((f"USER {user}", ("331", "230")),
                                  (f"PASS {password}", ("230",))):
            control.sendall(f"{command}\r\n".encode())
            reply = recv_line(control, buffer)
            if not reply.startswith(expected):
                raise RuntimeError(
                    f"{command.split()[0]} was rejected: {reply!r}"
                )

        control.sendall(b"PASV\r\n")
        reply = recv_line(control, buffer)
        match = re.search(r"\((\d+),(\d+),(\d+),(\d+),(\d+),(\d+)\)", reply)
        if not reply.startswith("227") or match is None:
            raise RuntimeError(f"PASV did not return a host:port: {reply!r}")
        numbers = [int(part) for part in match.groups()]
        data_host = ".".join(str(part) for part in numbers[:4])
        data_port = numbers[4] * 256 + numbers[5]

        with socket.create_connection((data_host, data_port), 3):
            control.sendall(b"LIST\r\n")
            reply = recv_line(control, buffer)
            if not reply.startswith(("125", "150")):
                raise RuntimeError(f"LIST was not accepted: {reply!r}")
        reply = recv_line(control, buffer)
        if not reply.startswith("226"):
            raise RuntimeError(f"LIST never completed: {reply!r}")

        control.sendall(b"QUIT\r\n")


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

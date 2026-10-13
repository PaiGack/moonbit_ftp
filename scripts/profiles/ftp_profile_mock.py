#!/usr/bin/env python3
"""A filesystem-backed FTP mock, so `cmd/profiles` can be driven without Docker.

Usage: ftp_profile_mock.py HOST PORT ROOT

`cmd/profiles` is the four-capability-profile end-to-end test. Its whole value
is that each profile is judged by *effects on the server* -- the file it
uploaded is listed with the right size, `NLST` names it, the timestamp it wrote
is the timestamp that comes back, the recursive delete really removed the tree.
A mock that answers with canned replies cannot judge any of that, and a mock
that only speaks the happy path cannot exercise `no-time`, whose assertion is a
refusal.

So this one keeps a real directory for the FTP root and answers the slice of
FTP the program uses against it:

  USER / PASS / FEAT / TYPE / OPTS / PWD / CWD / CDUP / PASV / EPSV / PRET /
  MLSD / LIST / NLST / RETR / STOR / SIZE / MDTM / MKD / RMD / DELE / QUIT

Shortcomings, all deliberate and all in the direction of being *stricter* than
vsftpd where the profiles care:

  * `FEAT` advertises exactly what a stock vsftpd 3.0.5 on Alpine does --
    `MLST`, `MDTM`, `SIZE`, `UTF8`, `EPSV`, ... but **not** `MFMT`, which is
    the fact that makes the `no-time` profile reach the "no way to write a
    timestamp" path at all.
  * `RMD` on a non-empty directory is refused with `550`, and `STOR`/`MKD` do
    not create parent directories. The profile asserts both.
  * `MDTM <time> <path>` on a file sets the mtime; a bare `MDTM <path>` reads
    it. Only the `writing_mdtm` profile sends the two-argument form.
  * `EPSV` is answered normally. `no-epsv` is a *client* switch, so the server
    has to be able to do both for the profile to mean anything.

One control connection per socket, one data connection per passive command on
a fresh ephemeral port -- which is what `PASV` / `EPSV` are for.
"""

import argparse
import os
import re
import socket
import threading
import time
from datetime import datetime, timezone

# What a stock vsftpd 3.0.5 announces. `MFMT` is conspicuously absent: that is
# what makes `no-time` reachable, and it is true of the real image too.
FEATURES = [
    "MDTM",
    "MLST type*;size*;modify*;",
    "REST STREAM",
    "SIZE",
    "EPRT",
    "EPSV",
    "PASV",
    "TVFS",
    "UTF8",
]


def send(control, text):
    control.sendall((text + "\r\n").encode())


def reply(control, code, text):
    send(control, f"{code} {text}")


def remote_to_local(root, path):
    """Map a remote path onto the mock's root, refusing traversal."""
    normalized = os.path.normpath("/" + (path or "/").lstrip("/"))
    local = os.path.normpath(os.path.join(root, normalized.lstrip("/")))
    if local != root and not local.startswith(root + os.sep):
        raise PermissionError("outside the FTP root")
    return local


def list_line(name, path, stat_result, now):
    """One `ls -l` line, the shape `LIST` uses (no MLST facts)."""
    kind = "d" if os.path.isdir(path) else "-"
    mtime = time.gmtime(stat_result.st_mtime)
    if abs(stat_result.st_mtime - now) > 180 * 24 * 3600:
        stamp = f"{time.strftime('%b', mtime)} {mtime.tm_mday:2d}  {mtime.tm_year}"
    else:
        stamp = time.strftime("%b %d %H:%M", mtime)
    return (
        f"{kind}rw-r--r--    1 0        0 {stat_result.st_size:12d} "
        f"{stamp} {name}"
    )


def mlsd_line(name, path, stat_result):
    """One RFC 3659 fact line, at second precision like vsftpd's."""
    kind = "dir" if os.path.isdir(path) else "file"
    stamp = datetime.fromtimestamp(stat_result.st_mtime, timezone.utc)
    return (
        f"type={kind};size={stat_result.st_size};"
        f"modify={stamp.strftime('%Y%m%d%H%M%S')}; {name}"
    )


class Session:
    """One control connection, from banner to `QUIT`."""

    def __init__(self, root):
        self.root = root
        self.cwd = "/"
        self.data_listener = None
        self.rest = 0

    # -- plumbing ---------------------------------------------------------
    def readline(self, control, buffer):
        while b"\r\n" not in buffer[0]:
            chunk = control.recv(4096)
            if not chunk:
                return None
            buffer[0] += chunk
        line, _, rest = buffer[0].partition(b"\r\n")
        buffer[0] = rest
        return line.decode(errors="replace")

    def open_listener(self):
        if self.data_listener is not None:
            self.data_listener.close()
        listener = socket.socket()
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind(("127.0.0.1", 0))
        listener.listen(1)
        listener.settimeout(10)
        self.data_listener = listener
        return listener.getsockname()[1]

    def transfer(self, control, writer, final="226 transfer complete"):
        send(control, "150 opening data connection")
        try:
            data, _ = self.data_listener.accept()
        except (socket.timeout, TimeoutError, OSError):
            reply(control, 425, "cannot open data connection")
            return
        try:
            writer(data)
            data.shutdown(socket.SHUT_WR)
            time.sleep(0.05)
        except OSError:
            pass
        finally:
            data.close()
        reply(control, final.split(" ")[0], " ".join(final.split(" ")[1:]))

    def path_of(self, argument):
        if argument.startswith("/"):
            return argument
        base = self.cwd.rstrip("/")
        return f"{base}/{argument}"

    def local(self, argument):
        return remote_to_local(self.root, self.path_of(argument))

    # -- commands ---------------------------------------------------------
    def run(self, control):
        send(control, "220 mock ready")
        buffer = [b""]
        while True:
            line = self.readline(control, buffer)
            if line is None:
                return
            command, _, argument = line.partition(" ")
            command = command.upper()
            print(f"CMD {line}", flush=True)
            if not self.handle(control, command, argument):
                return

    def handle(self, control, command, argument):
        if command == "USER":
            reply(control, 331, "need password")
        elif command == "PASS":
            reply(control, 230, "logged in")
        elif command == "FEAT":
            send(control, "211-Features:")
            for feature in FEATURES:
                send(control, f" {feature}")
            send(control, "211 End")
        elif command == "TYPE":
            reply(control, 200, "type set")
        elif command == "OPTS":
            reply(control, 200, "ok")
        elif command == "PWD":
            reply(control, 257, f'"{self.cwd}" is current')
        elif command == "CWD":
            target = self.local(argument)
            if os.path.isdir(target):
                self.cwd = self.path_of(argument)
                reply(control, 250, "cwd ok")
            else:
                reply(control, 550, "no such directory")
        elif command == "CDUP":
            self.cwd = os.path.dirname(self.cwd.rstrip("/")) or "/"
            reply(control, 250, "cdup ok")
        elif command == "PASV":
            port = self.open_listener()
            reply(
                control, 227,
                f"Entering Passive Mode (127,0,0,1,{port // 256},{port % 256})",
            )
        elif command == "EPSV":
            port = self.open_listener()
            reply(control, 229, f"Entering Extended Passive Mode (|||{port}|)")
        elif command == "PRET":
            reply(control, 200, "ok")
        elif command == "MLSD":
            self.do_listing(control, argument, facts=True)
        elif command == "LIST":
            self.do_listing(control, argument, facts=False)
        elif command == "NLST":
            self.do_nlst(control, argument)
        elif command == "RETR":
            self.do_retr(control, argument)
        elif command == "STOR":
            self.do_stor(control, argument)
        elif command == "SIZE":
            target = self.local(argument)
            if os.path.isfile(target):
                reply(control, 213, str(os.path.getsize(target)))
            else:
                reply(control, 550, "not a regular file")
        elif command == "MDTM":
            self.do_mdtm(control, argument)
        elif command == "MKD":
            target = self.local(argument)
            if os.path.exists(target):
                reply(control, 550, "already exists")
            else:
                try:
                    os.makedirs(target, exist_ok=False)
                    reply(control, 257, f'"{self.path_of(argument)}" created')
                except OSError:
                    reply(control, 550, "cannot create directory")
        elif command == "RMD":
            self.do_rmd(control, argument)
        elif command == "DELE":
            target = self.local(argument)
            if os.path.isfile(target):
                os.remove(target)
                reply(control, 250, "deleted")
            else:
                reply(control, 550, "no such file")
        elif command == "QUIT":
            reply(control, 221, "bye")
            return False
        else:
            reply(control, 200, "ok")
        return True

    def do_listing(self, control, argument, facts):
        target = self.local(argument)
        if os.path.isfile(target):
            names = [os.path.basename(target)]
            parent = os.path.dirname(target)
        elif os.path.isdir(target):
            names = sorted(os.listdir(target))
            parent = target
        else:
            reply(control, 550, "not a directory")
            return
        lines = []
        for name in names:
            full = os.path.join(parent, name)
            stat_result = os.stat(full)
            if facts:
                lines.append(mlsd_line(name, full, stat_result))
            else:
                lines.append(
                    list_line(name, full, stat_result, time.time())
                )
        body = ("\r\n".join(lines) + "\r\n").encode()
        self.transfer(control, lambda data: data.sendall(body))

    def do_nlst(self, control, argument):
        target = self.local(argument)
        if os.path.isfile(target):
            names = [os.path.basename(target)]
        elif os.path.isdir(target):
            names = sorted(os.listdir(target))
        else:
            reply(control, 550, "not a directory")
            return
        body = ("\r\n".join(names) + "\r\n").encode()
        self.transfer(control, lambda data: data.sendall(body))

    def do_retr(self, control, argument):
        target = self.local(argument)
        if not os.path.isfile(target):
            reply(control, 550, "no such file")
            return
        with open(target, "rb") as handle:
            handle.seek(self.rest)
            self.rest = 0
            body = handle.read()
        self.transfer(control, lambda data: data.sendall(body))

    def do_stor(self, control, argument):
        target = self.local(argument)
        if not os.path.isdir(os.path.dirname(target)):
            reply(control, 550, "no such directory")
            return
        received = []

        def drain(data):
            while True:
                chunk = data.recv(65536)
                if not chunk:
                    return
                received.append(chunk)

        self.transfer(control, drain, final="226 stored")
        with open(target, "wb") as handle:
            handle.write(b"".join(received))

    def do_rmd(self, control, argument):
        target = self.local(argument)
        if not os.path.isdir(target):
            reply(control, 550, "no such directory")
        elif os.listdir(target):
            # Non-empty: this is the guard `remove_dir_recur` exists for, so
            # the mock keeps it rather than being helpful.
            reply(control, 550, "directory not empty")
        else:
            os.rmdir(target)
            reply(control, 250, "removed")

    def do_mdtm(self, control, argument):
        # `split(None, 1)` and not `split()`: a path is allowed to contain a
        # space, and `split()` would turn one argument into three.
        parts = argument.split(None, 1)
        if len(parts) == 2 and re.fullmatch(r"\d{14}", parts[0]):
            stamp, path = parts
            target = self.local(path)
            if not os.path.isfile(target):
                reply(control, 550, "no such file")
                return
            match = re.fullmatch(
                r"(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})", stamp
            )
            if match is None:
                reply(control, 501, "bad time format")
                return
            when = datetime(
                *[int(part) for part in match.groups()], tzinfo=timezone.utc
            ).timestamp()
            os.utime(target, (when, when))
            reply(control, 213, f"{stamp} {path}")
            return
        target = self.local(argument)
        if not os.path.isfile(target):
            reply(control, 550, "no such file")
            return
        stamp = datetime.fromtimestamp(
            os.path.getmtime(target), timezone.utc
        ).strftime("%Y%m%d%H%M%S")
        reply(control, 213, stamp)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("host")
    parser.add_argument("port", type=int)
    parser.add_argument("root")
    args = parser.parse_args()

    root = os.path.realpath(args.root)
    os.makedirs(root, exist_ok=True)

    server = socket.socket()
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind((args.host, args.port))
    server.listen(8)
    print("mock ready", flush=True)
    while True:
        conn, _ = server.accept()
        threading.Thread(
            target=lambda: Session(root).run(conn), daemon=True
        ).start()


if __name__ == "__main__":
    main()

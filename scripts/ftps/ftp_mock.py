#!/usr/bin/env python3
"""A minimal plaintext FTP server, so `cmd/ftps` can be driven without Docker.

Usage: ftp_mock.py HOST PORT DATA_PORT LIST_REPLY_FILE [--stor-refused]

Speaks exactly the slice of FTP `cmd/ftps` exercises: banner, `USER` / `PASS`,
`FEAT`, `TYPE`, `PWD`, `EPSV` (refused, to force the `PASV` fallback), `PASV`,
`LIST`, `RETR`, `STOR`, `SIZE`, `DELE` and `QUIT`. A single passive listener
serves every transfer, which is what real servers with a one-port-per-transfer
model look like from the client's side.

The point of this file is to be able to run the *real* `cmd/ftps` binary
without Docker, so that a defect that only shows up in the `cmd/ftps` process
itself -- rather than in the library -- can be caught by `scripts/ci.sh` before
any container is pulled. One flag changes the `STOR` outcome because the bug
this guards lives on the failure path: a transfer that the server rejects used
to leave a background task behind and turned the run into a deadlock panic.
"""

import argparse
import socket
import threading
import time


def send(sock, text):
    sock.sendall((text + "\r\n").encode())


class Handler:
    """One control connection, from banner to `QUIT`."""

    def __init__(self, args, conn):
        self.args = args
        self.control = conn
        self.buffer = b""
        self.data_listener = None

    # -- plumbing ---------------------------------------------------------
    def readline(self):
        while b"\r\n" not in self.buffer:
            chunk = self.control.recv(4096)
            if not chunk:
                return None
            self.buffer += chunk
        line, _, rest = self.buffer.partition(b"\r\n")
        self.buffer = rest
        return line.decode(errors="replace")

    def open_data_listener(self):
        """(Re)bind the passive port so every transfer gets a fresh accept."""
        if self.data_listener is not None:
            self.data_listener.close()
        listener = socket.socket()
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind((self.args.host, self.args.data_port))
        listener.listen(1)
        listener.settimeout(10)
        self.data_listener = listener

    def accept_data(self):
        conn, _ = self.data_listener.accept()
        return conn

    # -- one connection ---------------------------------------------------
    def run(self):
        send(self.control, "220 mock ready")
        while True:
            line = self.readline()
            if line is None:
                return
            command, _, argument = line.partition(" ")
            command = command.upper()
            print(f"CMD {line}", flush=True)
            if command == "USER":
                send(self.control, "331 need password")
            elif command == "PASS":
                send(self.control, "230 logged in")
            elif command == "FEAT":
                send(self.control, "211 end")
            elif command == "TYPE":
                send(self.control, "200 type set")
            elif command == "PWD":
                send(self.control, '257 "/" is current')
            elif command == "EPSV":
                # Refused on purpose: `cmd/ftps` must fall back to `PASV`.
                send(self.control, "500 EPSV not supported")
            elif command == "PASV":
                self.open_data_listener()
                port = self.data_listener.getsockname()[1]
                send(
                    self.control,
                    "227 Entering Passive Mode "
                    f"(127,0,0,1,{port // 256},{port % 256})",
                )
            elif command == "LIST":
                body = open(self.args.list_reply, "rb").read()
                self.transfer(lambda data: data.sendall(body))
            elif command == "RETR":
                self.transfer(lambda data: data.sendall(b"hello world\n"))
            elif command == "STOR":
                if self.args.stor_refused:
                    # Answer the transfer command with a failure and never
                    # accept the data connection. The client's `STOR` raises,
                    # so nothing ever drains the reader it was handed -- the
                    # exact shape this test exists for.
                    send(self.control, "550 STOR refused")
                else:
                    self.transfer(lambda data: None, final="226 stored")
            elif command == "SIZE":
                send(self.control, "213 5")
            elif command == "DELE":
                send(self.control, "250 deleted")
            elif command == "QUIT":
                send(self.control, "221 bye")
                return
            else:
                send(self.control, "200 ok")

    def transfer(self, write_payload, final="226 transfer complete"):
        send(self.control, "150 opening data connection")
        try:
            data = self.accept_data()
        except (socket.timeout, TimeoutError, OSError):
            send(self.control, "425 cannot open data connection")
            return
        try:
            write_payload(data)
            # Half close so the client sees EOF, then give it a moment to read
            # the payload before the socket disappears: a bare `close()` can
            # race the client's last read.
            data.shutdown(socket.SHUT_WR)
            time.sleep(0.1)
        except OSError:
            pass
        finally:
            data.close()
        send(self.control, final)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("host")
    parser.add_argument("port", type=int)
    parser.add_argument("data_port", type=int)
    parser.add_argument("list_reply")  # path to a file with the raw LIST body
    parser.add_argument("--stor-refused", action="store_true")
    args = parser.parse_args()

    server = socket.socket()
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind((args.host, args.port))
    server.listen(8)
    print("mock ready", flush=True)
    while True:
        conn, _ = server.accept()
        threading.Thread(
            target=lambda: Handler(args, conn).run(), daemon=True
        ).start()


if __name__ == "__main__":
    main()

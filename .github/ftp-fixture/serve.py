#!/usr/bin/env python3
"""Start a pyftpdlib FTP server for the integration tests.

The daemon is deliberately small: it exposes one user, a fixed root directory
and a fixed passive port range, so both CI and the CNB cloud dev environment
can start the *same* server and the tests can rely on the same addresses.

    python3 .github/ftp-fixture/serve.py --root /path/to/root --port 2121

Root layout expected by `ftp_server_test.mbt`:

    <root>/fixture/hello.txt     committed fixture, 12 bytes "hello world\\n"
    <root>/fixture/sub/          committed fixture directory
    <root>/upload/               writable, created on demand

Passive ports are pinned to a small range because the tests connect back to the
server for every transfer; a random port would be unreachable behind the
container network of CNB.
"""

from __future__ import annotations

import argparse
import logging
import sys

from pyftpdlib.authorizers import DummyAuthorizer
from pyftpdlib.handlers import FTPHandler
from pyftpdlib.servers import FTPServer


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True, help="directory served to the user")
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=2121)
    parser.add_argument("--user", default="test")
    parser.add_argument("--passwd", dest="passwd", default="test")
    parser.add_argument("--pasv-min", type=int, default=30000)
    parser.add_argument("--pasv-max", type=int, default=30009)
    # The address advertised in PASV/EPRT replies. Loopback is right for a
    # local daemon; a container needs its own reachable address here.
    parser.add_argument("--pasv-address", default="127.0.0.1")
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
    )

    authorizer = DummyAuthorizer()
    # `e` change dir, `l` list, `r` retrieve, `a` append, `d` delete,
    # `f` rename, `m` mkdir, `w` store, `M` chmod, `T` set mtime (MFMT).
    authorizer.add_user(
        args.user, args.passwd, args.root, perm="elradfmwMT"
    )

    handler = FTPHandler
    handler.authorizer = authorizer
    handler.passive_ports = range(args.pasv_min, args.pasv_max + 1)
    handler.masquerade_address = args.pasv_address
    # The tests run on loopback, but a containerised runner may present a
    # different source address on the data connection than on the control one.
    handler.permit_foreign_addresses = True

    server = FTPServer((args.host, args.port), handler)
    print(
        f"pyftpdlib serving {args.root} on {args.host}:{args.port} "
        f"(user {args.user}, passive {args.pasv_min}-{args.pasv_max})",
        flush=True,
    )
    server.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())

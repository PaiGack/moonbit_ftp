#!/usr/bin/env bash
# Re-verify the plaintext vsftpd container before a client that depends on it.
#
#   scripts/ensure-ftp.sh
#
# `scripts/start-ftp.sh` proves the container healthy once, at the start of the
# plaintext block. The `plain` leg of `cmd/ftps/run.sh` runs much later -- after
# the whole FTPS block, which pulls an image, mints a CA and completes a second
# handshake, i.e. twenty-odd seconds and one `docker run` in between. On CNB's
# DinD the `jmoyer/vsftpd` container can be gone by then, and the only thing the
# client says is:
#
#     ==> plain: dial 127.0.0.1:21
#     OSError("@socket.Tcp::connect(): Connection refused")
#
# which names the port, not the container, and reads like a client or a TLS
# regression even though `cmd/example`, `cmd/ftp` and `cmd/profiles` had just
# passed against the very same endpoint.
#
# A container that is stopped, exited, or simply no longer answering its own
# readiness probe is therefore *restarted* here rather than reported. The demo
# needs a live server, not a particular process id, and `start-ftp.sh` already
# rebuilds its private fixture copy from the checked-in one, so a restarted
# container is indistinguishable from a fresh one.
#
# When the restart cannot produce a healthy server the function fails with the
# container's own log, because at that point the fault *is* the server.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
: "${FTP_USER:=test}"
: "${FTP_PASS:=test}"
: "${FTP_PORT:=21}"
# A confirmation, not a cold start: a server that needs the starter's full
# `PROBE_TIMEOUT` (60s) to answer a login is already a failure here.
: "${RECHECK_TIMEOUT:=20}"

NAME="moonbit-ftp-example"

# `docker ps -q` lists *running* containers only, which is the whole question:
# a stopped one has no port published and answers nothing.
running() {
  [ -n "$(docker ps -q --filter "name=^${NAME}$" 2>/dev/null)" ]
}

# The same login + passive LIST the starter gates on. A running container is not
# enough: vsftpd's control channel and its passive listeners are separate, and
# the half that breaks is the one a bare connect never touches. probe-ftp.py
# takes its deadline as an argument, and `RECHECK_TIMEOUT` is deliberately
# shorter than the starter's own.
#
# The probe ends every session with a `QUIT`, which is what makes calling it
# before each client safe: vsftpd keeps one data-channel slot per login until
# the client says goodbye, and a probe that only closed its socket would hold
# one of them per call -- so the guard would be the thing that starves the
# client it guards. `probe-ftp-selftest.py` counts the `QUIT`s against a mock,
# because a real server is up and answers either way.
healthy() {
  python3 "$SCRIPT_DIR/probe-ftp.py" \
    "127.0.0.1" "$FTP_PORT" "$FTP_USER" "$FTP_PASS" "$RECHECK_TIMEOUT" \
    >/dev/null 2>&1
}

if running && healthy; then
  exit 0
fi

if running; then
  echo "ensure-ftp.sh: $NAME is running but did not answer a login + passive" \
    "LIST on 127.0.0.1:$FTP_PORT; restarting it." >&2
else
  echo "ensure-ftp.sh: $NAME is not running any more; restarting it." >&2
fi

# `start-ftp.sh` clears both a leftover container and a stale fixture copy, so
# this is a clean start and not a re-entry into a half-dead one.
if ! "$SCRIPT_DIR/start-ftp.sh"; then
  echo "ensure-ftp.sh: $NAME could not be restarted." >&2
  docker logs "$NAME" >&2 2>/dev/null || true
  exit 1
fi

# And the restart has to hold. A container that dies again within the probe is
# the `run-vsftpd.sh` fd-0 failure, which `vsftpd-env-selftest.py` guards the
# variable list for; here it is just a fact about the server.
if ! running || ! healthy; then
  echo "ensure-ftp.sh: $NAME is still not answering after a restart." >&2
  docker logs "$NAME" >&2 2>/dev/null || true
  exit 1
fi

echo "ensure-ftp.sh: $NAME is healthy on 127.0.0.1:$FTP_PORT"

#!/usr/bin/env bash
# Start a single vsftpd container for `cmd/example` / `cmd/ftp` to connect to.
# One container, control port + PASV range published onto 127.0.0.1, testdata
# mounted as the FTP root.
set -euo pipefail

: "${FTP_IMAGE:=jmoyer/vsftpd:latest}"
: "${FTP_USER:=test}"
: "${FTP_PASS:=test}"
: "${PASV_MIN_PORT:=30000}"
: "${PASV_MAX_PORT:=30099}"
: "${PROBE_TIMEOUT:=60}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FIXTURE="$ROOT/testdata/ftp/fixture"

NAME="moonbit-ftp-example"
PORT=21

# Drop any leftover container with the same name.
if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$NAME"; then
  docker rm -f "$NAME" >/dev/null 2>&1 || true
fi

# Bridge networking with explicit port publishing, *not* `--network host`.
#
# CNB runs the `docker` service as a DinD sidecar: the daemon lives in its own
# container, so `--network host` there means "the DinD container's namespace",
# which the build container does not reach. Only ports published with `-p` show
# up as 127.0.0.1 inside the build container, through the daemon's port proxy.
#
# Publishing the control port alone is not enough, and that is the trap: FTP
# uses a *second* connection for every transfer. With the PASV range
# unpublished the login and `PWD` succeed and the first `LIST` dies with
# `@socket.Tcp::connect(): Connection refused`, which reads like a client bug
# rather than a container that is only half reachable. Both ranges are
# published here for that reason.
#
# `-p` is also the portable choice: rootless Docker cannot share the host
# network namespace either, and on GitHub Actions it makes the runner's
# behaviour independent of how its daemon is configured.
#
# PASV_ADDRESS=127.0.0.1 pins the advertised data-channel IP to loopback (the
# image otherwise autodetects the gateway IP, which a client dialling
# 127.0.0.1 cannot reach).
docker run -d --rm \
  --name "$NAME" \
  -p "127.0.0.1:$PORT:21" \
  -p "127.0.0.1:$PASV_MIN_PORT-$PASV_MAX_PORT:$PASV_MIN_PORT-$PASV_MAX_PORT" \
  -e FTP_USER="$FTP_USER" \
  -e FTP_PASS="$FTP_PASS" \
  -e PASV_ADDRESS=127.0.0.1 \
  -e PASV_MIN_PORT="$PASV_MIN_PORT" \
  -e PASV_MAX_PORT="$PASV_MAX_PORT" \
  -v "$FIXTURE:/home/vsftpd/$FTP_USER" \
  "$FTP_IMAGE" >/dev/null

# Readiness: a full login *plus* a passive `LIST`, retried until PROBE_TIMEOUT.
# A bare connect only proves something accepted the control port; it says
# nothing about the data channel, which is exactly the half that breaks when
# the PASV range is not published. See scripts/probe-ftp.py.
if ! python3 "$SCRIPT_DIR/probe-ftp.py" \
  "127.0.0.1" "$PORT" "$FTP_USER" "$FTP_PASS" "$PROBE_TIMEOUT"; then
  echo "start-ftp.sh: $NAME did not answer a login + passive LIST" \
    "on 127.0.0.1:$PORT within ${PROBE_TIMEOUT}s" >&2
  docker logs "$NAME" >&2 || true
  exit 1
fi

echo "start-ftp.sh: $NAME ready on 127.0.0.1:$PORT" \
  "(control + passive $PASV_MIN_PORT-$PASV_MAX_PORT, user $FTP_USER)"

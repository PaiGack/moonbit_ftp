#!/usr/bin/env bash
# Start a single vsftpd container for `cmd/example` to connect to.
# One container, control port + PASV range mapped onto 127.0.0.1, testdata
# mounted as the FTP root.
set -euo pipefail

: "${FTP_IMAGE:=jmoyer/vsftpd:latest}"
: "${FTP_USER:=test}"
: "${FTP_PASS:=test}"
: "${PASV_MIN_PORT:=30000}"
: "${PASV_MAX_PORT:=30099}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FIXTURE="$ROOT/testdata/ftp/fixture"

NAME="moonbit-ftp-example"
PORT=2121

# Drop any leftover container with the same name.
if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$NAME"; then
  docker rm -f "$NAME" >/dev/null 2>&1 || true
fi

# Bridge networking with explicit port mappings is more portable than
# --network host: rootless Docker cannot share the host's network namespace,
# and even non-rootless setups fall back to bridge when the user namespace
# differs. PASV_ADDRESS=127.0.0.1 fixes the advertised PASV IP to loopback
# (the image otherwise autodetects the gateway IP, which isn't reachable
# from the client connecting via 127.0.0.1).
docker run -d --rm \
  --name "$NAME" \
  -p 127.0.0.1:$PORT:21 \
  -p 127.0.0.1:$PASV_MIN_PORT-$PASV_MAX_PORT:$PASV_MIN_PORT-$PASV_MAX_PORT \
  -e FTP_USER="$FTP_USER" \
  -e FTP_PASS="$FTP_PASS" \
  -e PASV_ADDRESS=127.0.0.1 \
  -e PASV_MIN_PORT="$PASV_MIN_PORT" \
  -e PASV_MAX_PORT="$PASV_MAX_PORT" \
  -v "$FIXTURE:/home/vsftpd/$FTP_USER" \
  "$FTP_IMAGE" >/dev/null

# Poll the control port.
for _ in $(seq 1 30); do
  if (echo > "/dev/tcp/127.0.0.1/$PORT") >/dev/null 2>&1; then
    echo "start-ftp.sh: $NAME ready on 127.0.0.1:$PORT"
    exit 0
  fi
  sleep 1
done

echo "start-ftp.sh: $NAME did not come up on port $PORT in 30s" >&2
docker logs "$NAME" >&2 || true
exit 1

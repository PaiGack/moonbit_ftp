#!/usr/bin/env bash
# Start a single vsftpd container for `cmd/example` / `cmd/ftp` to connect to.
# One container on the host network (no -p port mappings), control port 21 and
# the PASV range bound directly on the host, testdata mounted as the FTP root.
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
PORT=21

# Drop any leftover container with the same name.
if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$NAME"; then
  docker rm -f "$NAME" >/dev/null 2>&1 || true
fi

# --network host shares the host's network namespace, so vsftpd listens on
# port 21 (and the PASV range) directly on the host — no -p mappings needed.
# PASV_ADDRESS=127.0.0.1 advertises loopback as the data-channel IP, which is
# what the client reaches when it dials 127.0.0.1.
docker run -d --rm \
  --name "$NAME" \
  --network host \
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

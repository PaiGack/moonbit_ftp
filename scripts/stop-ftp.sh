#!/usr/bin/env bash
# Stop and remove the vsftpd container started by `start-ftp.sh`.
# Never fails: a missing container is fine, this is cleanup.
# Designed to run under `if: always()` so a failed CI run still gets logs.

set +e

NAME="moonbit-ftp-example"

if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$NAME"; then
  echo "---- $NAME logs ----"
  docker logs "$NAME" 2>&1 || true
  echo "---- removing $NAME ----"
  docker rm -f "$NAME" >/dev/null 2>&1 || true
fi

echo "stop-ftp.sh: done"
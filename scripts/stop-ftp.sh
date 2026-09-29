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

# The private fixture copy is scratch, and a root-owned leftover from an
# aborted run is exactly what made the next `STOR` fail with `553`. Removing it
# here means a clean start does not depend on the previous run having finished.
rm -rf "$(cd "$(dirname "$0")/.." && pwd)/.ftp-plain-root" 2>/dev/null || true

echo "stop-ftp.sh: done"

#!/usr/bin/env bash
# Stop the FTPS container started by `scripts/ftps/start-ftps.sh`, dumping its
# logs first so a failure in the smoke test is readable.
#
# Never fails: a missing container is the normal case for cleanup. Designed to
# run under `trap ... EXIT` in `scripts/ci.sh`, so a failed run still gets the
# server's side of the story.
set +e

NAME="moonbit-ftps-explicit"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$NAME"; then
  echo "---- $NAME logs ----"
  docker logs "$NAME" 2>&1 || true
  echo "---- removing $NAME ----"
  docker rm -f "$NAME" >/dev/null 2>&1 || true
fi

rm -f "$ROOT/.ftp-tls.env"

echo "stop-ftps.sh: done"

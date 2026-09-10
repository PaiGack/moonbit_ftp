#!/bin/sh
# Dump the log of every FTP profile container and remove it.
#
# This is the counterpart of scripts/start-ftp.sh and the single place the CNB
# pipeline, the GitHub workflow and the cloud dev environment use to tear the
# test servers down. It never fails the build: a missing container (the script
# ran before a failed start, or twice) is not an error.
#
# Usage:
#   scripts/stop-ftp.sh
#   PROFILES="full" scripts/stop-ftp.sh   # only tear one profile down

set -u

PROFILES="${PROFILES:-full no-mlst no-time no-epsv}"
TAIL_LINES="${TAIL_LINES:-40}"

for profile in $PROFILES; do
  name="moonbit-ftp-$profile"
  echo "===== $name ====="
  docker logs "$name" 2>&1 | tail -n "$TAIL_LINES" || true
  docker rm -f "$name" >/dev/null 2>&1 || true
done

#!/usr/bin/env bash
# Run cmd/profiles against the vsftpd container started by scripts/start-ftp.sh.
#
# The four capability profiles run in sequence, each on its own connection, so
# a failure names the profile it happened in.
#
# Usage:
#   scripts/start-ftp.sh
#   cmd/profiles/run.sh
#   scripts/stop-ftp.sh
#
# No wrapper-owned configuration file. The endpoint comes from
# `FTP_TEST_HOST` / `FTP_TEST_PORT` / `FTP_TEST_USER` / `FTP_TEST_PASS`, which
# this script only *defaults* and exports; `cmd/profiles` reads the four
# variables itself and treats a missing one as a hard failure. A `.env` copy of
# them used to sit next to this script, which meant the values it documented and
# the values the binary needed could disagree -- it is gone for the same reason
# `cmd/ftp/run.sh` no longer has one: one reader, no middle layer that can hold
# an empty value.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

export FTP_TEST_HOST="${FTP_TEST_HOST:-127.0.0.1}"
export FTP_TEST_PORT="${FTP_TEST_PORT:-21}"
export FTP_TEST_USER="${FTP_TEST_USER:-test}"
export FTP_TEST_PASS="${FTP_TEST_PASS:-test}"

# Build/run from the repo root so `moon run cmd/profiles` resolves the package.
cd "$SCRIPT_DIR/../.."
exec moon run cmd/profiles --target native

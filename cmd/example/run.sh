#!/usr/bin/env bash
# Run cmd/example against the vsftpd container started by scripts/start-ftp.sh.
#
# Usage:
#   scripts/start-ftp.sh
#   cmd/example/run.sh
#   scripts/stop-ftp.sh
#
# A plain wrapper with no configuration of its own. It used to copy
# `.env.example` to `.env` and source that, which was pure indirection: the
# program reads `FTP_TEST_HOST` / `FTP_TEST_PORT` / `FTP_TEST_USER` /
# `FTP_TEST_PASS` itself and already defaults each one
# (`env_string(...).unwrap_or(...)` in `cmd/example/main.mbt`), so the file
# could only ever restate the built-in defaults. Removing it removes the same
# window `cmd/ftp/run.sh` had: a `.env` that the script creates and then
# sources is a file that can be missing at exactly the moment it is read.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Build/run from the repo root so `moon run cmd/example` resolves the package.
cd "$SCRIPT_DIR/../.."
exec moon run cmd/example --target native

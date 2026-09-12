#!/usr/bin/env bash
# Run cmd/example against the vsftpd container started by scripts/start-ftp.sh.
#
# Reads configuration from a .env file (auto-created from .env.example) and
# exports it to the child process. Takes no arguments: the server address, the
# credentials and the moon invocation are fixed here so the same command works
# locally and in CI.
#
# Usage:
#   scripts/start-ftp.sh
#   cmd/example/run.sh
#   scripts/stop-ftp.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# First run: copy the template so local overrides persist in .env.
if [ ! -f "$SCRIPT_DIR/.env" ]; then
  cp "$SCRIPT_DIR/.env.example" "$SCRIPT_DIR/.env"
fi

# Load variables and export them to the child process.
set -a
# shellcheck disable=SC1091
. "$SCRIPT_DIR/.env"
set +a

# Build/run from the repo root so `moon run cmd/example` resolves the package.
cd "$SCRIPT_DIR/../.."
exec moon run cmd/example --target native

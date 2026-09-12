#!/usr/bin/env bash
# Run cmd/example against the vsftpd container started by scripts/start-ftp.sh.
#
# Reads configuration from a .env file (auto-created from .env.example) and
# exports it to the child process. Extra arguments are forwarded to
# `moon run cmd/example`, so CI can pin the target explicitly.
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
moon run cmd/example "$@"

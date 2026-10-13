#!/usr/bin/env bash
# Run cmd/profiles against the vsftpd container started by scripts/start-ftp.sh.
#
# The four capability profiles run in sequence, each on its own connection, so
# a failure names the profile it happened in. Configuration comes from a .env
# file (auto-created from .env.example) and is exported to the child process.
#
# Usage:
#   scripts/start-ftp.sh
#   cmd/profiles/run.sh
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

# Build/run from the repo root so `moon run cmd/profiles` resolves the package.
cd "$SCRIPT_DIR/../.."
moon run cmd/profiles --target native

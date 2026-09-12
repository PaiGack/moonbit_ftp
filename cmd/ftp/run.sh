#!/usr/bin/env bash
# Run cmd/ftp against the vsftpd container started by scripts/start-ftp.sh.
# Reads configuration from a .env file (auto-created from .env.example) and
# forwards it to cmd/ftp as CLI flags.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# First run: copy the template so local overrides persist in .env.
if [ ! -f "$SCRIPT_DIR/.env" ]; then
  cp "$SCRIPT_DIR/.env.example" "$SCRIPT_DIR/.env"
fi

# Load variables. FTP_COMMAND is split into words below; the rest are passed
# verbatim as flags.
set -a
# shellcheck disable=SC1091
. "$SCRIPT_DIR/.env"
set +a

# Build/run from the repo root so `moon run cmd/ftp` resolves the package.
cd "$SCRIPT_DIR/../.."

# Extra args on the command line replace $FTP_COMMAND.
if [ "$#" -gt 0 ]; then
  cmd_args=("$@")
else
  # shellcheck disable=SC2206
  cmd_args=($FTP_COMMAND)
fi

moon run cmd/ftp --target native -- \
  --host "$FTP_HOST" \
  --port "$FTP_PORT" \
  --user "$FTP_USER" \
  --pass "$FTP_PASS" \
  --timeout "$FTP_TIMEOUT" \
  "${cmd_args[@]}"

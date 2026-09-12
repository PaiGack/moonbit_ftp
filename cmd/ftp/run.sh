#!/usr/bin/env bash
# Run cmd/ftp against the vsftpd container started by scripts/start-ftp.sh.
#
# Reads configuration from a .env file (auto-created from .env.example) and
# forwards it to cmd/ftp as CLI flags. Arguments are passed straight through to
# cmd/ftp; with none, the default command from .env runs, so the script works as
# a no-argument smoke test in CI and as `cmd/ftp/run.sh ls /x` locally.
#
# Usage:
#   scripts/start-ftp.sh
#   cmd/ftp/run.sh                  # default command from .env
#   cmd/ftp/run.sh ls /sub          # explicit subcommand, overrides .env
#   scripts/stop-ftp.sh
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

# Explicit argv wins; otherwise fall back to the command configured in .env so
# the script stays runnable with no arguments.
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

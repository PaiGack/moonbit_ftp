#!/usr/bin/env bash
# Run cmd/ftps against the containers started by the two starters.
#
# Usage:
#   scripts/start-ftp.sh                # plain vsftpd, 127.0.0.1:21
#   scripts/ftps/start-ftps.sh          # FTPS vsftpd,  127.0.0.1:2121
#   cmd/ftps/run.sh                     # explicit AUTH TLS (default)
#   cmd/ftps/run.sh plain               # no TLS, against the plain container
#   scripts/stop-ftp.sh && scripts/ftps/stop-ftps.sh
#
# The mode argument is passed straight through to cmd/ftps, which owns the
# decision of which transport to speak. The FTPS endpoint (host, port, CA) comes
# from `.ftp-tls.env`, written by `scripts/ftps/start-ftps.sh`; the plain
# endpoint shares the same host and credentials, and its port is whatever
# `FTP_PLAIN_PORT` says (default 21).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR/../.."
ENV_FILE="$ROOT/.ftp-tls.env"

if [ ! -f "$ENV_FILE" ]; then
  echo "cmd/ftps/run.sh: $ENV_FILE is missing - run scripts/ftps/start-ftps.sh first" >&2
  exit 1
fi

# shellcheck disable=SC1090
set -a
. "$ENV_FILE"
set +a

export FTP_TLS_HOST="${FTP_TLS_HOST:-127.0.0.1}"
export FTP_TLS_USER="${FTP_TLS_USER:-test}"
export FTP_TLS_PASS="${FTP_TLS_PASS:-test}"
export FTP_PLAIN_PORT="${FTP_PLAIN_PORT:-21}"

cd "$ROOT"
moon run cmd/ftps --target native -- "$@"

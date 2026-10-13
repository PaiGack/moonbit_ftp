#!/usr/bin/env bash
# Run cmd/ftp against the vsftpd container started by scripts/start-ftp.sh.
#
# A thin wrapper: it sets the container's endpoint as *default* environment and
# forwards every argument straight through to cmd/ftp. It does not parse
# anything, which is the point -- see "Why this is not a flag builder" below.
#
# Usage:
#   scripts/start-ftp.sh
#   cmd/ftp/run.sh                  # no arguments: prints the CLI's usage
#   cmd/ftp/run.sh ls /sub          # any subcommand, forwarded verbatim
#   scripts/stop-ftp.sh
#
# `FTP_COMMAND` used to be *shell-parsed* here (`cmd_args=($FTP_COMMAND)`) to
# give "no arguments" a default subcommand. That is gone: a default subcommand
# belongs in the CLI's own argument handling, and a shell splitting a
# user-supplied string into argv is a second, worse parser for the same job.
# With no arguments the CLI prints its usage, which is what a wrapper whose
# contract is "forward argv" should do.
#
# Why this is not a flag builder
# ------------------------------
# This script used to build `--host "$FTP_HOST" --port "$FTP_PORT" ...` from a
# sourced `.env`. That shape is a footgun: a flag's *value* is a separate argv
# entry, so an unset variable hands the *next* argv entry to `--host` as its
# value, and a bare expansion that survives becomes a positional argument the
# CLI rejects as a usage error on input nobody typed. Neither failure names the
# environment it came from.
#
# `.env` made that worse by being optional in the wrong direction: the file is
# created by `[ ! -f .env ] && cp .env.example .env` at the top of this very
# script, so the run in which the copy does not land is the run that fails to
# export a single variable.
#
# There is no `.env` any more. The endpoint defaults live in `cmd/ftp/main.mbt`
# (read from `FTP_HOST` / `FTP_PORT` / `FTP_USER` / `FTP_PASS` / `FTP_TIMEOUT`),
# which removes the empty-value window entirely: the environment is either set
# or absent, and absent means "keep the built-in default", never "pass an empty
# argv entry". An explicit flag on the command line still wins.
#
# `scripts/ftps/run.sh`-style `.ftp-tls.env` files are untouched: that one is
# written by `scripts/ftps/start-ftps.sh` for the FTPS endpoint, and
# `cmd/ftps/run.sh` guards on its existence rather than treating it as optional.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Build/run from the repo root so `moon run cmd/ftp` resolves the package.
cd "$SCRIPT_DIR/../.."

exec moon run cmd/ftp --target native -- \
  --host "${FTP_HOST:-127.0.0.1}" \
  --port "${FTP_PORT:-21}" \
  --user "${FTP_USER:-test}" \
  --pass "${FTP_PASS:-test}" \
  --timeout "${FTP_TIMEOUT:-15000}" \
  "$@"

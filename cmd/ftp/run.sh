#!/usr/bin/env bash
# Run cmd/ftp against the vsftpd container started by scripts/start-ftp.sh.
#
# A thin wrapper: it forwards every argument straight through to cmd/ftp and
# owns no configuration of its own. The container's endpoint reaches the CLI
# through `FTP_HOST` / `FTP_PORT` / `FTP_USER` / `FTP_PASS` / `FTP_TIMEOUT`,
# which `cmd/ftp/main.mbt` reads as defaults -- this script neither sets nor
# echoes them. It does not parse anything, which is the point -- see "Why this
# is not a flag builder" below.
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

# The endpoint is *not* passed as flags. `cmd/ftp/main.mbt` reads the four
# connection settings itself, as defaults an explicit flag on the command line
# still overrides, so they reach the CLI through the environment and this
# script forwards nothing but argv.
#
# The environment is *defaulted*, not merely inherited, because CI exports
# none of it: `scripts/ci.sh` starts the container and runs this wrapper, and
# nothing in between sets a single connection variable. Inheriting-only once
# meant the CLI fell through to its built-in `anonymous` default and failed
# `login` -- `error: login failed: PaiGack/ftp.FtpError.ServerError` -- while
# `cmd/example` and `cmd/profiles`, which default `test`/`test` for themselves,
# passed against the same container. The names are `FTP_TEST_*`, the ones those
# two clients and every `scripts/*.sh` helper use, so one exported environment
# configures the whole repo; `cmd/ftp/main.mbt` also still reads the
# unprefixed `FTP_*` names this wrapper used to document, as a second fallback.
#
# Defaulting here, rather than only inside the binary, keeps this wrapper's
# contract the same as `cmd/profiles/run.sh`'s: set defaults, export, exec.
export FTP_TEST_HOST="${FTP_TEST_HOST:-127.0.0.1}"
export FTP_TEST_PORT="${FTP_TEST_PORT:-21}"
export FTP_TEST_USER="${FTP_TEST_USER:-test}"
export FTP_TEST_PASS="${FTP_TEST_PASS:-test}"
exec moon run cmd/ftp --target native -- "$@"

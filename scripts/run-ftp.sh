#!/usr/bin/env bash
# Single entry point for running the CLI (`cmd/ftp`) in CI.
#
# CI runs this through `cmd/ftp/run.sh`; the same wrapper also covers
# `cmd/example` once the required flags are supplied. Keeping one runner means
# the target, the package name and the flag layout live in exactly one place,
# so switching `--target native` (or the package path) is a one-line change
# instead of an edit in every pipeline step.
#
# Usage: scripts/run-ftp.sh [moon run args...] [-- <cmd/ftp flags...>]
#
#   # CLI smoke test, same as `moon run cmd/ftp --target native -- <flags>`
#   scripts/run-ftp.sh --target native -- --host 127.0.0.1 --port 21 ls /
#
#   # Real-server demo, same as `moon run cmd/example --target native`
#   scripts/run-ftp.sh --target native --package cmd/example
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$ROOT"

# Default to the CLI package and the native target, because FTP needs real
# TCP + TLS and `moon.mod` declares `preferred_target = "native"`.
# An explicit `--package` in "$@" wins: both packages here are native-only.
pkg="cmd/ftp"
for arg in "$@"; do
  case "$arg" in
    --package|--package=*|-p) pkg="" ;;
  esac
done

if [ -z "$pkg" ]; then
  exec moon run "$@"
fi

exec moon run "$pkg" --target native "$@"

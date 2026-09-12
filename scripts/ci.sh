#!/usr/bin/env bash
# The single CI entry point. Both pipelines call exactly this script:
#
#   .github/workflows/ci.yml   ->  - run: bash scripts/ci.sh
#   .cnb.yml                   ->  script: bash scripts/ci.sh
#
# so the step list, the tool flags and the FTP server lifecycle live in one
# place instead of being duplicated per provider. Steps mirror the GitHub
# Actions job one-for-one; the container start/stop is always attempted so a
# failed demo still prints the server logs.
set -uo pipefail

# Resolve the repo root from this script's own location, so it works no matter
# which directory the pipeline invokes it from.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

# MoonBit installs into ~/.moon/bin; the CNB image has it on PATH but the
# GitHub runner only adds it via GITHUB_PATH, so add it defensively for both.
export PATH="$HOME/.moon/bin:$PATH"

status=0

step() {
  echo
  echo "===== $* ====="
}

# Run a documented step, remembering failures instead of aborting: a broken
# demo must not hide the later steps, and the exit code still propagates.
run() {
  step "$*"
  if ! "$@"; then
    echo "FAILED: $*" >&2
    status=1
  fi
}

# Always stop the vsftpd container, whatever happened above, and dump its
# logs. `stop-ftp.sh` never fails on a missing container.
cleanup() {
  step "scripts/stop-ftp.sh"
  "$SCRIPT_DIR/stop-ftp.sh" || true
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Toolchain. `moon update` is required in a clean container: without the
# registry index `moon check` fails with "module was not found in the registry".
# ---------------------------------------------------------------------------
run moon version
run moon update

# ---------------------------------------------------------------------------
# check / test / build — the same commands as the GitHub Actions steps.
# ---------------------------------------------------------------------------
run moon fmt --check
run moon check --target native --deny-warn
run moon info
run git diff --exit-code
run git status

run moon test --target native --deny-warn --enable-coverage
run moon coverage report -f summary

run moon build --target native
run moon build --target native --release

run moon run cmd/ftp -- --help

# Code statistics. Best-effort: a registry hiccup must not fail the build.
run docker run --rm -v "$ROOT:/src" ghcr.io/xampprocky/tokei:latest .

# ---------------------------------------------------------------------------
# Real FTP server demo. Both package wrappers take no arguments and talk to
# the container started here, on 127.0.0.1:21.
# ---------------------------------------------------------------------------
run "$SCRIPT_DIR/start-ftp.sh"
run "$ROOT/cmd/example/run.sh"
run "$ROOT/cmd/ftp/run.sh"

exit "$status"

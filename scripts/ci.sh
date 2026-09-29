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
  step "scripts/ftps/stop-ftps.sh"
  "$SCRIPT_DIR/ftps/stop-ftps.sh" || true
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

# ---------------------------------------------------------------------------
# Logic checks that need a server but not a *real* one, so they run before any
# Docker work and cannot be blamed on a flaky image pull.
#
# `probe-ftps.sh` is the readiness gate the whole FTPS block hangs off: when it
# wrongly reports "unhealthy", `start-ftps.sh` fails, `.ftp-tls.env` is never
# written and both `cmd/ftps/run.sh` calls fail after it -- with no hint that
# the gate, not the server, was the problem. That is exactly how a pipeline that
# never actually reached the FTPS assertions still looked like a TLS bug, so
# the gate gets its own test against a mock that answers the same handshake.
# ---------------------------------------------------------------------------
run python3 "$SCRIPT_DIR/ftps/probe-ftps-selftest.py" \
  "$SCRIPT_DIR/ftps/probe-ftps.sh"

# Code statistics. Best-effort: a registry hiccup must not fail the build.
run docker run --rm -v "$ROOT:/src" ghcr.io/xampprocky/tokei:latest .

# ---------------------------------------------------------------------------
# Real FTP server demo, in the clear. Both package wrappers take no arguments
# and talk to the plaintext container started here, on 127.0.0.1:21.
# ---------------------------------------------------------------------------
run "$SCRIPT_DIR/start-ftp.sh"
run "$ROOT/cmd/example/run.sh"
run "$ROOT/cmd/ftp/run.sh"

# ---------------------------------------------------------------------------
# FTPS (explicit AUTH TLS) end-to-end. The plaintext demo above cannot cover
# this: it is the one capability the README advertised whose failure mode is
# "the first read hangs", which no unit test can reach.
#
# A second container runs vsftpd with `force_local_data_ssl=YES`, presenting a
# leaf signed by the CA `scripts/ftps/gen-cert.sh` mints. `cmd/ftps/run.sh`
# reaches it with `trust=CustomPemFile(ca)`, so certificate verification stays
# ON rather than being disabled to make the test pass.
#
# The *same* `cmd/ftps` binary is then run with `plain` against the container
# from the previous block. That is the regression guard for the fix in this
# change: deferring the data-channel handshake must not disturb the plaintext
# ordering, and only running both transports proves it.
# ---------------------------------------------------------------------------
run "$SCRIPT_DIR/ftps/start-ftps.sh"
run "$ROOT/cmd/ftps/run.sh"
run "$ROOT/cmd/ftps/run.sh" plain
run "$SCRIPT_DIR/ftps/stop-ftps.sh"

exit "$status"

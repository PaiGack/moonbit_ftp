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

# Same rule for `cmd/ftps` itself. Its `plain` leg is the only thing that runs
# the smoke test in the clear, and until now the earliest it ran was against a
# real container -- so a defect in the *program* surfaced as a container-log
# dump with no connection to its cause. That is exactly what happened: a
# `MemoryReader` built inline at the `STOR` call site had no owner to close it,
# so a refused `STOR` left its producer task alive and the event loop ended
# with a deadlock panic, naming `cmd/ftps/main.mbt:202` and nothing else.
#
# The mock speaks the same slice of FTP the smoke test uses and binds ephemeral
# ports, so this runs before any image is pulled and cannot be blamed on a
# flaky pull. The refused-`STOR` case is the regression guard.
run python3 "$SCRIPT_DIR/ftps/cmd-ftps-selftest.py" "$ROOT"

# Same rule again for `cmd/profiles`, the four-capability-profile end-to-end
# test. Each profile's claim is about the command the client *chose* -- `LIST`
# instead of `MLSD`, `PASV` instead of `EPSV`, a refused timestamp write
# instead of a silent no-op -- and a real vsftpd serves whatever it is asked
# for, so against the container every one of those claims would look identical
# whether it held or not. The mock keeps a real directory (the program's
# assertions are effect-level) and logs every command, so the transport claims
# can be read off the wire. It runs before any image is pulled.
run python3 "$SCRIPT_DIR/profiles/cmd-profiles-selftest.py" "$ROOT"

# And the cross-container invariant, which no single-container test can see:
# `bfren/ftps` recursively chowns its `/files` bind mount at init, so mounting
# the shared `testdata/ftp/fixture` from both containers silently takes write
# access away from the plaintext one and its `STOR` starts failing with `550`.
# That only shows up once the FTPS container has run, i.e. after `cmd/example`
# has already passed -- which is why it read as an inexplicable `plain` failure.
run python3 "$SCRIPT_DIR/ftps/fixture-isolation-selftest.py" "$ROOT"

# And the plaintext client wrapper's own precondition: `cmd/ftp/run.sh` must
# hand the endpoint over as *environment* values rather than by building
# `--host <value>` from them. A flag whose value is a bare expansion loses its
# argument when the expansion is empty, and the value it was meant to carry
# arrives as a positional argument -- a usage error on input nobody typed, with
# nothing in it about the environment. No image is needed to check that, and the
# wrapper that reads `.env` cannot be trusted to notice the day it does not
# exist.
run python3 "$SCRIPT_DIR/ftp-wrapper-selftest.py" "$ROOT"

# And the plaintext container's own precondition, which no Docker-free test
# below can reach: the `jmoyer/vsftpd` entrypoint interpolates ten environment
# variables into `vsftpd.conf` and dies with the reason on fd 0 -- i.e. in no
# log anyone reads -- when one is missing. Forgetting them made the server
# answer the readiness probe and then vanish, so four later steps failed with
# `Connection refused` while the actual fault was one `docker run` line.
# Checking the variable list here costs nothing and needs no image.
run python3 "$SCRIPT_DIR/vsftpd-env-selftest.py" "$ROOT"

# And the recoverability of that same container once the run has moved on.
# `scripts/ensure-ftp.sh` re-checks it before the last step that needs it and
# restarts it if it is gone; the three outcomes it has -- leave a healthy server
# alone, restart a dead one, fail loudly when the restart does not help -- are
# exactly the ones a real-container run cannot distinguish, because there the
# container is usually up. Its stub `docker` makes all three reachable.
run python3 "$SCRIPT_DIR/ensure-ftp-selftest.py" "$ROOT"

# Code statistics. Best-effort: a registry hiccup must not fail the build.
run docker run --rm -v "$ROOT:/src" ghcr.io/xampprocky/tokei:latest .

# ---------------------------------------------------------------------------
# Real FTP server demo, in the clear. Both package wrappers take no arguments
# and talk to the plaintext container started here, on 127.0.0.1:21.
# ---------------------------------------------------------------------------
run "$SCRIPT_DIR/start-ftp.sh"
run "$ROOT/cmd/example/run.sh"

# `cmd/example` is the first client, so it is also the first chance to notice
# that the server died between `start-ftp.sh`'s probe and here -- and the run
# that produced this line did exactly that, in the *next* step instead:
#
#   ===== cmd/example/run.sh =====   ==> OK
#   ===== cmd/ftp/run.sh =====       error: connect failed: ReaderClosed
#   ===== cmd/profiles/run.sh =====  profile full: Connection reset by peer
#   ===== cmd/ftps/run.sh plain =====  Connection refused
#
# Four steps, four clients, one dead container, and only the last one named
# anything a reader could act on. `cmd/example` passing says nothing about the
# server staying up, so the re-check goes *after* it: it is the earliest point
# where "the container is gone" is a fact about the container rather than a
# guess about a client, and the earliest point at which restarting it saves the
# three steps behind it. See scripts/ensure-ftp.sh for why the check is a login
# + passive LIST and not a bare `docker ps`.
run "$SCRIPT_DIR/ensure-ftp.sh"
run "$ROOT/cmd/ftp/run.sh"

# The four capability profiles, against that *same* container. One server that
# advertises everything, dialled four times with different client options; see
# cmd/profiles/main.mbt for why the profiles are client-side rather than four
# container configurations.
run "$ROOT/cmd/profiles/run.sh"

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

# Re-verify the plaintext container first. `plain` is the last step that needs
# it, and by now it is a full FTPS block -- an image pull, a generated CA, a
# second handshake, one more `docker run` -- away from the probe that declared
# it healthy. On CNB's DinD the `jmoyer/vsftpd` container can be gone by then,
# and the client then reports only `dial 127.0.0.1:21: Connection refused`,
# which names the port rather than the container and looks exactly like a
# plaintext-transport regression. See scripts/ensure-ftp.sh.
run "$SCRIPT_DIR/ensure-ftp.sh"
run "$ROOT/cmd/ftps/run.sh" plain
run "$SCRIPT_DIR/ftps/stop-ftps.sh"

exit "$status"

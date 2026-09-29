#!/usr/bin/env bash
# Prove a running FTPS server completes an explicit `AUTH TLS` handshake with a
# certificate that verifies against `CA`.
#
#   probe-ftps.sh HOST PORT USER PASS CA_FILE TIMEOUT_SECONDS
#
# Readiness gate for `scripts/ftps/start-ftps.sh`. This is the FTPS counterpart
# of `scripts/probe-ftp.py`: a bare TCP connect only proves something accepted
# the control port, and the interesting failures (the daemon not finished
# starting, a missing/incorrect certificate, the image ignoring the mounted
# `/ssl/vsftpd.pem`) all show up only once the TLS handshake is attempted.
#
# The probe deliberately stops at the handshake. What proves the *encrypted data
# channel* -- `PBSZ` / `PROT P`, the passive range, the client-side handshake
# ordering -- is `cmd/ftps/run.sh`, which runs a real dial / login / LIST / RETR
# / STOR round trip against this server. Duplicating that over a shell pipe
# would not be an independent check, so the probe stays a readiness gate and the
# smoke test stays the assertion.
#
# `openssl s_client -starttls ftp` is the shell equivalent of the client's
# `AUTH TLS` upgrade, and `-verify_return_error` turns a bad certificate into a
# non-zero exit instead of a warning -- which is what makes this a real gate
# rather than a "did the port open" test.
#
# The verdict comes from the *transcript*, never from `openssl`'s exit code.
# vsftpd closes the data/control socket after `QUIT` without sending a TLS
# `close_notify`, so `s_client` always exits 1 with
# `ssl3_read_n:unexpected eof while reading` -- after a perfectly good
# `230 Login successful.`. Treating that exit code as the verdict made this
# probe retry a healthy server until the timeout, and report "gave up ... last
# error:" followed by a banner of the *successful* handshake, which is exactly
# the confusing log that sent two earlier rounds hunting for a TLS bug. So:
# capture the output with `|| true`, and let the `230` in the transcript decide.
set -euo pipefail

HOST="${1:?usage: probe-ftps.sh HOST PORT USER PASS CA_FILE TIMEOUT_SECONDS}"
PORT="${2:?}"
USER="${3:?}"
PASS="${4:?}"
CA="${5:?}"
TIMEOUT="${6:?}"

deadline=$((SECONDS + TIMEOUT))
attempts=0
last_out=""

while [ "$SECONDS" -lt "$deadline" ]; do
  attempts=$((attempts + 1))
  # `|| true` is load bearing: see the header. The exit code is not the verdict;
  # the transcript below is. Without this, a successful login is discarded and
  # an idle retry loop burns the whole timeout.
  out="$(
    printf 'USER %s\r\nPASS %s\r\nQUIT\r\n' "$USER" "$PASS" \
      | openssl s_client -starttls ftp -connect "$HOST:$PORT" \
          -servername localhost \
          -verifyCAfile "$CA" -verify_return_error -quiet 2>&1 || true
  )"
  last_out="$out"

  # A completed handshake plus the `220`/`230` replies is the pass. `AUTH TLS`
  # itself was already driven by `-starttls ftp`. A certificate that fails
  # verification never produces the `230`, so `-verify_return_error` is still
  # enforced -- just through the transcript, not through the exit status.
  if printf '%s' "$out" | grep -q '^230 '; then
    if [ "$attempts" -gt 1 ]; then
      echo "  AUTH TLS + login succeeded on attempt $attempts"
    fi
    exit 0
  fi
  sleep 0.5
done

echo "gave up after $attempts attempts." >&2
# Print the whole last transcript, not its tail: the interesting line is often
# the `depth=0 ... verify error` near the top, and truncating it to the last
# line is what made the previous failure unreadable.
printf '%s\n' "$last_out" >&2
exit 1

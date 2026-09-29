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
set -euo pipefail

HOST="${1:?usage: probe-ftps.sh HOST PORT USER PASS CA_FILE TIMEOUT_SECONDS}"
PORT="${2:?}"
USER="${3:?}"
PASS="${4:?}"
CA="${5:?}"
TIMEOUT="${6:?}"

deadline=$((SECONDS + TIMEOUT))
attempts=0
last_error="no attempt was made"

while [ "$SECONDS" -lt "$deadline" ]; do
  attempts=$((attempts + 1))
  if out="$(
    printf 'USER %s\r\nPASS %s\r\nQUIT\r\n' "$USER" "$PASS" \
      | openssl s_client -starttls ftp -connect "$HOST:$PORT" \
          -servername localhost \
          -verifyCAfile "$CA" -verify_return_error -quiet 2>&1
  )"; then
    # A completed handshake plus the `220`/`230` replies is the pass. `AUTH TLS`
    # itself was already driven by `-starttls ftp`.
    if printf '%s' "$out" | grep -q '^230 '; then
      if [ "$attempts" -gt 1 ]; then
        echo "  AUTH TLS + login succeeded on attempt $attempts"
      fi
      exit 0
    fi
    last_error="handshake completed but no 230 reply: $(printf '%s' "$out" | tail -n 1)"
  else
    last_error="$out"
  fi
  sleep 0.5
done

echo "gave up after $attempts attempts, last error: $last_error" >&2
exit 1

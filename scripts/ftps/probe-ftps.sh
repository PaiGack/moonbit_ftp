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
# Two properties of `openssl s_client` are load bearing here, because getting
# either wrong turns this gate into a liar rather than a failure:
#
#   * **It never exits on its own.** `s_client` keeps reading the socket until
#     it sees EOF or an error, and `-starttls ftp` leaves it in a state where
#     the server's `221 Goodbye.` and one `close_notify` do not add up to a
#     clean EOF. Run without a deadline inside a shell loop, and the pipeline
#     never returns: the probe hangs *even when the login succeeded*, and
#     `$(...)` swallows both the hang and the exit status, so the symptom is a
#     silent no-op rather than a failure. `timeout` below bounds it.
#
#   * **`-quiet` writes server replies to stderr, not stdout.** All of
#     `s_client`'s own chatter shares one stream (it configures itself with
#     `-quiet` by dropping its normal stdout bio), so the replies have to be
#     captured with `2>&1` or `grep '^230 '` sees nothing but OpenSSL's own
#     error text and fails forever against a perfectly healthy server.
#
# The verdict comes from the *transcript*, never from `openssl`'s exit code.
# vsftpd closes the control socket after `QUIT` without sending a TLS
# `close_notify`, so `s_client` ends with
# `ssl3_read_n:unexpected eof while reading` -- after a perfectly good
# `230 Login successful.`. Keying the verdict off that exit status made this
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

# Per-attempt bound for `s_client`, well inside the overall TIMEOUT so that one
# wedged handshake costs a retry rather than the whole budget.
S_CLIENT_TIMEOUT="${S_CLIENT_TIMEOUT:-10}"

deadline=$((SECONDS + TIMEOUT))
attempts=0
last_out=""

while [ "$SECONDS" -lt "$deadline" ]; do
  attempts=$((attempts + 1))

  # `timeout` is what makes `s_client` finish; the header above explains why the
  # reply stream has to be captured with `2>&1`.
  #
  # `|| true` is required rather than defensive: it is the only thing that keeps
  # `set -e` from aborting here. The exit code is not the verdict -- a nonzero
  # `s_client` is *expected* even on success, because the deadline-kill that
  # ends a good run is also a nonzero exit -- the transcript below is.
  out="$(
    printf 'USER %s\r\nPASS %s\r\nQUIT\r\n' "$USER" "$PASS" \
      | timeout "$S_CLIENT_TIMEOUT" openssl s_client -starttls ftp \
          -connect "$HOST:$PORT" \
          -servername localhost \
          -verifyCAfile "$CA" -verify_return_error -quiet 2>&1
  )" || true
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

  # Keep only the lines worth reading: the server's rejection, or OpenSSL's own
  # error. A full `s_client` transcript is hundreds of lines of certificate
  # dump, and the retry loop discards every attempt but the last.
  last_error="$(
    printf '%s' "$out" \
      | grep -E '^[45][0-9]{2} |error:|errno=' \
      | tail -n 2 | tr '\n' ' '
  )"
  if [ -n "$last_error" ]; then
    echo "  attempt $attempts: $last_error" >&2
  fi

  sleep 0.5
done

echo "gave up after $attempts attempts." >&2
# Print the whole last transcript, not its tail: the interesting line is often
# the `depth=0 ... verify error` near the top, and truncating it to the last
# line is what made the previous failure unreadable.
printf '%s\n' "$last_out" >&2
exit 1

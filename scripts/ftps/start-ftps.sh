#!/usr/bin/env bash
# Start the FTPS (explicit `AUTH TLS`) container `cmd/ftps` connects to.
#
#   scripts/ftps/start-ftps.sh
#   cmd/ftps/run.sh ...        # see cmd/ftps/run.sh for the flags
#   scripts/ftps/stop-ftps.sh
#
# This is the encrypted half of the pair: `scripts/start-ftp.sh` runs a plain
# vsftpd on 127.0.0.1:21, this one runs an FTPS vsftpd on 127.0.0.1:$FTPS_PORT.
# Two *containers* rather than one server with two ports, because plain FTP and
# FTPS are different daemon configurations here: the FTPS image is built with
# `ssl_enable=YES`, `force_local_logins_ssl=YES` and `force_local_data_ssl=YES`,
# and those are exactly the settings this test needs (a client that upgrades
# only the control channel cannot transfer a single byte against them).
#
# The image is `bfren/ftps` (Alpine + vsftpd 3.0.5). Certificate handling is the
# reason: it reads `/ssl/vsftpd.pem` and only mints a self-signed one when that
# path is missing, so mounting the CA-signed leaf from `gen-cert.sh` there makes
# the *server* present a certificate the client can verify against `ca.pem`,
# instead of forcing `NoVerification`.
#
# Bridge networking with explicit port publishing, *not* `--network host` -- see
# `scripts/start-ftp.sh` for the full DinD reasoning. The data-channel range is
# published for the same reason it is there: without it login succeeds and the
# first `LIST` dies with a connection refused that reads like a client bug.
#
# Environment:
#   FTPS_IMAGE      image to run (default bfren/ftps:latest)
#   FTPS_PORT       control port on 127.0.0.1 (default 2121)
#   FTPS_PASV_MIN   first passive port (default 21100)
#   FTPS_PASV_MAX   last passive port (default 21110)
#   FTP_USER/PASS   credentials (default test/test), shared with start-ftp.sh
set -euo pipefail

: "${FTPS_IMAGE:=bfren/ftps:vsftpd3.0.5}"
: "${FTP_USER:=test}"
: "${FTP_PASS:=test}"
: "${FTPS_PORT:=2121}"
: "${FTPS_PASV_MIN:=21100}"
: "${FTPS_PASV_MAX:=21110}"
: "${PROBE_TIMEOUT:=60}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CERT_DIR="$ROOT/testdata/ftp/tls"
FIXTURE="$ROOT/testdata/ftp/fixture"
ENV_FILE="$ROOT/.ftp-tls.env"

NAME="moonbit-ftps-explicit"

# `--rm` in the run below plus this line: a leftover container from an
# interrupted run holds the port and the old fixture.
if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$NAME"; then
  docker rm -f "$NAME" >/dev/null 2>&1 || true
fi

"$SCRIPT_DIR/gen-cert.sh" "$CERT_DIR"

# The image expects the certificate at `/ssl/vsftpd.pem`, combined cert+key.
# `gen-cert.sh` writes exactly that shape to `server.pem`.
docker run -d --rm \
  --name "$NAME" \
  -p "127.0.0.1:$FTPS_PORT:21" \
  -p "127.0.0.1:$FTPS_PASV_MIN-$FTPS_PASV_MAX:$FTPS_PASV_MIN-$FTPS_PASV_MAX" \
  -e BF_FTPS_EXTERNAL_IP=127.0.0.1 \
  -e BF_FTPS_VSFTPD_USER="$FTP_USER" \
  -e BF_FTPS_VSFTPD_PASS="$FTP_PASS" \
  -e BF_FTPS_VSFTPD_MIN_PORT="$FTPS_PASV_MIN" \
  -e BF_FTPS_VSFTPD_MAX_PORT="$FTPS_PASV_MAX" \
  -v "$FIXTURE:/files" \
  -v "$CERT_DIR:/ssl:ro" \
  "$FTPS_IMAGE" >/dev/null

# Readiness: a real `AUTH TLS` handshake *and* a passive `LIST` over the
# encrypted data channel, i.e. the same handshake `cmd/ftps` will perform.
# Proving only that the control port accepts would miss the half that breaks
# when the passive range or `PROT P` is wrong. See scripts/ftps/probe-ftps.sh.
if ! "$SCRIPT_DIR/probe-ftps.sh" \
  "127.0.0.1" "$FTPS_PORT" "$FTP_USER" "$FTP_PASS" "$CERT_DIR/ca.pem" "$PROBE_TIMEOUT"; then
  echo "start-ftps.sh: $NAME did not answer AUTH TLS + a passive LIST" \
    "on 127.0.0.1:$FTPS_PORT within ${PROBE_TIMEOUT}s" >&2
  docker logs "$NAME" >&2 || true
  exit 1
fi

# Hand the client the CA and the port. The port is fixed (21-style) rather than
# ephemeral because it is published by `docker run`; the only thing the client
# cannot guess is the CA path, and that lives here.
cat > "$ENV_FILE" <<ENV
# Written by scripts/ftps/start-ftps.sh. Sourced by cmd/ftps/run.sh.
# Regenerated on every run, not meant to be committed.
FTP_TLS_HOST=127.0.0.1
FTP_TLS_PORT=$FTPS_PORT
FTP_TLS_CA=$CERT_DIR/ca.pem
FTP_TLS_USER=$FTP_USER
FTP_TLS_PASS=$FTP_PASS
ENV

echo "start-ftps.sh: $NAME ready on 127.0.0.1:$FTPS_PORT" \
  "(explicit AUTH TLS, passive $FTPS_PASV_MIN-$FTPS_PASV_MAX, CA $CERT_DIR/ca.pem)"

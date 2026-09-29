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
# `/ssl` is mounted *read-only*, and that is deliberate: it makes the "the leaf
# is missing" case a loud failure instead of a silent one. `13-vsftpd-ssl.nu`
# would otherwise mint its own self-signed certificate, the server would come up
# presenting a certificate `ca.pem` cannot verify, and the failure would surface
# as a client-side TLS error that reads like a bug in this library. Read-only
# turns it into "the image could not write /ssl/vsftpd.pem during init", i.e.
# the container never starts and the mount is the obvious suspect.
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

# A leftover container from an interrupted run holds the port and the old
# fixture. `stop-ftps.sh` is the normal remover; this is the re-entry guard, so
# it also has to clear a container that died during init.
if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$NAME"; then
  docker rm -f "$NAME" >/dev/null 2>&1 || true
fi

"$SCRIPT_DIR/gen-cert.sh" "$CERT_DIR"

# The image expects the certificate at `/ssl/vsftpd.pem`, combined cert+key.
# `gen-cert.sh` writes exactly that path and shape, so the init script finds it
# and skips generating one. The mount stays a *directory* mount rather than a
# single-file one: `ca.pem` comes from the same directory and the client is
# handed that path, and `bfren/ftps` declares `/ssl` as a VOLUME, so a bind mount
# of the whole directory is the least surprising thing here.
#
# No `--rm` here, unlike `scripts/start-ftp.sh`. A container that dies during
# init must stay inspectable: `--rm` deletes it, and `docker logs` then answers
# `No such container` -- which is exactly how the wrong certificate path went
# undiagnosed. `stop-ftps.sh` removes it explicitly and the liveness check below
# dumps its log, so nothing leaks.
docker run -d \
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

# Liveness first, readiness second.
#
# A container that fails *init* -- a wrong certificate path, a bad
# `vsftpd.conf`, a missing `BF_FTPS_*` variable -- exits within a second or two.
# Without this check the only symptom is the probe below retrying `Connection
# refused` for the full timeout, which names neither the cause nor the
# container. So give init a moment to either finish or die, and when it dies say
# so with its log.
for _ in $(seq 1 50); do
  if [ -z "$(docker ps -q --filter "name=^${NAME}$")" ]; then
    echo "start-ftps.sh: $NAME exited during init - see its log below." \
      "The usual cause is a certificate or config problem under /ssl." >&2
    docker logs "$NAME" >&2 || true
    exit 1
  fi
  sleep 0.1
done

# Readiness: a real `AUTH TLS` handshake followed by a `USER`/`PASS` that earns
# a `230`, i.e. the handshake `cmd/ftps` will perform first. Proving only that
# the control port accepts would miss a certificate the client cannot verify
# or a daemon that is not ready yet. The *data* channel -- `PBSZ` / `PROT P`,
# the passive range -- is deliberately left to `cmd/ftps/run.sh`, which is the
# real assertion; a shell pipe would only re-run the same code. See
# scripts/ftps/probe-ftps.sh.
if ! "$SCRIPT_DIR/probe-ftps.sh" \
  "127.0.0.1" "$FTPS_PORT" "$FTP_USER" "$FTP_PASS" "$CERT_DIR/ca.pem" "$PROBE_TIMEOUT"; then
  echo "start-ftps.sh: $NAME did not complete AUTH TLS + login" \
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

#!/usr/bin/env bash
# Start a single vsftpd container for `cmd/example` / `cmd/ftp` to connect to.
# One container, control port + PASV range published onto 127.0.0.1, testdata
# mounted as the FTP root.
set -euo pipefail

: "${FTP_IMAGE:=jmoyer/vsftpd:latest}"
: "${FTP_USER:=test}"
: "${FTP_PASS:=test}"
: "${PASV_MIN_PORT:=30000}"
: "${PASV_MAX_PORT:=30099}"
: "${PROBE_TIMEOUT:=60}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE_FIXTURE="$ROOT/testdata/ftp/fixture"

NAME="moonbit-ftp-example"
PORT=21

# A *private copy* of the fixture, not the checked-in directory itself.
#
# The FTP home is writable by design -- the demos upload, rename and delete
# files in it -- so mounting `testdata/ftp/fixture` directly means the tests
# mutate the working tree. That is how this script and `scripts/ftps/
# start-ftps.sh` came to share one directory: both mounted the same path, and
# the FTPS container's init step (`11-user.nu`, "Ensuring user test owns
# /files") `chown`s it to its own user before it starts. The plaintext
# container uses a *different* image whose user does not match, so after the
# FTPS container had run once, the plaintext server could no longer create
# files in what was now someone else's directory -- vsftpd answered
# `553 Could not create file.` and the plain smoke test failed with no
# obvious connection to TLS.
#
# Copying per container removes the coupling rather than papering over it: two
# servers cannot fight over one directory if each owns its own, and a crashed
# run cannot leave a root-owned scratch file behind for the next one.
FIXTURE="$ROOT/.ftp-plain-root"
rm -rf "$FIXTURE"
mkdir -p "$FIXTURE"
cp -R "$SOURCE_FIXTURE/." "$FIXTURE/"
chmod -R a+rwX "$FIXTURE"

# Drop any leftover container with the same name.
if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$NAME"; then
  docker rm -f "$NAME" >/dev/null 2>&1 || true
fi

# Bridge networking with explicit port publishing, *not* `--network host`.
#
# CNB runs the `docker` service as a DinD sidecar: the daemon lives in its own
# container, so `--network host` there means "the DinD container's namespace",
# which the build container does not reach. Only ports published with `-p` show
# up as 127.0.0.1 inside the build container, through the daemon's port proxy.
#
# Publishing the control port alone is not enough, and that is the trap: FTP
# uses a *second* connection for every transfer. With the PASV range
# unpublished the login and `PWD` succeed and the first `LIST` dies with
# `@socket.Tcp::connect(): Connection refused`, which reads like a client bug
# rather than a container that is only half reachable. Both ranges are
# published here for that reason.
#
# `-p` is also the portable choice: rootless Docker cannot share the host
# network namespace either, and on GitHub Actions it makes the runner's
# behaviour independent of how its daemon is configured.
#
# PASV_ADDRESS=127.0.0.1 pins the advertised data-channel IP to loopback (the
# image otherwise autodetects the gateway IP, which a client dialling
# 127.0.0.1 cannot reach).
#
# Every variable the image entrypoint (`/usr/sbin/run-vsftpd.sh`) interpolates
# must be passed with a *non-empty* value, and the list is longer than the
# three obvious passive ones.
#
# The entrypoint appends a fixed set of directives to
# `/etc/vsftpd/vsftpd.conf`, one per variable:
#
#   PASV_ADDRESS  PASV_MAX_PORT  PASV_MIN_PORT  PASV_ADDR_RESOLVE
#   PASV_ENABLE   FILE_OPEN_MODE  LOCAL_UMASK   XFERLOG_STD_FORMAT
#   PASV_PROMISCUOUS  PORT_PROMISCUOUS
#
# vsftpd rejects an empty value for any non-string directive
# (`parseconf.c`: `missing value in config file for: <name>`) and exits 2.
# That message goes to fd 0 (`VSFTP_COMMAND_FD`), which in a container is not
# the log stream, so the container dies with `docker logs` stopping at
# "Starting vsftpd..." and no explanation. The symptom is a server that
# answered the readiness probe and then refuses every later connection --
# because it is not the same process any more, it is gone.
#
# hence: all ten, always, and never empty. FILE_OPEN_MODE / LOCAL_UMASK /
# XFERLOG_STD_FORMAT / PASV_PROMISCUOUS / PORT_PROMISCUOUS below are not
# optional extras, they are the other half of the directive list.
#
# No `--rm`, for the same reason `scripts/ftps/start-ftps.sh` does not pass it:
# a container that dies must stay inspectable, and `--rm` deletes the corpse
# before `docker logs` can say anything, so the exit code and the fd-0 message
# both go missing. `stop-ftp.sh` removes it explicitly, and the `docker rm -f`
# re-entry guard above clears one left by an interrupted run.
docker run -d \
  --name "$NAME" \
  -p "127.0.0.1:$PORT:21" \
  -p "127.0.0.1:$PASV_MIN_PORT-$PASV_MAX_PORT:$PASV_MIN_PORT-$PASV_MAX_PORT" \
  -e FTP_USER="$FTP_USER" \
  -e FTP_PASS="$FTP_PASS" \
  -e PASV_ADDRESS=127.0.0.1 \
  -e PASV_MIN_PORT="$PASV_MIN_PORT" \
  -e PASV_MAX_PORT="$PASV_MAX_PORT" \
  -e PASV_ENABLE=YES \
  -e PASV_ADDR_RESOLVE=NO \
  -e FILE_OPEN_MODE=0666 \
  -e LOCAL_UMASK=022 \
  -e XFERLOG_STD_FORMAT=NO \
  -e PASV_PROMISCUOUS=NO \
  -e PORT_PROMISCUOUS=NO \
  -v "$FIXTURE:/home/vsftpd/$FTP_USER" \
  "$FTP_IMAGE" >/dev/null

# Liveness first, readiness second.
#
# The probe below retries for the whole PROBE_TIMEOUT, and a container that
# dies *late* -- after it served one handshake -- makes that loop look like a
# healthy server that then stopped answering. Worse, with `--rm` the corpse is
# gone by the time anything tries to look at it, so the exit reason is
# unrecoverable. Checking that the container is still running right after the
# probe turns "the demo gets Connection refused" into a statement about the
# server, which is where the fault actually is.
#
# The order matters: a ready-then-dead container must fail *here*, not as four
# unrelated client errors that all name 127.0.0.1:$PORT.
if [ -z "$(docker ps -q --filter "name=^${NAME}$")" ]; then
  echo "start-ftp.sh: $NAME is no longer running after the readiness probe." \
    "A late exit is usually vsftpd refusing its own config: the entrypoint" \
    "appends one directive per PASV_*/FILE_OPEN_MODE/... variable, and an" \
    "empty value is fatal (exit 2, message on fd 0, so absent from logs)." >&2
  docker logs "$NAME" >&2 || true
  exit 1
fi

# Readiness: a full login *plus* a passive `LIST`, retried until PROBE_TIMEOUT.
# A bare connect only proves something accepted the control port; it says
# nothing about the data channel, which is exactly the half that breaks when
# the PASV range is not published. See scripts/probe-ftp.py.
if ! python3 "$SCRIPT_DIR/probe-ftp.py" \
  "127.0.0.1" "$PORT" "$FTP_USER" "$FTP_PASS" "$PROBE_TIMEOUT"; then
  echo "start-ftp.sh: $NAME did not answer a login + passive LIST" \
    "on 127.0.0.1:$PORT within ${PROBE_TIMEOUT}s" >&2
  docker logs "$NAME" >&2 || true
  exit 1
fi

# And confirm the server survived the probe: a config that only fails on a
# later command would otherwise pass readiness and then refuse the demo.
if [ -z "$(docker ps -q --filter "name=^${NAME}$")" ]; then
  echo "start-ftp.sh: $NAME exited during the readiness probe." >&2
  docker logs "$NAME" >&2 || true
  exit 1
fi

echo "start-ftp.sh: $NAME ready on 127.0.0.1:$PORT" \
  "(control + passive $PASV_MIN_PORT-$PASV_MAX_PORT, user $FTP_USER)"

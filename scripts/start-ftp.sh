#!/bin/sh
# Start one `jmoyer/vsftpd` (vsftpd 3.0.5 on Debian Trixie) container per
# server profile.
#
# The tests run against a real vsftpd, never against a mock. Each profile is a
# separate container on its own port: vsftpd reads its capability switches
# (`cmds_denied`, ...) from the config file only at startup, so a single
# process cannot present two profiles at once.
#
# Usage:
#   scripts/start-ftp.sh                 # start every profile, wait for the ports
#   PROFILES="full no-mlst" scripts/start-ftp.sh
#
# Ports (control, then passive range) are fixed so the tests can hardcode them:
#
#   profile    control   passive
#   full        2121     30000-30099
#   no-mlst     2122     30100-30199
#   no-time     2123     30200-30299
#   no-epsv     2124     30300-30399
#
# The range is 100 ports wide, not 10, on purpose. `moon test` runs the
# end-to-end file with every test in parallel, so a dozen sessions hit the same
# profile at once and each transfer needs its own passive port. With a 10 port
# range vsftpd exhausts the range and answers
# `500 OOPS: vsf_sysutil_bind` *and closes the control connection* while the
# client is waiting for a reply, which surfaces as a confusing
# `ReaderClosed` failure in unrelated tests.
#
# This is the single source of truth for the test server. The CNB pipeline
# (DinD), the GitHub workflow and the CNB cloud dev environment all call this
# same script, so the three run the identical daemon and the identical config.
#
# Environment:
#   FTP_USER / FTP_PASS  virtual user shared by every profile (default test/test)
#   FTPS_PASS            password of the `ftps` user used for the TLS profile
#   PROFILES             space separated subset of the profiles above
#   FTP_ROOT             host directory serving the fixture, default .tmp/ftp-root
#   FTP_CONF_ROOT        host directory holding the per-profile configs,
#                        default .tmp/ftp-conf
#   FTP_IMAGE            image to run, default jmoyer/vsftpd
#   FTP_IMAGE_TAG        image tag, default latest
#
# Layout note. `jmoyer/vsftpd` serves `local_root=/home/vsftpd/$USER`, so the
# fixture tree is bind mounted at `/home/vsftpd/$FTP_USER` inside the
# container. The tests see `/fixture/...` (read only) and `/upload/...`
# (writable) because vsftpd chroots the user into that directory.
#
# The image entrypoint (`/usr/sbin/run-vsftpd.sh`) does three things this
# script has to cooperate with:
#
#   1. it writes the virtual user db into `/etc/vsftpd/`, so `/etc/vsftpd`
#      must be writable and the profile config must sit at exactly
#      `/etc/vsftpd/vsftpd.conf`;
#   2. it appends `pasv_address`, `pasv_max_port`, `pasv_min_port`, ... from
#      `PASV_ADDRESS` / `PASV_MIN_PORT` / `PASV_MAX_PORT` and friends. All
#      three are required: an empty `pasv_min_port=` makes vsftpd exit 2 with
#      no message at all. They are always passed below;
#   3. it creates `/home/vsftpd/$USER` and runs `db_load`, so the mounted home
#      directory must be writable by the container.

set -eu

PROFILES="${PROFILES:-full no-mlst no-time no-epsv}"
FTP_USER="${FTP_USER:-test}"
FTP_PASS="${FTP_PASS:-test}"
FTP_ROOT="${FTP_ROOT:-$PWD/.tmp/ftp-root}"
FTP_CONF_ROOT="${FTP_CONF_ROOT:-$PWD/.tmp/ftp-conf}"
FTP_IMAGE="${FTP_IMAGE:-jmoyer/vsftpd}"
FTP_IMAGE_TAG="${FTP_IMAGE_TAG:-latest}"

# The read only fixture tree plus one writable directory per profile. vsftpd
# chroots every user into its home, so the layout the tests see is
# `/fixture/...` (read only) and `/upload/...` (writable).
mkdir -p "$FTP_ROOT/upload"
if [ ! -e "$FTP_ROOT/fixture" ]; then
  cp -r testdata/ftp/fixture "$FTP_ROOT/fixture"
fi
chmod -R a+rX "$FTP_ROOT"
chmod 777 "$FTP_ROOT/upload" "$FTP_ROOT"

# The image entrypoint runs `db_load` and mkdirs inside `/home/vsftpd`, so the
# host directory bind mounted there has to be writable by the container.
mkdir -p "$FTP_CONF_ROOT/home"
chmod 777 "$FTP_CONF_ROOT/home"

# Return the control port and passive range of a profile.
profile_ports() {
  case "$1" in
    full)    echo "2121 30000 30099" ;;
    no-mlst) echo "2122 30100 30199" ;;
    no-time) echo "2123 30200 30299" ;;
    no-epsv) echo "2124 30300 30399" ;;
    *) echo "unknown profile: $1" >&2; exit 2 ;;
  esac
}

# Read the control port and passive range of a profile into the positional
# parameters, so `$1 $2 $3` are port / pasv_min / pasv_max.
read_profile_ports() {
  # shellcheck disable=SC2046  # the three fields are wanted as three arguments
  set -- $(profile_ports "$1")
  port="$1"; pasv_min="$2"; pasv_max="$3"
}

start_profile() {
  profile="$1"
  port=""; pasv_min=""; pasv_max=""
  read_profile_ports "$profile"
  name="moonbit-ftp-$profile"

  # One config per profile: the base file with the overlay appended. The image
  # entrypoint appends the passive settings itself from the environment, so
  # they must NOT be written here (a duplicate directive makes vsftpd refuse
  # to start).
  conf_dir="$FTP_CONF_ROOT/$profile"
  mkdir -p "$conf_dir/vsftpd"
  cat testdata/ftp/vsftpd-base.conf > "$conf_dir/vsftpd/vsftpd.conf"
  cat "testdata/ftp/vsftpd-$profile.conf" >> "$conf_dir/vsftpd/vsftpd.conf"
  # The control port is per profile and cannot come from the base file, so it
  # is appended here. `listen_port` is not touched by the entrypoint.
  printf 'listen_port=%s\n' "$port" >> "$conf_dir/vsftpd/vsftpd.conf"
  chmod -R a+rwX "$conf_dir"

  docker rm -f "$name" >/dev/null 2>&1 || true
  docker run -d --name "$name" \
    -p "$port:$port" \
    -p "$pasv_min-$pasv_max:$pasv_min-$pasv_max" \
    -v "$FTP_ROOT:/home/vsftpd/$FTP_USER" \
    -v "$conf_dir/vsftpd:/etc/vsftpd" \
    -e "FTP_USER=$FTP_USER" \
    -e "FTP_PASS=$FTP_PASS" \
    -e "PASV_ADDRESS=127.0.0.1" \
    -e "PASV_MIN_PORT=$pasv_min" \
    -e "PASV_MAX_PORT=$pasv_max" \
    -e "PASV_ENABLE=YES" \
    -e "PASV_ADDR_RESOLVE=NO" \
    "$FTP_IMAGE:$FTP_IMAGE_TAG" >/dev/null
}

# Wait for a control port to accept a connection.
wait_for_port() {
  port="$1"
  i=0
  while [ "$i" -lt 60 ]; do
    if python3 -c "import socket; socket.create_connection(('127.0.0.1', $port), 1).close()" 2>/dev/null; then
      return 0
    fi
    i=$((i + 1))
    sleep 1
  done
  return 1
}

# Log in for real on a control port, using the same handshake the tests do,
# and return non-zero unless every reply arrives.
#
# A bare TCP connect is not enough to prove a profile works. The daemon's
# post-login child can die after it accepted the connection and after it
# started writing its banner: the client then reads a truncated `500 OOPS: `
# and the tests fail with an error that looks like a protocol bug in the
# library. `seccomp_sandbox=NO` in testdata/ftp/vsftpd-base.conf exists to
# keep that from happening, so this probe makes its absence loud here rather
# than as thirty confusing test failures later.
probe_login() {
  port="$1"
  python3 - "$port" "$FTP_USER" "$FTP_PASS" <<'PY'
import socket, sys

port, user, password = sys.argv[1], sys.argv[2], sys.argv[3]


def read_reply(sock):
    data = b""
    while b"\r\n" not in data:
        chunk = sock.recv(4096)
        if not chunk:
            break
        data += chunk
        if len(data) > 4096:
            break
    return data


try:
    sock = socket.create_connection(("127.0.0.1", int(port)), 5)
    sock.settimeout(5)
    banner = read_reply(sock)
    # A bare `500 OOPS: ` banner means the login child died mid-write, which
    # is exactly what a killing seccomp filter looks like on the wire.
    if not banner.startswith(b"220"):
        print("  control connection did not send a 220 banner: %r" % banner, file=sys.stderr)
        sys.exit(1)
    for command, expected in (
        ("USER %s" % user, b"331"),
        ("PASS %s" % password, b"230"),
        ("PWD", b"257"),
    ):
        sock.sendall(command.encode() + b"\r\n")
        reply = read_reply(sock)
        if not reply.startswith(expected):
            print("  %s got %r, expected a %s reply" % (command.split()[0], reply, expected.decode()), file=sys.stderr)
            sys.exit(1)
    sock.sendall(b"QUIT\r\n")
    sock.close()
except OSError as exc:
    print("  login probe failed: %s" % exc, file=sys.stderr)
    sys.exit(1)
PY
}

for profile in $PROFILES; do
  echo "starting FTP profile '$profile'"
  start_profile "$profile"
  if ! wait_for_port "$port"; then
    echo "FTP profile '$profile' did not come up on port $port" >&2
    docker logs "moonbit-ftp-$profile" >&2 || true
    exit 1
  fi
  if ! probe_login "$port"; then
    echo "FTP profile '$profile' accepted the connection but the login failed on port $port" >&2
    echo "  A bare '500 OOPS: ' banner means the login child died before it could answer;" >&2
    echo "  check that testdata/ftp/vsftpd-base.conf still sets seccomp_sandbox=NO." >&2
    docker logs "moonbit-ftp-$profile" >&2 || true
    exit 1
  fi
  echo "  profile '$profile' is up on 127.0.0.1:$port (user $FTP_USER)"
done

echo "all FTP profiles are up"

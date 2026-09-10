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
#   full        2121     30000-30009
#   no-mlst     2122     30010-30019
#   no-time     2123     30020-30029
#   no-epsv     2124     30030-30039
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
    full)    echo "2121 30000 30009" ;;
    no-mlst) echo "2122 30010 30019" ;;
    no-time) echo "2123 30020 30029" ;;
    no-epsv) echo "2124 30030 30039" ;;
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

for profile in $PROFILES; do
  echo "starting FTP profile '$profile'"
  start_profile "$profile"
  if ! wait_for_port "$port"; then
    echo "FTP profile '$profile' did not come up on port $port" >&2
    docker logs "moonbit-ftp-$profile" >&2 || true
    exit 1
  fi
  echo "  profile '$profile' is up on 127.0.0.1:$port (user $FTP_USER)"
done

echo "all FTP profiles are up"

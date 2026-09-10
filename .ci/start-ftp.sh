#!/bin/sh
# Start one `bogem/ftp` (vsftpd 3.0.3) container per server profile.
#
# The tests run against a real vsftpd, never against a mock. Each profile is a
# separate container on its own port: vsftpd reads its capability switches
# (`cmds_denied`, `mdtm_write`, ...) from the config file only at startup, so a
# single process cannot present two profiles at once.
#
# Usage:
#   .ci/start-ftp.sh                 # start every profile, wait for the ports
#   PROFILES="full no-mlst" .ci/start-ftp.sh
#
# Ports (control, then passive range) are fixed so the tests can hardcode them:
#
#   profile    control   passive
#   full        2121     30000-30009
#   no-mlst     2122     30010-30019
#   no-time     2123     30020-30029
#   no-epsv     2124     30030-30039
#
# The same script is used by the CNB pipeline (DinD), the GitHub workflow and
# the CNB cloud dev environment, so all three run the identical server.
#
# Environment:
#   FTP_USER / FTP_PASS  virtual user shared by every profile (default test/test)
#   PROFILES             space separated subset of the profiles above
#   FTP_ROOT             host directory serving the fixture, default .ci/ftp-root
#   FTP_CONF_ROOT        host directory holding the per-profile configs and
#                        user home dirs, default .ci/ftp-conf. Kept *outside*
#                        FTP_ROOT so the config files are not visible through
#                        the FTP user's chroot.

set -eu

PROFILES="${PROFILES:-full no-mlst no-time no-epsv}"
FTP_USER="${FTP_USER:-test}"
FTP_PASS="${FTP_PASS:-test}"
FTP_ROOT="${FTP_ROOT:-$PWD/.ci/ftp-root}"
FTP_CONF_ROOT="${FTP_CONF_ROOT:-$PWD/.ci/ftp-conf}"
IMAGE="${FTP_IMAGE:-bogem/ftp}"

# The read only fixture tree plus one writable directory per profile. vsftpd
# chroots every user into `/srv`, so the layout the tests see is
# `/fixture/...` (read only) and `/upload/...` (writable).
mkdir -p "$FTP_ROOT/upload"
if [ ! -e "$FTP_ROOT/fixture" ]; then
  cp -r testdata/ftp/fixture "$FTP_ROOT/fixture"
fi
chmod -R a+rX "$FTP_ROOT"
chmod 777 "$FTP_ROOT/upload"

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

start_profile() {
  profile="$1"
  set -- $(profile_ports "$profile")
  port="$1"; pasv_min="$2"; pasv_max="$3"
  name="moonbit-ftp-$profile"

  # One config per profile: the base file with the overlay appended.
  #
  # The image entrypoint (`/usr/sbin/run-vsftpd.sh`) does two things we must
  # keep working: it writes the virtual user db under `/etc/vsftpd/` and then
  # runs `vsftpd /etc/vsftpd/vsftpd.conf`. So the profile config has to live at
  # exactly that path, and the surrounding `/etc/vsftpd` directory must stay
  # writable for `db_load`.
  #
  conf_dir="$FTP_CONF_ROOT/$profile"
  mkdir -p "$conf_dir/vsftpd" "$conf_dir/home"
  cat testdata/ftp/vsftpd-base.conf > "$conf_dir/vsftpd/vsftpd.conf"
  cat "testdata/ftp/vsftpd-$profile.conf" >> "$conf_dir/vsftpd/vsftpd.conf"
  # The passive range and the control port cannot come from the base file
  # alone: every profile listens on its own range. `pasv_address` is appended
  # by the entrypoint from `PASV_ADDRESS`, so it is not written here.
  {
    printf 'pasv_min_port=%s\n' "$pasv_min"
    printf 'pasv_max_port=%s\n' "$pasv_max"
    printf 'listen_port=%s\n' "$port"
  } >> "$conf_dir/vsftpd/vsftpd.conf"

  docker rm -f "$name" >/dev/null 2>&1 || true
  docker run -d --name "$name" \
    -p "$port:$port" \
    -p "$pasv_min-$pasv_max:$pasv_min-$pasv_max" \
    -v "$FTP_ROOT:/srv" \
    -v "$conf_dir/vsftpd:/etc/vsftpd" \
    -v "$conf_dir/home:/home/vsftpd" \
    -e "FTP_USER=$FTP_USER" \
    -e "FTP_PASS=$FTP_PASS" \
    -e "PASV_ADDRESS=127.0.0.1" \
    "$IMAGE" >/dev/null
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
  set -- $(profile_ports "$profile")
  if ! wait_for_port "$1"; then
    echo "FTP profile '$profile' did not come up on port $1" >&2
    docker logs "moonbit-ftp-$profile" >&2 || true
    exit 1
  fi
  echo "  profile '$profile' is up on 127.0.0.1:$1 (user $FTP_USER)"
done

echo "all FTP profiles are up"

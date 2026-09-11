#!/bin/sh
set -x
ROOT=/tmp/diag-root
mkdir -p "$ROOT/upload"
[ -e "$ROOT/fixture" ] || cp -r testdata/ftp/fixture "$ROOT/fixture"
chmod -R a+rX "$ROOT"; chmod 777 "$ROOT/upload" "$ROOT"
run() {
  name="$1"; shift
  d="/tmp/diag-conf/$name"; rm -rf "$d"; mkdir -p "$d"
  cp testdata/ftp/vsftpd-base.conf "$d/vsftpd.conf"
  if [ "$1" != "-" ]; then for line in "$@"; do printf '%s\n' "$line" >> "$d/vsftpd.conf"; done; fi
  printf 'listen_port=2122\n' >> "$d/vsftpd.conf"
  chmod -R a+rwX "$d"
  docker rm -f "c-$name" >/dev/null 2>&1
  docker run --name "c-$name" \
    -v "$ROOT:/home/vsftpd/test" -v "$d:/etc/vsftpd" \
    -e FTP_USER=test -e FTP_PASS=test \
    -e PASV_ADDRESS=127.0.0.1 -e PASV_MIN_PORT=30100 -e PASV_MAX_PORT=30199 \
    -e PASV_ENABLE=YES -e PASV_ADDR_RESOLVE=NO \
    -e FILE_OPEN_MODE=0666 -e LOCAL_UMASK=022 -e XFERLOG_STD_FORMAT=NO \
    -e PASV_PROMISCUOUS=NO -e PORT_PROMISCUOUS=NO \
    jmoyer/vsftpd:latest 2>&1 | tail -25
  echo "EXITCODE $name => $(docker inspect -f '{{.State.ExitCode}}' c-$name 2>/dev/null)"
  docker rm -f "c-$name" >/dev/null 2>&1
}
echo "@@@@ base @@@@"; run base -
echo "@@@@ nomlst @@@@"; run nomlst 'cmds_denied=MLST,MLSD'

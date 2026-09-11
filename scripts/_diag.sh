#!/bin/sh
set -x
mk() {
  name="$1"; shift
  d="/tmp/diag/$name"; rm -rf "$d"; mkdir -p "$d"
  cp testdata/ftp/vsftpd-base.conf "$d/vsftpd.conf"
  if [ "$1" != "-" ]; then
    for line in "$@"; do printf '%s\n' "$line" >> "$d/vsftpd.conf"; done
  fi
  printf 'listen_port=2122\n' >> "$d/vsftpd.conf"
  chmod -R a+rwX "$d"
  docker rm -f "c-$name" >/dev/null 2>&1
  id=$(docker run -d --name "c-$name" -v "$d:/etc/vsftpd" \
    -e FTP_USER=test -e FTP_PASS=test \
    -e PASV_ADDRESS=127.0.0.1 -e PASV_MIN_PORT=30100 -e PASV_MAX_PORT=30199 \
    -e PASV_ENABLE=YES -e PASV_ADDR_RESOLVE=NO \
    -e FILE_OPEN_MODE=0666 -e LOCAL_UMASK=022 -e XFERLOG_STD_FORMAT=NO \
    -e PASV_PROMISCUOUS=NO -e PORT_PROMISCUOUS=NO \
    jmoyer/vsftpd:latest)
  sleep 4
  st=$(docker inspect -f '{{.State.Status}}' "c-$name" 2>/dev/null)
  ec=$(docker inspect -f '{{.State.ExitCode}}' "c-$name" 2>/dev/null)
  echo "RESULT $name status=$st exit=$ec"
  docker rm -f "c-$name" >/dev/null 2>&1
}
echo "run base (no overlay directive)"
mk base -
echo "run mlsd"
mk mlsd 'cmds_denied=MLST,MLSD'
echo "run dele"
mk dele 'cmds_denied=DELE'
echo "run emptycmds"
mk emptycmds 'cmds_denied='

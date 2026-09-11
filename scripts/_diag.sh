#!/bin/sh
set -x
ROOT=/tmp/diag-root
mkdir -p "$ROOT/upload"; chmod 777 "$ROOT/upload" "$ROOT"
d=/tmp/diag-conf/x; rm -rf "$d"; mkdir -p "$d"
cp testdata/ftp/vsftpd-base.conf "$d/vsftpd.conf"
printf 'cmds_denied=MLST,MLSD\n' >> "$d/vsftpd.conf"
printf 'listen_port=2122\n' >> "$d/vsftpd.conf"
chmod -R a+rwX "$d"
docker rm -f c-x >/dev/null 2>&1
docker run --name c-x -v "$ROOT:/home/vsftpd/test" -v "$d:/etc/vsftpd" \
  --entrypoint /bin/bash -e FTP_USER=test -e FTP_PASS=test \
  -e PASV_ADDRESS=127.0.0.1 -e PASV_MIN_PORT=30100 -e PASV_MAX_PORT=30199 \
  -e PASV_ENABLE=YES -e PASV_ADDR_RESOLVE=NO -e FILE_OPEN_MODE=0666 \
  -e LOCAL_UMASK=022 -e XFERLOG_STD_FORMAT=NO -e PASV_PROMISCUOUS=NO -e PORT_PROMISCUOUS=NO \
  jmoyer/vsftpd:latest -c '
    echo "### host base conf listen lines ###"
    grep -n "listen" /etc/vsftpd/vsftpd.conf
    echo "### count of listen= lines in ORIGINAL (before append) ###"
    grep -c "^listen=" /etc/vsftpd/vsftpd.conf
    echo "### vsftpd -v ###"
    /usr/sbin/vsftpd -v
    echo "### try running with only listen=YES forced at end ###"
    printf "listen=YES\n" >> /etc/vsftpd/vsftpd.conf
    /usr/sbin/vsftpd /etc/vsftpd/vsftpd.conf 0>/tmp/fd0 2>/tmp/fd2 &
    sleep 2; kill %1 2>/dev/null
    echo "### fd0 ###"; cat /tmp/fd0
  ' 2>&1 | tail -30
docker rm -f c-x >/dev/null 2>&1

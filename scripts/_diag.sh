#!/bin/sh
# Run the image's entrypoint but redirect fd 0 (where vsftpd writes its fatal
# message) into a captured pipe, so we see WHY it exits 2.
set -x
ROOT=/tmp/diag-root
mkdir -p "$ROOT/upload"; chmod 777 "$ROOT/upload" "$ROOT"
d=/tmp/diag-conf/x; rm -rf "$d"; mkdir -p "$d"
cp testdata/ftp/vsftpd-base.conf "$d/vsftpd.conf"
printf 'cmds_denied=MLST,MLSD\n' >> "$d/vsftpd.conf"
printf 'listen_port=2122\n' >> "$d/vsftpd.conf"
chmod -R a+rwX "$d"
docker rm -f c-x >/dev/null 2>&1
# override entrypoint: mimic it, but capture fd0 to a file and also print it
docker run --name c-x \
  -v "$ROOT:/home/vsftpd/test" -v "$d:/etc/vsftpd" \
  --entrypoint /bin/bash \
  -e FTP_USER=test -e FTP_PASS=test \
  -e PASV_ADDRESS=127.0.0.1 -e PASV_MIN_PORT=30100 -e PASV_MAX_PORT=30199 \
  -e PASV_ENABLE=YES -e PASV_ADDR_RESOLVE=NO \
  -e FILE_OPEN_MODE=0666 -e LOCAL_UMASK=022 -e XFERLOG_STD_FORMAT=NO \
  -e PASV_PROMISCUOUS=NO -e PORT_PROMISCUOUS=NO \
  jmoyer/vsftpd:latest -c '
    mkdir -p /home/vsftpd/$FTP_USER
    chown -R ftp:ftp /home/vsftpd/
    echo -e "$FTP_USER\n$FTP_PASS" > /etc/vsftpd/virtual_users.txt
    /usr/bin/db_load -T -t hash -f /etc/vsftpd/virtual_users.txt /etc/vsftpd/virtual_users.db
    {
      echo "pasv_address=${PASV_ADDRESS}"
      echo "pasv_max_port=${PASV_MAX_PORT}"
      echo "pasv_min_port=${PASV_MIN_PORT}"
      echo "pasv_addr_resolve=${PASV_ADDR_RESOLVE}"
      echo "pasv_enable=${PASV_ENABLE}"
      echo "file_open_mode=${FILE_OPEN_MODE}"
      echo "local_umask=${LOCAL_UMASK}"
      echo "xferlog_std_format=${XFERLOG_STD_FORMAT}"
      echo "pasv_promiscuous=${PASV_PROMISCUOUS}"
      echo "port_promiscuous=${PORT_PROMISCUOUS}"
    } >> /etc/vsftpd/vsftpd.conf
    echo "### effective config tail ###"
    tail -14 /etc/vsftpd/vsftpd.conf
    echo "### running vsftpd, fd0 captured ###"
    /usr/sbin/vsftpd /etc/vsftpd/vsftpd.conf 0>/tmp/fd0 2>/tmp/fd2
    echo "### rc=$? fd0= ###"; cat /tmp/fd0
    echo "### fd2= ###"; cat /tmp/fd2
  ' 2>&1 | tail -40
echo "exit=$(docker inspect -f '{{.State.ExitCode}}' c-x 2>/dev/null)"
docker rm -f c-x >/dev/null 2>&1

#!/bin/sh
set -x
mkdir -p /tmp/diag/nm/vsftpd
cp testdata/ftp/vsftpd-base.conf /tmp/diag/nm/vsftpd/vsftpd.conf
cat testdata/ftp/vsftpd-no-mlst.conf >> /tmp/diag/nm/vsftpd/vsftpd.conf
printf "listen_port=2122\n" >> /tmp/diag/nm/vsftpd/vsftpd.conf
chmod -R a+rwX /tmp/diag/nm
docker rm -f d-nomlst d-nomlst2
echo "=== run with cmds_denied, capture stderr ==="
docker run --name d-nomlst -p 2122:2122 -p 30100-30199:30100-30199 -v /tmp/diag/nm/vsftpd:/etc/vsftpd -e FTP_USER=test -e FTP_PASS=test -e PASV_ADDRESS=127.0.0.1 -e PASV_MIN_PORT=30100 -e PASV_MAX_PORT=30199 -e PASV_ENABLE=YES -e PASV_ADDR_RESOLVE=NO -e FILE_OPEN_MODE=0666 -e LOCAL_UMASK=022 -e XFERLOG_STD_FORMAT=NO -e PASV_PROMISCUOUS=NO -e PORT_PROMISCUOUS=NO jmoyer/vsftpd:latest 2>&1 | head -40
echo "exit=$?"
echo "=== now WITHOUT cmds_denied ==="
mkdir -p /tmp/diag/nm2/vsftpd
cp testdata/ftp/vsftpd-base.conf /tmp/diag/nm2/vsftpd/vsftpd.conf
printf "listen_port=2123\n" >> /tmp/diag/nm2/vsftpd/vsftpd.conf
chmod -R a+rwX /tmp/diag/nm2
timeout 8 docker run --name d-nomlst2 -p 2123:2123 -p 30200-30299:30200-30299 -v /tmp/diag/nm2/vsftpd:/etc/vsftpd -e FTP_USER=test -e FTP_PASS=test -e PASV_ADDRESS=127.0.0.1 -e PASV_MIN_PORT=30200 -e PASV_MAX_PORT=30299 -e PASV_ENABLE=YES -e PASV_ADDR_RESOLVE=NO -e FILE_OPEN_MODE=0666 -e LOCAL_UMASK=022 -e XFERLOG_STD_FORMAT=NO -e PASV_PROMISCUOUS=NO -e PORT_PROMISCUOUS=NO jmoyer/vsftpd:latest 2>&1 | head -30
echo "second exit=$?"
docker rm -f d-nomlst d-nomlst2 >/dev/null 2>&1

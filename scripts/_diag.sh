#!/bin/sh
set -x
mkdir -p /tmp/diag/nm/vsftpd
cp testdata/ftp/vsftpd-base.conf /tmp/diag/nm/vsftpd/vsftpd.conf
cat testdata/ftp/vsftpd-no-mlst.conf >> /tmp/diag/nm/vsftpd/vsftpd.conf
printf "listen_port=2122\n" >> /tmp/diag/nm/vsftpd/vsftpd.conf
docker rm -f d-nomlst >/dev/null 2>&1
echo "=== start container, let entrypoint append, but keep it up ==="
docker run -d --name d-nomlst -v /tmp/diag/nm/vsftpd:/etc/vsftpd -e FTP_USER=test -e FTP_PASS=test -e PASV_ADDRESS=127.0.0.1 -e PASV_MIN_PORT=30100 -e PASV_MAX_PORT=30199 -e PASV_ENABLE=YES -e PASV_ADDR_RESOLVE=NO -e FILE_OPEN_MODE=0666 -e LOCAL_UMASK=022 -e XFERLOG_STD_FORMAT=NO -e PASV_PROMISCUOUS=NO -e PORT_PROMISCUOUS=NO jmoyer/vsftpd:latest
sleep 6
echo "=== full config after entrypoint appended ==="
cat /tmp/diag/nm/vsftpd/vsftpd.conf
echo "=== run vsftpd manually in a fresh container, config only, capture fd0 and stderr ==="
docker run --rm -v /tmp/diag/nm/vsftpd:/etc/vsftpd --entrypoint /bin/sh jmoyer/vsftpd:latest -c "/usr/sbin/vsftpd /etc/vsftpd/vsftpd.conf; echo RC=\$?" 2>&1 | head -40
echo "=== isolate: which single directive breaks it ==="
docker run --rm -v /tmp/diag/nm/vsftpd:/etc/vsftpd --entrypoint /bin/sh jmoyer/vsftpd:latest -c "grep -v cmds_denied /etc/vsftpd/vsftpd.conf > /tmp/c1 && /usr/sbin/vsftpd /tmp/c1 & sleep 2; kill %1 2>/dev/null; echo RC=\$?" 2>&1 | head -20
docker rm -f d-nomlst >/dev/null 2>&1

#!/bin/sh
set -x
docker version
docker run -d --name d-full -p 2121:2121 -p 30000-30099:30000-30099 jmoyer/vsftpd:latest || echo "full run failed"
sleep 3
docker ps -a
docker inspect d-full | grep -E '"Status"|"ExitCode"|"Running"'
python3 -c "import socket;s=socket.create_connection(('127.0.0.1',2121),5);print('full banner',repr(s.recv(100)))" || echo "full probe failed"
echo "===== now no-mlst ====="
mkdir -p /tmp/diag/nm/vsftpd
cp testdata/ftp/vsftpd-base.conf /tmp/diag/nm/vsftpd/vsftpd.conf
cat testdata/ftp/vsftpd-no-mlst.conf >> /tmp/diag/nm/vsftpd/vsftpd.conf
printf 'listen_port=2122\n' >> /tmp/diag/nm/vsftpd/vsftpd.conf
chmod -R a+rwX /tmp/diag/nm
docker run -d --name d-nomlst -p 2122:2122 -p 30100-30199:30100-30199 -v /tmp/diag/nm/vsftpd:/etc/vsftpd -e FTP_USER=test -e FTP_PASS=test -e PASV_ADDRESS=127.0.0.1 -e PASV_MIN_PORT=30100 -e PASV_MAX_PORT=30199 -e PASV_ENABLE=YES -e PASV_ADDR_RESOLVE=NO -e FILE_OPEN_MODE=0666 -e LOCAL_UMASK=022 -e XFERLOG_STD_FORMAT=NO -e PASV_PROMISCUOUS=NO -e PORT_PROMISCUOUS=NO jmoyer/vsftpd:latest || echo "nomlst run failed"
sleep 5
docker inspect d-nomlst | grep -E '"Status"|"ExitCode"|"Running"'
docker logs d-nomlst
echo "--- nomlst conf tail ---"
docker exec d-nomlst cat /etc/vsftpd/vsftpd.conf || echo "exec failed"
echo "--- listeners ---"
docker exec d-nomlst ss -ltn || docker exec d-nomlst netstat -ltn || echo "no ss"
python3 -c "import socket;s=socket.create_connection(('127.0.0.1',2122),5);print('nomlst banner',repr(s.recv(100)))" || echo "nomlst probe failed"
sleep 5
python3 -c "import socket;s=socket.create_connection(('127.0.0.1',2122),5);print('nomlst banner2',repr(s.recv(100)))" || echo "nomlst probe2 failed"
docker rm -f d-full d-nomlst || true

#!/bin/sh
set -x
mkdir -p /tmp/diag/a /tmp/diag/b
# config A: with cmds_denied, ordered exactly like start-ftp.sh
cp testdata/ftp/vsftpd-base.conf /tmp/diag/a/vsftpd.conf
cat testdata/ftp/vsftpd-no-mlst.conf >> /tmp/diag/a/vsftpd.conf
printf "listen_port=2122\n" >> /tmp/diag/a/vsftpd.conf
{
  echo "pasv_address=127.0.0.1"
  echo "pasv_max_port=30199"
  echo "pasv_min_port=30100"
  echo "pasv_addr_resolve=NO"
  echo "pasv_enable=YES"
  echo "file_open_mode=0666"
  echo "local_umask=022"
  echo "xferlog_std_format=NO"
  echo "pasv_promiscuous=NO"
  echo "port_promiscuous=NO"
} >> /tmp/diag/a/vsftpd.conf
# config B: identical but WITHOUT cmds_denied
grep -v '^cmds_denied' /tmp/diag/a/vsftpd.conf > /tmp/diag/b/vsftpd.conf
echo "===== A (with cmds_denied) ====="
timeout 6 docker run --rm -v /tmp/diag/a:/c --entrypoint /bin/sh jmoyer/vsftpd:latest -c "cat /tmp/diag/a 2>/dev/null; /usr/sbin/vsftpd /c/vsftpd.conf < /dev/null; echo A_RC=\$?" 2>&1 | tail -20
echo "===== B (without cmds_denied) ====="
timeout 6 docker run --rm -v /tmp/diag/b:/c --entrypoint /bin/sh jmoyer/vsftpd:latest -c "/usr/sbin/vsftpd /c/vsftpd.conf < /dev/null & sleep 3; kill %1 2>/dev/null; wait 2>/dev/null; echo B_DONE" 2>&1 | tail -20
echo "===== A direct, capture fd1+fd2 explicitly ====="
docker run --rm -v /tmp/diag/a:/c --entrypoint /bin/sh jmoyer/vsftpd:latest -c "/usr/sbin/vsftpd /c/vsftpd.conf </dev/null 1>/tmp/out 2>/tmp/err; echo RC=\$?; echo STDOUT:; cat /tmp/out; echo STDERR:; cat /tmp/err" 2>&1 | tail -20

#!/bin/sh
set -x
d=/tmp/diag-conf/x; rm -rf "$d"; mkdir -p "$d"
cp testdata/ftp/vsftpd-base.conf "$d/vsftpd.conf"
printf 'cmds_denied=MLST,MLSD\n' >> "$d/vsftpd.conf"
printf 'listen_port=2122\n' >> "$d/vsftpd.conf"
chmod -R a+rwX "$d"
echo "### host side file ###"; ls -la "$d"; grep -c "^listen=" "$d/vsftpd.conf"
docker rm -f c-x >/dev/null 2>&1
docker run --rm -v "$d:/etc/vsftpd" --entrypoint /bin/sh jmoyer/vsftpd:latest -c '
  echo "### inside container ###"
  ls -la /etc/vsftpd/ || true
  echo "--- listen lines ---"
  grep -n "^listen" /etc/vsftpd/vsftpd.conf || echo "NO FILE"
  echo "--- run vsftpd ---"
  /usr/sbin/vsftpd /etc/vsftpd/vsftpd.conf 0>/tmp/fd0 2>/tmp/fd2
  echo "rc=$?"
  echo "--- fd0 ---"; cat /tmp/fd0
  echo "--- fd2 ---"; cat /tmp/fd2
' 2>&1 | tail -30

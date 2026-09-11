#!/bin/sh
set -x
# Run the REAL start-ftp.sh, then inspect each container and probe logins.
FTP_ROOT="$PWD/.tmp/ftp-root" FTP_CONF_ROOT="$PWD/.tmp/ftp-conf"
export FTP_ROOT FTP_CONF_ROOT
echo "### PWD=$PWD ###"
ls -la .tmp 2>/dev/null
echo "### starting profiles one by one, with the real script ###"
rm -rf .tmp/ftp-root .tmp/ftp-conf
for p in full no-mlst no-time no-epsv; do
  echo "===== PROFILE $p ====="
  PROFILES="$p" scripts/start-ftp.sh 2>&1 | tail -25
  echo "start-ftp.sh rc for $p = $?"
  name="moonbit-ftp-$p"
  echo "status=$(docker inspect -f '{{.State.Status}}' $name 2>/dev/null) exit=$(docker inspect -f '{{.State.ExitCode}}' $name 2>/dev/null)"
  echo "--- conf seen by daemon ---"
  docker exec $name sh -c 'tail -18 /etc/vsftpd/vsftpd.conf' 2>&1 | head -25
  echo "--- home seen by daemon ---"
  docker exec $name sh -c 'ls -la /home/vsftpd/test | head -5' 2>&1 | head -8
  echo "--- try login ---"
  docker exec $name sh -c 'echo PWD_MARK; pwd' 2>&1 | head -3
done
scripts/stop-ftp.sh >/dev/null 2>&1 || true

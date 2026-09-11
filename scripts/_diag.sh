#!/bin/sh
set -x
run() {
  name="$1"; shift
  d="/tmp/diag/$name"; mkdir -p "$d"
  cp testdata/ftp/vsftpd-base.conf "$d/vsftpd.conf"
  printf 'listen_port=2122\n' >> "$d/vsftpd.conf"
  printf 'pasv_address=127.0.0.1\npasv_max_port=30199\npasv_min_port=30100\npasv_enable=YES\n' >> "$d/vsftpd.conf"
  for line in "$@"; do printf '%s\n' "$line" >> "$d/vsftpd.conf"; done
  docker run --rm -v "$d:/c" --entrypoint /bin/sh jmoyer/vsftpd:latest -c "/usr/sbin/vsftpd /c/vsftpd.conf </dev/null 1>/tmp/o 2>/tmp/e; echo RC=\$? OUT=\$(cat /tmp/o) ERR=\$(cat /tmp/e)" 2>/dev/null
}
echo "baseline:            $(run base)"
echo "cmds_denied=MLST,MLSD:  $(run mlst_mlsd 'cmds_denied=MLST,MLSD')"
echo "cmds_denied=MLST:       $(run mlst 'cmds_denied=MLST')"
echo "cmds_denied=MLSD:       $(run mlsd 'cmds_denied=MLSD')"
echo "cmds_denied=DELE:       $(run dele 'cmds_denied=DELE')"
echo "cmds_denied=EPSV:       $(run epsv 'cmds_denied=EPSV')"
echo "cmds_denied=MDTM:       $(run mdtm 'cmds_denied=MDTM')"
echo "cmds_denied=MDTM,MFMT:  $(run mdtm_mfmt 'cmds_denied=MDTM,MFMT')"

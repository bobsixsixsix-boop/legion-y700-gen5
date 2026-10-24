#!/usr/bin/env bash
# 用法：./apply.sh batch1.txt [adb序列号]
# 逐个 pm disable-user --user 0，结果追加到 applied.log。可用 restore.sh 恢复。
set -u
list=$1; S=${2:-}; A="adb ${S:+-s $S}"
ts=$(date +%Y%m%d-%H%M%S)
# 先备份包状态（只能 root 读）
$A shell "su -c 'cp /data/system/users/0/package-restrictions.xml /data/local/tmp/package-restrictions-$ts.xml'" \
  && $A shell "su -c 'cat /data/local/tmp/package-restrictions-$ts.xml'" > "backup/package-restrictions-$ts.xml"
grep -v '^#' "$list" | cut -f1 | grep . | while read -r p; do
  r=$($A shell "pm disable-user --user 0 $p" </dev/null 2>&1 | tr -d '\r')
  echo "$ts $list $p :: $r" | tee -a applied.log
done

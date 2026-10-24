#!/usr/bin/env bash
# 用法：./restore.sh batch1.txt [adb序列号]   —— 把清单里的包全部重新启用
# 或：./restore.sh 包名 [adb序列号]          —— 只恢复一个
set -u
S=${2:-}; A="adb ${S:+-s $S}"
if [ -f "$1" ]; then pkgs=$(grep -v '^#' "$1" | cut -f1 | grep .); else pkgs=$1; fi
for p in $pkgs; do echo "$p :: $($A shell "su -c 'pm enable $p'" </dev/null 2>&1 | tr -d '\r')"; done

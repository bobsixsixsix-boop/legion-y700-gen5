#!/bin/bash
# 9008 way back: write the stock ColorOS 17 boot image into boot_a, read it back, reboot.
# Use when a Linux test kernel hangs before its emergency key works.
# Tablet: unplug, hold power+vol-down >8 s, then hold vol-up while plugging in (~10 s) -> 9008.
set -e
cd "$(dirname "$0")/../edl-win"
L=--loader=C:/Users/me/AI/y700/y700-recovery/loader/qsahara_device_programmer.xml
IMG=../coloros-v17/image/boot_a.img
WANT=5173be64d8f33749f477d59196367bdeee9536080109fb152a659a51b9ac0073
export PYTHONIOENCODING=utf-8 PYTHONUTF8=1
D=../flash-logs/$(date +%Y%m%d-%H%M%S)-restore-boot; mkdir -p $D
./venv/Scripts/python edl.py w boot_a $IMG --lun=4 $L --memory=ufs >$D/edl.log 2>&1
./venv/Scripts/python edl.py r boot_a $D/readback.img --lun=4 $L --memory=ufs >>$D/edl.log 2>&1
got=$(sha256sum $D/readback.img | cut -c1-64)
echo "boot_a readback $got"
[ "$got" = "$WANT" ] && echo "OK: boot_a is ColorOS again" || { echo "MISMATCH - do not reboot"; exit 1; }
rm -f $D/readback.img
./venv/Scripts/python edl.py reset --resetmode=reset $L >>$D/edl.log 2>&1 || true
echo "rebooting"

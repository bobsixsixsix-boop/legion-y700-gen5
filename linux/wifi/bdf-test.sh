#!/bin/bash
# y700: try the BDF/regdb of the flashed (PRC) modem partition instead of the ROW-extracted ones.
# Keeps them only if Wi-Fi still comes up; otherwise puts the originals back. Logs to /root/bdf-test.log.
F=/lib/firmware/ath12k/WCN7860/hw2.0; MOD=/mnt/modem/image/peach; L=/root/bdf-test.log; : > $L
I=wlp1s0; D=/root/wifi5g; mkdir -p $D; chmod 700 $D
[ -f $F/board.bin.row ] || cp -a $F/board.bin $F/board.bin.row
[ -f $F/regdb.bin.row ] || cp -a $F/regdb.bin $F/regdb.bin.row
reload() { rmmod ath12k_wifi7 ath12k 2>/dev/null; sleep 1; modprobe ath12k_wifi7; sleep 12; }
up6g() { nmcli dev set $I managed yes; sleep 3; nmcli con up HOME_6G >/dev/null 2>&1 || nmcli con up HOME_2.4G >/dev/null 2>&1; }
revert() { cp -a $F/board.bin.row $F/board.bin; cp -a $F/regdb.bin.row $F/regdb.bin; reload; up6g; echo "REVERTED to ROW files" >> $L; }
( sleep 600; echo WATCHDOG >> $L; revert; echo DONE >> $L ) & WD=$!
cp $MOD/bdwlan.elf $F/board.bin; cp $MOD/regdb.bin $F/regdb.bin; sync
echo "board=$(sha256sum $F/board.bin | cut -c1-16) regdb=$(sha256sum $F/regdb.bin | cut -c1-16)" >> $L
reload; dmesg | tail -40 | grep -iE "ath12k.*(fail|error|board)" >> $L
up6g; sleep 5
s6=$(nmcli -t -f NAME,DEVICE con show --active | grep -c "HOME_6G:$I")
p6=$(ping -c 20 -i 0.2 -W 2 192.168.0.1 | grep -oE "[0-9.]+% packet loss")
echo "6G after swap: active=$s6 ping=$p6 $(iw dev $I link | grep -E "tx bitrate" | tr -s " \t" " ")" >> $L
if [ "$s6" != 1 ]; then revert; kill $WD; echo DONE >> $L; exit; fi
# 5G through NetworkManager, 60 s
f0=$(dmesg | grep -c "failed to flush transmit queue")
nmcli con up HOME_5G >/dev/null 2>&1; sleep 3
t0=$(date +%s)
p5=$(ping -i 0.2 -w 60 -q 192.168.0.1 2>&1 | grep -oE "[0-9.]+% packet loss")
bl=$(journalctl -u wpa_supplicant --since "@$t0" --no-pager -o cat | grep -c BEACON-LOSS)
dc=$(journalctl -u wpa_supplicant --since "@$t0" --no-pager -o cat | grep -c "CTRL-EVENT-DISCONNECTED")
f1=$(dmesg | grep -c "failed to flush transmit queue")
echo "5G 60s: ping=$p5 beacon_loss=$bl disconnects=$dc flushfail_new=$((f1-f0)) $(iw dev $I link | grep -E "freq|tx bitrate" | tr -s " \t" " " | tr "\n" " ")" >> $L
nmcli con up HOME_6G >/dev/null 2>&1
kill $WD; echo "kept PRC files (originals in *.row)" >> $L; echo DONE >> $L

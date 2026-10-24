#!/bin/bash
# y700: HOME_5G stability with ath12k idle_ps=false for WCN7860 (test module).
# The other SSIDs have autoconnect off meanwhile, so NetworkManager cannot hop away.
I=wlp1s0; L=/root/wifi5g-noidle.log; : > $L; D=/usr/local/lib/modules/y700-noidleps
stock() {
	nmcli con mod HOME_6G connection.autoconnect yes; nmcli con mod HOME_2.4G connection.autoconnect yes
	rmmod ath12k_wifi7 ath12k 2>/dev/null; sleep 1; modprobe ath12k_wifi7; sleep 12
	nmcli con up HOME_6G >/dev/null 2>&1 || nmcli con up HOME_2.4G >/dev/null 2>&1
	echo "restored: $(nmcli -t -f NAME,DEVICE con show --active | grep $I)" >> $L
}
( sleep 300; echo WATCHDOG >> $L; stock; echo DONE >> $L ) & WD=$!
nmcli con mod HOME_6G connection.autoconnect no; nmcli con mod HOME_2.4G connection.autoconnect no
rmmod ath12k_wifi7 ath12k; sleep 1; insmod $D/ath12k.ko && insmod $D/ath12k_wifi7.ko; sleep 12
nmcli con up HOME_5G >/dev/null 2>&1; sleep 3; t0=$(date +%s)
echo "link: $(iw dev $I link | grep -E "freq|tx bitrate" | tr -s " \t" " " | tr "\n" " ")" >> $L
p=$(ping -i 0.2 -w 90 -q 192.168.0.1 2>&1 | grep -oE "[0-9.]+% packet loss")
j=$(journalctl -u wpa_supplicant --since "@$t0" --no-pager -o cat)
echo "5G noidleps 90s: ping=$p beacon_loss=$(echo "$j" | grep -c BEACON-LOSS) disconnects=$(echo "$j" | grep -c CTRL-EVENT-DISCONNECTED) bcn_rx=$(iw dev $I station dump | awk '/beacon rx/{print $3}')" >> $L
kill $WD; stock; echo DONE >> $L

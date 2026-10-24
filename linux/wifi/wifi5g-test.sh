#!/bin/bash
# y700: HOME_5G stability by feature set, outside NetworkManager. Wi-Fi goes away while it runs;
# it always hands wlp1s0 back to NetworkManager (trap + 8-minute watchdog).
I=wlp1s0; D=/root/wifi5g; L=$D/result.log; mkdir -p $D; : > $L; chmod 700 $D
CTRL=/run/y700wpa; MAC=02:00:00:00:00:10
restore() {
	pkill -f "wpa_supplicant -i $I -c $D/" 2>/dev/null; sleep 1
	ip addr flush dev $I 2>/dev/null; rm -f $D/*.conf
	nmcli dev set $I managed yes; sleep 3; nmcli con up HOME_6G >/dev/null 2>&1 || nmcli con up HOME_2.4G >/dev/null 2>&1
	echo "restored: $(nmcli -t -f NAME,DEVICE con show --active | grep $I)" >> $L
}
( sleep 480; echo "WATCHDOG fired" >> $L; restore ) & WD=$!
trap "kill $WD 2>/dev/null; restore; echo DONE >> $L" EXIT
PSK=$(nmcli -s -g 802-11-wireless-security.psk con show HOME_5G)
nmcli dev set $I managed no; sleep 3
ip link set $I down; ip link set $I address $MAC; ip link set $I up
run() {
	name=$1; shift
	{ echo "ctrl_interface=$CTRL"; echo "network={"; echo " ssid=\"HOME_5G\""; echo " key_mgmt=SAE"
	  echo " sae_password=\"$PSK\""; echo " ieee80211w=2"; for o in "$@"; do echo " $o"; done; echo "}"; } > $D/$name.conf
	chmod 600 $D/$name.conf
	wpa_supplicant -i $I -c $D/$name.conf -B -t -f $D/$name.wpa.log -P $D/wpa.pid
	for t in $(seq 1 30); do wpa_cli -p $CTRL -i $I status 2>/dev/null | grep -q wpa_state=COMPLETED && break; sleep 1; done
	ip addr flush dev $I; ip addr add 192.168.0.81/24 dev $I
	link=$(iw dev $I link | grep -E "freq|tx bitrate" | tr -s " \t" " " | tr "\n" " ")
	loss=$(ping -i 0.2 -w 40 -q 192.168.0.1 2>&1 | grep -oE "[0-9.]+% packet loss")
	bl=$(grep -c BEACON-LOSS $D/$name.wpa.log); dc=$(grep -c CTRL-EVENT-DISCONNECTED $D/$name.wpa.log)
	fl=$(dmesg | grep -c "failed to flush transmit queue")
	echo "$name: connect_s=$t beacon_loss=$bl disconnects=$dc ping_loss=$loss flushfail_total=$fl | $link | opts: $*" >> $L
	pkill -F $D/wpa.pid; sleep 2; ip addr flush dev $I
}
run eht
run he disable_eht=1
run vht disable_eht=1 disable_he=1
run ht40 disable_eht=1 disable_he=1 disable_vht=1

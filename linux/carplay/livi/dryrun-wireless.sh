#!/bin/bash
# linux/carplay/livi/dryrun-wireless.sh -- LIVI headless with its wireless side up, checked without a phone (2026-10-20):
# the hotspot, LIVI's Bluetooth profiles (iAP2/CarPlay, HFP, Android Auto's RFCOMM), Android Auto's BLE advertisement
# and TCP listener, through the real launcher (y700-carplay, no UI, no compositor), 60 s then TERM, then the state
# after. dryrun.sh is the run that keeps Wi-Fi (wireless off); this one takes wlp1s0 for the hotspot, so the ssh
# session drops for ~2 min. It therefore runs detached in a transient unit, with test-guard.sh armed (8 min) first.
# Root, on the tablet from /root/src-carplay-livi/, LIVI not running:
#   dryrun-wireless.sh     start it and return; results in /root/livi-dryrun-wireless.txt once ssh is back
# Reads only the two wireless switches from config.json (it holds the Wi-Fi passphrase); every log line goes through
# the passphrase filter. Run it again after a LIVI upgrade or a change to the launcher.
# LIVI starts without sudo's SUDO_USER: livi-core writes that user into livi-wifi-ap.service, and as root the
# hotspot's helperd finds no config.json and tries wlan0 (the first 10-20 run; see UE).
export LC_ALL=C
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=/root/livi-dryrun-wireless.txt
U=user
H=/home/$U
CFG=$H/.config/LIVI/config.json
CORE='^/opt/livi-10.0.0/resources/core/livi-core'
UE="sudo -u $U env -u SUDO_USER -u SUDO_UID -u SUDO_GID -u SUDO_COMMAND XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus"
AA_UUID=4de17a00-52cb-11e6-bdf4-0800200c9a66

[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
cut_secrets() { sed -E 's/((passphrase|password|sae_password|wpa_psk|psk)[^a-z_-]).*/\1 [cut]/I'; }

if [ "${1:-}" != --run ]; then
    pgrep -f "$CORE" >/dev/null && { echo "LIVI is running - quit it first"; exit 1; }
    bash "$HERE/test-guard.sh" arm 8 || exit 1
    systemd-run --quiet --unit=y700-livi-dryrun-wireless --collect /bin/bash "$HERE/dryrun-wireless.sh" --run
    echo "started: ssh drops in a few seconds, back ~2-3 min later; then cat $OUT"
    exit 0
fi

exec >"$OUT" 2>&1
snap() {
    echo "## $1 $(date +%T)"
    # every tool under timeout: btmgmt never returns without a terminal (10-20, the first run hung right here)
    bt=$(timeout 5 bluetoothctl show </dev/null)
    echo "$bt" | grep -E 'Alias|Class|Powered|Discoverable|Pairable|ActiveInstances'
    u=$(echo "$bt" | tr 'A-Z' 'a-z')
    # HFP is not in this list even while LIVI runs: its HF profile is Role=client (the tablet calls the phone), and
    # BlueZ publishes no SDP record for that; the log's "[hfp] HF profile registered" is the evidence
    case "$u" in *"$AA_UUID"*) echo "uuid android auto: yes" ;; *) echo "uuid android auto: no" ;; esac
    timeout 5 btmgmt --index 0 info </dev/null | grep 'current settings'
    echo "livi-wifi-ap: $(systemctl is-active livi-wifi-ap.service), unit $(grep -o 'SUDO_USER=.*' /etc/systemd/system/livi-wifi-ap.service)"
    timeout 5 iw dev wlp1s0 info 2>&1 | grep -E 'type|channel'
    echo "tcp listening: $(ss -Hltn | awk '{print $4}' | grep -E ':(5277|7000)$' | tr '\n' ' ')"
    timeout 10 nmcli -t -f DEVICE,STATE,CONNECTION dev | grep wlp1s0
}
echo "== $(date '+%F %T') config: $(python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); print("wirelessCpEnabled", c.get("wirelessCpEnabled"), "wirelessAaEnabled", c.get("wirelessAaEnabled"))' "$CFG")"
snap before
t0=$(date +%s)
$UE HOME=$H LIVI_NO_UI=1 LIVI_NO_COMPOSITOR=1 timeout -k 20 -s TERM 60 /usr/local/bin/y700-carplay &
lp=$!
sleep 40
snap "during (40 s)"
wait $lp
echo "launcher rc=$? after $(( $(date +%s) - t0 )) s"
echo "== guard restore"
bash "$HERE/test-guard.sh" restore
bash "$HERE/test-guard.sh" disarm
i=0
while [ $i -lt 60 ] && ! nmcli -t -f DEVICE,STATE dev | grep -q '^wlp1s0:connected$'; do sleep 2; i=$((i + 1)); done
snap after
echo "== launcher and LIVI log: wireless lines"
# the launcher's log holds LIVI's own lines too: each line once; the iPhone's reconnect pages (it is not here) left out
grep -h -E '\[(aa|hfp|bt|helperd|wifi|wifi-ap|cp)\]|BLE|profile|advertis|error|fail|refus' \
    $H/.cache/y700-carplay/livi.log $H/.config/LIVI/log/LIVI.log 2>/dev/null | awk '!seen[$0]++' | cut_secrets |
    grep -v -E 'reconnect: (paging|.*br-connection-refused)' | cut -c1-220 | head -120
echo "== hotspot (journal of livi-wifi-ap)"
journalctl -u livi-wifi-ap.service --since "@$t0" --no-pager -o short 2>&1 | cut_secrets |
    grep -E 'wifi-ap\]|ap-settle|AP-ENABLED|AP-DISABLED|AP-STA|refused|failed|Started|Stopped' | cut -c1-220 | head -60
echo "== leftovers"
pgrep -a -f 'livi-(core|helperd|compositor|gst)|avahi-(daemon|publish|browse)' || echo none
echo "== checklist"
y700-checklist 2>&1 | grep -E 'CarPlay|WARN' | cut -c1-300
echo "== done $(date +%T)"

#!/bin/bash
# linux/carplay/livi/dryrun.sh -- LIVI dry run on the tablet (root): wireless CarPlay switched off for the run, no UI,
# no compositor, through the real launcher (y700-carplay), 60 s then TERM; state before/after, the launcher log (any
# passphrase line filtered out), leftovers, and y700-checklist against /root/livi-baseline-checklist-20261017.txt.
# Wi-Fi stays with NetworkManager, so it is safe over ssh. Run it again after any LIVI upgrade (2026-10-17).
# Both wireless switches go off for the run, as either one makes LIVI take wlp1s0 for its hotspot (wireless Android
# Auto is on since 10-20), and go back as they were afterwards. LIVI starts without sudo's SUDO_USER (see UE).
# Since LIVI 10.0.0 that is not free any more (10-23, livi-runtime/src/bluetoothd.rs): the helper fits bluetoothd to
# the wireless switches - with both off it removes its --noplugin drop-in, takes its car-kit Class out of main.conf
# and restarts bluetoothd, and the next start with them on puts both back and restarts it again. Every paired device
# (keyboard, headphones, the iPhone) drops twice. So it asks for Y700_BT_RESTART_OK=1, after telling the owner;
# dryrun-wireless.sh runs with the switches as they are and leaves bluetoothd alone (but takes Wi-Fi for ~2 min).
export LC_ALL=C
if [ "${Y700_BT_RESTART_OK:-}" != 1 ]; then
    echo "LIVI >= 10 restarts bluetoothd twice for this dry run (see the head of $0); Y700_BT_RESTART_OK=1 to go on"
    exit 1
fi
U=user; H=/home/$U; CFG=$H/.config/LIVI/config.json
# Without sudo's SUDO_* variables: livi-core takes the user from SUDO_USER (root here) and writes it into
# livi-wifi-ap.service, whose helperd then reads root's (missing) config.json and runs the hotspot on wlan0 (10-20).
UE="sudo -u $U env -u SUDO_USER -u SUDO_UID -u SUDO_GID -u SUDO_COMMAND XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus"
snap() {
  echo "## $1 $(date +%T)"
  bluetoothctl show | grep -E 'Name|Alias|Class|Powered|Discoverable|Pairable'
  grep -n -E '^\s*#?\s*Class' /etc/bluetooth/main.conf
  echo "bt dropins: $(ls /etc/systemd/system/bluetooth.service.d/ 2>&1)"
  cat /etc/systemd/system/bluetooth.service.d/* 2>/dev/null
  systemctl show bluetooth -p ExecMainStartTimestamp -p MainPID
  echo "wp dropins: $(ls $H/.config/wireplumber/wireplumber.conf.d/ 2>&1)"
  $UE systemctl --user show wireplumber -p ExecMainStartTimestamp -p MainPID
  $UE pactl get-default-sink
  $UE pactl list short sinks | cut -f2
  echo "nm conf.d: $(ls /etc/NetworkManager/conf.d/)"
  echo "livi-wifi-ap: $(systemctl is-active livi-wifi-ap.service)"
  nmcli -t -f DEVICE,STATE,CONNECTION dev | grep wlp1s0
  echo "sudoers.d: $(ls /etc/sudoers.d/)"
  echo "avahi: $(systemctl is-active avahi-daemon.service)"
  echo "i2c-99: $([ -e /dev/i2c-99 ] && echo present || echo missing)"
  echo "gvfs: $(pgrep -u $U -l gvfs | awk '{print $2}' | sort | tr '\n' ' ')"
}
echo "== env through the shim"; sudo -u $U env LIVI_T=kept PATH=/usr/local/lib/y700-carplay/bin:/usr/bin:/bin sudo -n -E /usr/bin/env | grep LIVI_T || echo "LIVI_T lost"
snap before > /root/livi-dry-before.txt 2>&1
SW='("wirelessCpEnabled", "wirelessAaEnabled")'
was=$($UE python3 -c "import json,sys; c=json.load(open(sys.argv[1])); print(json.dumps({k: c[k] for k in $SW if k in c}))" "$CFG")
echo "wireless switches before: $was"
$UE python3 -c "import json,sys; p=sys.argv[1]; c=json.load(open(p)); c.update(dict.fromkeys($SW, False)); open(p,'w').write(json.dumps(c,indent=2)+'\n')" "$CFG"
echo "wireless now: $(python3 -c "import json,sys; c=json.load(open(sys.argv[1])); print([c.get(k) for k in $SW])" $CFG)"
t0=$(date +%s)
$UE HOME=$H LIVI_NO_UI=1 LIVI_NO_COMPOSITOR=1 timeout -k 20 -s TERM 60 /usr/local/bin/y700-carplay
echo "launcher rc=$? after $(( $(date +%s) - t0 )) s"
sleep 2
snap after > /root/livi-dry-after.txt 2>&1
$UE python3 -c "import json,sys; p=sys.argv[1]; c=json.load(open(p)); w=json.loads(sys.argv[2])
for k in $SW:
    c.__setitem__(k, w[k]) if k in w else c.pop(k, None)
open(p,'w').write(json.dumps(c,indent=2)+'\n')" "$CFG" "$was"
echo "wireless switches after: $(python3 -c "import json,sys; c=json.load(open(sys.argv[1])); print(json.dumps({k: c[k] for k in $SW if k in c}))" $CFG)"
stat -c '%a %U' "$CFG"
echo "===== diff before/after"; diff /root/livi-dry-before.txt /root/livi-dry-after.txt
echo "===== launcher log"; cat $H/.cache/y700-carplay/livi.log | grep -v -i -E 'passphrase|password|LIVI_PASSPHRASE' | head -120
echo "===== LIVI log dir"; ls -la $H/.config/LIVI/ $H/.config/LIVI/log/ 2>&1
echo "===== leftovers"; pgrep -a -f 'livi-(core|helperd|compositor|gst)|avahi-(daemon|publish|browse)' || echo none
echo "===== checklist vs baseline"; y700-checklist > /root/livi-after-checklist.txt 2>&1; echo "rc=$?"
diff <(cut -c1-60 /root/livi-baseline-checklist-20261017.txt) <(cut -c1-60 /root/livi-after-checklist.txt) && echo "checklist same as baseline"

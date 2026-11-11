#!/bin/bash
# linux/carplay/livi/install-livi.sh -- set LIVI 10.3.0 up for the y700 "CarPlay" icon, by hand instead of LIVI's own
# install.sh (2026-10-17; 9.4.0 until 10-23, 10.0.0 until 11-04). Run as root on the tablet from a copy of this
# directory; running it again is safe.
#
# Expects /opt/livi-10.3.0 (the official arm64 AppImage unpacked with --appimage-extract, /opt/livi -> it) and the
# MFi authentication coprocessor on I2C bus 99 (/dev/i2c-99, not part of this tree), and gcc (for the colorimetry shim). Does:
#   0. the unpacked tree's directories 0755: 10.0.0's AppImage has them at 0700, which works on its FUSE mount (owned
#      by whoever runs it) but, unpacked as root, kept the desktop user out of resources/ (10-23); a file or
#      directory anyone but root may write stops the install
#   1. a tarball of everything LIVI changes, once: /root/livi-preinstall-<date>.tgz
#   2. /etc/sudoers.d/99-LIVI-helper from LIVI's template, pointed at /opt (root-owned) instead of
#      ~/.config/LIVI/driver/, where livi-core only copies the helper when it runs from an AppImage mount
#   3. the touch filter and LIVI's udev rule without its Android vendor lines (below)
#   4. rtprio for the desktop user (LIVI's install.sh does the same; from the next login)
#   5. avahi-daemon disabled at boot - y700-carplay starts it while CarPlay runs
#   6. /usr/local/bin/y700-carplay, the sudo shim LIVI runs under (./sudo: classic sudo, sudo-rs drops -E),
#      y700-carplay-boot-guard.service, y700-carplay-ap-tune (+ its unit) and y700-carplay-ap-settle with the
#      livi-wifi-ap.service drop-in that runs both (settle: hostapd waits for wpa_supplicant to let go of the
#      interface, then for a fresh Wi-Fi firmware - ath12k reloaded; tune: a hostapd debug log) and, when the
#      access point stops, y700-carplay-ps-restore (LIVI leaves the station's power save off) with its
#      NetworkManager dispatcher hook 90-y700-carplay-ps (when wlp1s0 is not a station again in time), the colorimetry
#      shim /usr/local/lib/y700-carplay/y700-gst-colorimetry.so built from source (without it the iPhone's video
#      does not get the hardware decoder: black), the menu entry and the desktop icon, and a KWin rule (kwinrulesrc,
#      y700-livi-fullscreen: app_id dev.f-io.livi, title LIVI, full screen forced). 10.0.0's livi-core sizes the
#      window for kiosk.main but never tells livi-compositor, which goes full screen only for LIVI_KIOSK=1 or when the
#      host says so; it opened windowed, 32 px title bar on top, 1034 px tall, the dock cut off (10-23). LIVI_KIOSK=1
#      is not the way: livi-core then owns the host, and Power Off / Restart in its settings shut down the tablet.
#   7. ~/.config/LIVI/config.json if there is none: wireless CarPlay and wireless Android Auto (10-20) on wlp1s0,
#      5 GHz ch 36/80 MHz, JP, the MFi coprocessor on bus 99, full screen at the panel's size, the phones asked for
#      1600x1000 with no dpi of ours (10.0.0 sizes CarPlay's screen from it, 10-23), LIVI's dashboard and its vehicle
#      climate off (60 fps; the iPhone's own dock), a random Wi-Fi passphrase made here (the phone gets it over
#      Bluetooth, nobody types it); an existing one is kept, with a note if its dashboard or climate is on, wireless
#      Android Auto is off or the projection is not that
# Left out of LIVI's install.sh, and why:
#   - autostart at login: the tablet is a daily desktop, CarPlay starts from its icon;
#   - NetworkManager wifi.powersave=2: undoes the ath12k power save our y700-1041 build brought;
#   - a global NM pmf=2 default: touches every connection, the home 6 GHz WPA3 one included;
#   - regdom and its time helper: the phy's regulatory domain is self-managed (JP), the clock comes from NTP;
#   - the udev rule's Android vendor lines: they switch MTP and auto-mount off system-wide for those makers' phones,
#     Lenovo (17ef) included, for LIVI's wired Android Auto, which is not used here (wireless Android Auto, on since
#     10-20, never sees the phone's USB).
set -euo pipefail
export LC_ALL=C
HERE=$(cd "$(dirname "$0")" && pwd)
U=user
H=/home/$U
LIVI=/opt/livi-10.3.0
RES=$LIVI/resources
HELPER=$RES/driver/livi-helperd

[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
[ -x "$RES/core/livi-core" ] && [ -x "$HELPER" ] || { echo "no LIVI in $LIVI"; exit 1; }
[ "$(readlink -f /opt/livi)" = "$LIVI" ] || { echo "/opt/livi does not point at $LIVI"; exit 1; }

echo "0. permissions"
w=$(find "$LIVI" ! -type l \( ! -user root -o -perm /022 \) | head -3)
[ -z "$w" ] || { echo "   not root's alone: $w ..."; exit 1; }
n=$(find "$LIVI" -type d ! -perm 0755 | wc -l)
find "$LIVI" -type d ! -perm 0755 -exec chmod 0755 {} +
echo "   $n directories made 0755"
sudo -u $U test -x "$RES/core/livi-core" || { echo "   $U still cannot run $RES/core/livi-core"; exit 1; }

echo "1. backup"
if ls /root/livi-preinstall-*.tgz >/dev/null 2>&1; then
    echo "   kept: $(ls /root/livi-preinstall-*.tgz)"
else
    BK=/root/livi-preinstall-$(date +%Y%m%d).tgz
    tar czf "$BK" --ignore-failed-read /etc/bluetooth /etc/NetworkManager/conf.d \
        /etc/systemd/system/bluetooth.service.d /etc/udev/rules.d /etc/sudoers.d /etc/security/limits.d \
        "$H/.config/wireplumber" 2>/dev/null || true
    echo "   $BK ($(stat -c %s "$BK") bytes)"
fi

echo "2. sudoers"
tmp=$(mktemp)
{
    echo "# y700 (linux/carplay/livi/install-livi.sh): LIVI's 99-LIVI-helper.sudoers.template, the helper's root-owned"
    echo "# copy in $LIVI instead of ~/.config/LIVI/driver/ (only staged there when LIVI runs from an AppImage mount)."
    sed -e "s#/home/__USERNAME__/.config/LIVI/driver/livi-helperd#$HELPER#" -e "s#__USERNAME__#$U#g" \
        "$RES/99-LIVI-helper.sudoers.template"
} >"$tmp"
grep -q "$HELPER" "$tmp" || { echo "   template changed, check it"; exit 1; }
visudo -cqf "$tmp"
install -m 0440 -o root -g root "$tmp" /etc/sudoers.d/99-LIVI-helper
rm -f "$tmp"
sudo -n -l -U "$U" "$HELPER" >/dev/null && echo "   $U may run $HELPER"

echo "3. udev"
install -D -m 0755 "$RES/livi-touch-filter" /usr/local/lib/livi/livi-touch-filter
{
    echo "# y700 (linux/carplay/livi/install-livi.sh): LIVI's 99-LIVI.rules.template without the Android vendor lines."
    echo "# livi-core only looks for the version line and leaves the file alone while it is there."
    echo "# The touch filter keeps this tablet's NVT panel (no mouse interface) - checked 2026-10-17."
    grep -v -E 'ENV\{ID_MTP_DEVICE\}=""|^# Android phones' "$RES/99-LIVI.rules.template"
} >/etc/udev/rules.d/99-LIVI.rules.new
grep -q '^# LIVI-RULE-VERSION=' /etc/udev/rules.d/99-LIVI.rules.new || { echo "   no version line"; exit 1; }
mv -f /etc/udev/rules.d/99-LIVI.rules.new /etc/udev/rules.d/99-LIVI.rules
udevadm control --reload-rules
echo "   $(grep -c -v '^#' /etc/udev/rules.d/99-LIVI.rules) rules, $(grep '^# LIVI-RULE-VERSION' /etc/udev/rules.d/99-LIVI.rules)"

echo "4. rtprio"
echo "$U - rtprio 30" >/etc/security/limits.d/99-livi-rtprio.conf

echo "5. avahi on demand"
systemctl disable --now avahi-daemon.service avahi-daemon.socket 2>&1 | sed 's/^/   /'

echo "6. launcher, sudo shim, colorimetry shim, boot guard, icons, KWin rule"
install -m 0755 "$HERE/y700-carplay" /usr/local/bin/y700-carplay
install -D -m 0755 "$HERE/sudo" /usr/local/lib/y700-carplay/bin/sudo
t=$(mktemp -d)       # the old .so stays in place unless the new one built
if gcc -O2 -Wall -shared -fPIC -o "$t/y700-gst-colorimetry.so" "$HERE/y700-gst-colorimetry.c" -ldl; then
    install -m 0644 "$t/y700-gst-colorimetry.so" /usr/local/lib/y700-carplay/y700-gst-colorimetry.so
elif [ -e /usr/local/lib/y700-carplay/y700-gst-colorimetry.so ]; then
    echo "   WARNING: y700-gst-colorimetry.so not rebuilt, the one from an earlier run stays"
else
    echo "   WARNING: y700-gst-colorimetry.so not built - the iPhone's video cannot use the hardware decoder (black)"
fi
rm -rf "$t"
[ -x /usr/bin/sudo.ws ] || echo "   WARNING: no /usr/bin/sudo.ws (package sudo) - under sudo-rs LIVI cannot announce CarPlay"
install -m 0644 "$HERE/y700-carplay-boot-guard.service" /etc/systemd/system/y700-carplay-boot-guard.service
install -m 0755 "$HERE/y700-carplay-ap-tune" /usr/local/sbin/y700-carplay-ap-tune
install -m 0755 "$HERE/y700-carplay-ap-settle" /usr/local/sbin/y700-carplay-ap-settle
install -m 0755 "$HERE/y700-carplay-ps-restore" /usr/local/sbin/y700-carplay-ps-restore
install -o root -g root -m 0755 "$HERE/90-y700-carplay-ps" /etc/NetworkManager/dispatcher.d/90-y700-carplay-ps
install -m 0644 "$HERE/y700-carplay-ap-tune.service" /etc/systemd/system/y700-carplay-ap-tune.service
install -D -m 0644 "$HERE/livi-wifi-ap-y700.conf" /etc/systemd/system/livi-wifi-ap.service.d/y700.conf
systemctl daemon-reload
systemctl enable y700-carplay-boot-guard.service 2>&1 | sed 's/^/   /'
install -D -o $U -g $U -m 0644 "$HERE/dev.f-io.livi.desktop" "$H/.local/share/applications/dev.f-io.livi.desktop"
install -o $U -g $U -m 0755 "$HERE/dev.f-io.livi.desktop" "$H/Desktop/CarPlay.desktop"
RUN="runuser -u $U -- env LC_ALL=C.UTF-8 HOME=$H XDG_RUNTIME_DIR=/run/user/$(id -u $U) DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u $U)/bus"
RULE=y700-livi-fullscreen   # only when kwinrulesrc has no rule of ours yet; appended to whatever the owner made
kwrule() { $RUN kwriteconfig6 --file kwinrulesrc --group "$1" --key "$2" "$3"; }
if [ "$($RUN kreadconfig6 --file kwinrulesrc --group $RULE --key wmclass)" != dev.f-io.livi ]; then
    kwrule $RULE Description "LIVI 主屏全屏（y700，10-23）"
    kwrule $RULE fullscreen true; kwrule $RULE fullscreenrule 2
    kwrule $RULE wmclass dev.f-io.livi; kwrule $RULE wmclassmatch 1; kwrule $RULE wmclasscomplete false
    kwrule $RULE title LIVI; kwrule $RULE titlematch 1
    have=$($RUN kreadconfig6 --file kwinrulesrc --group General --key rules)
    kwrule General rules "${have:+$have,}$RULE"
    kwrule General count "$(( $($RUN kreadconfig6 --file kwinrulesrc --group General --key count --default 0) + 1 ))"
    $RUN qdbus6 org.kde.KWin /KWin org.kde.KWin.reconfigure >/dev/null 2>&1 || echo "   KWin not reached, the rule applies from the next login"
    echo "   KWin rule $RULE written"
else
    echo "   KWin rule $RULE already there"
fi

echo "7. config.json"
CFG=$H/.config/LIVI/config.json
if [ -e "$CFG" ]; then
    echo "   kept: $CFG"
    # only "dashboard(s)", "wirelessAaEnabled", "carPlayVehicleClimate" and the projection's size are read: the file
    # has the Wi-Fi passphrase
    sudo -u $U python3 - "$CFG" <<'EOF'
import json, sys
try:
    cfg = json.load(open(sys.argv[1]))
    d = cfg.get("dashboard") or {}       # 10.0.0: per screen; 9.4.0's "dashboards" slots it migrates on first start
    old = cfg.get("dashboards") or {}
    aa = cfg.get("wirelessAaEnabled")    # LIVI's default, when absent: off
    clim = cfg.get("carPlayVehicleClimate")   # 10.0.0 writes it, on
    proj = tuple(cfg.get(k) for k in ("projectionWidth", "projectionHeight", "projectionDpi"))
except Exception:
    cfg, d, old, aa, clim, proj = None, {}, {}, None, None, None
on = [s for s in ("main", "cluster", "aux") if isinstance(d, dict) and d.get(s) is True]
if on:
    print("   NOTE: LIVI's dashboard on (" + ", ".join(on) + "): LIVI then gives the iPhone a cluster display and it"
          " sends the main one at 30 fps instead of 60; set every screen in \"dashboard\" in that file to false"
          " while LIVI is not running")
elif not d and any(isinstance(v, dict) and any(v.get(s) for s in ("main", "dash", "aux")) for v in old.values()):
    print("   NOTE: a 9.4.0 \"dashboards\" slot is on: 10.0.0 turns that into its dashboard on that screen (30 fps);"
          " switch all of them off in that file while LIVI is not running")
if cfg is not None and aa is not True:
    print("   NOTE: wireless Android Auto is off: Android phones cannot connect; switch it on in LIVI's settings,"
          " or set wirelessAaEnabled to true in that file while LIVI is not running")
if cfg is not None and clim is not False:
    print("   NOTE: LIVI's vehicle climate is on: the iPhone puts two temperature controls into its dock and the clock"
          " goes; set carPlayVehicleClimate to false in that file while LIVI is not running")
if cfg is not None and (proj[0], proj[1], proj[2] or 0) != (1600, 1000, 0):
    print("   NOTE: projection %sx%s at %s dpi, not 1600x1000 with dpi 0: a dpi makes the iPhone draw for a smaller,"
          " denser screen (everything a size larger), another size gives Android Auto a smaller tier (blurred); set"
          " projectionWidth/Height/Dpi in that file while LIVI is not running"
          " (README \"换 LIVI 10.0.0\")" % tuple("-" if v is None else v for v in proj))
EOF
else
    install -d -o $U -g $U -m 0700 "$H/.config/LIVI"
    sudo -u $U python3 - "$CFG" <<'EOF'
import json, os, secrets, sys
cfg = {
    "wirelessCpEnabled": True,
    # Both share LIVI's hotspot and Bluetooth: an Android phone pairs like the iPhone does (LIVI's own HFP and its
    # Android Auto RFCOMM profile, then the same Wi-Fi), and gets 60 fps as projectionFps is LIVI's default 60.
    "wirelessAaEnabled": True,
    "wifiInterface": "wlp1s0",
    "wifiType": "5ghz",
    "wifiChannel": 36,
    "wifiChannelWidth": 80,
    "country": "JP",
    "hand": 1,
    "carName": "Y700 CarPlay",
    "wifiPassword": secrets.token_urlsafe(12),
    "carPlayMfiI2cBus": 99,
    "carPlayMfiPowerGpio": -1,
    # Full screen without window controls (the UI's kiosk); leave it in the app: Settings > System > Power Off,
    # which only quits LIVI - powering the host off needs LIVI_KIOSK=1 in the environment, never set here. Under
    # 10.0.0 it only sizes the window; the KWin rule from step 6 makes it full screen.
    "kiosk": {"main": True, "cluster": False, "aux": False},
    # The panel's logical size (3040x1904 at scale 1.9). livi-compositor publishes its output mode once, from these,
    # and keeps it when KWin makes the window fullscreen: with the 1280x720 default the UI sat in the top-left corner.
    "mainScreenWidth": 1600,
    "mainScreenHeight": 1002,
    # The size asked of the phones: the window's (1600x1002, 16:10; LIVI could not read the panel and stayed at
    # 1280x720, 16:9). Not LIVI's fit_720p (1152x720, used until 10-20): Android Auto takes the first of its tiers
    # 800x480, 1280x720, 1920x1080, ... whose 16:10 area needs at most 1.2x upscaling to this size (fitting_tier in
    # livi-aa-stack/src/config.rs), so 1152x720 got the 1280x720 tier, stretched ~2.6x onto the panel and blurred;
    # 1600x1000 gets 1920x1080 (area 1728x1080). The iPhone renders at 1600x1000 itself.
    "projectionWidth": 1600,
    "projectionHeight": 1000,
    # 0: LIVI's own. 10.0.0 also sizes the iPhone's screen from it (the mm it reports, before the panel's 268x168):
    # at 270 dpi it said 150x94 mm, the iPhone drew for a small dense screen, every control a size larger (10-23).
    # With 0 CarPlay gets the panel's mm as under 9.4.0, and Android Auto LIVI's 200 dpi for the 1080p tier
    # (864 dp tall, a quarter smaller than the 270 of 10-20, which only Android Auto read in 9.4.0); Android Auto's
    # size under 10.0.0 is still to be tried.
    "projectionDpi": 0,
    # LIVI's dashboard (the phone's cluster screen) on any screen makes LIVI advertise the phone a second, cluster
    # display, and the iPhone, encoding two, sends the main one at 30 fps instead of 60 (2026-10-18 under 9.4.0's
    # dash3/dash4; 10.0.0 asks for it whenever "dashboard" is on for any screen, and turned 9.4.0's dash1/dash2 on the
    # main screen into exactly that, 10-23).
    "dashboard": {"main": False, "cluster": False, "aux": False},
    # 10.0.0's vehicle climate (and seats) for the phone: the iPhone puts a temperature control at each end of its
    # dock for a car that has none, and the clock has no room (10-23).
    "carPlayVehicleClimate": False,
}
fd = os.open(sys.argv[1], os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
EOF
    echo "   written (passphrase not shown)"
fi

echo "done"

#!/bin/bash
# linux/carplay/livi/test-guard.sh -- safety net for a CarPlay test run over ssh (2026-10-17). While wireless CarPlay
# runs, wlp1s0 is LIVI's hotspot, the tablet is off the home Wi-Fi and the ssh session is gone; this gives it back.
# Root, on the tablet from /root/src-carplay-livi/:
#   test-guard.sh arm [MIN]   in MIN minutes (default 20) run "restore" from a transient timer (unit
#                             y700-carplay-test-guard; its output: journalctl -u y700-carplay-test-guard)
#   test-guard.sh disarm      cancel that timer
#   test-guard.sh restore     quit LIVI the way its own quit does - TERM to livi-core, after which y700-carplay stops the
#                             hotspot unit, runs the teardown if needed, ends the helper and stops avahi - then check
#                             each of those again and make sure wlp1s0 is managed by NetworkManager and connected.
#   test-guard.sh state       what restore would look at
# It never reboots and never touches the passphrase or config.json.
export LC_ALL=C
UNIT=y700-carplay-test-guard
CORE='^/opt/livi-10.0.0/resources/core/livi-core'
LAUNCHER='/usr/local/bin/y700-carplay'
HELPER=/opt/livi-10.0.0/resources/driver/livi-helperd
AP=livi-wifi-ap.service
NM_CONF=/etc/NetworkManager/conf.d/99-livi-ap-unmanaged.conf
IF=wlp1s0

[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }

state() {
    echo "livi-core: $(pgrep -f "$CORE" | wc -l), launcher: $(pgrep -f "$LAUNCHER" | wc -l), helper: $(pgrep -f "^$HELPER" | wc -l)"
    echo "$AP: $(systemctl is-active $AP); unmanaged conf: $([ -e $NM_CONF ] && echo present || echo absent)"
    echo "avahi: $(systemctl is-active avahi-daemon.service)"
    echo "nm $IF: $(nmcli -g GENERAL.STATE,GENERAL.CONNECTION device show $IF | tr '\n' ' ')"
    echo "power_save: $(iw dev $IF get power_save 2>&1 | awk '{print $NF}'), tailscale: $(tailscale ip -4 2>/dev/null || echo none)"
    # LIVI copies the netplan-rendered Wi-Fi profiles from /run to here before it takes wlp1s0 (empty before LIVI).
    echo "nm profiles in /etc: $(ls /etc/NetworkManager/system-connections/ | wc -l)"
}

wait_gone() {  # pattern seconds
    local i=0
    while pgrep -f "$1" >/dev/null && [ $i -lt "$2" ]; do sleep 1; i=$((i + 1)); done
    ! pgrep -f "$1" >/dev/null
}

restore() {
    echo "[guard] restore $(date '+%F %T')"
    state
    if pgrep -f "$CORE" >/dev/null; then
        echo "[guard] TERM livi-core"
        pkill -TERM -f "$CORE"
        wait_gone "$CORE" 30 || { echo "[guard] livi-core still there, KILL"; pkill -KILL -f "$CORE"; }
    fi
    # y700-carplay tidies up once LIVI is gone.
    wait_gone "$LAUNCHER" 30 || echo "[guard] launcher still running"
    if [ "$(systemctl is-active $AP)" != inactive ]; then
        echo "[guard] stop $AP"
        systemctl stop $AP
    fi
    if [ -e $NM_CONF ]; then
        t=/usr/local/sbin/livi-helperd
        [ -x $t ] || t=$HELPER
        echo "[guard] teardown"
        "$t" --wifi-ap-teardown
    fi
    if pgrep -f "^$HELPER" >/dev/null; then
        echo "[guard] end the helper"
        pkill -TERM -f "^$HELPER"
        wait_gone "^$HELPER" 5 || pkill -KILL -f "^$HELPER"
    fi
    systemctl stop avahi-daemon.service avahi-daemon.socket
    if nmcli -g GENERAL.STATE device show $IF | grep -q unmanaged; then
        echo "[guard] $IF back to NetworkManager"
        nmcli device set $IF managed yes
    fi
    i=0
    until nmcli -g GENERAL.STATE device show $IF | grep -q '^100'; do
        [ $((i % 15)) = 0 ] && nmcli device connect $IF >/dev/null 2>&1
        [ $i -ge 60 ] && { echo "[guard] $IF not connected after 60 s"; break; }
        sleep 1; i=$((i + 1))
    done
    state
    echo "[guard] done $(date '+%F %T')"
}

case "$1" in
arm)
    min=${2:-20}
    systemctl stop $UNIT.timer 2>/dev/null
    systemctl reset-failed $UNIT.service 2>/dev/null
    systemd-run --quiet --unit=$UNIT --on-active="${min}m" --timer-property=AccuracySec=1s \
        /bin/bash "$(readlink -f "$0")" restore
    systemctl list-timers $UNIT.timer --no-pager | head -2
    ;;
disarm)
    systemctl stop $UNIT.timer 2>/dev/null
    systemctl reset-failed $UNIT.service 2>/dev/null
    echo "disarmed"
    ;;
restore) restore ;;
state) state ;;
*) echo "usage: $0 arm [MIN] | disarm | restore | state"; exit 2 ;;
esac

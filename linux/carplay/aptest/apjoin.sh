#!/bin/bash
# K throwaway AP sessions (SSID Y700-T<k>, test-only passphrase), each joined by this PC running pcloop.ps1.
# The interface is taken from NetworkManager the way LIVI's claim does it, then y700-carplay-ap-settle waits for
# wpa_supplicant to let go, then hostapd + dnsmasq. Per session: redacted hostapd -dd log, the kernel log, and
# one summary line; cfg80211/mac80211 trace events (no key material in their formats) run across the whole loop.
# Usage: apjoin.sh K HOLD GAP [extra hostapd lines: key=value replaces, -key removes]
# Env: SEC=wpa2 (WPA-PSK only, no PMF) | livi (LIVI's own WPA2/WPA3 transition, PMF optional; only ssid and
#      passphrase replaced); SETUP=plain | livi (also LIVI's setup_interface: iw reg set, IPv6 link-local);
#      SETTLE=/root/y700-carplay-ap-settle | none; NOSTA=1: no NetworkManager station between the sessions;
#      WATCH=N: y700-carplay-ap-m1watch (/root/) on each hostapd with limit N, and when it stops one, a new hostapd
#      on the same config 2 s later, the way LIVI restarts it (dnsmasq too);
#      STA=<NM connection>: the station spells join that one (e.g. HOME_6G) instead of what NM picks;
#      RELOAD=1: reload ath12k (firmware restart) before every hostapd | pair: sessions in pairs, the odd one after a
#      station spell as usual, the even one right after it with no station spell, only the reload (does the reload
#      clear the state the odd one shows?) | onbad: after a session where the PC associated but never answered M1
#      (M2 0), the next one comes with no station spell and a reload; after any other, a station spell as usual.
#      During the reload NM is kept off the new interface by $NMC.
#      CLAIM=livi: take the interface from NM and give it back exactly the way LIVI's helper does (its
#      99-livi-ap-unmanaged.conf + nmcli general reload / teardown), so SETTLE runs as it does under LIVI.
export LC_ALL=C
K=${1:-6}; HOLD=${2:-70}; GAP=${3:-20}; shift 3; EXTRA=("$@")
SETTLE=${SETTLE:-/root/y700-carplay-ap-settle}; SEC=${SEC:-wpa2}; SETUP=${SETUP:-plain}
B=/root/aptest2; O=$B/join-$(date +%H%M%S); mkdir -p "$O"; chmod 700 "$B" "$O"
exec >"$O/run.log" 2>&1
R() { sed -E 's/((passphrase|password|sae_password|wpa_psk|psk)[^a-z_-]).*/\1 [cut]/I'; }
IF=wlp1s0; BASE=$O/base.conf; CTRL=/var/run/hostapd-test; T=/sys/kernel/tracing
ts() { date '+%T.%N' | cut -c1-12; }
EV="cfg80211/rdev_start_ap cfg80211/rdev_stop_ap cfg80211/cfg80211_rx_control_port cfg80211/rdev_tx_control_port
cfg80211/cfg80211_control_port_tx_status cfg80211/rdev_add_key cfg80211/rdev_del_key cfg80211/rdev_add_station
cfg80211/rdev_change_station cfg80211/rdev_del_station cfg80211/rdev_change_virtual_intf mac80211/drv_add_interface
mac80211/drv_remove_interface mac80211/drv_change_interface mac80211/drv_set_key mac80211/drv_sta_state
mac80211/drv_start_ap mac80211/drv_stop_ap mac80211/drv_assign_vif_chanctx mac80211/drv_unassign_vif_chanctx
mac80211/drv_sta_set_decap_offload mac80211/drv_wake_tx_queue"
mark() { echo "$*" >$T/trace_marker 2>/dev/null; echo "$(ts) $*"; }
to_nm() {
    ip addr flush dev $IF scope global
    [ "$CLAIM" = livi ] && { rm -f $LIVI_NM; nmcli general reload; }
    nmcli device set $IF managed yes
    if [ -n "$STA" ]; then nmcli --wait 40 connection up id "$STA" ifname $IF >/dev/null 2>&1
    else nmcli device connect $IF >/dev/null 2>&1; fi
    for i in $(seq 40); do
        c=$(nmcli -t -f DEVICE,STATE,CONNECTION device | grep "^$IF:")
        case $c in *:connected:*) break ;; esac; sleep 1
    done
    echo "$(ts) NM: $c"
}
start_dns() {
    dnsmasq --conf-file=/dev/null --keep-in-foreground --interface=$IF --bind-interfaces --except-interface=lo --port=0 \
        --dhcp-range=192.168.77.10,192.168.77.20,10m --dhcp-leasefile="$O/leases$k" --log-dhcp --log-facility="$O/dnsmasq$k.log" &
    DNS=$!
}
start_hostapd() {
    hostapd -dd -t -f "$L" -B -P "$O/h$k.pid" "$CONF" || return 1
    for i in $(seq 50); do
        [ "$(hostapd_cli -p $CTRL -i $IF status 2>/dev/null | sed -n 's/^state=//p')" = ENABLED ] && break; sleep 0.2
    done
}
NMC=/etc/NetworkManager/conf.d/98-y700-aptest-unmanaged.conf
LIVI_NM=/etc/NetworkManager/conf.d/99-livi-ap-unmanaged.conf
claim_livi() {      # LIVI's release_iface_from_nm
    printf '[keyfile]\nunmanaged-devices=interface-name:%s\n' $IF >$LIVI_NM
    nmcli general reload; nmcli device set $IF managed no; nmcli device disconnect $IF >/dev/null 2>&1
    systemctl stop wpa_supplicant@$IF 2>/dev/null; rfkill unblock wifi
}
reload_fw() {
    local t0=$(date +%s%N) i
    printf '[keyfile]\nunmanaged-devices=interface-name:%s\n' $IF >$NMC; nmcli general reload conf
    modprobe -r ath12k_wifi7 ath12k || echo -n "modprobe -r failed; "
    sleep 1; modprobe ath12k_wifi7
    for i in $(seq 150); do [ -e /sys/class/net/$IF ] && break; sleep 0.2; done
    udevadm settle -t 10
    nmcli device set $IF managed no
    rm -f $NMC; nmcli general reload conf
    sleep 1
    echo "ath12k $(cat /sys/module/ath12k/version) $IF after $(( ($(date +%s%N) - t0) / 1000000 )) ms," \
        "nm $(nmcli -t -f DEVICE,STATE device | grep "^$IF:" | tr '\n' ' ')"
}
start_watch() {
    [ -n "$WATCH" ] || return 0
    /root/y700-carplay-ap-m1watch "$L" "$(cat "$O/h$k.pid")" "$WATCH" >>"$O/watch$k.log" 2>&1 &
}
stop_ap() {
    [ -f "$O/h$1.pid" ] && kill "$(cat "$O/h$1.pid")" 2>/dev/null
    [ -n "$DNS" ] && kill "$DNS" 2>/dev/null; DNS=
    sleep 1
}
cleanup() {
    echo "== cleanup $(ts)"
    stop_ap "$k"
    echo 0 >$T/tracing_on; for e in $EV; do echo 0 >$T/events/$e/enable; done
    cp $T/trace "$O/trace.txt"; echo >$T/trace
    iw dev $IF set power_save on
    to_nm
    rm -f "$O"/*.conf
    [ -e $NMC ] && { rm -f $NMC; nmcli general reload conf; }
    systemctl stop y700-aptest2-guard.timer 2>/dev/null
    echo "== end $(ts)"
}
trap cleanup EXIT
echo "== K=$K hold=${HOLD}s gap=${GAP}s sec=$SEC setup=$SETUP settle=$SETTLE nosta=${NOSTA:-0} watch=${WATCH:-0} sta=${STA:-nm} reload=${RELOAD:-0} claim=${CLAIM:-nmcli} extra='${EXTRA[*]}' start $(ts)"
[ -s $B/pw ] || { echo "no $B/pw"; exit 1; }
if [ "$SEC" = livi ]; then
    sed -E -e '/^(ssid|wpa_passphrase|sae_password|wpa_psk|ctrl_interface)=/d' /tmp/livi-hostapd.conf >"$BASE"
else
    sed -E -e '/^(ssid|wpa_passphrase|sae_password|wpa_psk|ctrl_interface)=/d' -e 's/^wpa_key_mgmt=.*/wpa_key_mgmt=WPA-PSK/' \
        -e '/^(ieee80211w|sae_pwe)=/d' /tmp/livi-hostapd.conf >"$BASE"
fi
chmod 600 "$BASE"
for l in "${EXTRA[@]}"; do x=${l%%=*}; x=${x#-}; sed -i "/^$x=/d" "$BASE"; case $l in -*) ;; *) echo "$l" >>"$BASE" ;; esac; done
grep -E '^(hw_mode|channel|ieee80211(n|ac|ax|be|w)|vht_oper_chwidth|he_oper_chwidth|wpa_key_mgmt|sae_pwe|wmm_enabled|country_code)=' "$BASE"
echo 0 >$T/tracing_on; echo >$T/trace; echo 4096 >$T/buffer_size_kb
for e in $EV; do echo 1 >$T/events/$e/enable; done; echo 1 >$T/tracing_on
for k in $(seq 1 "$K"); do
    CONF=$O/h$k.conf; S=Y700-T$k
    { cat "$BASE"; echo "ssid=$S"; echo "ctrl_interface=$CTRL"; printf 'wpa_passphrase=%s\n' "$(cat $B/pw)"; } >"$CONF"
    chmod 600 "$CONF"
    k0=$(date +%s)
    mark "s$k release"
    if [ "$CLAIM" = livi ]; then claim_livi
    else nmcli device set $IF managed no; nmcli device disconnect $IF >/dev/null 2>&1; rfkill unblock wifi; fi
    [ "$SETTLE" != none ] && mark "s$k settle: $($SETTLE $IF 10)"
    if [ "$RELOAD" = 1 ] || { [ "$RELOAD" = pair ] && [ $((k % 2)) = 0 ]; } || [ "$reload_next" = 1 ]; then
        mark "s$k reload: $(reload_fw 2>&1 | tr '\n' ' ')"
    fi
    [ "$SETUP" = livi ] && iw reg set JP
    ip link set $IF up; iw dev $IF set power_save off
    ip addr flush dev $IF scope global; ip addr add 192.168.77.1/24 dev $IF
    if [ "$SETUP" = livi ]; then
        sysctl -qw net.ipv6.conf.$IF.disable_ipv6=0 net.ipv6.conf.$IF.addr_gen_mode=0
        ip -6 addr show dev $IF scope link | grep -q inet6 || mark "s$k no link-local (LIVI would add one)"
    fi
    L=$O/h$k.raw
    start_hostapd || { echo "s$k hostapd failed"; continue; }
    mark "s$k enabled $S"
    start_dns; start_watch
    sleep 2; iw dev >"$O/iwdev$k.txt"
    end=$(( $(date +%s) + HOLD )); auth=; rs=0
    while [ "$(date +%s)" -lt $end ]; do
        if [ -n "$WATCH" ] && ! kill -0 "$(cat "$O/h$k.pid")" 2>/dev/null; then
            mark "s$k hostapd gone: $(tail -1 "$O/watch$k.log" 2>/dev/null | cut -c1-60)"
            kill "$DNS" 2>/dev/null; wait "$DNS" 2>/dev/null; DNS=
            sleep 2
            ip link set $IF up; ip addr add 192.168.77.1/24 dev $IF 2>/dev/null
            start_hostapd || { mark "s$k restart failed"; break; }
            rs=$((rs + 1)); mark "s$k restarted ($rs)"
            start_dns; start_watch
        fi
        f=$(hostapd_cli -p $CTRL -i $IF all_sta 2>/dev/null | grep '^flags=')
        [ -z "$auth" ] && case $f in *AUTHORIZED*) auth=$(ts); mark "s$k authorized" ;; esac
        sleep 1
    done
    stop_ap "$k"
    mark "s$k stopped"
    R <"$L" >"$O/h$k.log"; rm -f "$L"; chmod 600 "$O/h$k.log"
    journalctl -k --since "@$k0" -o short-precise | grep -E 'ath12k|wlp1s0|y700[a-z]+:' | cut -c8-700 >"$O/k$k.log"
    as=$(grep -c 'IEEE 802.11: associated' "$O/h$k.log")
    hs=$(grep -c 'pairwise key handshake completed' "$O/h$k.log")
    m1=$(grep -c 'WPA_PTK entering state PTKSTART' "$O/h$k.log")
    m2=$(grep -c 'received EAPOL-Key frame (2/4' "$O/h$k.log")
    pf=$(grep -c 'failed to find the peer' "$O/k$k.log")
    ch=$(awk -v i=$IF '$1 == "Interface" { x = ($2 == i) } x && $1 == "channel" { print $2, $3, $5, $6; exit }' "$O/iwdev$k.txt")
    ls=$(cat "$O/leases$k" 2>/dev/null | wc -l)
    echo "s$k $S channel '${ch:-none}' assoc $as M1 $m1 M2 $m2 handshake $hs authorized '${auth:-no}' lease $ls peer_not_found $pf restarts ${rs:-0}"
    # NOSTA=1: no NetworkManager station between two access points, only hostapd restarted (LIVI's own restart)
    # RELOAD=pair: no station before an even session either
    nosta=$NOSTA; [ "$RELOAD" = pair ] && [ $(((k + 1) % 2)) = 0 ] && nosta=1
    # RELOAD=onbad: a bad session (associated, no M2) is followed by a reload instead of a station spell
    reload_next=0; [ "$RELOAD" = onbad ] && [ "$as" -gt 0 ] && [ "$m2" = 0 ] && { reload_next=1; nosta=1; }
    [ "$k" -lt "$K" ] && { [ "$nosta" = 1 ] || to_nm; sleep "$GAP"; }
done

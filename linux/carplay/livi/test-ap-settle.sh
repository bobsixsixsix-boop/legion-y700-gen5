#!/bin/bash
# linux/carplay/livi/test-ap-settle.sh [SCRIPT] -- stub test for y700-carplay-ap-settle's firmware restart (10-19 audit).
# Runs anywhere (Git Bash on the PC, or the tablet as any user): fake modprobe/lsmod/nmcli/udevadm/iw/busctl/readlink
# on PATH and a fake /sys/class/net (Y700_AP_SYSNET); nothing real is touched. Every scenario must end with the
# interface back and ath12k_wifi7 loaded:
#   ok     modprobe -r removes both modules, the reload works
#   stuck  modprobe -r removes ath12k_wifi7 but ath12k stays in use (the old script exited there: no wlp1s0)
#   flaky  the first modprobe ath12k_wifi7 fails, the second works (the old script fell back to plain ath12k)
H=$(cd "$(dirname "$0")" && pwd)
S=${1:-$H/y700-carplay-ap-settle}
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/net"
cat >"$T/bin/lsmod" <<'EOF'
#!/bin/bash
echo "Module                  Size  Used by"
while read -r m; do [ -n "$m" ] && echo "$m 1 0"; done <"$STUB/mods"
EOF
cat >"$T/bin/modprobe" <<'EOF'
#!/bin/bash
echo "modprobe $*" >>"$STUB/log"
have() { grep -qx "$1" "$STUB/mods"; }
drop() { grep -vx "$1" "$STUB/mods" >"$STUB/mods.n"; mv "$STUB/mods.n" "$STUB/mods"; }
if [ "$1" = -r ]; then
    drop ath12k_wifi7; rm -rf "$STUB/net/wlp1s0"
    if [ "$SCEN" = stuck ]; then echo "modprobe: FATAL: Module ath12k is in use." >&2; exit 1; fi
    drop ath12k; exit 0
fi
case "$1" in
    ath12k_wifi7)
        n=$(grep -c . "$STUB/tries" 2>/dev/null); echo x >>"$STUB/tries"
        [ "$SCEN" = flaky ] && [ "${n:-0}" = 0 ] && exit 1
        have ath12k || echo ath12k >>"$STUB/mods"
        echo ath12k_wifi7 >>"$STUB/mods"; mkdir -p "$STUB/net/wlp1s0/device" ;;
    ath12k) have ath12k || echo ath12k >>"$STUB/mods" ;;   # the bus-independent core: no interface
esac
exit 0
EOF
printf '#!/bin/sh\necho /sys/bus/pci/drivers/ath12k_wifi7_pci\n' >"$T/bin/readlink"
for c in nmcli udevadm iw busctl; do printf '#!/bin/sh\nexit 0\n' >"$T/bin/$c"; done
chmod +x "$T"/bin/*

fails=0
for scen in ok stuck flaky; do
    rm -rf "$T/net/wlp1s0" "$T/tries" "$T/log"; mkdir -p "$T/net/wlp1s0/device"
    printf 'ath12k\nath12k_wifi7\n' >"$T/mods"
    out=$(STUB=$T SCEN=$scen PATH="$T/bin:$PATH" Y700_AP_SYSNET="$T/net" Y700_AP_NM_CONF="$T/none" \
        bash "$S" wlp1s0 1 2>&1)
    if [ -d "$T/net/wlp1s0" ] && grep -qx ath12k_wifi7 "$T/mods"; then
        echo "PASS $scen"
    else
        echo "FAIL $scen: no wlp1s0 / ath12k_wifi7 afterwards"; echo "$out" | sed 's/^/     /'; fails=$((fails + 1))
    fi
done
[ $fails = 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }

#!/bin/bash
# One dry run of apjoin.sh's reload_fw: release wlp1s0 from NM, reload ath12k with NM kept off the new interface,
# show the state, give the interface back. Log: /root/aptest2/reloadtest.log
exec >/root/aptest2/reloadtest.log 2>&1
IF=wlp1s0; NMC=/etc/NetworkManager/conf.d/98-y700-aptest-unmanaged.conf
eval "$(sed -n '/^reload_fw() {/,/^}/p' /root/apjoin.sh)"
echo "== $(date +%T.%N | cut -c1-12) start"
nmcli device set $IF managed no; nmcli device disconnect $IF >/dev/null 2>&1
/root/y700-carplay-ap-settle $IF 10
echo "$(date +%T.%N | cut -c1-12) reload: $(reload_fw 2>&1 | tr '\n' ' ')"
sleep 5
echo "$(date +%T.%N | cut -c1-12) after 5 s: $(nmcli -t -f DEVICE,STATE,CONNECTION device | grep wlp | tr '\n' ' ')"
iw dev
ls /etc/NetworkManager/conf.d/
nmcli device set $IF managed yes; nmcli device connect $IF >/dev/null 2>&1
for i in $(seq 40); do nmcli -t -f DEVICE,STATE device | grep -q "^$IF:connected" && break; sleep 1; done
echo "$(date +%T.%N | cut -c1-12) back: $(nmcli -t -f DEVICE,STATE,CONNECTION device | grep "^$IF:")"
journalctl -k --since "-90s" | grep -iE 'ath12k.*(error|fail|warn)|BTI|Oops' | tail -5
echo DONE

#!/bin/bash
# y14 prep step 4: configuration dry-run on the t52 tree, out of tree (O=/root/y14-cfg/*): no build, the source tree
# /usr/local/src/linux-t52 stays clean. Compares
#   old : config-t49.release + olddefconfig on v7.3/t52            vs config-t49.release
#   y14 : the y13 recipe (t49 release - trim + power fragments)   vs y13's pre-build config
#   up  : upstream's documented recipe (defconfig + infiniti defconfig + baldur fragments) = stand-in for the
#         t52 release asset config-tb323fu-t52                      vs old
# and checks that every symbol named in the y8 fragments / must-keep list still exists in t52's Kconfig.
set -uo pipefail
W=/usr/local/src/linux-t52; FR=/root/y8-fragments; UPC=/usr/local/src/tb323fu-linux-t52/kernel/config
B=/root/y14-cfg; rm -rf $B; mkdir -p $B/old $B/y14 $B/up
M="nice -n 10 make -s -C $W LLVM=/opt/llvm-18/bin/ LOCALVERSION="
CMDLINE="fw_devlink.sync_state=timeout fbcon=font:TER16x32 panic=10 oops=panic console=tty1 qcom_scm.download_mode=full baldur.end=hold consoleblank=120 no_console_suspend mem_sleep_default=s2idle cpuidle_psci_domain.allow_cluster_off=0 msm.idle_refresh_ms60=500 msm.idle_refresh_ms30=2000"
opts() { grep -E '^(CONFIG_[A-Z0-9_]+=|# CONFIG_[A-Z0-9_]+ is not set)' "$1" | sort; }
cd $W
[ -z "$(git status --porcelain --untracked-files=no)" ] || { echo "linux-t52 not clean"; exit 1; }

echo "##### 1. t49 release config + olddefconfig on the t52 tree (what changes by itself)"
cp /root/config-t49.release $B/old/.config
$M O=$B/old olddefconfig
diff <(opts /root/config-t49.release) <(opts $B/old/.config)

echo "##### 2. y13 recipe on the t52 tree vs y13's pre-build config"
C="$W/scripts/config --file $B/y14/.config"
cp /root/config-t49.release $B/y14/.config
$C --set-str LOCALVERSION "-tb323fu-t52-y14" --set-str INITRAMFS_SOURCE "" --set-str CMDLINE "$CMDLINE"
apply_fragment() {
	grep -E '^(# CONFIG_[A-Z0-9_]+ is not set|CONFIG_[A-Z0-9_]+=)' "$1" | while read -r line; do
		case "$line" in
		"# CONFIG_"*" is not set") s=${line#\# }; s=${s% is not set}; $C --disable "${s#CONFIG_}" ;;
		*=y) $C --enable "${line%=y}" ;;
		*=m) $C --module "${line%=m}" ;;
		*=\"*) s=${line%%=*}; v=${line#*=}; v=${v#\"}; v=${v%\"}; $C --set-str "${s#CONFIG_}" "$v" ;;
		*=*) s=${line%%=*}; $C --set-val "${s#CONFIG_}" "${line#*=}" ;;
		esac
	done
}
apply_fragment $FR/y8-trim.fragment
apply_fragment $FR/y8-power.fragment
$M O=$B/y14 olddefconfig
echo "--- vs y13's final config (as kbuild-y13's cfgcmp: comments and the two naming lines left out)"
cfgcmp() { grep -vE "^CONFIG_(LOCALVERSION|INITRAMFS_SOURCE)=|^#" "$1"; }
diff <(cfgcmp /usr/local/src/y700-kernel-y13/config-t49-y13) <(cfgcmp $B/y14/.config)
echo "--- the same with the 'is not set' lines"
diff <(opts /usr/local/src/y700-kernel-y13/config-t49-y13 | grep -vE "^CONFIG_(LOCALVERSION|INITRAMFS_SOURCE)=") \
	<(opts $B/y14/.config | grep -vE "^CONFIG_(LOCALVERSION|INITRAMFS_SOURCE)=")
cp $B/y14/.config $B/config-t52-y14.expected
echo "--- the y13 build's own checks (check_config of kbuild-y13.sh) on this config"
cd $B/y14
bad=0
for o in CONFIG_NTSYNC=m CONFIG_ZRAM_BACKEND_ZSTD=y CONFIG_EXFAT_FS=m CONFIG_LRU_GEN_ENABLED=y CONFIG_DEBUG_INFO_BTF=y \
	CONFIG_DEBUG_INFO_BTF_MODULES=n CONFIG_ANDROID_BINDER_IPC=n; do
	if [ "${o#*=}" = n ]; then grep -q "^${o%=n}=" .config && { echo "UNEXPECTED ${o%=n} set"; bad=1; }
	elif ! grep -qx "$o" .config; then echo "MISSING $o"; bad=1; fi
done
grep -qx "CONFIG_CMDLINE=\"$CMDLINE\"" .config || { echo "CMDLINE not as intended"; bad=1; }
grep -qx "CONFIG_ARM_PSCI_CPUIDLE_DOMAIN=y" .config || { echo "ARM_PSCI_CPUIDLE_DOMAIN not built in"; bad=1; }
grep -q "^CONFIG_PREEMPT_RT=y" .config && { echo "PREEMPT_RT is on"; bad=1; }
grep -E '^[A-Z0-9_]+ [ym] ' $FR/y8-must-keep.txt | while read -r sym st _; do
	grep -qE "^CONFIG_$sym=" .config || echo "MUST-KEEP LOST: $sym (wanted $st)"
done
for f in $FR/y8-trim.fragment $FR/y8-power.fragment; do
	grep -E '^# CONFIG_[A-Z0-9_]+ is not set' "$f" | while read -r _ sym _; do
		grep -qE "^$sym=[ym]$" .config && echo "REVIVED by olddefconfig: $sym"
	done
	grep -E '^CONFIG_[A-Z0-9_]+=' "$f" | while read -r line; do
		grep -qx "$line" .config || echo "NOT APPLIED: $line (now: $(grep "^${line%%=*}[= ]" .config || echo unset))"
	done
done
echo "check_config fixed checks bad=$bad"
cd $W

echo "##### 3. upstream recipe (defconfig + kaanapali-oneplus-infiniti_defconfig + baldur, display, netfilter, extra) vs 1."
$M O=$B/up defconfig
(cd $W && scripts/kconfig/merge_config.sh -m -O $B/up $B/up/.config arch/arm64/configs/kaanapali-oneplus-infiniti_defconfig \
	$UPC/baldur.fragment $UPC/baldur-display.fragment $UPC/baldur-netfilter.fragment $UPC/baldur-extra.fragment > $B/up/merge.log 2>&1) || echo "merge_config failed"
grep -c "Value of" $B/up/merge.log | sed 's/^/merge_config overrides: /'
$M O=$B/up olddefconfig
diff <(opts $B/old/.config) <(opts $B/up/.config)

echo "##### 4. fragment / must-keep symbols that are not Kconfig symbols in t52 (and whether they were in rc4/t49)"
ksyms() { git grep -hE '^[[:space:]]*(menu)?config [A-Za-z0-9_]+' "$1" -- '*Kconfig*' | awk '{print $2}' | sort -u; }
ksyms t52-base > $B/ksyms-t52; ksyms 5211e37c9 > $B/ksyms-t49
{ grep -ohE 'CONFIG_[A-Z0-9_]+' $FR/y8-trim.fragment $FR/y8-power.fragment | sed 's/^CONFIG_//'
  grep -E '^[A-Z0-9_]+ [ym] ' $FR/y8-must-keep.txt | awk '{print $1}'; } | sort -u > $B/fragsyms
echo "symbols named: $(wc -l < $B/fragsyms)"
comm -23 $B/fragsyms $B/ksyms-t52 | while read -r s; do
	if grep -qx "$s" $B/ksyms-t49; then echo "VANISHED in t52: $s"; else echo "not a Kconfig symbol in t49 either: $s"; fi
done
echo "##### 5. Kconfig symbols new in t52 (not in rc4/t49), with their value in the y14 config"
comm -13 $B/ksyms-t49 $B/ksyms-t52 | while read -r s; do echo "NEW $s: $(grep -E "^(# )?CONFIG_$s[= ]" $B/y14/.config || echo '(not in .config: dependency off)')"; done
echo CONFIG_DRYRUN_DONE

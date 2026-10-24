#!/bin/bash
# y11-verify.sh: after booting y11 (= y10 + the 1044 Qualcomm Oryon DC ZVA erratum workaround). Run as root on the
# tablet (root only needed for the debugfs counter and dmesg). PASS/FAIL per line, exit 1 on any FAIL.
#
# y11 is byte-for-byte y10 plus 1044, so the full hardware/userspace sweep is y10-verify.sh's; run that too (it will
# only FAIL its "running y10" uname line). This script checks the 1044 delta and the handful of invariants that make
# it meaningful, and it drives the EL0 self-test dczva-selftest.c.
#
# It auto-detects which image booted from /proc/cmdline:
#   primary  Image-t49-y11            -> workaround ACTIVE  (SCTLR_EL1.DZE clear, DC ZVA trapped+emulated, fast paths out)
#   twin     Image-t49-y11-dczva-off  -> qcom_oryon_dc_zva=off, workaround COMPILED IN but DISABLED (DC ZVA native)
# The A/B that proves the erratum is: run dczva-stress.c under cx-exp.sh E2 on BOTH images and compare the reset rate
# (RESEARCH.md 3.2). This script only verifies the kernel is in the state each image intends.
ST=${DCZVA_SELFTEST:-}
HERE=$(cd "$(dirname "$0")" && pwd)
fail=0
ok() { printf 'PASS  %s\n' "$1"; }
ko() { printf 'FAIL  %s\n' "$1"; fail=1; }
info(){ printf 'INFO  %s\n' "$1"; }
chk() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else ko "$1"; fi; }
kmsg() { dmesg 2>/dev/null; journalctl -k -b -o cat 2>/dev/null; }   # early boot lines survive a wrapped ring buffer in the journal
DBG=/sys/kernel/debug/qcom_oryon_dc_zva_emulated
DET='CPU features: detected: Qualcomm Oryon DC ZVA erratum'
OFFLINE='Qualcomm Oryon DC ZVA workaround disabled on the command line'

chk "running y11: $(uname -r)" '[ "$(uname -r)" = 7.3.0-rc4-tb323fu-t49-y11 ]'
mode=primary; grep -q "qcom_oryon_dc_zva=off" /proc/cmdline && mode=off
info "boot mode: $mode  (cmdline: $(tr " " "\n" < /proc/cmdline | grep -E "qcom_oryon_dc_zva|allow_cluster_off|allow_system_off" | tr "\n" " "))"
chk "MIDR is the one 1044 matches: implementer 0x51, part 0x002 (dmesg 0x512f0021)" 'grep -qE "^CPU implementer[[:space:]]*: 0x51$" /proc/cpuinfo && grep -qE "^CPU part[[:space:]]*: 0x002$" /proc/cpuinfo'

# build the self-test if we were not handed a binary (cc/gcc/clang, or the kernel's clang 18; CC=... overrides)
if [ -z "$ST" ]; then
	src=""
	for c in "$HERE/dczva-selftest.c" /root/y8-patches/dczva-selftest.c /usr/local/src/tb323fu-linux/linux/kernel-y8/dczva-selftest.c; do
		[ -f "$c" ] && { src=$c; break; }
	done
	CC_BIN=""
	for c in "${CC:-}" cc gcc clang /opt/llvm-18/bin/clang; do
		[ -n "$c" ] && command -v "$c" >/dev/null 2>&1 && { CC_BIN=$c; break; }
	done
	if [ -n "$src" ] && [ -n "$CC_BIN" ]; then
		ST=/tmp/dczva-selftest
		"$CC_BIN" -O2 -o "$ST" "$src" 2>/tmp/dczva-selftest.cc.log || { ko "could not build dczva-selftest from $src with $CC_BIN (see /tmp/dczva-selftest.cc.log)"; ST=""; }
	else
		info "dczva-selftest.c not found or no compiler; set DCZVA_SELFTEST=/path to the built binary to run it"
	fi
fi

if [ "$mode" = primary ]; then
	chk "1044: 'detected: Qualcomm Oryon DC ZVA erratum' in the kernel log" 'kmsg | grep -qF "$DET"'
	chk "1044: no 'workaround disabled' line (primary image)" '! kmsg | grep -qF "$OFFLINE"'
	chk "1044: debugfs counter exists, mode 0444" '[ -f "$DBG" ] && [ "$(stat -c %a "$DBG")" = 444 ]'
	chk "1044: counter is a number (now $(cat "$DBG" 2>/dev/null))" 'c=$(cat "$DBG" 2>/dev/null); [ -n "$c" ] && [ "$c" -ge 0 ] 2>/dev/null'
	if [ -n "$ST" ]; then
		info "running $ST (expect DZP=1, emulation correct, counter grows)"
		out=$("$ST" 2>&1); rc=$?; printf '%s\n' "$out" | sed 's/^/    selftest: /'
		chk "dczva-selftest passed (workaround active): exit 0, ends with ALL PASS" '[ "$rc" = 0 ] && grep -q "^ALL PASS$" <<<"$out"'
		chk "dczva-selftest: DZP=1 seen from EL0" 'grep -q "^PASS  DZP=1" <<<"$out"'
		[ "$(id -u)" = 0 ] && chk "dczva-selftest: debugfs counter grew by the executed dc zva count" 'grep -q "^PASS  debugfs counter grew" <<<"$out"'
	fi
else
	chk "1044 off-twin: 'workaround disabled on the command line' in the kernel log" 'kmsg | grep -qF "$OFFLINE"'
	chk "1044 off-twin: no 'detected:' line" '! kmsg | grep -qF "$DET"'
	chk "1044 off-twin: debugfs counter ABSENT (capability never set)" '[ ! -e "$DBG" ]'
	if [ -n "$ST" ]; then
		info "running $ST --expect-dze (expect DZP=0, native DC ZVA)"
		out=$("$ST" --expect-dze 2>&1); rc=$?; printf '%s\n' "$out" | sed 's/^/    selftest: /'
		chk "dczva-selftest --expect-dze passed (DC ZVA native): exit 0, ends with ALL PASS" '[ "$rc" = 0 ] && grep -q "^ALL PASS$" <<<"$out"'
		chk "dczva-selftest: DZP=0 seen from EL0" 'grep -q "^PASS  DZP=0" <<<"$out"'
	fi
fi

# invariants that must hold on y11 regardless of mode (the 1043 knob is still present; cx knobs still off at boot)
chk "PSCI domain topology in OSI mode" 'dmesg | grep -q "CPUidle PSCI: Initialized CPU PM domain topology using OSI mode"'
chk "1043 knob present and N (y11 still carries 1043)" 'f=/sys/module/cpuidle_psci_domain/parameters/allow_system_off; [ -f "$f" ] && [ "$(cat "$f")" = N ]'
chk "allow_cluster_off N (0118)" '[ "$(cat /sys/module/cpuidle_psci_domain/parameters/allow_cluster_off)" = N ]'
chk "no silent reset last boot: pstore/flightrec sane" 'journalctl -b -1 -n 50 --no-pager -o cat 2>/dev/null | grep -qE "reboot.target|Reached target.*Reboot|Journal stopped" || [ -z "$(journalctl --list-boots -q 2>/dev/null | sed -n 2p)" ]'
chk "systemctl --failed empty" '[ -z "$(systemctl --failed --no-legend)" ]'
chk "wifi connected (base image unchanged from y10)" 'nmcli -t -f DEVICE,STATE device | grep -q "^wlp1s0:connected"'
chk "no WARNING/BUG/Oops/Call trace since boot" '! dmesg | grep -qE "WARNING:|BUG:|Oops|Call trace|Unhandled fault|SError"'
info "run y10-verify.sh as well for the full hardware/userspace sweep (its uname check will FAIL on y11; everything else applies)."
[ $fail = 0 ] && echo "ALL PASS" || echo "SOME FAILED"
exit $fail

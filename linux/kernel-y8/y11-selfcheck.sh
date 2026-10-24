#!/bin/bash
# y11-selfcheck.sh [TREE]: grep assertions that the 1044 Qualcomm Oryon DC ZVA erratum patch has the shape its commit
# message and RESEARCH.md 3.2 describe, plus two shape guards that keep it aligned with the x1e-sleep / Marc Zyngier
# original (reviewed 2026-10-16 against the raw v7.3-rc4 sources):
#   - traps.c masks DCZID_EL0.BS with "& 0xf" (as x1e-sleep and clear_page.S do). Note DCZID_EL0_BS_MASK DOES exist in
#     v7.3-rc4 (gen-sysreg.awk emits <reg>_<field>_MASK into asm/sysreg-defs.h), so this is one agreed spelling, not a
#     compile fix;
#   - cpu_enable_qcom_oryon_dc_zva_trap() calls no isb(): none is needed, the eret back to EL0 is the context
#     synchronization, exactly as the sibling UCI/UCT cache-trap errata (cpu_enable_cache_maint_trap) rely on.
# Two layers, PASS/FAIL per line, exit 1 on any FAIL; nothing is built or executed from the tree.
#   1. the patch file next to this script (always).
#   2. TREE (default /usr/local/src/linux-t47, skipped when absent): the same properties in the applied source, and
#      whether 1044 is already applied (reverse-check) or would apply cleanly (forward check) with git.
# Run before kbuild-y11.sh (which repeats the tree assertions) and y11-verify.sh after the first boot.
HERE=$(cd "$(dirname "$0")" && pwd)
PATCH=${PATCH:-$HERE/1044-arm64-errata-qcom-oryon-dc-zva-workaround.patch}
[ -f "$PATCH" ] || { c=/root/y8-patches/1044-arm64-errata-qcom-oryon-dc-zva-workaround.patch; [ -f "$c" ] && PATCH=$c; }
TREE=${1:-/usr/local/src/linux-t47}
fail=0
ok() { printf 'PASS  %s\n' "$1"; }
ko() { printf 'FAIL  %s\n' "$1"; fail=1; }
chk() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else ko "$1"; fi; }
dgrep() { sed -n '/^diff --git/,$p' "$PATCH" | grep "$@"; }   # the diff part only (message also has "-" lines)

echo "== patch file: $PATCH"
chk "patch present" '[ -f "$PATCH" ]'
chk "subject [PATCH 1044]" 'grep -q "^Subject: \[PATCH 1044\] arm64: errata: work around the Qualcomm Oryon DC ZVA" "$PATCH"'
chk "touches the 10 expected files" '[ "$(grep -c "^diff --git" "$PATCH")" = 10 ]'
for f in Documentation/arch/arm64/silicon-errata.rst arch/arm64/Kconfig arch/arm64/include/asm/cputype.h \
	 arch/arm64/include/asm/esr.h arch/arm64/kernel/cpu_errata.c arch/arm64/kernel/traps.c \
	 arch/arm64/lib/clear_page.S arch/arm64/lib/memset.S arch/arm64/lib/mte.S arch/arm64/tools/cpucaps; do
	chk "  edits $f" "grep -q '^diff --git a/$f b/$f' '$PATCH'"
done
# cputype.h: the new part number and MIDR, X1 kept in the match list
chk "cputype: QCOM_CPU_PART_ORYON_V3 0x002" 'dgrep -qE "^\+#define QCOM_CPU_PART_ORYON_V3[[:space:]]+0x002"'
chk "cputype: MIDR_QCOM_ORYON_V3" 'dgrep -q "^+#define MIDR_QCOM_ORYON_V3 MIDR_CPU_MODEL"'
# cpucaps
chk "cpucaps: WORKAROUND_QCOM_ORYON_DC_ZVA" 'dgrep -qx "+WORKAROUND_QCOM_ORYON_DC_ZVA"'
# Kconfig
chk "Kconfig: QCOM_ORYON_ERRATUM_DC_ZVA, default y" 'dgrep -q "^+config QCOM_ORYON_ERRATUM_DC_ZVA" && dgrep -q "^+[[:space:]]*default y"'
# esr.h
chk "esr: ESR_ELx_SYS64_ISS_CRM_DC_ZVA = 4" 'dgrep -qE "^\+#define ESR_ELx_SYS64_ISS_CRM_DC_ZVA[[:space:]]+4"'
# cpu_errata.c
chk "errata entry desc" 'dgrep -q "\"Qualcomm Oryon DC ZVA erratum\""'
chk "errata capability" 'dgrep -q "ARM64_WORKAROUND_QCOM_ORYON_DC_ZVA"'
chk "match list has X1 and V3 (all versions)" 'dgrep -q "MIDR_ALL_VERSIONS(MIDR_QCOM_ORYON_X1)" && dgrep -q "MIDR_ALL_VERSIONS(MIDR_QCOM_ORYON_V3)"'
chk "cpu_enable clears SCTLR_EL1.DZE" 'dgrep -q "sysreg_clear_set(sctlr_el1, SCTLR_EL1_DZE, 0);"'
chk "shape guard: cpu_enable adds no isb() (not needed: the eret to EL0 syncs, as the UCI/UCT siblings)" '! dgrep -q "^+[[:space:]]*isb();"'
chk "boot-time off switch: early_param qcom_oryon_dc_zva" 'dgrep -q "early_param(\"qcom_oryon_dc_zva\""'
chk "matches() honours the off switch" 'dgrep -q "qcom_oryon_dc_zva_workaround_off"'
chk "guarded by CONFIG_QCOM_ORYON_ERRATUM_DC_ZVA" 'dgrep -q "^+#ifdef CONFIG_QCOM_ORYON_ERRATUM_DC_ZVA"'
chk "includes <linux/init.h> (early_param/__init)" 'dgrep -q "^+#include <linux/init.h>"'
# traps.c
chk "traps: DC ZVA case in user_cache_maint_handler" 'dgrep -q "case ESR_ELx_SYS64_ISS_CRM_DC_ZVA:" && dgrep -q "ret = emulate_dc_zva(address);"'
chk "traps: emulate_dc_zva zeroes with clear_user" 'dgrep -q "clear_user(va, bs)"'
chk "shape guard: block-size mask spelled & 0xf (x1e-sleep shape), not DCZID_EL0_BS_MASK" 'dgrep -q "read_sysreg(dczid_el0) & 0xf" && ! dgrep -q "DCZID_EL0_BS_MASK"'
chk "traps: debugfs counter + late_initcall" 'dgrep -q "qcom_oryon_dc_zva_emulated" && dgrep -q "late_initcall(qcom_oryon_dc_zva_debugfs_init)"'
chk "traps: includes <linux/debugfs.h>" 'dgrep -q "^+#include <linux/debugfs.h>"'
# the three asm fast paths, cpucap-gated
for f in clear_page memset mte; do
	chk "$f.S: ZVA fast path gated on alternative_if ARM64_WORKAROUND_QCOM_ORYON_DC_ZVA" "dgrep -A3 '^diff --git a/arch/arm64/lib/$f.S' >/dev/null; sed -n '/^diff --git a\/arch\/arm64\/lib\/$f.S/,/^diff --git/p' '$PATCH' | grep -q 'alternative_if ARM64_WORKAROUND_QCOM_ORYON_DC_ZVA'"
done
chk "commit message: how to switch + how to verify" 'grep -q "^How to switch" "$PATCH" && grep -q "^How to verify it booted" "$PATCH"'
chk "commit message: honest-limits section (not compiled/booted)" 'grep -qi "Not compiled, not booted" "$PATCH"'

if [ -d "$TREE" ]; then
	echo "== tree: $TREE"
	chk "tree is v7.3-rc4-ish: cpucaps has the Oryon CNTVOFF cap" 'grep -q "^WORKAROUND_QCOM_ORYON_CNTVOFF$" "$TREE/arch/arm64/tools/cpucaps"'
	if grep -q "WORKAROUND_QCOM_ORYON_DC_ZVA" "$TREE/arch/arm64/tools/cpucaps"; then
		echo "      1044 is in the tree: checking its shape"
		chk "cputype V3 0x002" 'grep -qE "QCOM_CPU_PART_ORYON_V3[[:space:]]+0x002" "$TREE/arch/arm64/include/asm/cputype.h"'
		chk "Kconfig symbol" 'grep -q "config QCOM_ORYON_ERRATUM_DC_ZVA" "$TREE/arch/arm64/Kconfig"'
		chk "cpu_enable clears DZE, no isb" 'grep -q "sysreg_clear_set(sctlr_el1, SCTLR_EL1_DZE, 0);" "$TREE/arch/arm64/kernel/cpu_errata.c" && ! { sed -n "/cpu_enable_qcom_oryon_dc_zva_trap(const/,/^}/p" "$TREE/arch/arm64/kernel/cpu_errata.c" | grep -q "isb();"; }'
		chk "traps mask & 0xf, no DCZID_EL0_BS_MASK" 'grep -q "read_sysreg(dczid_el0) & 0xf" "$TREE/arch/arm64/kernel/traps.c" && ! grep -q "DCZID_EL0_BS_MASK" "$TREE/arch/arm64/kernel/traps.c"'
		for f in clear_page memset mte; do
			chk "$f.S gated" 'grep -q "alternative_if ARM64_WORKAROUND_QCOM_ORYON_DC_ZVA" "$TREE/arch/arm64/lib/'$f'.S"'
		done
		if command -v git >/dev/null && git -C "$TREE" rev-parse >/dev/null 2>&1; then
			chk "git apply --reverse --check: the tree carries exactly this 1044" 'git -C "$TREE" apply --reverse --check "$PATCH"'
		fi
	else
		echo "      1044 not applied yet"
		if command -v git >/dev/null && git -C "$TREE" rev-parse >/dev/null 2>&1; then
			chk "git apply --check: 1044 applies cleanly on this tree" 'git -C "$TREE" apply --check "$PATCH"'
		fi
	fi
else
	echo "== tree: $TREE absent, source checks skipped (fine on the Win11 side)"
fi
[ $fail = 0 ] && echo "ALL PASS" || echo "SOME FAILED"
exit $fail

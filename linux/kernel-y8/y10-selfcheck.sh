#!/bin/bash
# y10-selfcheck.sh [TREE]: grep assertions that the 1043 allow_system_off knob has the shape RESEARCH.md 3.3 asks for.
# Two layers, PASS/FAIL per line, exit 1 on any FAIL; nothing is built or executed from the tree.
#   1. the patch file next to this script (always): default N, 0644, RT guard, 0106 quirk kept (not removed), no genpd
#      lock, no cmdline/fragment change, single file, hunk contexts taken from the 0118-patched file.
#   2. TREE (default /usr/local/src/linux-t47, skipped when absent): the same properties in the applied source, and
#      whether 1043 is already applied (reverse-check) or would apply cleanly (forward check) with git.
# Run it on the tablet before kbuild-y10.sh (which repeats the tree assertions) and y10-verify.sh after the first boot.
HERE=$(cd "$(dirname "$0")" && pwd)
# the patch: next to this script, or PATCH=/path/to/it, or where kbuild-y10.sh expects it on the tablet
PATCH=${PATCH:-$HERE/1043-cpuidle-psci-domain-allow_system_off.patch}
[ -f "$PATCH" ] || { c=/root/y8-patches/1043-cpuidle-psci-domain-allow_system_off.patch; [ -f "$c" ] && PATCH=$c; }
TREE=${1:-/usr/local/src/linux-t47}
D=drivers/cpuidle/cpuidle-psci-domain.c
fail=0
ok() { printf 'PASS  %s\n' "$1"; }
ko() { printf 'FAIL  %s\n' "$1"; fail=1; }
chk() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else ko "$1"; fi; }
# grep the diff part only (from the first "diff --git" on): the commit message above it also has lines starting with "-"
dgrep() { sed -n '/^diff --git/,$p' "$PATCH" | grep "$@"; }

echo "== patch file: $PATCH"
chk "patch file present" '[ -f "$PATCH" ]'
chk "subject [PATCH 1043]" 'grep -q "^Subject: \[PATCH 1043\] cpuidle: psci-domain: baldur: allow_system_off" "$PATCH"'
chk "touches exactly one file, $D" '[ "$(grep -c "^diff --git" "$PATCH")" = 1 ] && grep -q "^diff --git a/$D b/$D" "$PATCH"'
chk "no baldur.fragment / CONFIG_CMDLINE change (default N must not depend on the cmdline)" '! grep -q "baldur.fragment" "$PATCH" && ! grep -q "CONFIG_CMDLINE" "$PATCH"'
chk "default N: +static bool allow_system_off; (no = true)" 'grep -qx "+static bool allow_system_off;" "$PATCH" && ! grep -q "allow_system_off = true" "$PATCH"'
chk "module_param_cb(..., 0644)" 'grep -qx "+module_param_cb(allow_system_off, &allow_system_off_ops, &allow_system_off, 0644);" "$PATCH"'
chk "ops carry KERNEL_PARAM_OPS_FL_NOARG (a bare cmdline token means =1, as for the 0118 bool)" 'grep -q "^+[[:space:]]*\.flags = KERNEL_PARAM_OPS_FL_NOARG,$" "$PATCH"'
chk "pointer to the system genpd" 'grep -qx "+static struct generic_pm_domain \*psci_system_pd;" "$PATCH" && grep -q "^+[[:space:]]*psci_system_pd = pd;" "$PATCH"'
chk "PREEMPT_RT early return in psci_system_pd_apply()" 'grep -A1 "^+[[:space:]]*if (IS_ENABLED(CONFIG_PREEMPT_RT))" "$PATCH" | grep -q "^+[[:space:]]*return;"'
chk "flag flipped with WRITE_ONCE, both directions" 'grep -q "^+[[:space:]]*WRITE_ONCE(psci_system_pd->flags, flags);" "$PATCH" && grep -q "^+[[:space:]]*flags &= ~GENPD_FLAG_RPM_ALWAYS_ON;" "$PATCH" && grep -q "^+[[:space:]]*flags |= GENPD_FLAG_RPM_ALWAYS_ON;" "$PATCH"'
chk "0106 quirk kept: its lines are not removed, the flag is still set at probe (context line in the rewritten block)" '! dgrep -q "^-.*of_machine_is_compatible" && ! dgrep -q "^-.*pd->flags |= GENPD_FLAG_RPM_ALWAYS_ON;" && dgrep -qE "^[ +][[:space:]]*pd->flags \|= GENPD_FLAG_RPM_ALWAYS_ON;" && dgrep -q "^ [[:space:]]*if (of_machine_is_compatible(\"lenovo,baldur\") &&"'
chk "0118 untouched (no allow_cluster_off / -EBUSY line removed)" '! dgrep -q "^-.*allow_cluster_off" && ! dgrep -q "^-.*EBUSY"'
chk "only the two expected lines are removed (both rewritten with a brace)" '[ "$(dgrep -c "^-[^-]")" = 2 ] && dgrep -q "^-[[:space:]]*if (!IS_ERR(genpd))$"'
chk "no genpd lock taken" '! dgrep -q "^+.*genpd_lock"'
chk "one report line at boot and on change" 'grep -q "^+[[:space:]]*psci_system_pd_report(\"lenovo,baldur quirk, boot\");" "$PATCH" && grep -q "^+[[:space:]]*psci_system_pd_report(\"parameter written\");" "$PATCH"'
chk "hunk context is the 0118-patched file (allow_cluster_off desc as context)" 'grep -q "^ MODULE_PARM_DESC(allow_cluster_off," "$PATCH"'
chk "hunk context is the 0106-patched file (power-domain-system line rewritten, not added)" 'grep -q "^-[[:space:]]*of_node_name_eq(np, \"power-domain-system\"))$" "$PATCH" && grep -q "^+[[:space:]]*of_node_name_eq(np, \"power-domain-system\")) {$" "$PATCH"'
chk "commit message says how to switch and how to verify" 'grep -q "^How to switch:" "$PATCH" && grep -q "^How to verify it booted:" "$PATCH"'

if [ -d "$TREE" ]; then
	echo "== tree: $TREE"
	F=$TREE/$D
	chk "tree has $D" '[ -f "$F" ]'
	chk "tree has 0106 (lenovo,baldur quirk)" 'grep -q "of_machine_is_compatible(\"lenovo,baldur\")" "$F"'
	chk "tree has 0118 (allow_cluster_off, -EBUSY)" 'grep -q "allow_cluster_off" "$F" && grep -q "return -EBUSY;" "$F"'
	if grep -q "allow_system_off" "$F"; then
		echo "      1043 is in the tree: checking its shape"
		chk "default N" 'grep -qx "static bool allow_system_off;" "$F"'
		chk "module_param_cb 0644" 'grep -qx "module_param_cb(allow_system_off, &allow_system_off_ops, &allow_system_off, 0644);" "$F"'
		chk "ops flags NOARG" 'grep -q "KERNEL_PARAM_OPS_FL_NOARG" "$F"'
		chk "psci_system_pd pointer set in the quirk" 'grep -qx "static struct generic_pm_domain \*psci_system_pd;" "$F" && grep -q "psci_system_pd = pd;" "$F"'
		chk "WRITE_ONCE flip" 'grep -q "WRITE_ONCE(psci_system_pd->flags, flags);" "$F"'
		chk "RT guard (>= 2 IS_ENABLED(CONFIG_PREEMPT_RT): 0106 line + 1043 early return)" '[ "$(grep -c "IS_ENABLED(CONFIG_PREEMPT_RT)" "$F")" -ge 2 ]'
		chk "0106 still sets the flag at probe (>= 2 pd->flags |= GENPD_FLAG_RPM_ALWAYS_ON)" '[ "$(grep -c "pd->flags |= GENPD_FLAG_RPM_ALWAYS_ON;" "$F")" -ge 2 ]'
		chk "no genpd_lock in the file" '! grep -q "genpd_lock" "$F"'
		if command -v git >/dev/null && [ -f "$PATCH" ] && git -C "$TREE" rev-parse >/dev/null 2>&1; then
			chk "git apply --reverse --check: the tree carries exactly this 1043 (series detection will see it)" 'git -C "$TREE" apply --reverse --check "$PATCH"'
		fi
	else
		echo "      1043 not applied yet"
		if command -v git >/dev/null && [ -f "$PATCH" ] && git -C "$TREE" rev-parse >/dev/null 2>&1; then
			chk "git apply --check: 1043 applies cleanly on this tree" 'git -C "$TREE" apply --check "$PATCH"'
		fi
	fi
else
	echo "== tree: $TREE absent, source checks skipped (fine on the Win11 side)"
fi
[ $fail = 0 ] && echo "ALL PASS" || echo "SOME FAILED"
exit $fail

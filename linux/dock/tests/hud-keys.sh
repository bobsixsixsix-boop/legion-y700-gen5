#!/bin/sh
# hud-keys.sh (2026-10-23): static check that the performance numbers' .kv key names agree end to end. NOT an sb-bed
# scenario: plain sh, no tablet, no KWin; run it from the repo on the PC or anywhere (sh linux/dock/tests/hud-keys.sh).
#
# The keys are written by the sampler (linux/games/hud/overlay/src/sampler.rs, Kv::pairs) and read by name, as strings,
# in the status bar (y700-shellbar qml/hud.js, HudLine.qml, HudWidget.qml: num("k"), has("k"), H.color("k", ..), kv.k,
# and the thresholds table T in hud.js). The test bed scripts (hud.sh, hudlook.sh) write their own hand-made .kv. A
# renamed key breaks none of them: the QML reads undefined and shows "--" or 0, and the test bed, writing the old name
# too, still passes - only the real screen shows it (README 性能浮层 周期性义务). The compiler only checks main.rs.
#
# Checks (FAIL = exit 1):
#   1. every field of struct Kv is in Kv::pairs() (a field left out is never written)
#   2. every key the QML / hud.js reads, and every key of hud.js's T, is one the sampler writes
#   3. every key the test bed writes is one the sampler writes
#   4. every key the QML / hud.js reads is written somewhere in the test bed (else the bed never exercises it)
# INFO only: a pairs() key that differs from its field name; a sampler key nothing reads.
# Paths can be overridden for tests: HUD_SAMPLER, HUD_QML (directory with hud.js and the two QML files), HUD_BED
# (directory with hud.sh and hudlook.sh).
R=$(cd "$(dirname "$0")/../../.." && pwd)
SAMPLER=${HUD_SAMPLER:-$R/linux/games/hud/overlay/src/sampler.rs}
QML=${HUD_QML:-$R/linux/dock/y700-shellbar/qml}
BED=${HUD_BED:-$R/linux/dock/tests}
for f in "$SAMPLER" "$QML/hud.js" "$QML/HudLine.qml" "$QML/HudWidget.qml" "$BED/hud.sh" "$BED/hudlook.sh"; do
	[ -f "$f" ] || { echo "HUDKEYS_FAIL: $f missing"; exit 1; }
done
bad=0
fail() { echo "FAIL $*"; bad=1; }
words() { tr ' ' '\n' | sed '/^$/d' | sort -u | tr '\n' ' '; }
# in $1 (a word list) but not in $2
minus() { for w in $1; do case " $2 " in *" $w "*) ;; *) printf '%s ' "$w" ;; esac; done; }

pairs=$(sed -n '/fn pairs(/,/^    }/p' "$SAMPLER" | grep -o -E '\("[a-z_0-9]+", &self\.[a-z_0-9]+\)' | sed -E 's/\("([a-z_0-9]+)", &self\.([a-z_0-9]+)\)/\1:\2/')
keys=$(echo "$pairs" | cut -d: -f1 | words)
pfields=$(echo "$pairs" | cut -d: -f2 | words)
fields=$(sed -n '/pub struct Kv {/,/^}/p' "$SAMPLER" | grep -o -E 'pub [a-z_0-9]+: String' | sed -E 's/pub ([a-z_0-9]+):.*/\1/' | words)
[ -n "$keys" ] || { echo "HUDKEYS_FAIL: no Kv::pairs() entries found in $SAMPLER (layout changed? fix this script)"; exit 1; }
[ -n "$fields" ] || { echo "HUDKEYS_FAIL: no struct Kv fields found in $SAMPLER (layout changed? fix this script)"; exit 1; }
echo "sampler writes $(echo $keys | wc -w) keys: $keys"
for p in $pairs; do [ "${p%%:*}" = "${p#*:}" ] || echo "INFO key ${p%%:*} comes from field ${p#*:}"; done
m=$(minus "$fields" "$pfields"); [ -z "$m" ] || fail "struct Kv fields not in Kv::pairs() (never written): $m"

read=$(cat "$QML/hud.js" "$QML/HudLine.qml" "$QML/HudWidget.qml" |
	grep -o -E '(num|has)\((kv, *)?"[a-z_0-9]+"|color\("[a-z_0-9]+"|kv\.[a-z_0-9]+' | grep -o -E '"[a-z_0-9]+"|\.[a-z_0-9]+$' | tr -d '".' | words)
thr=$(sed -n '/^var T = {/,/^};/p' "$QML/hud.js" | grep -o -E '^ *[a-z_0-9]+:' | tr -d ' :' | words)
[ -n "$read" ] || { echo "HUDKEYS_FAIL: found no key reads in $QML (layout changed? fix this script)"; exit 1; }
echo "status bar reads $(echo $read | wc -w) keys: $read"
m=$(minus "$read" "$keys"); [ -z "$m" ] || fail "read by the status bar, not written by the sampler: $m"
m=$(minus "$thr" "$keys"); [ -z "$m" ] || fail "in hud.js's T table, not written by the sampler: $m"

bed=$(cat "$BED/hud.sh" "$BED/hudlook.sh" | grep -E 'hudkv|^[A-Z_]+="' | grep -v -E '^[[:space:]]*#|^hudkv\(\)' |
	grep -o -E '(^|[ "])[a-z_0-9]+=' | tr -d ' "=' | words)
[ -n "$bed" ] || { echo "HUDKEYS_FAIL: found no .kv samples in $BED/hud.sh, hudlook.sh (layout changed? fix this script)"; exit 1; }
m=$(minus "$bed" "$keys"); [ -z "$m" ] || fail "written by the test bed, not by the sampler: $m"
m=$(minus "$read" "$bed"); [ -z "$m" ] || fail "read by the status bar, never written by the test bed: $m"

m=$(minus "$keys" "$read"); [ -z "$m" ] || echo "INFO written by the sampler, read by nothing in the status bar: $m"
if [ $bad = 0 ]; then echo "HUDKEYS_OK"; else echo "HUDKEYS_FAIL"; exit 1; fi

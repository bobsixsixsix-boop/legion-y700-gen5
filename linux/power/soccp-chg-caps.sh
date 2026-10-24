#!/bin/bash
# PD negotiation per attach from the newest (or given) charger ulog, deduped (mV values folded so the PPS step loop collapses)
f=${1:-$(ls -t /root/chg-ulog-*.txt | head -1)}
echo "== $f ($(grep -c . $f) lines)"
grep -n -E 'CC attach=1|SourceCap|Evaluation|set_pd_contract|power_update: Input\[0\]|detach ModuleType:0, PartnerType:[1-9]|^--- ' "$f" |
sed -E 's/0x[0-9A-F]+: (Info|Warn|Error): //; s/pe_snk_evaluate_partner_source_caps: \[port_0\]: //' |
awk '
  /CC attach=1/ { delete seen; lastv = -1; print; next }
  /:--- / { split($0, a, "usb "); v = int(a[2] + 0.5); if (v != lastv) { print substr($0, 1, 160); lastv = v } next }
  { k = $0; sub(/^[0-9]+:/, "", k); gsub(/[0-9]+ ?mV/, "N mV", k); if (!(k in seen)) { seen[k] = 1; print substr($0, 1, 230) } }
'

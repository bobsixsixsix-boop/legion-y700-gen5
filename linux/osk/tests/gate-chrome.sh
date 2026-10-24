#!/bin/bash
# gate-chrome.sh: keyboard-popup cases for a Chromium (text-input v3) client, on tests/touchprobe.html in
# a throw-away Chrome placed on the right half (810,10 780x900) next to Telegram (left).
# Expected: field -> keyboard; grey pad -> none; re-tap a focused field -> keyboard; omnibox -> keyboard;
# focus restored by an activation (tap elsewhere) -> none.
K=/usr/local/libexec
act() { echo "for (const w of workspace.windowList()) if (w.resourceClass == '$1' && w.normalWindow) workspace.activeWindow = w;" | $K/kwin-eval.sh >/dev/null; sleep 0.8; }
run() { QUIET=1 GATELINES=${GL:-5} $K/gate-run.sh "$@"; }
FIELD="1086 169"; PAD="1083 451"; OMNI="1092 67"; TG_PANE="510 285"
# the probe Chrome on top of the right half (gate-matrix.sh puts Claude there)
echo "for (const w of workspace.windowList()) if (w.resourceClass == 'google-chrome' && w.normalWindow && w.caption.indexOf('touchprobe') >= 0) { w.setMaximize(false, false); w.frameGeometry = { x: 810, y: 10, width: 780, height: 900 }; workspace.activeWindow = w; }" | $K/kwin-eval.sh >/dev/null; sleep 1
act org.telegram.desktop; run c1-act-field "tap $FIELD 80" 2
run c3-refocus-field "tap $FIELD 80" 2
act org.telegram.desktop; run c2-act-pad-restore "tap $PAD 80" 2
run c0-focus-field "tap $FIELD 80" 2
act org.telegram.desktop; run c4-act-field-restore "tap $FIELD 80" 2
run c5-omnibox "tap $OMNI 80" 2
act google-chrome; run c6-tg-pane-from-chrome "tap $TG_PANE 80" 2

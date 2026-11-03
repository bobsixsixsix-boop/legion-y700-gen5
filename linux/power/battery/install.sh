#!/bin/bash
# install.sh: install the battery page's parts on the tablet (ROOT). 2026-10-30. Two stages of DESIGN.md section 9,
# each on its own:
#   install.sh          step 3: y700-batteryd, the resident recorder
#   install.sh --page   step 6: the report and the page. The recorder is not touched and the entry is not switched:
#                       install-entry.sh does that (step 7), once the page has been looked at
#
# The recorder: run from a staged copy of y700/linux/power/battery (e.g. /tmp/battery/install.sh). Builds recorder/
# offline against Ubuntu's packaged crates (libc only, recorder/.cargo/config.toml), runs its unit tests, then installs
#   /usr/local/libexec/y700-batteryd                         the recorder
#   ~user/.config/systemd/user/y700-batteryd.service     user unit (default.target), enabled and started
#   ~user/.local/state/y700-battery/                     the ledger directory, owned by user
# It needs flightrec with src/acc.rs deployed (/run/y700-flightrec/energy and edge): without them the recorder runs
# degraded (cov:0 in every S line, "degraded" in its journal) and still records everything else.
#
# The report and the page (--page): run from a staged copy that keeps the repository's layout from linux/ down, at
# least linux/power/battery, linux/power/flightrec/fixtures (the report's acc tests run flightrec's shared cases) and
# linux/dock/tests/batpage (the report's contract test and the page's load check read the canned reports there), e.g.
# /tmp/y700/linux/power/battery/install.sh --page. Runs the report's unit tests (python3; the 40-day timing against
# the tablet's 1.5 s target), builds page/ with cmake in /root/src/y700-battery-page, starts that build once off-screen
# on a canned report (the QML is compiled in, but a missing import or type only shows when the engine loads it), then
# installs
#   /usr/local/bin/y700-battery-report                       the report's entry script
#   /usr/local/lib/y700-battery/y700_battery/                its package, byte-compiled here: the report runs as
#                                                            user, who cannot write __pycache__ there
#   /usr/local/share/y700-battery/                           coeffs-v<N>.json and rules.json
#   /usr/local/libexec/y700-battery-page                     the page, its QML compiled in
# and runs the installed report once as user (read-only) to show it works on the real ledger, and how long it
# takes there (DESIGN.md section 11 item 9). Needs cmake, qt6-declarative-dev, and at run time the QML modules
# QtQuick.Shapes and org.kde.kirigami.
#
# Whatever either stage overwrites is saved first as /root/<name>.bak-<stamp>; no backup, no install.
# Undo:  install.sh --rollback                everything. The report and the page removed (saved first), and the
#                                             launcher /usr/local/bin/y700-battery put back to the newest saved one
#                                             that does not open the page (install-entry.sh saves what it replaces):
#                                             the entry opens KDE's battery page again. Then the recorder: stop +
#                                             disable, remove the binary and the unit (both saved first), and take the
#                                             ledger away as DESIGN.md section 9 says - moved, not deleted, to
#                                             /root/y700-battery-state.bak-<stamp>: refresh-auto's foreground log stops
#                                             with the directory gone
#        install.sh --rollback --keep-ledger  the same, the ledger left in place (the foreground log then goes on
#                                             growing there, with no recorder to prune it)
#        install.sh --rollback --page         the report, the page and the launcher only; the recorder and the
#                                             ledger stay
set -eu
U=user; H=/home/$U
HERE=$(cd "$(dirname "$0")" && pwd)
BIN=/usr/local/libexec/y700-batteryd
UNIT=$H/.config/systemd/user/y700-batteryd.service
STATE=$H/.local/state/y700-battery
SRC=/root/src/y700-batteryd
STAMP=$(date +%Y%m%d-%H%M%S)
RUN=(sudo -u $U env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus)
# the report and the page (--page); the launcher is install-entry.sh's, only --rollback puts an older one back
PAGE=/usr/local/libexec/y700-battery-page
REPORT=/usr/local/bin/y700-battery-report
LIB=/usr/local/lib/y700-battery
SHARE=/usr/local/share/y700-battery
LAUNCHER=/usr/local/bin/y700-battery
PSRC=/root/src/y700-battery-page
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 2; }

usage() {
	echo "usage: install.sh [--page | --rollback [--keep-ledger | --page]]" >&2
	exit 2
}

# backup PATH [NAME]: copied to /root/<NAME, default the basename>.bak-<stamp> before anything replaces or removes it;
# a failed copy stops here. NAME keeps apart the paths that share a basename (/usr/local/{bin,lib,share}/y700-battery)
backup() {
	[ -e "$1" ] || return 0
	local b=/root/${2:-$(basename "$1")}.bak-$STAMP
	cp -a "$1" "$b" || { echo "no backup of $1: stopping before it is touched" >&2; exit 2; }
	echo "saved $1 -> $b"
}

# --page: CRs from a Windows copy out of the files named in argv (python3, not sed: the tablet's rule for files edited
# in place). The recorder's stage keeps its own copy of this below, as it was
UNCR='import sys
for p in sys.argv[1:]:
    b = open(p, "rb").read()
    if b"\r" in b:
        open(p, "wb").write(b.replace(b"\r\n", b"\n"))'

# --rollback, --rollback --page: the entry back to KDE's page, then the report and the page gone
rollback_page() {
	# the launcher opens the page (install-entry.sh ran): the newest saved one that does not (the KDE-only launcher)
	# goes back. Without one the new launcher stays: with the page gone it opens KDE's page by itself.
	if [ -f $LAUNCHER ] && grep -q "$PAGE" $LAUNCHER; then
		local prev= b
		for b in /root/y700-battery.bak-*; do     # by name = by stamp: the newest last
			if [ -f "$b" ] && ! grep -q "$PAGE" "$b"; then prev=$b; fi
		done
		if [ -n "$prev" ]; then
			backup $LAUNCHER
			install -m 0755 "$prev" $LAUNCHER
			echo "launcher restored from $prev: the entry opens KDE's battery page again"
		else
			echo "no saved launcher without the page in /root/y700-battery.bak-*: $LAUNCHER stays (it opens KDE's battery page once the page is gone)"
		fi
	fi
	backup $PAGE
	backup $REPORT
	backup $LIB y700-battery-lib
	backup $SHARE y700-battery-share
	rm -rf $PAGE $REPORT $LIB $SHARE $H/.cache/y700-battery
	echo "report and page removed (and the page's cache)"
}

# --page: the report and the page; the recorder and the entry are not touched
install_page() {
	local f m rc out t0 t1
	command -v python3 >/dev/null || { echo "python3 missing" >&2; exit 2; }
	command -v cmake >/dev/null || { echo "cmake missing (apt install cmake: ask the owner first)" >&2; exit 2; }
	dpkg -s qt6-declarative-dev >/dev/null 2>&1 || { echo "qt6-declarative-dev missing (apt install qt6-declarative-dev: ask the owner first)" >&2; exit 2; }
	for f in report/y700-battery-report report/y700_battery/cli.py report/tests rules.json coeffs-v1.json \
		page/CMakeLists.txt page/src/main.cpp page/src/report.cpp page/src/report.h page/qml/Main.qml; do
		[ -e "$HERE/$f" ] || { echo "no $f next to $0" >&2; exit 2; }
	done
	local bat=$HERE/../../dock/tests/batpage
	[ -f "$bat/ok.json" ] || { echo "no linux/dock/tests/batpage beside this copy: stage it with the repository's layout from linux/ down" >&2; exit 2; }
	# the report's acc tests (tests/test_acc_ref.py) read flightrec's shared cases; without them five tests error out
	[ -f "$HERE/../flightrec/fixtures/acc/cases.txt" ] || { echo "no linux/power/flightrec/fixtures beside this copy (the report's acc tests read acc/cases.txt there): stage it with the repository's layout from linux/ down" >&2; exit 2; }
	# the QML's run-time imports beyond QtQuick (the load check below finds any other)
	local qml
	qml=$(qmake6 -query QT_INSTALL_QML 2>/dev/null) || qml=
	[ -n "$qml" ] || qml=/usr/lib/aarch64-linux-gnu/qt6/qml
	for m in QtQuick/Shapes org/kde/kirigami; do
		[ -f "$qml/$m/qmldir" ] || { echo "QML module $m missing under $qml (the page imports it; ask the owner before apt)" >&2; exit 2; }
	done
	find "$HERE/report" "$HERE/page" -type f \( -name '*.py' -o -name '*.json' -o -name '*.cpp' -o -name '*.h' \
		-o -name '*.qml' -o -name '*.js' -o -name CMakeLists.txt -o -name y700-battery-report \) \
		-exec python3 -c "$UNCR" {} +
	python3 -c "$UNCR" "$HERE"/coeffs-v*.json "$HERE/rules.json"

	# the report's unit tests (DESIGN.md section 8): a failing one stops here, nothing installed. -B: no __pycache__
	# in the staged copy; -I: nothing from the current directory and no PYTHON* variables. Y700_BATTERY_PERF_LIMIT
	# (not a PYTHON* one, so it gets through): test_cli's 40-day timing is held to the tablet's target in DESIGN.md
	# 6b.b / section 11 item 9, 1.5 s, not to the 1.0 s it asserts on the dev PC
	echo "--- report unit tests"
	Y700_BATTERY_PERF_LIMIT=1.5 python3 -X utf8 -I -B -m unittest discover -s "$HERE/report/tests" -t "$HERE/report" \
		|| { echo "report tests failed: nothing installed" >&2; exit 1; }

	# the page, built in a root-owned copy (as the recorder is): sources replaced, the build directory kept
	install -d $PSRC
	rm -rf $PSRC/src $PSRC/qml $PSRC/CMakeLists.txt
	cp -r "$HERE/page/CMakeLists.txt" "$HERE/page/src" "$HERE/page/qml" $PSRC/
	cmake -S $PSRC -B $PSRC/build -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local >/dev/null
	cmake --build $PSRC/build -j8

	# does it load? Off-screen on the canned ok.json (no cache, no signal, no report run): exit 1 within the time =
	# the QML did not load (main.cpp); still up when timeout ends it (124) = loaded. Warnings are shown, not judged.
	local plug
	plug=$(qmake6 -query QT_INSTALL_PLUGINS 2>/dev/null) || plug=
	[ -n "$plug" ] || plug=/usr/lib/aarch64-linux-gnu/qt6/plugins
	if [ -f "$plug/platforms/libqoffscreen.so" ]; then
		rc=0
		env -u WAYLAND_DISPLAY -u DISPLAY QT_QPA_PLATFORM=offscreen Y700_BATTERY_REPORT="$bat/ok.json" \
			timeout 6 $PSRC/build/y700-battery-page > $PSRC/build/load.log 2>&1 || rc=$?
		grep -E 'qrc:|qml|QML' $PSRC/build/load.log | head -n 20 || true
		[ $rc = 124 ] || { echo "the page did not stay up off-screen (exit $rc, $PSRC/build/load.log): nothing installed" >&2; exit 1; }
		echo "page loads off-screen"
	else
		echo "no offscreen platform plugin under $plug: load check skipped"
	fi

	backup $PAGE
	backup $REPORT
	backup $LIB y700-battery-lib
	backup $SHARE y700-battery-share
	install -D -m 755 $PSRC/build/y700-battery-page $PAGE
	install -m 755 "$HERE/report/y700-battery-report" $REPORT
	# whole directories replaced: a module or a coeffs-v<N>.json dropped from the repository must not stay behind
	# (the report takes the highest N)
	rm -rf $LIB $SHARE
	install -d $LIB $SHARE
	cp -r "$HERE/report/y700_battery" $LIB/
	find $LIB -name __pycache__ -prune -exec rm -rf {} +
	chmod -R u=rwX,go=rX $LIB
	python3 -I -m compileall -q $LIB/y700_battery >/dev/null
	install -m 644 "$HERE"/coeffs-v*.json "$HERE/rules.json" $SHARE/

	# the installed report once, as the page runs it (read-only: no cache, no ledger write, no signal), and timed for
	# DESIGN.md section 11 item 9 (< 1.5 s on 40 days of ledger): took_ms is the report's own count from cli.main on,
	# the wall time adds sudo and python's start-up and imports; the ledger's size says how many days it had
	echo "--- y700-battery-report --json as $U:"
	rc=0
	t0=$(date +%s%N)
	out=$("${RUN[@]}" HOME=$H $REPORT --json 2>$PSRC/build/report.err) || rc=$?
	t1=$(date +%s%N)
	printf '%s' "$out" | python3 -I -c 'import json, sys
try:
    d = json.load(sys.stdin)
except ValueError as e:
    sys.exit("not JSON: %s" % e)
if not isinstance(d, dict):
    sys.exit("not a JSON object")
if "error" in d:
    print("report error:", d["error"])
else:
    r = (d.get("ranges") or {}).get("since_full") or {}
    lb = (d.get("diag") or {}).get("ledger_bytes")
    print("took %s ms in the report; since_full %s, used %s%%, %d items; ledger %s"
          % (d.get("took_ms"), r.get("state"), r.get("used_pct"), len(r.get("items") or []),
             "%.1f MiB" % (lb / 1048576) if isinstance(lb, (int, float)) else "?"))' || true
	echo "report run on the tablet: $(( (t1 - t0) / 1000000 )) ms wall as $U (sudo and python start-up included; target < 1500 ms on 40 days)"
	[ $rc = 0 ] || echo "the report exited $rc (stderr in $PSRC/build/report.err); the page is installed and shows its error" >&2
	echo "entry not switched: bash install-entry.sh switches it (DESIGN.md section 9 step 7)"
	echo "PAGE_INSTALL_OK $(sha256sum $PAGE | cut -c1-16)"
}

if [ "${1:-}" = --rollback ]; then
	KEEP=0; PAGEONLY=0
	case "${2:-}" in
	"") ;;
	--keep-ledger) KEEP=1 ;;
	--page) PAGEONLY=1 ;;
	*) usage ;;
	esac
	rollback_page
	if [ $PAGEONLY = 1 ]; then echo ROLLBACK_OK; exit 0; fi
	"${RUN[@]}" systemctl --user disable --now y700-batteryd.service || true
	backup $BIN
	backup $UNIT
	rm -f $BIN $UNIT
	"${RUN[@]}" systemctl --user daemon-reload || true
	rm -rf /run/user/1000/y700-battery
	if [ ! -d $STATE ]; then
		echo "no ledger at $STATE"
	elif [ $KEEP = 1 ]; then
		echo "ledger kept: $STATE (refresh-auto's foreground log goes on there until it is removed)"
	else
		mv $STATE /root/y700-battery-state.bak-$STAMP || { echo "could not move $STATE away" >&2; exit 1; }
		echo "ledger moved to /root/y700-battery-state.bak-$STAMP (refresh-auto's foreground log stops)"
	fi
	echo ROLLBACK_OK
	exit 0
fi
if [ "${1:-}" = --page ]; then
	[ $# -eq 1 ] || usage
	install_page
	exit 0
fi
[ $# -eq 0 ] || usage

command -v cargo >/dev/null || { echo "cargo missing (apt install cargo: ask the owner first)" >&2; exit 2; }
[ -f "$HERE/recorder/Cargo.toml" ] && [ -f "$HERE/recorder/y700-batteryd.service" ] || { echo "no recorder/ next to $0" >&2; exit 2; }
# CRs from a Windows copy out (python3, not sed: the tablet's rule for files edited in place)
find "$HERE/recorder" -type f \( -name '*.rs' -o -name '*.toml' -o -name '*.service' -o -name Cargo.lock \) -exec \
	python3 -c 'import sys
for p in sys.argv[1:]:
    b = open(p, "rb").read()
    if b"\r" in b:
        open(p, "wb").write(b.replace(b"\r\n", b"\n"))' {} +

# build + unit tests (DESIGN.md section 8) in a root-owned copy; a failing test stops here, nothing installed
install -d $SRC
rm -rf $SRC/src $SRC/.cargo
cp -r "$HERE/recorder/Cargo.toml" "$HERE/recorder/src" "$HERE/recorder/.cargo" $SRC/
if [ -f "$HERE/recorder/Cargo.lock" ]; then cp "$HERE/recorder/Cargo.lock" $SRC/; fi
(cd $SRC && cargo build --release --offline && cargo test --release --offline --quiet)

"${RUN[@]}" systemctl --user stop y700-batteryd.service 2>/dev/null || true
backup $BIN
backup $UNIT
install -m 755 $SRC/target/release/y700-batteryd $BIN
install -d -o $U -g $U $H/.config/systemd/user
install -m 644 -o $U -g $U "$HERE/recorder/y700-batteryd.service" $UNIT
[ -d $H/.local/state ] || install -d -m 755 -o $U -g $U $H/.local/state
install -d -m 755 -o $U -g $U $STATE

"${RUN[@]}" systemctl --user daemon-reload
"${RUN[@]}" systemctl --user enable y700-batteryd.service
"${RUN[@]}" systemctl --user restart y700-batteryd.service
sleep 3
st=$("${RUN[@]}" systemctl --user is-active y700-batteryd.service || true)
echo "is-active: $st"
"${RUN[@]}" journalctl --user -u y700-batteryd -n 8 --no-pager -o cat || true
ls -la $STATE
[ "$st" = active ] || { echo "y700-batteryd is not running (undo: bash $0 --rollback)" >&2; exit 1; }
echo "--- --once as $U (no lock, no ledger):"
"${RUN[@]}" HOME=$H $BIN --once | cut -c1-400
echo "INSTALL_OK $(sha256sum $BIN | cut -c1-16)"

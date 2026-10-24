#!/bin/bash
# linux/carplay/livi/test-ps-restore.sh -- stub test for y700-carplay-ps-restore and its NetworkManager dispatcher hook
# 90-y700-carplay-ps (10-24). Runs anywhere (Git Bash on the PC, or the tablet as any user): fake iw and logger on
# PATH, the pending mark and helper.toml in a temporary directory; nothing real is touched. ~20 s.
#   quick     a station at once, power save off -> restored, no mark left
#   already   a station, power save on -> left as it is, no mark left
#   helperd   helper.toml's power_save_off lists the interface -> left off, no mark left
#   late      still an access point after the wait (23:49 on 10-23) -> deferred, mark kept; then the hook:
#             "down" -> nothing; "up" while still an access point -> still pending; "up" as a station -> restored,
#             mark gone; "up" once more -> nothing
#   setfail   iw set power_save on does not take -> not restored, mark kept for the hook
#   nomark    the hook on "up" with nothing pending -> nothing, iw untouched
#   hang      iw never answers (IW_S 1, MAX 2) -> ends within MAX + 4 * IW_S + 1, deferred
H=$(cd "$(dirname "$0")" && pwd)
R=${1:-$H/y700-carplay-ps-restore}
HOOK=${2:-$H/90-y700-carplay-ps}
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
cat >"$T/bin/iw" <<'EOF'
#!/bin/sh
[ -e "$STUB/hang" ] && exec sleep 10
echo "$*" >>"$STUB/calls"
case "$3" in
    info) [ -e "$STUB/ap" ] && printf '\ttype AP\n' || printf '\ttype managed\n' ;;
    get) echo "Power save: $(cat "$STUB/ps")" ;;
    set) [ -e "$STUB/setfail" ] || echo "$5" >"$STUB/ps" ;;
esac
EOF
cat >"$T/bin/logger" <<'EOF'
#!/bin/sh
shift 2; echo "$*" >>"$STUB/log"
EOF
printf '#!/bin/sh\nexec bash "%s" "$@"\n' "$R" >"$T/bin/ps-restore"
chmod +x "$T"/bin/*
export STUB=$T PATH="$T/bin:$PATH" Y700_PS_PENDING_DIR=$T/run Y700_HELPER_TOML=$T/helper.toml Y700_PS_RESTORE=$T/bin/ps-restore
MARK=$T/run/ps-pending-wlp1s0

fails=0
reset() {   # power save off (as LIVI leaves it), a station, nothing pending
    rm -rf "$T/run" "$T/ap" "$T/hang" "$T/setfail" "$T/calls" "$T/log" "$T/helper.toml"; : >"$T/log"
    echo off >"$T/ps"
}
stop() { bash "$R" wlp1s0 "${1:-2}" >/dev/null; }
hook() { sh "$HOOK" wlp1s0 "$1"; }
lines() { wc -l <"$T/log" | tr -d ' '; }
expect() {   # name, what the last log line must say ("" for no new line since $n), mark (yes/no), power save
    local why=
    if [ -z "$2" ]; then
        [ "$(lines)" = "$n" ] || why="new log lines"
    else
        tail -n 1 "$T/log" | grep -qF -- "$2" || why="last log line wants \"$2\""
    fi
    { [ "$3" = yes ] && [ -e "$MARK" ]; } || { [ "$3" = no ] && [ ! -e "$MARK" ]; } || why="$why${why:+, }mark should be $3"
    [ "$(cat "$T/ps")" = "$4" ] || why="$why${why:+, }power save $(cat "$T/ps"), want $4"
    if [ -z "$why" ]; then
        echo "PASS $1"
    else
        echo "FAIL $1: $why"; sed 's/^/     /' "$T/log"; fails=$((fails + 1))
    fi
}

reset; stop
expect quick "restored after the CarPlay access point: Power save: on" no on

reset; echo on >"$T/ps"; stop
expect already "already on" no on

reset; printf '[wifi]\npower_save_off = ["wlp1s0"]\n' >"$T/helper.toml"; stop
expect helperd "left off: tb323fu-helperd" no off

reset; touch "$T/ap"; stop
expect late "deferred to NetworkManager's dispatcher" yes off
grep -q . "$MARK" || { echo "FAIL late: the mark has no time in it"; fails=$((fails + 1)); }
n=$(lines); hook down
expect "late, hook on down" "" yes off
hook up
expect "late, hook on up while still an access point" "still pending for the next time" yes off
rm -f "$T/ap"; hook up
expect "late, hook on up as a station" "restored when NetworkManager brought wlp1s0 up (pending since 20" no on
n=$(lines); echo off >"$T/ps"; hook up
expect "late, hook on up once more" "" no off

reset; touch "$T/setfail"; stop
expect setfail "left 'Power save: off'" yes off

reset; n=0; hook up
expect nomark "" no off
[ ! -e "$T/calls" ] || { echo "FAIL nomark: iw was called"; fails=$((fails + 1)); }

reset; touch "$T/hang"; t0=$SECONDS; Y700_PS_IW_S=1 bash "$R" wlp1s0 2 >/dev/null; took=$((SECONDS - t0))
expect hang "iw gave no type" yes off
[ "$took" -le 7 ] || { echo "FAIL hang: took ${took}s, want <= 7"; fails=$((fails + 1)); }

[ $fails = 0 ] && echo "all passed" || echo "$fails failed"
exit $fails

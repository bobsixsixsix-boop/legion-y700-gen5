#!/bin/bash
# linux/power/flightrec/test-deploy.sh [DEPLOY] -- stub test for deploy.sh's backup and rollback (10-19 audit).
# Runs anywhere (Git Bash on the PC, the tablet as any user): a fake root (Y700_FR_ROOT), fake systemctl/systemd-run/
# sleep on PATH, two fake recorders (shell scripts); nothing real is touched.
#   first   Python era: y700-flightrec.py is the recorder, no binary yet; a bad Rust build must leave the Python
#           recorder and its unit in place
#   second  Rust over Rust: y700-flightrec.py is a symlink to the good binary; a bad build must leave the good binary
#           (the old deploy.sh backed up the binary through the symlink and restored the bad one)
#   good    a good build over the good one is installed and kept
#   busy    a CX knob is on: `bash deploy.sh src` started in its dir changes nothing (busy-wait) and queues a retry;
#           the retry, run from / like the transient unit 30 min later, installs the good build (busy-retry; the old
#           deploy.sh queued the relative "deploy.sh" and "src", which bash cannot find from /: exit 127, nothing
#           deployed, the deploy log stuck at "retrying in 30 min" - 10-19 audit B6)
H=$(cd "$(dirname "$0")" && pwd)
D=${1:-$H/deploy.sh}
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
cat >"$T/bin/systemctl" <<'EOF'
#!/bin/bash
# the unit "runs" its ExecStart once with --start, which writes the log lines deploy.sh looks for
case "$1" in
    is-active) [ "$2" = -q ] && shift; [ "$2" = y700-flightrec ] && { [ "$1" = is-active ] && :; exit 0; }; exit 3 ;;
    restart)
        exe=$(sed -n 's/^ExecStart=\([^ ]*\).*/\1/p' "$Y700_FR_ROOT/etc/systemd/system/y700-flightrec.service")
        "$Y700_FR_ROOT$exe" --start ;;
esac
exit 0
EOF
# the retry timer: keeps the command it would run 30 min later (busy runs it from /, a system unit's working dir)
cat >"$T/bin/systemd-run" <<'EOF'
#!/bin/bash
while [ $# -gt 0 ]; do case $1 in --unit) shift 2 ;; -*) shift ;; *) break ;; esac; done
printf '%s\n' "$@" >"$Y700_FR_ROOT/queued"
EOF
printf '#!/bin/sh\nexit 0\n' >"$T/bin/sleep"
chmod +x "$T"/bin/*
# $1 = name; good recorders write HEADER/MODE/sample and answer --once, the bad one writes nothing and fails --once
recorder() {
    local log='$Y700_FR_ROOT/var/log/y700-flightrec/current.log'
    if [ "$2" = good ]; then
        printf '#!/bin/sh\n# %s\n[ "$1" = --once ] && { echo "t=1 qs=0"; exit 0; }\nprintf "HEADER idle_interval=10\\nMODE slow\\nt=1 qs=0\\n" >>"%s"\n' "$1" "$log"
    else
        printf '#!/bin/sh\n# %s\nexit 1\n' "$1"
    fi
}
fails=0
setup() {  # $1 = first|second
    rm -rf "$T/r" "$T/src"; mkdir -p "$T/r/usr/local/libexec" "$T/r/etc/systemd/system" "$T/r/root" "$T/r/var/log/y700-flightrec" \
        "$T/r/sys/module/cpuidle_psci_domain/parameters" "$T/r/run" "$T/src"
    local L=$T/r/usr/local/libexec
    if [ "$1" = first ]; then
        recorder python good >"$L/y700-flightrec.py"; chmod +x "$L/y700-flightrec.py"
        echo "ExecStart=/usr/local/libexec/y700-flightrec.py --interval 1" >"$T/r/etc/systemd/system/y700-flightrec.service"
    else
        recorder rust-v1 good >"$L/y700-flightrec"; chmod +x "$L/y700-flightrec"
        ln -s y700-flightrec "$L/y700-flightrec.py"
        echo "ExecStart=/usr/local/libexec/y700-flightrec --interval 1" >"$T/r/etc/systemd/system/y700-flightrec.service"
    fi
    echo "ExecStart=/usr/local/libexec/y700-flightrec --interval 1" >"$T/src/y700-flightrec.service"
}
check() {  # name, the recorder the unit must run afterwards (its marker line)
    local exe; exe=$(sed -n 's/^ExecStart=\([^ ]*\).*/\1/p' "$T/r/etc/systemd/system/y700-flightrec.service")
    if grep -qx "# $2" "$T/r$exe" 2>/dev/null; then echo "PASS $1"; else
        echo "FAIL $1: the unit runs $exe = $(sed -n 2p "$T/r$exe" 2>/dev/null || echo missing), want $2"
        sed 's/^/     /' "$T/r/var/log/y700-flightrec-deploy.txt"; fails=$((fails + 1)); fi
}
run() { Y700_FR_ROOT=$T/r PATH="$T/bin:$PATH" bash "$D" "$T/src" >/dev/null 2>&1; }

setup first;  recorder rust-bad bad >"$T/src/y700-flightrec"; chmod +x "$T/src/y700-flightrec"; run; check first python
setup second; recorder rust-bad bad >"$T/src/y700-flightrec"; chmod +x "$T/src/y700-flightrec"; run; check second rust-v1
setup second; recorder rust-v2 good >"$T/src/y700-flightrec"; chmod +x "$T/src/y700-flightrec"; run; check good rust-v2
setup second; recorder rust-v2 good >"$T/src/y700-flightrec"; chmod +x "$T/src/y700-flightrec"
K=$T/r/sys/module/cpuidle_psci_domain/parameters/allow_cluster_off; echo Y >"$K"; cp "$D" "$T/deploy.sh"
(cd "$T" && Y700_FR_ROOT=$T/r PATH="$T/bin:$PATH" bash deploy.sh src >/dev/null 2>&1); check busy-wait rust-v1
rm "$K"; q=(); [ -e "$T/r/queued" ] && mapfile -t q <"$T/r/queued"
(cd / && Y700_FR_ROOT=$T/r PATH="$T/bin:$PATH" "${q[@]}" >/dev/null 2>&1); check busy-retry rust-v2
[ $fails = 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }

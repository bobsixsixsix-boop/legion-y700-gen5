#!/bin/bash
# Unit test of y700-carplay-ap-m1watch with a synthetic hostapd log and a sleep standing in for hostapd.
W=${1:-/root/y700-carplay-ap-m1watch}
L=/tmp/m1w-test.log
st() { echo "1792238925.6: WPA: $1 WPA_PTK entering state $2" >>"$L"; sleep 0.3; }
run() {  # name, then the lines as "sta state" pairs; prints exit status and whether the stand-in is still alive
    local name=$1; shift
    : >"$L"; sleep 300 & local P=$!
    "$W" "$L" "$P" 3 >/tmp/m1w-out.txt & local WP=$!
    sleep 1.2
    while [ $# -gt 0 ]; do st "$1" "$2"; shift 2; done
    sleep 1.5
    if kill -0 "$P" 2>/dev/null; then alive=alive; kill "$P"; else alive=killed; fi
    wait "$WP"; local rc=$?
    echo "$name: hostapd stand-in $alive, m1watch exit $rc, said: $(cat /tmp/m1w-out.txt)"
}
A=aa:bb:cc:00:00:01; B=aa:bb:cc:00:00:02
run "good handshake, then 3 PTKSTART (rekey-like)" $A AUTHENTICATION $A PTKSTART $A PTKCALCNEGOTIATING $A PTKINITDONE $A PTKSTART $A PTKSTART $A PTKSTART
run "two unanswered 1/4s only" $A AUTHENTICATION $A PTKSTART $A PTKSTART $A DISCONNECT
run "unanswered x2, re-association, unanswered x2" $A AUTHENTICATION $A PTKSTART $A PTKSTART $A AUTHENTICATION $A PTKSTART $A PTKSTART
run "two stations interleaved, 2 each" $A AUTHENTICATION $B AUTHENTICATION $A PTKSTART $B PTKSTART $A PTKSTART $B PTKSTART
run "three unanswered 1/4s (the firmware drop)" $A AUTHENTICATION $A INITPSK $A PTKSTART $A PTKSTART $A PTKSTART $A PTKSTART
rm -f "$L" /tmp/m1w-out.txt

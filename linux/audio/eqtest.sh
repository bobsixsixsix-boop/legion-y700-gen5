#!/bin/bash
export XDG_RUNTIME_DIR=/run/user/$(id -u) DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus
nid() { pw-dump | python3 -c "import json,sys; n=sys.argv[1]; print(next(o['id'] for o in json.load(sys.stdin) if o.get('type')=='PipeWire:Interface:Node' and o.get('info',{}).get('props',{}).get('node.name')==n))" "$1"; }
P=$(nid effect_input.speakers); L=$(nid effect_input.y700_lenovo)
echo "prot=$P lenovo=$L"; [ -n "$P" ] || exit 1
wpctl set-mute "$P" 1
wpctl get-volume "$P" | grep -q MUTED || { echo "mute failed, abort"; exit 1; }
wpctl set-volume "$L" 1.0
cd /tmp && python3 /tmp/eqtest.py
wpctl set-mute "$P" 0; wpctl get-volume "$P"; wpctl get-volume "$L"

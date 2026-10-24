#!/system/bin/sh
# Y700 Switcher status: one key=value per line, read by the app.
D=/data/adb/y700
android=$(cut -c1-64 "$D/android.sha256" 2>/dev/null)
h() { sha256sum "$1" 2>/dev/null | cut -c1-64; }
a=$(h /dev/block/by-name/boot_a); b=$(h /dev/block/by-name/boot_b)
img=/data/adb/tb323fu/linux.img; want=$(cut -c1-64 "$img.sha256" 2>/dev/null)
echo "slot=$(getprop ro.boot.slot_suffix)"
echo "boot_b_ok=$([ -n "$android" ] && [ "$b" = "$android" ] && echo yes || echo no)"
echo "boot_a=$([ "$a" = "$android" ] && echo android || { [ "$a" = "$want" ] && echo linux || echo other; })"
echo "staged=$([ -f "$img" ] && [ "$(h "$img")" = "$want" ] && echo ${want:0:12} || echo none)"

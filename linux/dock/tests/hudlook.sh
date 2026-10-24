# sb-bed scenario (10-22): how the desktop performance widget (qml/HudWidget.qml) looks in every state it has, on
# the wallpaper in use - the shots a layout change is judged by (10-22: the first layout of the widget looked
# unbalanced). No windows, no touches: the widget is up from the first shot. Each state is one
# sample written as the sampler writes it; the values are real readings (w2 is a real-device state,
# a 5 V USB port that cannot keep up; its screenshot is not included). The shellbar log gets the card's size per state ("hud widget: ...").
#   SB_WALL=/home/user/Pictures/<wallpaper>.png SB_BAR=/opt/y700-next/bin/y700-shellbar \
#       sh ./sb-bed.sh hudlook.sh /root/sb-hudlook
# A light sky (the worst case for white text): the same wallpaper at 1.7 x brightness (PIL ImageEnhance.Brightness)
# as SB_WALL (the comparison screenshot of both is not included).
KV=$XDG_RUNTIME_DIR/y700-hud.txt.kv
MODE=$XDG_RUNTIME_DIR/y700-hud.mode
hudkv() { printf '%s\n' "$@" > "$KV.tmp" && mv "$KV.tmp" "$KV"; sleep 0.8; }
CORE="fps= hz=30 cpu=1 cpu_mhz=768 cpu_c=36 gpu=0 gpu_mhz=160 gpu_c=36 skin_c=36 thr=0"
OFF="on=0 bat_w= in_w=0.0 in_v=0.00 in_a=0.00 adapter="

echo full > "$MODE"
# shellcheck disable=SC2086
{
mark idle;  hudkv $CORE sys_w=3.4 $OFF bat_pct=96;                                                   shot w1-idle
            sbexpect "hud widget: shown full"
mark usb;   hudkv $CORE sys_w=3.4 on=1 bat_w=-0.7 in_w=2.7 in_v=4.90 in_a=0.55 adapter=SDP bat_pct=96; shot w2-usb5v
mark pd;    hudkv $CORE sys_w=4.3 on=1 bat_w=15.6 in_w=19.9 in_v=8.95 in_a=2.22 adapter=PD bat_pct=62;  shot w3-pd
mark pps;   hudkv $CORE sys_w= on=1 bat_w=21.4 in_w= in_v=9.10 in_a= adapter=PPS bat_pct=40;            shot w4-pps
mark full;  hudkv $CORE sys_w=4.1 on=1 bat_w=0.1 in_w=4.2 in_v=8.95 in_a=0.47 adapter=PD bat_pct=100;    shot w5-full
mark hot;   hudkv fps= hz=120 cpu=91 cpu_mhz=3400 cpu_c=96 gpu=99 gpu_mhz=700 gpu_c=88 skin_c=51 thr=1 sys_w=13.2 $OFF bat_pct=62
            shot w6-hot
mark wide;  hudkv fps= hz=120 cpu=100 cpu_mhz=4396 cpu_c=99 gpu=100 gpu_mhz=900 gpu_c=99 skin_c=56 thr=0 sys_w=18.8 $OFF bat_pct=100
            shot w7-widest
mark mini;  echo mini > "$MODE"; hudkv $CORE sys_w=3.4 $OFF bat_pct=96;                              shot w8-mini
mark minipd; hudkv $CORE sys_w=4.3 on=1 bat_w=15.6 in_w=19.9 in_v=8.95 in_a=2.22 adapter=PD bat_pct=62; shot w9-mini-pd
}
wins

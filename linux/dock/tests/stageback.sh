# sb-bed scenario (11-09): the Stage Manager's backdrop (y700-shellbar qml/Backdrop.qml) and the see-through status
# bar over it. The stage script (linux/stage) calls fyi.y700.Shellbar.setStage(b) as it turns on / off; here the
# scenario calls it itself (no stage script in this bed). The bar reads the desktop's picture out of
# plasma-org.kde.plasma.desktop-appletsrc as the stage opens; the bed has none, so the scenario writes one into the
# bed's config, its Image= a file:// URL with a Chinese file name, as the tablet's own (11-09).
#   SB_BAR=/tmp/y700st2/prefix/bin/y700-shellbar sh ./sb-bed.sh stageback.sh /tmp/y700st2/out-back   (a build installed
#   with -DCMAKE_INSTALL_PREFIX=/tmp/y700st2/prefix, so its QML comes from there; leave SB_BAR out once installed)
# Shots (OUT/*.png): b0-before  a small app over the bed's wallpaper, the status bar drawn
#                    b1-on      the backdrop: the wallpaper blurred, a little darker, the status bar gone
#                    b2-off     back as b0 (the backdrop fades out in 300 ms and its window goes)
#                    b3-nowall  no picture found: the plain fallback colour (#2a3346)
setstage() { busctl --user call fyi.y700.Shellbar /Shellbar fyi.y700.Shellbar setStage b "$1" >/dev/null 2>&1 || echo "setStage $1 failed" >> "$LOG"; }
RC=$T/config/plasma-org.kde.plasma.desktop-appletsrc
cp "$T/wall.png" "$T/data/测试壁纸.png"
printf '[Containments][1]\nwallpaperplugin=org.kde.image\n\n[Containments][1][Wallpaper][org.kde.image][General]\nImage=file://%s\n' "$T/data/测试壁纸.png" > "$RC"

mark before
app Blue '#2c6fd6' --small
sleep 0.5
shot b0-before

mark on
setstage true
sleep 1
shot b1-on
wins
sbexpect 'stage on'
sbreject 'no wallpaper found'
expect 'y700-shellbar/@0,0+1600x1002'   # the backdrop (a layer window: no caption)

mark off
setstage false
sleep 1
shot b2-off
wins
sbexpect 'stage off'
reject 'y700-shellbar/@0,0+1600x1002'

mark nowall
rm -f "$RC"
setstage true
sleep 1
shot b3-nowall
sbexpect 'stage on (no wallpaper found)'
setstage false
sleep 0.5

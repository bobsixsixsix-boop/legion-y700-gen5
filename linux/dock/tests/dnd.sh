# sb-bed scenario (11-09): do not disturb (qml/Banners.qml; fn+F6 on the Magic Keyboard -> y700-dnd-toggle.desktop
# -> fyi.y700.Shellbar.toggleDoNotDisturb). Written as the tablet's own 11-03/11-04 shellbar work (do not disturb,
# the keyboard's and the mouse's battery: kbd-dnd-mouse-20261104.patch) came into git; that work was tried in a bed
# on 11-03 that never reached git. The keyboard's and the mouse's battery need UPower on the system bus: not here.
#   SB_BAR=/tmp/y700st2/prefix/bin/y700-shellbar sh ./sb-bed.sh dnd.sh /tmp/y700st2/out-dnd   (a build installed
#   with -DCMAKE_INSTALL_PREFIX=/tmp/y700st2/prefix; leave SB_BAR out once installed)
# Shots (OUT/*.png): d0-on        do not disturb on: the crescent in the status bar, no banner for a normal one
#                    d1-critical  a critical one still comes up as a banner
#                    d2-after     off again: a new one is a banner, the one held back is not
app Kate '#3d7bf7'
sleep 1

# before: a banner as always; it goes by itself in 5 s, so the rest starts from an empty screen
mark before
notify "勿扰前" "开勿扰之前的一条照常出横幅"
sleep 0.7
sbexpect "banner + 勿扰前"
sleep 5.5
sbexpect "banner expired: 勿扰前"

# on: a normal one stays out (it goes straight to the notification centre)
mark on
sbcall toggleDoNotDisturb
sleep 0.5
sbexpect "do not disturb on"
notify "勿扰中" "普通的一条不出横幅"
sleep 0.7
sbreject "banner + 勿扰中"
shot d0-on

# a critical one comes up all the same
mark critical
notify-send -u critical -a 测试 "紧急" "紧急的一条照样出横幅" >> "$LOG" 2>&1; sleep 0.3
sleep 0.7
sbexpect "banner + 紧急"
shot d1-critical

# off: what came in meanwhile is expired just before, so it does not all come up late as banners
mark off
sbcall toggleDoNotDisturb
sleep 0.8
sbexpect "do not disturb off"
sbexpect "held back, to the notification centre"
sbreject "banner + 勿扰中"

# after: banners as before
mark after
notify "勿扰后" "关了勿扰，新的一条又出横幅"
sleep 0.7
sbexpect "banner + 勿扰后"
sbreject "banner + 勿扰中"
shot d2-after

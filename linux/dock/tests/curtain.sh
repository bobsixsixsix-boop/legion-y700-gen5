# sb-bed scenario: the shellbar's notification banners and the control centre's curtain (phase 2, 10-22).
#   SB_CC=/opt/y700-next/bin/y700-control-center sh ./sb-bed.sh curtain.sh /root/sb-curtain   (a control centre
#   not installed yet); plain `sh ./sb-bed.sh curtain.sh /root/sb-curtain` for the installed one.
# y700-shellbar is the notification server (the bed starts it first); the notification centre watches it.
# the shellbar registered org.freedesktop.Notifications at start (before any mark: the whole log)
sbexpect "notifications: serving"
app Kate '#3d7bf7'
sleep 1

# banners: three cards at the top of the screen, the newest on top; the window is the 680 px band KWin centred
# (the mark before the notifications: sbexpect reads the shellbar's log from the last mark on)
mark banners
notify "张三" "晚上吃火锅吗？我订了七点的位子。" "Telegram"
notify "下载完成" "y700-kernel-y13.tar.zst 已保存到「下载」" "Google Chrome"
notify "电量低" "剩余 15%，请连接充电器" "电源管理"
sleep 0.7
sbexpect "banner + 张三"
sbexpect "banner + 电量低"
wins
expect "y700-shellbar/@460,0+680x480"
shot c5-banners
# a swipe up on the top card sends it off (expired: it is still in the notification centre); the others move up
swipe 800 100 800 20 150
sleep 0.6
sbexpect "banner swiped: 电量低"
shot c6-banner-swiped

# halfway: the curtain's lower edge under the finger (a held pull: a background ftouch, the shot while it holds).
# The curtain coming down expires the two banners left: they are in the notification centre (c2) as expired
printf 'd 1 %s\ns 150\nd 0 1200 10\ns 40\nm 0 1200 120\ns 40\nm 0 1200 260\ns 40\nm 0 1200 420\ns 900\nu 0\ns 30\nu 1\n' "$HOLD_AT" | "$T/bin/ftouch" &
fp=$!
sleep 0.75
shot c0-pulling
wait $fp    # not a bare wait: that one would wait for KWin and the rest of the bed too
sleep 0.8

# right half: the controls
mark controls
wins
expect "y700-control-center/"
reject "y700-shellbar/@460,0+680x480"
shot c1-controls
# a tap on the empty curtain (left of the controls) closes it. The bed's holding finger is that tap itself (a
# short press on the same spot): the curtain's window-wide TapHandler tracks the first finger down and ignores a
# second one while the first is held, so a tap by the second finger is lost (10-22: one run in two)
HOLD_AT="300 700"; HOLD_MS=150
tap 300 700
sleep 0.8
mark closed
wins
reject "y700-control-center/"

# left half: the notification centre, newest first (the two banners the curtain expired are in it, greyed).
# The holding finger: on the app for the pull; on the empty right half, held long (a long press is no tap), for
# the swipe and the 「清除」 tap - those go to the card's and the button's own handlers
HOLD_AT="1500 900"; HOLD_MS=1000
pull 300 10 700 450
sleep 1
mark notes
wins
expect "y700-control-center/"
shot c2-notes
# swipe the top card away, then 「清除」 the rest
swipe 300 270 760 270 200
sleep 0.8
shot c3-swiped
tap 585 184
sleep 0.8
shot c4-cleared

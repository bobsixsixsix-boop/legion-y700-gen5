# sb-bed scenario: the shellbar's notification banners and the control centre's curtain (phase 2, 10-22).
#   SB_CC=/opt/y700-next/bin/y700-control-center sh ./sb-bed.sh curtain.sh /root/sb-curtain   (a control centre
#   not installed yet); plain `sh ./sb-bed.sh curtain.sh /root/sb-curtain` for the installed one.
# y700-shellbar is the notification server (the bed starts it first); the notification centre watches it.
# the shellbar registered org.freedesktop.Notifications at start (before any mark: the whole log)
sbexpect "notifications: serving"
app Kate '#3d7bf7'
sleep 1

# a lone notification is a banner at once (10-31): the window waited on notes.count, which libnotificationmanager
# signals before its outer layers have the row, so it read 0 and the banner came only with the next notification.
# Then it goes by itself (5 s), so the three below start from an empty screen as before
mark lone
notify "单条" "一条单独的通知也要马上出横幅" "测试"
sleep 0.7
sbexpect "banner + 单条"
wins
expect "y700-shellbar/@460,0+680x480"
sleep 5.5
sbexpect "banner expired: 单条"

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

# the curtain expires the banners waiting behind the three as well (10-31 审计 D1). Five in a row with the curtain
# away: three on screen, two waiting in the model; a waiting one has no clock (its card is gone), so whatever the
# timing, five are left when the curtain comes down. The old loop took rowCount() = 3 rows from the last up, each
# expired row let a waiting one in, and two came back as banners the moment the curtain went. The curtain over
# D-Bus (as tray.sh): no touches, so not the empty-curtain tap that now and then misses (README「偶尔不收」)
cc() { busctl --user call fyi.y700.ControlCenter /ControlCenter fyi.y700.ControlCenter "$@" >/dev/null 2>&1 || { echo "SBBED_EXPECT_FAIL: cc $*"; FAIL=1; }; }
cc hide
sleep 0.8
mark queued
notify "会议" "15:00 例会改到 3 楼" "日历"
notify "快递" "已放到驿站" "快递"
notify "备份" "相册已备份 12 张" "相册"
notify "日程" "明天 9:00 牙医" "日历"
notify "天气" "傍晚有雨，记得带伞" "天气"
sleep 0.5
sbexpect "banner + 天气"
cc showSide s left
sleep 0.8
mark queue-curtain
cc hide
sleep 0.8
sbreject "banner +"
wins
reject "y700-shellbar/@460,0+680x480"

# the control centre dies with the curtain open (10-31 审计 D2). openChanged(false) only comes from its hide(), so
# before, a crash (or a restart) left the shellbar's ccOpen true for good: no banner, no clock in the status bar, no
# pull strip over a fullscreen app. Now the shellbar takes the control centre's name changing hands as the curtain
# gone. kill -9: no hide() on the way out, as a crash. The bed's control centre by the PID behind its name on the
# bed's bus (a pkill would hit the owner's own one in the real session too); a new one started as the bed starts it
cc showSide s left
sleep 0.8
mark cc-died
wins
expect "y700-control-center/"
ccpid=$(busctl --user call org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus GetConnectionUnixProcessID s fyi.y700.ControlCenter 2>/dev/null)
ccpid=${ccpid#u }
case $ccpid in
    [1-9]*) kill -9 "$ccpid" ;;
    *) echo "SBBED_EXPECT_FAIL: no control centre on the bed's bus"; FAIL=1 ;;
esac
sleep 1
"$CC" >> "$LOG" 2>&1 &
sleep 3
mark cc-back
notify "控制中心重启" "帘子开着时它没了，横幅照样要出" "测试"
sleep 0.7
sbexpect "banner + 控制中心重启"
wins
expect "y700-shellbar/@460,0+680x480"

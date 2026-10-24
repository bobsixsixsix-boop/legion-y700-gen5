# sb-bed scenario: real-look.sh's cleanup path (10-22). A test notification revoked through the server leaves the
# shellbar's banners and every watcher's list: the server answers CloseNotification(id) with NotificationClosed(id, 3)
# on the bus, and libnotificationmanager's models drop a notification on any close reason but "expired" (an
# expired one stays as history: that is how three runs left a pile of 张三 / 电量低 in the notification centre).
# Checks: notify-send -p prints ids the server accepts; each id gets its NotificationClosed(id, 3); the banners
# are gone before they could expire (no "banner expired" for them). n3 is for eyes: the centre with no test card.
timeout 10 dbus-monitor --session "type=signal,interface=org.freedesktop.Notifications,member=NotificationClosed" > "$OUT/nc-mon.txt" 2>&1 &
mp=$!
sleep 1
mark revoke
IDS=$(notify-send -p -a Telegram "张三" "晚上吃火锅吗？"; sleep 0.3; notify-send -p -a "电源管理" "电量低" "剩余 15%")
echo "revoke ids: $(echo $IDS)" >> "$LOG"
[ -n "$IDS" ] || { echo "SBBED_FAIL: notify-send -p printed no ids"; FAIL=1; }
sleep 1.2
sbexpect "banner + 张三"
sbexpect "banner + 电量低"
shot n1-banners
for i in $IDS; do
    busctl --user call org.freedesktop.Notifications /org/freedesktop/Notifications org.freedesktop.Notifications CloseNotification u "$i" >> "$LOG" 2>&1 || { echo "SBBED_FAIL: CloseNotification $i"; FAIL=1; }
done
sleep 1
shot n2-revoked
wait $mp
for i in $IDS; do
    grep -A3 "member=NotificationClosed" "$OUT/nc-mon.txt" | grep -A1 "uint32 $i\$" | grep -q "uint32 3\$" || { echo "SBBED_FAIL: no NotificationClosed($i, 3) on the bus"; FAIL=1; }
done
# the banners' own timer is 5 s: past it, no expiry logged = the server's model had already dropped them
sleep 4.5
sbreject "banner expired: 张三"
sbreject "banner expired: 电量低"
# the notification centre after the revoke: no test card (and no count next to 通知)
pull 300 10 640 450
sleep 1
shot n3-centre

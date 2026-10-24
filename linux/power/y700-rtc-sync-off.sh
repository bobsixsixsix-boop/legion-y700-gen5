#!/bin/sh
# y700-rtc-sync-off.sh: stop the kernel from trying to write the (unwritable) PMIC RTC every time chrony adjusts
# the clock. Root, on the tablet. NOT run yet (2026-10-16): first confirm with
#   always-on-check.sh --rtc 90        -> rtc_set_time ... err=-19 lines every 20-30 s, no rtc_set_alarm
# Why (linux/power/ALWAYS-ON.md section 5b): CONFIG_RTC_SYSTOHC=y + chrony's "rtcsync" make the kernel call
# rtc_set_time() after every adjtimex(); rtc-pm8xxx has no nvmem offset cell and no allow-set-time on this board,
# so the write fails with -ENODEV, but rtc_set_time() still counts a wakeup event on rtc@6100 (61 in 25 min on
# the 22:47 audit). Zero power either way; this only removes noise from the wakeup accounting. fake-hwclock keeps
# the time across boots as before; the RTC never could be written, so nothing changes functionally.
# Undo: cp /etc/chrony/chrony.conf.y700bak /etc/chrony/chrony.conf && systemctl restart chrony
set -e
CONF=/etc/chrony/chrony.conf
grep -q '^[[:space:]]*rtcsync' "$CONF" || { echo "rtcsync not active in $CONF, nothing to do"; exit 0; }
[ -e "$CONF.y700bak" ] || cp -p "$CONF" "$CONF.y700bak"
sed -i 's/^\([[:space:]]*\)rtcsync\b/\1#rtcsync   # y700: the PMIC RTC cannot be written (no nvmem offset), see linux\/power\/ALWAYS-ON.md 5b/' "$CONF"
systemctl restart chrony
echo "chrony.conf: $(grep -n 'rtcsync' "$CONF")"
echo "chronyc: $(chronyc -n tracking 2>/dev/null | grep -E 'Leap status' || echo '(not answering yet)')"
echo RTC_SYNC_OFF_OK

#!/bin/sh
# y700-no-suspend.sh: the tablet never suspends - it idles with the screen off (design decision, 2026-10-15:
# no suspend; sit with the screen off and draw as little power as possible). Run as root on the tablet.
#   1. PowerDevil: "sleep after N min idle" -> do nothing, on AC / battery / low battery; the critical-battery
#      action becomes shut down (8) instead of sleep, so a forgotten tablet powers off cleanly at ~5 %.
#      (PowerDevil action codes: 0 nothing, 1 sleep, 2 hibernate, 8 shut down, 16 lock, 32 screen off.)
#   2. systemd: sleep/suspend/hibernate/hybrid-sleep targets masked - no program can suspend the tablet.
# Screen-off itself stays as configured (PowerDevil turns the screen off after its idle time; the power key
# toggles it). Undo: systemctl unmask sleep.target suspend.target hibernate.target hybrid-sleep.target;
# kwriteconfig6 ... AutoSuspendAction 1 (or the KDE settings page).
set -e
U="sudo -u user env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus"
for profile in AC Battery LowBattery; do
	$U kwriteconfig6 --file powerdevilrc --group $profile --group SuspendAndShutdown --key AutoSuspendAction 0
done
$U kwriteconfig6 --file powerdevilrc --group BatteryManagement --key BatteryCriticalAction 8
$U qdbus6 org.kde.Solid.PowerManagement /org/kde/Solid/PowerManagement org.kde.Solid.PowerManagement.refreshStatus >/dev/null 2>&1 || true
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target >/dev/null 2>&1
echo "powerdevil: $(grep -A3 '^\[Battery\]\[SuspendAndShutdown\]' /home/user/.config/powerdevilrc | tr '\n' ' ')"
echo "critical: $(grep -A2 '^\[BatteryManagement\]' /home/user/.config/powerdevilrc | tr '\n' ' ')"
echo "systemd: $(systemctl is-enabled sleep.target suspend.target 2>&1 | tr '\n' ' ')"
echo NO_SUSPEND_OK

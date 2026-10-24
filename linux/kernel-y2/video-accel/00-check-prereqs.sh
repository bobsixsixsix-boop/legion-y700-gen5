#!/bin/bash
# Confirm the device really has the Iris codec and that we know its shape.
set -u
echo "== kernel =="; uname -r
echo "== iris platform device =="
ls -d /sys/bus/platform/devices/*video-codec* 2>/dev/null || { echo "  NOT FOUND - is this an Iris device?"; exit 1; }
for d in /sys/bus/platform/devices/*video-codec*; do
  echo "  $d  driver=$(basename "$(readlink -f "$d/driver" 2>/dev/null)")  iommu_group_type=$(cat "$d/iommu_group/type" 2>/dev/null)"
done
echo "== v4l2 nodes =="
v4l2-ctl --list-devices 2>/dev/null | head -12
echo "== decoder capabilities =="
v4l2-ctl -d /dev/video0 --list-formats-out 2>/dev/null | grep -E "^\s+\[" || echo "  no coded formats"
echo "== encoder capabilities =="
v4l2-ctl -d /dev/video1 --list-formats 2>/dev/null | grep -E "^\s+\[" || echo "  no coded formats"

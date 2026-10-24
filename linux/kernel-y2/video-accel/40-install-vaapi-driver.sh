#!/bin/bash
# Make the backend findable by libva's default probing, system-wide.
set -eu
for n in v4l2_drv_video.so msm_drv_video.so; do
  SRC=$(find /usr/local/lib -name "$n" | head -1)
  [ -n "$SRC" ] && ln -sf "$SRC" "/usr/lib/$(gcc -dumpmachine)/dri/$n" && echo "  linked $n"
done
# 'msm_drv_video.so' is the name libva probes for Qualcomm parts, so plain
# vaInitialize() calls - Chrome included - find the backend with no configuration.
mkdir -p /etc/environment.d
cp "$(dirname "$0")/../configs/50-vaapi.conf" /etc/environment.d/50-vaapi.conf
sed 's/^\([A-Z_]*=\)\(.*\)/export \1\2/' /etc/environment.d/50-vaapi.conf > /etc/profile.d/vaapi.sh
echo "== verify with no environment help =="
env -u LIBVA_DRIVER_NAME -u LIBVA_DRIVERS_PATH vainfo --display drm --device /dev/dri/renderD128 2>&1 | grep -E 'Driver version|va_openDriver|Trying' | head -4

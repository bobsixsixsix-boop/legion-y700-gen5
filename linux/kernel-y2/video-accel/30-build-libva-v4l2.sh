#!/bin/bash
# Build and install the VA-API backend for Qualcomm Iris (stateful V4L2 M2M).
#
# The upstream mxsrc/libva-v4l2 is STATELESS ONLY - its README lists stateful
# support as future work.  Radxa's fork is the one written for Iris.
set -eu
cd /root
[ -d libva-v4l2 ] || git clone --depth 1 https://github.com/radxa-pkg/libva-v4l2.git
cd libva-v4l2
grep -qi 'Qualcomm Iris' README.md && echo "  README confirms: Qualcomm Iris, stateful M2M" || echo "  WARNING: unexpected README"
export PKG_CONFIG_PATH=/usr/local/lib/pkgconfig:${PKG_CONFIG_PATH:-}
rm -rf build
meson setup build
ninja -C build
ninja -C build install
ls -l /usr/local/lib/*/dri/*drv_video.so

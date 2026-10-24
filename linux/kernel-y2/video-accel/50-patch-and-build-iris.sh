#!/bin/bash
# Apply the kernel-side patches and rebuild the iris module.
# Usage: 50-patch-and-build-iris.sh /path/to/linux-source
set -eu
SRC=${1:?usage: $0 <kernel source dir>}
HERE=$(cd "$(dirname "$0")" && pwd)
cd "$SRC"
echo "== applying the iris patch (y700: rebased for the t47 tree, see ../upstream-patches/) =="
# reference copy from code002-2/sm8750-video-accel; its patches/clean/ is not shipped here. On the tablet
# the same change is part of the y2 kernel (../y700-y2.patch), so this step is only for a fresh tree.
patch -p1 --batch --fuzz=0 < "$HERE/../upstream-patches/iris-decode-order-deblock-t47.patch"
echo "== building the module =="
# match how the running kernel was built - check CONFIG_CC_IS_GCC in .config
if grep -q '^CONFIG_CC_IS_GCC=y' .config; then
  make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j"$(nproc)" M=drivers/media/platform/qcom/iris modules
else
  make ARCH=arm64 LLVM=1 -j"$(nproc)" M=drivers/media/platform/qcom/iris modules
fi
ls -l drivers/media/platform/qcom/iris/qcom-iris.ko
modinfo drivers/media/platform/qcom/iris/qcom-iris.ko | grep -E '^vermagic'

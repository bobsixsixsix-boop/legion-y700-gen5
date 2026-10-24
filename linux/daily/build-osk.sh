#!/bin/bash
exec > /root/build-osk.log 2>&1
set -ex
export DEBIAN_FRONTEND=noninteractive
apt-get install -y -q rustc cargo cmake pkg-config libxkbcommon-dev libwayland-dev libdbus-1-dev libfontconfig-dev libssl-dev libudev-dev
cd /usr/local/src/fcitx5-osk
cmake -B build -S . -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local
cmake --build build -j8
echo OSK_BUILD_OK

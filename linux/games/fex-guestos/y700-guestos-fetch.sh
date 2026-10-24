#!/bin/bash
# Download FEX's official ArchLinux x86 rootfs (the image ArmadaOS pins) and verify it.
exec > /root/y700-guestos-fetch.log 2>&1
set -ex
D=/usr/local/share/y700/guestos; mkdir -p $D
URL=https://rootfs.fex-emu.gg/ArchLinux/2026-08-11/ArchLinux.sqsh
SHA=5d0c1a38590c68e5c2597c2c8a26d2f80170b1b738c857d63e1cdadada5f5f2a
curl --fail --location --retry 5 --retry-delay 10 -C - -o $D/ArchLinux.sqsh.part "$URL" || curl --fail --location --retry 5 -o $D/ArchLinux.sqsh.part "$URL"
echo "$SHA  $D/ArchLinux.sqsh.part" | sha256sum -c -
mv $D/ArchLinux.sqsh.part $D/ArchLinux.sqsh
unsquashfs -cat $D/ArchLinux.sqsh graphics_provider.json | python3 -m json.tool
echo FETCH_OK

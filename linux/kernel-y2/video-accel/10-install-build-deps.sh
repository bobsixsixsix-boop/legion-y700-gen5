#!/bin/bash
# Build dependencies - and the graphical stack is protected first.
#
# WHY: libgbm-dev is a *Mesa* package.  On a device running vendor-patched Mesa
# (this one runs 26.1.6-...+piano1 for the Adreno 830), installing it DOWNGRADES
# libgbm1 and can take the GPU with it.  We hold the stack and get the gbm headers
# another way (see 20-provide-gbm-headers.sh).
set -eu
echo "== holding the graphics stack =="
for p in libgbm1 libegl1 libgles2 libgl1 libglx0 mesa-libgallium; do
  dpkg -l "$p" >/dev/null 2>&1 && { apt-mark hold "$p" >/dev/null && echo "  held $p"; }
done
echo "== installing only non-Mesa dev packages =="
apt-get install -y build-essential meson ninja-build pkg-config git \
    libva-dev libdrm-dev libegl-dev libgles-dev
echo "== verify =="
for c in g++ meson ninja pkg-config; do printf '  %-12s %s\n' "$c" "$(command -v $c || echo MISSING)"; done
for p in libva libdrm egl glesv2; do printf '  %-12s %s\n' "$p" "$(pkg-config --modversion $p 2>/dev/null || echo MISSING)"; done
echo "== GPU still the vendor build? =="
dpkg -l libgbm1 mesa-libgallium 2>/dev/null | awk '/^ii/{printf "  %-18s %s\n",$2,$3}'

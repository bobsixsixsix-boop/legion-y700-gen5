#!/bin/bash
# Supply the gbm headers and the link-time symlink WITHOUT installing libgbm-dev.
#
# libgbm-dev is a Mesa package: it depends on an exact libgbm1, so on a device with
# vendor-patched Mesa it downgrades the graphics stack.  All we actually need from it
# is headers plus the libgbm.so -> libgbm.so.1 symlink, so take those by hand.
set -eu

if pkg-config --exists gbm 2>/dev/null; then
  echo "gbm is already visible: $(pkg-config --modversion gbm)"
  exit 0
fi

cd /root
apt-get download libgbm-dev
rm -rf /root/gbm-dev && mkdir -p /root/gbm-dev
dpkg-deb -x libgbm-dev_*.deb /root/gbm-dev

mkdir -p /usr/local/include /usr/local/lib/pkgconfig
cp -a /root/gbm-dev/usr/include/. /usr/local/include/

LIBDIR=$(dirname "$(readlink -f /usr/lib/*/libgbm.so.1 | head -1)")
PC=$(find /root/gbm-dev -name gbm.pc | head -1)
[ -n "$PC" ] || { echo "no gbm.pc in the package" >&2; exit 1; }
sed -e 's|^prefix=.*|prefix=/usr/local|' \
    -e "s|^libdir=.*|libdir=$LIBDIR|" \
    -e 's|^includedir=.*|includedir=/usr/local/include|' \
    "$PC" > /usr/local/lib/pkgconfig/gbm.pc
echo "wrote /usr/local/lib/pkgconfig/gbm.pc (libdir=$LIBDIR)"

# the linker looks for libgbm.so, which only the -dev package normally provides
TARGET=$(basename "$(readlink -f "$LIBDIR"/libgbm.so.1)")
ln -sf "$TARGET" "$LIBDIR/libgbm.so"
echo "linked $LIBDIR/libgbm.so -> $TARGET"

PKG_CONFIG_PATH=/usr/local/lib/pkgconfig pkg-config --modversion gbm

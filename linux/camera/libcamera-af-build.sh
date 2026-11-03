#!/bin/bash
# Build Ubuntu's libcamera 0.7.0-1ubuntu2 plus linux/camera/patches/y700-000[1-5] (rear-camera autofocus + VCM power
# leak fix) as 0.7.0-1ubuntu2+y700.1 .debs: ROOT on the tablet, as a transient unit so the desktop stays usable:
#   systemd-run --unit=y700-libcamera-build --collect -p Nice=19 -p CPUWeight=20 -p IOWeight=20 /root/libcamera-af-build.sh
#   journalctl -fu y700-libcamera-build          (also logged to /root/libcamera-y700/build-<stamp>.log)
# Installs no libcamera package: libcamera-af-install.sh --install does that from the .debs this leaves behind.
# Files: /root/libcamera-y700/ (D below) holds the downloads, the unpacked tree, the .debs and the logs;
#   the patches are read from $D/patches/ (= linux/camera/patches/; LIBCAMERA_Y700_PATCHES=dir overrides).
# Steps (any failure aborts; the installed libcamera is never touched, see the trap):
#   1. apt-get update; dpkg-dev if dpkg-source is missing. Download the .dsc, .debian.tar.xz and .orig.tar.gz from
#      ports.ubuntu.com into $D (a cached file is reused when its sha256 matches) and verify the sha256 values pinned
#      below. The two tarball values are the ones Ubuntu's .dsc lists; the .dsc value was computed from the copy the
#      patches were prepared against. dpkg-source -x checks the tarballs against the .dsc once more; it checks the
#      .dsc's PGP signature only if a keyring with the Ubuntu key is installed (a warning otherwise, not an error).
#   2. A fresh dpkg-source -x into $D/libcamera-0.7.0 (a tree left by an earlier run is deleted first: everything in
#      it is generated). Copy the five y700-*.patch into debian/patches, append them to series, prepend the
#      0.7.0-1ubuntu2+y700.1 changelog entry (printf, no dch; date -R; distribution copied from the top entry), then
#      dpkg-source --before-build applies them with dpkg-source's own patch options (fuzz 0). A patch that does not
#      apply fails here, before anything is installed.
#   3. Build-Depends: apt-get build-dep --arch-only --no-install-recommends on the unpacked tree (apt resolves the
#      [arm64] and <!nocheck> qualifiers itself; Build-Depends-Indep, the doxygen/sphinx docs, is skipped). Every
#      package that steps 1 and 3 newly install is appended to $D/builddeps-installed.txt, for a later
#        apt-get purge --simulate $(cat /root/libcamera-y700/builddeps-installed.txt)     (check what else would go)
#        apt-get purge $(cat /root/libcamera-y700/builddeps-installed.txt) && apt-get autoremove --purge
#   4. dpkg-buildpackage -B -uc -us with DEB_BUILD_OPTIONS="nocheck parallel=N": N = nproc, capped at one job per
#      1.5 GB of MemAvailable (LIBCAMERA_Y700_JOBS=N overrides). Then a sanity check that libcamera.so.0.7 of the new
#      libcamera0.7 .deb carries strings of patches 0001 and 0005.
# Build profiles: debian/rules passes -Dpycamera=enabled -Dqcam=enabled -Dgstreamer=enabled -Dtest=true
#   unconditionally, so the pkg.libcamera.{nopython,noqt,nosdl,notrace} profiles only drop Build-Depends and would
#   break or silently change the build, and the nocheck PROFILE drops libgtest-dev, which lc-compliance (shipped in
#   libcamera-tools) needs. So no profile is used: nocheck is only a DEB_BUILD_OPTIONS (dh_auto_test does nothing)
#   and libgtest-dev gets installed.
# Output: the seven arch:arm64 .debs (libcamera0.7 libcamera-ipa libcamera-tools libcamera-v4l2 gstreamer1.0-libcamera
#   libcamera-dev python3-libcamera; -dbgsym .ddebs too) in $D. The IPA modules are signed with a key generated
#   per build and the public half is compiled into libcamera0.7; patch 0002 also changes the statistics layout the
#   two share. Install libcamera0.7 and libcamera-ipa from the same build together: the install script does.
# A re-run starts again from step 2 (downloads and the builddeps record are kept) and overwrites the .debs.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive LC_ALL=C.UTF-8
unset DEB_BUILD_PROFILES DEB_BUILD_OPTIONS
UP=0.7.0; VER=$UP-1ubuntu2; NEW=$VER+y700.1
POOL=https://ports.ubuntu.com/ubuntu-ports/pool/main/libc/libcamera
D=/root/libcamera-y700; SRC=$D/libcamera-$UP
PD=${LIBCAMERA_Y700_PATCHES:-$D/patches}
LIST=$D/builddeps-installed.txt
MAINT='bobsixsixsix-boop <304558835+bobsixsixsix-boop@users.noreply.github.com>'
declare -A SHA=(
	[libcamera_$VER.dsc]=27a10011fd5efe43564e94bb0328342ec11441963bed37db10a2d524553a02d8
	[libcamera_$VER.debian.tar.xz]=0ee3195d74ad85b089c62eb7b2904023f8556544b2d9dbcc67aa834ddde5a09e
	[libcamera_$UP.orig.tar.gz]=ebd90a3aa2ca87a39323ffb7a4f5bbf72090b43a2431133759620b63e982db87
)
PKGS=(libcamera0.7 libcamera-ipa libcamera-tools libcamera-v4l2 gstreamer1.0-libcamera libcamera-dev python3-libcamera)
APT=(apt-get -q -o DPkg::Lock::Timeout=600)
phase=preflight; BEFORE=

[ "$(id -u)" -eq 0 ] || { echo "run as root"; exit 1; }
mkdir -p "$D"
stamp=$(date +%Y%m%d-%H%M%S); LOG=$D/build-$stamp.log
exec > >(tee -a "$LOG") 2>&1

finish() {
	local rc=$?
	[ -n "$BEFORE" ] && record_new >/dev/null || true
	[ -n "$BEFORE" ] && rm -f "$BEFORE"
	[ $rc -eq 0 ] && return
	echo "FAILED (rc $rc) in step '$phase'. No libcamera package was installed or changed." \
		"Build dependencies installed so far: $LIST. Log: $LOG"
}
trap finish EXIT

# installed packages, one "name" or "name:arch" per line, sorted for comm
installed() {
	dpkg-query -W -f='${Status}\t${binary:Package}\n' | awk -F'\t' '$1 == "install ok installed" { print $2 }' | sort -u
}
# append what was installed since $BEFORE to $LIST (kept sorted and unique across runs)
record_new() {
	local new
	new=$(comm -13 "$BEFORE" <(installed))
	[ -n "$new" ] || return 0
	{ [ -f "$LIST" ] && cat "$LIST"; printf '%s\n' "$new"; } | sort -u > "$LIST.tmp"
	mv "$LIST.tmp" "$LIST"
	echo "newly installed (recorded in $LIST): $(echo $new)"
}

# ---- preflight
[ "$(dpkg --print-architecture)" = arm64 ] || { echo "expected an arm64 system"; exit 1; }
mapfile -t PATCHES < <(ls "$PD"/y700-*.patch 2>/dev/null | sort)
[ ${#PATCHES[@]} -eq 5 ] || { echo "expected the 5 y700-000[1-5]*.patch in $PD (copy linux/camera/patches/ there), found ${#PATCHES[@]}"; exit 1; }
avail=$(df --output=avail -k "$D" | tail -1 | tr -d " ")
[ "$avail" -ge $((4 * 1024 * 1024)) ] || { echo "less than 4 GB free under $D"; exit 1; }
inst=$(dpkg-query -W -f='${Version}' libcamera0.7 2>/dev/null || true)
echo "installed libcamera0.7: ${inst:-none}; building $NEW"
if [ -n "$inst" ] && [[ $inst != "$VER" && $inst != "$VER"+y700.* ]]; then
	echo "WARNING: the installed libcamera0.7 is $inst, not $VER: Ubuntu moved on. This build is still based on $VER;"
	echo "  libcamera-af-install.sh refuses to downgrade. Rebase the patches onto the new version first (README checklist)."
fi

# ---- 1. tools and sources
phase=download
BEFORE=$(mktemp); installed > "$BEFORE"
"${APT[@]}" update
command -v dpkg-source >/dev/null || "${APT[@]}" install -y --no-install-recommends dpkg-dev
fetch() {
	local f=$1
	if [ -f "$D/$f" ] && echo "${SHA[$f]}  $D/$f" | sha256sum -c --status -; then echo "cached: $f"; return; fi
	rm -f "$D/$f.part"
	if command -v curl >/dev/null; then curl -fsSL --retry 3 -o "$D/$f.part" "$POOL/$f"
	else wget -q --tries=3 -O "$D/$f.part" "$POOL/$f"; fi
	echo "${SHA[$f]}  $D/$f.part" | sha256sum -c --status - || {
		echo "sha256 mismatch for $f: got $(sha256sum "$D/$f.part" | cut -d' ' -f1), expected ${SHA[$f]}"; exit 1; }
	mv "$D/$f.part" "$D/$f"
	echo "fetched and verified: $f"
}
for f in "${!SHA[@]}"; do fetch "$f"; done

# ---- 2. unpack, add the patches and the changelog entry, apply
phase=unpack
rm -rf "$SRC"
(cd "$D" && dpkg-source -x "libcamera_$VER.dsc" "$SRC")
S=$SRC/debian/patches/series
[ -z "$(tail -c1 "$S")" ] || echo >> "$S"
for p in "${PATCHES[@]}"; do
	cp "$p" "$SRC/debian/patches/"
	echo "${p##*/}" >> "$S"
done
dist=$(dpkg-parsechangelog -l "$SRC/debian/changelog" -S Distribution)
{
	printf 'libcamera (%s) %s; urgency=medium\n\n' "$NEW" "$dist"
	printf '  * Local build for the Lenovo Legion Y700 Gen 5 (TB323FU), not for upload.\n'
	printf '  * d/p/y700-0001..0004: simple pipeline manual focus, software ISP focus\n'
	printf '    metric and contrast-detect autofocus (iceland-mainline 990a0597:\n'
	printf '    Osilvfe, mzak), regenerated or ported for 0.7.0.\n'
	printf '  * d/p/y700-0005: open the lens subdev only while the camera streams, so\n'
	printf '    the rear VCM (dw9719/GT9764) powers down when the camera is idle.\n'
	printf '\n -- %s  %s\n\n' "$MAINT" "$(date -R)"
	cat "$SRC/debian/changelog"
} > "$SRC/debian/changelog.y700"
mv "$SRC/debian/changelog.y700" "$SRC/debian/changelog"
w=$(dpkg-parsechangelog -l "$SRC/debian/changelog" 2>&1 >/dev/null || true)
[ -z "$w" ] || { echo "dpkg-parsechangelog complains about the new entry: $w"; exit 1; }
[ "$(dpkg-parsechangelog -l "$SRC/debian/changelog" -S Version)" = "$NEW" ] || { echo "changelog version is not $NEW"; exit 1; }
[ "$(dpkg-parsechangelog -l "$SRC/debian/changelog" -o 1 -c 1 -S Version)" = "$VER" ] || { echo "second changelog entry is not $VER"; exit 1; }
phase=patch
dpkg-source --before-build "$SRC"
for p in "${PATCHES[@]}"; do
	grep -qxF "${p##*/}" "$SRC/.pc/applied-patches" || { echo "${p##*/} is not applied (.pc/applied-patches)"; exit 1; }
done
grep -q 'FocusAbsolute' "$SRC/src/libcamera/control_ids_draft.yaml" || { echo "patch 0001 content missing from the tree"; exit 1; }
grep -q 'focusLens_->close()' "$SRC/src/libcamera/pipeline/simple/simple.cpp" || { echo "patch 0005 content missing from the tree"; exit 1; }
echo "patches applied: $(tail -n 5 "$SRC/.pc/applied-patches" | tr '\n' ' ')"

# ---- 3. build dependencies
phase=build-dep
"${APT[@]}" build-dep -y --arch-only --no-install-recommends "$SRC"
record_new

# ---- 4. build
phase=build
memjobs=$(awk '/^MemAvailable:/ { print int($2 / 1572864) }' /proc/meminfo)
njobs=$(nproc); [ "$memjobs" -lt "$njobs" ] && njobs=$memjobs; [ "$njobs" -ge 1 ] || njobs=1
njobs=${LIBCAMERA_Y700_JOBS:-$njobs}
rm -f "$D"/*_"$NEW"_*.deb "$D"/*_"$NEW"_*.ddeb "$D"/libcamera_"$NEW"_*.buildinfo "$D"/libcamera_"$NEW"_*.changes
echo "dpkg-buildpackage -B -uc -us, DEB_BUILD_OPTIONS=\"nocheck parallel=$njobs\" ($(date))"
(cd "$SRC" && DEB_BUILD_OPTIONS="nocheck parallel=$njobs" dpkg-buildpackage -B -uc -us)
echo "build finished ($(date))"

# ---- 5. what came out
phase=verify
debs=()
for p in "${PKGS[@]}"; do
	f=$D/${p}_${NEW}_arm64.deb
	[ -f "$f" ] || { echo "missing $f"; exit 1; }
	[ "$(dpkg-deb -f "$f" Version)" = "$NEW" ] || { echo "$f is not version $NEW"; exit 1; }
	debs+=("$f")
done
X=$(mktemp -d)
dpkg-deb -x "$D/libcamera0.7_${NEW}_arm64.deb" "$X"
so=$(ls "$X"/usr/lib/aarch64-linux-gnu/libcamera.so.0.7.* | head -1)
grep -q -a 'FocusAbsolute' "$so" || { rm -rf "$X"; echo "$so lacks the FocusAbsolute control (patch 0001)"; exit 1; }
grep -q -a 'Failed to open the focus lens' "$so" || { rm -rf "$X"; echo "$so lacks patch 0005's message"; exit 1; }
rm -rf "$X"
echo "OK: libcamera $NEW built (patches: ${PATCHES[*]##*/})"
printf '  %s\n' "${debs[@]}"
echo "next: /root/libcamera-af-install.sh --install"

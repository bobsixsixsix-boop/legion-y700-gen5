#!/bin/bash
# Update libva-v4l2 (radxa-pkg, the VA-API backend Chrome/mpv/wiliwili/haruna use for Iris) to a REVIEWED upstream
# commit: ROOT on the tablet.   bash libva-v4l2-update.sh <commit>        e.g. 6d03c3f
# ("origin/master" is accepted too, but then it installs whatever upstream pushed last, unreviewed.)
# Local patches: every /root/libva-v4l2-patches/*.patch (= linux/video/libva-v4l2-patches/) is applied on top of <commit>.
# Env: LIBVA_EXPECT_ERRTS=0|1  does the running kernel carry radxa patches/0004 (iris keeps the timestamp on error
#        buffers; ours is 1051, from y14 on)? Default: 0 on kernels whose release ends in -yN with N <= 13, else 1.
#      LIBVA_UPDATE_FORCE=1    run although a process holds the Iris decoder/encoder (video nodes named qcom-iris*).
#      LIBVA_LOCAL_PATCHES=dir local patch directory (default /root/libva-v4l2-patches; empty = pure upstream).
# <commit> already installed (marker below = HEAD and its sha256 = the installed file = the fresh build): validation
# run - steps 1-3 as usual, then "already installed, nothing to do": no backup, no install.
# Nothing is installed until every check passed; any failure before that aborts with the installed driver untouched:
#   1. fetch, fast-forward /usr/local/src/libva-v4l2 to <commit> (forward only), print any change under patches/
#      (= kernel work: radxa 0001-0003 are our 00y1 / y2 iris patch, 0004 is our 1051); then git am the local patches
#      in name order on a DETACHED HEAD: branch master only ever holds upstream commits, so the next run fast-forwards
#      as before. Fixed committer + committer date = author date: the same <commit> and patches give the same commit id,
#      so the marker / validation-run logic below works unchanged. A patch that no longer applies (upstream changed that
#      code or merged it) aborts here: delete it from linux/video/libva-v4l2-patches/ if upstream merged it, else rebase.
#   2. meson reconfigure with -Dgpu_copy=enabled (fail instead of silently falling back to CPU surface copies,
#      upstream 13649f6; buildtype is left as configured - the tablet's build dir is buildtype=debug), build with nice,
#      assert the driver links libEGL
#   3. against the UNINSTALLED build, as the desktop user: upstream's board tests decoder/main10, decoder/prime-import,
#      decoder/error-recovery.py (injected OUTPUT/CAPTURE errors -> neutral gray frames, PRIME1/PRIME2/export storage,
#      failure paths, and a real truncated HEVC stream); vainfo (no profile/entrypoint may disappear compared with the
#      installed driver); /root/vaapi-check.sh (H.264, HEVC 8/10-bit, VP9 p0/p2 and their show_existing_frame
#      variants: every frame in hardware, frame-exact against libavcodec's software decode, no
#      iris-vaapi:/error/fail/timeout/damaged line - a gray-frame substitution counts as a failure there);
#      /root/vp9-hidden-check.sh (= linux/video/vp9-hidden-check.sh: hidden VP9 frames with injected error buffers,
#      a picture that never comes, persistent exports and a really damaged alt-ref; upstream's tests cover only HEVC).
#      error-recovery's "-truncated" cases can only pass with the kernel patch above: when LIBVA_EXPECT_ERRTS is 0 they
#      are XFAIL only with the known y13 signature (an AssertionError and "surface sync timeout" in the case's log;
#      reported, not fatal; an unexpected pass prints XPASS) - a subprocess timeout or any other failure is still a
#      FAIL; when it is 1 the upstream test runs unmodified and a failing truncated case is a real FAIL.
#   4. back up the installed driver to /root/v4l2_drv_video.so.bak-<stamp>-<its commit>, install, record commit + sha256
#      in /root/libva-v4l2.installed, then vainfo (must equal the build's) and vaapi-check.sh on the installed driver.
#      (The installed commit comes from that marker while its sha256 matches; without it, from HEAD only when build/
#      is up to date and byte-identical to the installed file; else the backup is named ...-unknown.)
# Rollback: cp -a --remove-destination /root/v4l2_drv_video.so.bak-<...> /usr/local/lib/aarch64-linux-gnu/dri/v4l2_drv_video.so
#   (--remove-destination: a plain cp rewrites the file in place under players that have it mapped)
#   Source tree: a run with local patches leaves HEAD detached on them; git -C /usr/local/src/libva-v4l2 checkout master
#   before any manual git reset there (this script does that checkout itself). A run killed in the middle of git am
#   leaves .git/rebase-apply behind: the next run aborts that am first and says so.
# Upstream registers no meson test() targets, so "meson test" (the previous version's test step) ran nothing.
set -euo pipefail
[ $# -eq 1 ] || { sed -n '2,11p' "$0"; exit 2; }
T=$1
unset LIBVA_DRIVER_NAME LIBVA_DRIVERS_PATH
S=/usr/local/src/libva-v4l2; SO=/usr/local/lib/aarch64-linux-gnu/dri/v4l2_drv_video.so
MARK=/root/libva-v4l2.installed; VC=/root/vaapi-check.sh; VH=/root/vp9-hidden-check.sh; DEV=/dev/dri/renderD128
LP=${LIBVA_LOCAL_PATCHES-/root/libva-v4l2-patches}
stamp=$(date +%Y%m%d-%H%M%S); W=/tmp/libva-test-$stamp
U=(runuser -u user -- env XDG_RUNTIME_DIR=/run/user/1000)
B=(LIBVA_DRIVER_NAME=v4l2 LIBVA_DRIVERS_PATH=$S/build)    # env selecting the uninstalled build
phase=check; old=; BAK=
finish() {
	local rc=$?
	[ $rc -eq 0 ] && return
	if [ $phase = check ]; then
		echo "ABORTED (rc $rc) before install: the installed driver is unchanged. Source tree now at" \
			"$(git -C $S log --oneline -1 2>/dev/null) (was ${old:-?}). Logs: $W"
	else
		echo "FAILED (rc $rc) AFTER install. Roll back: cp -a --remove-destination $BAK $SO   Logs: $W"
	fi
}
trap finish EXIT
mkdir -p $W/t

# ---- preflight
[ -r $VC ] || { echo "missing $VC (copy linux/kernel-y7/vaapi-check.sh there)"; exit 1; }
[ -r $VH ] || { echo "missing $VH (copy linux/video/vp9-hidden-check.sh there)"; exit 1; }
# the Iris nodes by name: the same /dev/video* number space holds 17 camss nodes, the probe order may change
iris=()
for d in /sys/class/video4linux/video*; do
	if [[ "$(cat $d/name 2>/dev/null)" == qcom-iris* ]]; then iris+=(/dev/${d##*/}); fi
done
[ ${#iris[@]} -gt 0 ] || { echo "no Iris video node (/sys/class/video4linux/video*/name qcom-iris*): is qcom_iris loaded?"; exit 1; }
echo "Iris nodes: ${iris[*]}"
if fuser -s "${iris[@]}" 2>/dev/null; then
	fuser -v "${iris[@]}" || true
	[ "${LIBVA_UPDATE_FORCE:-0}" = 1 ] || { echo "the Iris decoder/encoder is in use (above): close the player first, or LIBVA_UPDATE_FORCE=1"; exit 1; }
fi
kr=$(uname -r)
if [ -n "${LIBVA_EXPECT_ERRTS:-}" ]; then errts=$LIBVA_EXPECT_ERRTS; why="LIBVA_EXPECT_ERRTS=$errts"
elif [[ $kr =~ -y([0-9]+)$ ]] && [ "${BASH_REMATCH[1]}" -le 13 ]; then errts=0; why="$kr is y13 or older"
else errts=1; why="$kr is not a y13-or-older release"; fi
case $errts in 0|1) ;; *) echo "LIBVA_EXPECT_ERRTS must be 0 or 1"; exit 2 ;; esac
echo "kernel error-timestamp patch expected: $errts ($why)"

# ---- 1. source
cd $S
old=$(git rev-parse --short HEAD)
cur=$(sha256sum $SO | cut -d' ' -f1)
# commit of the installed driver: our marker while its sha256 matches, else HEAD when build/ is up to date with HEAD
# and byte-identical to the installed file (a run that aborted after the fast-forward leaves a stale build/ behind)
prev=unknown
if [ -r $MARK ] && [ "$(cut -d' ' -f2 $MARK)" = "$cur" ]; then prev=$(cut -c1-7 $MARK)
elif cmp -s build/v4l2_drv_video.so $SO && [ "$(ninja -C build -n 2>/dev/null | tail -1)" = "ninja: no work to do." ]; then prev=$old; fi
# root may have no git identity (am and am --abort need one); a fixed one also keeps local commit ids reproducible
GL=(git -c user.name=y700-local -c user.email=root@localhost -c commit.gpgsign=false)
if [ -d .git/rebase-apply ]; then echo "leftover git am in $S (an earlier run was killed): aborting it"; "${GL[@]}" am --abort || true; fi
# a previous run with local patches left HEAD detached on them: back to the upstream-only branch
git symbolic-ref -q HEAD >/dev/null || git checkout -q master
git fetch -q origin
git rev-parse -q --verify "$T^{commit}" >/dev/null || { echo "unknown commit: $T"; exit 1; }
git merge-base --is-ancestor "$T" origin/master || echo "WARNING: $T is not on origin/master"
echo "installed driver: $prev    source before: $(git log --oneline -1)"
git merge -q --ff-only "$T"
[ "$(git rev-parse HEAD)" = "$(git rev-parse "$T^{commit}")" ] || { echo "HEAD is not $T (older than HEAD? this script only moves forward)"; exit 1; }
echo "source after: $(git log --oneline -1)"
base=$old; [ $prev = unknown ] || base=$prev
if ! git cat-file -e "$base^{commit}" 2>/dev/null; then echo "WARNING: $base is gone from the tree, cannot compare patches/"
elif [ -n "$(git diff --name-only "$base" HEAD -- patches/)" ]; then
	echo "!!! KERNEL PATCHES CHANGED upstream ($base..HEAD): port them to our kernel; the new code runs without them until then"
	git diff --stat "$base" HEAD -- patches/ | sed 's/^/!!!   /'
fi
up=$(git rev-parse --short HEAD); nlp=0
if [ -n "$LP" ] && compgen -G "$LP/*.patch" >/dev/null; then
	git checkout -q --detach
	for p in "$LP"/*.patch; do
		if ! "${GL[@]}" am -q --committer-date-is-author-date "$p" >$W/am.log 2>&1; then
			cat $W/am.log; "${GL[@]}" am --abort || true; git checkout -q master
			echo "FAIL  local patch ${p##*/} does not apply on $up: upstream merged it (delete it from linux/video/libva-v4l2-patches/ and $LP) or changed that code (rebase it)"
			exit 1
		fi
		nlp=$((nlp + 1)); echo "local patch: $(git log --oneline -1)"
	done
fi
echo "building: $(git rev-parse --short HEAD) = upstream $up + $nlp local patch(es)"

# ---- 2. configure + build
if grep -q "'gpu_copy'" meson_options.txt; then
	# twice: meson 1.10 rejects -D for an option the build dir has not seen yet ("Unknown option"), the first run adds it
	{ meson setup --reconfigure build && meson setup --reconfigure build -Dgpu_copy=enabled; } >$W/meson-setup.log 2>&1 \
		|| { tail -20 $W/meson-setup.log; echo "FAIL  meson setup -Dgpu_copy=enabled (EGL / GLES 3.2 / GBM dev packages?)"; exit 1; }
fi
meson introspect build --buildoptions >$W/options.json
opts=$(python3 -I -c 'import json,sys; o={x["name"]: x["value"] for x in json.load(open(sys.argv[1]))}; print("buildtype=%s gpu_copy=%s fastcv=%s prefix=%s" % (o["buildtype"], o.get("gpu_copy", "-"), o["fastcv"], o["prefix"]))' $W/options.json)
echo "options: $opts"
nice -n 10 ninja -C build >$W/ninja.log 2>&1 || { tail -30 $W/ninja.log; echo "FAIL  build"; exit 1; }
tail -1 $W/ninja.log
ldd build/v4l2_drv_video.so >$W/ldd-build.log
grep -q libEGL $W/ldd-build.log || { echo "FAIL  build/v4l2_drv_video.so does not link libEGL (GPU copy compiled out)"; exit 1; }
echo "PASS  build links libEGL"
# validation mode: the target is what is installed (marker commit = HEAD, marker sha256 = installed file = this build)
built=$(sha256sum build/v4l2_drv_video.so | cut -d' ' -f1); already=0
if [ -r $MARK ] && [ "$(cut -d' ' -f1 $MARK)" = "$(git rev-parse HEAD)" ] && [ "$(cut -d' ' -f2 $MARK)" = "$built" ] \
	&& [ "$cur" = "$built" ]; then
	already=1; echo "target $(git rev-parse --short HEAD) is already installed (sha256 ${built:0:16}... per $MARK): validation run, nothing will be installed"
fi

# ---- 3. checks against the uninstalled build (nothing installed yet)
for f in main10.cpp prime-import.cpp error-completion.c surface-storage.cpp error-recovery.py; do
	[ -f tests/decoder/$f ] || { echo "tests/decoder/$f is gone upstream: update this script"; exit 1; }
	cp tests/decoder/$f $W/t/
done
if [ $errts = 0 ]; then
	python3 -I - "$W/t/error-recovery.py" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1]); s = p.read_text()
old = """            images, log = decode(label + '-truncated', corrupt, depth)
            assert gray in images and 'replaced damaged picture' in log
            print(f'PASS {label}-truncated: {frames} frames, firmware error recovered', flush=True)
"""
new = """            try:
                images, log = decode(label + '-truncated', corrupt, depth)
                assert gray in images and 'replaced damaged picture' in log
            except AssertionError:
                # only the known y13 signature (decode() wrote the case log before asserting): the corrupt picture's
                # error buffer comes back with timestamp 0, so its surface waits for the 5 s sync timeout. A subprocess
                # timeout (hang >= 30 s) or any other failure propagates and is a real FAIL.
                case_log = root / f'{label}-truncated.log'
                if not (case_log.is_file() and 'surface sync timeout' in case_log.read_text(errors='replace')):
                    raise
                print(f'XFAIL {label}-truncated: real corrupt stream not recovered (AssertionError, surface sync timeout), expected on a kernel without the iris error-timestamp patch', flush=True)
            else:
                print(f'XPASS {label}-truncated: recovered although the kernel is assumed to lack the error-timestamp patch', flush=True)
"""
assert s.count(old) == 1, "error-recovery.py changed upstream: re-check the -truncated XFAIL wrapper in libva-v4l2-update.sh"
p.write_text(s.replace(old, new))
PY
fi
(cd $W/t && nice -n 10 c++ -std=c++17 main10.cpp -lva -lva-drm -o main10 && nice -n 10 c++ -std=c++17 prime-import.cpp -lva -lva-drm -o prime-import)
chown -R user: $W
run() {   # run <name> <cmd...>: as the desktop user against build/, log to $W/<name>.log, abort on failure
	local n=$1; shift
	if "${U[@]}" "${B[@]}" timeout 900 "$@" >$W/$n.log 2>&1; then echo "PASS  $n"
	else tail -30 $W/$n.log; echo "FAIL  $n (log $W/$n.log)"; exit 1; fi
}
run main10 $W/t/main10
run prime-import $W/t/prime-import
run error-recovery python3 -I $W/t/error-recovery.py $W/out --driver-dir $S/build
echo "      $(grep -c '^PASS' $W/error-recovery.log || true) PASS, $(grep -c '^XFAIL' $W/error-recovery.log || true) XFAIL," \
	"$(grep -c '^XPASS' $W/error-recovery.log || true) XPASS (case logs in $W/out)"
grep -E '^X(FAIL|PASS)' $W/error-recovery.log | sed 's/^/      /' || true

profiles() {   # profiles [env assignments...]: sorted "VAProfileX:VAEntrypointY" lines from vainfo as the desktop user
	"${U[@]}" "$@" vainfo --display drm --device $DEV 2>&1 | grep -E '^[[:space:]]*VAProfile' | tr -d ' \t' | sort || true
}
profiles >$W/vainfo-installed.txt
profiles "${B[@]}" >$W/vainfo-build.txt
[ -s $W/vainfo-build.txt ] || { echo "FAIL  vainfo lists nothing with the new build"; exit 1; }
gone=$(comm -23 $W/vainfo-installed.txt $W/vainfo-build.txt); new=$(comm -13 $W/vainfo-installed.txt $W/vainfo-build.txt)
[ -z "$new" ] || echo "      vainfo, new in the build: $(echo $new)"
[ -z "$gone" ] || { echo "FAIL  vainfo: the new build drops $(echo $gone)"; exit 1; }
echo "PASS  vainfo ($(wc -l <$W/vainfo-build.txt) profile/entrypoint pairs, none lost)"
if env "${B[@]}" bash $VC >$W/vaapi-check-build.log 2>&1; then echo "PASS  vaapi-check (build)"; sed 's/^/      /' $W/vaapi-check-build.log
else cat $W/vaapi-check-build.log; echo "FAIL  vaapi-check (build)"; exit 1; fi
if LIBVA_EXPECT_ERRTS=$errts bash $VH $S/build >$W/vp9-hidden-build.log 2>&1; then echo "PASS  vp9-hidden-check (build)"
	sed 's/^/      /' $W/vp9-hidden-build.log
else cat $W/vp9-hidden-build.log; echo "FAIL  vp9-hidden-check (build)"; exit 1; fi
if [ $already = 1 ]; then
	echo "DONE  already installed, nothing to do: $(git log --oneline -1) ($opts) passed every pre-install check;" \
		"no backup, no install. Logs in $W (tmpfs, gone at reboot)"
	exit 0
fi

# ---- 4. install
BAK=/root/v4l2_drv_video.so.bak-$stamp-$prev
cp -a $SO $BAK
phase=installed
ninja -C build install >$W/install.log 2>&1 || { tail -20 $W/install.log; echo "FAIL  ninja install"; exit 1; }
ls -la $SO /usr/lib/aarch64-linux-gnu/dri/msm_drv_video.so
echo "backup of the previous driver ($prev): $BAK"
echo "$(git rev-parse HEAD) $(sha256sum $SO | cut -d' ' -f1) $stamp $opts upstream=$up local=$nlp" >$MARK
ldd $SO >$W/ldd-installed.log
grep -q libEGL $W/ldd-installed.log || { echo "FAIL  installed driver does not link libEGL"; exit 1; }
"${U[@]}" vainfo --display drm --device $DEV 2>&1 | grep 'Driver version' || true
profiles >$W/vainfo-after.txt
cmp -s $W/vainfo-build.txt $W/vainfo-after.txt || { diff $W/vainfo-build.txt $W/vainfo-after.txt || true; echo "FAIL  vainfo of the installed driver differs from the build's"; exit 1; }
sed 's/^/      /' $W/vainfo-after.txt
if bash $VC >$W/vaapi-check-installed.log 2>&1; then echo "PASS  vaapi-check (installed)"; sed 's/^/      /' $W/vaapi-check-installed.log
else cat $W/vaapi-check-installed.log; echo "FAIL  vaapi-check (installed)"; exit 1; fi
echo "DONE  installed $(git log --oneline -1) (upstream $up + $nlp local patch(es); $opts); logs in $W (tmpfs, gone at reboot)"
# the checks above go through FFmpeg only; Chrome's own VA-API path (dmabuf import, colour, seek, hidden frames) is not
# covered (10-23: the BT.601 colouring was invisible to every check here)
echo "NEXT  Chrome end to end: systemd-run --unit=y700-vp9chrome --collect -p StandardOutput=file:/root/chrome-vp9-check-\$(date +%Y%m%d-%H%M).log bash /root/chrome-vp9-check.sh  (~4 min, want 0 failed; README Chrome 硬解自测)"

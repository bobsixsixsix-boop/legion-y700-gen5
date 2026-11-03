#!/bin/bash
# Update qcom-va-driver (radxa-pkg; called libva-v4l2 until 10-27: the VA-API backend Chrome/mpv/wiliwili/haruna use for
# Iris) to a REVIEWED upstream commit: ROOT on the tablet.   bash libva-v4l2-update.sh <commit>        e.g. 35eff37
# ("origin/master" is accepted too, but then it installs whatever upstream pushed last, unreviewed. v1.1.1 = 35eff37;
# master after it installs the driver as qcom_drv_video.so with v4l2_drv_video.so a symlink: step 2 refuses that tree.)
# Local patches: every /root/libva-v4l2-patches/*.patch (= linux/video/libva-v4l2-patches/*.patch) is applied on top of
# <commit>. For v1.1.x there are none: 0001 (hidden VP9 frames on y14) is retired, see libva-v4l2-patches/retired/
# README; the tablet's copy moves aside before the first v1.1.x run (only *.patch directly in the directory is applied;
# step 1 refuses it otherwise):  cd /root/libva-v4l2-patches && mkdir -p retired && mv 0001-*.patch retired/
# Env: IRIS_NOSHOW_MODE=gray|errts|recycle  what the running kernel does with a hidden picture's NOSHOW buffer (block
#        "NOSHOW mode" below, the same in vp9-hidden-check.sh and chrome-vp9-check.sh). Default from uname -r's -yN
#        suffix: N <= 13 gray, 14 errts, >= 15 recycle; any other release stops and asks for it. LIBVA_EXPECT_ERRTS=0|1
#        (the older switch) still works and means gray|errts.
#      LIBVA_UPDATE_FORCE=1    run although a process holds the Iris decoder/encoder (video nodes named qcom-iris*).
#      LIBVA_UPDATE_NOFIX_OK=1 build and install without local patches on a gray / errts kernel (GUARD below).
#      LIBVA_ALLOW_REWRITE=<old>:<new>  accept a rewritten upstream history whose content changed too (step 1).
#      LIBVA_LOCAL_PATCHES=dir local patch directory (default /root/libva-v4l2-patches; empty = pure upstream).
# <commit> already installed (marker below = HEAD and its sha256 = the installed file = the fresh build): validation
# run - steps 1-3 as usual, then "already installed, nothing to do": no backup, no install.
# GUARD: without local patches, a gray or errts kernel stops the run before anything moves (LIBVA_UPDATE_NOFIX_OK=1
#   overrides). Upstream has no userspace fix for hidden VP9 frames: it relies on kernel patch 0005 (our 1052, y15)
#   recycling the NOSHOW buffer. On y14 (errts) such a build grays every hidden VP9 frame - 7 of 7 in vp9-hidden-check
#   for 6d03c3f alone (10-23) and for v1.1.1 (10-28), and YouTube's VP9 has hundreds - vp9-hidden-check would stop it
#   too, but only after the fetch and the build. On gray kernels (y13 and older) hidden VP9 frames happen to survive
#   (the NOSHOW buffer's timestamp 0 matches nothing), but AV1's hidden references need 0005 as well and nothing runs
#   y13 any more, so the rule stays one line: recycle mode, or local patches (0001 on 6d03c3f for y14), or the override.
# Nothing is installed until every check passed; any failure before that aborts with the installed driver untouched:
#   1. origin: renamed to https://github.com/radxa-pkg/qcom-va-driver.git while it still names radxa-pkg/libva-v4l2
#      (GitHub still redirects the old name; origin is printed every run). fetch; master moves to <commit>:
#      - forward (git merge --ff-only): the default;
#      - over a REWRITTEN upstream history (10-24: upstream re-committed its tip, our 6d03c3f is 3dd2926 now - same
#        parent 077818b, and all 49 files of a 10-22 copy of 6d03c3f's checkout equal 3dd2926's blobs) only on a
#        checked path, then git reset --keep <commit> on master: master's tree equals the tree of a commit in
#        <commit>'s history (the same content under a new id; both printed), or LIBVA_ALLOW_REWRITE=<old>:<new> names
#        master and the commit of <commit>'s history that replaces it, reviewed by hand (their diff --stat is printed).
#        An older <commit>, or an unrelated history without that variable, stops here.
#      - a RETIRED local patch still in the patch directory (0001, libva-v4l2-patches/retired/README) stops the run
#        before master moves on a recycle kernel (not needed there) or for a <commit> from upstream a6cc17b on (it does
#        not apply there; v1.1.x), with the mv that puts it aside; only y14 with an older <commit> still takes it.
#      Then print any change under patches/ (= kernel work: radxa 0001-0003 are our 00y1 / y2 iris patch, 0004 is our
#      1051, 0005 our 1052), then git am the local patches in name order on a DETACHED HEAD: branch master only ever
#      holds upstream commits, so the next run moves it as above. Fixed committer + committer date = author date: the
#      same <commit> and patches give the same commit id, so the marker / validation-run logic below works unchanged. A
#      patch that no longer applies (upstream changed that code or merged it) aborts here: delete it from
#      linux/video/libva-v4l2-patches/ and the tablet's directory if upstream merged it, else rebase it.
#   2. meson, build dir options: -Dgpu_copy=enabled (fail instead of silently falling back to CPU surface copies,
#      upstream 13649f6), -Dcdsp_vpp=disabled -Dvulkan_vpp=disabled (v1.1's VA video processing on the CDSP - ghc to
#      build, a Hexagon skeleton - and on Vulkan: nothing here uses VideoProc, the installed driver lists none), each
#      only if the tree declares it. When the build dir's options differ from the tree's (v1.1 dropped fastcv and added
#      cdsp_vpp / vulkan_vpp), a reconfigure cannot get there: meson 1.10 rejects -D for an option the build dir has
#      not seen ("Unknown option"), and a plain reconfigure first fails on cdsp_vpp's default (enabled: no ghc). So
#      the build dir is set up afresh: the old one moves to $W/build-old, its buildtype / prefix / libdir carry over
#      (the tablet's: debug, /usr/local, lib/aarch64-linux-gnu) and are checked afterwards; the buildtype is never
#      changed here. Otherwise one meson setup --reconfigure with the -D options. Build with nice; build/
#      v4l2_drv_video.so must be a real file linking libEGL; then upstream's host tests (meson test: CAPTURE memory
#      budget, MSM allocation cache modes; no hardware) when the tree registers any.
#   3. against the UNINSTALLED build, as the desktop user: upstream's board tests decoder/main10 (HEVC Main10 and,
#      from v1.1, AV1 capabilities and rejected AV1 pictures), decoder/prime-import, decoder/error-recovery.py
#      (injected OUTPUT/CAPTURE errors -> neutral gray frames, PRIME1/PRIME2/export storage, failure paths, and a real
#      truncated HEVC stream; it builds the adjacent shims error-completion.c and surface-storage.cpp); vainfo (no
#      profile/entrypoint may disappear compared with the installed driver); /root/vaapi-check.sh (H.264, HEVC
#      8/10-bit, VP9 p0/p2 and their show_existing_frame variants, plus an 8-bit AV1 clip with hidden references when
#      the build lists VAProfileAV1Profile0: every frame in hardware, frame-exact against software decode, no
#      iris-vaapi:/error/fail/timeout/damaged line - a gray-frame substitution counts as a failure there);
#      /root/vp9-hidden-check.sh with IRIS_NOSHOW_MODE=<mode> (= linux/video/vp9-hidden-check.sh: hidden VP9 frames with
#      injected error buffers, persistent exports, a really damaged alt-ref; upstream's tests cover only HEVC and AV1).
#      error-recovery's "-truncated" cases can only pass with the kernel error-timestamp patch: in gray mode they are
#      XFAIL only with the known y13 signature (an AssertionError and "surface sync timeout" in the case's log;
#      reported, not fatal; an unexpected pass prints XPASS) - a subprocess timeout or any other failure is still a
#      FAIL; in errts and recycle mode (y14: 1051; y15: 1051 + 1052) the upstream test runs unmodified.
#      AV1, when the build lists VAProfileAV1Profile0: upstream's decoder/av1.py (FFmpeg + libaom + libdav1d: every
#      frame pixel-identical to dav1d, no "recover" / VA status / sync timeout line), one case per process through a
#      small wrapper (a failure does not hide the next case; av1.py's dav1d reference, up to 375 MB per case, leaves
#      tmpfs after each), the kernel log read around each case. Cases ($AV1_CASES): 720p8 must pass; 1080p8-lookahead
#      (lag 25: hidden references; y14 grayed them) and tiles8 (2x2 tiles, lag 25) must pass in recycle mode and are
#      SKIPped elsewhere (they need 0005 / 1052); 1080p10 must pass from y15 on (1057, the AV1 LINE buffer sized for
#      10-bit: 10-29 on y15 bit-exact against dav1d); before y15 it is XFAIL only with the known firmware signature
#      (FFmpeg exit 251 and "session error received 0x4000005" in the kernel log during that case: 10-28 on y14, also
#      tiles10 / still10, while 4k10 passed), a pass there prints XPASS, any other failure FAILs. Not run: 1080p8, 4k8,
#      4k10 (passed on y14 10-28; long), 1080p10-lookahead, lossless8 / motion8 (judge them after the first recycle
#      run), superres8 (needs aomenc).
#   4. back up the installed driver to /root/v4l2_drv_video.so.bak-<stamp>-<its commit>, install, record commit, sha256,
#      options (cdsp_vpp / vulkan_vpp included), upstream commit, local patch count and NOSHOW mode in
#      /root/libva-v4l2.installed, then vainfo (must equal the build's) and vaapi-check.sh on the installed driver.
#      (The installed commit comes from that marker while its sha256 matches; without it, from HEAD only when build/
#      is up to date and byte-identical to the installed file; else the backup is named ...-unknown.)
# Rollback: cp -a --remove-destination /root/v4l2_drv_video.so.bak-<...> /usr/local/lib/aarch64-linux-gnu/dri/v4l2_drv_video.so
#   (--remove-destination: a plain cp rewrites the file in place under players that have it mapped). The 10-23 build
#   2de1857 (6d03c3f + 0001) is the one to go back to on y14; on y15 both it and v1.1.x pass vp9-hidden-check.
#   Source tree: a run with local patches leaves HEAD detached on them; git -C /usr/local/src/libva-v4l2 checkout master
#   before any manual git reset there (this script does that checkout itself). A run killed in the middle of git am
#   leaves .git/rebase-apply behind: the next run aborts that am first and says so. After a fresh meson setup the old
#   build dir is in $W/build-old until the next reboot (tmpfs); nothing needs it.
set -euo pipefail
[ $# -eq 1 ] || { sed -n '2,/^#      LIBVA_LOCAL_PATCHES=/p' "$0"; exit 2; }
T=$1
unset LIBVA_DRIVER_NAME LIBVA_DRIVERS_PATH
S=/usr/local/src/libva-v4l2; SO=/usr/local/lib/aarch64-linux-gnu/dri/v4l2_drv_video.so
MARK=/root/libva-v4l2.installed; VC=/root/vaapi-check.sh; VH=/root/vp9-hidden-check.sh; DEV=/dev/dri/renderD128
LP=${LIBVA_LOCAL_PATCHES-/root/libva-v4l2-patches}
ORIGIN=https://github.com/radxa-pkg/qcom-va-driver.git
AV1_CASES="720p8 1080p8-lookahead tiles8 1080p10"
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
# ---- NOSHOW mode (the same block in libva-v4l2-update.sh, vp9-hidden-check.sh and chrome-vp9-check.sh)
noshow_mode() {   # sets kr, mode (gray|errts|recycle, else unknown and returns 1) and why
	local n
	kr=$(uname -r); mode=; why=
	if [ -n "${IRIS_NOSHOW_MODE:-}" ]; then mode=$IRIS_NOSHOW_MODE; why="IRIS_NOSHOW_MODE=$mode"
	elif [ -n "${LIBVA_EXPECT_ERRTS:-}" ]; then
		why="LIBVA_EXPECT_ERRTS=$LIBVA_EXPECT_ERRTS"
		case $LIBVA_EXPECT_ERRTS in 0) mode=gray ;; 1) mode=errts ;; esac
	elif [[ $kr =~ -y([0-9]+)$ ]]; then
		n=$((10#${BASH_REMATCH[1]})); why="$kr is y$n"
		if [ $n -le 13 ]; then mode=gray; elif [ $n -eq 14 ]; then mode=errts; else mode=recycle; fi
	else why="$kr has no -yN suffix"; fi
	case $mode in gray|errts|recycle) return 0 ;; esac
	mode=unknown; return 1
}
noshow_mode || { echo "cannot tell the kernel's NOSHOW mode ($why): set IRIS_NOSHOW_MODE=gray|errts|recycle"; exit 2; }
echo "kernel NOSHOW mode: $mode ($why)"
# ---- GUARD (header): no local patch outside recycle mode
nlp_avail=0
if [ -n "$LP" ] && compgen -G "$LP/*.patch" >/dev/null; then nlp_avail=$(compgen -G "$LP/*.patch" | wc -l); fi
if [ $mode != recycle ] && [ $nlp_avail = 0 ]; then
	if [ "${LIBVA_UPDATE_NOFIX_OK:-0}" = 1 ]; then
		echo "WARNING: no local patch in ${LP:-(LIBVA_LOCAL_PATCHES empty)} on a $mode kernel: LIBVA_UPDATE_NOFIX_OK=1 overrides the guard"
	else
		echo "REFUSED  no local patch in ${LP:-(LIBVA_LOCAL_PATCHES empty)} on a $mode kernel ($why): upstream's driver grays" \
			"hidden VP9 frames unless the kernel recycles NOSHOW buffers (0005 = our 1052, y15). Boot y15 first, or" \
			"LIBVA_UPDATE_NOFIX_OK=1 (header: GUARD)"
		exit 1
	fi
fi

# ---- 1. source
cd $S
old=$(git rev-parse --short HEAD)
cur=$(sha256sum $SO | cut -d' ' -f1)
# commit of the installed driver: our marker while its sha256 matches, else HEAD when build/ is up to date with HEAD
# and byte-identical to the installed file (a run that aborted after the source moved leaves a stale build/ behind)
prev=unknown
if [ -r $MARK ] && [ "$(cut -d' ' -f2 $MARK)" = "$cur" ]; then prev=$(cut -c1-7 $MARK)
elif cmp -s build/v4l2_drv_video.so $SO && [ "$(ninja -C build -n 2>/dev/null | tail -1)" = "ninja: no work to do." ]; then prev=$old; fi
# root may have no git identity (am and am --abort need one); a fixed one also keeps local commit ids reproducible
GL=(git -c user.name=y700-local -c user.email=root@localhost -c commit.gpgsign=false)
if [ -d .git/rebase-apply ]; then echo "leftover git am in $S (an earlier run was killed): aborting it"; "${GL[@]}" am --abort || true; fi
# a previous run with local patches left HEAD detached on them: back to the upstream-only branch
git symbolic-ref -q HEAD >/dev/null || git checkout -q master
url=$(git config --get remote.origin.url)   # the configured value (get-url would expand url.*.insteadOf)
if [[ $url =~ github\.com[:/]radxa-pkg/libva-v4l2(\.git)?/?$ ]]; then
	git remote set-url origin $ORIGIN; echo "origin renamed upstream: $url -> $ORIGIN"; url=$ORIGIN
fi
echo "origin: $url"
git fetch -q origin
git rev-parse -q --verify "$T^{commit}" >/dev/null || { echo "unknown commit: $T"; exit 1; }
Tc=$(git rev-parse "$T^{commit}"); M=$(git rev-parse HEAD)
git merge-base --is-ancestor $Tc origin/master || echo "WARNING: $T is not on origin/master"
# retired local patches (header, step 1), before master moves: 0001 does not apply from a6cc17b (AV1 Main decoding,
# which rewrote Decoder::pump) on, and a recycle kernel never hands userspace the NOSHOW buffer it waited for
A6=a6cc17ba7ce313bf94c0b260404a1408d937fe2b
for r in 0001-decoder-do-not-gray-a-hidden-VP9-frame-on-its-Iris-no-show-buffer.patch; do
	[ $nlp_avail -gt 0 ] && [ -e "$LP/$r" ] || continue
	if [ $mode = recycle ]; then rwhy="a $mode kernel does not need it"
	elif git merge-base --is-ancestor $A6 $Tc 2>/dev/null; then rwhy="it does not apply on $T (upstream a6cc17b on)"
	else echo "      local patch $r is retired; applied anyway: $T does not contain upstream a6cc17b and the kernel is $mode"; continue; fi
	echo "REFUSED  $LP/$r is retired (libva-v4l2-patches/retired/README): $rwhy. master has not moved. Move it aside"
	echo "  (only $LP/*.patch is applied; it stays at hand for a y14 rollback build): mkdir -p $LP/retired && mv $LP/$r $LP/retired/"
	exit 1
done
echo "installed driver: $prev    source before: $(git log --oneline -1)"
if git merge-base --is-ancestor $M $Tc; then
	git merge -q --ff-only $Tc
elif git merge-base --is-ancestor $Tc $M; then
	echo "$T is older than master ($(git log --oneline -1 $M)): this script only moves forward"; exit 1
else
	# master is not in <commit>'s history: upstream rewrote it (or <commit> is unrelated). Only the checked paths.
	mt=$(git rev-parse "$M^{tree}")
	same=$(git log --format='%H %T' $Tc | awk -v t="$mt" '$2 == t && !f {print $1; f = 1}')
	if [ -n "$same" ]; then
		echo "upstream rewrote its history: master $(git log --oneline -1 $M) has the same tree ($mt)"
		echo "  as $(git log --oneline -1 $same) in $T's history: moving master to $T (git reset --keep)"
	elif [ -n "${LIBVA_ALLOW_REWRITE:-}" ]; then
		ro=${LIBVA_ALLOW_REWRITE%%:*}; rn=${LIBVA_ALLOW_REWRITE#*:}
		[ "$ro" != "$LIBVA_ALLOW_REWRITE" ] && [ -n "$ro" ] && [ -n "$rn" ] || { echo "LIBVA_ALLOW_REWRITE must be <old>:<new>"; exit 2; }
		[ "$(git rev-parse -q --verify "$ro^{commit}" || true)" = "$M" ] \
			|| { echo "LIBVA_ALLOW_REWRITE: $ro is not master ($(git log --oneline -1 $M))"; exit 1; }
		rnc=$(git rev-parse -q --verify "$rn^{commit}" || true)
		[ -n "$rnc" ] && git merge-base --is-ancestor $rnc $Tc || { echo "LIBVA_ALLOW_REWRITE: $rn is not in $T's history"; exit 1; }
		echo "upstream rewrote its history; LIBVA_ALLOW_REWRITE: master $(git log --oneline -1 $M)"
		echo "  is replaced by $(git log --oneline -1 $rnc); what differs between them:"
		git diff --stat $M $rnc | sed 's/^/      /'
		echo "  moving master to $T (git reset --keep)"
	else
		echo "master ($(git log --oneline -1 $M)) is not in $T's history and no commit there has its tree: upstream rewrote"
		echo "its history with other content, or $T is unrelated. Review, then rerun with LIBVA_ALLOW_REWRITE=<master>:<its"
		echo "replacement in $T's history>"
		exit 1
	fi
	git reset -q --keep $Tc
fi
[ "$(git rev-parse HEAD)" = "$Tc" ] || { echo "HEAD is not $T"; exit 1; }
echo "source after: $(git log --oneline -1)"
base=$old; [ $prev = unknown ] || base=$prev
if ! git cat-file -e "$base^{commit}" 2>/dev/null; then echo "WARNING: $base is gone from the tree, cannot compare patches/"
elif [ -n "$(git diff --name-only "$base" HEAD -- patches/)" ]; then
	echo "!!! KERNEL PATCHES CHANGED upstream ($base..HEAD): port them to our kernel; the new code runs without them until then"
	git diff --stat "$base" HEAD -- patches/ | sed 's/^/!!!   /'
fi
up=$(git rev-parse --short HEAD); nlp=0
if [ $nlp_avail -gt 0 ]; then
	git checkout -q --detach
	for p in "$LP"/*.patch; do
		if ! "${GL[@]}" am -q --committer-date-is-author-date "$p" >$W/am.log 2>&1; then
			cat $W/am.log; "${GL[@]}" am --abort || true; git checkout -q master
			echo "FAIL  local patch ${p##*/} does not apply on $up: upstream merged it (delete it from linux/video/libva-v4l2-patches/ and $LP) or changed that code (rebase it). 0001 is retired for v1.1.x (libva-v4l2-patches/retired/README)"
			exit 1
		fi
		nlp=$((nlp + 1)); echo "local patch: $(git log --oneline -1)"
	done
fi
echo "building: $(git rev-parse --short HEAD) = upstream $up + $nlp local patch(es)"

# ---- 2. configure + build
declared() { grep -qs "option('$1'" meson.options meson_options.txt; }   # -s: one of the two files is always missing
want=()
for kv in gpu_copy=enabled cdsp_vpp=disabled vulkan_vpp=disabled; do
	if declared ${kv%%=*}; then want+=(-D$kv); fi
done
fresh=
if [ ! -f build/meson-private/coredata.dat ]; then fresh="no configured build dir"
elif ! meson introspect build --buildoptions >$W/options-old.json 2>$W/introspect-old.log; then fresh="meson introspect fails on the build dir"
else
	# project options of the build dir vs the tree's: any difference means a fresh setup (header, step 2)
	diffo=$(python3 -I -c 'import json, re, sys
have = {x["name"] for x in json.load(open(sys.argv[1])) if x.get("section") == "user"}
text = ""
for f in ("meson.options", "meson_options.txt"):
    try:
        text += open(f).read()
    except OSError:
        pass
print(" ".join(sorted(have ^ set(re.findall(r"option\(\s*.([A-Za-z0-9_]+).", text)))))' $W/options-old.json)
	[ -z "$diffo" ] || fresh="the build dir's options differ from the tree's: $diffo"
fi
if [ -n "$fresh" ]; then
	carry=()
	if [ -s $W/options-old.json ]; then
		mapfile -t carry < <(python3 -I -c 'import json, sys
o = {x["name"]: x["value"] for x in json.load(open(sys.argv[1]))}
print("\n".join("--%s=%s" % (k, o[k]) for k in ("buildtype", "prefix", "libdir") if k in o))' $W/options-old.json)
	fi
	echo "meson: fresh build dir ($fresh), carrying over ${carry[*]:-nothing} with ${want[*]:-no -D option}"
	[ ! -e build ] || mv build $W/build-old
	meson setup build "${carry[@]}" "${want[@]}" >$W/meson-setup.log 2>&1 \
		|| { tail -20 $W/meson-setup.log; echo "FAIL  meson setup ${carry[*]} ${want[*]} (EGL / GLES 3.2 / GBM dev packages?)"; exit 1; }
else
	meson setup --reconfigure build "${want[@]}" >$W/meson-setup.log 2>&1 \
		|| { tail -20 $W/meson-setup.log; echo "FAIL  meson setup --reconfigure ${want[*]} (EGL / GLES 3.2 / GBM dev packages?)"; exit 1; }
fi
grep -E '^ *(GPU surface copy|CDSP VPP|Vulkan VPP|FastCV CDSP VPP) *:' $W/meson-setup.log | sed 's/^ */      meson: /' || true
meson introspect build --buildoptions >$W/options.json
# what was asked for must be what the build dir holds; a fresh setup keeps buildtype / prefix / libdir
bad=$(python3 -I -c 'import json, sys
o = {x["name"]: x["value"] for x in json.load(open(sys.argv[1]))}
want = dict(a[2:].split("=", 1) for a in sys.argv[3:])
try:
    old = {x["name"]: x["value"] for x in json.load(open(sys.argv[2]))}
except (OSError, ValueError):
    old = {}
want.update({k: old[k] for k in ("buildtype", "prefix", "libdir") if k in old})
print(" ".join("%s=%s(want %s)" % (k, o.get(k), v) for k, v in want.items() if str(o.get(k)) != v))' \
	$W/options.json $W/options-old.json "${want[@]}")
[ -z "$bad" ] || { echo "FAIL  meson build dir options: $bad"; exit 1; }
opts=$(python3 -I -c 'import json, sys
o = {x["name"]: x["value"] for x in json.load(open(sys.argv[1]))}
print(" ".join("%s=%s" % (k, o[k]) for k in ("buildtype", "gpu_copy", "cdsp_vpp", "vulkan_vpp", "fastcv", "prefix") if k in o))' $W/options.json)
echo "options: $opts"
nice -n 10 ninja -C build >$W/ninja.log 2>&1 || { tail -30 $W/ninja.log; echo "FAIL  build"; exit 1; }
tail -1 $W/ninja.log
[ -f build/v4l2_drv_video.so ] && [ ! -L build/v4l2_drv_video.so ] \
	|| { ls -la build/*_drv_video.so 2>/dev/null || true; echo "FAIL  build/v4l2_drv_video.so is not a real file (the tree installs the driver under another name: pin a v1.1.x commit or adapt this script)"; exit 1; }
ldd build/v4l2_drv_video.so >$W/ldd-build.log
grep -q libEGL $W/ldd-build.log || { echo "FAIL  build/v4l2_drv_video.so does not link libEGL (GPU copy compiled out)"; exit 1; }
echo "PASS  build links libEGL"
# upstream's host tests (v1.1: test() targets, build_by_default false, no hardware)
meson test -C build --list >$W/meson-test-list.log 2>&1 || true
if grep -q . $W/meson-test-list.log && ! grep -qi 'no tests defined' $W/meson-test-list.log; then
	if nice -n 10 meson test -C build --print-errorlogs >$W/meson-test.log 2>&1; then
		echo "PASS  meson test ($(grep -E '^ *[0-9]+/[0-9]+ ' $W/meson-test.log | grep -c ' OK ' || true) OK; $(tr '\n' ';' <$W/meson-test-list.log))"
	else tail -30 $W/meson-test.log; echo "FAIL  meson test (log $W/meson-test.log)"; exit 1; fi
else echo "      meson test: the tree registers no test"; fi
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
if [ $mode = gray ]; then
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
av1=0; if grep -qx 'VAProfileAV1Profile0:VAEntrypointVLD' $W/vainfo-build.txt; then av1=1; fi
if env "${B[@]}" bash $VC >$W/vaapi-check-build.log 2>&1; then echo "PASS  vaapi-check (build)"; sed 's/^/      /' $W/vaapi-check-build.log
else cat $W/vaapi-check-build.log; echo "FAIL  vaapi-check (build)"; exit 1; fi
if IRIS_NOSHOW_MODE=$mode bash $VH $S/build >$W/vp9-hidden-build.log 2>&1; then echo "PASS  vp9-hidden-check (build)"
	sed 's/^/      /' $W/vp9-hidden-build.log
else cat $W/vp9-hidden-build.log; echo "FAIL  vp9-hidden-check (build)"; exit 1; fi

# AV1 (header, step 3): upstream's av1.py one case per process; the kernel log of each case from the line after the
# last one before it (a grep -F -x of that line survives a ring buffer that dropped older lines; not found = all)
if [ $av1 = 1 ]; then
	[ -f tests/decoder/av1.py ] || { echo "tests/decoder/av1.py is gone upstream: update this script"; exit 1; }
	cp tests/decoder/av1.py $W/t/
	cat >$W/t/av1-case.py <<'PY'
# av1-case.py <av1.py> <case> <out-dir> <driver-dir>: upstream's tests/decoder/av1.py restricted to one of its cases
# (written by libva-v4l2-update.sh). Prints "case <name> depth <bits>" first; av1.py raises on any failure (exit 1).
import importlib.util, sys
path, case, out, drv = sys.argv[1:5]
spec = importlib.util.spec_from_file_location('av1', path)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
sel = [c for c in m.CASES + m.EXTENDED_CASES if c[0] == case]
if len(sel) != 1:
    sys.exit(f'av1.py has no case {case!r}: update AV1_CASES in libva-v4l2-update.sh')
print('case', case, 'depth', sel[0][3], flush=True)
m.CASES, m.EXTENDED_CASES = sel, []
sys.argv = ['av1.py', out, '--driver-dir', drv]
m.main()
PY
	mkdir -p $W/av1; chown -R user: $W/t $W/av1
	# 10-bit (header, step 3): y15 on has 1057 (the vpu4x AV1 LINE buffer sized for 10-bit), which ended the firmware
	# failure: there a 10-bit case passes or FAILs like any other
	ten=0; if [[ $kr =~ -y([0-9]+)$ ]] && [ $((10#${BASH_REMATCH[1]})) -ge 15 ]; then ten=1; fi
	for c in $AV1_CASES; do
		case $c in *-lookahead|tiles*)
			if [ $mode != recycle ]; then echo "SKIP  av1 $c: hidden references need the kernel's NOSHOW recycling (mode $mode)"; continue; fi ;;
		esac
		k0=$(dmesg | tail -1)
		if "${U[@]}" timeout 900 python3 -I $W/t/av1-case.py $W/t/av1.py $c $W/av1/$c $S/build >$W/av1-$c.log 2>&1; then rc=0; else rc=$?; fi
		dmesg >$W/av1-$c.dmesg
		n=$(grep -n -F -x -e "$k0" $W/av1-$c.dmesg | tail -1 | cut -d: -f1 || true)
		tail -n +$((${n:-0} + 1)) $W/av1-$c.dmesg >$W/av1-$c.kmsg; rm -f $W/av1-$c.dmesg
		rm -f $W/av1/$c/reference-* $W/av1/$c/ffmpeg-*.nv12 $W/av1/$c/ffmpeg-*.p010
		depth=$(sed -n '/^case .* depth [0-9]*$/{s/.* //p;q}' $W/av1-$c.log)
		kerr=$(grep -c 'session error' $W/av1-$c.kmsg || true)
		row=$(grep -m1 '^{"case"' $W/av1-$c.log | sed -E 's/.*"frames": ([0-9]+).*"reference_replays": ([0-9]+), "hidden_pictures": ([0-9]+).*/\1 frames identical to dav1d, \2 reference replays, \3 hidden pictures/' || true)
		if [ $rc = 0 ] && grep -q '^PASS: 1 AV1 cases' $W/av1-$c.log; then
			if [ "$depth" != 10 ]; then echo "PASS  av1 $c: $row"
			elif [ $ten = 1 ]; then echo "PASS  av1 $c: $row (10-bit, $kr has 1057)"
			else echo "XPASS av1 $c: $row (10-bit, the firmware failed it 10-28 on y14)"; fi
			[ "$kerr" = 0 ] || echo "      WARNING: $kerr Iris session error line(s) in the kernel log during $c ($W/av1-$c.kmsg)"
		elif [ "$depth" = 10 ] && [ $ten = 0 ] && grep -qF "RuntimeError: ffmpeg-$c.log: exit 251" $W/av1-$c.log \
			&& grep -q 'session error received 0x4000005' $W/av1-$c.kmsg; then
			echo "XFAIL av1 $c: the known 10-bit firmware failure (FFmpeg exit 251, \"session error received 0x4000005\" in the kernel log)"
		else
			tail -25 $W/av1-$c.log; grep -i iris $W/av1-$c.kmsg | head -8 || true
			echo "FAIL  av1 $c (rc $rc; logs $W/av1-$c.log, $W/av1-$c.kmsg, $W/av1/$c/)"; exit 1
		fi
	done
else echo "SKIP  av1: the build lists no VAProfileAV1Profile0"; fi
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
echo "$(git rev-parse HEAD) $(sha256sum $SO | cut -d' ' -f1) $stamp $opts upstream=$up local=$nlp noshow=$mode" >$MARK
ldd $SO >$W/ldd-installed.log
grep -q libEGL $W/ldd-installed.log || { echo "FAIL  installed driver does not link libEGL"; exit 1; }
"${U[@]}" vainfo --display drm --device $DEV 2>&1 | grep 'Driver version' || true
profiles >$W/vainfo-after.txt
cmp -s $W/vainfo-build.txt $W/vainfo-after.txt || { diff $W/vainfo-build.txt $W/vainfo-after.txt || true; echo "FAIL  vainfo of the installed driver differs from the build's"; exit 1; }
sed 's/^/      /' $W/vainfo-after.txt
if bash $VC >$W/vaapi-check-installed.log 2>&1; then echo "PASS  vaapi-check (installed)"; sed 's/^/      /' $W/vaapi-check-installed.log
else cat $W/vaapi-check-installed.log; echo "FAIL  vaapi-check (installed)"; exit 1; fi
echo "DONE  installed $(git log --oneline -1) (upstream $up + $nlp local patch(es); $opts; NOSHOW mode $mode); logs in $W (tmpfs, gone at reboot)"
# the checks above go through FFmpeg only; Chrome's own VA-API path (dmabuf import, colour, seek, hidden frames) is not
# covered (10-23: the BT.601 colouring was invisible to every check here). CODEC=vp9,av1 adds the AV1 clip.
ce=; [ $av1 = 0 ] || ce="-E CODEC=vp9,av1 "
echo "NEXT  Chrome end to end: systemd-run --unit=y700-vp9chrome --collect ${ce}-p StandardOutput=file:/root/chrome-vp9-check-\$(date +%Y%m%d-%H%M).log bash /root/chrome-vp9-check.sh  (~4 min, want 0 failed; README Chrome 硬解自测)"

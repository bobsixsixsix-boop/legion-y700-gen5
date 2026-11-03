#!/bin/bash
# Install / roll back / show the y700 libcamera build (0.7.0-1ubuntu2+y700.1 from libcamera-af-build.sh): ROOT on the tablet.
#   bash libcamera-af-install.sh --install  [--restart-wireplumber]
#   bash libcamera-af-install.sh --rollback [--restart-wireplumber]
#   bash libcamera-af-install.sh --status
# --restart-wireplumber: afterwards restart pipewire, pipewire-pulse and wireplumber of the desktop user `user`
#   (systemctl --user, XDG_RUNTIME_DIR=/run/user/1000). Audio drops for a moment and an open camera stream ends.
#   Without it nothing is restarted: those processes keep the libcamera they loaded (and with the stock one, the
#   rear VCM stays powered) until they restart, e.g. at the next login or reboot.
# --install (all checks first; nothing is changed until every backup exists):
#   1. the five packages gstreamer1.0-libcamera libcamera-ipa libcamera-tools libcamera-v4l2 libcamera0.7, plus
#      libcamera-dev / python3-libcamera only when already installed (libcamera-dev depends on exactly its libcamera0.7
#      version and would block the upgrade; nothing on the tablet needs either), must be built in /root/libcamera-y700/
#      and currently be absent, 0.7.0-1ubuntu2 or an earlier y700 build: a newer Ubuntu version means rebase the
#      patches first (README checklist), LIBCAMERA_Y700_FORCE=1 overrides;
#   2. back up Ubuntu's 0.7.0-1ubuntu2 .deb of each into /root/libcamera-y700/orig-0.7.0-1ubuntu2/ (apt-get download,
#      else /var/cache/apt/archives; kept across runs). No backup, no install;
#   3. record the versions found before the first install in /root/libcamera-y700/install-state.txt (kept);
#   4. dpkg -i all of them in one call (libcamera0.7 and libcamera-ipa must come from the same build: the IPA
#      signature key and the statistics layout), then apt-mark hold them so that apt upgrade does not put Ubuntu's
#      libcamera back. The hold also blocks Ubuntu's libcamera security updates: README checklist;
#   5. list the processes that still map the replaced libcamera, i.e. run the old code.
# --rollback: apt-mark unhold, then dpkg -i the saved 0.7.0-1ubuntu2 .debs of every package of the list that is installed
#   (downloaded again when the backup is missing - only possible while the archive still carries that version).
#   Packages that install-state.txt records as absent before the first install stay installed at Ubuntu's version;
#   the rollback prints them (apt-get purge them by hand if wanted).
# --status: versions and hold state, which processes map which libcamera, and the rear lens (I2C 5-000c): its
#   v4l-subdev node, who holds it open, runtime PM status, and the vreg_l6b_2p8 regulator state. Read-only.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive LC_ALL=C.UTF-8
UP=0.7.0; VER=$UP-1ubuntu2; NEW=$VER+y700.1
D=/root/libcamera-y700; O=$D/orig-$VER; STATE=$D/install-state.txt
BASE=(gstreamer1.0-libcamera libcamera-ipa libcamera-tools libcamera-v4l2 libcamera0.7)
OPTIONAL=(libcamera-dev python3-libcamera)
U=(runuser -u user -- env XDG_RUNTIME_DIR=/run/user/1000)
LENS_I2C=${LIBCAMERA_Y700_LENS_I2C:-5-000c}; REGNAME=vreg_l6b_2p8
APT=(apt-get -q -o DPkg::Lock::Timeout=600 -o APT::Sandbox::User=root)
usage() { sed -n '2,8p' "$0"; exit 2; }
mode=; restart=0
for a in "$@"; do
	case $a in
	--install|--rollback|--status) [ -z "$mode" ] || usage; mode=$a ;;
	--restart-wireplumber) restart=1 ;;
	*) usage ;;
	esac
done
[ -n "$mode" ] || usage
[ "$(id -u)" -eq 0 ] || { echo "run as root"; exit 1; }
phase=check
finish() {
	local rc=$?
	[ $rc -eq 0 ] && return
	if [ $phase = check ]; then
		echo "ABORTED (rc $rc) before any package was changed."
	elif [ $phase = restart ]; then
		echo "FAILED (rc $rc) restarting pipewire/wireplumber of user; the packages were changed as shown above." \
			"Restart them by hand or log out/in."
	else
		echo "FAILED (rc $rc) while changing packages ($phase). See dpkg's messages above; libcamera-af-install.sh --status" \
			"shows the state, --rollback returns to $VER."
	fi
}
trap finish EXIT

# installed version of $1, or "none". A held package's status is "hold ok installed" (the hold is the want field;
# 10-29 the first --install took its own held packages for "none" and stopped after dpkg -i and the hold; --rollback
# would have skipped every held package and said "nothing to roll back")
ver() {
	local s
	s=$(dpkg-query -W -f='${Status}|${Version}' "$1" 2>/dev/null) || { echo none; return; }
	case ${s%%|*} in "install ok installed"|"hold ok installed") echo "${s#*|}" ;; *) echo none ;; esac
}
# the package set this run works on: BASE plus the installed OPTIONAL ones
pkgset() {
	local p
	printf '%s\n' "${BASE[@]}"
	for p in "${OPTIONAL[@]}"; do [ "$(ver "$p")" = none ] || echo "$p"; done
}
# processes that map libcamera.so.0.7; "OLD" = the file they mapped was replaced or removed since
maps_report() {
	local f pid st n=0
	for f in /proc/[0-9]*/maps; do
		pid=${f#/proc/}; pid=${pid%/maps}
		grep -q 'libcamera\.so\.0\.7' "$f" 2>/dev/null || continue
		st=current
		grep -q 'libcamera\.so\.0\.7.* (deleted)' "$f" 2>/dev/null && st='OLD (replaced file still mapped)'
		echo "  pid $pid $(cat /proc/$pid/comm 2>/dev/null) ($(stat -c %U /proc/$pid 2>/dev/null)): $st"
		n=$((n + 1))
	done
	[ $n -gt 0 ] || echo "  (no process maps libcamera.so.0.7)"
}
old_mappers() { maps_report | grep -c 'OLD' || true; }
# the rear lens subdev node: the v4l-subdev whose device is the I2C client $LENS_I2C
lens_node() {
	local d
	for d in /sys/class/video4linux/v4l-subdev*; do
		[ "$(basename "$(readlink -f "$d/device" 2>/dev/null)")" = "$LENS_I2C" ] && { echo "/dev/${d##*/}"; return; }
	done
	return 0
}
lens_report() {
	local n r d h
	n=$(lens_node)
	echo "rear lens $LENS_I2C: node ${n:-not found}," \
		"runtime_status $(cat /sys/bus/i2c/devices/$LENS_I2C/power/runtime_status 2>/dev/null || echo missing)"
	if [ -n "$n" ]; then
		h=$( { find /proc/[0-9]*/fd -lname "$n" 2>/dev/null || true; } | cut -d/ -f3 | sort -un |
			while read -r p; do printf ' %s(%s)' "$p" "$(cat /proc/$p/comm 2>/dev/null)"; done)
		echo "  held open by:${h:- nobody}"
	fi
	r=
	for d in /sys/class/regulator/regulator.*; do
		[ "$(cat "$d/name" 2>/dev/null)" = "$REGNAME" ] && { r=$d; break; }
	done
	if [ -n "$r" ]; then
		echo "  $REGNAME ($r): state $(cat "$r/state" 2>/dev/null || echo ?), num_users $(cat "$r/num_users" 2>/dev/null || echo ?)"
	else
		echo "  $REGNAME: not found under /sys/class/regulator"
	fi
}
status() {
	local p
	echo "packages (installed version, hold):"
	for p in "${BASE[@]}" "${OPTIONAL[@]}"; do
		printf '  %-24s %-28s %s\n' "$p" "$(ver "$p")" "$(apt-mark showhold "$p" 2>/dev/null | grep -qx "$p" && echo held || echo -)"
	done
	echo "processes mapping libcamera.so.0.7:"
	maps_report
	lens_report
}
restart_session() {
	local u units=()
	for u in pipewire.service pipewire-pulse.service wireplumber.service; do
		[ "$("${U[@]}" systemctl --user show -p LoadState --value "$u" 2>/dev/null)" = loaded ] && units+=("$u")
	done
	[ ${#units[@]} -gt 0 ] || { echo "no pipewire/wireplumber user unit of user is loaded: nothing restarted"; return 0; }
	echo "restarting ${units[*]} of user"
	"${U[@]}" systemctl --user restart "${units[@]}"
	sleep 3
	{ "${U[@]}" systemctl --user is-active "${units[@]}" || true; } | paste -sd' ' | sed 's/^/  active: /'
}
after_change() {
	local n
	n=$(old_mappers)
	echo "processes mapping libcamera.so.0.7:"
	maps_report
	if [ "$restart" = 1 ]; then
		phase=restart
		restart_session
		echo "after the restart:"
		maps_report
		n=$(old_mappers)
	fi
	if [ "$n" -gt 0 ]; then
		echo "NOTE: $n process(es) above still run the replaced libcamera. pipewire and wireplumber of user each keep a"
		echo "  CameraManager for the whole session: restart them (rerun with --restart-wireplumber, or as user:"
		echo "  XDG_RUNTIME_DIR=/run/user/1000 systemctl --user restart pipewire pipewire-pulse wireplumber), or log out/in."
	fi
}
# make sure $O/<pkg>_$VER_arm64.deb exists and is that package and version
backup() {
	local p=$1 f=$O/${1}_${VER}_arm64.deb c
	if [ -f "$f" ] && [ "$(dpkg-deb -f "$f" Package Version 2>/dev/null | paste -sd' ')" = "Package: $p Version: $VER" ]; then
		return 0
	fi
	rm -f "$f"
	(cd "$O" && "${APT[@]}" download "$p=$VER") || true
	if [ ! -f "$f" ]; then
		c=/var/cache/apt/archives/${p}_${VER}_arm64.deb
		[ -f "$c" ] && cp "$c" "$f"
	fi
	[ -f "$f" ] && [ "$(dpkg-deb -f "$f" Package Version 2>/dev/null | paste -sd' ')" = "Package: $p Version: $VER" ] || {
		rm -f "$f"; echo "cannot get Ubuntu's $p $VER .deb (apt-get download and the apt cache both failed)"; return 1; }
	echo "  backed up: $f"
}

case $mode in
--status)
	status
	;;
--install)
	mapfile -t P < <(pkgset)
	debs=()
	for p in "${P[@]}"; do
		f=$D/${p}_${NEW}_arm64.deb
		[ -f "$f" ] || { echo "missing $f: run libcamera-af-build.sh first"; exit 1; }
		[ "$(dpkg-deb -f "$f" Version)" = "$NEW" ] || { echo "$f is not version $NEW"; exit 1; }
		debs+=("$f")
		v=$(ver "$p")
		if [ "$v" != none ] && [ "$v" != "$VER" ] && [[ $v != "$VER"+y700.* ]]; then
			if [ "${LIBCAMERA_Y700_FORCE:-0}" = 1 ]; then echo "WARNING: $p is $v, installing $NEW anyway (LIBCAMERA_Y700_FORCE=1)"
			else echo "$p is $v (neither $VER nor a y700 build): rebase the patches onto it first (README), or LIBCAMERA_Y700_FORCE=1"; exit 1; fi
		fi
	done
	echo "backing up Ubuntu's $VER packages into $O"
	mkdir -p "$O"
	for p in "${P[@]}"; do backup "$p"; done
	if [ ! -f "$STATE" ]; then
		for p in "${BASE[@]}" "${OPTIONAL[@]}"; do echo "$p $(ver "$p")"; done > "$STATE"
		echo "versions before the first install recorded in $STATE"
	fi
	phase=install
	echo "dpkg -i: ${debs[*]##*/}"
	dpkg -i "${debs[@]}"
	apt-mark hold "${P[@]}"
	for p in "${P[@]}"; do
		[ "$(ver "$p")" = "$NEW" ] || { echo "$p is $(ver "$p") after dpkg -i, expected $NEW"; exit 1; }
	done
	after_change
	echo "OK: installed and held ${P[*]} at $NEW. Check: /root/libcamera-af-check.sh"
	;;
--rollback)
	mapfile -t P < <(pkgset)
	held=$(apt-mark showhold)
	mkdir -p "$O"
	debs=()
	for p in "${P[@]}"; do
		[ "$(ver "$p")" = none ] && continue
		backup "$p"
		debs+=("$O/${p}_${VER}_arm64.deb")
	done
	[ ${#debs[@]} -gt 0 ] || { echo "none of ${P[*]} is installed: nothing to roll back"; exit 0; }
	phase=rollback
	for p in "${P[@]}"; do
		if grep -qx "$p" <<<"$held"; then apt-mark unhold "$p"; fi
	done
	echo "dpkg -i: ${debs[*]##*/}"
	dpkg -i "${debs[@]}"
	for f in "${debs[@]}"; do
		p=$(dpkg-deb -f "$f" Package)
		[ "$(ver "$p")" = "$VER" ] || { echo "$p is $(ver "$p") after dpkg -i, expected $VER"; exit 1; }
	done
	after_change
	if [ -f "$STATE" ]; then
		absent=$(awk '$2 == "none" { print $1 }' "$STATE" | while read -r p; do [ "$(ver "$p")" = none ] || echo "$p"; done | paste -sd' ')
		[ -z "$absent" ] || echo "NOTE: not installed before the first --install, now at $VER: $absent (apt-get purge them if unwanted)"
	fi
	echo "OK: rolled back to Ubuntu's $VER and unheld."
	;;
esac

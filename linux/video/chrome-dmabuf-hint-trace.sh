#!/bin/bash
# chrome-dmabuf-hint-trace.sh: which YUV hints the test Chrome's GPU process hands to Mesa's dmabuf import. ROOT on the
# tablet, next to chrome-vp9-check.sh (2026-10-23, README "视频硬解" 「Chrome 硬解画面按 BT.601 上色」):
#   systemd-run --unit=y700-vp9hint --collect -p StandardOutput=file:/root/H.log bash /root/chrome-dmabuf-hint-trace.sh
#   ONLY=video YT_URL= systemd-run --unit=y700-vp9chrome --collect -p StandardOutput=file:/root/X.log bash /root/chrome-vp9-check.sh
# Waits (2 min) for the check's GPU process, attaches gdb with a breakpoint on libgallium's dri2_from_dma_bufs (what
# eglCreateImage(EGL_LINUX_DMA_BUF_EXT) ends in) and prints one IMPORT line per call: fourcc, size, modifier, plane count,
# EGL_YUV_COLOR_SPACE_HINT_EXT (0 none, 0x327f 601, 0x3280 709, 0x3281 2020) and EGL_SAMPLE_RANGE_HINT_EXT (0 none,
# 0x3282 full, 0x3283 narrow). The 2 hints are stack arguments: at the caller's sp, word 1 and word 2 (low 32 bits),
# calibrated on Mesa 26.0.8 with nv12-egl-matrix.c, whose hints are known; recheck after a Mesa upgrade.
# Detaches after DUR seconds (arg 1, default 150) or when Chrome exits. Only reads; gdb stops the GPU process per import.
set -u
DUR=${1:-150}
pid=
for _ in $(seq 240); do
	for p in $(pgrep -u user -f -- '--user-data-dir=/tmp/y700-cvp9-'); do
		tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null | grep -q -- '--type=gpu-process' && grep -q libgallium /proc/$p/maps 2>/dev/null && { pid=$p; break; }
	done
	[ -n "$pid" ] && break
	sleep 0.5
done
[ -n "$pid" ] || { echo "FAIL no test Chrome GPU process with libgallium mapped within 2 min"; exit 1; }
echo "GPU process $pid: $(grep -o '/[^ ]*libgallium[^ ]*' /proc/$pid/maps | head -1)"
C=$(mktemp /tmp/y700-hint-XXXXXX.gdb)
cat > "$C" <<'EOF'
set pagination off
set confirm off
handle all nostop noprint pass
handle SIGINT stop print nopass
break dri2_from_dma_bufs
commands
silent
printf "IMPORT fourcc=0x%x %dx%d mod=0x%lx planes=%d", $w3, $w1, $w2, $x4, $w6
up-silently
printf " colorspace=0x%x range=0x%x\n", (int)*(long*)($sp+8), (int)*(long*)($sp+16)
down-silently
continue
end
continue
detach
quit
EOF
gdb -q -batch -x "$C" -p "$pid" 2>&1 | grep -E 'IMPORT|Breakpoint 1 at|exited|rror' & g=$!
( sleep "$DUR"; pkill -INT -f "gdb -q -batch -x $C" ) & s=$!
wait $g
kill $s 2>/dev/null
rm -f "$C"
echo "done"

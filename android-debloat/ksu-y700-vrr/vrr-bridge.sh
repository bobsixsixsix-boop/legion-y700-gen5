#!/system/bin/sh
# y700 vrr-bridge：把应用通过 OPPO 私有接口发出的刷新率请求，翻译成真正的显示模式切换。
#
# 背景：抖音等应用播放视频时调用 OPlusRefreshRateService.setFrameRate(30, ...)，ColorOS 原本靠
# LTPO 面板级空闲降频来响应；联想 Y700 的面板/HWC 没有这条路，请求在 SurfaceFlinger 扩展里空转。
# 本脚本盯着 logcat 里这条请求，用 oplusscreenmode 服务的 requestRefreshRate(开关, 速率id)
# （binder 事务 4，PRIORITY_MEMC 投票，无权限检查）临时把屏幕压到 LOW_RATE；
# 应用申请 >=60、申请 0(取消)、切到别的应用、熄屏、或看门狗发现前台不是持有者时撤回。
#
# 速率 id：1=90 2=60 3=120 4=144 5=72 6=30 7=165
# 状态文件 /data/adb/y700/vrr-held（持有者包名，空=未持有），主循环和看门狗共用。
# 日志在 /data/adb/y700/vrr-bridge.log（只记状态变化）。
LOW_RATE=${LOW_RATE:-2}
APPS_FILE=${APPS_FILE:-/data/adb/y700/vrr-apps.txt}   # 每行一个包名；没有这个文件就对所有应用生效
DIR=/data/adb/y700
LOG=$DIR/vrr-bridge.log
STATE=$DIR/vrr-held
mkdir -p $DIR
: > $STATE

log() { echo "$(date '+%m-%d %H:%M:%S') $*" >> "$LOG"; }
held() { cat $STATE 2>/dev/null; }
front() { dumpsys window 2>/dev/null | grep -m1 mCurrentFocus | sed -n 's/.* u0 \([^ /]*\)\/.*/\1/p'; }
hold() {
	[ "$(held)" = "$1" ] && return
	# 只在它确实是前台应用时才压，防止后台应用的请求把前台拖慢
	f=$(front)
	if [ -n "$f" ] && [ "$f" != "$1" ]; then log "ignore hold $1: front is $f"; return; fi
	service call oplusscreenmode 4 i32 1 i32 "$LOW_RATE" >/dev/null 2>&1
	echo "$1" > $STATE; log "hold $1 rate=$LOW_RATE"
}
release() {
	h=$(held); [ -n "$h" ] || return
	service call oplusscreenmode 4 i32 0 i32 "$LOW_RATE" >/dev/null 2>&1
	: > $STATE; log "release ($h) $1"
}
wanted() {
	[ -f "$APPS_FILE" ] || return 0
	grep -qx "$1" "$APPS_FILE"
}

log "start pid=$$ LOW_RATE=$LOW_RATE apps=$APPS_FILE"
# 看门狗：持有期间每 3 秒核对前台应用
(
	while :; do
		sleep 3
		h=$(held); [ -n "$h" ] || continue
		f=$(front)
		[ -n "$f" ] && [ "$f" != "$h" ] && release "watchdog: front is $f"
	done
) &

# 三类日志：setFrameRate 请求 / 应用切换 boost / 熄屏。
# logcat 的 -s 标签过滤不认 "VRR [OPlusRefreshRateService]" 这种带空格方括号的标签，所以用 grep（toybox grep 支持 --line-buffered）。
logcat -v brief -T 1 2>/dev/null | grep --line-buffered -E 'setFrameRate \[|Trigger app switch boost|handleScreenStateChange' | while IFS= read -r line; do
	case "$line" in
	*"setFrameRate [ "*)
		# ... setFrameRate [ 30.0 , <window> , <pkg> , <pid> ]
		rest=${line#*setFrameRate \[ }
		rate=${rest%%.*}; rate=${rate% }
		pkg=$(echo "$rest" | cut -d, -f3 | tr -d ' ')
		case "$rate" in
		''|*[!0-9]*) ;;                                   # 解析不出数字，忽略
		0) [ "$pkg" = "$(held)" ] && release "app cancelled" ;;   # 0 = 取消
		*) if [ "$rate" -le 30 ]; then wanted "$pkg" && hold "$pkg"
		   else [ "$pkg" = "$(held)" ] && release "app asked $rate"; fi ;;
		esac
		;;
	*"Trigger app switch boost"*)
		# ... ar=ActivityRecord{... u0 <pkg>/<activity> t..}
		pkg=${line#*u0 }; pkg=${pkg%%/*}
		h=$(held); [ -n "$h" ] && [ "$pkg" != "$h" ] && release "switched to $pkg"
		;;
	*"handleScreenStateChange"*"state: 1"*)
		release "screen off"
		;;
	esac
done
log "logcat ended, exit"

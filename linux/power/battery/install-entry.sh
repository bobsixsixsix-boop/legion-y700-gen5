#!/bin/sh
# 装「电池」入口（root，在这个目录里跑）：启动器、应用菜单项、桌面图标，和一条让 KDE 电量页最大化打开的 KWin 规则
# （kwinrulesrc 的 y700-battery-max，已有就不动；做法同 linux/carplay/livi/install-livi.sh）。只放文件，不起任何服务。
# 启动器打开我们自己的电池页 /usr/local/libexec/y700-battery-page（先跑 install.sh --page 装好：DESIGN.md 第 9 节第 6 步，
# 这里是第 7 步）；页面没装时、以及带 --kde（页面里「KDE 电量页 ›」那一行）时打开 KDE 电量页，KWin 规则就是留给它的。
# 换掉的旧启动器先存成 /root/y700-battery.bak-<时间>（内容一样就不存）：install.sh --rollback 从那里把入口还原成 KDE 电量页。
# 卸载：rm /usr/local/bin/y700-battery ~user/.local/share/applications/y700-battery.desktop ~user/Desktop/y700-battery.desktop；
# 规则在 系统设置 > 窗口规则 里删「电池页最大化（y700）」。
set -eu
cd "$(dirname "$0")"
[ "$(id -u)" = 0 ] || { echo "要 root"; exit 1; }
U=user
H=/home/$U
if [ -e /usr/local/bin/y700-battery ] && ! cmp -s y700-battery /usr/local/bin/y700-battery; then
    B=/root/y700-battery.bak-$(date +%Y%m%d-%H%M%S)
    cp -a /usr/local/bin/y700-battery "$B" || { echo "旧启动器没存下来，什么都没换"; exit 1; }
    echo "旧启动器存到了 $B"
fi
install -m 0755 y700-battery /usr/local/bin/y700-battery
install -d -o $U -g $U "$H/.local/share/applications"
install -m 0644 -o $U -g $U y700-battery.desktop "$H/.local/share/applications/y700-battery.desktop"
install -m 0755 -o $U -g $U y700-battery.desktop "$H/Desktop/y700-battery.desktop"   # 755：Plasma 才不问信不信任
RUN="runuser -u $U -- env LC_ALL=C.UTF-8 HOME=$H XDG_RUNTIME_DIR=/run/user/$(id -u $U) DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u $U)/bus"
RULE=y700-battery-max   # kcmshell6 opens the page as a 684x470 dialog in the middle of the screen
kwrule() { $RUN kwriteconfig6 --file kwinrulesrc --group "$1" --key "$2" "$3"; }
if [ "$($RUN kreadconfig6 --file kwinrulesrc --group $RULE --key wmclass)" != kcm_mobile_power ]; then
    kwrule $RULE Description "电池页最大化（y700）"
    kwrule $RULE maximizehoriz true; kwrule $RULE maximizehorizrule 3
    kwrule $RULE maximizevert true; kwrule $RULE maximizevertrule 3
    kwrule $RULE wmclass kcm_mobile_power; kwrule $RULE wmclassmatch 1; kwrule $RULE wmclasscomplete false
    have=$($RUN kreadconfig6 --file kwinrulesrc --group General --key rules)
    kwrule General rules "${have:+$have,}$RULE"
    kwrule General count "$(( $($RUN kreadconfig6 --file kwinrulesrc --group General --key count --default 0) + 1 ))"
    $RUN qdbus6 org.kde.KWin /KWin org.kde.KWin.reconfigure >/dev/null 2>&1 || echo "KWin 没连上，规则下次登录生效"
    echo "KWin 规则 $RULE 写好了"
else
    echo "KWin 规则 $RULE 已经在"
fi
sha256sum /usr/local/bin/y700-battery "$H/Desktop/y700-battery.desktop" | cut -c1-12,65-
[ -x /usr/local/libexec/y700-battery-page ] || echo "电池页还没装（install.sh --page）：入口先打开 KDE 电量页"
echo "装好了：桌面「电池」"

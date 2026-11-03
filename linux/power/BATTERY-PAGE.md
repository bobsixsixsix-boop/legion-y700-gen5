# 「电池」页（安卓 / iOS 那种用电统计）调研 — 2026-10-30

作者问：「安卓/ios 都有一个 电池/电量 的软件，统计用电情况你晓得吧。我们有类似的东西吗？」

**状态：作者 10-30 说「两档都做吧，闪电也修一下」。第 1 档和 ⚡ 已装（10-30 05:07，见 README「控制中心」第十六轮；文件在 `linux/power/battery/`）；第 2 档的记录器 10-30 08:10 已装、在记，报表和页面 10-30 写好、审过（28 条确认问题已修），20:15 已装、入口已换（胶囊和桌面「电池」开我们的页面；进度见 README「电池页第 2 档」），**定稿的实现规格在 [battery/DESIGN.md](battery/DESIGN.md)**（10-30 设计评审：3 方案 → 3 评委 → 合成 → 2 挑错，21 条问题逐条对过仓库后全部采纳，正文标「评审修订」）。**
做法：一路盘点仓库，一路查上游和生态，一路出设计，再各派一路反驳核对；关键事实在平板上只读核过（10-30 04:16、04:5x）。

## 结论

- **没有**安卓 / iOS 那种「按应用列出谁耗了多少电」的页面。
- **整个 Linux 圈子也没有**：KDE（T8908「按应用电池用量」2018 年开到现在，Needs Triage 无人负责）、GNOME Usage（2018 GSoC 的按应用功耗面板没合入）、Plasma Mobile、Phosh、postmarketOS、Ubuntu Touch、Sailfish 都只做到「电量（偶尔加功率）曲线 + 电池详情」，数据都取 UPower 历史。唯一的 Linux 系先例是 Tizen 的 Battery Monitor API（只在穿戴设备上，做法同安卓）。
- 安卓 / iOS 本身也不是逐应用实测，是「各部件使用时间 × 能耗系数 → 按比例分掉总放电」，结果是份额、是估算。

## 我们手上已有的零件

| 东西 | 显示什么 | 历史 | 按应用 | 用户看得到吗 |
|---|---|---|---|---|
| 状态栏电池图标（`linux/dock/y700-shellbar/src/status.cpp`） | 电量 %、充电变绿 | 无 | 否 | 是 |
| 控制中心顶部电量胶囊（`linux/controlpanel/y700-control-center/qml/Main.qml`） | 电量 % 和 ⚡ | 无 | 否 | 是 |
| 性能浮层采样器（`linux/games/hud/overlay/src/sampler.rs`） | 实时整机瓦数、充放电、PD/PPS | 无 | 内部已按进程算 GPU 忙时，只用来找 FPS，不输出 | 是（开浮层时） |
| 飞行记录器 `y700-flightrec`（`linux/power/flightrec/`） | 每 10 s 一行：电池 I×V、亮灭屏、CPU 忙、中断… | 留最近 12 次开机，约 2.5 MB/天 | 否 | 否（只有 ssh 读、Win11 上 `tools/fr-slice.py`） |
| `y700-powerwhy` / `y700-whoawake` / `y700-service-cost.sh` / `y700-wakeups` | 一个窗口内按进程或按 cgroup 的 CPU、GPU、唤醒 | 无 | 是（CPU/GPU 占用，不是电量） | 否（root 命令行） |
| UPower（系统自带） | 一直在记 `/var/lib/upower/history-{charge,rate}-*.dat` | 约 7 天 | 否 | 没有查看界面 |

## 上游现成的（判断）

| 选项 | 内容 | 本机 | 判断 |
|---|---|---|---|
| **Plasma Mobile「电源」页 `kcm_mobile_power`**（powerdevil 自带） | 设备列表；点电池进去：固定最近 24 h 电量曲线（`GetHistory("charge", 86400, 100)`）、健康度、厂商型号；三项熄屏/休眠超时（会改 powerdevil 配置，只看别改；11-01 补：`[AC]` 只写了「从不」没写秒数时，**一开页就把三档写成从不变暗、从不熄屏**，见 README「熄屏不锁屏」坑 2） | **已经装着**：`/usr/lib/aarch64-linux-gnu/qt6/plugins/plasma/kcms/systemsettings/kcm_mobile_power.so`（10-30 核过）；打开方式 `kcmshell6 kcm_mobile_power`（还没实际打开过） | 零安装可用，内容少（无功率曲线、范围不能选、无按应用） |
| **KDE 信息中心「能源」`kcm_energyinfo`**（包 `kinfocenter` 4:6.6.6，universe） | 电量 % 和功率两种曲线，1 h–7 天六档；详情含健康度、循环次数、温度 | 没装。要 `apt install --no-install-recommends kinfocenter`（不加会拉 aha、clinfo、vulkan-tools 等），约 5 MB，无常驻。6.6 装在 `plasma/kcms`，`kcmshell6 kcm_energyinfo` 能开；不会出现在 plasma-settings 的菜单里（json 没有 System-Settings 分类键）。6.6 曲线只取 100 个点（7 天档每点约 1.7 h），Canvas 画、没有触摸读数（master 才换 Qt Graphs） | 部分可用，比上一个多功率曲线和 7 天；同样无按应用 |
| GNOME Power Statistics | UPower 曲线 + 充放电统计 | GTK、非触摸 | 不推荐（数据同上，非 KDE 原生） |
| Mission Center 1.2（flatpak） | 按应用 CPU/内存/GPU 占用；新 Battery 页 | 未在骁龙上见实测；CPU 功耗曲线疑需 RAPL | 只是任务管理器，不是电池页 |
| PowerTOP 2.15（Ubuntu） | 按进程「Power est.」 | **在本机出不来**：2.15 不对 power_now 取绝对值，本机放电时 power_now 为负，永远攒不到样本（上游 8bc94ed 才修，Debian 未带）；无 RAPL、GPU 只认 i915；`--auto-tune` 绝对不能跑（会全开 runtime PM / USB autosuspend） | 不行 |
| powerstat、Plasma 系统监视器、PowerJoular、Scaphandre/Kepler 等 | 整机或 RAPL 口径 | 无 RAPL / 与已有工具重复 | 不行 |

## 平板上核过的事实（10-30，只读）

- `qcom-battmgr-bat` 有 `charge_counter`、`time_to_empty_avg`、`cycle_count`、`state_of_health`、`voltage_ocv`，没有 `voltage_*_design`（有 `voltage_max`）。`charge_counter` 是独立库仑计还是 SoC 换算，未核。
- UPower 给本机电池的 `energy-full-design` 随电压漂（10-30 读到 37.422 Wh；设计 9.0 Ah），历史文件名后缀 = 启动 upowerd 那一刻折出的整数 Wh（见过 -33 到 -40）。所以**官方曲线页的历史按后缀切成几段、不连续**（同后缀的不同次开机会混在一起），Wh 读数偏高，只有百分比可信。
  - 想补内核 `VOLTAGE_*_DESIGN` 把名字固定：会让 UPower 的 rate 变成 |I| × 固定电压，引入 5–15 % 系统误差——修一个坑造一个坑。更省事的是自己读所有后缀的 `.dat` 合并。
- `.dat` 是纯文本，一行「unix 时间 \t 值 \t 状态」。
- 用户 cgroup 开了 cpu 控制器，`app.slice` 下每个应用一个 scope / service，`cpu.stat` 有 `usage_usec`。scope 退出时 cgroup 被删，但父 slice 的累计不丢（内核释放前刷到父级），丢的只是「记到谁头上」。scope 至少四种命名：`app-y700-*`（dock 起的）、`app-<desktopid>-<n>.scope` / `app-<id>@<n>.service`（KDE 启动器）、`app-flatpak-<appid>-<pid>.scope`（flatpak 会把沙箱进程移进它自己的 scope，dock 那个很快空掉）、`app-steam-*.service`。
- msm 的 `/proc/PID/fdinfo` 有 `drm-engine-gpu`、`drm-cycles-gpu`、`drm-client-id`（同一 client 出现在多个 fd，要去重）。

## 如果要做：分档

1. **零成本**（半小时）：桌面图标 / 控制中心电量胶囊点进去 → 打开现成的 `kcm_mobile_power`（24 h 曲线、健康度），或装 `kinfocenter` 看功率和 7 天。无按应用。
2. **我们自己的电池页**（约 3–4 天）：口径「自上次充满 / 24 小时 / 7 天」：电量曲线标出亮屏段；屏幕、待机底噪、各应用（前台 / 后台时长、CPU、GPU、估算占电量 %）、系统界面、系统服务、其他 / 未归属。
   - 新常驻程序用 Rust（用户服务），只记原始累计增量，折算在打开页面时做（系数改了能回溯）。亮屏每分钟一次，熄屏零轮询（开关屏事件触发 + 稀疏检查点），估计远小于 1 mW；上线后用 `tools/y700-service-cost.sh` 实测。
   - **总量直接用飞行记录器现成的 10 s 电池读数**（`/run/y700-flightrec/live.log` 0644），不自己另读：每 60 s 读一个点的误差实测很大（拿 `runs/diag/flightrec/flightrec-690a169c.log.gz` 的 1 s 数据下采样：单窗口亮屏 p90 68 %、熄屏最大 372 %）；熄屏也不能拿一个瞬时读数乘 30 分钟。
   - 前台时长复用 `y700-refresh-auto` 的 KWin 脚本（每次窗口激活已经 `callDBus fyi.y700.RefreshAuto activeWindow(cls,covers,pid)`），不新加脚本。Rust 侧 D-Bus：universe 有 zbus 5.13 / dbus 0.9.7，平板都没装（zbus 连带 303 个包），`linux/display/autobright/src/dbus.rs` 是只依赖 libc 的最小客户端，可以扩展。
   - **熄屏时后台应用的主要代价是唤醒**（让 SoC 进不了深睡），不是 CPU 秒：README「底噪研究」里 ss3 驻留随全系统唤醒率从 69 % 掉到 9 %，Claude 熄屏只占 0.72 % CPU 却有约 13 次唤醒/s。只按 CPU 时间分账会把熄屏耗电全塞进「其他」，要加按唤醒率分摊，用 powerbench J 态（冻结应用）那种 A/B 标定。
   - 系数：背光整体约 0.83 mW/级（按 README「续航」第二次实测 1/10/50/100 % → 1.13/1.38/2.75/4.50 W 分段取，第一次的 0.78 被 120 Hz 污染）；亮屏额外约 0.5–0.7 W（y7/y9 配对）；亮屏段底噪用旋钮全关的约 0.33 W，不是 E3a 的 0.24–0.31；刷新率约 6.7 mW/Hz 只是量级；扬声器没有单独实测。**都要在现役 y15 上重测**。CPU / GPU 各频点功耗本机没有分项实测，要一次约 40 分钟的无人值守标定（熄屏、电池、作者不用、不 ssh）。
   - 时间基准：开机早期 RTC 从 1970 起，NTP 同步后才对；账本用 boot_id + 单调时钟，等同步后再换算墙钟。
   - 诚实精度：总量和屏幕比较准；各应用只能看排序和量级（±30–50 %）；Wi‑Fi、音频、合成器（KWin，单列「系统界面」）只能粗分；蓝牙、传感器、ADSP 进「其他」。
3. **补精度**（先不做）：内核给刷新率加驻留计数、eBPF 按 cgroup×簇×频点记 CPU（安卓 time_in_state 的做法）、按应用分 Wi‑Fi 流量 / 扬声器。等第 2 档跑一两周看「其他」有多大再挑。

## 入口

控制中心顶部的电量胶囊（10-30 起点得动，现在开的是 KDE 电量页）点了收帘、打开电池页（和安卓 / iOS「点电量进电池页」的肌肉记忆一致；属于跳转，不违反「操作不收起面板」）；另放桌面图标。不放状态栏小图标（太小、和下拉手势冲突），不做常驻浮层（会把面板钉在 120 Hz）。

## 顺带发现

- 控制中心电量胶囊的 ⚡ 判据是 `InputCurrentMa > 0`（`backend.cpp` 约 371–374 行），PPS 电荷泵快充时 USB `current_now` 读 0，**快充时不显示 ⚡**。10-30 已修：改按电池 `Status`（Charging / Full / Not charging），USB 电流留作兜底，见 README「控制中心」第十六轮。
- README 约 396 行「power_now 固件值不可信」只适用于 y3 之前的内核；现役内核的 `power_now` 已一律按 I×V 算（`linux/kernel-y15/patches/00y2-…` 73–84 行）。

## 第 2 档开工前的只读预检（10-30 05:18，熄屏、放电 79 %，没在测量）

- **`charge_counter` 不是库仑计**：放电 70–107 mA 的 60 s 里（2 s 一读，30 次）一直是 6678000（≈ 电量 % × `charge_full`），连续放电本该少约 1300 µAh。**不用它**，总量照旧用 I×V。`current_now` 每 4–6 s 才变一次（和飞行记录器里写的「5–8 s」一致）。
- **systemd 用户管理器在 scope / service 退出时记一行**「`app-com.google.Chrome-296351.scope: Consumed 2.879s CPU time over 11min …`」（2 天 77 行）：两次快照之间就退出的应用，CPU 时间能从这里补回来。
- **cgroup**：`user@1000.service` 的子树开了 cpu 控制器，`app.slice` 往下只开 memory / pids，但 v2 每个 cgroup 都有 `cpu.stat` 的 `usage_usec`（rstat），`user` 读得到。当时的总账（开机 28.6 h）：根 19569 s CPU，`user.slice` 12259 s，`system.slice` 3428 s，`init.scope` 39 s，其余约 3843 s 是内核线程和中断（不在任何 cgroup 里）。`app.slice` 下除了应用（`app-com.anthropic.Claude-16803.scope`、`app-flatpak-org.telegram.desktop-<n>.scope`、`app-steam-*.service`、`app-geoclue\x2ddemo\x2dagent@autostart.service`）**还有我们自己的服务**（`y700-control-center` / `y700-shellbar` / `y700-refresh-auto` / `y700-autobright` 等 `.service`）；KWin、plasmashell、pipewire 在 `session.slice`（`plasma-kwin_wayland.service` 等），powerdevil 在 `background.slice`。
- **GPU（msm fdinfo）**：每个客户端有 `drm-engine-gpu`（ns）、`drm-cycles-gpu`、`drm-maxfreq-gpu`（1.2 GHz）和显存。cycles / engine 折出的平均频率 KWin 205、Telegram 407、Claude 211、steamwebhelper 260、Xwayland 236 MHz，都落在 160–1200 MHz 里，可用。同一进程常有多个客户端（多数是 0）。**`user` 读不到 `kwin_wayland` 的 fdinfo**：KWin 带 `cap_sys_nice`，进程不可 dump，同用户也读不了（plasmashell 等都读得到）。KWin 开机以来 GPU 忙 1167 s（28.6 h 的 1.1 %），量很小。
- 没有 `/proc/PID/schedstat`（内核没开 schedstats）；每个线程的 `/proc/PID/task/TID/status` 有 `voluntary_ctxt_switches`，可以当唤醒次数的代理。GPU devfreq 有 `trans_stat`（各频点驻留时间），cpufreq 两个 policy（cpu0–5、cpu6–7）有 `stats/time_in_state`。
- **飞行记录器**：`/run/y700-flightrec/live.log` 0644，`user` 读得到（1.6 MB、5202 行约 14 h，到 2 MiB 截短）；`/var/log/y700-flightrec/*.log` 是 0600 root，`user` 读不到。熄屏也照样每 10 s 一行（`bat=`、`dpms=`）。
- **开关屏没有现成的 D-Bus 信号**：`org.kde.Solid.PowerManagement` 下的 Actions 只有 BrightnessControl / HandleButtonEvents / PowerProfile / ScreenBrightnessControl / SuspendSession，没有 DPMSControl；屏保只有 `ActiveChanged`（锁屏）。sysfs：`/sys/class/drm/card1-DSI-1/dpms`（`On` / `Off`），背光 `/sys/class/backlight/aw99706-backlight`（0–4095，当时 332；熄屏 `bl_power=4`）。
- UPower 历史 0644，后缀 33–40 加无后缀一个，10-11 到 10-30 都在。
- `y700-refresh-auto` 是 Python（RSS 37 MB），状态里 `active: ["plasmashell", true, 3315]`。
- 平板工具链：cargo / rustc 1.93.1，离线库 208 个（有 libc 0.2.178、serde、serde_json 1.0.145）。Qt QML 有 QtQuick.Shapes / Controls / Layouts / Effects，**没有 QtCharts / QtGraphs**（曲线用 Shapes 或 Canvas 自己画）。Win11 上没有 cargo：Rust 只能在平板上编、跑测试。

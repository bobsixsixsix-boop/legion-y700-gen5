# 熄屏唤醒治理：把每秒 300 次唤醒压到 50 次以下 —— 名单、修法、预期

> 状态：**2026-10-16 凌晨写成，全部只读研究（本仓库、上游源码公开副本），没碰平板、没编译、没跑任何实验。** 本文里的每一个"修法"都还没在平板上执行；每一个"预期"都是模型推算，等 `y700-wakeups` 实测后要回来改数字。
> 复核（2026-10-16 第二遍，仍是只读）：helper 补丁 `git apply --check` 重新通过、它调用的 `sys::path/list_dir/read_opt` 都在；解析器用内核真实输出格式（含 `record-tgid` 列、带连字符的 comm、IPI/csd 字段）的合成 trace 跑通；PowerDevil / libddcutil / tailscale 的源码结论逐条重读。**改了两处事实**：tailscaled 的 portlist 在 Linux 上是 **1 s** 一次不是 5 s（`portlist_linux.go` 的 `init()`）；memlat 的 devfreq 监视器是 **deferrable** 定时器，自己不叫醒空闲核，能算的只剩 11 次 mbox 中断/s。tick 的 hrtimer 回调在 7.x 叫 `tick_nohz_handler`（6.9–6.x `tick_nohz_highres_handler`，更早 `tick_sched_timer`），工具三个名字都认。
> 复核（2026-10-16 第三遍，独立审稿，仍只读）：逐条重取源码对照，**改了四处**：(1) `TS_DEBUG_DISABLE_PORTLIST` 并非"ticker 照样响"——`runPollLoop` 在 `Poll()` 出错时 `return` 并停掉 ticker，只是走错误路径，`TS_PORTLIST=false` 仍是正解；(2) `/sys/class/devfreq/ddr/timer` 只打印 `deferrable`，不是 `[deferrable] delayed`；(3) 15 个 NTC 通道里带 `qcom,adc-tm` 的是 14 个，`xo_therm` 没有；(4) `y700-wakeups` 的 IPI 命名改为读 `/sys/kernel/irq/<N>/actions`——原来按 trace 里出现过的 IPI 序号推，窗口里没出现 IPI0 时每一行都会错位。其余（portlist 1 s、PowerDevil/libddcutil 链条、thermal_of 缺省取 0、`tick_nohz_handler`、netmon 15 s、STUN 45 s 停、helper 补丁 apply --check、`read_opt` 有 trim）核对无误。
> 读者：作者，以及接手"熄屏不休眠 0.42 W 还能不能再降"的下一个工程师。先读 [cx-collapse/RESEARCH.md](cx-collapse/RESEARCH.md) §1.4 和 §3.7，本文是它说的"并行的零风险工作"的具体施工图。
> 出处约定：补丁号指 `linux/tb323fu-linux/kernel/patches/NNNN-*.patch`；上游源码行号指 2026-10-16 读到的公开副本（版本在正文标明）。lore/patchwork 有反爬页面，没有绕过，没读到的地方写明"未读"。

## 0. 一页纸

1. **为什么要管唤醒**：熄屏 0.42 W 的大头是 SoC 醒着的底噪（簇/系统域下电被 0106/0118 有意关掉）。RESEARCH §1.4 的模型：系统级 ss3 的驻留率由全系统的唤醒率决定——**300 次/秒时只有 9%，50 次/秒才有 69%**。所以哪天 ss3 放开了，收益是 0.03 W 还是 0.2 W，取决于今天把唤醒率治到多少。**今天 ss3 还关着，这里的任何改动对功耗表都不会有可测的变化（<0.03 W 噪声）**——这是为 E3 实验铺路，不是省电本身；别指望 offbench 给出奖励。
2. **现状（y9，熄屏，README 续航第三轮 + 零风险 A/B 段）**：idle 进入 285 次/秒；中断 300–400/秒（`arch_timer` 160、IPI1 86、`apss_cpucp_mbox` 11、`ce2` 约 40）；上下文切换 409/秒。按线程（`y700-whoawake` 数的是上下文切换，不完全等于唤醒，见 §1）：tailscaled 约 35、Claude 桌面版 22、PowerDevil 线程 `display_recheck` 10、tb323fu-helperd 7+3（5 s 轮询）、`kworker/0:0-events` 17、`kworker/u33:17-async` 11、pipewire 4+3。**10-19 核对（X16）：285 = 10-15 whoawake 的 idle 进入/s（中断另为 300–400/s）；10-16 `y700-wakeups` 首测基线为 idle 退出 467/s、IRQ 552/s（装前；装后数据被 ssh 轮询抬高不可用，README「熄屏唤醒治理」10-16 04:00 首测条）；两工具口径不同（whoawake 读 sysfs usage 计数 `tools/y700-whoawake.py:93-95`，wakeups 读 tracefs cpu_idle 退出 `tools/y700-wakeups.py:364-367`），不可直接相减；§3 模型表按 467 重算待做（本轮只加注）。**
3. **已经查到根因、有现成修法的**：

   | 谁 | 实测 | 根因（出处见各节） | 修法 | 代价 |
   |---|---|---|---|---|
   | PowerDevil `display_recheck` | 10/s | libddcutil 2.2.5 的 `display_recheck_thread`：`g_async_queue_timeout_pop(queue, 100 ms)` 空转，PowerDevil 启动时无条件 `ddca_start_watch_displays()`；这台机的屏是 DSI，根本没有 DDC/CI | 用户单元 drop-in `Environment=POWERDEVIL_NO_DDCUTIL=1`（PowerDevil 自己的开关） | 外接 USB‑C DP 显示器失去 DDC 亮度控制 |
   | tb323fu-helperd | 7+3/s | 主循环和 LED 环线程各自每 5 s 醒一次，每次读一遍电池属性（每个属性一次 glink 往返） | 树外补丁 [helperd-slow-poll.patch](helperd-slow-poll.patch)：`[poller] poll_s_display_off = 30`，熄屏时两个线程都按它睡 | 熄屏时插拔充电器的 PropertiesChanged 最多迟 30 s |
   | tailscaled | ≈35/s | 周期性的只有 portlist **每 1 s** 扫一遍监听端口（Linux 的 `init()` 把通用的 5 s 改成 1 s；四次 netlink `inet_diag` 查询，有新 socket 时再遍历 `/proc/*/fd`）、netmon 15 s 看墙钟、DERP 60 s keepalive；STUN/心跳在无流量 45 s 后已自动停。35/s 的大头很可能就是这每秒一簇的 goroutine 交接（算作上下文切换），加上测量时若 ssh 走的是 tailnet，它自己的流量 | 系统单元 drop-in `TS_PORTLIST=false`（[tailscaled-wakeups.conf](tailscaled-wakeups.conf)） | 管理台看不到这台机的 "Services" 列 |
   | Claude 桌面版 / Chrome | 22/s | Electron/Chromium 后台定时器；官方应用改不了 | 可选的用户服务 [y700-screen-off-freeze](y700-screen-off-freeze)：熄屏 60 s 后 cgroup 冻结，亮屏即解冻；永不冻 Telegram，永不冻正在播放的 MPRIS 播放器 | **冻住 Claude 桌面版等于冻住里面跑着的 agent 会话**；实测只省 0.01 W |
   | 内核 memlat 统计回读 | 11 次 `apss_cpucp_mbox` 中断/s（3 个 `devfreq_monitor` 定时器是 deferrable，不独立叫醒空闲核） | `polling_interval=1000`（我们自己从 2 ms 改来的；0126 的缺省是 `cpucp_sample_ms/2`，没设 `profile.timer`） | udev 规则改 10000 或 0（同时改体检脚本的期望值） | `trans_stat` 变粗/不更新；`cur_freq` 仍是现查 |
   | 软锁死看门狗 | 2/s | 每核一个 hrtimer，`watchdog_thresh=10` → 4 s | `sysctl kernel.watchdog_thresh=60` → 0.33/s | 软锁死要 120 s 才报 |
   | 板温 quiet-thermal | 1/s + 1 次 ADC 中断 | 0108 只给 quiet-thermal 设了 `polling-delay = 1000`。**任务书里"15 个 NTC 区都在轮询"是错的**：`baldur-adc.dtsi` 的 `BALDUR_NTC_ZONE` 宏没有 polling 属性（不轮询；14 个通道带 `qcom,adc-tm` 靠阈值中断，`xo_therm` 连阈值中断也没有），SoC 的 55 个 tsens 区也没有 | 留着；要动只能在 y10 的 DT 把它改成 2–5 s | 皮肤限频反应慢几秒 |

4. **还不知道、要靶子工具（§1 的 `y700-wakeups`）才能定的**：`kworker/0:0-events` 17/s 跑的是什么 work（PSI？电池？）、`kworker/u33:17-async` 11/s 的 `async_schedule()` 来自哪个驱动、`ce2` 40/s 是 Wi‑Fi 固件的 WMI 事件还是局域网的广播流量、`rtc@6100` 每 25 s 一次的闹钟是谁设的（10-16 补：更可能是失败的 `rtc_set_time()`，见 ALWAYS-ON.md §5b，待 `--rtc 90` 定案）、IPI1 86/s 里多少是远程唤醒（`ttwu_queue_wakelist`）多少是 JIT 的 `membarrier`。
5. **预期**（§3）：名单里能确定的用户态项修完，全系统约 285 → 200 次/秒，模型驻留率 10% → 21%；再把内核侧的 memlat/看门狗处理掉约 190–215，PSI 若真有十几次/秒再降到 180 上下；要到 50 以下，必须解决 §0.4 里那几个未知项。**功耗方面今天为零**，ss3 放开后对应 0.42 → 0.35–0.37 W（模型，地板 0.10–0.20 W 两种假设）。**10-19 核对（X16）：这里的 285 是 10-15 whoawake 口径；按 10-16 `y700-wakeups` 的 idle 退出 467/s 基线，这些预期数字要整体重算（未做）。**

## 1. 先量再改：`y700-wakeups`

`tools/y700-wakeups.py`（平板装到 `/usr/local/bin/y700-wakeups`，root）。和 `y700-whoawake` 的区别：whoawake 数的是每个线程的**上下文切换**增量——一个每 5 s 醒一次、每次交接 30 下的 Go 程序会显示 6/s，看起来像 6 次唤醒；而唤醒率模型关心的是"CPU 从 idle 被叫起来多少次、被谁叫"。`y700-wakeups` 用 tracefs 的事件（只开事件，不开函数跟踪；熄屏空闲时每秒约一两千条，开销可忽略）记录一个窗口：

| 事件 | 回答什么 |
|---|---|
| `timer:hrtimer_expire_entry` | 哪些 hrtimer 回调在响：`tick_nohz_handler`（忙核的调度 tick；6.9 前叫 `tick_sched_timer`）、`hrtimer_wakeup`（某线程自己的 nanosleep/poll/epoll/futex 超时）、`watchdog_timer_fn`、`timerfd_tmrproc`… |
| `timer:timer_expire_entry` | 低精度定时器：`delayed_work_timer_fn`（延迟 work）、`process_timeout`（内核线程的 schedule_timeout）、网络栈定时器 |
| `irq:irq_handler_entry` | 硬件中断按名字（`arch_timer`、`IPI`、`ce2`、`apss_cpucp_mbox`、RTC…），每个落在哪个核 |
| `ipi:ipi_send_cpu/_cpumask`、`ipi:ipi_raise`、`csd:csd_queue_cpu` | 谁发 IPI（调用点）、为什么（reason）、跨核函数调用的函数名（`flush_tlb_*`、`ipi_sync_core` = membarrier…）；本内核 `CONFIG_HAVE_EXTRA_IPI_TRACEPOINTS=y`，三组都有 |
| `sched:sched_waking` | 谁叫醒谁：唤醒者是那条 trace 行的任务，或——在中断/软中断上下文里——同一个核上刚发生的中断/定时器；被叫醒者是 comm/pid，事后解析成进程 |
| `workqueue:workqueue_execute_start` | kworker 到底在跑哪个 work 函数（psi_avgs_work、devfreq_monitor、thermal_zone_device_check…） |
| `power:cpu_idle` | 每个核的 idle 退出次数——分母 |

用法：

```sh
# 基线：熄屏（kscreen-doctor --dpms off，等 20 s 让 HUD 采样器退出），录 60 s，留下原始 trace
systemd-run --unit y700-wakeups --collect --wait -p StandardOutput=file:/var/log/y700-wakeups-$(date +%m%d-%H%M).txt \
    y700-wakeups 60 --off --save /var/log/y700-wakeups-$(date +%m%d-%H%M).trace --timer-list
# 改完一项，同样的命令再录一次，比 "wakeups/s by woken process" 和 "idle exits/s per CPU" 两张表
# 离线复看（Win11 上也行，不用 root）：python tools/y700-wakeups.py --parse xxx.trace
```

规矩：**用 `systemd-run` 跑、从局域网地址（192.168.x / USB）上去，别从 tailnet 上去**——否则 tailscaled 处理的是测量会话自己的 ssh 包，名单第一名就是你自己。输出里的 `packets wlp1s0:rx N/s` 用来核对窗口里有没有流量。它写过的东西（事件开关、`tracing_on`、`buffer_size_kb`、`saved_cmdlines_size`）都在退出时还原，SIGINT/SIGTERM 也还原；`--probe-async` 是唯一超出"纯 tracepoint"的选项（在 `async_schedule_node_domain` 上放一个 kprobe 读函数参数，退出时删除），默认不开。不读任何寄存器类 debugfs。

读表的几个要点：`hrtimer:hrtimer_wakeup → 进程` 一表就是"谁的定时器把自己叫醒"的名单；`wakeups/s by woken process` 的 "active seconds / max per second" 两列区分**稠密**（Claude 每秒都醒）和**突发**（5 s 轮询：60 s 窗口里只有 12 个活跃秒）；`arch_timer` 的次数应约等于落在空闲核上的 hrtimer 到期次数；"likely owners" 一节把看到的名字对应到本机已知的来源，没对应上的就是新发现。

## 2. 逐项

### 2.1 PowerDevil 的 `display_recheck`（10/s）——libddcutil 的空转线程

**查到的链条**（全部来自公开源码，版本与平板一致：`powerdevil 4:6.6.6-0ubuntu0.1`、`libddcutil5 2.2.5-1`，见 `linux/kernel-y8/inventory/packages`）：

- PowerDevil 6.6 `daemon/controllers/ddcutildetector.cpp`（KDE/powerdevil 分支 Plasma/6.6）：`DDCutilPrivateSingleton` 构造时 `m_noDdcutil = qEnvironmentVariableIntValue("POWERDEVIL_NO_DDCUTIL") > 0;`，不为真就 `ddca_init2(...)`，注册回调，然后在构造函数末尾 `ddca_start_watch_displays(DDCA_Display_Event_Class(DDCA_EVENT_CLASS_ALL))`——**不看有没有找到任何 DDC 显示器**（只有变量为真、`ddca_init2` 失败、回调注册失败三种情况提前返回；检测本身在之后的 `detect()` 里）。它自己不开线程（只有一个 `QMutex`）；`ddcutildisplay.cpp` 的定时器全是单次的（1/2/3 s 退避重试、1 s 写亮度去抖），没有显示器时一个都不会启动。
- libddcutil 2.2.5 `src/dw/dw_main.c`：`dw_start_watch_displays()` 起监视线程 `watch_displays` 的同时再起一个 `recheck_thread = g_thread_new("display_recheck_thread", dw_recheck_displays_func, rdd)`（条件和监视线程相同：显示适配器都走 DRM、watch 没关、事件类含 DPMS 或 CONNECTION——PowerDevil 传的是 ALL；Linux 线程名截到 15 字符就是 `display_recheck`）。`src/dw/dw_recheck.c` 里这个线程的循环：`while (!terminate_watch_thread) { ... while (!rqe && !terminate_watch_thread) { rqe = g_async_queue_timeout_pop(recheck_queue, pop_interval_micros); } ... }`，`pop_interval_millis = 100`、`sleep_interval_millis = 200`——队列永远是空的（本机没有任何 I2C 显示器），内层循环永不退出，200 ms 的睡眠（在外层循环开头，源码注释 `// move to end of loop`）只在线程启动时跑一次，于是**每 100 ms 醒一次，永远**。2.2.0 的 CHANGELOG 把它描述为"EDID 能读但 DDC 还没就绪的显示器进 recheck 队列，由单独线程处理"。监视线程 `watch_displays` 自己也按 `dw_calc_watch_loop_millisec()` 的间隔轮询（`parms.h` 的缺省是 500 ms 级；`dw_main.c` 里 udev 间隔已被注释掉、用的是 poll 间隔，`dw_poll.c` 本次未读），估计再加约 2/s。
- 所以这 10/s（加上 udev 线程的 2/s）是在一台**只有 DSI 面板、不可能有 DDC/CI** 的平板上，为不存在的显示器空转。

**修法**：PowerDevil 自己的开关 `POWERDEVIL_NO_DDCUTIL=1`（源码就在 `ddcutildetector.cpp` 的单例构造函数里；PowerDevil README 也写着"可以只禁用它对 ddcutil 的使用：定义 `POWERDEVIL_NO_DDCUTIL=1`，除了没有 DDC/CI 亮度控制，系统照常"）。放进用户单元的 drop-in——PowerDevil 是 `plasma-powerdevil.service`（`daemon/plasma-powerdevil.service.in`：`Type=dbus`、`BusName=org.kde.Solid.PowerManagement`、`PartOf=graphical-session.target`），README 推荐的就是 `systemctl --user edit plasma-powerdevil.service`：

```ini
# ~/.config/systemd/user/plasma-powerdevil.service.d/y700-no-ddcutil.conf  （仓库：plasma-powerdevil-no-ddcutil.conf）
[Service]
Environment=POWERDEVIL_NO_DDCUTIL=1
```

安装：`linux/power/install-wakeups.sh --powerdevil`（装 drop-in、`systemctl --user daemon-reload`、重启 `plasma-powerdevil.service`、在 `/proc/<pid>/environ` 里核对变量、数 `display_recheck` 线程应为 0）。另一条路 `~/.config/plasma-workspace/env/*.sh` 里 `export POWERDEVIL_NO_DDCUTIL=1`：startplasma 的 `runEnvironmentScripts()` 会把它注入进程环境再 `syncDBusEnvironment()` 同步给 systemd 用户实例——理论上也到得了，但多一层间接且下次登录才生效，不如 drop-in 直接、可当场核对；不选。

**代价**：外接显示器（USB‑C DP）的 DDC/CI 亮度调节没有了。内置面板的亮度走 KWin → backlight class（aw99706），不受影响。重启 PowerDevil 的几秒内亮度键/电源键动作不响应。

**预期**：−10（recheck）−2（udev 循环）≈ −12 次/秒。体检：drop-in 在而进程环境里没有变量 → WARN（`y700-checklist`）。

### 2.2 tb323fu-helperd 的 5 s 轮询（7+3/s）——树外补丁

**它在做什么**（`helper/crates/tb323fu-helperd/src/main.rs:582-627`，上游 0c7c0c4）：主循环每 `Duration::from_secs(5)` 一轮：`profile_tick`（GPU/CPU 限频、热配置、Wi‑Fi 省电跟随 ppd）、`panel_tick`（面板过热限亮度）、`haptics_tick`、`full_by_tick`（读电池）、USB wake 复位，然后对**每个** D-Bus 对象做一次 `watch::<T>()`——取属性快照比对、变了就发 `PropertiesChanged`；Battery 的快照要读 `status/capacity/current_now/voltage_now/temp/...`，**每个属性都是一次到 ADSP 的 glink 往返**（RESEARCH §3.4 对飞行记录器的同一条修正），每次往返一睡一醒，所以一轮 5 s 的轮询在 whoawake 里是 35 次上下文切换 = 7/s。另一个线程是 LED 环（`led.rs`）：`const IDLE = 5 s`，每 5 s 重读一次 `battery_info()` 决定充电指示色（屏幕关着没人看），3/s 就是它。

**补丁** [helperd-slow-poll.patch](helperd-slow-poll.patch)（对仓库副本 `linux/tb323fu-linux` 的 `helper/`，`git apply --check` 通过；**没编译**——本机没有 cargo，规则也不许在这里构建）：

- `config.rs`：新增 `[poller]` 段 `poll_s = 5`、`poll_s_display_off = 30`（serde default：旧的 helper.toml 照常加载，下次保存时写出新段）。
- `features.rs`：`display_off() -> Option<bool>`——只看 `/sys/class/drm/card*-DSI-*` 里 `status == connected` 的接口的 `dpms`（断开的 DP 和 Writeback 接口永远报 On，自动亮度当年就栽在这里）。
- `main.rs` 循环末尾：面板关着就睡 `poll_s_display_off`，否则 `poll_s`。
- `led.rs`：去掉 `const IDLE`，改成按同一配置算的 `idle_wait(&cfg)`，充电色重读和 condvar 等待都用它。
- `data/helper.toml.example`：写上两个键。

**构建与安装（平板上做，补丁头里有完整命令）**：`apt install cargo rustc`（Rust ≥ 1.80，helper/README.md）→ 在 `/usr/local/src/tb323fu-linux` 打补丁 → `cd helper && cargo build --release -p tb323fu-helperd`（workspace 排除了 GTK 设置应用，不需要 GTK 开发库）→ 二进制装到 `/usr/local/libexec/tb323fu-helperd` → **不要跑 install.sh**：平板上的 helper 是 dpkg 包 `tb323fu-helper 0.4.1`（`/usr/libexec/tb323fu-helperd`、`/usr/lib/systemd/system/tb323fu-helperd.service`），用 drop-in `/etc/systemd/system/tb323fu-helperd.service.d/y700-local.conf` 把 `ExecStart` 指到我们的二进制即可，包升级不会覆盖 drop-in；helper 的自更新对 dpkg 安装的实例本来就拒绝。然后 `/etc/tb323fu/helper.toml` 里把 `poll_s_display_off` 改 60 也行，`tb323fu-ctl reload`。

**副作用**：熄屏期间插拔充电器，`PropertiesChanged`/LED 充电色最多迟 `poll_s_display_off` 秒；`wifi_tick` 的"每 12 轮复查一次性能档 Wi‑Fi 省电"变成每 6 分钟（熄屏跑性能档本来就不常见）；内核自动检查按时间判断，不受影响。亮屏时行为完全不变。

**预期**：10/s → 约 1.7/s（两个线程各 30 s 一轮）；设 60 则 0.8/s。周期性义务：`tb323fu-helper` 包升级后要重打补丁重编（体检：drop-in 在、运行中的 `/proc/<pid>/exe` 不在 `/usr/local/libexec` → WARN；包版本变化 → CHANGED 提示重编）。

### 2.3 Claude 桌面版 / Chrome（22/s）——熄屏冻结服务（可选）

> 10-19 括注（X15）：22/s 为 10-15 whoawake 整程序唤醒（插电）；10-16 `y700-wakeups` 的 9.6/s 只数自身定时器超时；10-18 的 120/s 是重启后 VizCompositorThread 单线程空转的故障态；三者均为 BFS 开关（10-18）装前数据，装后整程序唤醒未复测。

**先说清楚它不是为了省电**：README 第二次实测 I/J 档，熄屏 0.59 W vs 熄屏 + 冻结全部桌面应用 0.58 W，**0.01 W，在噪声里**；当时的结论是"不做常驻功能"。现在做它只有一个理由：Claude 桌面版熄屏后仍每秒醒 22 次（且是稠密的，每秒都有），Chrome 的后台定时器也在，这两个占了用户态唤醒的大头，是 §3 模型里 300 → 50 的必经之路。官方应用改不了（Electron 没有"屏幕关了就停定时器"的开关；Chromium 对后台标签的定时器节流是 1 Hz 一档，而且 Claude 是前台窗口），所以用 cgroup freezer。

**设计**（[y700-screen-off-freeze](y700-screen-off-freeze) + [y700-screen-off-freeze.service](y700-screen-off-freeze.service)，用户服务，`WantedBy=graphical-session.target`，和控制中心同一套路）：

- 每 2 s 读一次 `/sys/class/drm/card*-DSI-*/{status,dpms}`（只看 connected 的接口）；面板连续 Off 满 `DELAY`（默认 60 s，电源键开关屏的短暂熄屏不触发）才冻结；面板 On 立刻解冻（冻着的时候 1 s 轮询一次，所以亮屏最多黑 1 s）。没用 KWin/PowerDevil 的 D-Bus 信号：Plasma 6.6 没有稳定的"DPMS 变了"信号，sysfs 轮询和浮层、自动亮度用的是同一个判据。
- 对象：`systemctl --user list-units --type=scope,service` 里 `app-*` 开头、名字含 `MATCH`（默认 `claude,chrome`，大小写不敏感；平板上的桌面文件是 `com.anthropic.Claude.desktop`、`claude-code.desktop`、`google-chrome.desktop`——**注意 `claude` 也会命中 `claude-code.desktop` 的单元，冻住它就是冻住正在干活的 Claude Code；只想冻桌面版就把 MATCH 写成 `com.anthropic.claude,chrome`**；Plasma 启动的应用各在自己的 `app-<desktop 文件名>@<id>.service` 或 `.scope` 里，powerbench 的 J 档就是这样枚举的）的单元；**排除**含 `NEVER`（默认 `telegram`）的；**排除**拥有 `org.mpris.MediaPlayer2.*` 总线名且 `PlaybackStatus == Playing` 的单元（`busctl --user list --json=short` 直接给出每个总线名所属的单元；Chrome 放视频/音乐时继续放）。
- `systemctl --user freeze <unit>`（cgroup v2 的 `cgroup.freeze`，systemd 原生支持），只冻 `FreezerState == running` 的；冻过的单元记在 `$XDG_RUNTIME_DIR/y700-screen-off-freeze.frozen`，解冻只解自己冻过的；服务启动时先解冻上次残留、`ExecStopPost=… --thaw` 兜底，所以服务崩了或被停了都不会留下冻住的应用。
- `--list` 先看会冻谁，`--status`、`--thaw` 手动操作。配置 `~/.config/y700-screen-off-freeze.conf`：`MATCH`、`NEVER`、`DELAY`、`POLL`。

**作者必须知道的代价**：**Claude 桌面版被冻住，里面跑着的 agent 会话也停了**——作者让 Claude 干活时如果顺手熄了屏，60 s 后任务就停在那里，亮屏才继续。所以默认不装（`install-wakeups.sh --freeze` 才装），或者把 `MATCH` 改成只有 `chrome`。其它已知后果：冻住的 Chrome 窗口亮屏后 1 s 内恢复；Chrome 下载会停；没有 MPRIS 的网页音频（极少）会停；xdg-desktop-portal 若正等着冻住的应用回话会一直等（没见过，记一下）。

**预期**：−22（Claude）− Chrome 的部分（未测）。

### 2.4 tailscaled（≈35/s）——周期性的其实不多，突发才是大头

**读源码（tailscale v1.104.1，与平板同版）得到的空闲时定时器清单**：

| 来源 | 周期 | 空闲时是否在跑 | 出处 |
|---|---|---|---|
| portlist：扫本机监听端口，上报管理台 "Services" | **1 s**（`portlist_linux.go` 的 `init()`：`pollInterval = 1 * time.Second`，注释 "Refresh service discovery once per second"；`poller.go` 的 5 s 只是通用缺省，上一稿写成 5 s 是错的） | **是**，`feature/portlist/portlist.go` 的 `runPollLoop` 用 `NewTicker(portlist.PollInterval())` 永远在转；`shouldUploadServices` 为假（ShieldsUp 或管理台关了 Collect services）时只是 `continue`，ticker 照响；一次 poll 走 netlink `inet_diag` 查 TCP_LISTEN（失败则重读 `/proc/net/tcp*`、`udp*`），新 socket 还要遍历 `/proc/*/fd` 找进程名 | `portlist/poller.go`、`portlist_linux.go` |
| netmon 墙钟检查（防睡醒没通知） | 15 s（`pollWallTimeInterval`） | 是（只在 Android/iOS/Plan 9 关） | `net/netmon/netmon.go` |
| 周期性 STUN（保 NAT 映射） | 20–26 s 随机 | **否**：`shouldDoPeriodicReSTUNLocked()` 在 `idleFunc()`（= `tundev.IdleDuration`，`wgengine/userspace.go`（`IdleFunc: e.tundev.IdleDuration`，无平台条件），所有平台都接）超过 `sessionActiveTimeout = 45 s` 就返回 false，除非控制面 `ForceBackgroundSTUN` | `wgengine/magicsock/magicsock.go` |
| disco 心跳（每个活跃对端） | 3 s（`heartbeatInterval`） | **否**：`lastSendExt` 超过 45 s 就不再重排 | 同上 `endpoint.go heartbeat()` |
| DERP 家中继 keepalive | ≥ 60 s（服务器发，`derp.KeepAlive`） | 是，1/min | `derp/derp.go` |
| 控制面 map 长轮询 | 服务器 keepalive，分钟级 | 是 | — |
| logtail 日志上传 | 有新日志 2 s 后批量上传（`defaultFlushDelay`） | 空闲时几乎没有日志 | `logtail/config.go` |
| Go 运行时 | sysmon：全部 P 空闲时睡到下一个 Go 定时器到期为止（`timeSleepUntil()`，上限 `forcegcperiod/2` = 60 s），所以**每个 Go 定时器到期约等于两次线程唤醒**（netpoll 里的 M + sysmon）；GC 强制周期 2 min | — | `runtime/proc.go sysmon` |

把这些加起来，稳态真正周期性的就是 portlist 的 **1 Hz**。**35/s 从哪来？** 两个解释，`y700-wakeups` 一跑就知道：(a) whoawake 数的是上下文切换，portlist 一次扫描是四次 netlink 请求 + 解析 + 结果比对，几十次 goroutine 交接（有新 socket 时再加几百次 `/proc` 读），每秒一簇，平均下来就是十几到几十"次/秒"——而且是**每个活跃秒都有**的稠密节律，不是上一稿说的 5 s 突发；(b) 测量会话本身——如果 whoawake 是从 Win11 经 tailnet（100.64.0.10）ssh 上去跑的，每个 ssh 包都经过 tailscaled 和 wireguard-go，它当然是第一名。README 没写当时走的是哪个地址。工具里看 `hrtimer_wakeup → tailscaled` 的每秒峰值：若 `TS_PORTLIST=false` 之后 tailscaled 掉到 <2/s，(a) 就坐实了。

**修法**（[tailscaled-wakeups.conf](tailscaled-wakeups.conf)，系统单元 drop-in；tailscaled.service 本来就 `EnvironmentFile=/etc/default/tailscaled`，写进那个文件也行，drop-in 更明确）：

- `TS_PORTLIST=false`：`envknob.BoolDefaultTrue("TS_PORTLIST")` 为假时整个扩展 `SkipExtension`，ticker 根本不建。（`TS_DEBUG_DISABLE_PORTLIST=1` 其实也会安静下来，但走的是错误路径：`poller.init()` 记下 `initErr`，第一次 `Poll()` 返回错误时 `runPollLoop` 直接 `return`、`defer ticker.Stop()` 收掉 ticker——源码注释自己写着 "TODO: this is kinda weird that we just return here"；而 ShieldsUp 或管理台关了 Collect services 时 `Poll()` 根本到不了、ticker 一直响。上一稿说它"ticker 照样每秒响"不准确，第三遍复核改正；仍选 `TS_PORTLIST=false`，因为扩展根本不加载、不靠错误路径。）失去的只有管理台里这台机的 "Services" 列。
- 可选 `TS_NO_LOGS_NO_SUPPORT=1`（或 `/etc/default/tailscaled` 的 `FLAGS="--no-logs-no-support"`）：不上传日志，少几次上传突发，代价是 Tailscale 支持看不到日志。默认不开。
- **不用**：`TS_DEBUG_RESTUN_STOP_ON_IDLE`（STUN 本来就在空闲 45 s 后停，这个旋钮只加日志）、`TS_DEBUG_ENABLE_SILENT_DISCO`（实验特性，心跳本来也会停）、`GODEBUG`（没有减少定时器的项）。`GOMAXPROCS=2` 理论上减少跨核 goroutine 交接（IPI1），没有测过，先量再说。
- `tailscale down` 当然最省，但作者要用它；README 熄屏对照里 "Tailscale 下线" 对功耗没有可测影响（0.57 vs 0.55 W 基线），再次说明这里省的是唤醒不是电。

**预期**：portlist 一项去掉后，tailscaled 稳态 <2/s；若实测仍高，看 `hrtimer_wakeup → tailscaled` 的活跃秒分布和 `packets wlp1s0:rx` 一栏：有流量就不是它的问题。

### 2.5 内核：`arch_timer` 160/s、IPI1 86/s 背后是什么

**`arch_timer` 不是独立的来源**——它是每个核的定时器中断，次数 ≈ 落在空闲核上的 hrtimer 到期次数。所以问题是"哪些 hrtimer 在空闲时到期"。本配置（`config-t49-y9`：`HZ=250`、`NO_HZ_IDLE`、`HIGH_RES_TIMERS`、`PREEMPT`、`RCU_NOCB_CPU_DEFAULT_ALL` + `RCU_LAZY`、`CPU_FREQ_DEFAULT_GOV_SCHEDUTIL`、`PSI=y`、`SOFTLOCKUP_DETECTOR=y`、`SCHED_MC`、`ENERGY_MODEL`、`THERMAL_GOV_STEP_WISE`、`CPU_IDLE_GOV_TEO`）下可能的候选，按能算出来的速率：

| 候选 | 机制 | 空闲时速率（推算） | 工具里看哪一行 | 可做的 |
|---|---|---|---|---|
| 用户态自己的超时 | `hrtimer_wakeup`（nanosleep/poll/epoll/futex） | ≈ §0 名单之和（PowerDevil 10 + helperd 10 + Claude 22 + pipewire 7 + tailscaled 的实际定时器…）≈ 60–90 | `hrtimer_wakeup → 进程` 表 | §2.1–2.4 |
| 调度 tick | `tick_nohz_handler`（6.9–6.x 叫 `tick_nohz_highres_handler`，更早 `tick_sched_timer`；工具三个都认），只在非空闲核上以 HZ=250 响 | 与 CPU 忙时间成正比（熄屏 0.2–0.4% 忙 → 几次/秒） | hrtimer 表 | 随用户态修复自然下降 |
| 软锁死看门狗 | `watchdog_timer_fn`，每核 `watchdog_thresh*2/5` = 4 s 一次，pinned（空闲核也醒） | 8 核 → **2/s** | hrtimer 表 | `sysctl kernel.watchdog_thresh=60`（→ 0.33/s；软锁死 120 s 才报，panic 行为不变）或 `kernel.soft_watchdog=0` |
| RT 带宽 | `sched_rt_period_timer`（1 s），只在 RT 任务消耗 runtime 时重排 | pipewire 的 RT 线程活跃时 ≤1/s | hrtimer 表 | 无需 |
| memlat 统计回读 | devfreq 监视器 `devfreq_monitor`（`polling_interval=1000`；0126 没设 `profile.timer`，所以是 devfreq 核心缺省的 **deferrable** 延迟 work——到期不叫醒空闲核，等该核因别的原因醒来才跑；`cat /sys/class/devfreq/ddr/timer` 应显示 `deferrable`——`timer_show()` 只打印当前值，不是带方括号的列表；y7 inventory 的 `memlat-sysfs` 里这个文件存在，说明 remote 调速器导出了 TIMER 属性；`--timer-list` 会打印），3 个设备各 1/s，每次 11 条 SCMI 消息 → 11 次 `apss_cpucp_mbox` 中断（README 已测），每条回复都可能把刚睡下的 CPU0 叫醒 | **≈ 11/s**（中断；定时器本身 ≈ 0） | wq 表 `devfreq_monitor`、IRQ 表 `apss_cpucp_mbox` | udev 规则 `90-y700-memlat-poll.rules` 的 1000 → 10000（或 0 = 停监视，`cur_freq` 读时现查不受影响）；**同时改 `y700-checklist` 里期望 "1000" 的那条**（`tools/y700-checklist.py:718-719`）。10-19 核对（PLAN §2.11 WK-1 :286-287，c30/X2）：这是 **deferrable 定时器，不是唤醒源**——到期不叫醒空闲核，只有核因别的原因醒来时才跑；DDR/LLCC 调频由 CPUCP 固件做，轮询只抄统计；1000 → 10000 只省 ≈9/s 的 mbox 中断（≈10/s → ≈1/s），功耗 ≈0，代价只是 `trans_stat` 变粗；体检改名 `check_memlat_poll`、期望值从规则文件读（PLAN :287 说「体检现无 memlat 项」与 :718 不符，以代码为准）；阶段 N5 捆臂。 |
| PSI | `psi_avgs_work`，每个最近有活动的 cgroup 一个延迟 work，2 s 周期（`PSI_FREQ`）；systemd 几十个 cgroup | 未知，可能 5–15/s | wq 表 `psi_avgs_work` | 本机没人读 `/proc/pressure`（没有 systemd-oomd）：y10 的 CMDLINE 加 `psi=0` 或 `CONFIG_PSI_DEFAULT_DISABLED=y`（我们的内核命令行编在镜像里，改不了只能重编） |
| 热区轮询 | `thermal_zone_device_check`，**只有 quiet-thermal** 有 `polling-delay = 1000`（0108，`baldur-skin-thermal.dtsi:30-31`），一次 ADC 读 = SPMI 事务 + EOC 中断 | **≈ 2/s** | wq 表、IRQ 表（spmi/pmic_arb） | 留着。CPU 区的 `polling-delay-passive = 100`（`baldur-thermal.dtsi`）和 GPU 区的 10 ms（0004）只在 95/105 °C 被动触发后才轮询；其余 14 个 NTC 区（`baldur-adc.dtsi` 的 `BALDUR_NTC_ZONE`）和 55 个 tsens 区**没有 polling 属性 = 不轮询**（thermal_of 对缺省的 polling-delay 取 0 而不是报错——反证：y7 的 inventory 里 `thermal_zone0…77` 共 78 个区全注册成功，含这 15 个 NTC 区），靠阈值中断：15 个 NTC 通道里 **14 个**在 `baldur-adc.dtsi` 带 `qcom,adc-tm;`，由 0039 的 ADC_TM5 gen3/gen4 阈值中断推 `thermal_zone_device_update`；例外是 `xo_therm`（channel@44）——既不轮询也没有 `qcom,adc-tm`，xo-thermal 区只在有人读 sysfs 时更新（对唤醒率是 0，对结论无影响）；tsens 同理。**任务书的"15 个 NTC 区 polling-delay"不成立。** |
| 惰性 RCU | `rcu_gp_kthread` 的 fqs 等待（jiffies 定时器 `process_timeout`）、rcuog 的 bypass 刷新（≤10 s） | 有 call_rcu 才有宽限期；空闲时很少 | timer 表 `process_timeout` → waker 表里 `rcu_*` | 已是最省的配置 |
| vmstat | `vmstat_update` 每核 1 s，**deferrable**，不叫醒空闲核 | 0 | — | 无需 |
| 回写 | `wb_workfn` 5 s（`dirty_writeback_centisecs`） | 有脏页才有 | wq 表 | 无需 |
| cpufreq schedutil / EAS | 没有周期定时器（irq_work + kthread，由调度器事件驱动） | 0 | — | 无需 |
| 网络栈 | TCP keepalive/重传、邻居表、IPv6 MLD/RA | 分钟级 | timer 表 | 无需 |
| **未知** | `kworker/0:0-events` 17/s、`kworker/u33:17-async` 11/s（`async` 是 `kernel/async.c` 的 `async_wq`，`async_schedule()` 的用户——空闲时谁在 `async_schedule`？不像设备探测） | 28/s | wq 表；`--probe-async` 直接给函数名 | 看结果再说 |

**IPI1 86/s（"Function call interrupts"）**：arm64 上把任务叫醒到一个**空闲**远程核走的是 `ttwu_queue_wakelist()` → `__smp_call_single_queue()` → `send_call_function_single_ipi()` = IPI_CALL_FUNC，**记在 IPI1 而不是 IPI0**。所以 86/s 的大部分很可能就是"唤醒本身"的跨核那一半，随唤醒率下降。剩下的是真正的 `smp_call_function_*`：JIT 的 `membarrier()`（`ipi_sync_core`/`ipi_mb`，Chromium/V8、Electron；Go 不用）、TLB shootdown（`flush_tlb_*`，进程改内存映射）、cpufreq。README 猜的"V8 membarrier"属于后者；`ipi_send_cpu` 的 callsite 表和 `csd_queue_cpu` 的函数表直接给答案。安卓的 `gic-intr-routing`（RESEARCH §2.5）在主线没有对应物，不做。

**`ce2` ≈ 40/s**：ath12k 给 WCN7860 的 CE 管道中断命名 `ce0…ce15`，WCN7850 家族里 CE2 是 target→host 的 WMI 事件环。空闲时 40 条 WMI 事件/秒不正常——除非它实际承载的是数据路径，那 40/s 就是**到达的包**：局域网的 mDNS/SSDP/ARP/IPv6 ND 广播在 DTIM 后整批送达，每批叫醒网卡再叫醒主机（安卓用 APF 固件过滤器挡这些，主线没有）。工具把 `wlp1s0:rx N/s` 印在第一行，和 `irq:ce2` 的次数并排看：相近就是流量，差很多就是 WMI。`CONFIG_ATH12K_TRACING` 没开，看不到 WMI 事件 ID；要查只能临时 `tcpdump -i wlp1s0 -nn -c 200 not host <本机>`（只读抓包，不发任何命令给固件）数广播类型。广播流量的治理在路由器侧，不在平板。

**`rtc@6100` 每 24.5 s 一次闹钟**（审计 1494 s 里 61 次）：内核的 alarmtimer 只在挂起时才编程 RTC；不休眠的系统上每 25 s 一次说明有人直接用 RTC 闹钟或 UIE。`--timer-list` 会打印 `/proc/driver/rtc` 的 `alrm_time/alarm_IRQ/update IRQ enabled` 和 `wakealarm`，IRQ 表里 `pm8xxx_rtc_alarm → 被叫醒的进程` 直接点名。候选：chrony（`rtcsync` 不用闹钟，但 `rtcfile` 模式会）、某个 `WakeSystem=` 的 systemd 定时器、`fake-hwclock`。**2026-10-16 补（[ALWAYS-ON.md](ALWAYS-ON.md) §5b）**：更可能根本没有闹钟——`CONFIG_RTC_SYSTOHC=y` 让内核在每次 chrony `adjtimex()` 后试写 RTC，pm8xxx 没有 nvmem 偏移返回 -ENODEV，但 `rtc_set_time()` 无条件 `pm_stay_awake()` 计一次（0.08 ms/次，与 total_time 5 ms 吻合）。`--timer-list` 看到 `alarm_IRQ: no` 且 IRQ 表里没有 `pm8xxx_rtc_alarm` 即印证；`always-on-check.sh --rtc 90` 的 `rtc_set_time … err=-19` 一次定案，之后 `y700-rtc-sync-off.sh` 去掉 `rtcsync`。

**预期**：内核侧能动的只有 memlat（−11）、看门狗（−1.7）、PSI（未知，y10）、quiet-thermal（−2，不建议）；加起来约 −15/s。其余随用户态下降。（10-19 核对：memlat 的 −11 按 WK-1 口径应为 ≈ −9/s，且它是 deferrable、不算唤醒源，见 §2.5 行内注）

## 3. 预期效果（RESEARCH §1.4 的模型）

驻留率 ≈ e^(−t/m)·(1 + (t − c)/m)，t = 10.15 ms（ss3 min-residency），c = 7.2 ms（2.8 + 4.4 进出开销），m = 1/唤醒率；功耗 = 0.42 − 驻留率 × (0.42 − 地板)，地板 0.10 W（s2idle 实测的数量级）/ 0.20 W（Wi‑Fi 关联、PCIe L1.x 的猜测）。**前提是 ss3 已放开（E3），今天它没放开，这一列全是 0.42。**

| 阶段 | 做了什么 | 唤醒率（次/秒，推算） | 模型驻留率 | 模型功耗（地板 0.10 / 0.20） |
|---|---|---|---|---|
| 现状 y9 | — | 285（10-15 whoawake idle 进入口径；10-16 `y700-wakeups` 基线 idle 退出 467，X16，表未按 467 重算） | 10% | 0.39 / 0.40 |
| + §2.1 PowerDevil | −12 | 273 | 11% | 0.39 / 0.40 |
| + §2.2 helperd | −8 | 265 | 12% | 0.38 / 0.39 |
| + §2.4 tailscaled portlist | −10 … −30（1 Hz 的 portlist 一簇算几次 idle 退出，看实测） | 235–255 | 13–17% | 0.37–0.38 / 0.39 |
| + §2.3 冻结 Claude/Chrome（可选） | −22 … −30 | 205–230 | 17–21% | 0.35–0.36 / 0.37–0.38 |
| + §2.5 memlat 10 s、watchdog_thresh 60 | −13（10-19 核对：memlat 部分 ≈ −9，WK-1） | 192–217 | 19–23% | 0.35 / 0.37 |
| + PSI（y10）、未知项查清 | ? | 目标 <100 → 47%；<50 → 69% | | 0.27 / 0.32 → 0.20 / 0.27 |

读法：名单上**已经确定**的项全做完大约 285 → 200，驻留率翻一倍但仍只有两成；要到 RESEARCH 说的 50 次/秒，必须把 §0.4 的四个未知项查清并处理——这正是工具存在的理由。另一个要诚实的点：模型把全系统唤醒当泊松过程，实际上 Claude 的 22/s 是稠密的、portlist 是每秒一簇，簇状唤醒对 ss3 比均匀分布友好（簇间空隙长），所以同样的"次/秒"下实际驻留率可能比表里好。

## 4. 实施顺序与验证

每一步之前先把 `y700-wakeups 60 --off --save` 的基线留下，之后同一命令再测一次，只比 `idle exits/s per CPU` 的 total 和 `wakeups/s by woken process` 两张表。全部用 `systemd-run`，从局域网地址上去。

1. **装工具、测基线**（只读）：`install -m755 tools/y700-wakeups.py /usr/local/bin/y700-wakeups`；基线保存到 `/var/log/`，一份拷回仓库（`linux/power/wakeups-<日期>-baseline.txt`，trace 原件太大不进仓库）。
2. **PowerDevil**（§2.1，零风险，可当场核对）：`install-wakeups.sh --powerdevil`。
3. **tailscaled**（§2.4）：`install-wakeups.sh --tailscale`——重启 tailscaled 断 VPN 几秒，脚本在 ssh 来自 100.x 时拒绝执行。
4. **helper**（§2.2）：平板上装 cargo、打补丁、编译、drop-in、重启，按补丁头的清单；`tb323fu-ctl status` 要照常回答，`tb323fu-ctl refresh preset power-saver` 等日常命令照常。
5. **冻结服务**（§2.3，**作者决定**）：`install-wakeups.sh --freeze`；先 `y700-screen-off-freeze --list` 看会冻谁。
6. **内核侧**（§2.5）：memlat 轮询 1000 → 10000（改规则 + 改体检期望）、`kernel.watchdog_thresh=60`（sysctl.d 文件 + 体检）；PSI 等 y10。
7. 全部做完再跑一次 `y700-offbench`——**预期功耗不变**（0.42 ± 0.03 W），变了反而要解释。

## 5. 有意不做、风险、未验证

- **不碰 0106/0118**：这里只治唤醒，簇/系统域的放开按 RESEARCH §3 的阶梯另做。
- **不冻 Telegram、pipewire、wireplumber、KWin、plasmashell、fcitx**：通知、声音、输入不能停。冻结服务只按名单来，默认名单只有 claude 和 chrome。
- **默认不装冻结服务**：会停掉 Claude 桌面版里的 agent 会话，作者点头才装。
- **不改 memlat 规则就不改体检**：两者必须一起改，否则每天 WARN。
- **不用 `--probe-async` 做常规测量**：kprobe 不是 tracepoint，只在查 `async` 那 11/s 时开一次。
- **不碰 quiet-thermal 的 1 s**：皮肤限频是安全功能，2/s 不值得。
- **没在平板上跑过任何一行**：`y700-wakeups` 的解析器只用按内核真实输出格式合成的 trace 测过（Win11 上 `--parse`；含 `record-tgid` 列、带连字符的 comm、IPI/csd 字段、`<...>` 唤醒者），真机若还有差异（comm 带空格）解析器做了容错但没验证；helper 补丁 `git apply --check` 过了但**没编译**；冻结脚本依赖 `busctl --user list --json=short` 的 `unit` 字段和 `systemctl --user show -p FreezerState`，这两者在 systemd 25x 上都有，没在平板核过版本。
- **没读到的**：lore/patchwork（反爬）；内核 `thermal_of.c` 和 `tick-sched.c` 原文（kernel.org cgit 回 403、raw.githubusercontent 回 429、github.com 只给前 1000 行——tick 回调名 `tick_nohz_handler` 来自那 1000 行里的定义，`hrtimer_setup` 那一行没看到；polling-delay 可选用 inventory 的 78 个区反证）；tailscale `feature/portlist` 的 `Run` 循环以外的 `ipnlocal` 细节（文件太大只读了命中行）；libddcutil 的监视线程循环体 `dw_poll.c`（只读了 `dw_main.c` 的三个 `g_thread_new` 和 `dw_recheck.c` 的常量）；上游 `kaanapali.dtsi` 的 thermal-zones 读了全文（55 区，无 polling 属性）。

## 6. 体检与回滚

`y700-checklist` 新增（都只在对应文件已安装时才检查，没装不报）：PowerDevil drop-in 在但进程环境无变量 → WARN；tailscaled drop-in 在但进程环境无 `TS_PORTLIST=false` → WARN；helper drop-in 在但运行中的 `tb323fu-helperd` 不在 `/usr/local/libexec` → WARN，`tb323fu-helper` 包版本变化 → CHANGED（重打补丁重编）；冻结服务单元装了但没在跑 → WARN。

回滚：每个 drop-in `rm` 掉再 `daemon-reload` + restart；冻结服务 `systemctl --user disable --now`（停止即解冻）；helper 删 drop-in 回到 dpkg 的二进制，`[poller]` 两个键原版忽略；memlat/看门狗改回原值并改回体检期望。

## 7. 出处

- KDE PowerDevil Plasma/6.6：`daemon/controllers/ddcutildetector.cpp`（`POWERDEVIL_NO_DDCUTIL`、`ddca_start_watch_displays`）、`ddcutildisplay.cpp`（单次定时器）、`daemon/plasma-powerdevil.service.in`、`README.md`（drop-in 写法与 `POWERDEVIL_NO_DDCUTIL=1`）——https://github.com/KDE/powerdevil/tree/Plasma/6.6
- libddcutil v2.2.5：`src/dw/dw_main.c`（`dw_start_watch_displays()` 的三个 `g_thread_new`：`watch_displays`、`display_recheck_thread`、`callback_displays_thread`）、`src/dw/dw_recheck.c`（`pop_interval_millis = 100` 的 `g_async_queue_timeout_pop`，`sleep_interval_millis = 200`）、`src/dw/dw_poll.c`、`src/base/parms.h`（`DEFAULT_UDEV_WATCH_LOOP_MILLISEC 500`）、`CHANGELOG.md` 2.2.0——https://github.com/rockowitz/ddcutil
- Plasma startplasma 的 env 脚本与 systemd 环境同步：plasma-workspace Plasma/6.6 `startkde/startplasma.cpp`（`runEnvironmentScripts`、`syncDBusEnvironment`）
- tailscale v1.104.1：`feature/portlist/portlist.go`（`envknob.BoolDefaultTrue("TS_PORTLIST")` → `SkipExtension`；`runPollLoop`）、`portlist/poller.go`（`pollInterval = 5 * time.Second` 通用缺省、`TS_DEBUG_DISABLE_PORTLIST` 设 `initErr`，`feature/portlist` 的 `runPollLoop` 在 `Poll()` 出错时 `return` 并 `ticker.Stop()`）、`portlist/portlist_linux.go`（`init()` 把 `pollInterval` 设为 1 s；netlink `inet_diag`、`/proc/net/tcp*` 回退、`/proc/*/fd` 找进程名）、`envknob/envknob.go`、`wgengine/magicsock/{magicsock.go,endpoint.go,debugknobs.go}`、`wgengine/userspace.go`（`IdleFunc: e.tundev.IdleDuration`，无平台条件）、`net/netmon/netmon.go`、`derp/derp.go`、`logtail/config.go`、`cmd/tailscaled/tailscaled.service`——https://github.com/tailscale/tailscale/tree/v1.104.1
- Go 运行时 `src/runtime/proc.go` `sysmon`（空闲时 `timeSleepUntil` / `forcegcperiod/2`）——https://github.com/golang/go
- Linux：`include/trace/events/{timer,ipi,csd}.h`（事件格式）；`kernel/async.c:358`（`alloc_workqueue("async", WQ_UNBOUND, 0)`）；`drivers/devfreq/devfreq.c`（`devfreq_monitor_start()`：`profile->timer` 缺省 `DEVFREQ_TIMER_DEFERRABLE` → `INIT_DEFERRABLE_WORK`）；`kernel/time/tick-sched.c`（`tick_nohz_handler(struct hrtimer *)`）；`arch/arm64/boot/dts/qcom/kaanapali.dtsi`（55 个 thermal zone 无 polling 属性）；本仓库 `linux/tb323fu-linux/kernel/dts/baldur-{skin-thermal,thermal,adc}.dtsi`、补丁 0004/0108；`linux/kernel-y8/config-t49-y9`、`inventory/`
- 本仓库：README 续航第三轮 / 零风险 A/B / 永不休眠各段；`cx-collapse/RESEARCH.md` §1.2、§1.4、§3.4、§3.7；`cx-collapse/cx-audit-2247.txt` wakeup sources 段；`tools/y700-whoawake.py`、`tools/y700-powerbench.sh`（J 档的冻结枚举）

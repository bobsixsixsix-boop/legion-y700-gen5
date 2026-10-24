# keyhold：紧急回安卓组合键的监视器每秒空转 5 次 —— 根因、事件驱动补丁、上游草稿、部署路线

> 状态：**2026-10-16 上午写成，全程离线**（本仓库 + 公开源码），没碰平板（无人值守测量到 12:30）、没装任何东西、没提交、没发帖。
> **补丁没编译**：Win11 上没有 gcc / clang / cl.exe（§3.5）。逻辑用仓库里的 [keyhold-model-test.py](keyhold-model-test.py) 跑过（C 的 `main()` 逐句翻成 Python，对着按 v7.3-rc4 源码写的 evdev 队列模型，§3.4），C 源码另做过 pycparser 语法/作用域/参数个数检查（§3.5）；C 代码本身要在平板上编译、测试（§6）之后才算数。
> 复核：同日由独立复核者重新核对过全部引用并修正了几处（§12），结论不变。
> 读者：作者，以及接手"熄屏不休眠还能不能再省一点"的下一个工程师。上下文见 [WAKEUPS.md](WAKEUPS.md)（唤醒治理总表与模型）、[cx-collapse/PROTOCOL.md](cx-collapse/PROTOCOL.md) §9（apps-pc 实测）。
> 版本约定：上游源码指 `joonhoekim/tb323fu-linux` tag **`helper-v0.4.2`**（2026-10-16 从 raw.githubusercontent.com 取的；`keyhold.c`、`tb323fu-emergency-key`、单元文件、`install.sh`、`emergency-key.conf`、`kernel/initramfs/init` 与本仓库副本 `linux/tb323fu-linux`（main 0c7c0c4）逐字节相同，`keyhold.c` blob `8c69ccc`，GitHub 上该文件只有一次提交 6234a5f；`build-debs.sh` 只差版本号 0.4.1→0.4.2）。上游 GitHub 的 `main` 在 2026-10-16 就是这个 tag 本身（`git ls-remote`：`main` 与 `helper-v0.4.2` 都是 `43ee432`），所以补丁对 `main` 同样原样适用；`0c7c0c4` 只是本地副本的 HEAD，比上游旧。内核源码指 torvalds/linux master `2f2f7ee`（7.3-rc7 之后）；复核时又取了 tag `v7.3-rc4`（平板内核的基线）的 `drivers/input/evdev.c`、`drivers/input/input.c`、`fs/select.c`、`kernel/time/sleep_timeout.c`，与 master **逐字节相同**，所以文中行号对 rc4 同样成立；本仓库和上游的内核补丁都不碰这四个文件（`linux/` 下全部 `.patch` 的 `+++` 行核过）。

## 0. 一页纸

1. **它是谁**：`/usr/libexec/tb323fu/keyhold 10 pmic_resin:114 gpio-keys:115` 是上游 `tb323fu-platform` 的**紧急回安卓组合键**（音量上 + 音量下按住 10 s → `back-to-android`）的按键监视器，由 `tb323fu-emergency-key.service` 起。README 1009 行把它写成"我们自己的屏幕键盘按键助手"是**错的**（屏幕键盘的是 `fcitx5-osk-key-helper` 那个 uinput 设备）。
2. **为什么醒**：`keyhold.c:78-97` 是一个永不结束的循环——每轮对每个设备 `EVIOCGKEY` 读一次键位图，然后**无条件** `usleep(200000)`（`:96`），不管有没有人碰键。于是每秒 5 次 `hrtimer_nanosleep` 到期，正好对上实测：单线程睡在 `hrtimer_nanosleep`、每 10 s 50 次自愿上下文切换、`y700-wakeups` 里 keyhold 5/s（README 1009 行）。
3. **轮询对正确性必要吗**：**不必要**，只有一条例外。启动时键已按下、事件丢失（SYN_DROPPED）、设备消失，这些用"事件唤醒 + 醒来后照旧 `EVIOCGKEY`"全都等价覆盖；原版**从不**重新扫描设备（缺设备就 exit 1，由外层脚本 1 s 后重启它），所以不需要 inotify。**唯一的例外是 `EVIOCGRAB`**：别的进程独占（grab）某个设备时，那个设备的事件只发给独占者，事件驱动版就收不到它的唤醒（只有另一个键最后按下时才认出组合键，§2.5），而 `EVIOCGKEY` 读的是设备的键位图、不受 grab 影响。本机查不到任何会 grab 这两个设备的东西（§2.5）。
4. **补丁**：[keyhold-event-driven.patch](keyhold-event-driven.patch)（git format-patch 格式，对 `helper-v0.4.2`，`git apply --check` 通过、应用后与 [keyhold.c](keyhold.c) 逐字节相同）。设备以 `O_NONBLOCK` 打开，全部放进一个 `ppoll()`：有键没按下时**不带超时**（内核里根本不挂定时器），所有键都按下时超时 = 距 "done" 的剩余时间；醒来先把事件读空再 `EVIOCGKEY`。参数、输出、退出码、设备消失后的行为全部不变。
5. **值多少**：−5 次唤醒/秒（全系统 300–500 次 idle 退出/秒的 1–1.7%）。功耗：今天旋钮默认关（ss3 不放开）亚毫瓦、测不出；apps-pc 放开时两种估法给 0.5–1.3 mW（泊松模型，按 E3a 实测的 300–360/s）和 4–7 mW（按 E3a 实测驻留粗估，偏上限），**取包络约 0.5–7 mW、几 mW 的量级**（§4）。**电池读数量不出来**（噪声 ±30 mW），验证靠数唤醒（§6）。
6. **部署建议**（§5）：按"成品系统走官方渠道"，**首选 A：作者发 PR，等上游出新版 deb，按 README 的官方 deb 路径装，装完手动 `systemctl restart tb323fu-emergency-key`**（postinst 不重启它）。只有在要给 E3 类实验把每一次唤醒都抠掉时，才用过渡方案 **C：本地编译 + systemd drop-in 的 `BindReadOnlyPaths=`**（只对这个服务生效、不碰包文件、`dpkg --verify` 干净、删一个文件即回滚）。任务书点名的 **B：`dpkg-divert`** 写全了命令和代价，但**不推荐**（§5.3）。

## 1. 为什么轮询（逐行，`helper-v0.4.2` 的 `userspace/platform/src/keyhold.c`）

| 行 | 内容 | 说明 |
|---|---|---|
| 10–13 | 头注释："Polls the key state (EVIOCGKEY) five times a second" | 作者明说是 5 Hz 采样设计 |
| 28–43 | `open_by_name()`：`/dev/input/event0..63` 逐个 `open(O_RDONLY \| O_CLOEXEC)`，`EVIOCGNAME` 比名字 | **只在启动时扫一次**；阻塞模式打开，之后**从不 `read()`** |
| 63 | `need = atol(argv[1]) * 1000` | 毫秒 |
| 64–76 | 解析 `NAME:CODE`；没有 `:` → `return 2`（无提示）；找不到设备 → `keyhold: no input device '%s'`，`return 1` | 缺设备时**退出**，不等待、不重扫 |
| 78–97 | `for (;;)` | 永不退出，除非 "done" |
| 80–85 | 每轮对每个 fd `EVIOCGKEY`，ioctl 失败或位不在 → `all = 0` | 设备消失后 ioctl 返回 `-ENODEV`，按"松开"算 |
| 86–95 | 状态机：首次全按下 → `hold` 并记 `since`；全按下且满 `need` → `done`、`return 0`；从全按下变为不全 → `release` | |
| **96** | **`usleep(200000)`** | **无条件**：不管状态，每 200 ms 醒一次 |

glibc 的 `usleep` 走 `clock_nanosleep` → 内核 `hrtimer_nanosleep`，定时器松弛是进程默认的 50 µs，几乎不可能和别的定时器合并。周期 = 200 ms + 一轮循环的执行时间（几十 µs），所以是"每 10 s 50 次自愿切换"这个整数。

外层（谁在跑它）：

- 根文件系统：`libexec/tb323fu-emergency-key`（单元 `tb323fu-emergency-key.service`，`Restart=always`，`ConditionPathExists=/etc/tb323fu/android-boot.sha256`）。脚本 `:15` 写死 `KEYHOLD=/usr/libexec/tb323fu/keyhold`；`:18-31` 的 `while :` 循环：`:19` 读 `/etc/tb323fu/emergency-key.conf`，`:20` `ENABLED != 1` 就 `sleep 30`，`:22` 跑 `keyhold $HOLD_SECONDS pmic_resin:114 gpio-keys:115 | while read`，keyhold 退出后 `:30` `sleep 1` 再来。**keyhold 退出（缺设备 exit 1 或 done 之后）时由这里 1 s 后重启——这才是原设计里的"重新扫描"。**
- initramfs：`kernel/initramfs/init:112-122` 同样的循环（`:113` 调用、`:121` `sleep 2`），二进制由 `kernel/initramfs/build.sh:74` 静态编译进镜像。switch_root 之前 `init:517-528` 把它和别的看门进程一起 `kill -TERM -1` / `kill -KILL -1`，所以**常驻的只有服务那一份**，initramfs 那份只活几秒，对熄屏功耗无关。

## 2. 轮询对正确性是否必要（逐条）

### 2.1 启动时键已经按着

原版第一轮就 `EVIOCGKEY`，立刻 `hold`。事件驱动版在第一次 `ppoll()` 之前同样先读一次状态（循环结构没变，读状态在循环顶部），行为相同。**不需要轮询。**

### 2.2 漏事件、队列溢出（SYN_DROPPED）

补丁**不跟踪单个事件**，每次醒来仍以 `EVIOCGKEY` 的键位图为准，所以溢出、乱序都无所谓。内核依据（`drivers/input/evdev.c`，master 2f2f7ee）：

- `evdev_handle_get_val()`（`:889-915`）：在 `dev->event_lock` 下复制 `dev->key`，然后 `__evdev_flush_queue(client, type)`（`:909`）丢掉本客户端队列里同类型（EV_KEY）的事件——内核注释就是为了"别让用户态拿到重复事件"。
- 键位图在交给任何处理者之前就更新：`drivers/input/input.c:246` `__change_bit(code, dev->key)`（`input_get_disposition()`，`:208` 起），所以读到的状态永远不落后于已投递的事件。
- **为什么醒来必须先读空队列**：`evdev_poll()`（`:613-627`）只要 `packet_head != tail` 就报 `EPOLLIN`；而 `__evdev_flush_queue()` 故意保留队首的 `SYN_REPORT`（`:116` "init to 1 so a leading SYN_REPORT will not be dropped"）。只靠 `EVIOCGKEY` 不 `read()`，队列里会剩一个 `SYN_REPORT`，`ppoll()` 立刻再返回——忙等。所以补丁的 `drain()` 先读到 `EAGAIN`（`evdev_read()` `:577-579`：非阻塞且没有完整包时返回 `-EAGAIN`），再 `EVIOCGKEY`。先读后查的竞态：读空之后、查之前来的事件，要么已经反映在键位图里（被 flush 掉也没关系），要么在查之后入队、让下一次 `ppoll()` 醒来——不会丢跳变。
- 唤醒粒度：`evdev_pass_values()` 只在 `SYN_REPORT` 时置 `wakeup`（`:277`）、`:289` 唤醒等待者，一次按下或松开 = 一个包 = 一次唤醒。

### 2.3 按住期间要计时

两个设备都只有 `EV=3`（`EV_SYN | EV_KEY`，`linux/kernel-y8/inventory/input-devices` 的 `pmic_resin`、`gpio-keys` 两段），**没有 `EV_REP`**，按住不会产生自动重复事件。所以"按满 N 秒"必须靠超时——补丁只在所有键都按下时才给 `ppoll()` 超时，正是这一段。

### 2.4 设备来来去去

- **原版从不重新扫描**：缺设备时 exit 1（`:72-75`），由外层 1 s / 2 s 后重跑；启动之后设备消失，`EVIOCGKEY` 返回 `-ENODEV`（`evdev_ioctl_handler()` `:1272-1273`），按"松开"算——若正在按住就打 `release`，之后永远不会再 `hold`，**也不退出**，继续每 200 ms 问一个死 fd。
- 补丁保持这一语义：死设备的 `ppoll()` 返回 `POLLHUP | POLLERR`（`evdev_poll()` `:621-624`；`evdev_hangup()` `:419` 起会唤醒等待者），`read()` 返回 `-ENODEV`（`:574-575`），任一出现就把该项的 `pfd.fd` 置 −1——内核 `do_pollfd()` 对负 fd 直接返回 0（`fs/select.c:867-868`），从此不再看它；求值时该键按"松开"算。所有设备都死了时 `ppoll()` 无 fd、无超时，永久睡眠——和原版"再也不触发、不退出"等价，只是不再空转。
- **为什么不加 inotify**：任务书说"如果原版周期性重扫，就换成不轮询的等价物"——原版没有重扫，重启是外层脚本的事，保留即可。而且两个驱动都是内建的：`CONFIG_KEYBOARD_GPIO=y`、`CONFIG_INPUT_PM8941_PWRKEY=y`（`linux/kernel-y8/config-t49-y9:2347`、`:2497`；y10 的配置与 y9 完全相同，`kbuild-y10.sh:4`；现役 y12 的 config 与 y10 相同、1046–1048 不碰 evdev/input/gpio-keys，结论不变——10-19 核对 X43，`kbuild-y12.sh:16-17`），开机 0.23 s / 0.97 s 就注册（`inventory/dmesg:446`、`:707`），只有手工 sysfs unbind 才会消失。加 inotify 反而是行为改变（缺设备时等而不是退出），不做。
- `logind` 的 `EVIOCREVOKE` 只作用于它自己打开、交给会话的那个 fd（evdev 的 revoke 是按客户端的：`evdev_revoke()` `:946-949` 只置该 client 的 `revoked`），keyhold 自己打开的 fd 不受影响——两版都一样。

### 2.5 唯一的例外：别人的 `EVIOCGRAB`

- 某个客户端 grab 了 evdev 设备后，`evdev_events()`（`:305-311`）只把事件交给 `evdev->grab` 那一个客户端；输入核心层面 `input_pass_values()`（`input.c:120-123`）也只交给 grab 的那个 handle。事件驱动版收不到**那个设备**的任何事件。准确地说（复核时用模型跑出来的，§3.4）：设 gpio-keys 被别人 grab——先按音量下、后按音量上，**认不出组合键**（最后一个跳变没有唤醒）；先按音量上、后按音量下，音量下的事件叫醒它、`EVIOCGKEY` 读到两个都按着，照样 `hold` → 10 s 后 `done`；按住期间音量上松开又按回，它**察觉不到**（直到超时那一刻才重读键位图），所以会照样 `done`。原版三种情况都按真实状态处理。
- 但 `dev->key` 照样更新（`input.c:246` 在投递之前），`EVIOCGKEY`（`evdev.c:1157-1158` → `evdev_handle_get_val()`，不检查 grab）照样读得到——**原版的采样循环对 grab 免疫，这是轮询唯一真正买到的东西**。
- 本机有没有谁 grab 这两个设备：
  - libinput 1.31.1（平板装的版本，`inventory/packages`）：`src/` 下全部 96 个 .c/.h 从 gitlab.freedesktop.org 取下来 grep，**没有 `EVIOCGRAB` / `libevdev_grab`**；只有调试工具 `tools/shared.c:494`（`libinput debug-events --grab`）会 grab——手工调试才会用。
  - KWin 6.6（`kwin-wayland 4:6.6.6`）：`src/backends/libinput/{context,connection,device}.cpp`、`src/core/session_logind.cpp` 没有 grab（它经 logind 拿 fd、交给 libinput）。
  - 上游仓库、本仓库（`linux/`、`tools/`）全文 grep 没有 `EVIOCGRAB`；我们自己读输入设备的只有 `y700-dpms-probe.py`（注释明说"a plain reader: nothing is grabbed"）和控制中心/OSK 的力反馈（`EVIOCSFF`）。
  - gamescope 3.16.20（平板装的版本）：复核时浅克隆了 tag `3.16.20`（`0b445d9`），`src/` 全部 .c/.cpp/.h/.hpp 里没有 `EVIOCGRAB` / `libevdev_grab`（输入走 `src/LibInputHandler.cpp` 的 libinput）；它内嵌的 wlroots（子模块 `Joshua-Ashton/wlroots@54e8447`）的 `backend/libinput/{backend,events,keyboard}.c`、`backend/session/session.c` 也没有 grab。
  - 平板的 `inventory/packages`（2165 个包）里没有常见的按键重映射/热键守护（keyd、evsieve、input-remapper、triggerhappy、interception-tools、kmonad、kanata、xremap、evremap、actkbd）——这类程序才是 grab 的典型来源。内核里挂在这两个设备上的 `idle_refresh` 处理器（0110 补丁）只观察事件，不 grab。
  - **没查**：Steam（`inventory/apps` 里有 `steam-arm64.desktop`，闭源，查不了）和其它装着的包。设备上也没有不 grab 就能列出"谁 grab 了"的接口；§6.3 的服务内功能测试就是实地证明（KWin 在跑时短按组合键能看到 `hold`/`release`）——但只证明测试那一刻没人 grab。
- 结论：在本机上没有已知的 grab 者；但这是一个**真实的取舍**，草稿里向上游原样说明，并给出折中（保留采样但改成 1 s 一次）。另一种折中（没写进草稿，留给维护者挑）：只在"至少一个键按着"时加一个 1 s 的兜底超时——空闲时仍然 0 次唤醒，被 grab 的键最后按下时最多晚 1 s 认出来；代价是代码多几行。

### 2.6 桌面冻住时

紧急键的设计目标是"桌面冻住也能用"（上游 `docs/helper-reference.md:17`："must work with no desktop and no helper"）。KWin 卡死不读它自己的 evdev 队列，不影响 keyhold：每个客户端有自己的缓冲区（`evdev_pass_values()` 按客户端入队）。两版在这一点上等价。

## 3. 补丁做了什么

### 3.1 改动（[keyhold.c](keyhold.c) 行号）

- `:22` `#define _GNU_SOURCE`（`ppoll`）；新增 `errno.h`、`poll.h`。
- `:44` `open(... | O_NONBLOCK | O_CLOEXEC)`：只为能把队列读空，`EVIOCGNAME` 不受影响。
- `:68-76` `drain()`：一次读 16 个 `input_event`，读到 `EAGAIN`；`ENODEV` 等错误返回 −1。
- `:112` 求值时死设备按"松开"。
- `:131-139` 有键没按下 → `tp = NULL`（无限等）；全按下 → `tp` = 剩余毫秒（≤0 取 0）。
- `:140-145` `ppoll()` 出错：`EINTR` 直接再来；其他 `usleep(200000)` 后再来——退回原版行为，**绝不忙等**。这是防御性代码，实际两种都碰不到：没装信号处理函数就没有 `EINTR`（SIGSTOP/SIGCONT 由内核透明重启）；`ENOMEM` 只来自 `do_sys_poll()` 超出栈上缓冲时的分配（`fs/select.c:991-1009`，栈上能放 30 个 pollfd）或等待项超出内联的 `N_INLINE_POLL_ENTRIES`（`:162-170`；`include/linux/poll.h:17-22`，576 字节 ÷ 每项约 64 字节 ≈ 9 项，"约 64 字节"是按结构体推算的），`MAXKEYS` = 8 都在里面。
- `:146-150` 有 `POLLERR/POLLHUP/POLLNVAL` 或 `drain()` 失败 → `pfd[i].fd = -1`。

`git diff --stat`：60 行增、6 行删，全在 `keyhold.c`。

### 3.2 内核里"不挂定时器"的依据

`ppoll(..., NULL, NULL)` → `do_poll()` 的 `end_time` 为 NULL，`to` 一直是 NULL（`fs/select.c:883-970`，`:899-900` 只有有超时才算 slack）→ `poll_schedule_timeout()` → `schedule_hrtimeout_range(NULL, …)`（`:241`）→ `kernel/time/sleep_timeout.c:206-207` `if (!expires) { schedule(); …}`：纯睡眠，**没有任何 hrtimer**，只有按键事件（或信号）能叫醒它。

按住时的超时精度：`select_estimate_accuracy()`（`fs/select.c:51-91`）给的 slack = 剩余时间的 0.1%（nice>0 时 0.5%），下限是进程的 `timer_slack_ns`（50 µs），上限 100 ms——10 s 超时约 10 ms。毫秒截断不会造成提前或忙等：剩余量是整数毫秒，`ppoll()` 至少睡这么久，醒来时 `now_ms() - since >= need` 必然成立。

### 3.3 可观察行为对照

| 项 | 原版 0.4.2 | 补丁 |
|---|---|---|
| 参数、usage 文本、`MAXKEYS`、event0..63 扫描 | — | 不变 |
| 输出行 / 行缓冲 | `hold` / `release` / `done`，`_IOLBF` | 不变 |
| 退出码 | 0 done、1 启动时缺设备、2 参数错 | 不变 |
| 启动时已按住 | 立刻 `hold` | 立刻 `hold` |
| `hold` 的时刻 | 最后一个键按下后 0–200 ms | 按下即时 |
| `done` 的时刻 | `since` 后 N s + 0–200 ms（相对实际按下最多晚 400 ms） | `since` 后 N s + 约 10 ms |
| 短于 200 ms 的松开/按下 | 可能漏掉 | 看得见（松开会重新计时） |
| 设备中途消失 | 按松开算、不退出、继续 5 Hz 问死 fd | 按松开算、不退出、不再看它 |
| 别人 grab 了一个设备 | 照样看得见 | **部分看不见**：那个键最后按下时认不出组合键，按住期间它松开又按回察觉不到（§2.5） |
| 空闲时的唤醒 | 5 次/秒 | 0 |
| `wchan` | `hrtimer_nanosleep` | poll 一类（预期 `do_sys_poll` 或 `poll_schedule_timeout`，未实测） |

### 3.4 逻辑模型测试（不是 C 代码测试）

[keyhold-model-test.py](keyhold-model-test.py)（入库；`python3 linux/power/keyhold-model-test.py`，Win11 上 1 秒内跑完）：把**两版** `main()` 逐句翻成 Python（`||` 短路、`now_ms()` 毫秒截断、`left` 的计算、`drain()` 的循环条件都照抄），对着一个按 v7.3-rc4 源码写的内核模型跑——`input_get_disposition()` 只在位变化时放行、键位图先于投递更新、单独的 `SYN_REPORT` 不投递、grab 只投给独占者、注销时先松键再标记死亡；每个客户端 64 项队列（`__pass_event()` 溢出成 `SYN_DROPPED` + 最新一项、`packet_head` 只在 `SYN_REPORT` 前移、丢空包）；`EVIOCGKEY` = 快照 + `__evdev_flush_queue(EV_KEY)`（保留队首 `SYN_REPORT`）；非阻塞 `read()` 只读完整包；`evdev_poll()` 的 HUP|ERR / IN；`ppoll()` 跳过负 fd、slack = max(50 µs, min(100 ms, 0.1%))。每个系统调用随机花 1–60 µs 模拟时间、物理事件落在调用之间，所以"`drain()` 之后、`EVIOCGKEY` 之前来了事件"这类竞态会真的发生（默认的一次完整运行里，`EVIOCGKEY` 冲掉事件后留下队首 `SYN_REPORT` 的情况出现 348 次，都只多转一圈）。结果（2026-10-16，全部通过）：

- 定向场景各 20 个种子：一直不按（永久睡、0 次空唤醒）；先后按下；按住中松开再按；启动前已按住；9.999 s 松开；超时后 5 ms 松开（slack 内，`release` 或 `done` 都算对）/ 20 ms 松开（`done`）；按住中一个设备消失；两个都消失；50 ms 的短松开（新版 20/20 都看见，原版 15/20 漏掉）；队列溢出（100 包突发）；按住期间来一阵不改变键位的事件（剩余时间不被重置）；`ENOMEM` 一次、30% 的 `EINTR`（输出与时序不变）；启动时缺设备（exit 1）。
- 随机时间线 2000 个种子（每段稳定状态 ≥ 450 ms，原版也看得见）：新版输出 = 理想输出，**与原版逐行相同**；各行相对真实跳变的延迟最多 10.3 ms（就是 10 s 超时的 slack）；没有忙等；`ppoll()` 只醒 13121 次，原版同样的时间线循环 313488 次。
- 触点抖动 500 个种子（20 µs–2 ms 的乱跳）：最终状态总是对的、行交替出现、不忙等；抖得比一次系统调用还快时可能把一对松/按合并掉（读到的是一致的键位图），这是允许的。
- 变异检查（`--mutants`）：去掉 `drain()`（忙等）、不理 POLLHUP（设备消失后忙等）、超时不减已过时间（按住期间被无关唤醒后 `done` 晚到）三个故意改坏的版本都被抓到。
- grab 取舍的三种情况（§2.5）就是这个脚本打印出来的。

这仍然只证明**状态机和它对内核语义的用法**，证明不了 C 的语法、头文件、警告——那要平板上编译（§6.1）。最初那版只有 8 个场景的模型（不模拟 `SYN_REPORT` 残留、溢出、调用之间的竞态、slack）未入库，已被这个脚本取代。

### 3.5 编译：本机做不到

- `gcc --version`、`clang --version`、`cl.exe`：Git Bash 里都是 command not found；没有 `C:\Program Files\LLVM`、没有 Visual Studio、没有 MSYS2/MinGW；Android SDK 里没有 NDK；`~/.rustup` 不存在。
- WSL 里有一个 Ubuntu（Stopped）。**没有启动它**：那是另一个项目的开发环境，一启动就把那一整套服务拉起来，不是编译一个 C 文件该有的副作用。
- 平板上有：`gcc 15.2.0`、`clang 21`、`libc6-dev 2.43`、`strace 6.19`（`inventory/packages`，10-15 的清单）。§6.1 第一步就是 `cc -O2 -Wall -Wextra`，要求零警告。
- 我能做的静态检查：补丁 `git apply --check` 对 v0.4.2 通过，应用后与 `keyhold.c` 逐字节相同（注意：Windows 的 Git 全局 `core.autocrlf=true`，在仓库外 `git apply` 会写出 CRLF，要加 `-c core.autocrlf=false`；平板上无此问题）；`git mailinfo` 解析出作者、标题、正文正常；两个文件 LF、无 CR。复核时又在一个临时仓库里 `git am` 了补丁（作者、日期、标题、diffstat 60+/6− 都对，结果 blob `7927c44` 与 `keyhold.c` 相同）。
- 复核加的"穷人版编译"（脚本未入库）：去掉 `#include`、手工展开用到的宏（`EVIOCGKEY`/`EVIOCGNAME` 按 `_IOC` 编码）、前面垫上 glibc/内核的原型和结构体，交给 pycparser 3.11 解析，再查三件事：每个标识符都在作用域里声明过、每个函数调用的参数个数与原型一致、每个 `.`/`->` 字段都存在。`keyhold.c` 与原版都通过；故意改坏的副本（未声明变量、`drain()` 多一个参数、字段名拼错）三处都报出来。它**不做类型检查**，也看不到 `-Wall -Wextra` 会说什么。人工过了一遍 `-Wextra` 常见项：没有有符号/无符号比较、没有未用参数/变量、`ts` 已初始化、`read()` 的返回值（glibc 标了 `warn_unused_result`）用了；`_FORTIFY_SOURCE=3` 下 `ppoll()` 的对象大小检查 `n ≤ MAXKEYS` 成立——这些是推断，不是编译器说的。

## 4. 值多少

- **唤醒**：−5 次/秒（keyhold 自己的 200 ms hrtimer；它落在空闲核上就是一次 idle 退出）。全系统熄屏 300–500 次/秒（README 1009：装前 467/s；PROTOCOL §9 E3a 第二轮中断 300–360/s），占 1.1–1.7%。
- **功耗，旋钮默认关（今天的常态）**：ss3/apps-pc 不放开，按 WAKEUPS §0 第 1 条的结论"任何唤醒改动对功耗表都不会有可测的变化"。直接开销（5 次极短的唤醒：出入 idle + 两次 ioctl + 调度）没有测过；若按单次唤醒 10–100 µJ 的一般量级**假设**，是 0.05–0.5 mW——**亚毫瓦**，但具体数没有依据（原稿写的"几十 µW"只是这个假设区间的下沿）。
- **功耗，apps-pc 放开时（E3a 那种状态）**，两种估法：
  - WAKEUPS §3 的泊松驻留模型（t = 10.15 ms、c = 7.2 ms，功耗 = 0.42 − 驻留 × (0.42 − 地板)）：467/s 时 0.2–0.3 mW、360/s 时 0.5–0.8 mW、300/s 时 0.9–1.3 mW、200/s 时 1.9–2.8 mW、100/s 时 4.1–6.0 mW、50/s 时 5.9–8.5 mW（地板 0.20 / 0.10 W）。
  - 实测驻留比模型好得多（PROTOCOL §9：300–360 次中断/s 时 apps-pc 驻留 67%，系统域进入约 23 次/秒、即平均每段停留约 29 ms；省约 0.1 W，即每 100% 驻留约 0.15 W——**这是上限**（10-19 补，X22：0.15 W/100% 基于 10-16 第二轮这单次 67%；驻留逐次变化，10-17 夜 y12 40%、10-18 白天 17%（整段 15 min 含复发；有效的前 7 min 为 34%，PROTOCOL §9 10-18 白天表），见 PROTOCOL 10-16 第二轮条目的补注）：PROTOCOL 自己说这 0.1 W 是 apps-pc 加两个唤醒 drop-in 的合计，没拆开）。一个独立的 5 Hz 定时器落在 apps-pc 停留里（概率约 0.67）就把一段停留切成两段，至少赔掉一次进出开销 c = 7.2 ms，切出的段若短于 10.15 ms 还要整段作废：期望每次赔 0.67 × (7.2 ms + 0–7 ms) ≈ 5–10 ms，5 次/秒 ≈ 驻留 −2.5–5%，× ≤0.15 W ≈ **≤4–7 mW**。这是粗估，不是测量。
  - 合起来：两种估法**不重叠**——泊松模型在 E3a 实测的 300–360/s 处给 0.5–1.3 mW，实测驻留粗估给 ≤4–7 mW。诚实的说法是 **apps-pc 放开时约 0.5–7 mW、几 mW 的量级**（原稿写"1–5 mW，取交叠"，两个区间其实没有交叠，复核改成包络）。
- **量得出来吗**：不能。`y700-powersample` / 记录器的电池读数分钟均值在 184–430 mW 之间跳（PROTOCOL §9），噪声 ±30 mW。验证只能数唤醒：服务里 keyhold 的 `voluntary_ctxt_switches` 60 s 增量 300 → 0，`y700-wakeups` 的 `hrtimer_wakeup → 进程` 表里 keyhold 消失。

## 5. 部署路线

规矩：成品系统上装东西走官方渠道；README 527 行记录了这台机的官方渠道——下 release 的 deb、核 `SHA256SUMS`、`apt-get install … --force-confold`，`tb323fu-ctl helper update` 对 dpkg 装的 helper 拒绝升级。

### 5.1 A（推荐）：上游修，走官方 deb

1. 作者审上游 PR 草稿（未入公开仓库），在平板测完（§6）后把 TBD 换成实测，用自己的 GitHub 账号开 PR（补丁 `git am keyhold-event-driven.patch` 后 `git commit --amend -s` 签 DCO）。
2. 等上游发布含修复的 `tb323fu-platform`（下面以 0.4.3 为例）。确认方法：`curl -s https://raw.githubusercontent.com/joonhoekim/tb323fu-linux/<新tag>/userspace/platform/src/keyhold.c | grep -c ppoll` 非 0；`tools/upstream-check.py` 的日常巡检也会看到上游变化。
3. 平板上（root，局域网地址，不在测量窗口内）：

   ```sh
   cd /root/tb323fu-0.4.3                      # 从 GitHub release 下的三个 arm64 deb + SHA256SUMS
   sha256sum -c SHA256SUMS --ignore-missing
   cp -a /etc/tb323fu /root/etc-tb323fu.before-0.4.3
   DEBIAN_FRONTEND=noninteractive apt-get install -y -o Dpkg::Options::=--force-confold \
       ./tb323fu-platform_0.4.3_arm64.deb ./tb323fu-helper_0.4.3_arm64.deb ./tb323fu-settings_0.4.3_arm64.deb
   systemctl restart tb323fu-helperd tb323fu-emergency-key   # postinst 不重启它们（build-debs.sh:96-103；README 527）
   ```

   若之前装过 C，同时按 §5.2 的回滚删掉 drop-in。然后做 §6.2 的验证。
4. **代价**：在上游发布之前，这 5 次/秒一直在；时间表不由我们定；维护者可能因为 §2.5 的 grab 取舍不收，或改成 1 s 采样（那样是 1 次/秒）。

### 5.2 C（过渡，可选）：本地编译 + systemd drop-in 绑定挂载

思路：不动任何包文件，只让 `tb323fu-emergency-key.service` 的挂载命名空间里 `/usr/libexec/tb323fu/keyhold` 指向我们的二进制。仓库文件 [y700-keyhold-local.conf](y700-keyhold-local.conf)：

```ini
[Service]
BindReadOnlyPaths=-/usr/local/libexec/tb323fu/keyhold:/usr/libexec/tb323fu/keyhold
```

依据：systemd.exec(5)（复核时取了平板同版本 tag `v259.5` 的 `man/systemd.exec.xml`，`BindPaths=` 一节 `:447-484` 与原稿引的 v258 逐字相同）——`BindReadOnlyPaths=` 是单元私有的只读绑定挂载，"not visible in the host's mount table"；前缀 `-` 表示源不存在时忽略（v259.5 `src/core/namespace.c:1993-1996`：`chase()` 得到 `-ENOENT` 且 `m->ignore` 就跳过这一项；于是 `/usr/local/...` 万一被删，服务退回包里的二进制，而不是起不来——紧急键绝不能因为这个覆盖失效）；它隐含 `PrivateMounts=`（新挂载命名空间，单元内的挂载不传回主机，主机的挂载照样传进来）。命名空间是在 `/run/systemd/mount-rootfs` 上递归绑定主机 `/` 再切根做出来的（`namespace.c:2636`、`:3032`），所以服务里 `/` 的设备号与主机相同——这正是下面 `cur_root` 的前提，§6.2 仍在平板上实地核一次。为什么不用 `ExecStart=` 覆盖（helperd 补丁的做法）：keyhold 不是 `ExecStart`，是包装脚本 `:15` 写死的路径；复制一份脚本会和上游脚本漂移。为什么不往 `emergency-key.conf` 里加 `KEYHOLD=`（脚本在 `:15` 之后才 `.` 它，技术上能覆盖）：helper 的 `emergency_set()` 每次整文件重写（`features.rs:645-658`，v0.4.2），作者在设置里一动紧急键这一行就没了；它还是 dpkg conffile（`build-debs.sh:68-71`：etc 下全是 conffile）。

安装（**要作者当轮明确同意**——这是往成品系统上装非官方二进制；平板，root，局域网地址，**不在无人值守测量窗口内**；按键测试要作者在场；下面"体检"三条要在同一轮落地，否则不装）：

```sh
install -d /usr/local/src/y700-keyhold
# Win11（脚本式 scp）：
#   scp -i ~/.ssh/y700_ed25519 linux/power/keyhold.c linux/power/y700-keyhold-local.conf root@192.168.0.81:/usr/local/src/y700-keyhold/
cd /usr/local/src/y700-keyhold
sha256sum keyhold.c          # 73beb1af876723f7941de918a8051d48469bdb196f0e6a884dab30982c28164c
cc -O2 -Wall -Wextra -o keyhold keyhold.c       # 必须零警告；有警告就停，回来改源码
systemctl stop tb323fu-emergency-key            # 测试期间停掉服务，免得按键测试真的回安卓
#   ……做 §6.1 的二进制测试……
install -D -m755 keyhold /usr/local/libexec/tb323fu/keyhold
dpkg-query -W -f='${Version}\n' tb323fu-platform > /usr/local/libexec/tb323fu/keyhold.platform-version
install -D -m644 y700-keyhold-local.conf /etc/systemd/system/tb323fu-emergency-key.service.d/y700-keyhold-local.conf
systemctl daemon-reload
systemctl start tb323fu-emergency-key
sleep 2                                         # Type=simple：start 在 fork 后就返回，命名空间建不起来（226/NAMESPACE）
                                                # 要等子进程失败、Restart=always 连撞 5 次限流后才看得出
systemctl is-active tb323fu-emergency-key       # 必须 active；不是就立刻回滚（下面）
cmp /proc/$(pgrep -x keyhold)/exe /usr/local/libexec/tb323fu/keyhold && echo ours   # 必须 ours（ENABLED=0 时没有 keyhold）
```

然后 §6.2、§6.3。

回滚：

```sh
rm /etc/systemd/system/tb323fu-emergency-key.service.d/y700-keyhold-local.conf
rmdir /etc/systemd/system/tb323fu-emergency-key.service.d 2>/dev/null
systemctl daemon-reload && systemctl restart tb323fu-emergency-key
sleep 2; systemctl is-active tb323fu-emergency-key
cmp /proc/$(pgrep -x keyhold)/exe /usr/libexec/tb323fu/keyhold && echo packaged-keyhold-again
rm -f /usr/local/libexec/tb323fu/keyhold /usr/local/libexec/tb323fu/keyhold.platform-version   # 可选
```

代价：

- **遮住上游的新版**：drop-in 在，包里的 keyhold 无论怎么更新，这个服务都用我们的——上游哪天改了 keyhold 的参数或包装脚本的调用方式，我们的旧二进制可能不兼容。所以要有周期性义务：每次 `tb323fu-platform` 版本变化（和 `keyhold.platform-version` 不同），看上游 `keyhold.c` 是否已经事件驱动——是就删 drop-in 回到包里的；否就确认脚本 `:22` 的调用参数没变。
- 包升级本身：drop-in 不碰 dpkg 数据库，升级不会冲突、不会提示、不会覆盖我们的文件（我们的在 `/usr/local`）。一个细节：dpkg 解包时把新文件写成 `keyhold.dpkg-new` 再 `rename()` 盖到 `/usr/libexec/tb323fu/keyhold` 上（dpkg 的这个做法凭记忆，没读 dpkg 源码）；那个 dentry 在主机命名空间里不是挂载点，在服务命名空间里是。内核这边复核时读了 v7.3-rc4 源码：`vfs_rename()` 只拿**调用者自己命名空间**判断 `-EBUSY`（`fs/namei.c:6175-6177` → `__is_local_mountpoint()` 只遍历 `current` 的 mnt_ns，`fs/namespace.c:839-851`），然后对被覆盖的目标 `dont_mount()` + `detach_mounts()`（`fs/namei.c:6213-6219`），后者把**所有命名空间里**挂在这个 dentry 上的挂载卸掉（`fs/namespace.c:1981-2002`）。所以升级会把服务里的绑定挂载拆掉：此后到服务重启前，包装脚本下一次 exec keyhold 用的是包里的新文件（正在跑的那个进程不受影响）；升级后照 A 的第 3 步重启服务，绑定恢复。两种情况下组合键都能用。
- 紧急服务多了一个挂载命名空间：`back-to-android` 在里面跑。它的 `cur_root()` 读 `/proc/self/mountinfo` 里挂在 `/` 的设备号（`android/back-to-android:50-51`），状态根不是当前根时临时挂到 `/run/tb323fu/b2a-state` 再卸（`:62-66`、`:77`）——在私有命名空间里都成立（`/run` 可写，挂载只在单元内可见，用完即卸）；最坏情况 `cur_root` 判断错，它只会多挂一次同一个 ext4 分区或只打一行 warning（该函数"失败只警告"）。§6.2 有一条 `nsenter` 核对 `cur_root` 在服务命名空间里与主机一致；真正的 `dd` + 重启路径无法在不回安卓的前提下测试。
- 体检（**未实现；装 C 的同一轮由装的人加进 `y700-checklist`**——"要记的事由机器记"，不能只写在这里）：drop-in 在时——服务不 active → FAIL；`cmp /proc/<keyhold pid>/exe /usr/local/libexec/tb323fu/keyhold` 不同 → WARN（没重启或绑定被懒卸载）；`tb323fu-platform` 版本 ≠ `keyhold.platform-version` → CHANGED（按上面的义务处理）。现有的"(deleted) 旧二进制"检查（`y700-checklist.py:472-485`）会在重编后没重启时报出来，不用改。

### 5.3 B（任务书点名，不推荐）：`dpkg-divert` 换掉包里的二进制

```sh
# 编译与测试同 C 的前半段，然后：
systemctl stop tb323fu-emergency-key
dpkg-divert --local --rename --divert /usr/libexec/tb323fu/keyhold.distrib --add /usr/libexec/tb323fu/keyhold
install -m755 /usr/local/src/y700-keyhold/keyhold /usr/libexec/tb323fu/keyhold
systemctl start tb323fu-emergency-key
dpkg-divert --list '*keyhold*'        # local diversion of /usr/libexec/tb323fu/keyhold to …keyhold.distrib
```

回滚：

```sh
systemctl stop tb323fu-emergency-key
rm /usr/libexec/tb323fu/keyhold
dpkg-divert --local --rename --remove /usr/libexec/tb323fu/keyhold
systemctl start tb323fu-emergency-key
dpkg --verify tb323fu-platform        # 应无输出
```

代价与不推荐的理由：

- 下次 `tb323fu-platform` 升级时，dpkg 把新版 keyhold 静默写到 `keyhold.distrib`，不提示、不失败，我们的二进制继续顶替——和 C 一样会遮住上游的新版，但**作用于全系统**（任何人手工跑 `/usr/libexec/tb323fu/keyhold` 都拿到我们的），而且改动在 dpkg 数据库里（`dpkg -S` 显示 "diversion by local"）。
- 这台机有前车之鉴：README 127 行"Codex 留下的坑"——6 个平台包文件被 `dpkg-divert --local` 换成空壳，紧急键在桌面里失效，作者花了一轮才撤掉、恢复 `dpkg --verify` 干净。往后看到 local divert 就该当成异常，不要再制造一个"合法的"。
- C 能做到的它都能做到，C 的回滚只是删一个文件；没有理由选 B。

### 5.4 否掉的做法

- 直接 `install` 覆盖 `/usr/libexec/tb323fu/keyhold`：下次升级被包里的版本静默覆盖回去，期间 `dpkg --verify` 报 `??5??????`。
- `KEYHOLD=` 写进 `emergency-key.conf`：见 §5.2（helper 整文件重写；conffile）。
- 改 initramfs 里的 keyhold：那份只活到 switch_root（§1），对熄屏功耗没有意义；等上游下一次出镜像自然带上。

## 6. 验证（A、C 通用；B 同 C）

### 6.1 二进制测试（服务停着；按键项要作者按）

服务在跑时按组合键会被服务里的那份 keyhold 一起看到，按满 `HOLD_SECONDS` 就真的回安卓——所以先 `systemctl stop tb323fu-emergency-key`，测完 `systemctl start tb323fu-emergency-key`（C 的安装流程里已经包含）。

```sh
K=/usr/local/src/y700-keyhold/keyhold        # A 路线用 /usr/libexec/tb323fu/keyhold
$K; echo "rc=$?"                              # usage: … SECONDS NAME:CODE [NAME:CODE ...]   rc=2
$K 3 nosuchdev:1; echo "rc=$?"                # keyhold: no input device 'nosuchdev'          rc=1
$K 3 pmic_resin:114 gpio-keys:115; echo "rc=$?"
#   按住音量上+下 → 立刻 hold；继续按满 3 s → done，rc=0
#   再跑一次：按住约 1 s 就松开 → hold、release；然后 Ctrl-C
#   再跑一次：先按住两个键，再回车启动 → 立刻 hold，3 s 后 done
strace -f -e trace=ppoll,ioctl timeout 5 $K 30 pmic_resin:114 gpio-keys:115
#   不按键：扫描用的 EVIOCGNAME、两次 EVIOCGKEY 之后停在 ppoll([...], 2, NULL, NULL, …)，5 s 内没有任何周期性的行，然后被 timeout 的 SIGTERM 结束
```

### 6.2 进程级（服务起来后，熄屏、不碰键）

```sh
systemctl is-active tb323fu-emergency-key
pid=$(pgrep -x keyhold); echo "$pid"                                   # 只有一个
cmp /proc/$pid/exe /usr/local/libexec/tb323fu/keyhold && echo ours     # C 路线；A 路线比 /usr/libexec/tb323fu/keyhold
cat /proc/$pid/wchan; echo                                             # 不应再是 hrtimer_nanosleep
a=$(awk '/^voluntary_ctxt_switches/ {print $2}' /proc/$pid/status); sleep 60
b=$(awk '/^voluntary_ctxt_switches/ {print $2}' /proc/$pid/status); echo "ctxsw/60s=$((b - a))"   # 0（原版约 300）
# C 路线：back-to-android 的 cur_root 在服务命名空间里与主机一致
h=$(awk '$5 == "/" { m = $3 } END { print m }' /proc/self/mountinfo)
n=$(nsenter -t "$pid" -m awk '$5 == "/" { m = $3 } END { print m }' /proc/self/mountinfo)
[ "$h" = "$n" ] && echo "cur_root ok ($h)" || echo "cur_root DIFFERS: host=$h service=$n -- roll back"
```

### 6.3 服务内功能（作者在场）

短按组合键约 3 秒后松开——**务必在 `HOLD_SECONDS`（默认 10 s）之前松开**，否则会真的把 `boot_b` 写回 `boot_a` 并重启进安卓。`dmesg | tail -3` 应看到 `tb323fu: >>> volume up+down held: keep holding 10 s to go back to Android` 和 `tb323fu: >>> (released: not restoring)`。这一步同时证明：KWin 在跑时、测试那一刻没有人 grab 这两个设备（§2.5；以后有人 grab 它证明不了）。顺序上建议**先按音量上、最后按音量下**和**先按音量下、最后按音量上**各试一次——只要有一个设备被 grab，两种顺序里会有一种看不到 `hold`（§2.5）。

### 6.4 唤醒表

按 WAKEUPS §1 的规矩（`systemd-run`、从局域网上去）录 `y700-wakeups 60 --off`，keyhold 应从 `hrtimer:hrtimer_wakeup → 进程` 表里消失；和上一次基线比 `idle exits/s per CPU` 的 total，预期 −5 左右（在噪声里，不作判据）。

## 7. 顺带发现（都没在平板上验证）

1. **关掉紧急键要等服务重启才生效**（源码推断）：包装脚本只在循环顶部读 conf（`tb323fu-emergency-key:19-20`），而 keyhold 一直跑到组合键完成才退出；helper 的 `SetEnabled` / `SetHoldSeconds`（`tb323fu-ctl emergency-key off|hold N`）只重写文件（v0.4.2 `features.rs:645-658`、`ifaces.rs:914-928`），不重启服务。所以 `off` 之后，正在跑的 keyhold 仍然武装着，按住 10 s 照样回安卓，直到服务重启或重启机器；改 `HOLD_SECONDS` 同理。安全的复现：`tb323fu-ctl emergency-key off` 后短按组合键 2–3 s 再松开，若 `dmesg` 仍出现 `>>> volume up+down held` 就证实了（**一定在 10 s 前松开**）。修法（上游）：helper 写完文件后 `systemctl try-restart tb323fu-emergency-key.service`。已写进上游草稿的"related"一节。
2. **postinst 不重启紧急键服务**：`build-debs.sh:96-103` 只 `daemon-reload` + `enable`。README 527 行已经实测到 0.4.1→0.4.2 后 keyhold 跑着被删掉的旧文件。这对本补丁的意义：上游发布修复后，不手动重启或不重启机器，新 keyhold 不会生效。也写进了草稿。
3. 原版的小毛病，补丁**有意没碰**（保持可观察行为）：`code` 不检查范围（`k[code / 8]`，`code > KEY_MAX` 越界读，负数时 `1 << 负数` 未定义）；`EVIOCGNAME` 名字 ≥128 字节时 `n` 不以 NUL 结尾。对固定参数 `114/115` 和这两个设备名都无影响。
4. 缺设备时外层脚本每 1 s 重跑一次 keyhold（fork+exec、扫 64 个节点、往日志写一行错误）——只在设备真的缺失的坏配置里发生，本机不会，不处理。

## 8. 有意不做

- **不加 inotify、不改"设备消失后不退出"**：原版没有重扫，语义保持；让 keyhold 在设备消失时 exit 1 交给外层重启也许更好，但那是行为改变，留给上游决定（草稿里没提，避免把一个省电 PR 变成设计讨论；需要时再开）。
- **不改 `kernel/initramfs/init:102` 的注释**（"keyhold polls both keys"）：它是启动镜像的一部分，补丁的 `---` 说明里提醒了维护者。
- **不碰 README.md、`y700-checklist`**：README 段落在 §10，体检项在 §5.2，由合并的人落地。
- **不发帖、不启动 WSL、不在 Win11 上装编译器、不下载 deb 二进制**。

## 9. 未验证

1. **C 代码没编译过**（§3.5）：头文件、类型、`-Wall -Wextra` 警告全部未知；有的只是 pycparser 的语法/作用域/参数个数检查、人工的 `-Wextra` 过目、模型测试（§3.4）和 `git apply --check` / `git am`。模型测试测的是 Python 转写，转写与 C 是否一致靠人眼对照。
2. 没在平板上跑过：`wchan` 的新名字、`voluntary_ctxt_switches` 归零、strace 里的 `ppoll(…, NULL, NULL)`、实际 `done` 偏差约 10 ms，全是从源码推出来的预期。
3. ~~内核行号来自 master，不是 rc4~~（复核已核：`v7.3-rc4` 与 master 的 `evdev.c`、`input.c`、`select.c`、`sleep_timeout.c` 逐字节相同，`linux/` 下所有内核补丁都不碰它们）。仍未核：平板上跑的 y10 构建是否真由这些源码编出（只看了 kbuild 脚本和补丁清单）。（10-19 补，X43：现役 y12 的 config 与 y10 相同、1046–1048 不碰 evdev/input/gpio-keys，结论不变）
4. grab：查了 libinput 1.31.1 的 `src/`、KWin 6.6 的 4 个文件、gamescope 3.16.20 的 `src/` 和它内嵌 wlroots 的 libinput/session 后端、上游仓库、本仓库、平板包清单里的重映射工具名；**Steam（闭源）和其它已装的包没查**；设备上无法直接列出 grab 者，§6.3 只证明测试那一刻。
5. C 路线的命名空间副作用（`back-to-android` 在私有挂载命名空间里）只做了推理加 systemd 源码（`/` 是主机根的递归绑定），§6.2 的 `nsenter` 核对只覆盖 `cur_root`；`dd` + 重启那段无法不回安卓地测。
6. ~~懒卸载凭记忆~~（复核已读 v7.3-rc4 的 `vfs_rename()` / `__detach_mounts()`，§5.2）；仍凭记忆的只有"dpkg 用 `rename()` 盖旧文件"这一步（没读 dpkg 源码）。
7. §7.1"关掉紧急键要等重启"只是读源码，没复现。
8. 功耗数字全是模型和粗估；单次唤醒的能量没有测量；装了也测不出（§4）。
9. 没下载 0.4.2 的 `tb323fu-platform_0.4.2_arm64.deb` 核对里面的 keyhold 二进制是否就是这份源码编的（只核对了 tag 源码与任务书转述的 usage 文本、命令行一致）。
10. `-Wextra` 的人工过目、`_FORTIFY_SOURCE=3` 下 `ppoll()` 对象大小检查能过、`ENOMEM`/`EINTR` 碰不到（§3.1，`poll_table_entry` 约 64 字节是推算）——都是推断。

## 10. README 已合并段落（提交 1814212，2026-10-16，位于 README「熄屏唤醒治理」第二批）

> 原题「README 待合并段落（合并时放进"## 熄屏唤醒治理"一节，并改掉错误描述）」——10-19 核对 X43，已合并，以下留作原稿。

行号说明：文中"README 115、127、527、1009 行"都是**提交 `ddbaf3e` 里的 README**；复核时工作区的 README 已有未提交的 2 行改动（527→529、1009→1011），合并时按文字找（搜 "我们自己的屏幕键盘按键助手"），别按行号。

> - **`keyhold` 5/s（10-16 上午，只读研究，补丁未编译、未装）**：之前的唤醒记录说它是"我们自己的屏幕键盘按键助手"是错的——它是上游 `tb323fu-platform` 的**紧急回安卓组合键**（音量上+下按住 10 s）监视器。`keyhold.c:78-97` 每轮 `EVIOCGKEY` 后无条件 `usleep(200000)`，与有没有人按键无关。轮询对正确性唯一的贡献是对别人的 `EVIOCGRAB` 免疫（事件驱动版遇到 grab 时只在另一个键最后按下时认得出组合键；本机查不到 grab 这两个设备的程序，Steam 闭源没查）。事件驱动版：[keyhold.c](keyhold.c)、补丁 [keyhold-event-driven.patch](keyhold-event-driven.patch)（对 `helper-v0.4.2` = 上游 `main`，`git apply --check` / `git am` 通过；Win11 无编译器，**没编译**）、模型测试 [keyhold-model-test.py](keyhold-model-test.py)（两版 `main()` 转写 + 按 v7.3-rc4 写的 evdev 队列模型，2000 条随机时间线与原版逐行一致，不碰键时 0 次唤醒）、上游 PR 草稿（**未发**，不在公开仓库中）、说明 [KEYHOLD.md](KEYHOLD.md)。值：−5 次唤醒/秒；功耗今天（旋钮关）亚毫瓦、测不出，apps-pc 放开时约 0.5–7 mW（两种估法的包络），电池读数量不出来。部署：**走官方渠道**——作者测完发 PR，等新版 deb，装完 `systemctl restart tb323fu-emergency-key`（postinst 不重启它）；要提前去掉就用 drop-in [y700-keyhold-local.conf](y700-keyhold-local.conf)（`BindReadOnlyPaths=-/usr/local/libexec/tb323fu/keyhold:/usr/libexec/tb323fu/keyhold`，只对这个服务生效、不碰包文件），**不用 dpkg-divert**（"Codex 留下的坑"）。周期性义务（装了 drop-in 才有）：每次 `tb323fu-platform` 升级看上游 `keyhold.c` 是否已事件驱动，是就删 drop-in。顺带发现（源码推断，未复现）：`tb323fu-ctl emergency-key off` / 改按住秒数要等服务重启才生效。

## 11. 出处

- 上游 tb323fu-linux tag `helper-v0.4.2`（https://github.com/joonhoekim/tb323fu-linux/tree/helper-v0.4.2）：`userspace/platform/src/keyhold.c`、`userspace/platform/libexec/tb323fu-emergency-key`、`userspace/platform/systemd/system/tb323fu-emergency-key.service`、`userspace/platform/etc/tb323fu/emergency-key.conf`、`userspace/platform/install.sh:56-61`（`$CC -O2 -Wall`）、`packaging/debian/build-debs.sh:68-71,84-108`、`kernel/initramfs/init:95-122,515-528`、`kernel/initramfs/build.sh:74`、`helper/crates/tb323fu-helper-core/src/features.rs:633-658`、`helper/crates/tb323fu-helperd/src/ifaces.rs:905-928`、`android/back-to-android`、`CONTRIBUTING.md`（这两个和 `kernel/initramfs/build.sh` 与本地副本逐字节相同；两个 helper 的 .rs 本地副本较旧、行号不同，以 v0.4.2 为准）、`docs/helper-reference.md:17`（文件别处与本地副本有差异，这一行相同）。
- Linux `v7.3-rc4`（这四个文件与 master 2f2f7ee 逐字节相同）：`drivers/input/evdev.c`（`:104-142` flush、`:220-245` `__pass_event` 溢出、`:247-292` pass_values、`:305-311` grab 分发、`:419` hangup、`:561-610` read、`:613-627` poll、`:889-915` get_val、`:946-949` revoke、`:1157-1158` EVIOCGKEY、`:1272-1273` ENODEV）、`drivers/input/input.c:111-140,208-250`、`fs/select.c:51-91,158-170,234-256,860-970,971-1009`、`kernel/time/sleep_timeout.c:189-225`；复核另读：`fs/namei.c:6075-6220`（`vfs_rename`）、`fs/namespace.c:839-851,1981-2002`、`include/linux/poll.h:17-22`（kernel.org cgit）。
- libinput 1.31.1（https://gitlab.freedesktop.org/libinput/libinput/-/tree/1.31.1）：`src/` 全部 96 个文件、`tools/shared.c:494`。KWin Plasma/6.6（https://github.com/KDE/kwin/tree/Plasma/6.6）：`src/backends/libinput/{context,connection,device}.cpp`、`src/core/session_logind.cpp`。gamescope tag `3.16.20`（`0b445d9`）`src/`，及其子模块 `Joshua-Ashton/wlroots@54e8447` 的 `backend/libinput/{backend,events,keyboard}.c`、`backend/session/session.c`。systemd `v259.5`（平板版本）`man/systemd.exec.xml`（`BindPaths=`/`BindReadOnlyPaths=` `:447-484`，与 v258 的 `:448-483` 逐字相同；`PrivateMounts=` `:2748` 起）、`src/core/namespace.c:1993-1996,2636,3032`。
- 本仓库：README（提交 `ddbaf3e`）115、127、527、1009–1010 行；[WAKEUPS.md](WAKEUPS.md) §0、§1、§3；[cx-collapse/PROTOCOL.md](cx-collapse/PROTOCOL.md) §9；`linux/kernel-y8/config-t49-y9:2333,2347,2497`、`kbuild-y10.sh:4`、`inventory/{input-devices,dmesg,packages}`；`tools/y700-checklist.py:472-485`、`tools/y700-dpms-probe.py:17`。

## 12. 独立复核（2026-10-16 上午，离线，没碰平板、没提交）

逐条重读了文中引用的源码行（上游 tag、内核 v7.3-rc4、systemd v259.5、libinput、KWin、gamescope）和本仓库文件，重新跑了补丁的 `git apply` / `git am`，C 代码按正确性（边界、错误路径、信号、竞态、资源、权限）人工过了一遍。**结论不变**：轮询只为 grab 免疫买单；补丁逻辑正确；部署首选 A。改了这些：

- 版本：上游 `main` 在 10-16 就等于 `helper-v0.4.2`（`43ee432`），`0c7c0c4` 只是本地副本——补丁说明和草稿里的"main 0c7c0c4"改掉了（§开头）。
- 内核行号：原稿只核了 master，复核取了 v7.3-rc4 的四个文件，逐字节相同；原稿"evdev.c 此后的两次提交"的说法不成立（rc4 与 master 之间这个文件没变），删掉了。
- grab 取舍原稿说"看不见组合键"，过于笼统：模型跑出来是"只在另一个键最后按下时才认得出；按住期间被 grab 的那个键松开又按回察觉不到"（§2.5），补丁说明、草稿、§6.3 的测试步骤都按这个改了；gamescope 补查了（无 grab），Steam 仍未查。
- 功耗：原稿"1–5 mW，取两种估法的交叠"——两个区间（0.5–1.3 mW 与 4–7 mW）并不重叠，且 0.15 W/100% 驻留是含 drop-in 的上限；改成包络 0.5–7 mW；"今天几十 µW"改成"亚毫瓦、具体数没有依据"（§4）。
- 测试：原稿的 8 场景模型不模拟 `SYN_REPORT` 残留、队列溢出、调用之间的竞态、slack，也没和原版比；换成入库的 [keyhold-model-test.py](keyhold-model-test.py)（§3.4，含变异检查），另加了 pycparser 检查（§3.5）。都通过。
- `ppoll()` 出错分支：原稿说"这里只可能是 ENOMEM"，实际 `n ≤ 8`、没有信号处理函数时 `ENOMEM` 和 `EINTR` 都碰不到，是纯防御代码（§3.1）。
- 部署：C 的安装加了"作者当轮同意""体检同轮落地"、`scp -i ~/.ssh/y700_ed25519`、`start` 之后 `sleep 2` 再 `is-active`（Type=simple 的 start 在 fork 后就返回，命名空间失败要等一下才看得出）并当场 `cmp` 确认跑的是我们的二进制；回滚同样加了等待；drop-in 文件里"package upgrades are not affected"不准确（升级会拆掉服务里的绑定，直到重启服务），改了注释。懒卸载那条原稿凭记忆，复核读了 `vfs_rename()` / `__detach_mounts()` 证实（§5.2）。
- README 行号：都是提交 `ddbaf3e` 里的；工作区 README 另有 2 行未提交改动，合并时按文字找（§10）。

C 源码 `keyhold.c` 没有改（sha256 仍是 `73beb1af…164c`，§5.2 的核对值不变）。复核也**没能编译**它：本机仍无编译器，WSL 不启动的理由同 §3.5。

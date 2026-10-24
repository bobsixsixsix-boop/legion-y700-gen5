# y700-kmsg-watch：把两个"每分钟看一眼"的看门狗定时器换成内核日志事件触发

> 状态：**2026-10-16 写成，全部离线**（本仓库 + 公开源码；平板上正在跑无人值守的功耗测量，没有 ssh/scp/ping 过它），**没装、没上机**。PC 上的离线自测 `y700-kmsg-watch-selftest.py` 72 项全过（在作者机器上；公开仓库没有作者的开机日志，T2/T3 跳过）；体检补丁 `git apply --check` 通过、打补丁后的体检自测 0 失败。**同日独立复审**（§12）：源码行号逐条复核；修了可选安全网 drop-in 的一个真 bug（两次清空把 `OnBootSec` 也清掉了，watcher 开机就死时安全网永远不响）；在 PC 的 WSL Ubuntu 26.04（python 3.14.4 / systemd 259.5 / glibc 2.43，与平板同版本，但 x86_64、内核 6.18）上用新写的 `y700-kmsg-watch-realtest.py` 实跑了真 `/dev/kmsg` 和**单元里全部沙箱设置**下的守护进程（§12.2）。
> 出处约定：内核 = 主线 **v7.3-rc4**（GitHub raw，2026-10-16 读；平板 = 7.3.0-rc4 + 上游补丁 + y 补丁，本仓库里的补丁没有一个碰 `kernel/printk/`、`fs/select.c`、`kernel/time/sleep_timeout.c`）；systemd = **v259.5**（平板 `systemd 259.5-0ubuntu3.4`）；CPython = **v3.14.4**（平板 `python3.14 3.14.4-1ubuntu0.2`）；glibc = GitHub 镜像 **master**（2.43 的 tag 镜像上没有，平板 `libc6 2.43-2ubuntu2.4`；复审补查：`glibc-2.42` tag 的 `poll.c` 与 master 只差版权年份，这个文件 2025-01 以来只有改版权年份的提交，所以 2.43 必然相同）。上游 tb323fu-linux 用的是本地副本（与本题无关的 helper 0.4.2 没读）。lore/patchwork 没用。
> 读者：作者，以及接手"熄屏不休眠还能不能再省"的下一个工程师。先读 §0，部署看 §4–§6。

## 0. 一页纸

- **为什么**：`y700-wifi-watchdog` 和 `y700-display-watchdog`（README「Wi‑Fi 睡醒后固件发不出包」「整机卡顿 = 显示引擎 vblank 超时」两节）各由一个 `OnUnitActiveSec=1min` 的 timer 拉起。需求里给的 10-16 熄屏 27 分钟实测：两个都约 65 s 响一次（**仓库里没找到这次测量的原始记录**）。每响一次 = 一个 systemd job、一个 cgroup 的建和删、`/bin/sh` + `date` + `$(journalctl -k --since … | grep -c …)`（脚本第 15–17 行 / 14–16 行），再加 PID 1 写进日志的 Starting/Finished 几行——**99.99 % 的时候结论是"没事，exit 0"**。
- **做了什么**：一个常驻小进程 `y700-kmsg-watch`（Python，单线程）阻塞在 `/dev/kmsg` 的 `poll()` 上。内核日志安静时它**一次都不醒**；内核记下一条带 `failed to flush transmit queue` / `vblank timeout` 的**内核**日志（facility 0）时，它在 5 s 后 `systemctl start --no-block` 对应的**现有** oneshot 单元，同一个看门狗 20 s 内最多启动一次。两个脚本**一个字没改**：阈值、回看窗口、冷却、Wi‑Fi 开关、恢复、通知全在脚本里。
- **零唤醒的证明**（§2.2）：空闲时的调用链是 `poll(-1)` → glibc `ppoll(…, NULL)` → 内核 `do_poll(end_time=NULL)` → `schedule_hrtimeout_range(NULL)` = 不挂任何 hrtimer 的 `schedule()`；唯一能叫醒它的是 printk 存下新记录时的 `wake_up_klogd()`（或信号）。只有在"刚看到匹配行、启动已排期"的 ≤20 s 里才有超时。
- **值多少（诚实版）**：省掉的是每小时约 110 次单元启停、约 9 次/分钟的 fork（§3 推算）；换算成 idle 退出约 **1–3 次/秒**（基线 300–500 次/秒的 ≤1 %），功耗约 **0.1–1 mW**，**电池电量计测不出**（5–8 s 一个读数、±0.03 W 噪声）。它和 WAKEUPS.md 的其它项一样，是"把周期性唤醒清干净"的一块，不是单独能在功耗表上看到的一项。能直接测的代理指标见 §5（`/proc/stat` 的 `processes` 增量、单元启动次数、`/proc/<pid>/syscall`）。
- **兜底**：进程挂了 `Restart=always`（5 s 起步、退避到 10 min、永不放弃）；重启后先把两个看门狗各踢一次（让脚本回看窗口覆盖断档）；"活着但聋了"由每天的 `y700-checklist` 用 `--selftest` 经 `/dev/kmsg` ping 一次发现。**15 分钟的安全定时器：不默认保留**（§7），想要双保险有现成的 drop-in。
- **和 timer 版不完全等价的一处**（§2.3 末）：timer 每分钟"按窗口重看"，watcher 只在**有新匹配行时**才叫脚本看。脚本因冷却（成功后 10 min、失败后 3 min）说"等着"之后，如果日志恰好不再来新行，冷却到期时 timer 还会再看一次（只要窗口里的旧行还够数），watcher 不会——要等下一行。

## 1. 文件

| 文件 | 平板上的位置 | 作用 |
|---|---|---|
| `y700-kmsg-watch` | `/usr/local/libexec/y700-kmsg-watch`（755） | 守护进程本体；`--selftest` 是给 root 从外面 ping 它的客户端 |
| `y700-kmsg-watch.service` | `/etc/systemd/system/` | 常驻单元：root、只留 `CAP_SYSLOG`、设备白名单只有 `/dev/kmsg r`、`SCHED_IDLE` |
| `y700-kmsg-watch-selftest.py` | 不装（PC 上跑） | 离线自测：模拟 `/dev/kmsg` 记录流 + 假时钟 + 假 systemctl；用平板真实的内核日志 |
| `y700-kmsg-watch-realtest.py` | 不装（任何 Linux 上 root 跑，平板上是部署前一步） | 真内核 + 真 systemd 测试（复审时加）：真 `/dev/kmsg` 语义、真 `daemon()`（systemctl 换成桩）、`--sandbox` 时在单元的**全部**设置下以临时单元运行、去启动两个临时空单元 |
| `y700-checklist-kmsg-watch.patch` | 打在 `tools/y700-checklist.py`（+ 其自测）上 | 体检：装了 watcher 就查它（含 `--selftest`），不再要求两个 timer active；没装时行为不变 |
| `y700-watchdog-safety.conf` | **默认不装**；可选放进两个 `*.timer.d/` | 可选安全网：旧 timer 改成 15 分钟一次 |
| `y700-wifi-watchdog`、`y700-display-watchdog` 及其 `.service`、`.timer` | 原样 | 不改；timer 文件保留但停用 |

离线自测：在仓库根目录 `python -X utf8 -I linux/net/y700-kmsg-watch-selftest.py`（exit 0 = 全过）。公开仓库不含 T2/T3 用的作者开机日志 `linux/kernel-y8/inventory/dmesg`（可能带 MAC/蓝牙地址和序列号，见该目录的 `.gitignore`），这两组打 `SKIP`，其余照跑；T3 断言的是那次开机的具体数字，换成自己的 dmesg 也不会过。2026-10-16 在 Win11（Python 3.12.10）上 69 项全过。顺手做了变异测试——把 watcher 改坏再跑：去掉 facility 过滤、空闲时 poll 改成 60 s 超时、`SEEK_END` 改成 `SEEK_SET`、去掉 20 s 去抖、去掉 `DRAIN_MAX` 上限，五种改法各自都让自测失败（T7 / T12 / T12 / T6+T11+T12 / T11；复审重做了这五种，结论相同）。复审后 72 项全过：新增 T12b（`daemon()` 按运行时的 `RESULT` 写答复）和 T14 两项（按 systemd 的合并规则算出"timer + 安全网 drop-in"的最终定时器表；断言旧的两次清空写法会丢 `OnBootSec`）；变异：把 `daemon()` 那一行改回去，T12b 失败；把 drop-in 改回两次清空，T14 的 drop-in 内容和合并结果两项失败。体检补丁：`git apply --check` 通过；在临时副本里打上补丁后 `tools/y700-checklist-selftest.py` 0 失败（新增场景 S11–S11f），未打补丁的原版也 0 失败。

## 2. 设计

### 2.1 `/dev/kmsg` 的读法（`kernel/printk/printk.c`，v7.3-rc4 行号）

- **打开**：`devkmsg_open()` :920–949。只读打开要过 `check_syslog_permissions(SYSLOG_ACTION_READ_ALL, …)`（:930）：只有 `kernel.dmesg_restrict=1` 时才要 `CAP_SYSLOG`（:603–633）。本机 `config-running` 里 `CONFIG_SECURITY_DMESG_RESTRICT` 没开，但 sysctl.d 有没有把它置 1 没核对——所以单元里留着 `CAP_SYSLOG`，两种情况都能读。`printk.devkmsg=off` 时连读都 `-EPERM`（:925）；本机 cmdline（`inventory/cmdline`、`kbuild-y10.sh` 的 CMDLINE）没有这个参数。
- **起点**：打开时 `seq = prb_first_valid_seq()`（:945）= 环里最老的一条，也就是环里还留着的全部（最多 4 MiB 文本，`CONFIG_LOG_BUF_SHIFT=22`）。所以打开后立刻 `lseek(fd, 0, SEEK_END)`：`devkmsg_llseek()` :870–899，offset 必须为 0（否则 `-ESPIPE`，:876），`SEEK_END` = `prb_next_seq()`（:893），只读之后的新记录。重启也一样从尾部开始——一条让它崩溃的"毒记录"不会被重读。
- **读**：一次 `read()` 恰好一条记录（:801–861）。没有记录时 `O_NONBLOCK` → `-EAGAIN`（:817），阻塞模式 `wait_event_interruptible(log_wait, …)`（无超时）。**记录被覆盖**（我们读得太慢）→ 位置被重置到最老的一条、返回 `-EPIPE`（:838–842）。**缓冲区比记录小** → `-EINVAL`，而且序号已经先加 1 了（:845 在 :847 之前），这条就丢了——所以 `READ_MAX = 8192`，远大于格式化上限 `PRINTK_MESSAGE_MAX 2048`（`kernel/printk/internal.h:48`）。这也是 shell 的 `read` 不能直接读 `/dev/kmsg` 的原因（逐字节读，1 字节的缓冲区每次都 `-EINVAL`）。
- **poll**：`devkmsg_poll()` :901–918，`poll_wait(file, &log_wait, …)`；有记录 → `EPOLLIN`，位置已被覆盖时再加 `EPOLLERR|EPOLLPRI`（:912，随后的 read 拿到 `-EPIPE`，已处理）。
- **格式**：`info_print_ext_header()` :641–660 + `msg_print_ext_body()` :699–716：`<prio>,<seq>,<usec>,<flag>[,caller=…];<正文>\n[ SUBSYSTEM=…\n DEVICE=…\n]`，`prio = facility<<3 | level`；正文里 <0x20、≥0x7f 的字节和反斜杠一律转义成 `\xNN`（:662–681），所以正文是 ASCII、不跨行，第一个换行之后是设备字典。本机 `CONFIG_PRINTK_CALLER` 没开，没有 `caller=` 字段（解析器两种都认）。
- **谁能冒充内核**：用户态写 `/dev/kmsg` 时 facility 缺省是 `LOG_USER`=1（:743），带 `<N>` 前缀也只接受非 0 的 facility（:789）——**用户态永远写不出 facility 0**。watcher 只认 facility 0 的匹配行，于是 journald/systemd、上游 `tb323fu-emergency-key` 的 `echo "<1>tb323fu: …" > /dev/kmsg`（`userspace/platform/libexec/tb323fu-emergency-key:16`）、以及任何人手写的同样文字，都触发不了看门狗。单元的设备白名单只给 `/dev/kmsg` 读权限，watcher 自己也写不进去，不可能自激。
- **两句原文**（看门狗脚本 grep 的就是它们，`WATCHES` 里一字不差，自测 T14 核对）：`drivers/net/wireless/ath/ath12k/mac.c:12669` `"failed to flush transmit queue, data pkts pending %d\n"`（`ath12k_warn`，带设备前缀 `ath12k_wifi7_pci 0000:01:00.0:`）；`drivers/gpu/drm/msm/disp/dpu1/dpu_encoder_phys_vid.c:545` `DPU_ERROR("vblank timeout: %x\n", …)`（本机实测行 `[drm:dpu_encoder_phys_vid_wait_for_commit_done:583] [dpu error]vblank timeout: 400000`，行号差是补丁造成的）。

### 2.2 为什么安静时一次都不醒（逐层，带行号）

1. watcher：`Watcher.timeout()` 在没有排期中的启动（`self.due` 为空）时返回 `None`；`daemon()` 里的 `wait()` 把 `None` 换成 `poller.poll(-1)`。自测 T2（真实开机日志去掉匹配行，3058 条、4253 s）断言**每一次** poll 都是无超时；T12 在假 `select` 上跑真正的 `daemon()`，记下的超时序列是 `[-1, 20001, -1]`（空闲、排期中、又空闲）。
2. CPython 3.14.4 `Modules/selectmodule.c`：`select_poll_poll_impl()` :621 起。watcher 传的是整数 `-1`（不是 `None`）：转换后 `timeout` 为负、不设 deadline（:646 的 `if (timeout >= 0)` 不成立），:654–660 把负数规范为 -1（传 `None` 也走到同一处），:681 `poll(self->ufds, self->ufd_len, (int)ms)`；被信号打断后只有 `timeout >= 0` 才重算期限（:693），否则原样再睡。
3. glibc `sysdeps/unix/sysv/linux/poll.c`（master）：aarch64 没有 `__NR_poll`，走 `SYSCALL_CANCEL (ppoll, fds, nfds, timeout_ts_p, NULL, 0)`，`timeout < 0` 时 `timeout_ts_p = NULL`。`__NR_ppoll` = 73（`include/uapi/asm-generic/unistd.h:194`）。
4. 内核 `fs/select.c`：`ppoll` :1092–1114，`tsp == NULL` → `to = NULL` → `do_sys_poll()` → `do_poll()` :883–972，`end_time` 为 NULL 时 `to` 一直是 NULL（:960–963），睡眠走 `poll_schedule_timeout(wait, TASK_INTERRUPTIBLE, NULL, 0)`（:234–257）→ `schedule_hrtimeout_range()` → `kernel/time/sleep_timeout.c:206–209`：`if (!expires) { schedule(); return -EINTR; }`——**不挂 hrtimer**。
5. 谁叫醒：`devkmsg_poll()` 把我们挂在 `log_wait` 上（printk.c:907）。`log_wait` 只在 `wake_up_klogd_work_func()` 里被 `wake_up_interruptible()`（:4601–4617），它由 `__wake_up_klogd()` 在**有等待者**时排的 irq_work 触发（:4646–4649，`IRQ_WORK_INIT_LAZY` :4620），调用方是 `vprintk_emit()`（:2423 起）存完新记录之后（:2486）、`defer_console_output()`、以及挂起恢复后的 `console_resume_all()`（:2818 起，:2848–2850）。后两种若没有新记录，poll 在内核里重新检查条件后接着睡，不回用户态。
6. 进程里没有别的东西会醒：单线程（没有 `threading`）、没有 `signal.alarm`/`setitimer`、没有 sd_notify 看门狗（单元不设 `WatchdogSec=`）。自测 T14 在 I/O 无关的核心代码里查不到 `sleep/alarm/setitimer/timerfd/threading`。
7. **实测（复审，WSL，§12.2）**：x86_64 有 `__NR_poll`，所以那里是 `poll` 而不是 `ppoll`——阻塞中的 `/proc/<pid>/syscall` = `7 … 0x1 0xffffffffffffffff …`（第 3 个参数 = 超时 -1），`wchan` = `poll_schedule_timeout`；真 `daemon()` 在 5 s 无内核记录的窗口里自愿上下文切换第二次跑 +0、第一次跑 +1（窗口紧跟在启动踢之后 0.5 s 开始，这 1 次多半是等最后一个 systemctl 桩退出的尾巴，没再细查）；在全部沙箱设置下同样停在无超时的 poll 里。aarch64 上的 `ppoll(…, NULL)` 这一层仍只有源码推理。

结论：**每条内核日志记录最多叫醒它一次（同一批一次），没有记录就是零**。顺带一提，journald（以及若开了 imklog 的 rsyslogd）本来就为每条内核记录醒一次，多它一个 Python 进程读一条记录约几十微秒。熄屏空闲时内核每小时写多少条，**没测**（§5 给了命令）。参考 `inventory/dmesg`（y8 内核的一次健康开机，亮屏）：全程 70 分钟平均 0.7 条/秒是被开机拖高的——0–60 s 1667 条，60–600 s 0.94 条/秒，600–1800 s 0.33 条/秒，**1800–3600 s 只有 35 条（0.019 条/秒）**，3600 s 之后 464 条又多起来，主要是 `dsiN: pclk=… byteclk=…`（显示模式切换）和 Awinic 功放的 `aw…` 每次放音/停音约 20 行。熄屏、不放音时应接近那 0.02 条/秒，即 watcher 自己每分钟醒约 1 次——和 timer 版相比可以忽略，但这是推断。PROTOCOL.md §9 里 journald→rsyslogd 的 7.7 条/秒是**所有来源**的日志，不是内核记录，不会叫醒 watcher（只有写进 `/dev/kmsg` 的才会）。

### 2.3 触发规则：SETTLE 5 s、DEBOUNCE 20 s

- 某看门狗第一次匹配后 **5 s** 启动它（让一阵爆发先到齐再让脚本数），且离它上一次启动**不少于 20 s**：`due = max(now + SETTLE, last + DEBOUNCE)`。排期中再来的匹配只计数。于是**每一条匹配行都会在 ≤20 s 内被一次启动"看到"**，日志风暴时每个看门狗每 20 s 最多一次。
- 为什么不是"第一条就立刻启动"：健康开机也会冒出成对的 vblank 超时（`inventory/dmesg`：70 分钟 10 行，168.35/168.42、250.93/250.99、572.61…574.94、4111.96/4112.02 s），立即启动 + 尾随启动会让每一对跑两次脚本；等 5 s 一对只跑一次。
- 和脚本窗口的关系：脚本各自回看 **180 s / ≥2 次**（Wi‑Fi）和 **60 s / ≥15 次**（显示）——自测从脚本源码里把这两个数读出来再判断"这次启动脚本会不会动手"，脚本改了阈值自测自动跟着变。
- 已经在跑的 oneshot 再 start：systemd 把新的 start 合并进正在运行的 start job，不会再跑一遍（`src/core/job.c:232–270` `job_install()` → `jobs_may_late_merge()` :186–211，start ⊇ start）。`--no-block` 让 watcher 不等脚本跑完。
- **启动时各踢一次**：刚开始读（开机或崩溃重启）时两个看门狗各 start 一次，脚本按自己的回看窗口把"watcher 还没在读"那段补上；这相当于原来 timer 的 `OnBootSec`。
- **记录丢失（-EPIPE）**：当作两个看门狗都匹配了一次（宁可多跑一次脚本）。4 MiB 的环要被覆盖得有上万条记录堆着没读，几乎只会发生在 `SCHED_IDLE` 的它被长时间饿着的时候。（复审补：`printk_get_next_message()` 的 `pmsg->dropped = r.info->seq - seq`（printk.c:3056）在**跳过数据丢失的记录**时也非 0，所以 -EPIPE 不只来自覆盖；处理方式一样。EPIPE 没有在真内核上强制制造过——要灌满 4 MiB 环，太扰民。）
- **边沿触发 vs. 电平触发（复审补，有意保留）**：timer 版每分钟按窗口重看一次，是"电平触发"；watcher 只在有新匹配行时叫脚本，是"边沿触发"。两者唯一的分歧：脚本因冷却说"等着"（Wi‑Fi 成功后 600 s、失败后 180 s；显示同）之后，**冷却在一段没有新匹配行的空档里到期**，而窗口（180 s / 60 s）里的旧行还够阈值——timer 会在到期后 ≤65 s 内动手，watcher 要等下一条匹配行。按两种故障的样子：Wi‑Fi 卡死时每次关联约 20 s 就失败一次，只要 NetworkManager 还在重试就不断有新行；它若用完自动重连次数停下来，行就成簇出现、簇间可能空几分钟，最坏多等到下一簇（NetworkManager 的重试节奏**没核对**）。显示卡死是"每次提交一行"，没人操作时本来就没有提交、也就没有新行，操作一恢复行就来。所以多出的延迟只在冷却到期那一刻、只到下一行为止。要严格等价就得把窗口/冷却搬进 watcher（与"判定只在脚本里"冲突）或者读脚本的 STAMP 文件（耦合），都不做；可选安全网（§7）也只在窗口里还有行时才帮得上。
- **`--selftest`**：root 往 `/dev/kmsg` 写一条 `<15>y700-kmsg-watch: selftest <token>`（user.debug：facility 1；级别 7 不会打到 tty1/ramoops 控制台——本机 `CONFIG_CONSOLE_LOGLEVEL_DEFAULT=7` 只打印 0–6，而不带前缀的写入缺省是 `CONFIG_MESSAGE_LOGLEVEL_DEFAULT=4`，会上控制台）；watcher 读到后**立即**启动两个看门狗、把每个 `systemctl` 的返回码和计数器写进 `/run/y700-kmsg-watch/selftest`；客户端 10 s 内读到同一个 token 就打印并 exit 0。它同时证明了"读得到内核日志"和"沙箱里能启动单元"。看门狗脚本看到的是正常的日志，没有匹配行就 exit 0，对系统无副作用。

自测里的几个场景（全部是模拟，时间是假时钟）：

| 场景 | 输入 | 启动 | 说明 |
|---|---|---|---|
| T3 健康开机 70 分钟（`inventory/dmesg` 原样回放） | 3070 条，含 10 行 vblank 超时 | 启动时 2 次 + 显示 4 次 | 4 次都不到阈值（脚本 exit 0）；同期两个 timer 约 131 次 |
| T4 03:41 死机前的日志（`crash-0341-lastkmsg.log`）压成 10 s | 420 条，36 行 vblank | 显示 1 次（首行后 5 s） | 那一次的 60 s 窗口里有 36 行 ≥15，脚本会动手 |
| T5 10-13 的 Wi‑Fi 故障：每次关联约 20 s 后一次 flush 失败 | 每 21 s 一行 × 6 | 每行一次（≥20 s 间隔） | 第 2 次启动（首行后 26 s）窗口里有 2 行，脚本重载驱动；timer 版最坏要等到第 2 行后约 65 s |
| T6 10-13 的显示风暴：每秒 2 行 + 伴随行，120 s | 480 条 | 7 次（3005、3025…3125 s） | 第 2 次（风暴开始后 25 s）就够阈值；240 行匹配只跑 7 次脚本 |
| T7 用户态写的同样文字 | facility 1/3 | 0 | facility 过滤 |
| T11 读不完的风暴（每读一条 10 ms、2 万条） | — | 首次在 5 s + 一轮 256 条之内 | `DRAIN_MAX` 让排期不被饿死 |

### 2.4 为什么是 Python 读 `/dev/kmsg`，不是 `journalctl -k -f` / `dmesg -W` / sh

- **`journalctl -k -f`**：`sd_journal_get_timeout()` 在本地文件系统上返回 `UINT64_MAX`（`src/libsystemd/sd-journal/sd-journal.c:2994–3016`，只有网络文件系统才 2 s 轮询），所以它自己没有周期定时器；**但**它用 inotify 盯日志目录的 `IN_MODIFY`（:2117、:2197），而 journald 每写一批就 `ftruncate()` 文件到原长度来制造 `IN_MODIFY`（`journal-file.c:2412–2427`，250 ms 合并一次：`journald-manager.c:80`、:314）——**任何单元的任何一行日志都会叫醒它**，`-k` 的过滤是醒来之后才做的。本机熄屏时 rsyslogd 每秒收 7.7 条（PROTOCOL.md §9 末的 y700-wakeups 样本），`journalctl -f` 会跟着每秒醒好几次。而且它要 mmap 全部日志文件，内存十几 MB 起。
- **sh**：`read` 逐字节读，读 `/dev/kmsg` 会 `-EINVAL` 并丢记录（§2.1）；`cat /dev/kmsg` 从最老一条开始（没有 SEEK_END）；去抖要后台 `sleep` 进程。`dmesg --follow-new`（util-linux 2.41.3 有）理论上能当输入源，但**没读它的源码**（不知道它对 `-EPIPE` 怎么处理），去抖照样要额外进程。
- **Python**：一个进程，只 import `os/select/signal/sys/time`，`#!/usr/bin/python3 -IS`（隔离模式、不加载 site）。RSS 估计 8–10 MB；复审在 WSL（同版本 python 3.14.4，x86_64）上实测：全部沙箱设置下 `VmRSS` 16.3 MB（含共享库页），单元 cgroup 的 `MemoryCurrent` 9.7 MB；平板（aarch64）上**没测**。`MemoryMax=48M` 对加上一个正在跑的 systemctl 子进程仍有余量。

### 2.5 沙箱：每一项为什么不碍事（systemd v259.5 源码）

被启动的看门狗单元由 PID 1 在**它们自己的单元**里 fork，watcher 的任何限制都不会传给 modprobe/nmcli/kscreen-doctor。

| 设置 | 为什么安全 / 为什么需要 |
|---|---|
| 以 root 运行 + `CapabilityBoundingSet=CAP_SYSLOG` | root 的 `systemctl` 直连 `/run/systemd/private`（`src/shared/bus-util.c:548–551`）；那个 socket 以 umask 0077 绑定（`src/core/dbus.c:932–934`，属主 root），uid 0 走属主位，不需要 `CAP_DAC_OVERRIDE`；PID 1 只核对对端 uid（`bus_check_peercred()` bus-util.c:222–240，dbus.c:658–662）；`StartUnit` 的授权 `sd_bus_query_sender_privilege(call, -1)`（`src/shared/bus-polkit.c:578`）在 capability 为 -1 时只比 uid，同 uid 即放行（`bus-convenience.c:707–739`）。所以**除了读 kmsg 可能要的 CAP_SYSLOG，一个能力都不需要**。非 root + polkit 规则能更严，但多一份授权规则要维护（§8）。 |
| `Environment=SYSTEMD_OFFLINE=0` | `systemctl start` 是"仅在线"动词，执行前判断自己是否在 chroot（`src/shared/verbs.c:14–40`、:131–134）：先看这个变量，没有才去比 `/proc/1/root` 和 `/`（`src/basic/virt.c:800–835`）。没有 `CAP_SYS_PTRACE` 时那次比较大概率失败（ptrace 访问检查，**推理、未实测**），而失败被当作"不在 chroot"（verbs.c:36–38）——本来也能工作，变量只是让它不依赖这条错误路径。 |
| `DevicePolicy=closed` + `DeviceAllow=/dev/kmsg r` | 只剩标准伪设备（`src/core/bpf-devices.c:413–422`：null/zero/full/random/urandom/tty/ptmx）加 kmsg 只读；cgroup BPF 设备过滤，`CONFIG_CGROUP_BPF=y`（config-t49-y9） |
| `ProtectClock=yes` | v259 里它只在**已有**设备策略时追加 `char-rtc r`（`src/core/unit.c:4471`、:4496），并去掉 `CAP_SYS_TIME/CAP_WAKE_ALARM`（:4421–4422）。（印象中较老的 systemd 会无条件加这条 rtc 白名单、从而把设备策略收紧到不含 kmsg——**没核对**；有了显式的 `DeviceAllow=/dev/kmsg r` 两种行为下都能读，升级 systemd 时每天的 `--selftest` 也会抓到。） |
| `ProtectSystem=strict`、`ProtectHome`、`PrivateTmp`、`ProtectKernelTunables/Modules`、`ProtectControlGroups`、`ProtectHostname` | `ProtectKernelTunables` 的表（`src/core/namespace.c:151–166`）不含 `/dev/kmsg`；只读的 `/run` 不妨碍连 socket：内核连路径型 unix socket 只做 `path_permission(&path, MAY_WRITE)`（`net/unix/af_unix.c:1225`），它不看挂载点的只读标志（`include/linux/fs.h:2719–2723`），只读超级块也只拦普通文件/目录/符号链接（`fs/namei.c:604–614`），socket inode 不在其列；`RuntimeDirectory=` 给 `--selftest` 留了可写的 `/run/y700-kmsg-watch` |
| `SystemCallFilter=@system-service` + `SystemCallErrorNumber=EPERM` | 含 `@io-event`（`ppoll`，`seccomp-util.c:616–636`）、`@process`（`clone3/wait4/…`，:818–847），`execve` 在 `@default`；被挡的调用返回 EPERM 而不是杀进程，watcher 会在日志里说 `cannot run systemctl` |
| `RestrictAddressFamilies=AF_UNIX`、`RestrictNamespaces`、`RestrictRealtime`、`RestrictSUIDSGID`、`LockPersonality`、`NoNewPrivileges`、`UMask=0077` | 只用到 unix socket 和普通文件 |
| `CPUSchedulingPolicy=idle`、`Nice=19`、`IOSchedulingClass=idle`、`MemoryMax=48M`、`TasksMax=8` | 醒着时也不和任何东西抢（子进程 systemctl 继承 SCHED_IDLE）；Nice 对 SCHED_IDLE 无效，留着是防有人把策略改回 other |
| `Restart=always`、`RestartSec=5s`、`RestartSteps=5`、`RestartMaxDelaySec=10min`、`StartLimitIntervalSec=0` | 崩了 5 s 后重启，连续失败时间隔指数增长到 10 min（`man/systemd.service.xml:596–623`），永不进入 start-limit 失败态 |
| **不设** `ProtectKernelLogs=` | 它让 `/dev/kmsg` 不可访问（namespace.c:186–193）并去掉 `CAP_SYSLOG`（unit.c:4418–4419） |
| **不设** `PrivateDevices=` | 私有 `/dev` 只有 API 伪设备、并隐含 `DevicePolicy=closed`（`systemd.exec.xml:1961` 起；unit.c:4466–4468），没有 kmsg |
| **不设** `WatchdogSec=` | 要周期性 sd_notify，正是要消灭的唤醒 |
| **不设** `MemoryDenyWriteExecute=` | 若 Ubuntu 的 python3.14 编进了 JIT 且默认开启，`mprotect(PROT_EXEC)` 被拒会在风暴时（热循环触发 JIT 编译）出事；**没核对**这版 python 的 JIT 构建选项，宁可不设 |
| **不设** `ProtectProc=`/`ProcSubset=` | PID 1 对 systemctl 不可见，收益小、没验证 |

单元里 37 个键名都在 v259.5 的 man 页（exec/service/resource-control/unit/kill）里核对过存在；**值没有经过 `systemd-analyze verify`**（PC 上没有 systemd）——部署第一步就是它。

复审补（WSL Ubuntu 26.04，`systemd 259.5-0ubuntu3.4` = 平板同一个包版本，§12.2）：`systemd-analyze verify` 对原样的单元只报 `/usr/local/libexec/y700-kmsg-watch` 不存在（那里没装，预期），把 `ExecStart` 指向仓库里的脚本后无输出、退出 0；`systemd-analyze security --offline=yes` 暴露分 **2.2 OK**。`realtest --sandbox` 用 `systemd-run` 把 `[Unit]`/`[Service]` 里除 `Description`/`ExecStart` 外的全部 34 项原样加在一个临时单元上（`RuntimeDirectory` 改名以免碰到真装的那份）：它读得到 `/dev/kmsg`（`DevicePolicy=closed` + `DeviceAllow`）、`CapEff` = 只有 `CAP_SYSLOG`、`NoNewPrivs 1`、`Seccomp 2`、调度策略 `SCHED_IDLE`、空闲时停在无超时的 poll；它在 `SystemCallFilter=@system-service` 下 `posix_spawn` 的 systemctl 两次启动两个临时空单元都返回 0（日志 `selftest … ok wifi=0 display=0`）——PID 1 先授权后排 job（`src/core/dbus-unit.c` `bus_unit_method_start_generic()`：`bus_verify_manage_units_async_full()` 在 `bus_unit_queue_job()` 之前），所以返回 0 就证明沙箱里的 StartUnit 被授权了；`systemctl stop` 后 `Deactivated successfully`（SIGTERM 是干净退出）。另做了一个对照：同样 `ProtectSystem=strict` 下 `/run` 是 `ro`，`RuntimeDirectory=` 那个目录可写。**这些是 x86_64 + 6.18 内核上的结果**，aarch64 的系统调用集合和 7.3 内核上的设备过滤仍以平板上 §4 的第一步（realtest）为准。

## 3. 定时器版到底花了什么（推算）

每次 timer 响（两个 timer 合计约每 32 s 一次）：PID 1 的 timerfd 醒、建 job、建 cgroup `system.slice/y700-*-watchdog.service`、fork `systemd-executor` 再 exec `/bin/sh`；脚本里 `now=$(date +%s)` 一个子进程，`n=$(journalctl … | grep -c …)` 一个子 shell 加两个进程（dash 的 fork 细节没核对，按 5 个进程/次估）；`journalctl -k --since -3min` 要打开并 mmap 日志目录里的文件、按时间二分；退出后 PID 1 处理 SIGCHLD、cgroup 空事件，删 cgroup（内核侧 css 下线/释放走 workqueue + RCU）；PID 1 给 journald 发 Starting/Finished 等几行，rsyslogd 再转写一遍。

- fork：约 5 个/次 × 每分钟约 1.85 次 ≈ **9 次/分钟**——这是最好测的一项（`/proc/stat` 的 `processes`）。
- idle 退出：每次估 30–60 次（跨核拉起子进程的 IPI、PID 1/journald/rsyslogd 各醒几次、kworker、rcuog），合计约 **1–3 次/秒**，占基线 300–500 次/秒的 ≤1 %。
- 功耗：每次约 40–80 ms 的 CPU 时间（journalctl 占大头），按单核低频 0.1–0.3 W 计 4–24 mJ/次，平均 **0.1–1 mW**；若 apps-pc（E3a 旋钮）开着，每次还挡住系统域约 0.1 s，折合不到 0.1 mW。**加起来测不出**。
- watcher 自己的花费：每条内核记录一次唤醒（约几十微秒 Python）；熄屏空闲时内核日志条数未知（§5 第 3 步给了命令），参考 `inventory/dmesg` 开机半小时后的 0.019 条/秒（§2.2 末）≈ 每分钟 1 次，对 1–3 次/秒的节省可以忽略；健康开机的前 70 分钟里显示看门狗被叫起 4 次。所以**净节省 ≈ 上面的估计**，前提是熄屏时内核日志真像那段一样安静——这正是 §5 第 3 步要测的。

## 4. 安装（平板上，root；**等无人值守的功耗测量结束后**、从局域网地址上去）

```sh
# 把 linux/net/y700-kmsg-watch、y700-kmsg-watch.service、y700-kmsg-watch-realtest.py 拷到平板同一个目录（例如 /tmp/），然后：
python3 -I /tmp/y700-kmsg-watch-realtest.py --sandbox                  # 真内核 + 真 systemd 预检，期望最后一行 "0 failures []"；
                                                                        # 不装任何东西：systemctl 换成桩 / 只启动它自己建的临时空单元 y700kw-*-rt，
                                                                        # 往 kmsg 写几行 user.debug 的 "y700kw-realtest …"；有 FAIL 就停下，别往下装
install -m755 /tmp/y700-kmsg-watch /usr/local/libexec/y700-kmsg-watch
install -m644 /tmp/y700-kmsg-watch.service /etc/systemd/system/y700-kmsg-watch.service
systemd-analyze verify /etc/systemd/system/y700-kmsg-watch.service      # 无输出 = 通过；有警告先停下看
systemctl daemon-reload
systemctl enable --now y700-kmsg-watch.service                          # 先起 watcher：它启动时会把两个看门狗各踢一次
/usr/local/libexec/y700-kmsg-watch --selftest                           # 期望：selftest <id> ok wifi=0 display=0; up … s, …
systemctl disable --now y700-wifi-watchdog.timer y700-display-watchdog.timer   # 再停 timer（文件留着）
```

体检（在 PC 的仓库里做）：`git apply linux/net/y700-checklist-kmsg-watch.patch`，跑 `python -X utf8 -I tools/y700-checklist-selftest.py`（应 0 失败），commit，然后把 `tools/y700-checklist.py` 装到平板 `/usr/local/bin/y700-checklist`。补丁对"没装 watcher"的平板行为不变，所以先打补丁后装 watcher、或者反过来都行。

`systemd-analyze security y700-kmsg-watch.service` 可以顺手看一眼暴露分数（只读）。

## 5. 验证

1. **在跑、能用**：`systemctl status y700-kmsg-watch` 为 active；`journalctl -u y700-kmsg-watch -b` 有一行 `reading /dev/kmsg from its end; …` 和两行 `start …: watcher start-up …`；`journalctl -u y700-wifi-watchdog -u y700-display-watchdog -n 4` 里两个脚本在那一刻各跑了一次、没有输出（低于阈值）；`--selftest` 返回 0。`systemctl list-timers | grep y700-` 里不再有两个看门狗 timer。
2. **空闲时确实不醒**（熄屏后）：
   ```sh
   pid=$(systemctl show -p MainPID --value y700-kmsg-watch)
   cat /proc/$pid/syscall        # 期望 "73 0x<fds> 0x1 0x0 …"：ppoll（73），nfds 1，第 3 个参数 tsp = 0x0（无超时）
   grep ctxt /proc/$pid/status   # 记下 voluntary_ctxt_switches，10 分钟后再看
   journalctl -k --since -10min -o short-monotonic | wc -l   # 同一段时间的内核记录数：上面的增量应 ≤ 它
   ```
   `/proc/<pid>/syscall` 的格式是 `nr arg1..arg6 sp pc`（`fs/proc/base.c` `proc_pid_syscall()`），关键只看第 3 个参数；在排期中的那 ≤20 s 里第 3 个参数会是一个指针，属正常。`voluntary_ctxt_switches` 的比较只在这 10 分钟里**没有触发过启动**时成立：每次启动它都要在 `waitpid` 里等 systemctl 退出，会多出几次切换（`journalctl -u y700-kmsg-watch --since -10min` 没有 `start …` 行即可）。
3. **省了什么**（与装之前同样条件各测一次，熄屏 10 分钟）：`grep processes /proc/stat` 的增量（期望少约 90）；`journalctl --since -10min | grep -c 'y700-.*-watchdog'`（期望从约 18×3 行降到 0）；`journalctl -k --since -1h | wc -l` 顺便记下熄屏时内核日志的速率（这就是 watcher 的唤醒率）。WAKEUPS.md 的 `y700-wakeups` 要开 **≥10 分钟**的窗口才看得到 timer 的那几簇，60 s 窗口里只有一两次，不适合比这一项。
4. **真实触发的第一次证据**：等它自然发生（健康开机也会有成对的 vblank 超时），`journalctl -u y700-kmsg-watch` 里出现 `start y700-display-watchdog.service: 2 matching lines since the last start, first: [drm:dpu_encoder_phys_vid_wait_for_commit_done:583] [dpu error]vblank timeout: 400000`，随后显示看门狗静默 exit 0。
5. **不要**用往 `/dev/kmsg` 写真实错误句子的办法测：watcher 不认（facility 过滤），但**脚本认**——`journalctl -k` 的 `_TRANSPORT=kernel` 也包括用户态写进 kmsg 的行，两行假的 flush 失败再加一次 `--selftest`（或旧 timer）就会让 Wi‑Fi 驱动真的被重载。这个暴露面在 timer 版就有，不是新引入的。

## 6. 回滚

```sh
systemctl disable --now y700-kmsg-watch.service
systemctl enable --now y700-wifi-watchdog.timer y700-display-watchdog.timer
rm /etc/systemd/system/y700-kmsg-watch.service /usr/local/libexec/y700-kmsg-watch
systemctl daemon-reload
```

体检补丁不用回退：它以 `/etc/systemd/system/y700-kmsg-watch.service` 是否存在来选择检查 watcher 还是检查 timer，删了单元文件就回到原来的检查。真要回退：`git apply -R linux/net/y700-checklist-kmsg-watch.patch`。

## 7. watcher 死了怎么办；15 分钟的安全定时器值不值得留

| 情形 | 谁兜底 | 断档 |
|---|---|---|
| 进程崩溃 / 被 OOM / 被杀 | `Restart=always`，5 s 起步、退避到 10 min、`StartLimitIntervalSec=0` 永不放弃；重启后从日志尾部读、并把两个看门狗各踢一次 | 5 s（连续崩溃时最长 10 min）；持续性故障会继续打日志，重启后立刻被看到 |
| 某条记录让它崩溃 | 同上；SEEK_END 保证不会反复读到同一条 | 同上 |
| 二进制被删/改坏、单元被禁用 | 每天的 `y700-checklist`：`y700-kmsg-watch.service 是 inactive` → WARN | ≤1 天 |
| 活着但聋了（循环卡住、读不到 kmsg、沙箱让 systemctl 失败） | 每天的 `y700-checklist` 跑 `--selftest`：没回音或 systemctl 返回非 0 → WARN | ≤1 天 |
| 内核改了那两句的措辞 | 定时器也救不了（脚本 grep 的是同一句）；见 §9 的周期性义务 | — |
| 脚本冷却期间说"等着"，冷却在没有新匹配行的空档里到期（§2.3 末，边沿触发） | 下一条匹配行；故障持续时它很快会来 | 到下一行为止（timer 版在冷却到期后 ≤65 s 内就会再看） |

**安全定时器的裁决：不默认保留。** 它主要多覆盖的情形是"watcher 聋了 **且** 恰好同一天里真出了故障"（上表最后一行它只有在 15 分钟那一刻窗口里还有足够旧行时才帮得上，基本帮不上）。两种故障本身就少见：Wi‑Fi 那次是 s2idle 没进 L2 留下的（平板现在从不休眠），显示那次是硬复位后 164 Hz 起来（README 两节）。15 分钟一次的代价是每小时 8 次脚本运行（timer 版的 7 %），功耗上同样测不出，但它让"安静时零唤醒"不再成立，还每小时多 24 行日志。想要双保险就装可选的 drop-in（体检补丁认得它，不会报"又启用了"）：

```sh
for t in y700-wifi-watchdog y700-display-watchdog; do
  install -D -m644 /tmp/y700-watchdog-safety.conf /etc/systemd/system/$t.timer.d/y700-safety.conf
done
systemctl daemon-reload && systemctl enable --now y700-wifi-watchdog.timer y700-display-watchdog.timer
```

（drop-in 第一行 `OnBootSec=` 的空值把主文件里的**整张**定时器表（90 s/2 min 的 `OnBootSec` 和 1 min 的 `OnUnitActiveSec`）一起清掉——任何一个 `OnXxxSec=`/`OnCalendar=` 赋空值都清整张表（`man/systemd.timer.xml:179–181`、:204–206；`src/core/load-fragment.c:2058` `config_parse_timer()` → `timer_free_values()`）——然后设 `OnBootSec=15min` 和 `OnUnitActiveSec=15min`。**只能清一次**：初版在两者之间又写了一行 `OnUnitActiveSec=`，把刚设的 `OnBootSec=15min` 也清掉了，只剩 `OnUnitActiveSec=15min`；而 `OnUnitActiveSec` 在服务本次开机从没启动过时根本不排期（`src/core/timer.c:483–487`，`base <= 0` → `continue`）——watcher 开机就起不来的那一次，安全网也永远不响，正好漏掉它要兜的情形。复审已改，自测 T14 用 systemd 的合并规则核对。`OnUnitActiveSec` 从服务上次启动算起（`timer.c:485`，`inactive_exit_timestamp`），watcher 的启动也会把它往后推。）

## 8. 有意不做的事

- **不改两个看门狗脚本**：触发器只回答"该看一眼了"，判定（阈值、窗口、冷却、Wi‑Fi 开关、恢复、通知）全留在脚本里，回滚 = 重新启用 timer，安全网也直接复用。
- **不把阈值搬进 watcher**：两处规则会漂移。代价是健康系统上偶发的成对 vblank 超时也会让显示脚本跑一次（70 分钟 4 次，对比 timer 的约 65 次）。
- **不扫开机以来的积压**（SEEK_SET 读 4 MiB 环再按时间戳判断）：用"启动时各踢一次、让脚本按自己的窗口回看"代替，简单且语义和原来的 `OnBootSec` 一样。
- **不用 `journalctl -f` / `dmesg -W` / sh**（§2.4）；**不用 D-Bus 库**直接调 `StartUnit`（`python3-dbus` 有，但多一个依赖和一条系统总线连接；fork 一次 systemctl 只发生在触发时）。
- **不做 sd_notify 心跳**（`WatchdogSec=`）：那就是周期唤醒。"活着但聋了"交给每天一次的 `--selftest`。
- **不用非 root + polkit 规则**：要多维护一份授权规则；root + 只留 `CAP_SYSLOG` + 设备/系统调用/地址族白名单已经把面收得很窄。
- **不加 `MemoryDenyWriteExecute=`、`ProtectProc=`**（§2.5 的理由）。
- **不删 timer 文件**：回滚和可选安全网都用它们。
- **不改 README**（当时有其他改动并行，避免冲突）：要合并的文字在 §11。
- **没在本机 WSL 里做真内核测试**（初稿）：WSL 的 Ubuntu 当时是停止状态，它承载着其他常驻服务和 WSL 里的 Tailscale 节点，启动它会顺带拉起这些服务；没有得到许可就不碰。真内核上的行为留给 §5 的上机验证。——复审时情况和后果见 §12.4：第一次看时它是运行状态，复审在上面跑了 realtest；但它空闲后会自己停，复审之后的几次 `wsl.exe` 调用很可能又把它（连同那些服务）拉起了几次。
- **不在 watcher 里补"冷却到期后再看一次"**（§2.3 末）：要么把窗口/冷却搬进 watcher，要么读脚本的 STAMP 文件，都违背"判定只在脚本里"。

## 9. 周期性义务（能自动的已经自动）

- （周期性义务）**每天（自动）**：`y700-checklist` 查 watcher 是否 active、跑 `--selftest`、查两个 timer 没被重新启用——~~打了体检补丁之后~~ 体检补丁已打上（`tools/y700-checklist.py` 的「kmsg 触发器」一项，`check_kmsg_watch`）。
- [ ] **换内核（新的 yN）时**：在内核源码树里确认两句还在——`git grep -n 'failed to flush transmit queue' drivers/net/wireless/ath/ath12k/`、`git grep -n 'vblank timeout' drivers/gpu/drm/msm/disp/dpu1/`（v7.3-rc4：`mac.c:12669`、`dpu_encoder_phys_vid.c:545`）。变了就**同时**改脚本里的 `grep -c "…"` 和 watcher 的 `WATCHES`，在 PC 上跑 `python -X utf8 -I linux/net/y700-kmsg-watch-selftest.py`（T14 会抓到两边不一致）。这条和 README 两节原有的"看报错字符串是否还一样"是同一件事，现在多了一处要一起改。
- [ ] **systemd 大版本升级时**：`systemd-analyze verify /etc/systemd/system/y700-kmsg-watch.service`，再跑一次 `--selftest`（沙箱选项的隐含规则可能随版本变，例如 §2.5 里 ProtectClock 与设备策略的关系；每天的体检也会发现）；改了单元的沙箱设置、或 python3 / systemd 大版本升级后，在平板上跑一次 `python3 -I y700-kmsg-watch-realtest.py --sandbox`（三个文件放同一目录）。
- [ ] **改了 watcher 时**：PC 上跑自测；能上平板时再跑 realtest（自测只用假的 os/select，realtest 才碰真 `/dev/kmsg` 和真沙箱）。
- [ ] **改了看门狗脚本的窗口/阈值时**：跑一次 PC 上的自测（它从脚本里读这两个数，场景结论跟着变）。

## 10. 未验证

复审后分三档：**已在同版本用户态上实跑**（WSL，§12.2）、**只有源码推理**、**完全没查**。

- **没有在平板上跑过任何一行**（平板当时在跑无人值守测量）。
- 已在 WSL 实跑（x86_64、内核 6.18.33.2-microsoft-standard-WSL2；用户态与平板同版本：python3 3.14.4、systemd 259.5-0ubuntu3.4、glibc 2.43）：`/dev/kmsg` 的 SEEK_END、带偏移 lseek 的 `-ESPIPE`、用户态 `<7>` 被存成 facility 1、16 字节缓冲区 `-EINVAL` 且那条记录丢失、`poll(-1)` 无超时睡眠并被新记录叫醒；真 `daemon()` 的启动踢 argv、子进程 SIGPIPE/SIGXFSZ 恢复默认、空闲无唤醒、SIGTERM；单元全部 34 项设置下读 kmsg、CapEff/NoNewPrivs/Seccomp/SCHED_IDLE、沙箱里 systemctl 启动被授权；`systemd-analyze verify/security`。**仍未在 aarch64 / 7.3 内核上跑过**：`ppoll(…, NULL)`（arm64 没有 `poll`）、aarch64 上 `@system-service` 是否覆盖 python3.14 + systemctl 用到的全部系统调用、7.3 内核和平板 cgroup 上的设备过滤——都交给 §4 第 1 步。
- realtest 自己的两项（2e、3f：`--selftest` 客户端读答复）在 WSL 上**失败过**，原因是测试替换的 `RESULT` 被 `Watcher` 的导入期默认参数绕过（守护进程本身答复正确，日志里有 `selftest … ok wifi=0 display=0`）；`daemon()` 已改为显式传 `RESULT`，自测 T12b 覆盖，但**修好之后的 realtest 没有再跑**（§12.4）。另有一个没解释的现象：那次 `--sandbox` 里守护进程按导入期默认路径 `/run/y700-kmsg-watch/selftest` 写答复，按理在沙箱只读的 `/run` 里该记一行 `cannot write …`，日志里却没有，没再查。生产配置里 `RESULT` 与 `RuntimeDirectory=` 是同一个目录，对照实验证实那个目录在沙箱里可写，所以不影响结论。
- EPIPE（环被覆盖）没在真内核上强制制造过（要灌满 4 MiB 环）；只有源码（printk.c:838–842、:3056）和假 `os` 的自测 T8。
- `/proc/1/root` 在没有 `CAP_SYS_PTRACE` 时比较失败：ptrace 规则推理，没实测（有 `SYSTEMD_OFFLINE=0` 兜着，沙箱实跑里 systemctl 正常）。
- 平板上 `kernel.dmesg_restrict` 的实际值没查（留了 CAP_SYSLOG，两种都能读；WSL 上是 0）。
- python3.14 的 JIT 构建选项没查（因此不设 MemoryDenyWriteExecute）；RSS 只在 WSL 上测了（§2.4），平板上没测。
- glibc：读的是 master 的 `poll.c`；复审补查 `glibc-2.42` tag 与之相同，2.43 夹在中间，按提交历史推断相同（tag 镜像上没有 2.43）。
- 需求里的"两个 timer 约 65 s 一次、熄屏 27 分钟"实测：仓库里没找到原始记录，照抄。
- §3 的 fork 数（dash 的子 shell 行为没核对）、idle 退出数、毫瓦数全是推算；熄屏空闲时内核日志的速率没测（§2.2 末给的 0.019 条/秒是 y8 内核、亮屏、开机半小时后的那一段，只是参考）。
- `inventory/dmesg` 里成对 vblank 超时的成因没查（与屏幕开关/模式切换是否相关不知道）。
- journald 对内核消息是否限速没查（与 timer 版相同，脚本都依赖 `journalctl -k`）。
- §2.3 末"冷却到期时边沿触发会晚到下一行"：NetworkManager 自动重连的次数/间隔没核对，延迟上限只是定性。
- `/proc/<pid>/wchan` 在 WSL 上显示 `poll_schedule_timeout.constprop.0`；平板内核上没看（§5 仍以 `/proc/<pid>/syscall` 为准）。

## 11. README 合并稿（手工合并用）

**「目录里有什么」表**，替换第 23–24 行并在其后加三行（装好之后把"未装"改成"已装"）：

```markdown
| `linux/net/y700-wifi-watchdog`、`.service`、`.timer` | Wi‑Fi 固件发送队列卡死（睡醒后）自动重载 ath12k 的看门狗 | 已装；2026-10-16 起由 y700-kmsg-watch 事件触发，timer 停用（文件保留） |
| `linux/net/y700-display-watchdog`、`.service`、`.timer` | DPU vblank 超时（整机卡顿）自动重编程面板的看门狗 | 已装；同上 |
| `linux/net/y700-kmsg-watch`、`.service`、`y700-kmsg-watch-selftest.py`、`y700-kmsg-watch-realtest.py`、`KMSG-WATCH.md` | 两个看门狗的事件触发器：阻塞读 `/dev/kmsg`，内核记下那两句才 start 对应 oneshot；安静时零唤醒。realtest = 真内核 + 真 systemd 预检（部署前在平板上跑） | 未装（PC 自测 72/72；WSL 同版本用户态实跑见 KMSG-WATCH.md §12） |
| `linux/net/y700-checklist-kmsg-watch.patch` | 体检改为查 y700-kmsg-watch（含 `--selftest`）；没装 watcher 时行为不变 | 未打 |
| `linux/net/y700-watchdog-safety.conf` | 可选：旧 timer 改成 15 分钟一次的安全网 | 默认不装 |
```

**「Wi‑Fi 睡醒后固件发不出包」节**，在"周期性义务"那条之前加：

```markdown
- **2026-10-16 起改为事件触发**（[KMSG-WATCH.md](KMSG-WATCH.md)）：每分钟一次的 timer 停用，由常驻的 `y700-kmsg-watch` 阻塞读 `/dev/kmsg`，内核记下 `failed to flush transmit queue`（只认内核 facility 0，用户态写的同样文字不算）后 5 s `systemctl start --no-block y700-wifi-watchdog.service`，同一看门狗 20 s 内最多一次；脚本本身不变，仍按"3 分钟 ≥2 次"判定。模拟 10-13 的故障节律（每 21 s 一次），首次失败后 26 s 就决定重载（timer 版最坏约 85 s）。安静时零唤醒；每天体检用 `y700-kmsg-watch --selftest` 经 kmsg ping 它。
```

**「整机卡顿 = 显示引擎 vblank 超时」节**，在"周期性义务"那条之前加：

```markdown
- **2026-10-16 起改为事件触发**（同上，[KMSG-WATCH.md](KMSG-WATCH.md)）：`vblank timeout` 出现 5 s 后启动 `y700-display-watchdog.service`，风暴中每 20 s 最多一次；模拟 10-13 的风暴（每秒 2 次），开始后 25 s 就够"1 分钟 ≥15 次"的阈值。注意健康开机也会冒出成对的 vblank 超时（inventory/dmesg：70 分钟 10 行），每对会让脚本白跑一次（exit 0），比 timer 的每小时约 55 次少得多。
- 周期性义务补充：报错字符串变了要**同时**改脚本的 grep 和 `y700-kmsg-watch` 的 `WATCHES`，跑 `linux/net/y700-kmsg-watch-selftest.py`。
```

**「平板体检」节**（README 第 1105 行起）——体检不再严格"只读"，要改两处：
- "只读，唯一会写的是自己的基线文件……" 那条后面加：

```markdown
  - 例外（装了 y700-kmsg-watch 之后）：每次体检跑一次 `y700-kmsg-watch --selftest`，它往 `/dev/kmsg` 写一行 user.debug 的 `y700-kmsg-watch: selftest <token>`，watcher 随即 `systemctl start` 两个看门狗单元一次（脚本照常判定：没有故障行就 exit 0；真有达到阈值且过了冷却的故障，它会像以前 timer 的一次例行检查那样动手）。这是证明"读得到内核日志、能启动单元"的唯一办法。
```
- WARN 列表里"Wi-Fi 和显示看门狗……这几个服务没在跑"改为：

```markdown
    - Wi-Fi 和显示看门狗：装了 `y700-kmsg-watch` 后查它在跑、`--selftest` 有回音，以及两个 timer 没被重新启用（带 15 分钟安全网 drop-in 的除外）；没装时仍查两个 timer。FEX rootfs、扬声器守护、联想调音、控制中心这几个服务没在跑
```

**`2026-10-14 Codex 复审与整改` 节的待办（第 793 行）**改为：

```markdown
- [ ] 看门狗真实触发后看 journal 的 ok/fail 与通知文案（`journalctl -u y700-kmsg-watch -u y700-wifi-watchdog -u y700-display-watchdog`）。10-23：Wi‑Fi 那半已有 4 次真实触发，全部 ok，都在 CarPlay 停热点后 30–60 s，10-18 以后没再出现。只剩显示看门狗，它还没触发过。详见 README「2026-10-14 Codex 复审与整改」的同一条。
```

**「熄屏唤醒治理」节**末尾加一句：

```markdown
- 2026-10-16：两个看门狗的每分钟 timer（每小时约 110 次单元启停、约 9 次/分钟 fork）换成内核日志事件触发 `y700-kmsg-watch`，见 [KMSG-WATCH.md](KMSG-WATCH.md)；推算 idle 退出 −1~3 次/秒、0.1–1 mW，测不出，属"清干净周期唤醒"的一块。
```

## 12. 独立复审（2026-10-16，独立进行；同样不碰平板、不 commit、不改 README）

### 12.1 复核了什么

- **源码逐条重读**（按文中声称的版本：内核 v7.3-rc4、systemd v259.5、CPython v3.14.4、glibc master + 2.42 tag，均为 GitHub raw）：printk.c 的 `check_syslog_permissions` :617、`info_print_ext_header` :641、`msg_add_ext_text` :662、`devkmsg_write` :739/:743/:789、`devkmsg_read` :801/:817/:838–842/:845/:847、`devkmsg_llseek` :870/:876/:893、`devkmsg_poll` :901/:907/:912、`devkmsg_open` :920/:945、`vprintk_emit` :2423/:2484/:2486、`console_resume_all` :2818/:2848、klogd 唤醒 :4601–4666；`internal.h:48`；`fs/select.c` :234–257/:883/:960–965/:1092–1114；`sleep_timeout.c` 无 expires 即 `schedule()`；`unistd.h:194`；af_unix/namei/fs.h 三处；ath12k `mac.c:12669`、dpu `:545`；systemd 的 sd-journal/journal-file/journald-manager、job.c、bus-util/dbus/bus-polkit/bus-convenience、namespace.c、unit.c、verbs.c、virt.c、bpf-devices.c、seccomp-util.c（含 `RestrictNamespaces=` 让 clone3 返回 ENOSYS、glibc 回退 clone 的那条 :1443–1456）、journald-kmsg.c（所有 kmsg 记录都打 `_TRANSPORT=kernel`，:269——§5 第 5 条的警告成立）。**全部对得上**，只更正了两处小地方：CPython 那条（watcher 传的是整数 -1、行号 :654）和 timer man 页的语义（见 12.3 第 1 条）。另补查了 `dbus-unit.c` 的授权先于排 job、`printk_get_next_message` 的 `dropped`（:3056）、`load-fragment.c:2058`、`timer.c:483–487`。
- **代码**：解析、去抖、排期、EPIPE、DRAIN_MAX、信号（SIGTERM 走默认动作 = systemd 眼里的干净退出；EINTR 由 CPython 自动重试；无 SIGCHLD 处理也不影响 `waitpid`）、posix_spawn 的 setsigdef、fd 的 O_CLOEXEC、`--selftest` 的原子替换与 token 校验、systemctl 的总线超时（sd-bus 缺省 25 s，不会永远卡在 `waitpid`）。没发现守护进程本身的错误。
- **重跑**：PC 自测 69/69（复审改动后 72/72）；体检补丁在临时副本里 `git apply --check` 通过、打上后 `tools/y700-checklist-selftest.py` 0 失败（S11–S11f 全过），`tools/` 两个文件的 md5 与补丁头里写的一致。
- **节省是否夸大**：§3 的数（每小时约 110 次单元启停、约 9 次/分钟 fork、1–3 次/秒 idle 退出、0.1–1 mW）都标了"推算"，量级合理，没有夸大；原文漏了和 watcher 自身花费的对照，已补（§2.2 末、§3：参考稳态 0.019 条/秒内核记录 ≈ 每分钟醒 1 次）。

### 12.2 WSL 实跑（`y700-kmsg-watch-realtest.py --sandbox`，root）

环境：WSL Ubuntu 26.04，`python3 3.14.4`、`systemd 259.5-0ubuntu3.4`、`glibc 2.43-2ubuntu2.4`（三者与平板同版本），x86_64，内核 `6.18.33.2-microsoft-standard-WSL2`，`dmesg_restrict=0`、`printk_devkmsg=on`（平板缺省多半是 `ratelimit`，每次打开 10 条/5 s，客户端每次只写 1 条，不受影响）。

| 项 | 结果 |
|---|---|
| 1a–1f `/dev/kmsg`：SEEK_END 后只读新记录；带偏移 lseek → ESPIPE；`<7>` 被存成 facility 1；16 字节缓冲区 → EINVAL 且该记录丢失、下一条不丢；`poll(-1)` 阻塞时 `/proc/<pid>/syscall` = `7 … 0xffffffffffffffff`、`wchan` = `poll_schedule_timeout`，新记录叫醒它 | 全过 |
| 2a–2d、2f、2g 真 `daemon()` + systemctl 桩：启动踢的 argv 一字不差；子进程 `SigIgn` 里 SIGPIPE/SIGXFSZ 位为 0；空闲停在无超时的 poll；5 s 无记录窗口自愿切换 +1 / +0；`--selftest` 触发两次启动；SIGTERM 结束 | 全过 |
| 2e `--selftest` 客户端拿到答复 | **失败**：测试改的 `RESULT` 被导入期默认参数绕过，守护进程把（正确的）答复写到了 `/run/y700-kmsg-watch/selftest`（事后在那里看到 `selftest … ok wifi=0 display=0`，已删）。已修 `daemon()`，未重跑 |
| 3a–3e、3g 临时单元带全部 34 项设置：systemd-run 全部接受；读得到 kmsg、两次启动踢成功；CapEff 只有 CAP_SYSLOG、NoNewPrivs 1、Seccomp 2；SCHED_IDLE；空闲无超时；stop 干净 | 全过 |
| 3f 沙箱版 `--selftest` | **失败**，原因同 2e；日志里守护进程的答复是 `selftest … ok wifi=0 display=0`（沙箱里两次 systemctl start 都返回 0） |
| `systemd-analyze verify` / `security --offline=yes` | 通过（只报没装二进制）/ 暴露分 2.2 OK |
| 对照：`ProtectSystem=strict` 下 `/run` 是否只读、`RuntimeDirectory=` 是否可写 | `/run` ro，RuntimeDirectory 可写 |

### 12.3 发现的问题与处理

1. **（重要，已改）可选安全网 drop-in 根本不起作用于它要兜的情形**：`y700-watchdog-safety.conf` 写了两次空值（`OnBootSec=` … `OnUnitActiveSec=`），而任何一个 `OnXxxSec=` 赋空值都清**整张**定时器表，第二次把刚设的 `OnBootSec=15min` 也清了；只剩的 `OnUnitActiveSec=15min` 在服务本次开机从没启动过时不排期——watcher 开机就起不来时，安全网永远不响。改成只在第一行清一次；自测 T14 按 systemd 的合并规则核对最终表，并保留一条断言说明旧写法会丢 `OnBootSec`。§7 的解释也重写了。
2. **（小，已改）`Watcher(result=RESULT)` 是导入期默认参数**：给 `RESULT` 换路径（测试、包装脚本）会被静默忽略，复审的 realtest 就栽在这上面。生产行为不变，`daemon()` 改为显式传 `result=RESULT`；自测 T12b。
3. **（小，文档）没说清边沿触发与 timer 的一处不等价**：冷却到期时若没有新行，timer 还会再看一次，watcher 不会（§2.3 末、§7 表、§8）。不改代码，理由见 §8。
4. **（小，文档）体检不再"只读"**：`--selftest` 写一行 kmsg、启动两个看门狗单元一次；README「平板体检」节里"只读"和 WARN 列表要跟着改，合并稿已加进 §11。
5. **（小，文档）内核日志速率的参考值误导**：原文给的 0.7 条/秒被开机拖高，开机半小时后那段是 0.019 条/秒；已改，并把 watcher 自身花费放进节省的对照里。PROTOCOL.md 的 7.7 条/秒是所有来源的日志、不会叫醒 watcher，也写明了。
6. **（小，文档）若干源码细节更正**：CPython 传 -1 的路径与行号；EPIPE 也来自"数据丢失的记录被跳过"；timer man 页的行号与语义；glibc 2.42 tag 补查。
7. **（缺测试，已补）**：只有假 `os/select` 的离线自测，没有任何真内核/真沙箱的测试。新增 `y700-kmsg-watch-realtest.py`（部署前在平板上跑，§4 第 1 步），并在 WSL 上跑了（12.2）。

### 12.4 复审过程本身的一个副作用（如实记录）

复审第一次 `wsl -l -v` 时 Ubuntu 是 **Running**（11:11 起，不是复审启动的），于是在它上面跑了上面的测试。事后才发现它空闲约十几秒就自己停：11:16 左右 journald 把内核环里已有的 `y700kw-realtest` 行又导入了一遍、`/run` 里的临时文件也没了，说明发行版重启过；复审结束时状态是 **Stopped**。也就是说复审之后的几次 `wsl.exe` 调用很可能把 Ubuntu 连同其上的其他服务和 WSL 里的 Tailscale 节点拉起了好几次（每次几十秒）。初稿作者正是因为这个才不碰 WSL。发现之后就停用了 WSL，所以修好的 realtest 没再跑。往 WSL 内核日志写过约十几行 user.debug 的 `y700kw-realtest …`，建过并停掉了临时单元 `y700kw-wifi-rt` / `y700kw-display-rt` / `y700kw-watch-rt`，删掉了 `/tmp/y700kw`、`/tmp/dbg-result`；测试误写的 `/run/y700-kmsg-watch/selftest` 第一次删了，第二次跑又写出来、没再删（`/run` 是 tmpfs，发行版停下时已随之清空）。WSL 里没装任何东西。

### 12.5 看过但没改、留给部署者判断

- 单元用 `Type=simple`：二进制坏了 `systemctl enable --now` 照样返回成功，要靠紧随其后的 `--selftest` 发现（§4 已有这一步）。`Type=exec` 能让 start 本身报错，但改了要重跑验证，没动。
- 体检补丁在 watcher 不 active 时提前 return，就不再检查两个 timer 是否被重新启用（反正已经 WARN 了）；没改。

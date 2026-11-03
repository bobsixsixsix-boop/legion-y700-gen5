# 第 2 档电池页：最终实现规格

> 以 lean 方案为底（三位评委里两位判它胜出）。在它上面嫁接了这些：
> - owner：降级模式、启动器自己套 scope、外行文案、先只记录一天；
> - accurate：cgroup inode、按段对账、唤醒饱和模型、按簇频点给 CPU 定价；
> - 修正了评委核实的事实错误：零读数、时钟同步判据、充满门槛、底噪系数、live.log 截短后能留多久、可用窗口尺寸。
>
> 已核实的事实以 `linux/power/BATTERY-PAGE.md` 为准。下文行号都是今天仓库里的。
>
> 11-03 起 refresh-auto 守护进程换成 Rust（`linux/display/refresh-auto/daemon/`），前台日志在 `daemon/src/fg.rs`；下文 `y700-refresh-auto:行号` 指被替换掉的 Python 版，带 `log_fg` 的那一版没有公开。
>
> 10-30 设计评审（3 方案 → 3 评委 → 合成 → 2 个挑错者）之后，挑错者提了 21 条问题，逐条对过仓库：
> - 核实属实的：refresh-auto 的 `on_call` 只包一层 `@safe`；flightrec 的 `num()` 读失败返回 0 并缓存 4.5 s；flightrec 的 unit 是 `Restart=always`、`RestartSec=5`、`ConditionPathExists=/sys/kernel/debug/pm_genpd`，没有 `RuntimeDirectory=`；`test-deploy.sh` 用的是假记录器。
> - 21 条全部采纳，已经改进正文对应位置，凡是改过的地方都标了「（评审修订）」。冲突时以带这个标记的文字为准。

## 1. Architecture and processes

| 部件 | 身份 | 常驻 | 职责 |
|---|---|---|---|
| `y700-flightrec`（已有，要改） | root 系统服务 | 是 | 新增 `src/acc.rs`（约 120 行）。每写一条数据行（`run.rs:417-418`）后做一次积分，把结果定宽 `pwrite` 到 `/run/y700-flightrec/energy`。dpms 或供电方向一变，就用 tmp+rename 写 `/run/y700-flightrec/edge`。live.log 的行格式一个字节都不改。acc 内部出错一律吞掉，不 unwrap、不 panic |
| `y700-batteryd`（新，Rust，只用 libc + serde_json + std） | user 用户服务，`Slice=background.slice` | 是 | 拍快照写账本。不连 D-Bus，不读电流，不读 live.log |
| `y700-refresh-auto`（已有，Python） | user | 是 | 在 `on_call` 的 activeWindow 分支（`y700-refresh-auto:593-599`）里加 `log_fg()`，约 25 行，追加前台日志 |
| `y700-battery-report`（新，Python 3 标准库；只有 `--fit` 要 numpy） | user | 否 | 页面打开时跑一次：读账本、前台日志、UPower 历史和用户 journal 的 Consumed 行，算出全部分项，输出 JSON |
| `y700-battery-page`（新，Qt6 QML + 约 200 行 C++） | user | 否 | 页面本身 |
| `calib/y700-battery-calib.sh` | root，一次性 `systemd-run` | 否 | 标定，只在作者同意的夜里跑 |

**积分为什么放进 flightrec**
- flightrec 熄屏时本来就每 10 s 醒一次，本来就在读 `bat` 和 `dpms`（`main.rs:263-271`），在那里积分不增加任何唤醒。
- 总量不受 live.log 截短影响：截短后保留 `LIVE_MAX/4` = 512 KiB，约 1700 行，10 s 档约 4.7 h，1 s 实验档约 28 min（`run.rs:68`）。
- batteryd 崩了、重启了，总量都不丢。

**batteryd 的唤醒源**：一个 `poll`，挂下面这些 fd，没有自己的周期定时器。

| 来源 | 亮屏 | 熄屏 |
|---|---|---|
| inotify 盯目录 `/run/y700-flightrec`，只订 `IN_MOVED_TO`，只认文件名 `edge` | 亮灭屏或插拔电时 1 次 | 熄屏那一刻 1 次，搭 flightrec 本来那次唤醒 |
| `poll` 超时（unit 设 `TimerSlackNSec=10s`） | 300 s 拍一次快照 | 1800 s 一个检查点 |
| signalfd | TERM：最后一次快照 + `fdatasync`；USR1：页面要一次即时快照，10 s 内只响应一次 | TERM |
| timerfd，`CLOCK_REALTIME`，`TFD_TIMER_ABSTIME\|TFD_TIMER_CANCEL_ON_SET`，到期时间设在 2100 年 | 只在时钟被步进时醒 | 同左 |

- **降级模式**：每次醒来先核对 `daemon.pid` 和 `/proc/<pid>/comm`，再看 `energy` 里的 t 是否超过 60 s 没更新。flightrec 不在，就自己读 `/sys/class/drm/card1-DSI-1/dpms`，节奏同上，快照标 `cov:0`。
- **节奏由 edge 文件决定，不只靠 inotify 事件（评审修订）**：
  - 不管因为什么醒来，都先 pread 一次 `edge`（tmpfs，几乎没有成本），按里面的 dpms 决定下一次超时是 300 s 还是 1800 s。
  - `/run/y700-flightrec` 由 flightrec 自己建（`run.rs:29`），unit 里没有 `RuntimeDirectory=`。自动登录时用户会话可能先起来，这时 `inotify_add_watch` 返回 ENOENT。
  - 监视没建上（add_watch 失败，或者收到 `IN_IGNORED`），就在每次醒来时重试，并把「监视缺失」算进降级判定。
  - 拿 edge 里的 (dpms, pw) 和自己记的状态比，没变就只更新状态、不拍快照。dpms 没变时，两次边沿快照之间至少隔 60 s。原因：flightrec 是 `Restart=always`、`RestartSec=5`，每次启动都写一次 edge，它要是崩溃循环，batteryd 不能跟着每 5 s 做一次完整快照。
- **出错不退出（评审修订）**：
  - 写盘失败（ENOSPC/EACCES）、解析出错、某个单元读不了：只记一次日志，跳过这次或这个单元，等下一次计划快照再试。代码里不 unwrap、不 panic。
  - 启动顺序：先 `sigprocmask` + signalfd，再写 pid 文件。否则页面在这个空当发来 USR1，会按默认动作杀掉进程。
  - 单实例：启动时对 `~/.local/state/y700-battery/lock` 做 `flock(LOCK_EX|LOCK_NB)`，拿不到就 `exit 0`（`--once`、`--bench` 不拿锁、不写账本）。
- unit 里另设 `CPUSchedulingPolicy=idle`、`IOSchedulingClass=idle`、`Nice=10`、`MemoryMax=64M`、`LimitNOFILE=4096`、`Restart=on-failure`、`RestartSec=30`、`RestartSteps=5`、`RestartMaxDelaySec=1h`（评审修订：只写 RestartSec=30 的话，systemd 默认的 10 s 内 5 次限速永远碰不到，持久故障会变成整夜每 30 s 启动一次）。

**常驻开销算账**
- 假设：一天亮屏 6 h、熄屏 18 h，熄屏 20 段，检查点 30 个，cgroup 约 120 个，线程约 2500 个。
- 单次成本：
  - 轻量快照约 3 ms：120 个 `cpu.stat` 用常开 fd 做 pread，每个约 8 µs（`sampler.rs` 实测 2.5–11 µs）；`/proc/stat`；2 个 `time_in_state`；GPU 增量扫描 1–2 ms。
  - 逐线程扫描 50–120 ms（评审修订）：线程的 `status` 没法常开（线程不停生灭），只能 open+read+close，仓库实测 20–45 µs/个（`sampler.rs:11-12`），2500 个线程，再加列 `/proc` 的开销。
- 熄屏一天：
  - CPU：(30 个检查点 + 20 次熄屏边沿) × 约 120 ms + flightrec 6480 行 × 15 µs ≈ 6.1 s；按小核 0.15 W 算 = 0.9 J。
  - 最坏情况（检查点都没合并进别人的唤醒）：30 × 5 mJ = 0.15 J。
  - `fdatasync` 50 次 × 10 mJ = 0.5 J。
  - 合计约 1.6 J / 18 h ≈ **25 µW**，是 0.24 W 底噪的 0.01 %。
- 亮屏一天：72 × 3 ms + 20 × 120 ms + 2160 × 15 µs + 前台日志 300 × 0.3 ms ≈ 2.8 s；按 0.5 W 算 = 1.4 J。
- 全天约 3 J，平均约 **35 µW**，离 1 mW 的目标有约 30 倍余量。估小 10 倍也只有 0.35 mW。RSS 约 3 MB。

## 2. Data

**energy 文件**（tmpfs，0644）
- 每行 pwrite 到偏移 0。数字一律定宽 13 位，末尾两个字段定宽 3 字符，所以整行覆盖不会留残渣。
- 读的一方连读两次、内容一样才采用。
- 不用 rename：rename 会触发 `IN_MOVED_TO`，等于每 10 s 叫醒 batteryd 一次。

```
v1 boot=3f2a9c1e t=0000031540012 n=0000000003154 ton=0000004120000 toff=0000027420000 don=0000004120333 doff=0000003311870 dton=0000004100000 dtoff=0000027000000 chg=0000000412004 tchg=0000000420000 tz=0000000180000 gap=0000000000000 bl=0001352000000 lb=+000000000412 lbt=0000031540012 dpms=Off pw=dis
```

字段单位：
- `t`、`ton`、`toff`、`dton`、`dtoff`、`tchg`、`tz`、`tzero`、`gap`、`lbt`：CLOCK_MONOTONIC 的 ms（评审修订：`tzero` 加在 `tz` 后面，示例行里还没画出来）；
- `don`、`doff`、`chg`：mJ，u64 整数；
- `bl`：背光级 × ms；
- `lb`：最近一次有效的 bat 读数（mW，带符号）。
- `tz` 不是累计量，是当前还开着的那段缺测的长度（acc.rs 的 `pend`）：这段一结束就清零，时长移进 `dton`/`dtoff`、`tzero` 或 `gap`。所以报表算区间差值时 `tz` 可以为负；只有 `t`、`n` 或其余累计字段（`lb`、`lbt` 不算）回退，才算 flightrec 的文件在本次开机内被重置，这个区间的 fr 记为空。`dton + dtoff + tchg + tzero + tz + gap` 的区间差值始终等于 `t` 的差值。

**积分规则**（每写一条数据行做一次）
1. 先算 dt。dt > 60 s 时整段计入 `gap`，不积分。
2. **零读数（评审修订）**：`bat` 为 0 时，flightrec 用 `{:+.0}` 打印成 `-0mW`。仓库日志里 974b286c 有 178 行、690a169c 有 232 行，`+0mW` 一行都没有。
   - 这些零读数里，有一部分是读失败：`num()` 读失败时返回 0（`main.rs:128-130`），而且这个 0 会被缓存 4.5 s（`main.rs:264-267`）。
   - 放电中也会出现连续超过 60 s 的零读数，例如 690a169c 的 t=66030–66600，连续 58 行，中间还有 dpms=On 的行。所以不能按时长判断。
   - 做法：flightrec 的 Sample 里给 bat 加一个「读成功」标志（live.log 行格式不变）。读到的 `current_now` 恰好是 0 时，再多读一次电池的 `status`。只有零读数的行才多这一次固件往返。
   - 读成功、电流为 0、而且 `status` 不是 `Discharging`（插着电：充满、停在上限、旁路）：算真的 0，时长记进 `tzero`，不进 `chg` / `tchg`。
   - 读失败，或者电流为 0 但 `status` 是 `Discharging`：算**缺测**，时长先记进 `tz`。下一个有效读数到来时：
     - 它是正的（放电），就按 (lb+cur)/2 把缺测这段补积到对应的 dpms 桶；
     - 它是负的（充电），就把缺测这段移进 `tzero`。
   - 缺测连续超过 30 min 时，整段算 `gap`，不补积。
   - 开机后还没有过有效读数时，零读数一律算 `tzero`。
3. 梯形法 `e=(prev+cur)/2·dt`。e > 0 记放电，按这一行的 dpms 计入 `don` 或 `doff`，同时累加 `dton` / `dtoff`；**只有 e < 0 才记进 `chg` 和 `tchg`**（评审修订）。
4. `ton` / `toff` 照常累加。亮屏时多 pread 一次 `/sys/class/backlight/aw99706-backlight/brightness`（缓存值，不走 I2C；不读 `actual_brightness`），累加 `bl`。
5. `pw` 的取值：有效读数 > +20 mW 为 `dis`，< −20 mW 为 `chg`，介于两者之间不改。新值连续 3 行才生效。**`pw` 只用来决定什么时候拍快照，不用来判断是否插电。**
6. flightrec 在同一次开机内重启时，从文件接着数；换了开机，文件归零。

**edge 文件**：内容如 `v1 t=7341.9 dpms=Off pw=dis`。写 `edge.tmp` 再 rename。flightrec 启动时写一次，之后只在 dpms 或 `pw` 变化时写。

**插电边沿的电池状态（评审修订）**：batteryd 在 `pw` 边沿快照里多读一次电池的 `status` 和 `capacity`，字段为 `st`、`cap`。只在边沿读，每天十几次固件往返。这是 7 天以外判断插电和充满的权威来源，因为 UPower 的每个历史文件只留 7 天。

**账本**：`~/.local/state/y700-battery/`
- `boots.txt`：按开机顺序记 boot id，做法和 `run.rs:105-139` 一样。RTC 从 1970 起，不能按 mtime 排序。
- `b-<boot8>.jsonl`：单个文件到 4 MiB 就切成 `b-<boot8>.<n>.jsonl`。每个分段文件开头都写全量的 H、U、S，单个文件就能自己解码。
- 每行一次 `write()`，O_APPEND，单行不超过 64 KiB。
- **同一次开机里 batteryd 重启（评审修订）**：
  - 启动时文件非空、而且末字节不是 `\n`，先补一个 `\n`。碰到 MemoryMax 时进程被 SIGKILL，可能留下没写完的半行。
  - U 表 id 的作用域到下一条 H 为止，重启后从 1 重编。报表跨 H 只按 (path, ino) 配对，不按 id 配对。

```
{"k":"H","v":1,"boot":"3f2a9c1e-77d0-4b1e-9a51-0c2d6e1f8a90","part":0,"m":18.42,"w":40213.7,"sync":0,"why":"start"}
{"k":"U","id":17,"p":"u/app.slice/app-com.anthropic.Claude-16803.scope","ino":48213}
{"k":"S","why":"start","m":18.6,"w":40213.9,"sync":0,"dpms":1,"cov":1,"fr":{"t":18512,"don":0,"doff":0,"dton":0,"dtoff":0,"chg":412,"tchg":7900,"ton":7900,"toff":0,"tz":0,"gap":0,"bl":2615000},"cg":{"1":61231000,"2":3011000,"17":902000},"cl":[[812345,95123456,912340],[20311,31234567,912340]],"ctx":81234567,"pkt":[1203,988],"x":[3315,812],"gpu":{"17":[1830000000,512000000]},"cap":81}
{"k":"K","m":41.2,"w":1761803001.4,"sync":1,"src":"chrony"}
{"k":"S","why":"off","m":7342.2,"w":1761810342.6,"sync":1,"dpms":0,"cov":1,"edge":7341.9,"fr":{…},"cg":{"17":1290331},"new":[23],"gone":[19],"cap":64}
{"k":"S","why":"ck","m":9142.0,"w":1761812142.4,"sync":1,"dpms":0,"cov":1,"fr":{…},"cg":{…},"wk":{"17":28130,"-k":22148,"2":1204}}
```

- **单元表**：U 行给每个单元分配一个 id。路径变了或 inode 变了，就分配新 id，所以同名单元重建后增量从 0 算，不会出负数。读 `cpu.stat` 遇到 ENODEV、或 inode 变了，就关掉常开的那个 fd，免得钉住正在销毁的 cgroup。
- **路径写法**：系统单元是 `s/<system.slice 下的路径>`，用户单元是 `u/<user@1000.service 下的路径>`，登录会话写成 `l/session-N.scope`。id 1 固定是根 cgroup，id 2 是 KWin。
- **计数器一律写绝对值**：`cg` 只写变了的单元；app.slice 下的单元用 `new` / `gone` 记出现和消失。丢一行只是分辨率变粗。
- `cl`：每簇 `[忙碌 ms, Σf·t, Σt]`，频率均值由增量折出。
- `x`：Xwayland 的 `[pid, utime+stime 节拍]`。
- `gpu`：每个单元的 `[engine_ns, cycles]`，按 `drm-client-id` 去重后归到持有它的最小 pid，renderD128 和 card1 都收。
- `wk`：自上次逐线程扫描以来的 `voluntary+nonvoluntary` 差值，按单元汇总；内核线程合成 `-k`。只在熄屏边沿、熄屏检查点、亮屏边沿这三种快照里出现。
- `cap`：只在边沿读，每读一次是一次固件往返。

**前台日志** `fg-<boot8>.log`：由 refresh-auto 写，见第 3 节。

**时钟**
- 每行都写 `m`（CLOCK_MONOTONIC，和 flightrec 的 `t=`、journal 的 `__MONOTONIC_TIMESTAMP` 是同一个钟）和原样的 `w`（CLOCK_REALTIME）。
- `sync` 的判据：以 `chronyc -n -c tracking` 的 Leap status 为准，`Normal` 就算已同步。本机是 chrony 加 fake-hwclock（README:173、192）。
  - 不用 adjtimex：chrony 在 Linux 上只有开着 `rtcsync` 才清 STA_UNSYNC，而仓库计划用 `y700-rtc-sync-off.sh` 把它关掉。
  - 不用 `>1.7e9`：fake-hwclock 载入的旧时间也大于 1.7e9，证明不了什么。
  - 没有 chronyc 时才退回 adjtimex。
- 何时去查：启动时、每次步进时钟（timerfd 被取消）后、`sync=0` 期间的每次快照时，各 exec 一次 chronyc。同步之后就不再 exec。每次步进写一行 K。
- 报表的换算：每次开机取 `sync=1` 各行 `w−m` 的中位数作偏移，套到这次开机的所有行上。
- 过去的某次开机从没同步过：接在上一次开机末尾，标「时间不明」，不进 24 小时和 7 天两个视图。
- **当前这次开机还没同步（评审修订）**：比如在车里，Wi‑Fi 被无线 CarPlay 占着。以「现在」为锚，本次开机内的时间按 mono 从现在往回推。之前的开机仍按各自同步过的时间排，中间的间隔标「长度不明」。本次开机的 UPower 点用同一个临时偏移换算，页面加注「时间未校准」。
  - **钟落后（10-31 审计修订）**：「现在 − mono」早于已定位的开机里最新的一行时（没联网、校时之前的早期时钟落后），以前的开机全落在「将来」，报表只剩本次开机、「自上次充满」退成「之前没有记录」。这时本次开机改从那一行起算（同过去没同步的开机的接法），报表的「现在」跟着挪到 mono_now 对应的时刻；clock 仍是 `now`，照样挂「时间未校准」，24 小时和 7 天照样算它。
- **UPower 历史的时间（评审修订）**：只丢 <1.7e9 的点不够，fake-hwclock 载入的旧时间也大于 1.7e9。upowerd 每次启动都会马上记一个点，用的就是 fake-hwclock 的时间。
  - 按点的先后顺序检查时间，倒退的点丢掉。
  - 落在两次开机之间的点丢掉，即上一次开机最后一条 sync=1 的 S 的 w，到下一次开机第一条 sync=1 的 w 之间。
  - 本次开机步进之前的点，能用 K 行记的步进量改正就改正，改不了就丢掉。

**保留期**：40 天，总量不超过 16 MiB。在 batteryd 启动时、以及每天第一次亮屏快照时，按 `boots.txt` 从最老的删起。估计约 130–300 KB/天。
- **清理单位是分段文件（评审修订）**：只有当前正在写的那一段始终保留，当前开机的旧段也参加 40 天和 16 MiB 的清理。否则一次开机持续 60 天就会超过上限。
- `fg-<boot8>.log` 到 1 MiB 就由 refresh-auto 切成 `fg-<boot8>.<n>.log`，和账本一起清理。

**写盘频率**
- 熄屏边沿快照、熄屏检查点、TERM 这三种时候做 `fdatasync`，约 50 次/天。
- 亮屏快照只 append，交给内核回写。
- 突然复位最多丢：熄屏时距上一个检查点的 ≤30 min；亮屏时 ≤5 min，再加约 30 s 还没回写的页缓存。缺的这段在页面上画成缺口，由 UPower 的电量 % 补。

## 3. Foreground tracking

**不改 KWin 脚本**。`main.js:19-27` 已经在窗口激活、全屏或几何变化时去重上报 `(cls, covers, pid)`。refresh-auto 的 `log_fg()` 收到后：
1. 读 `/proc/<pid>/cgroup` 的 `0::` 行，从叶子往上找到第一个 `.scope` 或 `.service`；
2. pread 新、旧两个前台单元的 `cpu.stat`；
3. open → append → close。

```
7342.61 16803 1 812345 912345678 /user.slice/user-1000.slice/user@1000.service/app.slice/app-com.anthropic.Claude-16803.scope Claude
```

- 字段依次是：mono、pid、covers、新单元的 `usage_usec`、上一个前台单元此刻的 `usage_usec`（读不到写 `-`）、cgroup 路径、class（放最后，可以带空格）。
- **目录不存在就什么也不写**，删掉目录就等于关掉这个功能。
- 不增加唤醒：refresh-auto 本来就为这次调用醒着。refresh-auto 重启时会重载脚本，脚本自动补报一行。
- **放在哪、出错怎么办（评审修订）**：
  - `on_call` 外面只有一层 `@safe(None)`（`y700-refresh-auto:68-79`）。异常会被吞掉，但出错位置之后的 `inv.return_value(None)` 和 `self.evaluate(...)` 都不会执行，比如从全屏视频切走时就不回 base Hz 了。
  - 所以 `log_fg()` 放在 `self.evaluate(...)` **之后**调用，自己包 `try/except Exception`。出错只计数，只记一次日志，绝不往外抛。
  - 读 `/proc/<pid>/cgroup` 失败（窗口刚关、进程已退出）时照样写一行，cgroup 字段写 `-`。
  - 不 fsync，不在 GLib 主循环里做任何阻塞操作。
  - 加一条测试：传入不存在的 pid 时，`evaluate` 照常被调用。
- **启停标记（评审修订）**：refresh-auto 启动时写一行 `START`，`app.stop()` 里写一行 `STOP`。报表再用账本里 `y700-refresh-auto.service` 单元的存活区间（U 表的 new/gone/inode）裁剪前台段。越过 STOP 或 gone 的部分记为「前台未知」，进「没算清」。
- pid 为 0、class 为空，或者 class 属于 {`plasmashell`, `org.kde.plasmashell`, `y700-shellbar`, `y700-control-center`}，记作「桌面」，归系统界面。

**时长和 CPU 怎么算**
- 前台时长：相邻两行之间的时间，再和亮屏区间取交集（亮屏区间来自账本的边沿快照，精度约 ±10 s）。
- 前台 CPU：每一段前台的 usage 差值；跨过熄屏的部分，用边沿快照里的 `cg` 把熄屏那段扣掉。
- 后台时长：单元存活时间（`new` 到 `gone`，或 journal 的退出时刻）减去前台时长。

**单元名 → 应用 id**（在报表里做，先还原 `\xNN`）：

| 变体 | 例子 | 规则 |
|---|---|---|
| dock 启动的（`apps.cpp:191-194`） | `app-y700-org.telegram.desktop-3315-12.scope` | 去掉 `app-y700-` 和末尾的 `-\d+-\d+`。id 里非 `[A-Za-z0-9_.-]` 的字符已被换成 `_`，匹配 .desktop 时 `_` 当通配符 |
| KDE 启动器 / XDG | `app-org.kde.dolphin-48213.scope`、`app-org.kde.konsole@1a2b.service` | 去掉最后一个 `-<数字或十六进制>` 或 `@…`（id 里的连字符已被转义） |
| flatpak | `app-flatpak-org.telegram.desktop-4120.scope` | 去掉 `app-flatpak-` 和 `-\d+`。dock 那个 scope 很快变空，两者合并成同一个应用 |
| Steam / 带启动器前缀 | `app-steam-arm64-…service` | 查 `rules.json` 的 `aliases`（→ `steam-arm64`）；否则逐段去前缀，和已知的 desktop id 做最长匹配 |

**id → .desktop**
- 目录表照搬 `apps.cpp:24-28` 的六个目录。
- 依次试：精确 id → 小写 → `rules.json` 的别名（例如 `com.google.Chrome` → `google-chrome`）→ 前台日志里同一 cgroup 的 class 去比 `StartupWMClass`。
- 名字取 `Name[zh_CN]`，没有就取 `Name`；图标取 `Icon=`。
- 能对上一个可见的 .desktop、或者当过前台的，才算「应用」。
- 我们自己的 `y700-*` 单元、KWin、plasmashell、pipewire 等，按 `rules.json` 的 `categories` 分到「系统界面」或「系统后台」。
- Steam 的 class `steam_app_<N>`：去找 Exec 里含 `rungameid/<N>` 的 .desktop 当名字。

## 4. Attribution model

**怎么切**
- 区间：同一次开机里相邻两条 S 之间。
- 段：亮灭屏和供电状态都不变的连续区间，最长 60 min。短于 5 min 的亮屏段并入时间上最近的亮屏段一起对账。电量计噪声在平静时 σ≈58 mW（690a169c 实测），按段对账才稳。
- 区间内的放电比例 f = Don/Ton（熄屏用 Doff/Toff）。
- 一个区间跨着插拔电时，切进页面范围的份额（`ranges.step_weight`）分两种（10-31 修订）：flightrec 的能量增量只在放电时累加，插电那段从分子分母都去掉；处理器秒数、图形秒数、熄屏唤醒次数是整个区间数出来的，插电那段只从分子去掉（`counted=True`）。之前两者共用前一种，拔电前后那个 30 min 区间插电 25 min 时，「自上次充满」把这 25 min 的处理器秒数和唤醒次数全算了进来（10-31 平板：Steam 处理器 247 s、熄屏唤醒约 200 万次，应为约 215 s、约 162 万次）；能耗和百分比本来就对。系统界面的 KWin 图形忙秒数随之改按 r_kwin·Ton 计（能耗仍是 r_kwin·Don·g）。

**是否插电（评审修订）**

UPower 的历史文件判断不了「现在插没插电」和「刚拔下」：
- 写盘合并到 10 min 一次（上游 `up-history.c` 的 `UP_HISTORY_SAVE_INTERVAL`）；
- charge 历史只在电量 % 变化时加点，旁路或停在上限时 % 不变，整段插电期间文件里可能一个点都没有；
- 每个文件只留 7 天。

所以按下面的优先级拼插电时间线：
1. 现在的状态：页面打开时，C++ 和报表直接读 sysfs 电池的 `status`。
2. 最近 7 天：报表 exec 一次 `busctl --system --json=short call org.freedesktop.UPower <电池对象> org.freedesktop.UPower.Device GetHistory suu <type> <秒> 0`，charge 和 rate 两种各一次，拿内存里的数据，包括还没写盘的点。rate 历史点多，而且也带 state。读不到时再退回读 `.dat` 文件。
3. 7 天以外，以及作为第二来源：账本里 `pw` 边沿快照的 `st`、`cap`。
4. `charging`、`fully-charged`、`pending-charge`，以及 sysfs 的 `Not charging`、`Full`，都算插电。

- 不按 |bat| 大小判断：放电中也会出现成串的 `-0mW`。
- 测试要有这个情形：`.dat` 最后一点仍是 charging，sysfs 已经 Discharging 5 min。
- 插电段的能量和时长都不计。例外是充电器功率不够：这一段平均 bat > +50 mW，而且电量 % 降了 ≥1，就当放电段算（README：电脑 USB 口只有 2.5–4 W）。

**亮屏池（每个区间）**
```
基本耗电 F = F_on·Don
屏幕     S = Don·(D_on + B(ℓ̄))，ℓ̄ = Δbl/Ton
CPU 单价 κ = Σc b_c·P_c(f̄_c) / Σc b_c；P_c(f) = Pmax_c·(f/fmax_c)^2.2；b_c 是该簇忙碌增量
应用 u   A_u = f·(κ·Δcpu_u + Σ客户端 Δengine_s·g(Δcycles/Δengine_ns))；g(f) = Pg·(f/1.2 GHz)^2
KWin     f·κ·(Δcpu_kwin − Δcpu_xw) + r_kwin·Don·g(205 MHz)            → 系统界面
Xwayland f·(κ·Δcpu_xw + GPU_xw)：前台 class 命中 rules.json 的 x11_classes 时记给前台应用，否则记「系统界面·X11 兼容层」
内核     f·κ·(Δroot − Δuser.slice − Δsystem.slice − Δinit.scope)         → 系统后台·内核与中断
Wi-Fi    f·min(k_pkt·Δpkt, P_wifi_max·Ton)
```

**熄屏池（每个区间）**
```
F = F_off·Doff
R = Δctx/Toff（ctxt 折成唤醒数，先按 1:1；评审修订：WAKEUPS.md:11-12 实测 ctxt 409/s、idle 进入 285/s、退出 467/s，比值约 0.9–1.4:1，不是 2:1）
W = A·(1−e^{−R/R0})·Doff；W_u = W·wk_u/Σwk（-k 计入内核）；区间里没有 wk 时按 CPU 份额分，并打标记
CPU、GPU、Wi-Fi 的公式同亮屏池
```

**对账（每段）**：E 是实测放电能量，Fix = F + S，Soft = 其余各项之和。
- Fix + Soft ≤ E：「没算清的部分」= E − Fix − Soft。
- Fix ≤ E < Fix + Soft：Soft 乘 λ = (E − Fix)/Soft。λ < 0.5 时这段标「模型偏高」。
- Fix > E：全部乘 E/(Fix + Soft)，同样标记。页面脚注写出有几段被标记。

**已退出的单元**
- 先查 `journalctl --user -o json MESSAGE_ID=ae8f7b866b0347b9af31fe1c80b127c0`，用 `USER_UNIT`、`CPU_USAGE_NSEC`、`_BOOT_ID`、`__MONOTONIC_TIMESTAMP`：寿命总量减去账本里最后一次的值，补进退出时刻所在的那个区间。
- app.slice 的增量减去已知子单元，剩下的列成「已关闭的程序（认不出）」。

**百分比**
- pct_k = E_k / ΣE × D，D 是范围内各放电段电量降幅之和。
- 按最大余数法取整，各项相加正好等于 D。大于 0 但取整成 0 的项显示「<1%」。
- D < 3 时改用 ΣE / E_full。E_full = `charge_full` × 3.87 V（续航速查：约 34 Wh）。

**系数**：随包装在 `/usr/local/share/y700-battery/coeffs-v1.json`。标定后的结果写到 `~/.config/y700-battery/coeffs-v<N>.json`，用最高版本。每项都带 `src`、`date`、`ci95`。

| 系数 | 初值 | 来源 | 标定 |
|---|---|---|---|
| F_on | 330 mW | 续航速查：旋钮全关时的熄屏底噪 0.33 W。cx-auto 只在熄屏且用电池时才开，所以亮屏时的底噪按这个算（BATTERY-PAGE:53） | 标定 A 阶段 |
| F_off | 约 120 mW（随 A 一起推） | 先验：让 F_off + W 在平静时的 R≈150/s 下复现 E3a 平静的约 0.25 W。A≈150 mW、R0=130 时 W≈150·(1−e^(−150/130))≈103 mW，所以 F_off≈0.25 W−103 mW≈147 mW，取整写约 120–150 mW，以 B1 为准 | 标定 B1。账本里熄屏 ≥20 min 各段的 P25 只拿来给体检查漂移，不自动采用 |
| D_on | 600 mW | y7/y9 配对：亮屏额外 0.5–0.7 W | A1 外推到背光 0，再减 F_on，**再减同一窗口里模型算出的系统界面 CPU/GPU 项**，免得重复计 |
| B(ℓ) | 分段线性 (41,0) (410,250) (2048,1620) (4095,3370) mW，约 0.83 mW/级 | 1/10/50/100 % → 1.13/1.38/2.75/4.50 W | A1 重测 4 档 |
| Pmax_c | cpu0–5：1500 mW/核；cpu6–7：3000 mW/核 | 假设（量级） | B4/B5 |
| Pg、r_kwin | 2500 mW；0.05 忙秒 / 亮屏秒 | 假设；r_kwin 由开机 28.6 h 里 GPU 忙 1167 s、按约 6.5 h 亮屏推出 | B6（要有 GPU 负载工具）；A 阶段以 root 读 KWin 的 fdinfo |
| A、R0 | 150 mW；130 次/s | 评审修订：README:3615 的 0.05 W 是旋钮开、关两种状态之差。按本模型，这个差 = A·e^(−R/R0)，R≈150 时约 0.32·A，反推 A≈150 mW。WAKEUPS.md:11 的「300 次/s 时 9 %、50 次/s 时 69 %」是 RESEARCH §1.4 的**模型值**，不是实测 | B2/B3 |
| k_pkt、P_wifi_max | 0.2 mJ/包；300 mW | 假设 | B7 |

`y700-battery-report --fit`：在账本数据上做非负最小二乘，每个系数只在当前值的 ×0.5–×2 之内才建议采用。**采不采用由人手动决定，不自动生效。**

## 5. The "自上次充满" rule

1. **插电会话**：按第 4 节「是否插电」拼出的时间线（sysfs 当前状态 → UPower GetHistory → 账本边沿），把插电状态连成一段；间隔不到 2 min 的（线插松了）并成一次。（评审修订：不再只读 `history-charge*.dat`）
2. **算不算充满**：期间出现过 `fully-charged`，或者电量最高 ≥ `full_pct`（rules.json，默认 98）。**不读充电上限**：旁路会把 `charge_control_end_threshold` 压成当时的电量（`config.rs:38-41`、`features.rs:98-107`），读它会把旁路误当充满。
3. **锚点**：最近一次已经结束的「充满」会话的拔线时刻。
4. **正插着电、而且已经满了**：显示上一轮，标题「上一轮：29日 22:40 拔下 → 31日 08:10 插上」，横幅「已充满 · 正在用充电器」。
5. **正插着电、还没满**：范围是锚点到现在，当前这段画成插电带。
6. **拔下不到 10 min**：显示「刚充满」状态，见第 6 节。
7. **40 天内一次都没充满**：从最早的数据开始，标题「自 10-25 起（之前没有记录）」。7 天以外靠账本边沿的 `st`、`cap` 判断（评审修订）。拔下时刻早于 now − 40 天的充满会话不算锚点：账本按整段文件清理，最老的那一段里也许还留着它，但它已在 40 天之外，再早一些 since_full 的日桶还会超过 48 个；这种情况照本条处理。
8. 停在某个上限、或旁路供电时拔下（不到 98 %）**不重置**锚点，这段画成插电带，副标题写「中间插电 2 次」。用掉的 % 是 D，不是首尾相减。

## 6. Page app

**分工**
- C++：`main.cpp`、`report.cpp`。
  - `setDesktopFileName("y700-battery")`，`showMaximized()`。
  - 先显示缓存 `~/.cache/y700-battery/last.json`。**评审修订**：
    - 电量 %、充放电状态由 C++ 直接读 sysfs 的当前值显示，不从缓存来；
    - 缓存超过 10 min 就不显示；
    - 报表出错时，缓存部分整块调暗，写「x 分钟前的数据」；页面开着、先前成功过的那份报表同样处理（10-31 审计修订：不只缓存），第 1 行不写剩余时间；
    - 用 `Y700_BATTERY_REPORT` 时不写缓存。
  - 读 `$XDG_RUNTIME_DIR/y700-battery/pid` 并核对 comm，给 batteryd 发 USR1；等账本变长，最多 1 s。
  - 用 QProcess 异步跑 `y700-battery-report --json`，一次算完三个范围，解析成 QVariantMap 交给 QML。
  - `openKde()`：`startDetached("/usr/local/bin/y700-battery", {"--kde"})`。
- 图标用 `Kirigami.Icon`，和 `Dock.qml:196` 一样，不写 ImageProvider。
- 环境变量 `Y700_BATTERY_REPORT=<json 文件>`：直接读这份 JSON（测试台用）。
- **页面没有任何定时器，也没有循环动画**。重跑报表只在这几种时候：窗口重新激活、且距上次开始跑报表超过 2 min；窗口一直激活着时，flightrec 的 edge 说屏幕重新亮了（立刻跑），或亮屏时来了别的 edge、且距上次开始超过 2 min；实时读数发现充电器插上或拔下。都由事件触发（窗口激活、inotify），不轮询（6b.c 数据流第 7、8 条）。

**报表的 JSON**

> 下面是最初的草图，只表达意图；字段、取值和不变量以第 6b 节为准。

```json
{"v":1,"now":1761900000,"rec":{"running":true,"degraded":false,"since":1761800000},
 "battery":{"pct":57,"state":"discharging","health_pct":98,"cycles":10,"full_wh":34.4},
 "coeffs":{"version":1,"calibrated":false,"date":null},
 "ranges":{"since_full":{
   "start":1761811402,"end":1761900000,"title":"自上次充满","sub":"10-30 07:12 拔下后","state":"ok",
   "used_pct":43,"on_s":11520,"off_s":50700,"charger_s":0,"coverage":0.62,"remain_h":9.2,"brightness_hint_pct_h":1.0,
   "model_high_segments":1,"unknown_time_boots":0,
   "curve":[[1761811402,100]],"bands":{"on":[[t0,t1]],"charger":[],"gap":[],"uncovered":[]},
   "items":[{"id":"app:org.telegram.desktop","kind":"app","name":"Telegram","icon":"org.telegram.desktop",
     "pct":12,"pct_raw":11.6,"fg_s":4800,"bg_s":21600,"cpu_s":405,"gpu_s":41,"wake_off_h":24000,
     "split":{"fg":9,"bg":3,"off":2},"buckets":[[1761811200,0.8]],"windows":[["Telegram",4800]],"note":null}]},
  "24h":{},"7d":{}}}
```

- `state` 取值：`ok|just_full|all_charger|empty|partial`。
- `kind` 取值：`screen|floor|app|apps_rest|ui|sys|wifi|other`。
- `buckets`：24 小时视图按小时，7 天视图按天，「自上次充满」不超过 48 桶。
- `curve` 不超过 400 个点。
- `--text` 输出带 Wh、mW 的明细，给 agent 看。

**视觉**
- 颜色：底色 #121212，正文 #f2f2f2，次要文字 #9a9a9a，强调色 #2e6bf6，充电 #34c759，屏幕 / 亮屏条 #f2c94c，分隔线 #262626。
- 圆角不超过 4 px，不用阴影。
- 字号：标题 32，大数字 72 Light，正文 22，次要 18，最小 16。

**横屏**：最大化后实际可用 1600×974，状态栏占 28（shellbar `main.cpp:163`）。左栏 x 56–968，右栏 x 1016–1544，栏间距 48。
- **顶栏 y 24–80**：左边「电池」32 px DemiBold；右边分段控件 3×176 = 528，正好对齐右栏 x 1016–1544，高 56，字号 22。选中段为强调色填充、白字。
- **概要 y 104–196**：
  - 左边「57%」72 px；
  - x 248 起三行：「正在用电池 · 按过去一天的用法还能用约 9 小时」22 px；「上次充满：昨天 22:40，之后用掉 43%」18 px 灰；「亮屏 3 小时 12 分 · 熄屏 14 小时 5 分」18 px 灰。
- **横幅 y 208–248**：左边一道 3 px 色条，文字 18 px；不需要横幅时这一条留白。
- **曲线**：
  - 绘图区 x 104–968、y 264–560；0/50/100 % 三条网格线，刻度文字 16 px，右对齐到 x 92；
  - 电量线 2.5 px，圆头；画线的 Shape 宽到绘图区右边为止（横屏 x 968、竖屏 x 970），最后一点的圆头在这里裁掉，不越过栏的右边；上下各多出 4 px，0 % 和 100 % 处不裁线；插电段线变绿，底下铺 12 % 绿带；缺数据处用灰色斜纹加虚线；
  - 亮屏条 y 572–588；时间刻度 y 596–620；图例 y 632–656；
  - 用 `QtQuick.Shapes` 的 `PathPolyline` 画。
- **用电去向 y 688–788**：标题 20 px；堆叠条 912×24（y 728–752），各段之间留 2 px；行内图例 16 px，y 760–784。八类一行放不下时折到第二行 y 784–808，最多两行：行与行之间不留空，项与项之间的 16 px 是每项自带的右侧留白（`Flow` 的 `spacing` 也会加在行间，会把第二行推到 800–824、压住 812 的说明，所以设 0）。
- **说明 y 812–868**（18 px 灰，两行）：「怎么算的：总耗电是电池实测；屏幕估得较准，各应用只适合看谁多谁少（可能差三到五成）；插着充电器的时间不算。」后面跟「估算 · 未校准」或「估算 · 11-02 校准」。
- **健康行 y 886–950**：64 高，整行可点；左边「电池健康 98% · 充放电 10 次」，右边「KDE 电量页 ›」。
- **右栏**：
  - 标题「谁用了电」24 px，y 104–144；右侧「占用掉的电量」16 px 灰。
  - 只有部分数据时，y 148–172 写「从 31日 14:05 起才有按应用的记录」。
  - 列表 y 184–950，每行 76 高：
    - 图标 44（x 1016）；
    - 名字 22 px DemiBold（x 1076）；
    - 副行 18 px 灰，例如「前台 1 小时 20 分 · 后台 6 小时」；
    - 百分比 24 px，右对齐到 x 1544；
    - 行底一条 3 px 份额条，最长 468，按最大一项缩放；
    - 分隔线从 x 1076 起。
  - 列表成员：屏幕、各应用、系统界面、系统后台、Wi‑Fi（粗估）、基本耗电（开着机就有）、没算清的部分，混在一起按大小排。不到 0.5 % 的应用并成「其他应用（N 个）」。

**详情**（右栏原地换掉）：
- 「‹ 谁用了电」56 高；图标 64 + 名字 30 px；
- 「约用掉 12% 电量」44 px Light；
- 「在前台时 9% · 在后台时 3%（其中熄屏 2%）」20 px；
- 事实表每行 56 高：前台使用、后台开着、处理器忙 N 分钟、图形芯片忙 N 分钟、熄屏时醒来约 N 万次；Steam 另列各窗口的前台时长；
- 左边曲线底部叠出这一项每个桶的用电柱（强调色，35 % 不透明度，最高占绘图区 30 %）；
- 组成项（屏幕、基本耗电等）的详情换成一段说明：它是什么、怎么估出来的。屏幕详情加一句「亮度每调低 10%，亮屏每小时约少用 1.0% 电量」，这个数按当时的平均亮度从 B(ℓ) 算。

**交互**
- 分段切换：指示块滑动 180 ms，`(0.23,1,0.32,1)`；数据直接换，不做动画。
- 按压反馈：列表行 scale 0.98 + 6 % 白底，120 ms ease-out；按钮 scale 0.96，160 ms（和 `Tile.qml:22` 一致）。
- 详情：进入时 x 位移 +24 → 0 加淡入，220 ms；退出 160 ms。
- 曲线读数：横屏按住即拖；竖屏长按 250 ms 再拖（避免和滚动冲突）。显示 1 px 竖线和「30日 14:20 · 64% · 亮屏」，跟手、不加动画；松手 1.5 s 后用 150 ms 淡出。
- 返回键 / Esc：在详情里回到列表；在列表里关闭窗口。
- 报表超过 150 ms 还没回来才出静态骨架，不做闪光。

**空数据 / 部分数据**

| 情况 | 显示 |
|---|---|
| 账本为空 | 曲线照常画（来自 UPower）；列表处写「刚开始记录」/「从 31日 14:05 起记各应用的用电，用一阵子再来看。」 |
| 拔下不到 10 min | 「刚充满」/「拔掉充电器后开始统计这一轮。」，加一个 56 高的「看 24 小时」按钮 |
| 整段都插着充电器 | 「这段时间一直插着充电器，电池没怎么用，所以不分应用。」 |
| 有缺口 | 曲线上画灰色斜纹；横幅「有 4 小时没记录（关机或重启）」 |
| 降级（`cov:0`）或缺 acc | 横幅「这段时间的总耗电按电量百分比粗算」。**评审修订**：降级时熄屏期间只有 30 min 一个检查点，短亮屏会整个漏掉，所以降级区间不出屏幕和应用的拆分，列表写「这段时间没有分项记录」，横幅写明原因。前台日志的行最多只当「这时候亮过屏」的下界。不为这个加熄屏轮询 |
| batteryd 没在运行 | 横幅「用电记录没在运行」 |
| 报表出错 | 小字写出错误原因；KDE 电量页按钮照常可用 |

**竖屏**：可用 1002×1572，边距 32。
- 整页是一个 Flickable：顶栏 → 分段控件（y 96–152，3 段宽 312/313/313）→ 概要 → 横幅 → 曲线（绘图区高 260）→ 去向 → 列表 → 说明 → 健康行。
- 详情整页推入。
- 按 `width > height` 切换布局，旋转时不加动画；已选的范围和打开的详情保留。
- KWin 画标题栏时，少掉的高度由曲线吸收，绘图区最低 240。

## 6b. 实现契约（报表 JSON、页面接口、报表内部接口）

本节是报表、页面、测试台分头并行开发时的约定，取代第 6 节「报表的 JSON」那段草图。可机查的权威是两份代码：
- `report/y700_battery/contract.py`：`validate(doc) -> list[str]`，JSON v1 的全部规则；
- `report/y700_battery/types.py`：报表内部各模块之间传递的数据类型，docstring 写明单位。

本节与这两份代码不一致时以代码为准，并当场改本节。**契约只经主线程改**：某个 agent 觉得字段不够用就提出来，不自己加。

活例子是 `linux/dock/tests/batpage/` 下的 7 份罐装报表，由同目录的 `gen_batpage.py`（一周的分钟级模拟，remain、充电次数、apps_rest 的 bg_s、data_from 都照报表的规则算）生成，不手改：改时间线后重跑 `python3 -I gen_batpage.py`。它们都过 `validate()`，`report/tests/test_contract.py` 每次都查，还查生成器重跑出来的内容和文件逐字节一致。

| 文件 | 场景（now = 10-30 08:11，UTC+8） |
|---|---|
| `ok.json` | 10-29 07:40 拔下，用到 24 %。三个范围都是 ok；14 行，含 Steam 的「示例游戏」窗口和「其他应用（2 个）」；7 天里充电 5 次，有「已关闭的程序（认不出）」 |
| `just_full.json` | 08:06 拔下，电量 99 %。自上次充满是 just_full，24 小时、7 天照常 |
| `empty.json` | 账本 08:07 才开始。三个范围都是 empty（「刚开始记录」），曲线照画 |
| `first_run.json` | 账本 08:09 才写下第一个快照（熄屏），还没有能分项的一步。三个范围都是 empty（「刚开始记录」），没有亮屏带，整段都是 uncovered；`data_from` 是 08:09，之前亮灭不明，页面不能画成熄屏 |
| `partial.json` | 账本 10-29 10:20 才开始；13:10–17:10 关机缺口；21:00–22:05 降级。三个范围都是 partial，横幅 degraded + gap |
| `all_charger.json` | 插着电停在 80 %（旁路，not_charging）。三个范围都是 all_charger；自上次充满退回「自 10-21 起（之前没有记录）」 |
| `degraded.json` | 飞行记录器 10-29 07:00 起没在记电流。自上次充满、24 小时是 empty（「没有分项记录」），7 天是 partial，`rec.degraded` 为真 |

### 6b.a 报表 JSON v1

**总则**
- `y700-battery-report --json` 往 stdout 写**一个** UTF-8 JSON 对象（`ensure_ascii=False`，紧凑格式），退出码 0。
- 键集合是精确的，不多也不少；可空的字段写 `null`，不省略。
- 类型：表里的「int」不接受 `true`/`false`；「num」是 int 或 float。
- 单位：
  - 时刻一律是 Unix epoch 秒（int），时长一律是秒（int）；
  - 百分比一律是**电池的百分点**（0–100 的电量，7 天里可以超过 100），不是占总量的比例。
- **页面永远看不到 Wh、mW、J**：能量只在报表内部用，出 JSON 前全部换成百分点。唯一的 mW 在 `diag` 里，页面不读 `diag`。
- 出错：
  - stdout 写 `{"v":1,"error":"<中文原因>"}`，退出码 2；traceback 只写 stderr。
  - 页面见到 `error` 键，就按第 6 节「报表出错」那一行处理。
  - 只要能出 JSON，状态再差（empty、降级）也是退出码 0。

**顶层**

| 字段 | 类型 | 含义 |
|---|---|---|
| `v` | int | 恒为 1 |
| `now` | int | 报表的「现在」；所有范围的 `end` ≤ `now` |
| `tz_offset_min` | int，−720..840 | 本地时区比 UTC 快多少分钟（UTC+8 = 480）。桶网格、报表里的中文时刻、QML 的时刻格式化都按它算，**不用系统时区** |
| `took_ms` | int | 报表自己用了多少毫秒 |
| `rec` | object | 记录器状态 |
| `battery` | object | 当前电池 |
| `coeffs` | object | 用的是哪份系数 |
| `remain` | object 或 null | 剩余时间；插着电时必须是 null |
| `ranges` | object | 恰好三个键：`since_full`、`24h`、`7d` |
| `diag` | object | 只给 `tools/y700-checklist.py` 用，页面不显示 |

**`rec`**

| 字段 | 类型 | 含义 |
|---|---|---|
| `running` | bool | batteryd 在跑：`$XDG_RUNTIME_DIR/y700-battery/pid` 指向的进程，comm 是 `y700-batteryd`（`--from` 时见 6b.b） |
| `degraded` | bool | 账本最新一条 S 行是 `cov:0` |
| `since` | int 或 null | 账本最早一行的时刻；没有账本时为 null |
| `last_write_age_s` | int 或 null | `now` − 账本最新一行的时刻 |
| `fg_log` | bool | 前台日志在记：本次开机有 `fg-<boot8>*.log`，最后一个标记不是 `STOP`，而且 refresh-auto 单元还活着 |
| `clock_unsynced` | bool | 本次开机还没对上网络时间（第 2 节时钟规则里「当前这次开机还没同步」的情形） |

**`battery`**（报表启动那一刻的 sysfs 值）

| 字段 | 类型 | 含义 |
|---|---|---|
| `pct` | int 0..100 或 null | `capacity` |
| `status` | `charging`、`discharging`、`full`、`not_charging`、`unknown` 之一 | sysfs `status` 转小写、空格换下划线（`Not charging` → `not_charging`），别的值都算 `unknown` |
| `plugged` | bool | 任一 `scope` 不是 Device、`type` 不是 Battery 的 supply 的 `online` = 1（挑法见 6b.b「电池」那一行），或 status 是 charging / full / not_charging。后一条成立时它必须为真 |
| `health_pct` | int 0..150 或 null | round(`charge_full` / `charge_full_design` × 100) |
| `cycles` | int 或 null | `cycle_count` |

页面平时的电量和充放电状态由 C++ 当场读 sysfs（第 6 节评审修订）。这一块只在 `Y700_BATTERY_REPORT`（罐装）模式下充当实时值；健康行用的是这里的 `health_pct` 和 `cycles`。

**`coeffs`**
- 四个字段：`version`（int ≥ 1）、`calibrated`（bool）、`date`（`"YYYY-MM-DD"` 或 null）、`source`（`package`、`user`、`dev` 之一，表示从哪找到的，见 6b.b）。
- 说明行末尾的「估算 · 未校准」由报表拼进 `range.footnote`，页面不自己拼。

**`remain`**
- 形如 `{"h": num, "basis_h": int}`，`h` 是小时数；不为 null 时 `basis_h` 恒为 24，即下面那个窗口的小时数。
- 算法：看过去 `basis_h`（= 24）小时，即 [now − 24 h, now]，把其中的**放电**时间（亮屏、熄屏、不能分项的都算；插电和缺口不算）加起来，用这段时间里电量掉的 % 除以它，得出平均每小时掉多少 %，再用当前电量除以它。取一整天，是为了不让一局游戏或一夜熄屏把它带偏：熄屏一夜之后，按最近 3 小时算会说还能用约 73 小时，看着屏幕的人会被误导。
- 插着电、这 24 小时里的放电时间不到 1 小时、或者电量没掉，为 null。
- 页面写「按过去一天的用法还能用约 N 小时」（见下文「QML 用数字拼的文字」）；`--text` 写「剩余：约 N 小时（按过去一天的放电）」。

**`diag`**（体检阈值归 `y700-checklist.py` 管，这里抄第 7 节的值供对照）

| 字段 | 类型 | 含义 | 体检 |
|---|---|---|---|
| `unexplained_median_7d` | num 0..1 或 null | 7 天里各放电段「没算清」占已分项能量比例的中位数 | > 0.20 报「电池页系数要重标」 |
| `floor_off_learned_mw` | num 或 null | 7 天里 ≥ 20 min 的熄屏段，实测平均功率的 P25；不到 4 段时为 null | 与下一项（模型对同样这些段算出的功率）差 > 25 % 报重标，按下一项算百分比 |
| `floor_off_model_mw` | num | 同一批熄屏段上，模型在对账前给出的平均功率（F_off 加唤醒、CPU/GPU、Wi‑Fi 各软项）的 P25；不到 4 段时退回系数里的 `F_off` | |
| `coeff_age_days` | int 或 null | `now` − `coeffs.date` 的天数 | > 90 报 |
| `ledger_bytes` | int | 账本加前台日志的总字节数 | > 20 MiB 报（16 MiB 上限加一份 4 MiB 分段的余量：修剪约一天一次，两次之间总量可以多出不到一天的量） |
| `ledger_newest_age_s` | int 或 null | 账本最新一行的年龄 | > 2400 报 |
| `energy_age_s` | int 或 null | `/run/y700-flightrec/energy` 的年龄，按它的 `t=` 和当前 mono 算；文件不在时为 null | flightrec 在跑而 > 60 时报 |
| `segments_flagged_7d` | int | 7 天里标「模型偏高」的段数 | 只记录 |

体检列里报「电池页系数要重标」的三条（`unexplained_median_7d`、`floor_off_learned_mw` 对 `floor_off_model_mw`、`coeff_age_days`）：`coeffs.calibrated` 为 true 时报 WARN；为 false（还是没标定的先验值）时只报 INFO，不触发每日通知。先验值本来就对不上账本，标定前天天报警只会逼作者同意标定夜。

**范围 `ranges.<key>`**

| 字段 | 类型 | 含义 |
|---|---|---|
| `key` | str | 等于所在的键 |
| `state` | 见下文「状态」 | |
| `start`、`end` | int | `24h` 恰好是 [now − 86400, now]，`7d` 恰好是 [now − 604800, now]；`since_full` 见第 5 节（显示上一轮时 `end` 是插上的时刻，< now） |
| `title` | str | 范围的短名字：「自上次充满」「上一轮」「自 10-21 起（之前没有记录）」「过去 24 小时」「过去 7 天」。竖屏整页详情里用作小标题，`--text` 用作段标题 |
| `sub` | str | 概要第二行的整句（见下文「报表生成的文字」） |
| `used_pct` | int | `used_pct_raw` 四舍五入（.5 进位） |
| `used_pct_raw` | num | D：各放电段电量降幅之和，含降级段和充电器带不动的段；D < `d_min_pct`（3）时改为能量 / 满电能量 × 100 |
| `on_s`、`off_s` | int | 放电时间里亮屏、熄屏各多少秒（不能分项、但知道亮灭的段也算） |
| `charger_s` | int | 插着电、而且带得动的秒数 |
| `gap_s` | int | 什么都不知道的秒数：关机、两次开机之间、时间不明的开机 |
| `uncovered_s` | int | 放电但不能分项的秒数（账本还没开始、降级、缺 acc）。知道亮灭时，它和 `on_s`/`off_s` 重叠 |
| `coverage` | num 0..1 | 已分项的放电能量 / 全部放电能量；没有放电时为 0 |
| `data_from`、`data_from_text` | int 和 str，或都为 null | 分项记录晚于范围开头、而且之前有放电时才有值：`data_from` 是第一个能分项的时刻；范围里一段都不能分项时，是亮灭状态开始可知的时刻（账本第一个快照；之前没人记亮灭，页面不能把那段画成熄屏），一直不可知就是 `end`。`data_from_text` 是右栏 y 148–172 那句「从 29日 10:20 起才有按应用的记录」。两个同时为 null 或同时有值 |
| `brightness_hint_pct_h` | num 或 null | 亮度每调低 10 %，亮屏每小时少用多少 %；没有亮屏数据时为 null。同一个数已写进屏幕项的 `hint`，页面只用 `hint` |
| `model_high_segments` | int | 标「模型偏高」的段数（已写进 `footnote`） |
| `unknown_time_boots` | int | 范围里时间不明的开机次数。只有 since_full 可能非 0，24h/7d 不收这些开机 |
| `curve` | `[[int t, num pct], …]` | 电量曲线：≤ 400 点，pct 0..100、一位小数；t 不减（同一 t 两点 = 竖直的一跳），落在 [start, end] 内 |
| `bands` | `{"on":[], "charger":[], "gap":[], "uncovered":[]}` | 各是 `[[a, b], …]`：排好序，不重叠也不首尾相接，落在范围内 |
| `bucket_s`、`bucket_t` | int、`[int, …]` | 桶网格（见下文） |
| `items` | `[item, …]` | 右栏列表，按 `pct_raw` 从大到小 |
| `composition` | `[comp, …]` | 堆叠条 |
| `banners` | `[banner, …]` | 横幅 |
| `empty` | object 或 null | 不分项时列表位置的提示 |
| `footnote` | str | 说明行末尾：「估算 · 未校准」或「估算 · 11-02 校准」；有模型偏高的段时再加「 · 有 N 段估算偏高，已按实测压低」 |

**bands 的规矩**
- `on`：亮屏区间，画亮屏条（y 572–588）。可以和 `charger`、`uncovered` 重叠，总长 ≥ `on_s`。
- `charger`：曲线这一段变绿，底下铺 12 % 绿带；总长 = `charger_s`。
- `gap`：
  - 画灰色斜纹；曲线在缺口两端各有一个点，QML 把这一段画成虚线。
  - 总长 = `gap_s`，不和其他三种重叠。
- `uncovered`：
  - 放电但不分项；总长 = `uncovered_s`，不和 `charger` 重叠。
  - 主图不画；打开「没记到是谁用的」的详情时，用 neutral4 的 35 % 铺底标出来。
- 总长的容差是每段 2 s。

**桶**
- `bucket_t` 是每个桶开头的时刻，`bucket_s` 是桶长。
- 网格对齐的是**本地**时间：`(t + tz_offset_min × 60) % bucket_s == 0`。
- 各范围的网格：
  - `24h`：24 个 3600 s 桶。最后一个桶是 `end` 所在的本地整点，往前数 24 个；`start` 到第一个桶开头之间那不到 1 小时的用电，并进第一个桶。
  - `7d`：7 个 86400 s 桶。最后一个是 `end` 所在的本地自然日；`start` 那天剩下的部分并进第一个桶。
  - `since_full`：从 {900, 1800, 3600, 7200, 10800, 21600, 43200, 86400} 里挑能让桶数 ≤ 48 的**最小**那个。第一个桶含 `start`，最后一个桶满足 `bucket_t[-1] < end ≤ bucket_t[-1] + bucket_s`。
- 每一项的 `buckets` 与 `bucket_t` 等长，单位是百分点，加起来等于这一项的 `pct_raw`（容差 0.002 × 桶数 + 0.02）。详情里左边曲线底部的用电柱画的就是它。

**状态**（按下表顺序判，先命中的算）

| state | 条件 | items / composition | empty |
|---|---|---|---|
| `just_full` | 只在 since_full 出现：最近一次充满会话拔下不到 `just_full_s`（600 s） | 都为空 | 「刚充满」/「拔掉充电器后开始统计这一轮。」，`action` = `show_24h` |
| `all_charger` | 放电时间（`on_s + off_s`，带不动的充电器段算放电）< 300 s，而且 `charger_s` > 0 | 都为空 | 「一直插着充电器」/「这段时间一直插着充电器，电池没怎么用，所以不分应用。」 |
| `empty` | 能分项的放电 < 300 s | 都为空 | 账本刚开始：「刚开始记录」/「从 30日 08:07 起记各应用的用电，用一阵子再来看。」<br>降级或缺 acc：「没有分项记录」/「这段时间飞行记录器没在记电流，只能按电量百分比粗算总量，分不出应用。」<br>没有账本：「还没有记录」/「用电记录没在运行，只能画电量曲线。」 |
| `partial` | `uncovered_s` ≥ 300（按写出来的整数秒，即半入后的值判断，状态和数字总是一致） | 有，而且必有一项 `unrecorded` | null |
| `ok` | 其余 | 有，没有 `unrecorded`；`uncovered_s` < 300 | null |

- 不分项的三种状态照样给出 `used_pct`、各项秒数、`curve`、`bands`、`bucket_t`。概要、曲线、亮屏条照常画，只有列表和堆叠条换成 `empty` 的提示。
- `empty.action` 为 `show_24h` 时，提示下面出一个 56 高的「看 24 小时」按钮，点了切到 24 小时。

**列表项 `items[]`**

| 字段 | 类型 | 含义 |
|---|---|---|
| `id` | str | 应用：`app:<desktop id>`；前台见过、但没有可见 .desktop 的：`app:class:<窗口 class>`；认不出的已关闭程序：`app:#closed`。组成项：等于 `kind`。同一范围里唯一；同一个东西在三个范围里 id 相同 |
| `kind` | 见下表 | |
| `name` | str | 中文名，由报表给 |
| `icon` | str 或 null | 主题图标名，或 `file:///绝对路径`（.desktop 的 Icon=）。组成项的图标固定（见下表）。null 时 QML 用 `application-x-executable` |
| `role` | str | 颜色角色，由 `kind` 定（见下表） |
| `pct`、`pct_raw` | int、num | 占用掉的电量（百分点）。全体 `pct` 用最大余数法凑成 `used_pct`；`pct_raw` 加起来等于 `used_pct_raw` |
| `fg_s`、`bg_s` | 应用类为 int，其余为 null | 放电时间里在前台、开着但不在前台各多少秒。`apps_rest` 的 `fg_s` 是成员之和（前台不会重叠）；`bg_s` 是成员开着的时间取并集再减 `fg_s`，不是成员 `bg_s` 之和（那样同一秒会按应用数重复算，还可能超过范围本身） |
| `cpu_s`、`gpu_s` | int 或 null | 处理器忙、图形芯片忙的秒数。只有 app、apps_rest、ui、sys 可以有值 |
| `wake_off_n` | int 或 null | 熄屏时把系统叫醒的次数。可有值的 kind 同上 |
| `split`、`split_raw` | 应用类为 `{"fg","bg","off"}`，其余为 null | 在前台 / 在后台 / 后台里熄屏的那部分。`split` 是 int，`fg + bg = pct`，`off ≤ bg`；`split_raw` 是 num，`fg + bg = pct_raw` |
| `buckets` | `[num, …]` | 见上文「桶」 |
| `windows` | `[[str, int], …]` | 只有 app 有：各窗口的前台秒数，从多到少（比如 Steam 里的游戏），加起来 ≤ `fg_s` |
| `parts` | `[[str, num], …]` | ui、sys、other、apps_rest 才有：组成部分和各自的百分点，从大到小，加起来 ≤ `pct_raw`。apps_rest 的 parts 是被合并的那些应用：≥ 2 个，各 < 0.5，加起来 = `pct_raw` |
| `explain` | str 或 null | 组成项必有，说它是什么、怎么估的；app 为 null；apps_rest 可有可无 |
| `hint` | str 或 null | 只有屏幕项有：「亮度每调低 10%，亮屏每小时约少用 1.0% 电量」 |
| `note` | str 或 null | 详情里多出的一行说明。比如 Steam：「游戏和 Steam 本身合在一起算，下面按窗口列前台时长。」；或者前台时间有一段不明 |

| kind | id | name | icon | role |
|---|---|---|---|---|
| `screen` | `screen` | 屏幕 | `video-display` | `screen` |
| `app` | `app:…` | .desktop 的 Name[zh_CN] → Name[zh] → Name | .desktop 的 Icon | `accent` |
| `apps_rest` | `apps_rest` | 其他应用（N 个） | `application-x-executable` | `accent` |
| `ui` | `ui` | 系统界面 | `preferences-desktop` | `accent2` |
| `sys` | `sys` | 系统后台 | `preferences-system` | `neutral1` |
| `wifi` | `wifi` | Wi‑Fi（粗估） | `network-wireless` | `neutral2` |
| `floor` | `floor` | 基本耗电（开着机就有） | `battery` | `neutral3` |
| `other` | `other` | 没算清的部分 | `help-about` | `neutral4` |
| `unrecorded` | `unrecorded` | 没记到是谁用的 | `dialog-information` | `neutral4` |

- 组成项每种最多一行。`unrecorded` 是不能分项的那部分降幅：`pct_raw` = (1 − `coverage`) × `used_pct_raw`。
- 不到 `apps_min_pct`（0.5）的应用有 ≥ 2 个时，并成 `apps_rest`，名字里带个数；只有 1 个时照常单列。
- 为零的项不列。

**堆叠条 `composition[]`**
- 每个元素是 `{"kind","name","pct","pct_raw","role"}`。
- kind 的顺序固定：screen、apps、ui、sys、wifi、floor、other、unrecorded；为零的不列。`apps` = app + apps_rest。
- 名字依次是：屏幕、应用、系统界面、系统后台、Wi‑Fi、基本耗电、没算清、没记到。
- `pct` 也用最大余数法凑成 `used_pct`；`pct_raw` 等于对应各项之和。
- 画法：段宽按 `pct_raw` 分，行内图例写「名字 pct%」。

**颜色角色**（第 6 节的色板，加四个中性灰、一个浅强调色和横幅的警示色）

| role | 颜色 | 用在 |
|---|---|---|
| `screen` | #f2c94c | 屏幕；亮屏条 |
| `accent` | #2e6bf6 | 应用；详情里的用电柱 |
| `accent2` | #8fb0ff | 系统界面 |
| `neutral1` | #9a9a9a | 系统后台 |
| `neutral2` | #707070 | Wi‑Fi |
| `neutral3` | #4d4d4d | 基本耗电 |
| `neutral4` | #333333 | 没算清、没记到 |
| 横幅 `warn` | #f2994a | 横幅色条 |
| 横幅 `charge` | #34c759 | 横幅色条；插电段 |

**横幅 `banners[]`**
- 每个元素是 `{"kind","level","text"}`。每种最多一条，按下表顺序排；`level` 由 kind 定。
- 横屏只有一行的位置（y 208–248）：按顺序用「；」接起来，放不下就在末尾省略；色条取第一条的 level。
- 竖屏一条一行。

| kind | level | 什么时候有 | 文字例 |
|---|---|---|---|
| `recorder_off` | warn | `rec.running` 为假（这时必须有） | 用电记录没在运行 |
| `degraded` | warn | 范围里有降级段 | 有 1 小时 5 分只按电量百分比粗算（飞行记录器没在记电流），这几段不分应用。整段都降级时：飞行记录器没在记电流：总耗电按电量百分比粗算，不分应用 |
| `gap` | warn | `gap_s` ≥ 300 | 有 4 小时没记录（关机或重启） |
| `unknown_time` | warn | `unknown_time_boots` > 0 | 有 1 次开机的时间不明，曲线上接在前一次后面 |
| `clock_unsynced` | warn | `rec.clock_unsynced`，而且范围含本次开机。`rec.clock_unsynced` 为假时不许出 | 时间未校准：这次开机后还没对上网络时间，时刻可能不准 |
| `fg_off` | warn | 有 ≥ 300 s 能分项的放电，不知道谁在前台 | 前台记录没开（refresh-auto 没在运行），这段分不出前台后台 |
| `charger_now` | charge | 当且仅当 `battery.plugged` | 正在充电 / 已充满 · 正在用充电器 / 插着充电器 · 没在充电（停在上限） |

**报表生成的文字和 QML 自己排的文字**

报表负责一切跟数据有关的句子，QML 只做数字格式化和固定标签。时刻、时长的写法两边一致：`out.py` 和 `Fmt.js` 各实现一份，规则如下。
- 时长：< 60 s 写「不到 1 分」；< 1 h 写「M 分」；整点写「H 小时」；否则写「H 小时 M 分」。
- 时刻：
  - 一般写「HH:MM」，带日子时写「D日 HH:MM」，日期写「MM-DD」；
  - `sub` 里的拔线时刻用「今天 HH:MM」「昨天 HH:MM」，更早的用「D日 HH:MM」；
  - 都按 `tz_offset_min` 算。

| 谁出 | 文字 |
|---|---|
| 报表 | `title`、`sub`、`data_from_text`、`footnote`、横幅文字、`empty` 的标题和正文、各项的 `name` / `explain` / `hint` / `note`、`parts` 和 `windows` 里的名字、堆叠条的名字 |
| QML 固定写死 | 「电池」；分段「自上次充满」「24 小时」「7 天」；「谁用了电」「占用掉的电量」「‹ 谁用了电」；说明正文（第 6 节）；「电池健康 X% · 充放电 N 次」「KDE 电量页 ›」；「看 24 小时」；详情事实表的行名（前台使用、后台开着、处理器忙、图形芯片忙、熄屏时醒来）；「约用掉 N% 电量」「在前台时 a% · 在后台时 b%（其中熄屏 c%）」 |
| QML 用数字拼 | 见下面的列表 |

QML 用数字拼的文字：
- **概要第一行**：
  - 按实时状态写「正在用电池」「正在充电」「已充满 · 正在用充电器」「插着充电器 · 没在充电」；
  - 放电而且 `remain` 不为 null 时，后面加「 · 按过去一天的用法还能用约 N 小时」（`basis_h` ≥ 24；别的 `basis_h` 写「 · 按最近 {basis_h} 小时的用法还能用约 N 小时」）；h < 1 时写「约 N 分钟」。
- **概要第三行**：依次拼下面几段，用「 · 」连接；一段都没有时整行不显示。
  - `on_s + off_s` ≥ 60 时写「亮屏 X · 熄屏 Y」；
  - 亮灭不明 U = (`end` − `start`) − `on_s` − `off_s` − `charger_s` − `gap_s`（账本开始之前的放电就是这种），U ≥ 300 时写「亮灭不明 U」；
  - `charger_s` ≥ 60 时写「插电 Z」。比如 all_charger 只剩「插电 Z」，empty.json 的 7 天是「亮屏 4 分 · 熄屏 不到 1 分 · 亮灭不明 152 小时 10 分 · 插电 15 小时 46 分」。
- **列表副行**：
  - 应用写「前台 X · 后台 Y」，不到 1 分的那一半不写；
  - 屏幕写「亮屏 X」；
  - 系统界面、系统后台写「处理器忙 N 分钟」。
- **百分比**：`pct` = 0 而 `pct_raw` > 0 时写「<1%」。
- **处理器、图形芯片忙**：「N 分钟」。
- **醒来次数**：不到 1 万写「N 次」，否则写「约 N 万次」。
- **曲线读数**：「30日 14:20 · 64% · 亮屏」；亮屏、熄屏、插电、没记录由 bands 决定。
- **时间刻度**：范围 ≤ 36 小时写「HH:MM」，否则写「D日」。

| 情形 | title | sub 例 |
|---|---|---|
| since_full，锚点是充满 | 自上次充满 | 上次充满：昨天 07:40，之后用掉 76%；中间插过电时再加「，中间插电 2 次」 |
| since_full，刚充满 | 自上次充满 | 刚充满：08:06 拔下 |
| since_full，插着电且已满（显示上一轮） | 上一轮 | 上一轮：29日 22:40 拔下 → 31日 08:10 插上，用掉 64% |
| since_full，40 天没充满过 | 自 10-21 起（之前没有记录） | 10-21 起没充满过，用掉 N%；一直插着时写「10-21 起没充满过，一直插着充电器」 |
| 24h | 过去 24 小时 | 过去 24 小时用掉 73%；有充电时加「，充电 N 次」 |
| 7d | 过去 7 天 | 过去 7 天一共用掉 428%（约 4.3 次满电），充电 5 次 |

「充电 N 次」数的是插上充电器的次数：范围里有充电时间、而且充电器带得动的插电会话；两次之间只隔着缺口的算一次（插着电重启会把一次插电画成两条插电带）。N 不是 `bands.charger` 的条数。

第 5 节说的标题「上一轮：…」「自 10-25 起（之前没有记录）」落在这里：整句进 `sub`，也就是概要第二行，因为横屏没有另放标题的位置；`title` 只是短名字。

**其余不变量**（`contract.py` 全都查）
- `used_pct` = floor(`used_pct_raw` + 0.5)。items 和 composition 的 `pct` 都用最大余数法凑成 `used_pct`。
- 秒数，容差取 max(120 s, 范围长的 1 %)：
  - on + off + charger + gap ≤ 范围长 + 容差；
  - 再加上 uncovered ≥ 范围长 − 容差。
- 应用类的 `split` 与 `pct` 一致，`split_raw` 与 `pct_raw` 一致；组成项的 `fg_s`、`bg_s`、`split` 必须为 null。
- 应用类（app、apps_rest）`fg_s + bg_s` ≤ `on_s + off_s` + 1。
- 电池和横幅之间：
  - `rec.running` 为假 ⇔ 有 `recorder_off`；
  - `battery.plugged` ⇔ 有 `charger_now`；
  - 插着电时 `remain` 为 null；
  - status 是 charging / full / not_charging 时，`plugged` 必须为真。
- 错误文档只有 `v` 和 `error` 两个键。

**相对第 6 节草图的改动**
- 电池块：
  - `battery.state` 改名 `status`，取值加 `full`、`not_charging`、`unknown`；
  - 去掉 `full_wh`（页面不碰 Wh），加 `plugged`。
- `remain_h` 从范围里挪到顶层的 `remain`。
- `wake_off_h` 改为次数 `wake_off_n`。
- `buckets` 从 `[[t, v]]` 改成和 `bucket_t` 对齐的数组。
- 新增 kind `unrecorded`。
- 新增字段：
  - 顶层与状态块：`tz_offset_min`、`took_ms`、`rec.{last_write_age_s, fg_log, clock_unsynced}`、`coeffs.source`、`diag`；
  - 范围：`used_pct_raw`、`uncovered_s`、`data_from`/`data_from_text`、`bucket_s`/`bucket_t`、`composition`、`banners`、`empty`、`footnote`；
  - 列表项：`role`、`split_raw`、`parts`、`explain`、`hint`。
- 24 小时、7 天是固定窗口 [now − 长度, now]。
- 第 3 节说的 `rules.json` 的 `categories`，落成了四张表：
  - `ui`、`sys`：单元键的通配，先查 ui 后查 sys；
  - `parents`：聚合用的父 cgroup，自身不成项；
  - `labels`：各部分的中文名。

### 6b.b 报表命令行

```
y700-battery-report [--json | --text | --fit] [--from DIR] [--now EPOCH] [--tz-offset MIN]
```

| 选项 | 作用 |
|---|---|
| `--json`（默认） | JSON v1 写到 stdout。打印前自己跑一遍 `contract.validate()`；不过就改出错误文档「报表自检没通过：<第一条>」，全部条目写 stderr，退出码 2 |
| `--text` | 给人和 agent 看的明细：三个范围的各段、各项的 J / mW / Wh、对账分支、标记。格式不算契约 |
| `--fit` | 用账本拟合系数，往 stdout 打印建议的 `coeffs-v<N+1>.json`，不写任何文件。只有它用 numpy，而且在函数里才 import；没有 numpy 时 stderr 写「--fit 要 numpy」，退出码 2 |
| `--from DIR` | 回放一份采集目录（见下表），不读任何实时文件，不起子进程 |
| `--now EPOCH` | 覆盖「现在」。默认实时取 `time.time()`；`--from` 时取 `now.txt`，没有就取采集里最新的墙钟时刻（账本、UPower、journal 里最大的那个） |
| `--tz-offset MIN` | 覆盖时区。默认用本机当前时区；`--from` 时取 `tz-offset.txt`，没有就用本机的。**测试一律显式传**，不依赖测试机的时区 |

- 退出码只有 0 和 2。用法错误、找不到系数或 rules、自检不过、任何没接住的异常，都在 stdout 写错误文档（「报表出错：<异常类型>: <消息>」），traceback 写 stderr。包本身导入不了（拷了一半、缺模块、换了 python 后的 SyntaxError）由入口脚本接住，同样写错误文档、退出码 2。读的一方提前关了管道（`--text | head`）不算报表出错：不写 traceback，不再写第二份文档，退出码照旧。
- 报表只读：不写缓存、不写账本、不发信号（USR1 由页面发）。
- 性能：平板上 40 天数据的目标耗时 < 1.5 s（第 11 节第 9 条）。
  - `report/tests/test_cli.py` 的上限取环境变量 `Y700_BATTERY_PERF_LIMIT`（秒，默认 1.0，对应开发 PC；install.sh 在平板上传 1.5）；40 天都没充满的最坏情形放宽到它的 6 倍。
  - 报表是短命进程：`cli.main` 运行期间关掉循环垃圾回收（解析出来的账本有几十万个对象，一直活到退出，分代回收反复扫它们却收不回东西），结束时对还活着的对象调 `gc.freeze()`，解释器退出时那次全量回收也就跳过它们；进程内调用（测试）时回收开关恢复原状。
  - 模型里的几处捷径（按开机二分查找 step、每个 step 只算一次前台重叠和叶子分类、每段只算一次分桶、短亮屏只看前后两个亮屏段）都必须保证输出逐字节不变，test_cli 的 Fragmented 用碎片化的 40 天采集逐项对照原始定义。
  - 实时模式下 journalctl、busctl 和 .desktop 扫描仍然串行执行：平板上整份实时报表实测 0.33–0.55 s，不值得并行（有意不做）。
- 子进程（busctl、journalctl）各有 5 s 超时；超时就当没有这份数据，不算出错。

**实时模式读什么**

| 数据 | 来源 |
|---|---|
| 账本 | `${XDG_STATE_HOME:-~/.local/state}/y700-battery/` 下的 `boots.txt`、`b-<boot8>[.<n>].jsonl`、`fg-<boot8>[.<n>].log` |
| UPower 历史 | 先跑 `busctl --system --json=short call org.freedesktop.UPower /org/freedesktop/UPower/devices/battery_<supply> org.freedesktop.UPower.Device GetHistory suu charge 3456000 0`，`rate` 同样跑一遍；**再合并** `/var/lib/upower/history-{charge,rate}-*.dat` 里属于这块电池的文件。原因：GetHistory 只给 upowerd 这次启动以来的点（10-30 的采集里，第一个点就是开机那一刻），而 timespan 填 0 又不是「全部」（11b） |
| journal | `journalctl --user -o json MESSAGE_ID=ae8f7b866b0347b9af31fe1c80b127c0 --since=@<now − 40 天>`，每行一个 JSON |
| 电池 | `/sys/class/power_supply/` 下 `scope` 读出来是 Device 的 supply 一律跳过：蓝牙/USB 外设自己的电池（如 `hid-<地址>-battery`、`ps-controller-battery-*`、`hidpp_battery_N`，名字都排在 `qcom-` 前面，连着时 `online` 一直是 1）；没有 `scope` 文件算 System。电池取 `qcom-battmgr-bat`（目录存在就用，和 batteryd 写死的一致，`recorder/src/main.rs` 的 `BAT`），没有它时取剩下的、按名字排序的第一个 `type` = Battery。读它的 `status`、`capacity`、`charge_full`、`charge_full_design`、`cycle_count`、`model_name`；`online` 只看剩下的、`type` 不是 Battery 的 supply。页面 C++ 用同一条规则（6b.c 数据流第 7 条）。**不读** `charge_counter`、`power_now` |
| 开机 | `/proc/sys/kernel/random/boot_id`；`time.clock_gettime(CLOCK_MONOTONIC)` |
| flightrec | `/run/y700-flightrec/energy`、`/run/y700-flightrec/edge` |
| batteryd | `$XDG_RUNTIME_DIR/y700-battery/pid`，加 `/proc/<pid>/comm` |
| .desktop | 和 dock `apps.cpp` 同一组目录、同样的先后（前面的目录赢），再加 `~/Desktop` |

**`--from DIR` 的目录结构**（`bp-capture.sh` 的输出就是这个样子；可选的文件缺了，就当没有这份数据）

| 路径 | 内容 | 是否必须 |
|---|---|---|
| `state/` | 账本目录的拷贝 | 必须（可以是空目录） |
| `sys/battery.txt` | `key=value` 行：status、capacity、charge_full、charge_full_design、cycle_count、model_name（可缺），外加 `/sys/class/power_supply/<supply>/online=N` 行；可选的同形 `<supply>/type=…`、`<supply>/scope=…` 行：type 是 Battery 或 scope 是 Device 的 supply 的 online 不算（和实时一样），没有这两种行就每条 online 都算 | 必须 |
| `sys/energy`、`sys/edge` | `/run/y700-flightrec/` 下这两个文件的拷贝 | 可选 |
| `upower-charge.json`、`upower-rate.json` | 上面那条 busctl 的原样输出 | 可选 |
| `upower-dat/` | `/var/lib/upower/history-*.dat` 里属于电池的那几份 | 可选 |
| `journal-consumed.jsonl` | journalctl 输出的 JSON 行 | 可选 |
| `desktop-files.txt` | 每个文件一段：先一行 `== <路径>`，接着是文件原文 | 可选 |
| `boot_id.txt` | 当前开机的 id | 可选；缺了取 `state/boots.txt` 的最后一个 |
| `mono.txt` | 采集时的 CLOCK_MONOTONIC 秒 | 可选；缺了就以当前开机的最后一行账本为锚 |
| `now.txt`、`tz-offset.txt`、`rec-running.txt`（内容 `1` 或 `0`） | 见上文 | 可选；`rec-running.txt` 缺了，就看账本最新一行是否在 now 之前 2400 s 以内 |

- 其余文件一律不读。
- `upower-files.txt`、`upower-props.json` 只给人看。`upower-files.txt` 里有蓝牙设备名和地址，**不进仓库**。

**系数和规则从哪来**（按顺序，先找到的用。文件坏了就跳到下一个，并在 stderr 说一声；都没有就出错误文档「找不到系数文件」或「找不到 rules.json」。系数文件里当除数的 `fmax_little`、`fmax_big`、`g_fref_mhz`、`R0`、`ctx_per_wake` 和 `V_nom` 不大于 0 也算坏文件（10-31 审计修订）。）
1. 系数：
   1. `~/.config/y700-battery/coeffs-v<N>.json` 里 N 最大的（`source` = `user`）。标定产物经人工确认后放这里。`--from` 时不看这一处，好让回放结果只取决于采集和包。
   2. `/usr/local/share/y700-battery/coeffs-v<N>.json` 里 N 最大的（`package`）。
   3. 开发目录的 `linux/power/battery/coeffs-v<N>.json`（`dev`），从包所在位置往上两级找。
2. 规则：`/usr/local/share/y700-battery/rules.json` → 开发目录的 `linux/power/battery/rules.json`。

**安装布局**

| 路径 | 内容 |
|---|---|
| `/usr/local/bin/y700-battery-report` | 入口脚本（`#!/usr/bin/python3 -I`）。先找自己旁边的 `y700_battery/`（开发目录里就是 `report/`），再找 `/usr/local/lib/y700-battery/`，插到 `sys.path` 最前面，然后调 `cli.main()` |
| `/usr/local/lib/y700-battery/y700_battery/` | 包 |
| `/usr/local/share/y700-battery/{coeffs-v1.json, rules.json}` | 数据 |
| `/usr/local/libexec/y700-battery-page` | 页面程序 |
| `/usr/local/bin/y700-battery` | 启动器（第 7 节） |

### 6b.c 页面：C++ 与 QML 的接口

**构建**（`page/CMakeLists.txt`）
- `find_package(Qt6 6.5 REQUIRED COMPONENTS Core Gui Qml Quick)`，`qt_standard_project_setup(REQUIRES 6.5)`。
- `qt_add_executable(y700-battery-page src/main.cpp src/report.cpp src/report.h)`。
- `qt_add_qml_module(y700-battery-page URI Y700.BatteryPage VERSION 1.0 QML_FILES qml/Main.qml qml/Segmented.qml qml/Summary.qml qml/Chart.qml qml/Composition.qml qml/UsageList.qml qml/UsageRow.qml qml/Detail.qml qml/Fmt.js)`。
- 链接 `Qt6::Core Qt6::Gui Qt6::Qml Qt6::Quick`。`org.kde.kirigami`（图标）和 `QtQuick.Shapes`（曲线）只在 QML 里 import，运行时要装着。
- 这和 dock、shellbar 的写法不同，它们是 `engine.load()` 磁盘上的 QML 目录。页面是一次性启动的程序：QML 编进二进制，装一个文件就完整，不会出现新二进制配旧 QML 的情况。

**main.cpp**
- `QGuiApplication`；`setApplicationName("y700-battery")`，`setDesktopFileName("y700-battery")`。后者决定 Wayland 的 app_id，`battcap.sh` 和 KWin 规则认的就是它。
- 命令行参数，只给测试台用：
  - `--range since_full|24h|7d`：启动时先选哪个范围；
  - `--detail <item id>`：启动时直接打开这一项的详情，找不到就留在列表。
- `engine.rootContext()->setContextProperty("backend", &backend)` 必须**在** `engine.loadFromModule("Y700.BatteryPage", "Main")` 之前。
- 根对象是 QtQuick 的 `Window`（`visible: false`、`title: "电池"`、`color: "#121212"`），加载完由 C++ 调 `showMaximized()`。加载失败时退出码 1。

**上下文对象 `backend`**（`report.h` 里的 `class Backend : public QObject`）

| 属性 | 类型 | 通知 | 含义 |
|---|---|---|---|
| `data` | QVariantMap | `dataChanged` | 最近一次成功的报表；还没有就是缓存；都没有就是空 map |
| `loading` | bool | `loadingChanged` | 报表进程在跑 |
| `skeleton` | bool | `skeletonChanged` | `loading` 已超过 150 ms，而且 `data` 为空：出静态骨架 |
| `error` | QString | `errorChanged` | 空表示没出错；否则是报表的 `error` 文本，或「报表超时」「报表没跑起来」「报表的输出读不懂」 |
| `cacheAgeMin` | int | `errorChanged` | `data` 那份报表（缓存或新跑的）按它自己的 `now` 有多少分钟了，读的时候算；没有 `data` 为 −1。只在出错时显示，所以跟着 `errorChanged` 走：每次失败都发，同一句错误再来一次也发（10-31 审计修订） |
| `stale` | bool | `errorChanged` | 有 `data`，而且最近一次刷新出错（10-31 审计修订：不再要求来自缓存）：整块调暗，横幅位置写「x 分钟前的数据」，第 1 行不写剩余时间 |
| `livePct` | int | `liveChanged` | 实时电量，读不到为 −1 |
| `liveStatus` | QString | `liveChanged` | 取值和 `battery.status` 一样 |
| `livePlugged` | bool | `liveChanged` | 判断方法和 `battery.plugged` 一样 |
| `fixture` | bool | CONSTANT | 设了 `Y700_BATTERY_REPORT` |
| `startRange` | QString | CONSTANT | `--range` 的值，没给为空 |
| `startDetail` | QString | CONSTANT | `--detail` 的值，没给为空 |

| 方法 | 作用 |
|---|---|
| `Q_INVOKABLE void refresh()` | 立刻走一遍「发 USR1 → 等账本 → 跑报表」（罐装模式只重读文件）；正在跑就什么都不做，只有第 7 条在这期间发现充电器插拔时记下来，跑完再跑一次 |
| `Q_INVOKABLE void openKde()` | `QProcess::startDetached("/usr/local/bin/y700-battery", {"--kde"})` |
| `Q_INVOKABLE void quit()` | 关窗退出 |

**数据流**
1. **启动**：读实时电量 → 读缓存 → `refresh()`。
2. **缓存**：
   - 位置：`${XDG_CACHE_HOME:-~/.cache}/y700-battery/last.json`；内容是报表成功时 stdout 的原样字节，用 `QSaveFile` 写。
   - 读的时候按文件里的 `now` 算年龄，只有 0 ≤ 年龄 ≤ 600 s 才显示。
   - 报表一回来就整块替换，不做合并。
3. **USR1**：
   1. 读 `$XDG_RUNTIME_DIR/y700-battery/pid`，核对 `/proc/<pid>/comm` 是 `y700-batteryd`。
   2. 记下本次开机账本最新分段的大小。账本在 `${XDG_STATE_HOME:-~/.local/state}/y700-battery/`，分段是 `b-<boot8>[.<n>].jsonl` 里 n 最大的；boot8 是 `boot_id` 去掉横线后的前 8 位。
   3. `kill(pid, SIGUSR1)`。
   4. 用 `QFileSystemWatcher` 等这个文件变长或出现新分段，最多等 1 s（`QTimer::singleShot`），然后跑报表。
   - pid 文件不在、comm 不对、文件读不到：跳过信号，直接跑报表。
   - batteryd 10 s 内只理一次 USR1，所以 10 s 内重开页面会等满 1 s，可以接受。
4. **报表**：
   - `QProcess` 跑 `/usr/local/bin/y700-battery-report --json`，环境照传。
   - 子进程在 fork 之后、exec 之前设 `prctl(PR_SET_PDEATHSIG, SIGKILL)`（`QProcess::setChildProcessModifier`），再核对 `getppid()` 还是页面，不是就 `_exit(1)`。启动器用 SIGTERM 关页面时不走析构；不设的话，报表会在页面的 scope 里白跑完，最后写 stdout 碰上 EPIPE。报表自己起的 busctl、journalctl 不跟着死，各有 5 s 超时兜着。
   - 20 s 超时就 kill，`error` 设为「报表超时」。
   - 退出码 0、输出是 JSON 对象、而且没有 `error` 键：放进 `data`，写缓存，清掉 `error`。
   - 有 `error` 键：`error` 取它的文本。
   - 别的情况：`error` 用上表里那几句。
5. **罐装模式**（`Y700_BATTERY_REPORT=<json 文件>`）：
   - 读这个文件当作报表输出；不发 USR1，不起进程，不读也不写缓存。
   - 实时三项取 `data.battery`：`livePct` = `pct`，`liveStatus` = `status`，`livePlugged` = `plugged`。
   - 文件读不了或不是 JSON：`error` 设为「读不了 <文件>」。
6. **`Y700_BATTERY_NOSCOPE`**：只有启动器 `y700-battery` 读它（第 7 节第 3 步），页面不管。
7. **实时电量**：挑电池的规则和报表一字不差（6b.b「实时模式读什么」的电池行）：`scope` 读出 Device 的 supply 一律不看（蓝牙手柄、鼠标的电池名字排在 `qcom-battmgr-bat` 前面，连着时 `online` 一直是 1），没有 `scope` 文件算 System；剩下的里面有 `qcom-battmgr-bat` 就用它，否则按名字取第一个 `type` = Battery 的，读它的 `capacity`、`status`；`livePlugged` 只看剩下那些 `type` 不是 Battery 的 supply 的 `online`，或 status 是 charging / full / not_charging。启动时读一次，以后在窗口激活和 flightrec 换 edge 时按第 8 条再读。读到的插电状态和上一次不同、而且 `data` 不为空时，`refresh()`；正在跑就记下来，跑完再跑一次。
8. **重新激活与 flightrec edge**：
   - 窗口 `activeChanged` 变真：距上次读 sysfs 超过 5 s 就重读实时电量；距上次**开始**跑报表超过 120 s 就 `refresh()`。
   - 窗口一直激活着时不会再有激活（KWin 熄屏、亮屏都不动激活状态，熄屏也不锁屏），所以窗口在的整个期间用 `QFileSystemWatcher` 看 `/run/y700-flightrec/` 目录（inotify）。flightrec 每次 dpms 或供电方向（pw）变化都用 tmp+rename 换掉 `edge`（`flightrec/src/acc.rs` 的 `write_edge`）；`energy` 是原地重写，目录监视看不到。
   - 目录一变就重读 `edge` 那一行（`v1 t=… dpms=On|Off pw=dis|chg|unk`）。和上次读到的一字不差就什么都不做：一次 edge 会来两次变化（建 `edge.tmp`、再改名），目录里还有别的文件。窗口没激活，或这一行写着 `dpms=Off`，只记下这一行：熄屏时没人看，亮屏那条 edge 会补上。
   - 否则按激活的两条规则走，另外：`dpms` 从别的值变成 `On` 就立刻 `refresh()`；`pw` 变了就不管 5 s 都重读实时电量，真插拔由第 7 条去 `refresh()`。`pw` 变化本身不触发报表：弱充电器在负载下方向也会翻，报表自己跑起来就是这种负载，会自己喂自己。
   - 没有 `/run/y700-flightrec/` 目录，或者罐装模式：不监视，只靠激活，和以前一样。
9. **没有周期定时器，也没有循环动画**。只有三个一次性的 `singleShot`：150 ms 出骨架、1 s 等账本、20 s 报表超时；外加第 8 条那个一直挂着的目录监视，它只在那个目录里有文件新建或改名时醒（flightrec 换 edge），不轮询。

**按键**：Esc、`Qt.Key_Back`、Alt+Left 三个键，详情开着时关详情，否则 `backend.quit()`。

**QML 文件**：都在模块 `Y700.BatteryPage` 里，彼此直接用类型名引用；`Fmt.js` 用 `import "Fmt.js" as Fmt` 引入。

| 文件 | 接口 | 职责 |
|---|---|---|
| `Main.qml` | 根 `Window`；`property string rangeKey`（初值取 `backend.startRange`，空就是 `"since_full"`）、`property string detailId` | 按 `width > height` 切横竖布局；把 `backend.data.ranges[rangeKey]` 传给各块；处理按键 |
| `Segmented.qml` | `property var model`（`[{key, label}]`）、`property string current`、`signal picked(string key)` | 分段控件，指示块滑动 180 ms |
| `Summary.qml` | `property var doc`、`property var range`、`property int livePct`、`property string liveStatus`、`property bool livePlugged` | 大数字和三行字；`stale` 时调暗 |
| `Chart.qml` | `property var range`、`property int tz`、`property var detailBuckets`（null 或某一项的 `buckets`）、`property bool showUncovered` | 曲线、各种带、亮屏条、刻度、图例、按住读数 |
| `Composition.qml` | `property var range` | 标题、堆叠条、行内图例 |
| `UsageList.qml` | `property var range`、`signal open(string id)`、`signal showRange(string key)` | 标题、`data_from_text`、列表；不分项时显示 `range.empty`，`show_24h` 时发 `showRange("24h")` |
| `UsageRow.qml` | `property var item`、`property var range`、`property real maxPct`、`signal clicked()` | 一行 76 高；份额条长 = `pct_raw / maxPct × 468` |
| `Detail.qml` | `property var item`、`property var range`、`signal back()` | 详情；事实表只列不为 null 的行 |
| `Fmt.js` | `.pragma library` | 见下 |

`Fmt.js` 的内容：
- 色板：上面的 role 表，加第 6 节的底色和文字色；`roleColor(role)`。
- 格式化函数：`dur(s)`、`pct(p, raw)`、`clock(t, tz)`、`dayClock(t, tz)`、`rel(t, now, tz)`、`mmdd(t, tz)`、`tick(t, span, tz)`、`minutes(s)`、`count(n)`、`remain(h)`。
- 时刻一律用 `new Date((t + tz × 60) × 1000)` 的 `getUTC*()` 方法，不用本地时区的方法。

**切换范围时的详情**：开着的详情如果在新范围里有同 id 的行，就换成新范围的数据继续开着；没有就回到列表。

### 6b.d 报表内部接口

**总则**
- 包是 `report/y700_battery/`，纯标准库（Python 3.12+）；numpy 只在 `fit.py` 的函数里 import。
- **只有 `sources.py` 和 `config.py` 碰文件系统和子进程**。其他模块只吃字符串和 `types.py` 的对象，所以单元测试和 `--from` 回放走的是同一条路。
- 三个 agent 分工：输入、核心、输出，各管下表里的模块。

| 模块 | 归属 | 公开接口 |
|---|---|---|
| `types.py`、`contract.py` | 主线程（冻结） | 数据类型；`validate(doc) -> list[str]`、`is_error(doc) -> bool` |
| `sources.py` | 输入 | `open_sources(from_dir: Optional[str], now: Optional[float], tz_offset_min: Optional[int]) -> Sources`（实时或 `--from`，见 6b.b） |
| `config.py` | 输入 | `load_coeffs(from_mode: bool) -> Coeffs`、`load_rules() -> Rules`、`parse_coeffs(text, source, path) -> Coeffs`、`parse_rules(text) -> Rules` |
| `ledger.py` | 输入 | `read_dir(path) -> Ledger`；`read_fg(text) -> list[FgEvent]`；`assign_clocks(led, cur_boot8, now, mono_now) -> float`（填 `Boot.clock` 和 `Boot.offset`，返回报表的「现在」：钟落后时挪过的那个）；`steps(boot) -> list[Step]`；`lives(boot) -> dict[UKey, UnitLife]`；`cgroup_key(path) -> str`（把 cgroup 路径换成账本的键）；`newest_wall(led) -> Optional[float]` |
| `upower.py` | 输入 | `parse_gethistory(text) -> list[UpPoint]`、`parse_dat(text) -> list[UpPoint]`、`battery_dat_names(names, model) -> list[str]`（排除蓝牙设备的文件）、`clean(points, led) -> tuple[list[UpPoint], int]`、`load(src, led) -> History` |
| `journal.py` | 输入 | `parse(lines) -> list[Consumed]`、`attach(consumed, led, lives) -> list[ExitFix]` |
| `apps.py` | 输入 | `parse_desktop(path, text) -> Optional[DesktopEntry]`、`parse_capture(text) -> list[DesktopEntry]`、`scan(dirs) -> list[DesktopEntry]`、`unescape_unit(name) -> str`、`unit_app_id(unit) -> Optional[str]`；`class AppIndex(entries, rules)`，方法有 `get(id)`、`by_class(cls)`、`steam_game(appid)`、`resolve(key, alive, fg_classes) -> Resolved`、`window_name(cls, title)`、`is_desktop_class(cls)`、`is_x11(cls)` |
| `acc_ref.py` | 已有 | flightrec acc 的参考实现，给测试用，不动 |
| `ranges.py` | 核心 | `plug_timeline(inp) -> list[PlugSession]`（同时写 `inp.sessions`）、`bucket_grid(key, start, end, tz_offset_min) -> tuple[int, list[int]]`、`build(inp) -> dict[str, Range]`（三个范围的起止、状态、切段、原始曲线和带） |
| `model.py` | 核心 | `attribute(rng, inp) -> RangeResult`（第 4 节的模型和对账，能量单位 J）、`remain(inp) -> Optional[Remain]`、`diag(inp, results) -> Diag` |
| `out.py` | 输出 | `to_json(rep: Report) -> dict`、`to_text(rep) -> str`、`largest_remainder(raws, total) -> list[int]`、`decimate(curve, n_max=400)`，以及和 Fmt.js 同规则的 `dur`、`clock`、`day_clock`、`rel`、`mmdd` |
| `fit.py` | 输出 | `fit(inp) -> dict`、`format_fit(res) -> str` |
| `cli.py` | 输出 | `main(argv: Optional[list[str]] = None) -> int`、`rec_state(inp) -> RecState`、`health_pct(bat) -> Optional[int]` |

**流水线**（`cli.main` 的骨架）

```
src    = sources.open_sources(args.from_dir, args.now, args.tz_offset)
coeffs = config.load_coeffs(from_mode=src.from_dir is not None); rules = config.load_rules()
led    = ledger.read_dir(src.state_dir); src.now = ledger.assign_clocks(led, cur_boot8, src.now, src.mono_now)
steps  = {b.boot8: ledger.steps(b) for b in led.boots}; lives = {b.boot8: ledger.lives(b) for b in led.boots}
hist   = upower.load(src, led)
fixes  = journal.attach(journal.parse(src.journal_lines), led, lives)
inp    = Inputs(src, coeffs, rules, led, hist, steps, lives, fixes, apps.AppIndex(src.desktop, rules))
rngs   = ranges.build(inp)
res    = {k: model.attribute(r, inp) for k, r in rngs.items()}
rep    = Report(..., ranges=res, remain=model.remain(inp), diag=model.diag(inp, res))
doc    = out.to_json(rep); errs = contract.validate(doc)   # 不过：出错误文档，退出码 2
```

**模块分界上的约定**
- 能量换成百分点只在 `out.py` 里做：
  - `model.py` 给出每一项的 J：`ItemEnergy.e_j`、`buckets_j`、`fg_j`/`bg_j`/`off_j`、`parts`；
  - `out.py` 按 `used_pct_raw / Σ e_j` 这一个比例换成百分点，所以各项加起来正好是 D；
  - `coverage` = 1 − unrecorded / Σ e_j。
- 以下都在 `out.py` 里做：`apps_rest` 的合并、最大余数法、曲线抽稀、所有中文句子（`title`、`sub`、横幅、`empty`、`footnote`、`explain`、`hint`）。
- 名字的来源：组成项的名字、图标、说明是 `out.py` 的常量表；应用的名字和图标来自 `apps.py`；部分名来自 `rules.json` 的 `labels`。
- 状态（`Range.state`）由 `ranges.py` 判；`partial` 的 `unrecorded` 项由 `model.py` 给出。
- 时刻：`types.py` 里的 `m` 是 mono 秒，`t` 是校正后的墙钟秒。`ledger.assign_clocks` 跑过之后才能用 `Boot.t(m)`。
- 测试：
  - 每个模块一个 `tests/test_<module>.py`，夹具放 `tests/fixtures/`；
  - 从采集复制进来的数据要去掉蓝牙地址和设备名；
  - 不依赖测试机的时区和语言环境，也不需要 Linux。

## 7. File list

**新增**
- `linux/power/flightrec/src/acc.rs`
- `linux/power/battery/recorder/`：`{Cargo.toml, Cargo.lock, .cargo/config.toml, src/{main.rs, snap.rs, units.rs, gpu.rs, threads.rs, clock.rs, ledger.rs, fds.rs}, y700-batteryd.service}`
- `linux/power/battery/report/`：`y700-battery-report`、`y700_battery/{ledger.py, acc_ref.py, upower.py, journal.py, apps.py, ranges.py, model.py, out.py, fit.py}`、`tests/{test_*.py, fixtures/}`
- `linux/power/battery/`：`{coeffs-v1.json, rules.json, install.sh（带 --rollback）, README.md}`、`calib/y700-battery-calib.sh`
- `linux/power/battery/page/`：`{CMakeLists.txt, src/{main.cpp, report.cpp, report.h}, qml/{Main, Segmented, Summary, Chart, Composition, UsageList, UsageRow, Detail}.qml, qml/Fmt.js}`
- `linux/dock/tests/{batpage.sh, batpage-run.sh, bp-look.py}`
- 第 6b 节的契约件：`report/y700_battery/{types.py, contract.py}`（冻结，改动经主线程）、`report/tests/test_contract.py`、罐装报表 `linux/dock/tests/batpage/{ok, just_full, empty, first_run, partial, all_charger, degraded}.json` 及其生成器 `gen_batpage.py`；报表另有 `y700_battery/{sources.py, config.py, cli.py}`（见 6b.d）

**修改**
- flightrec：
  - `src/main.rs`：`mod acc`；亮屏时读背光；Sample 加 bat 读成功标志；电流为 0 时读 `status`。
  - `src/run.rs`：第 418 行之后调用 acc；启动时写 `edge`。
  - `deploy.sh`：装完后的那组核对（`:69-75`）加上 energy 和 edge，缺了就回滚。评审修订：`test-deploy.sh` 用的是假记录器，在那里检查没有意义。
- `linux/display/refresh-auto/y700-refresh-auto`：加 `log_fg`。
- `linux/power/battery/y700-battery`，改为：
  1. 关掉同一 `WAYLAND_DISPLAY` 上已经开着的页面，和现在一样；
  2. `--kde`，或页面程序不在 → `exec kcmshell6 kcm_mobile_power`；
  3. 存在 `$XDG_RUNTIME_DIR/systemd/private`，而且没设 `Y700_BATTERY_NOSCOPE` → `exec systemd-run --user --scope --quiet --collect --slice=app.slice --unit=app-y700-y700-battery-$$-1 -- /usr/local/libexec/y700-battery-page`。原因：控制中心的 `launch()` 是 `startDetached /bin/sh`（`backend.cpp:628-635`），不套的话，页面的 CPU 会记到控制中心头上；
  4. 否则直接 exec 页面。
- `y700-battery.desktop`：Comment 改成「电量曲线、谁用了电」。`install-entry.sh`：保留原来的 KWin 规则，给 `--kde` 用。
- `linux/dock/tests/sb-bed.sh`：
  - 加 `SB_SIZE=WxH`（现在写死 `--width 1600 --height 1002`，第 65 行）。
  - 评审修订：把 `Y700_BATTERY_REPORT`、`XDG_CACHE_HOME`、`XDG_STATE_HOME`（指到 `$T`）加进 `env -i` 的白名单（`:126-131`）。否则经控制中心胶囊打开的页面（p8）会跑真报表，还会把测试数据写进作者真实的缓存。
- `battcap.sh`：c4–c6 改成等 class `y700-battery`。
- `tools/y700-checklist.py`，新增体检项：
  - batteryd 在跑，`NRestarts` 没在增长（评审修订）；
  - 账本 40 min 内有写入；
  - flightrec 在跑时 energy 文件 ≤60 s 新；
  - 账本总量 ≤20 MiB（ledger.rs 修剪到 16 MiB，但约一天才修剪一次，中间允许多出一天的量，总在一份 4 MiB 分段以内）；
  - 7 天里「没算清」的中位数 >20 %，或学出来的熄屏功率和模型对同样这些段算出的功率差 >25 %，报「电池页系数要重标」：系数已标定（`coeffs.calibrated` 为 true）时报 WARN，还是没标定的先验值时只报 INFO；
  - 系数超过 90 天也报。
  - 以 user 跑一次 `timeout 30 y700-battery-report --json`：30 s 内没出结果（退出码 124，或体检自己的 40 s 后备超时）报 INFO；没有输出就退出（退出码 1：Python 没走到入口脚本的兜底就崩了；126/127：起不来）报 WARN，带退出码和 stderr 最后一行；输出不是 JSON、出错文档、没有 diag 块也报 WARN。
- `linux/power/BATTERY-PAGE.md`、根 `README.md`。

## 8. Tests

**Rust，在平板上 `cargo test --offline`**
- acc：
  - 正负号拆分、亮灭屏拆分；
  - 零读数（评审修订）：读失败或放电中的 0 算缺测，下一个读数为正就补积、为负就移进 `tzero`；插着电时的 0 算 `tzero`；缺测超过 30 min 记成 gap；
  - 共用夹具里要有 690a169c 的 t=66030–66600、66620–66840、66870 起和 974b286c 的 t=21327.7 起这四段；
  - dt > 60 s 计入 gap；
  - 同一次开机续数、换开机清零；
  - 定宽格式往返一致；
  - `pw` 去抖；edge 只在变化时写；
  - 和 Python `acc_ref.py` 共用夹具（真实 live.log 摘录 + 期望计数器）。
- batteryd：
  - cgroup 路径 → key，嵌套子 cgroup 归到上层的 .scope/.service；
  - inode 变了换新 id，ENODEV 时关 fd；
  - `cpu.stat`、`time_in_state` 解析；
  - fdinfo 按 client-id 去重，核对 fd 号是否被复用；
  - 逐线程差值：退出的线程、新线程；
  - `chronyc -c` 的 CSV 解析，退回 adjtimex 的分支；
  - `boots.txt` 修剪（1970 的 mtime、16 MiB、40 天），4 MiB 分段；
  - inotify 文件名过滤；
  - 降级判定；
  - 评审修订新增：
    - 目录后来才出现、目录被删后重建；
    - edge 状态没变时不拍快照，60 s 内的重复边沿也不拍；
    - 末行没写完时先补 `\n`；
    - 拿不到 flock 就退出；
    - 写盘遇到 ENOSPC 时进程不退出。
- 自检命令：`--once` 打印一行快照；`--bench N` 分别报轻量快照、逐线程扫描的单次 ms。

**Python，在 Win11 上 `python -X utf8 -m unittest discover -s linux/power/battery/report/tests`**
- 四种单元命名、`\x2d`、dock 的 `_`、别名、.desktop 匹配。
- 第 5 节的 8 种情形，外加松线 <2 min 合并。
- 充电器功率不够的段照样计入。
- 三种对账分支；熄屏唤醒饱和模型；Wi‑Fi 封顶。
- 范围边界按比例切分。
- 每次开机的时钟偏移；整次未同步的开机被排除。
- 写了一半的末行、batteryd 重启、flightrec 计数器回零、缺 acc 时粗估。
- journal 补差。
- 前台 / 后台的时长和 CPU。
- 最大余数法相加等于 D。
- 输出 JSON 和 golden 文件逐项对照；40 天合成账本在 `Y700_BATTERY_PERF_LIMIT` 秒内跑完（默认 1 s，平板 1.5 s）。另有两份最坏情况，耗时上限放宽到 6 倍：一份是 40 天没充满；另一份在 40 天没充满之外再加前台日志和每天约 30 次短亮屏（days_capture fg=True，碎片化），它还把性能捷径与原始定义逐项对照，并统计 `spread` 和 `fg_overlap` 的调用次数。
- 用 `runs/diag/flightrec/*.log.gz` 的 1 s 数据：实测「10 s 积分」对「1 s 积分」在 5 min 窗口上的 p90 误差，核对零读数数量 178 / 232。

**测试台** `batpage.sh`：经 `batpage-run.sh` 以 root 跑；`SB_SIZE` 取 1600x1002 和 1002x1600 各一遍；用 `Y700_BATTERY_REPORT` 喂罐装 JSON。

| 截图 | 内容 |
|---|---|
| p0 | 自上次充满 |
| p1 / p2 | 点 24 小时、7 天 |
| p3 / p4 | 点第一行进详情 / 按返回键回来 |
| p5 | 空数据 |
| p6 | 刚充满 |
| p7 | 部分覆盖 + 缺口 |
| p8 | 从控制中心胶囊打开，只出一个页面 |
| p9 | 竖屏 |

`bp-look.py`（numpy）检查：
- x > 1544 处没有文字像素；
- 分段控件右缘 = 列表右缘 = 1544；
- 行高 76；
- 窗口是最大化的（1600×974）。

最后跑一遍 `battcap.sh` 回归。截图不能代替真机，最后要作者看真机。

**常驻开销实测**
- 熄屏、用电池、期间不 ssh，经 `systemd-run` 跑 `tools/y700-service-cost.sh 1800`。
- 期望 batteryd 的 CPU 显示为 0.000–0.002 %，wake/s 显示为 0.00，flightrec 的 CPU 变化在噪声以内。
- 评审修订：这个工具 CPU 打印到 `%7.3f`、wake/s 打印到 `%8.2f`，门槛只能按输出精度写；要看更细，就直接用 cgroup 的 `cpu.stat` 前后差值。
- `tools/y700-wakeups.py --off` 熄屏 30 min：batteryd 除检查点外没有 `hrtimer_wakeup`。
- 核对 `/proc/<pid>/timerslack_ns` = 10000000000。

## 9. Rollout steps

1. 做第 11 节的只读预检。
2. **flightrec**：在平板上编译 + `cargo test`，跑 `test-deploy.sh`，再用 `deploy.sh`（自带「实验进行中不换」和回滚）。确认 energy 每 10 s 更新、edge 跟着亮灭屏出现、live.log 的行格式不变，然后 commit。
3. **batteryd**：`install.sh` 装到 `/usr/local/libexec/`，`systemctl --user enable --now y700-batteryd`；跑一次 `--once`；看账本里有 H、U、S 行。
4. **refresh-auto**：建好 `~/.local/state/y700-battery/`，重装、重启服务；切几次窗口，看 fg 日志有没有新行。
5. **先只记录、不换入口，至少一天**，作者第一次打开就有数据。期间当晚做开销实测。
6. 用 `install.sh --page` 装报表和页面：从保持仓库 linux/ 以下布局的暂存副本跑，至少带 `linux/power/battery`、`linux/power/flightrec/fixtures`（报表的 acc 测试读那里的 cases.txt）、`linux/dock/tests/batpage`。它先跑报表的单元测试，40 天耗时那条按平板目标判（`Y700_BATTERY_PERF_LIMIT=1.5`）；装完以 user 跑一次真报表，打印报表自己的 took_ms、墙钟耗时和账本大小，记进第 11 节第 9 条。`y700-battery-report --text` 能出结果；在 Win11 和平板上各跑一遍测试和测试台。
7. 运行 `install-entry.sh` 切换启动器。请作者在真机上点控制中心胶囊和桌面图标验收。然后 commit，补 README 和体检项。
8. 作者同意的夜里跑标定（约 60 min，熄屏、用电池、不 ssh），出 `coeffs-v2.json` 后人工确认再 commit：
   - A 阶段，亮屏：背光 4 档各 90 s；以 root 读 KWin 的 fdinfo 求 r_kwin。
   - B 阶段，熄屏：B1 冻结应用；B2/B3 唤醒器 400/s、1600/s；B4/B5 锁频跑负载；B6 GPU（有负载工具才做）；B7 ping 50/500 pps；B8 再测一次基线。
   - 唤醒项要重定 R0（10-31 记）：v1 的 R0=130 次/s 在熄屏实测约 890 次/s 时已饱和，各程序分到的 W 只是按 wk 比例分摊，不是关掉它能省的电。10-29/10-31 实测 Steam 带来约 +460 次/s、+62～84 mW，套 W 公式要 R0≈600 次/s、A≈224～304 mW；B2/B3 是叠在这个底上测的。
   - 每步 3–4 min，前 15 s 丢掉，用 `y700-flightrec --mark` 切到 1 s 档。
   - trap 负责把频率、背光、冻结、DPMS 全部还原。

**回滚**：`install.sh --rollback`。
- 从 `.bak-<stamp>` 还原启动器，入口回到 KDE 页；
- `systemctl --user disable --now y700-batteryd`；
- 删掉 `~/.local/state/y700-battery`，前台日志随之停写；
- flightrec 新加的部分没人读就不起作用。要撤（评审修订）：`deploy.sh` 要的是一个目录，里面必须是固定名字的 `y700-flightrec` 和 `y700-flightrec.service`（`deploy.sh:39`、`:46-48`）。所以先把备份复制成这两个名字放进一个目录，再对这个目录跑 `deploy.sh`。

## 10. 有意不做

- **Rust 里的 D-Bus 服务端、新的 KWin 脚本**：refresh-auto 本来就醒着，让它写前台日志，省掉手写协议。代价是停掉 refresh-auto 就没有前台统计，页面会注明。
- **不解析 live.log**：截短后只能留 4.7 h（1 s 档约 28 min），而且每行都会叫醒我们。
- **batteryd 不自己读电流**：60 s 采一个点的误差 p90 达 68 %。
- **不在每次快照读电量和充电状态**：每读一次就是一次固件往返。
- **不订阅 UPower 的信号**：熄屏时会把我们叫醒。
- **不跟随充电上限调「充满」门槛**：旁路会把上限压成当前电量。
- **按应用分 Wi‑Fi、eBPF 按簇频点记 CPU、刷新率驻留、扬声器**：都属于第 3 档，差额落在「没算清」里。
- **系数不自动校准**：`--fit` 和学出来的底噪只给建议、只做体检。
- **不做**：耗电异常通知、状态栏图标、常驻浮层、页面上的冻结之类控制、导出、40 天以上的历史。
- **主视图不出现 Wh、mW**：页面面向不看这些单位的普通用户，给 agent 看的数字走 `--text`。
- **不加新的 root 常驻进程，不改权限**：KWin 的 GPU 用一次性 root 测出的常数。
- **数据源**：不读 debugfs、`energy_model`、`qcom_stats`、`charge_counter`（已核实不是库仑计）、`power_now`；不解析 flightrec 行里的 `qs=`、`pd=`；`power_profile.xml` 不进仓库。
- **同一单元内不按进程拆电量**：Steam 只按窗口 class 列前台时长。
- **控制中心 `launch()` 的 scope 问题**：本页靠启动器自己套 scope 绕开；其它从控制中心启动的程序（spectacle 等）还会记在控制中心头上，以后另开任务修。

## 11. Risks / unknowns（上平板核）

1. `/run/y700-flightrec` 是否 0755，user 能不能对它用 inotify；tmpfs 上 rename 是否正常投递 `IN_MOVED_TO`。
2. user 读不读得到 root 进程和 KWin 的 `/proc/*/task/*/status`；线程数和扫描耗时（评审修订：超过 150 ms 就只扫三个用户 slice，加 system.slice 里 CPU 前 10 的服务）。读 120 个 `cpu.stat` 的实际耗时（每次读都会触发 rstat flush）。
2b. 评审修订新增：UPower 的 `GetHistory` 参数，timespan 和 resolution 取什么值能拿到全部点；电池对象的路径；user 调 system bus 行不行。systemd 版本是否 ≥254（决定能不能用 `RestartSteps`）。
3. 用户 journal 里的 Consumed 消息带不带 `CPU_USAGE_NSEC`、`USER_UNIT`：`journalctl --user -o json MESSAGE_ID=… -n1`。
4. user 跑 `chronyc -n -c tracking` 行不行；`makestep` 第一次对时是否真的步进时钟、让 timerfd 被取消；fake-hwclock 是否在 batteryd 启动前就载入了。
5. `TimerSlackNSec` 是否真把检查点合并到了别人的唤醒里（slack 只和同一颗 CPU 上的到期合并），用 `y700-wakeups` 看。最坏 2 次/h。
6. Xwayland 在哪个 cgroup；Steam/FEX 窗口上报的 pid 是否非 0；flatpak 窗口上报的是不是宿主 pid；`x11_classes` 名单够不够。
7. 旁路、停在上限、充电器功率不够时，UPower 记成什么 state；插着电时 `-0mW` 和小正读数怎么分布。
8. 背光的 `brightness` 读起来是否只是缓存值（不走 I2C）。
9. 账本一天实际多大（目标 ≤200 KB）；报表在平板上 40 天数据跑多久（目标 <1.5 s；`install.sh --page` 的输出里有一次实跑的墙钟耗时和当时的账本大小，40 天的数要等账本攒够或看 FortyDays 测试）。
10. 有没有 KWin 标题栏（决定曲线要吸收的高度）；1002×1572 竖屏布局（截图 p9）。
11. 全部系数都要在现役 y15 上重测；c_gpu 缺离屏负载工具，暂时只能用假设值。B2/B3 的效应只有 30–60 mW，ci 可能很宽，照实标。
12. 平板如果哪天启用了休眠：CLOCK_MONOTONIC 会停，休眠期间只能落进 gap，用 UPower 的电量 % 补。
## 11b. 第 11 节预检的结果（10-30 06:28，熄屏、放电 78 %、没在测量，只读）

预检脚本 `bp-precheck2.sh` 没进仓库：除了在 `/run/user/1000` 下建一个临时目录做 rename 测试，其余全是只读。

- **第 1 条**：`/run/y700-flightrec` 是 0755 root。user 能对它 `inotify_add_watch`。tmpfs 上 rename 投递 `IN_MOVED_TO`，文件名就是 `edge`。
- **第 2 条**：
  - 1108 个线程，user 全部读得到，包括 KWin（`voluntary_ctxt_switches` 可读）。Python 整体扫一遍 9–15 ms，Rust 只会更快，比第 1 节的 50–120 ms 预算低得多。
  - 118 个 `cpu.stat`，常开 fd 做 pread，每个 0.6–2 µs。
  - 把所有 `/proc/*/fd` readlink 一遍找 DRM fd：70 个，Python 5.6 ms。
- **第 2b 条**：
  - systemd 259，可以用 `RestartSteps`。用户服务默认 `LimitNOFILE` 软上限是 1024。
  - UPower 电池对象是 `/org/freedesktop/UPower/devices/battery_qcom_battmgr_bat`。
  - `GetHistory` 的 timespan 填 0 **不是**「全部」，只回 13 个点。要用 `604800 0`：charge 回 138 个点，rate 回 3530 个点（每 30 s 一个，最新的在前）。
  - state 码：0 unknown、1 charging、2 discharging、3 empty、4 fully charged、5 pending charge、6 pending discharge。
- **第 3 条**：用户 journal 的 Consumed 消息带 `USER_UNIT`、`CPU_USAGE_NSEC`、`_BOOT_ID`、`__MONOTONIC_TIMESTAMP`，这次开机有 46 条。
- **第 4 条**：
  - user 能跑 `chronyc -n -c tracking`，CSV 最后一个字段是 Leap status，现在是 `Normal`。
  - chrony.conf 里有 `rtcsync` 和 `makestep 1 3`。
  - **fake-hwclock 是 masked，没在用**，所以对时之前的时间来自 RTC。第 2 节「倒退的点丢掉、两次开机之间的点丢掉」照样适用。
- **第 6 条**：Xwayland 在 `session.slice/plasma-kwin_wayland.service` 里，和 KWin 同一个 cgroup，与第 4 节的假设一致。
- **第 8 条**：背光 `type=raw`。熄屏时 `brightness=332`、`bl_power=4`，所以熄屏时不要累加 `bl`。
- **第 10 条**：kwinrc 里没有 `BorderlessMaximizedWindows`，最大化的窗口多半带标题栏，要在测试台截图里核。
- **零读数比预想的多**：此刻 live.log 5618 行里有 822 行 `-0mW`（15 %），`+0mW` 0 行，大部分时间熄屏。第 2 节的零读数规则影响很大，夹具要覆盖。

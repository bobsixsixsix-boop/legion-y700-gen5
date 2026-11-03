# 运行时 CX 下电实验协议（apps-pc / cxsd / aosd）— Y700 Gen5，内核 y9+

> 状态：2026-10-15 夜写成（只读了本地仓库、固件副本和上游源码）；**2026-10-16 凌晨 E1 已执行并通过（§9）**，E3 待 y10 上机。**10-19 核对（PLAN §6.2，X23）：E1/E3a 10-16 通过，E3b/E3c 10-18 已跑但 CX 未真睡（cxsd 始终 0，§9 10-18 条）；E3a 自 10-17 起由 `y700-cx-auto` 在熄屏+电池时日常开启（`linux/power/cx-auto/src/main.rs:1-27`），作者 10-18 定不升档（README「底噪研究·执行记录」10-18 条）。「E3 待 y10 上机」已过时。**
> 执行者：一个操作者（我），作者知情同意；作者永不休眠平板，目标是熄屏不休眠时把 0.42 W 的"醒着的底噪"压下去。
> 本目录其余文件：`y700-flightrec.service`（飞行记录器的单元；程序本身 2026-10-17 起是 Rust，在 `linux/power/flightrec/`，之前的 `y700-flightrec.py` 在 git 历史里）、`dczva-stress.c`（E2 复现程序）、
> `cx-exp.sh`（阶梯执行器）、`cx-audit.sh`（只读审计）、`cx-audit-2247.txt`（22:47 y9 的审计原文）、`crash-0341-lastkmsg.log`（03:41 死机的最后内核日志，来自 rawdump）。

## 0. 一页纸

- **我们缺的两个状态**：簇下电 cl5「ret-pll-off」PSCI 0x01000054（两个簇各自）和系统级 ss3「apps-pc」0x0200c354（CX 下电 / AOSS 睡眠 / DDR 自刷新的入口）。上游用两个补丁有意关掉它们：0118（`allow_cluster_off=0`，运行时拒绝簇下电，原因是允许时 78 分钟复位 2 次）和 0106（系统域 `GENPD_FLAG_RPM_ALWAYS_ON`，只在 s2idle 里用，原因是开关屏 + s2idle 循环约 1/25 复位）。安卓在同一台机、同一份固件上运行时进这些状态，所以是内核侧配置/唤醒路径问题。
- **y9 现状（审计 22:47）**：两个簇域 S0 被拒 58147 / 42201 次、系统域从未尝试（Rejected=Usage=0），`qcom_stats` 的 apss / cxsd / aosd / ddr 计数全 0；熄屏仍约 300–400 次中断/秒。
- **03:41 的死机与此无关**：rawdump 里的最后日志是 SCMI/DPU/GMU/ADC/battmgr 同时超时的总线挂死（读了 `debugfs pcie@1c00000` 的寄存器），不是空闲复位。
- **取证路径已验证**：`download_mode` 开机 3 分钟后关 → 静默复位 = 直接重启（**11-01 更正：错了**——只用 5 次干净重启验证过，干净重启本来就写 NODUMP；y16 之前 SDI 没关，固件接手的复位照样进转储模式等人，10-31 21:04 等了 2 h 9 min，见 README「10-31 21:04 死机」；y16 起写 off 也关 SDI，11-01 咬测试直接重启，见 README「内核 y16」）；ramoops 内容挺过热重启（今天 5 次重启后 `console-ramoops-0` 都在，头部有 ECC 纠正的位翻转），长按冷切断则丢（6 条 uncorrectable）。所以飞行记录器写 **pmsg + tmpfs + UFS 三份**，UFS 每秒 fdatasync 兜底。（10-19 核对，X44：「每秒 fdatasync」是旧 Python 版的节奏；Rust 版 10-17 起实验时每 1 s 一行/每 5 行落盘，平时每 10 s 一行/每 6 行落盘（旧 Python 版曾每秒写、每 5 s 落盘），见 §2 :58-59 与 `linux/power/flightrec/src/main.rs:16-22`）
- **阶梯**：E0 基线与取证演练 → E1 簇下电（熄屏 2×30 分钟）→ E2 簇下电 + DC ZVA 压力 → E3a/b/c 系统域分级放开（先只让 APSS 下电、CX/DDR 由 AOP 保持；再放 CX；再放 DDR）→ E4 开关屏循环 → E5 Wi‑Fi 流量。每级有前提、命令、时长、成功/中止判据、测量和风险。E3 需要 y10 的 `allow_system_off` 模块参数（规格见 §6）。
- **预期收益要说实话**：s2idle 0.07–0.13 W 是下限；熄屏时每秒 300 次唤醒的现状下，ss3 驻留率估计只有 10–25%，省 **0.03–0.08 W**；把唤醒压到每秒 50 次以下才可能到 60–85% 驻留、省 0.2–0.27 W。安卓同机熄屏驻留率没有公开数字（猜测 70–90%）。还有两个未知：mainline 没有安卓 PCIe DRV（链路在 apps-pc 期间靠硬件状态机维持 L1.2），CX 真下电时 PCIe/UFS/USB 的 GDSC 是否都能保持（0059 为 s2idle 修过 USB 的保持）。

## 1. 已知事实与证据

### 1.1 状态与层级（内核 DT 与安卓 vendor DT 一致）

| 状态 | PSCI 参数 | 进入/退出延迟、最小驻留（µs） | 内核 DT | 安卓 vendor DT（本机固件 vendor_boot blob 12「CanoeP v2」） |
|---|---|---|---|---|
| CPU retention c4 | 0x00000004 | 93/129/560（gold）、172/130/686（prime） | `kaanapali.dtsi:183-199` | `/cpus/idle-states/medium-cluster0-c4`、`large-cluster1-c4`，数值相同 |
| 簇 cl5「ret-pll-off」 | 0x01000054 | 2150/1983/9144 | `kaanapali.dtsi:203-209` | `medium-cluster-cl5`、`large-cluster-cl5`，数值相同 |
| 系统 ss3「apps-pc」 | 0x0200c354 | 2800/4400/10150 | `kaanapali.dtsi:211-217` | `cluster-ss3`「apps-pc」，数值相同 |

- 层级：vendor 是 `cpu-pd0..5 → cluster-pd0`、`cpu-pd6..7 → cluster-pd1`、两者 → `cluster-pd2`（ss3）；上游 kaanapali.dtsi 把 8 核放一个簇域，补丁 0031 按 vendor 拆成两簇（`patches/0031`，提交信息：拆前系统域被固件拒绝约 200 万次）。`apps_rsc` 挂在 `system_pd` 下（`kaanapali.dtsi:5835` `power-domains = <&system_pd>`；vendor `rsc@18900000` 同样 `power-domains = <cluster-pd2>`），所以 rpmh 的 sleep/wake 集在系统域 PRE_OFF 时刷下去（`rpmh-rsc.c:943-951`，控制器忙则 `NOTIFY_BAD` 否决下电）。
- 同一组 PSCI 值也用在 SM8750、Glymur、X1E80100（Glymur 评审帖 lkml.iu.edu/hypermail/linux/kernel/2510.1/04662.html 列出 `cluster-ss3`「apps-pc」0x0200C354 及三组 cl5 0x01000054；Maulik Shah 答复：更浅的 CL4/SS1「没有功耗/性能收益」；X1E80100 的 SS3 补丁 patchew.org/linux/20251012225950.15475-1-val@packett.cool 里 Konrad Dybcio 指出同一状态在 `PSCI_SYSTEM_SUSPEND` 时是硬编码的）。
- 两个 workaround 怎么起作用：
  - 0106：给 baldur 的 `power-domain-system` 加 `GENPD_FLAG_RPM_ALWAYS_ON`（`cpuidle-psci-domain.c` 补丁后 72-77 行）。genpd 在 `genpd_power_off()` 一进门就跳过该域（`drivers/pmdomain/core.c:966-969`），**从不尝试**，所以审计里系统域 Usage/Rejected 都是 0。只在 s2idle（`dev_pm_genpd_suspend`）里走系统状态。
  - 0118：`allow_cluster_off=0` 时 `psci_pd_power_off()` 对簇域返回 `-EBUSY`（`idle_should_enter_s2idle()` 为真时放行）。genpd 把失败记进 `rejected++`（`core.c:1013-1016`），域保持 on，CPU 自己仍进 retention。审计里的 58147/42201 就是这个计数。
  - 上游的数字：允许簇下电 78 分钟 2 次复位，拒绝 3 小时 0 次；熄屏功耗 658/659/621 mW 无差别（`patches/0118` 提交信息；`docs/hardware-status.md:120`）。0106：开关屏 + s2idle 循环约 1/25 复位，去掉系统状态后 180 次 0 复位；s2idle 保 CX 下电 4.8 小时，18–35 mA（`patches/0106` 提交信息）。上游用 drgn 读整块 DDR 转储看到：cluster0 的 CPU0-4 进 retention 20 ms 内再没出来，IPI 和 hrtimer 都在排队，CPU5-7 又跑了约 10 秒才被复位——**像是进入 CPU_SUSPEND 后再没被唤醒**。

### 1.2 y9 的现场（`cx-audit-2247.txt`，22:47，亮屏、充电中）

- cpuidle：每核两个状态 `WFI` / `cpu-sleep-N retention`，domain 状态不单列（OSI 下 `cpuidle-psci.c:253-271` 用最深的 CPU 状态触发 genpd 选域状态）。
- `pm_genpd`：`power-domain-cluster` S0 Rejected 58147、`cluster1` 42201、`system` 全 0；`cx` 域 **off-0**（APSS 侧没有 CX 性能投票；PCIe/UFS/USB 的 OPP 投票停在各自 GCC GDSC 上——`gcc_pcie_0_gdsc on 256`、`gcc_ufs_phy_gdsc on 56`——因为 `gcc` 节点没有父域，投票传不到 rpmhpd）；`mmcx on 384`（亮屏时 DPU/DSI）。
- `qcom_stats`：`apss`、`cxsd`、`aosd`、`ddr` Count 0；`adsp` 10094 次、`soccp` 7390 次（这两个子系统自己在睡）；`cdsp` Count 0 但 Accumulated Duration ≈ 整个开机时长、Last Entered At 13.4 s——按 `qcom_stats.c:99-106` 的算法这表示 CDSP 开机 13 秒后进了低功耗态再没醒，**不是阻塞者**。
- `qcom_aoss` debugfs（`/sys/kernel/debug/qcom_aoss/`）有四个**只写**旋钮（`qcom_aoss.c:499-503`，权限 0200）：`prevent_aoss_sleep`（`{class: aoss_slp, res: sleep: enable}`）、`prevent_cx_collapse`（`{class: cx_mol, res: cx, val: mol}`）、`prevent_ddr_collapse`（`{class: ddr_mol, res: ddr, val: mol}`）、`ddr_frequency_mhz`。写 1 发「mol」（保持最低工作电平），写 0 发「off」。这是 E3 分级的关键杠杆：**先让 APSS 自己下电而 CX/DDR 不动**。AOP 若不认这个消息，写入会返回错误（`qmp_send` 失败），要检查返回码。
- 唤醒：熄屏时 300–400 次中断/秒（README 续航第三轮：`arch_timer` 160/s、IPI1 86/s、`apss_cpucp_mbox` 11/s；用户态唤醒最多的是 tailscaled 约 35 次/s、PowerDevil 10 次/s、Claude 桌面版 22 次/s）。
- PCIe：L1.2 几乎进不去（4 小时 31 次，L1.1 163 万次，README）。mainline `pcie-qcom.c` 没有运行时电源管理：只有 `suspend_noirq`（`pcie-qcom.c:2340-2394`）在系统睡眠时把 ICC 带宽降到 1 kB/s、OPP 置空；运行时链路起着就一直投 Gen3 的 NOM OPP 和 PCIe 时钟（审计 clk_summary：`gcc_pcie_0_*`、`gcc_pcie_0_aux_clk`、`pcie0_pipe_clk` 全开）。安卓 vendor 的 `pcie@1c00000` 是 `qcom,pci-msm`，带 **DRV**（`qcom,drv-name = "cesta"`、`qcom,drv-l1ss-timeout-us = 5000`、`qcom,l1-2-th-*`）和独立的 `pdc@b370000`「qcom,pcie-pdc」——安卓在 apps-pc 期间由硬件状态机替 APSS 维持 PCIe L1ss 并处理唤醒，mainline 一概没有。

### 1.3 03:41 的死机（`crash-0341-lastkmsg.log`，README 849 行）

rawdump 里 `lastkmsg.log` 的最后几秒：163 条 `arm-scmi.1 timed out in resp`（CPUCP 的 SCMI 通道）、36 次 DPU `vblank timeout` / `wait for commit done -110`、17 次 GMU `delay in fenced register write`、ADC 读超时、battmgr 读属性 -110。所有和固件/硬件打交道的路径同时挂死——AHB/NoC 总线挂死的典型症状，时间点与"读 `debugfs pcie@1c00000/link_transition_count`"吻合（该文件 `readl_relaxed` 五个 PARF 调试计数寄存器，`pcie-qcom.c:1829-1849`）。**结论：和空闲复位问题无关；今后一律不读寄存器类 debugfs。**

### 1.4 复位后的取证：ramoops 挺不挺得过复位？

- 布局：`ramoops@c2000000` 0xc0000，`record-size 0x10000`（4 个 dmesg 区）、`console-size 0x40000`、`pmsg-size 0x40000`、`ecc-size 16`（`kernel/dts/kaanapali-lenovo-baldur.dts` reserved-memory；`patches/0054`）。vendor `qcom_ramoops` 同一几何（`record 0x10000 / console 0x40000 / pmsg 0x40000 / ecc 0x10`）。ECC 是 RS(255,239)，每 128 字节块 16 字节校验，最多纠 8 字节（`ram_core.c:198-201`）。
- **热重启挺过**：22:22 热重启后的开机日志是 `ramoops: error in header, 1` ×4、`error in header, 2` ×1（`ram_core.c:243-245`：**已纠正** 1–2 字节），`baldur: console-ramoops-0` 存在，systemd-pstore 把它归档到 `/var/lib/systemd/pstore/console-ramoops-0`（审计 pstore 段）。README 850 行：今天 5 次热重启后都在。头部每次都有一两个字节的位翻转，说明 DDR 在复位过程中没刷新、内容略有衰减（上游 kexec 配置片段的注释也提到「ramoops 的位翻转是设备自己的」）。
- **冷切断丢**：11:04 长按关机后的开机（`kernel-y8/inventory/dmesg:238-243`）6 个区全是 `uncorrectable error in header`，pstore 列表为空（`dmesg:782-783`）。
- **未知**：固件发起的静默复位是否走同一种热路径。E1 第一次复位后立刻验证（§3 E1 的「复位后」步骤）。**11-01 一次样本：保留**——10-31 固件复位 → 转储模式 2 h → 长按，console-ramoops 和 pmsg 都在，头部 `error in header` 全部已纠正（见 README「10-31 21:04 死机」）。
- **systemd-pstore 的行为**（`src/pstore/pstore.c:47-51, 95-150, 348`）：默认 `Storage=external`、`Unlink=yes`；非 EFI/ERST 的文件原名复制到 `/var/lib/systemd/pstore/<原名>`，**同名覆盖**（`COPY_REPLACE`），并把内容作为 `FILE=` 字段写进 journal（`journalctl -o verbose MESSAGE_ID=...` 或 `journalctl -b -u systemd-pstore`）。所以每次开机的 `console-ramoops-0` / `pmsg-ramoops-0` 会覆盖上一次的——飞行记录器启动时先把它们拷到 `/var/log/y700-flightrec/pstore/<boot-id>/`。
- **rawdump**（`download_mode=full` 时）：XBL 在转储模式把 ramoops 控制台（`lastkmsg.log`）、OCIMEM、AOP CODERAM/DATARAM、RPMh MSGRAM0–15、CPUCP 固件、`RST_STAT`/`PMIC_PON` 等 51 段写进 UFS 的 rawdump 分区（`/dev/disk/by-partlabel/rawdump`），`tools/rawdump-ls.py` 解析。代价是停在 900E 等人长按开机（03:41 那次 7 小时耗掉 36% 电）。**无人值守一律 off；有人盯着、想拿 AOP/RPMh 现场时临时 `echo full > /sys/module/qcom_scm/parameters/download_mode`**，实验完改回 `off`。（11-01 起内核 y16：开机 3 分钟写 off 时 SDI 也关了，`echo full` 打不开它；这时被咬或 panic 还写不写 rawdump 没试过，见 README「内核 y16」副作用。要靠这条路取证，先在有人在场时试一次。）

## 2. 飞行记录器 `y700-flightrec`（2026-10-17 起 Rust：`linux/power/flightrec/`）

- **节奏（2026-10-17 改）**：做实验时（任一 CX 旋钮 `allow_cluster_off`/`allow_system_off` 打开，或 `--mark "<步骤> start <N>min"` 之后、`--mark "<步骤> end ..."` 之前；标记在 `/run/y700-flightrec/fast` 里留一个到期时间：N 分钟 + 30 分钟，没写分钟就 3 小时，脚本中途死了也会自己过期）每 1 秒一行、每 5 行 fdatasync；平时每 10 秒一行、每 6 行（约 1 分钟）fdatasync。`--mark` 会用 SIGUSR1 叫醒守护，切到 1 秒是即时的（cx-exp.sh 先打 start 标记再拧旋钮）。切换时写一行 `MODE fast|slow`。旧的 Python 版全天每秒一行：熄屏 0.57 % 单核，外加每秒一次 UFS 写、每 5 秒一次落盘。
- 每行约 280 字节，同时写三处：`/dev/pmsg0`（pstore pmsg，256 KiB 环 ≈ 最近 15 分钟；`fs/pstore/pmsg.c` 每次 write 一条记录）、`/run/y700-flightrec/live.log`（tmpfs，`tail -f` 用）、`/var/log/y700-flightrec/flightrec-<bootid>.log`（UFS，实验时每 `--sync` 行 fdatasync 一次，平时每 `--idle-sync` 行）。按 boot-id 命名，保留最近 12 次开机；`current.log` 软链指向本次。
- 字段（全是相对上一行的增量）：`t` 单调时钟、`at` 墙钟、`up` 开机秒、`bat` 电池功率 mW（正 = 放电）、`dpms`、`wifi=<operstate>/+包数`、`gov`、`aco`（allow_cluster_off）、`aso`（allow_system_off，没有该参数显示 `-`）、`dl`（download_mode）、`busy` CPU 忙%、`ctxt`、`irqt` 总中断、`irq=` 增量最大的 3 个中断、`c0=`/`c1=` 两簇的 cpuidle 进入次数（wfi / ret / rejected）、`pd=` 三个 PSCI 域 `idle_states` 第一行的 Usage/Rejected 增量（`cl0`、`cl1`、`sys`）、`qs=` `qcom_stats` 的 `apss` / `cxsd` / `aosd` / `ddr` 计数与累计时长增量（ticks/19200 = ms）。
- 启动时：拷走 `/var/lib/systemd/pstore/*` 和 `/sys/fs/pstore/*` 到 `/var/log/y700-flightrec/pstore/<bootid>/`，写一条 `HEADER`（2026-10-17 起多 `idle_interval`、`idle_sync` 两项）和一条 `MODE`。`--mark TEXT` 往三处追加一条 `MARK`（实验器在每级开始/结束用），并按上面的规则设/清实验标记。`--once` 打一行到 stdout 自检；`--bench N` 测单次采样 CPU。
- 开销（Rust）：单次采样 0.3–0.4 ms（高频）/ 约 1.8 ms（熄屏低频，含写），平时每 10 秒一次 → 约 0.02 % 单核（Python 版 0.57 %）。实验期间每秒一次。对比实验时**两臂都开着记录器**（两臂都在实验状态，节奏一样），开销相互抵消；想测绝对底噪时停掉它。
- 安装：
  ```sh
  # 在平板上编译（只依赖 libc，离线用 Ubuntu 打包的 crate）：cd linux/power/flightrec && cargo build --release
  bash linux/power/flightrec/deploy.sh <放着 y700-flightrec 和 .service 的目录>   # 有实验在跑会推迟；失败自动回滚
  systemctl enable y700-flightrec
  /usr/local/libexec/y700-flightrec --once             # 自检一行
  # /usr/local/libexec/y700-flightrec.py 是指向它的软链（装着的 cx-exp.sh 用这个路径打标记）
  tail -f /run/y700-flightrec/live.log
  ```
- **复位后怎么读**：
  1. `journalctl --list-boots` 找上一次 boot-id 前 8 位 → `/var/log/y700-flightrec/flightrec-<id>.log` 的最后几行就是复位前最后 1–2 秒（实验时每 5 行落盘；最后一行与复位的间隔 ≤ 1 s + 落盘延迟；不在实验时是 ≤ 10 s + 最多约 1 分钟的落盘延迟）。
  2. `/var/lib/systemd/pstore/pmsg-ramoops-0`（systemd-pstore 搬过来的 pmsg 环）应与 1 的尾部一致——一致说明 DDR 内容挺过了这次复位（含 `console-ramoops-0` = 上一次开机的 printk 尾巴，看有没有 oops/warning）；若 pstore 为空而 UFS 有，说明这类复位丢 DDR，以后只能靠 UFS 和 rawdump。
  3. 看最后几行的组合判断：
     - `pd=cl0:N/..` 刚刚从 0 变成正数后几秒内复位 → 簇下电/上电路径（0118 类）；记下当时 `c0`/`c1` 的进入次数和 `irq` 前三——哪个中断在最后一秒还在来、哪个簇在循环下电。
     - `pd=sys:N/..` 第一次 >0 后复位 → 系统域路径（0106 类）；看 `qs=apss` 是否也动了（AOP 看到 APSS 睡了没）、`cxsd/aosd` 是否动了（死在 APSS 下电本身，还是死在 CX/DDR 真下电）。
     - （先看节奏：最后一条 `MODE` 是 fast 时每秒一行、每 5 行落盘，下面这条判据成立；是 slow 时每 10 秒一行、约 1 分钟落盘一次，UFS 尾行本来就可能比复位早几十秒——改看 pmsg 尾行，它比复位早 >20 s 才算异常。）最后一行之后记录器停了很久（UFS 文件时间戳与 journal 停止时间差几十秒）才复位 → 不是瞬间复位，是挂死后被 qcom_wdt（30 s）或固件看门狗咬的；对照 `console-ramoops-0` 末尾有没有 03:41 那种 `timed out in resp` 刷屏。
     - `bat` 在最后几行突然变化、`dpms` 翻转、`wifi` 包数激增 → 触发事件是外设/屏幕/网络，而非纯空闲。
  4. 想要 AOP/RPMh 现场（RST_STAT、MSGRAM）就得 `download_mode=full` + 有人在场（y16 起临时 full 还管不管用没试过，见 §1.4）；`rawdump-ls /dev/disk/by-partlabel/rawdump lastkmsg.log RST_STAT.BIN PMIC_PON.BIN`。

## 3. 实验阶梯

通用前提（每级都查，`cx-exp.sh` 会强制）：
- 作者知情，平板闲置，屏幕关（脚本用 `kscreen-doctor --dpms off`），不插充电器（功耗只有放电时准；纯浸泡可 `CX_ALLOW_CHARGING=1` 放宽），电量 ≥ 40%。
- `cat /sys/module/qcom_scm/parameters/download_mode` = `off` 且开机 ≥ 4 分钟（`y700-dumpmode-off.timer` 3 分钟才关；复位发生在前 3 分钟会卡转储模式）。
- `systemctl is-active y700-flightrec`；`y700-checklist` 没有 WARN。
- 一切经 `systemd-run --unit y700-cx-exp --collect /usr/local/libexec/cx-exp.sh <STEP> <分钟>` 跑，不依赖 ssh 会话（教训：README 613 行）。恢复由 EXIT trap 做；复位本身也会恢复（旋钮都是模块参数，命令行里 `allow_cluster_off=0`）。多级连跑用 `cx-ladder.sh P E0:20 E3a:30 …`（`P` = `cx-wakeprobe.sh` 熄屏探针），第一级非 0 退出就停。
- **实验期间不要 ssh 上平板**（2026-10-16 查出）：root 没开 linger，每次 ssh 登录都会拉起一整个 root 的 systemd 用户管理器（还会为 root 去启动全局启用的 pipewire / wireplumber / filter-chain，全部 Dependency failed），断开约 10 s 后再拆掉。04:10–04:37 我每 2 分钟 ssh 看一次进度，27 分钟里它起停了 13 次；04:05 那次每 10 s 轮询，熄屏 trace 里就出现了 4.8 次/秒 cgroup 释放、22 次/秒经 `kick_all_cpus_sync` 的全核 IPI（static key 翻转）。所以 10-16 凌晨的两次 E3a 功耗和装后对照的 0.58 W 都被我的轮询抬高过。做法：一条 `systemd-run` 起阶梯，跑完一次性登录收结果（`exp-collect.sh`）。**M-6 字段（PLAN §2.1 M-6 :145-149；`cx_disabled`/`armed_since`/`u0`/`ssh_sessions` 四项已于 10-19 落地——提交 14c6b9a，`y700-cx-status:24-30`，读不到时显示 `unreadable`/`?`，还没装上平板、随 P1 窗口装；`e3a_fail_rate_3d`/`night_plan_next` 仍排 P1.5）**：状态页加 `cx_disabled`（`/var/lib/y700/cx-auto.disabled` 存在）、`armed_since`、`u0`（`/run/user/0` 存在，即 root 用户管理器还在——ssh 污染的直接证据）、`ssh_sessions`（数 `/run/systemd/sessions/*` 里 `SERVICE=sshd`，DynamicUser 下可读性存疑，P1 现场验）、`e3a_fail_rate_3d`（读 CPU-2 T0 计数器）、`night_plan_next`（`/etc/y700/night-plan` 首行）；实验单元在跑与否页上已有（`units … exp=` 行，`y700-cx-status:23`；PLAN :149 写的 `experiment_unit` 不是页上的字段名）。有了这些字段，「要不要登录看一眼」先看页再定。
- 有人碰平板（触摸屏 `NVT-ts-spi`、电源键、音量键的中断 10 s 内 ≥ 3 次）时 `cx-exp.sh` 自动恢复、亮屏、退出 4，阶梯随之停止。**R15（PLAN §3.4 :430，10-19 定）**：每个测量窗另记 `NVT-ts-spi` 中断差分，差分 >0 的亮屏窗标「可能误触」（不自动作废；R6 的窗内 ≥3 次才作废）；场景记录器 SCN-1 复用本守卫（PLAN §2.17 :359）。
- **看进度用状态页，不用 ssh**（2026-10-16 补的漏洞：10:18 的阶梯 10:26 就因作者碰平板停了，我守着"不登录"的规矩，两个小时后才发现）：`y700-cx-status.socket` 在 Tailscale 地址 `100.64.0.10:8766` 上按连接拉起 `y700-cx-status`（动态用户、只读、不解析请求），`curl http://100.64.0.10:8766/` 返回时间、阶梯/实验单元是否在跑（看 cgroup 目录）、旋钮、亮屏与电池、`y700-cx-exp.txt` 最后 14 行。空闲时没有任何进程（PID 1 持着监听套接字）；每次请求只起一个短命单元，比一次 ssh 登录拉起整个 root 用户管理器轻得多。Win11 侧每 5 分钟 curl 一次即可。
- **MARK 语法与 `--keep-cx`（PLAN §2.1 M-2 :125-128、§2.2 CPU-4 :174-177；计划 P1.5，10-19 均未实现）**：裁决只认三种 MARK——`MARK <STEP>:<N>`（一级/一臂开始，N 为分钟）、`MARK ABORT:<原因>`（前置条件不满足或中途出事，之后的窗全部作废，R8）、`MARK DIAG:<name>`（诊断步，只出诊断文件、不计功耗，R12）；`fr-slice.py` 与 `exp-collect.sh` 用同一套。`cx-exp.sh --keep-cx`：不写 ACO/ASO/AOSS，EXIT trap 也不恢复，只给 BENCHES 在 E3a 下跑用；对应 `cx-auto` 在 BENCHES 单元存在时不 disarm。N2 的 K= 夜不等它，两臂都由 cx-exp 持 E3a（PLAN §7-14）。**今天的实际行为**：`cx-exp.sh:37` 的 `mark()` 把文本原样转发给 `y700-flightrec --mark`；记录器只在 MARK 文本第二个词是 `start` 时提高到 1 s 节奏（第三个词 `<N>min` 定时长 + FAST_MARGIN_S，没写分钟就按 FAST_DEFAULT_S），第二个词是 `end` 时降回，其它文本只记一行不改节奏（`linux/power/flightrec/src/run.rs:153-155,190-201`，常量在 `src/main.rs:61-62`）；`--keep-cx` 在 `cx-exp.sh` 里还不存在（10-19 grep）。
- **apps-pc 实验必须拔电**：插着充电器时系统域一次都进不去（E3a 第一轮），所以复位浸泡（E4/E5）若在充电时跑，等于没测 apps-pc。
- **白天每次最多 15 分钟，一两个小时的放到夜里**（2026-10-16 定：白天平板要能正常使用，长测试放到夜里）。用 `cx-when-idle.sh`：每一级开始前都要等平板闲置满 `--idle` 分钟（无触摸/电源键/音量键中断）、屏幕关着、在用电池；被作者打断的那一级（退出 4）等下一个闲置窗口重跑；`--until` 之后不再开新的一级。白天：`cx-when-idle.sh --idle 10 --until 18:00 E0:15 E3a:15`；夜里：`systemd-run --on-calendar=… cx-when-idle.sh --idle 30 --until 06:00 E3a:30 E5:30 E4:40`。一级结束时只在作者碰过、或开始前屏幕本来亮着时才点亮屏幕；E4 期间背光压到最低、结束恢复。所有单元都用 `-p KillMode=mixed`，`systemctl stop` 时让正在跑的那一级先恢复完。
- 脚本内置中止看门狗：每 10 秒扫 `journalctl -k --since -12s`，12 秒内 ≥5 条 `vblank timeout` / `failed to flush transmit queue` / `timed out in resp` / `TCS Busy` / rpmh 超时 / `Unhandled fault` / `SError` / `BUG:` / `WARNING:` 就恢复并退出 3。
- 测量：记录器的 `bat` 列（每秒）+ 每 10 分钟一次 `y700-powersample.py 75`（与 offbench 同格式，可与 0.42 W 基线直接比；2026-10-17 起记录器在实验臂是每秒一行、在 offbench/offmeasure 基线是 10 秒一行，差几 mW——严格对比用同一晚、同节奏的 E0）；判定用 `pm_genpd/*/idle_states` 和 `qcom_stats` 前后差。

### E0 基线与取证演练（零风险，先做）
- 命令：`cx-audit.sh --off > /var/log/y700-cx-audit-$(date +%H%M).txt`（熄屏版审计，§4）；`y700-whoawake 60 --off`（唤醒预算：中断/秒、按线程唤醒）；`y700-offbench`（或 `y700-powersample.py 90 baseline`）记当日基线。
- 取证演练 A（必做）：`systemctl reboot` 一次，开机后确认 `/var/log/y700-flightrec/pstore/<bootid>/` 里有上一次的 `pmsg-ramoops-0` 且尾部 = 上一次 `flightrec-*.log` 的尾部。
- 取证演练 B（可选，要作者点头，会丢未保存的窗口）：`echo c > /proc/sysrq-trigger` 故意 panic，10 秒后自动重启（`panic=10`、download off），验证 `dmesg-ramoops-*` + `console-ramoops-0` + `pmsg-ramoops-0` 完整走通。
- 成功：三份记录一致；唤醒预算有数字（目标见 §5）。

### E1 簇下电（0118 放开），熄屏，2 × 30 分钟
- 命令：`systemd-run --unit y700-cx-exp --collect /usr/local/libexec/cx-exp.sh E1 30`（脚本做 `echo 1 > /sys/module/cpuidle_psci_domain/parameters/allow_cluster_off`）。
- 判据：成功 = 30 分钟无复位，且 `power-domain-cluster`/`cluster1` S0 **Usage** 增长、Rejected 不再增长（簇真的下电了）；中止 = 复位、看门狗触发、Wi‑Fi 掉线 >60 s。
- 概率：按上游 1.5 次/小时，30 分钟内不复位的概率约 46%，两个 30 分钟都不复位约 21%——**E1 的目的首先是让记录器抓到一次复位，其次才是活过去**。累计 ≥2 小时无复位才算"簇下电在本机可用"，可以进 E3。
- 功耗：上游说无差别（658/659/621 mW）；这里预计也在 ±0.03 W 噪声里——簇只占 APSS 一部分，CX/DDR 没动。
- 复位后：按 §2 读；把 `flightrec-<id>.log` 尾部 200 行、`pstore/<id>/` 复制进本目录 `runs/E1-<日期时间>/`。连续 2 次复位就停，回到分析。
- 风险：复位 → 重启约 8 秒 + Wi‑Fi/Tailscale 重连；已开应用的状态丢。无数据损坏风险（根分区 ext4 journal；UFS 写少）。

### E2 簇下电 + DC ZVA 压力，30 分钟
- 复现程序 `dczva-stress.c`：每核一个线程，`-b 15` ms 突发里循环「memset 图案 → 逐块 `dc zva` 清零 → `dsb ish` → 校验全零、守护页未动」，突发之间随机睡 40–400 ms，让 6 核同时空闲 >9 ms 的窗口频繁出现（簇下电/上电循环最密）。任何不一致打印到 stderr 并写 `/dev/pmsg0`。编译：`cc -O2 -pthread -o /usr/local/libexec/dczva-stress dczva-stress.c`（平板上有 clang 18）。单跑自检：`dczva-stress -t 20`，期望 0 错、退出码 0。
- 命令：`systemd-run --unit y700-cx-exp --collect /usr/local/libexec/cx-exp.sh E2 30`。
- 判据：成功 = 无复位、0 错；信息价值在于**对照 E1**——若 E2 的复位率明显高于 E1，簇下电与缓存维护/清零流量的交互是线索；若出现校验错误而不复位，那是另一类 bug（记录偏移、CPU、簇状态）。假设来源：目前只是一个待验证的猜想，没有证据。
- 功耗不作数（memset 流量会拉 DDR）。

### E3 系统域运行时放开（需要 y10 `allow_system_off`，§6），分三级，每级 30 分钟
- E3a：`echo 1 > /sys/kernel/debug/qcom_aoss/prevent_cx_collapse`、`prevent_ddr_collapse` 各写 1（AOP 保持 CX 最低电平和 DDR 不下电），再 `allow_cluster_off=1`、`allow_system_off=1`。只让 APSS 进 apps-pc（GIC 断电、CPU 全下电、唤醒全靠 PDC）。判据：`power-domain-system` S0 Usage 增长、`qcom_stats apss` Count 增长，`cxsd/aosd/ddr` 仍 0；无复位。若 Usage 为 0 而 Rejected 增长 → rsc 忙否决或固件拒绝，看记录器里 `irq` 和 `pd`。若 AOP 拒收 QMP（write 报错）→ 跳过分级，直接 E3c 但缩短到 15 分钟。
- E3b：放开 CX（`prevent_cx_collapse` 写 0），DDR 仍保持。判据加 `cxsd` Count > 0。**这是最可能出事的一级**：CX 真下电时 PCIe/UFS/USB 的 GDSC 要靠保持（0059 为 s2idle 把 USB GDSC 改 `PWRSTS_RET_ON`；0128 为 UFS MCQ 修了 `FORCE_MEM_CORE_ON`），而 PCIe 链路起着、没有 DRV。复位了就是"CX 下电 + 外设未就绪"，比"APSS 下电"更难，先停。（10-19 核对，X25：10-18 两轮 E3b 零复位但 cxsd 均为 +0（`runs/E3b-20261018-0219/summary.txt:51-52`、`runs/E3b-20261018-0758/summary.txt:53-54`），此风险尚未被实际检验，见 §9 10-18 条；7.4 起 gcc 挂到 CX 后风险形态要重评，见 RESEARCH §1.3）
- E3c：全放（`prevent_ddr_collapse` 写 0）= s2idle 的深度。判据加 `aosd`/`ddr` Count > 0 和功耗下降。
- 每级功耗：记录器 `bat` 平均 + 三次 powersample；与同日 E0 基线比。
- 唤醒延迟的副作用：ss3 退出 4.4 ms，触摸/按键/网络首包多几毫秒，熄屏无所谓。

### E4 系统域 + 开关屏循环（0106 的触发器），60 次
- 命令：`cx-exp.sh E4 40`（每 20 秒 dpms on/off 一次，期间 ss3 放开到 E3 通过的那一级）。
- 判据：60 次无复位；上游 1/25 的失败率下 60 次约 91% 会撞上一次——所以这级的目的也是**抓现场**：复位前最后一行的 `dpms` 翻转方向 + `pd=sys` 计数告诉我们是开屏路径（DSI/DPU 上电时的唤醒）还是关屏后进入。
- 补充观察：DPMS off 后 `mmcx` 域应变 off-0（审计里亮屏是 on 384）；若熄屏仍 on，是显示没真正下电，先修它再谈 CX。

### E5 系统域 + Wi‑Fi 流量，30 分钟
- 命令：`cx-exp.sh E5 30`（对网关 `ping -i 0.2 -s 1000`；设 `IPERF_SERVER=<局域网内另一台机器>` 则每 30 秒一轮 `iperf3 -b 20M`）。
- 判据：无复位、无 `failed to flush transmit queue`（看门狗已盯）、`ping` 丢包 <1%、`qs=apss` 在包间隙仍增长。意义：PCIe 唤醒（WAKE# gpio104 / MSI）从 apps-pc 唤醒 APSS 的路径；ath12k 省电（1041）下固件只在有数据时叫醒主机。
- 风险：Wi‑Fi 固件卡死（README 600 行那类），看门狗单元 `y700-wifi-watchdog` 会重载驱动。

### 通过/不通过
- 每级至少 1 次完整时长 + 第二次复测；累计复位 ≥2 次停在该级做分析。
- E1 累计 ≥2 h 无复位 → E3；E3a/b/c 各 ≥1 h 无复位 → E4/E5；E4+E5 都过 → 评估常驻（届时再量 24 小时）。
- **门槛的读法（10-19 定，X24）**：≥1 h 是晋级 E4/E5/常驻的门槛，白天 ≤15 min 的短测只做探路、不计入门槛，累计只认 ≥30 min 的完整轮次。
- 任一级抓到复位：优先产出 `runs/<step>-<time>/` 里的尾部 + pstore，再决定是否继续。

## 4. 只读审计「谁挡着 CX」（E3 前跑，`cx-audit.sh --off`）

**安全（内核内存结构或 AOP 消息 RAM 的汇总，不碰断电模块寄存器）**：

| 文件 | 看什么 | 本机 22:47 亮屏快照 |
|---|---|---|
| `/sys/kernel/debug/pm_genpd/pm_genpd_summary` | 哪些域 on、谁 active、性能态（`core.c:3882` 表头） | `mmcx on 384`（显示）、`gcc_pcie_0_gdsc on 256`、`gcc_ufs_phy_gdsc on 56`、`gcc_usb3_phy_gdsc on`、`cx off-0`、系统/簇域 on |
| `/sys/kernel/debug/pm_genpd/power-domain-{cluster,cluster1,system}/idle_states` | S0 的 Usage/Rejected（`core.c:3955`） | 0/58147、0/42201、0/0 |
| `/sys/kernel/debug/qcom_stats/*` | 各低功耗态计数（AOP MSGRAM，`qcom_stats.c:267`） | apss/cxsd/aosd/ddr 0；adsp 10094；soccp 7390；cdsp 睡着 |
| `/sys/kernel/debug/interconnect/interconnect_summary` | 非零带宽投票（`core.c:1263`） | `llcc_mc`/`ebi` 3.7 GB/s 平均（memlat 固件投票），PCIe 峰值 1.97 GB/s |
| `/sys/kernel/debug/regulator/regulator_summary` | 开着的轨、always-on | 审计脚本过滤有误，列表空；本次重取原文 |
| `/sys/kernel/debug/clk/clk_summary` | enable_count>0 的时钟（`clk_core_is_enabled` 对未 runtime-active 的控制器直接返回 false，`clk.c:364-380`，不读断电寄存器） | PCIe 全套、显示全套（亮屏）、UFS ahb/ice、qup3（蓝牙 UART）、LPASS codec 时钟、`bi_tcxo` 被 cdsp 占着（10-19 更正，X20：`bi_tcxo` consumer 列显示 cdsp，实为两个子时钟使能，CDSP 不持，见 ALWAYS-ON §1） |
| `/sys/kernel/debug/wakeup_sources` | 唤醒源计数 | rtc、battmgr |
| `/sys/class/remoteproc/*/state` | adsp/cdsp/soccp | running/running/attached |
| `/sys/bus/pci/devices/*/link/*`、`power/runtime_status`、`/sys/module/pcie_aspm/parameters/policy`、`lspci -vv` 的 LnkCtl/L1SubCtl | 链路 ASPM/L1ss 配置（PCI 配置空间读，安全） | 待取 |
| `/proc/interrupts` | 每个中断的芯片列：`pdc` 路由的能从 apps-pc 唤醒，`GICv3` 的在 GIC 断电时不能 | 待取（脚本会分类计数） |
| `/sys/devices/system/cpu/cpu*/cpuidle/state*/{usage,rejected,time}`、`/sys/module/cpuidle_psci_domain/parameters/*` | 状态使用 | 见上 |
| `/sys/kernel/debug/psci` | PSCI 版本/特性（SMC 到固件，安全） | 存在 |
| UFS/USB/GPU/MDSS 的 `power/runtime_status`（sysfs） | 外设是否 runtime-suspended | 待取 |

**禁区（会读断电/断时钟模块的 MMIO，03:41 就是这么挂的）**：`/sys/kernel/debug/pcie@*`（`link_transition_count` 五个 `readl_relaxed`）、`/sys/kernel/debug/regmap/*/registers`（逐寄存器 dump）、`/sys/kernel/debug/dri/*` 下的寄存器 dump（`dpu/*`、`dsi*`）、`/sys/kernel/debug/*.gpu`、`/sys/kernel/debug/dwc3*`/`usb*` regdump、`ufshcd*`、`/sys/kernel/debug/ieee80211/phy*/ath12k/*`（向固件发命令）、`mhi*`、任何 `/dev/mem`。`qcom_aoss/*` 是只写旋钮，不读。`pinctrl`/`gpio` 读 TLMM（常开）本身安全但不需要。

读法：审计在**熄屏**后 20 秒跑一次、E3 前再跑一次；关注 (a) 熄屏后 `mmcx`、`disp_cc_*` 是否 off；(b) `pm_genpd` 里 rpmhpd 各域有没有 APSS 侧 active 设备（现在只有 mmcx）；(c) `/proc/interrupts` 里熄屏仍在跳的中断是不是 `pdc` 路由的——不是的那些（例如 `GICv3` 直连的 SPI）在 apps-pc 期间会丢唤醒（上游 drgn 看到的「进了 CPU_SUSPEND 再没回来」与此相符，**猜测**）。

## 5. 预期收益（诚实版）

- 下限：s2idle 18–35 mA ≈ 0.07–0.13 W（3.85 V；`patches/0106`），运行时不可能更低。现状熄屏 0.42–0.44 W（README）。
- ss3 只能在**所有 8 核同时空闲且预计空闲 > 10.15 ms**（min-residency）时进入，每次进出还要 2.8 + 4.4 ms。熄屏时 300 次中断/秒 → 系统级空闲间隙平均 3.3 ms。把间隙当泊松分布算（间隙均值 m，门限 t = 10.15 ms，开销 c = 7.2 ms），睡着的时间比例 ≈ e^(−t/m)·(1 + (t − c)/m)：

  | 唤醒率（次/秒） | m（ms） | 理想驻留率 | 功耗估计（0.42 − 0.32 × 驻留，且假定 CX/DDR 跟着下） |
  |---|---|---|---|
  | 300（现状） | 3.3 | ~10% | ~0.39 W（省 0.03） |
  | 100 | 10 | ~47% | ~0.27 W |
  | 50 | 20 | ~69% | ~0.20 W |
  | 20 | 50 | ~86% | ~0.15 W |

  实际调度器（menu/TEO）比理想保守，定时器会对齐成簇（有利），所以这是量级估计。**结论：E3 本身救不了多少电，唤醒率是另一半工程**——tailscaled 35 次/s、Claude 桌面版 22 次/s、PowerDevil 10 次/s、`arch_timer` 160/s（多半是这些进程的 hrtimer）。安卓靠 doze 把应用定时器批处理、Wi‑Fi 固件自己收信标（DTIM 约 300 ms 一次不叫醒主机，只有真有数据才唤醒），所以能熄屏 80–90% 驻留（**猜测，没找到本机或同代 SoC 的公开数字**；Qualcomm 文档只给了 `qcom_stats` 的读法，没有预期驻留）。
- 另外两项不确定：(1) CX 真下电需要 PCIe 链路在 L1.2 并由硬件维持（安卓 DRV/cesta），mainline 没有——可能 `apss` 计数涨而 `cxsd` 不涨，收益只剩 APSS 那份（估计 0.05–0.1 W，**猜测**）；(2) 若 CX 下电时 PCIe/UFS 状态丢失，E3b 会复位，收益为 0 直到有 PCIe runtime PM / GDSC 保持的补丁。
- 最有把握的收益顺序：唤醒率治理（0 风险，E0 的 whoawake 给出名单）> ss3 分级放开 > 簇下电本身（上游实测无差别）。

## 6. y10 内核旋钮规格（2026-10-16 按 RESEARCH.md §3.3 的裁决改写为 flag 方案；实现：`linux/kernel-y8/1043-cpuidle-psci-domain-allow_system_off.patch`，构建 `kbuild-y10.sh`，自检 `y10-selfcheck.sh` / `y10-verify.sh`，说明 `linux/kernel-y8/Y10-NOTES.md`）

目标：把 0106 的"系统域永不运行时下电"改成可运行时切换，默认行为不变（`aso=N` ≡ 0106 ≡ y9）。

- `drivers/cpuidle/cpuidle-psci-domain.c`：`static bool allow_system_off;`（默认 **N**，fail-safe，不依赖 cmdline），`module_param_cb(allow_system_off, …, 0644)`。0106 的 `of_machine_is_compatible("lenovo,baldur") && power-domain-system` 判定**保留**，probe 时照旧置 `GENPD_FLAG_RPM_ALWAYS_ON`，并把该 genpd 记在 `psci_system_pd`；参数的 set 回调在运行时只翻这一位：写 1 清掉（= 上游行为，运行时可进 ss3；但要 `aco=1` 簇先能下电才到得了），写 0 置回（= 0106）。`CONFIG_PREEMPT_RT` 下回调开头直接返回，不碰 RT 刻意给所有 CPU 域设的 flag（本机未开 RT）。
- 不加锁：genpd 锁没导出（`struct genpd_lock_ops` 只在 core.c 里）也不需要——参数写入由 kernel_param 锁串行化、单写者、单 bit、`unsigned int` 读不会撕裂；写者所在 CPU 的域链必为 on，所以系统域不可能正处在下电中途；清掉 flag 后下一次最后一个簇下电时 `genpd_power_off(system)` 就会通过 `core.c:966-969` 的检查（细节在补丁提交信息）。同一检查里 7.3 新加的 `genpd->stay_on` 由各 PSCI 域 provider 设备的 sync_state（`genpd_provider_sync_state`，`fw_devlink.sync_state=timeout` 保证最迟 late_initcall_sync 跑到）在启动时清掉——y9 上簇域能走到 0118 的 -EBUSY 并计 Rejected 就是它已清的证据，系统域同机制。参数 ops 带 `KERNEL_PARAM_OPS_FL_NOARG`，裸 `cpuidle_psci_domain.allow_system_off` 等于 `=1`，与 0118 的 bool 一致（审阅时补）。
- 不动 cmdline：`kbuild-y10.sh` 的 CMDLINE 与 y9 相同（RESEARCH §3.3 第 (3) 条"CMDLINE 加 `allow_system_off=0`"**不采用**：默认 N 已在 C 里，加了反而让人以为旋钮依赖 cmdline）。
- 验收：`aso=N` 时 `power-domain-system` 的 Usage/Rejected 恒 0（与 0106 相同；**不会**像原 -EBUSY 方案那样 Rejected 增长）；`aso=Y` 而 `aco=N` 时什么也不变（簇不下电，系统域到不了）；`aso=Y` 且 `aco=Y` 时 Usage 增长（`qcom_stats apss` 随之计数；cxsd/aosd/ddr 看 E3 分级）。dmesg：开机一行 `CPUidle PSCI: power-domain-system: allow_system_off=N, system domain state in system suspend only (lenovo,baldur quirk, boot)`，每次切换一行 `… allow_system_off=Y, system domain state in runtime idle too (parameter written)` / `… =N, … in system suspend only (parameter written)`。`/sys/module/cpuidle_psci_domain/parameters/allow_system_off` 0644。
- 原 -EBUSY 方案（照 0118 写法在 `psci_pd_power_off()` 拒绝系统域）**不采用**的原因：`_genpd_power_off()` 先发 PRE_OFF（系统域上是 `rpmh_rsc_pd_callback` → `rpmh_flush`）再调 `->power_off()`，-EBUSY 会回滚 `GENPD_NOTIFY_ON` 并 Rejected++——每次最后一个簇下电都刷一遍 RPMh sleep set，这是 0106 基线没有的新行为，给 A/B 掺进混杂变量（RESEARCH §3.3）。
- 升级地雷：linux-next 的 `is_off=use_osi`（RESEARCH §2.7）会让 0106/1043 的 `RPM_ALWAYS_ON` 在 `pm_genpd_init` 处 -EINVAL；基底过 7.3 时两者都要改写。

## 7. 有意不做 / 边界

- 不改默认值：所有旋钮只在 `cx-exp.sh` 的时长内打开，EXIT trap 和复位都会恢复；不写进 tmpfiles/cmdline，直到 E4/E5 通过且做了 24 小时浸泡。
  - **10-19 改写（X23，作者 10-17/10-18 决定）**：不改内核默认值/cmdline/tmpfiles；运行时旋钮由 `y700-cx-auto` 按作者 10-17 决定在熄屏用电池时打开（先于 E4/E5 ≥1 h + 24 h 浸泡，复位一次即自停，`linux/power/cx-auto/src/main.rs:18-24`），`cx-exp.sh` 仍只在实验时长内开。上一句的「所有旋钮只在 cx-exp.sh 的时长内打开」自 10-17 起不再成立。
- 不在 `download_mode=full` 下无人值守（会卡转储模式耗电）。
- 不读任何寄存器类 debugfs，不多个代理同时上平板，设备掉线就停工作流（README 850 行的教训）。
- 不动 ADSP/CDSP/SoCCP（它们已经在睡）；不改 Wi‑Fi 省电（1041 已开）。
- 不把 E2 的 DC ZVA 结果当功耗数据。

## 8. 开放问题

1. 固件发起的静默复位后 pstore 是否仍在（E1 第一次复位即知）。11-01：一次样本，在（见 README「10-31 21:04 死机」）。
2. `qcom_aoss` 的 `cx_mol`/`ddr_mol` 消息本机 AOP 是否接受（E3a 第一步即知）。
3. 熄屏时哪些仍在跳的中断不走 PDC（审计 `/proc/interrupts` 分类）；它们能不能在 apps-pc 期间唤醒。
4. 上游 drgn 看到的「CPU0-4 进 retention 再没回来」在本机复现时，记录器最后一行的 `irq` 是什么——这是区分"GIC 断电丢中断"与"固件 PSCI 实现缺陷"的第一手线索。
5. mainline 缺 PCIe DRV 的后果：E3b 的 `cxsd` 计数会不会动。
6. vendor 的 `cpuss-sleep-stats@18870000`（`qcom,cpuss-sleep-stats-v6`，两簇）是 APSS 自己的 LPM 计数器，mainline 没有驱动/DT；若 `qcom_stats apss` 不够用，可以作为后续 DT+驱动小补丁（只读 SRAM）。

## 9. 执行记录

### 2026-10-16 E1 簇下电，180 分钟：**通过，零复位**

- 命令：`systemd-run --unit y700-cx-exp --collect /usr/local/libexec/cx-exp.sh E1 180`，`CX_ALLOW_CHARGING=1`——平板整夜插着电（98%，Not charging），所以 **功耗列全是 0.00 W、无效**，这一轮只是复位浸泡。内核 y9（7.3.0-rc4-tb323fu-t49-y9），固件 ZUXOS 088（上游"78 分钟 2 次复位"是在 ROW .104 上测的）。00:11:39–03:11:42，熄屏，`aco=Y`，download_mode off。
- 结果：**无复位**（boot_id 不变，`journalctl -k` 近 200 分钟没有 WARNING/BUG/SError/超时/vblank 一类的行）。`power-domain-cluster` S0 Usage 0→300121、累计 8067 s（≈ 运行时长的 75%，簇 0 真的在下电）；`cluster1` Usage 0→119694、10552 s（≈ 98%，prime 簇几乎整晚关着）；系统域 0/0，`qcom_stats apss/cxsd/aosd/ddr` 全 0（0106 仍在，符合预期）。簇域在 aco=Y 期间 Rejected 仍以约 2 次/分钟缓慢增长（226581→226663），不是 0118 的 -EBUSY（已放开），来源待查（genpd governor 之外的 `_genpd_power_off` 失败路径）。
- 判定：累计 ≥2 h 无复位 → **E1 通过，可进 E3**（需 y10）。上游报告的 1.5 次/小时在本机本固件上没有重现：若真实速率是 1.5/h，3 小时零复位的概率只有 e^-4.5 ≈ 1.1%。本机差异候选：固件版本（088 vs .104）、y8/y9 的裁剪与 TEO、1041 的 Wi‑Fi 省电（Wi‑Fi 中断少了）。
- 记录：`runs/E1-20261016-0012/`（`summary.txt` 收尾快照、`cx-exp-E1.txt` 实验器日志段、`flightrec-E1.log.gz` 记录器全程逐秒行）。
- 待办：拔电再跑一次 E1 60 分钟量功耗（上游说无差别，预期在 ±0.03 W 噪声里），等平板空闲时。

### 2026-10-16 03:17 取证演练 A（E0）：**通过**——热重启后 pmsg 环挺过来了

- 03:17:46 `systemctl reboot` 进 y10（trial）。开机后 `y700-flightrec` 把 `/var/lib/systemd/pstore/*` 拷到 `/var/log/y700-flightrec/pstore/d621af4e/`：`pmsg-ramoops-0` 233032 字节、788 行记录器行（03:04:33 → `STOP t=17722.3 at=03:17:48`），**尾部与 UFS 上 `flightrec-e2b6380a.log` 的最后两行逐字一致**；ECC 报 2943 字节已纠正、26 块（≈3.3 KB）不可恢复，都不在尾部。`console-ramoops-0` 6995 字节、尾行 `reboot: Restarting system`，ECC 80 字节纠正、0 块丢。结论：§1.4 的"热路径挺得过"在 y10 上再次成立；固件静默复位是否同样热路径仍未知（E1 没复位，没机会验证）。
- 同时发现并修掉 `y10-verify.sh` 的一个坑：`chk` 用 `eval` 在当前 shell 跑判据，判据里的 `|| exit 1` 会把整个脚本杀掉（第一次跑在 56 个 PASS 后静默退出、rc=1 却一条 FAIL 都没有）；`y700-hud-overlay` 用户单元按设计是 disabled（作者不要它开机自启），验证只查它装着。修后 60/60 PASS，03:27 `kernel keep`，**good = y10**。

### 2026-10-16 E3a 系统域放开（AOP 保持 CX/DDR），30 分钟：**零复位，最后 4.5 分钟真的进了 apps-pc**

- 命令：`systemd-run --unit y700-cx-exp --collect --setenv=CX_ALLOW_CHARGING=1 /usr/local/libexec/cx-exp.sh E3a 30`，03:27:35–03:57:38，y10（开机 10 分钟后就开跑——太早，见下），熄屏，`aco=Y aso=Y`，`prevent_cx_collapse`/`prevent_ddr_collapse` 各写 1 **AOP 接受了**（没有 write 报错）。前 23 分钟插电，之后作者拔了充电器。
- 结果：无复位；内核日志只有一条与此无关的 `WARNING: net/mac80211/airtime.c:532 ieee80211_get_rate_duration`（NetworkManager 上下文，1 次）。
  - 前 25 分钟：`power-domain-system` Usage/Rejected 恒 0/0——**不是被拒**，是 genpd 的 CPU 域 governor 在 `_genpd_power_off` 之前否决（governor 否决不计数）。原因是刚重启、桌面没安静：每秒 500–700 次中断（审计里 `arch_timer` 419/s、IPI 140/s、`glink-smem`/`ipcc_0` 各 32/s），簇 0 两分钟只整体空闲 46 次（E1 稳态是 28 次/秒）。
  - 03:52:58–03:53:36 屏幕亮了半分钟（作者碰的），亮着时系统域只零星进入（首次 03:53:10）；**灭屏后从 03:53:37 起持续进入，03:53:10–03:57:38 平均 22.4 次/秒**，中断降到 380–420/s；最后 4.5 分钟 Usage 0→6047、Rejected 340，`qcom_stats apss` Count 5482、累计 141.6 s（≈ 60% 驻留）；cxsd/aosd/ddr 仍 0（E3a 的设计）。
- 判定：**apps-pc 在本机可用、不复位**（E3a 通过，可进 E3b——风险最高一级，等作者点头）。门槛是唤醒率：插着充电器时多出的上百次中断/秒把 8 核同时空闲 >10 ms 的窗口全吃掉（候选：pmic_glink 的电池/充电通知、helperd 的属性轮询），拔电后还要等它平息。这条要用"拔电 + 熄屏"的第二轮证实。
- 记录：`runs/E3a-20261016-0327/`。读法教训：系统域 0/0 ≠ 没考虑过，要配合记录器里的 `irq`/`pd=` 列看。
- 更正（逐秒记录核对）：充电器是 03:42 左右拔的（`bat` 列 03:44 起读数稳定），apps-pc 却到 03:53 才开始——03:42–03:52 电池 + 熄屏 + 旋钮全开仍然 0 次（每秒 500–740 次中断，电池读数 290–500 mW，03:44–03:52 均值约 410 mW）。触发到底是拔电后的瞬态平息、桌面终于安静、还是作者那次点亮屏幕顺手关掉了什么，这一轮分不出来；第二轮（下一条）给出的是稳态。

### 2026-10-16 E3a 第二轮，电池 + 熄屏，30 分钟（04:08–04:38）：**零复位，apps-pc 驻留 67%，熄屏功耗 ≈ 0.31 W（基线 0.42–0.45 W）**

- 命令同上，不带 `CX_ALLOW_CHARGING`（电池 99%，Discharging），y10，开机 50 分钟，`aco=Y aso=Y`，AOP 保持 CX/DDR。
- 结果：无复位；系统域 Usage +41611（≈23 次/秒）、Rejected +2429；`qcom_stats apss` +37013 次、累计 +1210.7 s / 1802 s = **67% 驻留**；cxsd/aosd/ddr 仍 0（设计如此）。中断 300–360/s（第一轮同期 500–740/s）。**10-19 补（X22）：apps-pc 驻留随内核与唤醒源状态逐次变化：10-16 y10 67%、10-17 夜 y12 40%（README 10-17 夜，exp-collect 算法）、10-18 白天 y12 17%（整段 15 min 含 07:17:55 后的复发段，`runs/E3a-20261018-0710/summary.txt` 末 4 行；有效的前 7 min 为 34%，§9 10-18 白天表）——67% 是单次最好值不是常态。**
- 功耗（记录器每 5 s 一次电池读数，04:10–04:37 共 28 个分钟均值，剔除固件掉帧的 0 读数）：**均值 309 mW**，分钟均值 184–430 mW（含 0 读数则 169–430 / 306 mW）；`y700-powersample` t+23m 一次 75 s 样本 0.36 W（min 0 max 0.67）。对照：同夜 y10 旋钮全关、熄屏、电池的 90 s 样本 0.45 W（04:00，刚亮过屏，偏高）；y9 熄屏 0.40–0.44 W（10-15 的几次样本，含 TEO 的 0.40）；第一轮 03:44–03:52（旋钮开、apps-pc 没进去）约 0.41 W。**省约 0.1 W（23–30%）。但要说清：04:03 装了 PowerDevil/tailscaled 两个唤醒 drop-in，所有基线都在它们之前、第二轮在之后——这 0.1 W 是 apps-pc + drop-in 的合计，没有拆开的 A/B**（drop-in 按 WAKEUPS 模型最多值几十毫瓦）。驻留 67% 远高于 §5 按泊松间隙算的 10–25%（定时器确实成簇对齐了），所以好于模型估计的 0.03–0.08 W。
- 判定：E3a 两轮共 60 分钟零复位、第二轮 ≥1 h 的要求只差 30 分钟——按 §3「每级 ≥1 h 无复位」再补一轮即可进 E4/E5；E3b（放 CX）是另一级、风险最高，等作者点头。
- 记录：`runs/E3a-20261016-0408/`（`exp-collect.sh` 的 MARK 区间把两轮都算进去了——rows=3607、sys use=47658 是两轮之和；第二轮单独的数字取自 `cx-exp-E3a.txt` 的 before/after 行）。
- 补记（10-16 10:18 的阶梯）：`P E0:20 E3a:30 E5:30 E4:40` 只跑完熄屏探针和 6 分钟 E0——10:26:56 作者点亮屏幕（10 s 内 48 次触摸/按键中断），`cx-exp.sh` 按设计恢复并退出 4，阶梯停止。这 6 分钟 E0（旋钮关、两个 drop-in 已装、Claude 桌面版开着、**没有 ssh 干扰**）：分钟均值 396–478 mW、powersample 0.43 W、中断 392–552/s。熄屏探针（同样无 ssh）：cgroup 创建/销毁 0 次、经 `kick_all_cpus_sync` 的 IPI 0.13 次/秒（凌晨 22 次/秒是我的 ssh 轮询，证实）；exec 0.77 次/秒，是一串约每 7.5 s 一次的 `pactl`/`pw-cli`/`pw-metadata`/`grep`/`head`（谁拉起的待查）。12:31 起用状态页盯着重跑 `E0:15 E3a:30`。
- 顺带（`y700-wakeups` 04:05 的 30 s 样本，电池、熄屏、旋钮关）：IPI「函数调用中断」216/s 的 185/s 是 `ttwu_queue_wakelist` 跨核任务唤醒本身（不是额外的唤醒源）；`kick_all_cpus_sync` 22/s 来源待查；按唤醒者：tailscaled 40/s（刚重启）、`glink-smem` → kworker 10/s、systemd-journal → rsyslogd 7.7/s（谁在每秒写 7 条日志，待查）。

### 2026-10-18 00:30 补测（E0 / E4@E3a / E3b / E3c / E5@E3c / E4@E3c）：**零复位，但系统域整晚没进——E3b/E3c 的深度实际没测到**

- 命令：`y700-cx-night.timer` → `cx-when-idle.sh --idle 15 --until 06:30 E0:20 E4:40 E3b:30 E3c:30 E5@E3c:20 E4@E3c:20`。y12（7.3.0-rc4-tb323fu-t49-y12），熄屏、电池 81 % → 76 %，六级全部跑满（00:48–04:45），每级之间空闲 15 分钟。
- 复位：**无**。开机 ID 690a169c 从 10-16 19:08 一直没变，pstore 没有新记录，cx-auto 没有自停；内核日志整晚 4 条 `vblank timeout`、2 条 `failed to flush transmit queue`，都远低于看门狗阈值（12 s 内 ≥5 条）。
- 各级（`exp-collect.sh` 汇总，记录器每秒一行，`bat` 列均值）：

  | 级别 | 时长 | 功耗 | cl0 进入 | cl1 进入 | 系统域进入 | cxsd/aosd/ddr |
  |---|---|---|---|---|---|---|
  | E0（旋钮全关） | 20 min | 353 mW | 0 | 0 | 0 | 0 |
  | E4@E3a（每 20 s 开关屏，背光 177–200） | 40 min | 723 mW | 1756 | 18062 | 102 | 0 |
  | E3b（放 CX，DDR 保持） | 30 min | 318 mW | 1159 | 12610 | 3 | 0 |
  | E3c（全放） | 30 min | 307 mW | 1145 | 13110 | 0 | 0 |
  | E5@E3c（ping 网关） | 20 min | 511 mW | 778 | 17912 | 0 | 0 |
  | E4@E3c（背光压到 1） | 20 min | 651 mW | 909 | 8709 | 86 | 0 |

- **判读：E3b/E3c 这一晚等于没测。** 系统域（apps-pc）30 分钟只进 0–3 次，簇 0 每秒不到 1 次（10-17 夜 E3a 正常时簇 0 约 25 次/秒、系统域约 20 次/秒、apss 驻留 40 %；出处（驻留 40 %）：README「底噪研究·执行记录」10-17 夜块里「`exp-collect.sh` 改了三处」子条的验算句「用昨晚的数据验过：E3a 30 分钟 1804 行、306 mW、apss 驻留 40 %」（README:1559，10-19 工作树；01:51–02:21 那条只有功耗数），驻留按 `exp-collect.sh:44` 的 qm/10/span 算法）。APSS 不进 apps-pc，CX/DDR 就轮不到下电（cxsd/aosd/ddr 全 0），所以"E3b/E3c 零复位"只说明旋钮按这两级拧着、APSS 一直醒着时没事，**不能当作 CX 真下电是安全的**。E3b/E3c 比 E0 省的 0.035–0.046 W 来自簇 1（prime 簇）几乎整晚下电和簇 0 偶尔下电。
- **原因（早上查清并证实）**：从 10-17 18:24 起，熄屏、cx-auto 打开时系统域一次都没进过（记录器 10 分钟分桶：13:38–18:13 每 10 分钟 12000–17000 次，18:28 以后全是 0；E3a 也一样白开了一整晚）。逐核看：cpu0、cpu1 的 arch_timer 每秒约 100 次，其余核 3–14 次；簇 0 的 genpd governor 因为下一个定时器太近一直否决（否决不计数，所以 Rejected 也不涨）。
  - **证明**：`kill -STOP` plasmashell 20 秒，系统域 +474（约 24 次/秒）、簇 0 +534，arch_timer 240 → 141 次/秒；`kill -CONT` 后立刻回到 0。
  - **是 plasmashell 里哪个东西**（gdb 挂上去、不带调试符号；断点 `QCoreApplication::notifyInternal2`，只看 QEvent::Timer）：定时器事件的接收者是 `QSGThreadedRenderLoop`。窗口不渲染（熄屏）时，它用一个按刷新率走的定时器（120 Hz 屏，约 8 ms）推进还在跑的 QML 动画。正在跑的动画是一个 `QQuickAnimatorProxyJob` → `QQuickOpacityAnimatorJob`，目标对象的父链是 `BusyIndicator ← Switch ← RowLayout ← Toolbar ← RowLayout ← PlasmoidHeading ← PopupDialog`：**网络小程序（plasma-nm）弹窗顶栏 Wi‑Fi 开关上的忙碌转圈**。弹窗早就收起了，熄屏了，它还在无限循环地跑。
  - **怎么卡住的**：10-17 18:13:53 CarPlay 热点测试把 wlp1s0 设成 NetworkManager unmanaged（`activated -> unmanaged (reason 'unmanaged-user-settings')`），当时 Wi‑Fi 弹窗正开着；18:14:25–18:18:35 一串扫描失败，18:18:38 网卡回来，开关的"忙"状态却再也没清掉。
  - **我的探针弄坏过一个对象（如实记录）**：第一版 `gdbowner.sh` 对动画任务（不是 QObject）也调了 vtable[0] 当 `metaObject()`，实际调到的是它的析构函数的一部分（之后它的 vtable 变成了基类 `QAbstractAnimationJob`）。plasmashell 没崩，但这个对象已经坏了；05:50 重启平板把它清掉了。第二版 `gdbowner2.py` 先查 vtable[0] 的符号含 `metaObject() const` 才调用。教训：没有调试符号时，在活进程里调虚函数前必须先确认类型。
- **防再犯**：`y700-checklist` 加了「熄屏省电生效」一项（2026-10-18）：读本次开机记录器里最近 30 分钟"熄屏且旋钮打开"的行，系统域低于 1 次/秒就 WARN，并报本次开机最后一次进系统域的时间和处理办法（重启 plasmashell 或重启平板）。
- 判定：零复位只说明旋钮按 E3b/E3c 拧着时，开关屏和 Wi‑Fi 流量下 APSS 不进 apps-pc 是安全的。**E3b/E3c（以及这两级下的 E4/E5）要在系统域真的能进的状态下重测**：先确认重启后熄屏时系统域约 20 次/秒，再按 §3 每级 ≥1 h。
- 记录：`runs/E0-20261018-0048/`、`runs/E4-E3a-20261018-0124/`、`runs/E3b-20261018-0219/`、`runs/E3c-20261018-0304/`、`runs/E5-E3c-20261018-0350/`、`runs/E4-E3c-20261018-0425/`（各自的 `summary.txt` 和 `cx-exp-*.txt`）；`runs/apps-pc-stuck-20261018/`（10 分钟分桶表、18:0x 起止的逐行记录、逐核中断；公开副本只保留生成脚本和 `stoptest-0540.txt`，含使用作息与系统日志的原始输出未收录）。
- **重启后又挡了一次，换了个程序（2026-10-18 06:02–06:50）**：开机后熄屏，系统域还是 0、簇 0 约 0.1 次/秒。这次 plasmashell 是安静的，挡路的是 Claude 桌面版 GPU 进程的 `VizCompositorThread`，按 120 Hz 空转，渲染进程都不动。Chrome 的同名线程也在 60 Hz 空转。
  - 只读观察 25 分钟不会自己停。最小化窗口不管用。
  - `taskset` 把这两个程序挪到 cpu6–7 后，簇 0 立刻到 26.3 次/秒，挪回来就掉回去——坐实是它们。
  - **亮屏 10 秒再熄屏后 Claude 的线程降到 0，系统域 29.6 次/秒**。推测原因：熄屏那一刻有一帧还没呈现，合成器一直等帧回调。
  - Chrome 的窗口被 Claude 整个盖住，亮屏也拿不到帧回调，仍按 60 Hz 空转，但单它一个不挡系统域。
  - 判定不变：**现在系统域能进了，可以开始重测 E3b/E3c**。
  - 记录：`runs/postboot-20261018/`（公开副本未收录含窗口标题的 `mintest-0635.txt` / `viz-0635.txt` 输出，脚本仍在）。

### 2026-10-18 白天短测（系统域真的进了：E3a / E3b / E3c 各 15 分钟）：**零复位；E3b/E3c 下 CX 还是一次没睡，功耗和 E3a 分不出来**

- 条件：y12，熄屏、电池 70 % → 69 %。Chrome 的合成线程全程按 60 Hz 空转（被盖住的窗口，不挡系统域）。
- **第一轮（`day-20261018/daytest.sh`）**：06:59 亮屏清掉 Claude 的空转。cx-when-idle 等了 10 分钟后 07:10 开 E3a，07:17:55 Claude 又复发，之后系统域 0。所以 E3a 只有前 7 分钟有效，E3b（07:35）整段系统域 0，等于白跑，E3c 没开就停了。
- **第二轮（`day-20261018/daytest2.sh`）**：每级开测前亮屏 10 秒，1 分钟后开测；两级都没复发。

| 段 | 时间 | 系统域 | 簇 0 | APSS 下电 | cxsd / aosd / ddr | `bat` 均值 |
|---|---|---|---|---|---|---|
| 旋钮全关（cx-auto 让位） | 07:00–07:10 | 0 | 0 | 0 % | 0 | 331 mW |
| 旋钮全关、Claude 空转 | 07:26–07:35 | 0 | 0 | 0 % | 0 | 351 mW |
| E3a | 07:10–07:18 | 26.2/s | 33.2/s | 34 % | 0 | 305 mW |
| E3a、Claude 空转 | 07:18–07:25 | 0 | 0.6/s | 0 % | 0 | 317 mW |
| E3b、Claude 空转 | 07:36–07:50 | 0 | 0.5/s | 0 % | 0 | 313 mW |
| **E3b** | 07:58–08:14 | 27.9/s | 35.6/s | 36 % | **0** | **275 mW** |
| **E3c** | 08:15–08:30 | 27.5/s | 35.1/s | 35 % | **0** | **286 mW** |
| cx-auto（E3a） | 08:31–08:36 | 30.1/s | 37.3/s | 39 % | 0 | 267 mW |

- **读法**：E3b/E3c 第一次在 APSS 真进 apps-pc 的状态下跑完，零复位。但 CX/AOSS/DDR 的睡眠计数全是 0，DDR 停在约 600 MHz，说明拽着 CX/DDR 的不是 APSS。E3a / E3b / E3c 的功耗差在窗口间波动（±20 mW）以内。Claude 合成线程空转每次多耗 12–40 mW。
- **判定**：现在升档没有收益，日常继续用 E3a（作者 2026-10-18 已同意）。§3 规定的每级 ≥1 h + E4/E5 + 24 h 先不做，等 CX 真能睡了再说。下一步要找出拽着 CX/DDR 的投票（`/sys/kernel/debug/interconnect/interconnect_summary` 里熄屏时还挂着带宽的节点、RPMh 的 CX 投票）。
- 记录：`runs/E3a-20261018-0710/`（含复发后那半段）、`runs/E3b-20261018-0758/`、`runs/E3c-20261018-0815/`（`summary.txt` + `cx-exp-*.txt`）；`runs/day-20261018/`（两轮脚本、每分钟的线程/电源域计数 `vizlog*.txt`、按时间段切片的 `slices.sh` / `slices-0840.txt`、复发时的线程快照 `relapse*.{sh,txt}`）。

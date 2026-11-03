# 运行时 CX 下电（apps-pc）研究综述 — Y700 Gen5 / kaanapali，内核 y9

> 状态：**研究综述，2026-10-15 夜至 16 日凌晨完成；全部只读（仓库、固件副本、上游源码与公开邮件列表），没碰平板，没跑任何实验。**
> 读者：作者，以及下一个接手"熄屏不休眠 0.42 W 还能不能再降"这题的工程师。
> 来源：同一晚三条研究线（历史梳理 / 上游动态 / 唤醒路径）各自的报告与独立复核，以及已提交的 [PROTOCOL.md](PROTOCOL.md)（实验协议）及其复核。本文只写**复核后站得住的结论**，复核推翻或修正的地方按修正后的写，并标明。所有判断都附出处：补丁号指 `linux/tb323fu-linux/kernel/patches/NNNN-*.patch`，行号指 v7.3-rc4 上游源码或仓库文件。
> 与 PROTOCOL.md 的关系：PROTOCOL 是"怎么做"，本文是"为什么、做什么、能指望什么"。两者冲突之处以本文 §3.3 的裁决为准，PROTOCOL 需要随之修订（清单在 §3.4）。

## 0. 一页纸

1. **底噪是什么**：熄屏不休眠 0.42–0.44 W（README 续航第三轮）。其中 SoC 自己"醒着"的部分来自：APSS 运行时从不进簇下电 cl5「ret-pll-off」（PSCI 0x01000054）和系统级 ss3「apps-pc」（0x0200c354，CX 下电 / AOSS 睡眠 / DDR 自刷新的唯一入口）——上游用 0118（`allow_cluster_off=0`）和 0106（系统域 `GENPD_FLAG_RPM_ALWAYS_ON`）为防静默复位有意关掉；再加常开外设：由 AP 持有的 PCIe/Wi‑Fi 链路（4 小时只进 31 次 L1.2）、~~CDSP 持着 XO~~（10-16 更正：不持，见 ALWAYS-ON §1）、蓝牙 UART 时钟、USB3 PHY GDSC、UFS ICE 时钟。`qcom_stats` 里 apss/cxsd/aosd/ddr 计数全 0 **是 0106 的必然结果**，不是另一个 bug（§1.3）。
2. **能省多少，要说实话**：s2idle（CX 塌缩）约 0.07–0.13 W 是物理下限，运行时 Wi‑Fi 关联着不可能到那里。按现状熄屏每秒 285–400 次唤醒，ss3 驻留率估计只有 10–25%，**近期收益 0.03–0.08 W**；唤醒压到 50 次/秒以下且 CX/DDR 真的跟着塌，才有 0.15–0.27 W（满电熄屏 83 h → 110–170 h）。簇下电本身不值钱（上游实测 658/659/621 mW 无差别）。
3. **复位问题**：两类静默复位（0106 记录的"核卡在 retention 不醒、10 秒后复位"，0118 记录的"CPU_SUSPEND 不返回、与簇关/开对齐"）全部来自上游作者那台 ROW .104 固件的机器；**本机现为国行 ZUXOS 088 底层固件，`allow_cluster_off=1` 从未在本机试过**。内核在这条路上几乎不做事（三个状态都是 PSCI retention 型、不保存上下文、不编程唤醒时间），所以根因大概率在固件/hypervisor 的唤醒路径或 Oryon 核的勘误，而不是我们能"改对"的配置。排名第一的可验证假说是**同家族 X1E 已公开复现的 DC ZVA × CL5 勘误**（§2.4 H2），但它有两条硬反证（安卓同固件稳定；本机是 Oryon v3，MIDR 部件号不同），只能当"便宜就能排除的候选"。
4. **计划**：先只读审计与文档合并（不碰内核）→ E0 取证演练与基线 → E1 在本机固件上重做 0118 对照、让飞行记录器抓到第一次复位 → E2 按 x1e-crash 序列做 DC ZVA 判别 → y10 加 `allow_system_off` 旋钮 → E3a/b/c 分级放开系统域 → E4/E5。每一级单变量、有中止判据、无人值守一律 `download_mode=off`。**并行、零风险、收益更确定的另一半：把唤醒率从 300/s 压到 50/s（tailscaled、Claude 桌面版、PowerDevil、RTC 闹钟）。**
5. **我们修不了的**：TZ/Gunyah/AOP/CPUCP 固件里的缺陷；安卓 PCIe DRV（`cesta`）与 `pcie-pdc` 不在主线——即使复位解决，Wi‑Fi 关联时 CX 是否真塌仍是未知；Lenovo 不会为 Linux 更新固件。

---

## 1. 醒着的底噪由什么构成；运行时 apps-pc 实际能省多少

### 1.1 现状数字（全部来自电池放电实测或 y9 审计）

| 项 | 数值 | 出处 |
|---|---|---|
| 熄屏不休眠（y7/y8/y9，Wi‑Fi 省电补丁 1041 后） | **0.42–0.44 W**，满电约 83 h | README 续航第三轮、永不休眠段 |
| 熄屏 + Wi‑Fi rfkill | 0.36 W（1041 之前基线 0.55 → 0.36，−0.19；1041 后 Wi‑Fi 残余约 0.06 W） | README 熄屏对照第二轮 |
| s2idle，CX 塌缩 | 18–35 mA ≈ 0.07–0.13 W（上游，4.8 h） | 0106 提交信息 |
| 簇下电 允许/拒绝/允许 | 658/659/621 mW，噪声约 20 mW → 无差别 | 0118 提交信息；`docs/hardware-status.md:120` |
| 熄屏唤醒率（y9） | idle 进入 285/s；中断 300–400/s：`arch_timer` 160、IPI1 86、`apss_cpucp_mbox` 11；用户态 tailscaled ≈35/s、Claude 桌面版 22/s、PowerDevil 10/s | README 续航第三轮 + 零风险 A/B 段 |
| PSCI 域（审计 22:47，uptime 1494 s） | `power-domain-cluster` Rejected 58147、`cluster1` 42201（≈39/28 次每秒）、`power-domain-system` Usage 0 Rejected 0 | `cx-audit-2247.txt` pm_genpd 段 |
| `qcom_stats` | apss / cxsd / aosd / ddr 全 Count 0；adsp 10094、adsp_island 8838、soccp 7390 次；cdsp 开机 13.4 s 后一直在睡 | `cx-audit-2247.txt` qcom_stats 段；`qcom_stats.c:99-106` |

复核确认 `qcom_stats` 的 0 是真的 0：debugfs 文件名 `aosd`/`cxsd`/`ddr` 是驱动从 SRAM 每条记录首 4 字节读出的 ASCII 标签（`qcom_stats.c:260-280`），标签正确即偏移正确；`apss` 走 SMEM 631 也是 0，与 pm_genpd 系统域 Usage 0 吻合。

### 1.2 底噪的组成（分层）

**A. APSS 醒着（本题主体）**。每核只有 WFI 和 retention（0x4）两个状态；两个簇域每秒被拒 39/28 次，说明调度器几乎每次都想下电而被 0118 挡回；系统域因 0106 根本不被尝试。CPU 核本身在 retention 里耗电很少，大头是簇 PLL、L3/DSU、GIC、APSS 电源轨、以及被 APSS 活跃状态钉着的 CX 轨和 DDR 时钟——这些只有 ss3 能释放。

**B. 常开外设与时钟（审计 22:47，亮屏充电，熄屏电池态尚未重采）**：
- PCIe/Wi‑Fi：`gcc_pcie_0_gdsc on (perf 256)`、`gcc_pcie_0_phy_gdsc on`、全部 `gcc_pcie_0_*` 与 `pcie0_pipe_clk` 125 MHz 开着；链路由 AP 持有，L1.2 4 h 仅 31 次（L1.1 163 万次）。安卓用 DRV 状态机（vendor `pcie@1c00000`：`qcom,drv-name="cesta"`、`drv-l1ss-timeout-us=5000`、`l1-2-th-*`）和独立 `pdc@b370000`「qcom,pcie-pdc」在 apps-pc 期间托管链路；主线 `pcie-qcom.c` 只有 `suspend_noirq`（2340-2394 行）在系统睡眠降票，probe 里 `pm_runtime_get_sync` 后再不 put（2159-2160），运行时永远 active。板级 `baldur-wifi.dtsi:160-174` 把 `vreg_l3k_1p2` 设 always-on、S1J/S2J 892 mV 常驻（注释：这里没人经 PDC 拉它们）。
- ~~CDSP 持 `bi_tcxo`（`26300000.remoteproc` 的 'xo'，enable_cnt 2）→ XO 常开。~~ **2026-10-16 更正：不成立。** `bi_tcxo` 的 enable_cnt 2 正好是两个使能的子时钟（`dsi0vco_clk`、`bi-tcxo-div2`）贡献的；`clk_summary` 的 consumer 列只是 `clk_get()` 过的用户，不是使能者。PAS 驱动在 handover 后已 `clk_disable_unprepare(xo)`（CDSP 的三个代理域 nsp/mxc/cx 在审计里也都 suspended）。CDSP 没有任何用户、开机 13 s 后一直睡；逐项裁决见 [../ALWAYS-ON.md](../ALWAYS-ON.md) §1。
- 蓝牙 UART：`gcc_qupv3_wrap3_s5_clk` 51.2 MHz（`1994000.serial`）常开。**2026-10-16 补**：geni 串口有 runtime PM，但引用在 open 期间一直持着（hci0 Powered = serdev open）；hci_qca 的 IBS 投票 `__serial_clock_on/off` 是空存根（linux-next 仍是），DT 的 uart18 没有 RX 唤醒中断。关蓝牙实测在噪声内（0.54 vs 0.55 W）；真修要三层内核工作，见 [../ALWAYS-ON.md](../ALWAYS-ON.md) §3。
- UFS：`gcc_ufs_phy_gdsc on (perf 56)`、`gcc_ufs_phy_ice_core_clk` 403 MHz（`1d88000.crypto`）。**2026-10-16 补**：ICE 时钟跟 UFS 主机 runtime PM 走（`ufs_qcom_suspend()` 末尾关，不跟 150 ms clk gating），审计时脚本正在写盘所以主机 active 是必然，熄屏电池态要重核；真问题是 `1d88000.crypto` 没有 runtime PM（genpd 里 `unsupported`）把 `gcc_ufs_phy_gdsc` 钉死——主机挂起了域也关不掉，sm8550/8650/8750 同病（binding 要求 power-domains，驱动没跟上）。草案补丁见 [../ALWAYS-ON.md](../ALWAYS-ON.md) §4。
- USB：控制器 `a600000.usb` 已挂起（`gcc_usb30_prim_gdsc off`），但 `gcc_usb3_phy_gdsc on`、`88e8000.phy active`——~~审计时在充电，需拔电熄屏复查（0098 的 DP runtime 引用是嫌疑）~~ **2026-10-16 更正：与充电无关，拔电也是 on，不必复查。** 原因是 qmp-combo probe 里的 `pm_runtime_forbid()`、同域里没有 runtime PM 的 `aux_bridge.aux_bridge.0`（genpd 永远关不掉带 unsupported 设备的域），以及 0059 把该 GDSC 改成 `PWRSTS_RET_ON` 后 `gdsc_disable()` 根本不切电（`gcc_usb30_prim_gdsc off-0` 同理只是记账）。PHY 自己的时钟在 dwc3 挂起时已关，0098 已生效（DP 控制器 suspended）。见 [../ALWAYS-ON.md](../ALWAYS-ON.md) §2。
- LPASS 6 个 codec 时钟 19.2 MHz；`sleep-clk`（看门狗）。**2026-10-16 补**：这些是 q6prm 对 ADSP 的软件投票，不是 GCC 分支；五个 lpass macro 全 runtime-active（各自 100 ms 就会自动挂起），持有者只能是 soundwire 主控（3 s autosuspend）或开着的 PCM/麦克风，离线定不了，`always-on-check.sh` 5a 段现场看（[../ALWAYS-ON.md](../ALWAYS-ON.md) §5a）。
- 显示（仅亮屏）：`mmcx on (perf 384 = TURBO)`、disp_cc 全套；熄屏后 0032/0050 应让 dispcc/MMCX 掉电，审计未覆盖熄屏态。
- 唤醒源：`rtc@6100` 在 1494 s 内 61 次事件（~~有东西在设 RTC 闹钟~~ **2026-10-16 更正**：更可能根本没有闹钟，是 61 次失败的 `rtc_set_time()`——`CONFIG_RTC_SYSTOHC=y` + chrony `rtcsync` 让内核在每次 `adjtimex()` 后试写 RTC，pm8xxx 没有 nvmem 偏移返回 -ENODEV，但 `rtc_set_time()` 无条件 `pm_stay_awake()` 计一次，0.08 ms/次与 total_time 5 ms 吻合；`always-on-check.sh --rtc 90` 一次定案，见 [../ALWAYS-ON.md](../ALWAYS-ON.md) §5b）、`qcom-battmgr-bat` 33 次。
- 稳压器：审计脚本过滤词 `enabled` 没命中任何行，常开轨情况**未取到**（`cx-audit.sh` 要改成直接打印 `regulator_summary` 前 60 行）。

**C. 用户态**：熄屏时 CPU 0.2–0.4%，冻结全部桌面应用只省 0.01 W（README 第二次实测 I/J 档）。用户态作为**耗电**已不重要，但作为**唤醒源**决定 ss3 的驻留率（§1.4）。

### 1.3 为什么 cxsd/aosd 全 0 是设计使然

`apps_rsc`（`rsc@18900000`）在 DT 里挂在 `system_pd` 下（`kaanapali.dtsi:5835`；vendor 同样挂 `cluster-pd2`）。rpmh-rsc 没注册 cpu_pm 通知器，而是走 genpd 通知器：系统域 `GENPD_NOTIFY_PRE_OFF` 时 `rpmh_rsc_pd_callback()` 若 ACTIVE TCS 不忙就 `rpmh_flush()` 把缓存的 SLEEP/WAKE 投票写进 TCS（`rpmh-rsc.c:943-953, 1119-1140`），固件在进入最深态时执行它们。0106 给系统域加 `GENPD_FLAG_RPM_ALWAYS_ON` 后，`genpd_power_off()` 在入口直接返回（`pmdomain/core.c:966-969`），不发 PRE_OFF、不 flush、不下发 0x0200c354 的 CPU_SUSPEND；只有 s2idle 的 `genpd_sync_power_off()`（`core.c:1404-1412`，只查 `ALWAYS_ON` 不查 `RPM_ALWAYS_ON`）会走系统态。所以 AOP 在运行时永远看到 APSS 活跃，cxsd/aosd/ddr-LPM 不可能计数；0106 自己也说 s2idle 4.8 h 里 CX 一直塌着。**结论：运行时 CX 下电的唯一前提是放开 ss3，也就是解决复位；在那之前任何驱动/用户态的投票清理都不会让 cxsd 动。**

另一个相关事实：`cx` 域在 APSS 侧 **off-0**（`cx-audit-2247.txt:112`）——APSS 对 CX 没有任何投票；PCIe/UFS 的 OPP 投票停在各自 GCC GDSC（`gcc` 节点无父域，`kaanapali.dtsi:542-556`，sm8750 同样），传不到 rpmhpd。所以一旦 ss3 放开，CX 塌不塌完全由 AOP 按**其它子系统**的票决定，APSS 既帮不上也挡不住（这是 §3 E3b 风险的具体形态）。**2026-10-16 补**：linux-next 已给 kaanapali 的 `gcc` 节点加 `power-domains = <&rpmhpd RPMHPD_CX>`（infiniti-mainline 的补丁上游化，Linus 树 7.3-rc7 还没有）——升到 7.4 后 GDSC 的投票会传到 CX，本段与 E3b 的风险形态要重写；`tools/upstream-check.py` 的 `gcc-cx` 条目盯着它进 Linus 树的时间。

### 1.4 运行时 apps-pc 实际能省多少

**驻留率模型**（PROTOCOL §5，复核重推导无误）：ss3 要求 8 核同时空闲且预计空闲 > 10.15 ms（min-residency），每次进出 2.8 + 4.4 ms。把系统级空闲间隙当指数分布（均值 m，门限 t = 10.15 ms，开销 c = 7.2 ms），睡着比例 ≈ e^(−t/m)·(1 + (t − c)/m)：

| 唤醒率（次/秒） | 理想驻留率 | 功耗估计（地板 0.10 W） | 功耗估计（地板 0.20 W，Wi‑Fi 关联、PCIe L1.x） |
|---|---|---|---|
| 300（现状） | ~9–10% | 0.39 W | 0.40 W |
| 100 | ~47% | 0.27 W | 0.32 W |
| 50 | ~69% | 0.20 W | 0.27 W |
| 20 | ~86% | 0.15 W | 0.23 W |

两列地板的含义：0.10 W 是 s2idle 的数（Wi‑Fi 进 WoW、PCIe 进 L2），运行时 Wi‑Fi 关联着、链路在 L1.x、固件只在有数据时叫醒主机，地板只会更高；0.20 W 是**猜测**，没有本机或同代 SoC 的公开数字。安卓同机熄屏的 apps-pc 驻留率没有公开数据（任务前提"安卓运行时能进这些状态"来自 vendor DT 的能力描述，不是测量——见 §5 开放问题 1）。

**两道闸，不是一道**（复核对 PROTOCOL F3 的修正）：
1. APSS 进 ss3（本题）。
2. 进了 ss3 之后 CX/DDR 是否真塌：(a) 今天因 0106 从未刷过 RPMh sleep set，AOP 在 APSS 睡着时会看到什么投票无人知道；(b) icc 里带 `QCOM_ICC_TAG_ALWAYS` 的路径同时进 sleep set——审计里 `pcie-mem` 峰值 1.97 GB/s、memlat 的 `llcc_mc`/`ebi` 平均 3.7 GB/s，`pcie-qcom` 只在 `suspend_noirq` 才降到 1 kB/s；(c) 主线没有 PCIe DRV，链路由 AP 持有。**很可能出现 `apss` 计数涨而 `cxsd`/`ddr` 不涨**，收益只剩 APSS 那份（估计 0.05–0.1 W，猜测）。

**收益区间**：近期（唤醒率不变）0.03–0.08 W；条件性上限（唤醒 <50/s 且 CX/DDR 跟着塌）0.15–0.27 W；物理上限约 0.3 W（0.42 → s2idle 的 0.10–0.13）。**最有把握的顺序：唤醒率治理（零风险）> ss3 分级放开 > 簇下电本身。**

### 1.5 与同代设备对照（预期管理）

- 主线高通设备"醒着进 cxsd"的公开证据为零：SM8550 掌机（portareos #505/#506、ROCKNIX #3126）醒着熄屏 1.015 W、cxsd/aosd/ddr 全 0，连 s2idle 也进不去（GMU/crypto 无驱动卡 sync_state、PCIe 投票）；X1E（justririll/x1e-sleep）要 8 个额外补丁才在 s2idle 到 cxsd+aosd 99.7%、0.25 W（Windows Modern Standby 0.23 W），且作者称**运行时从首次 s2idle 后进 DRIPS(ss3) 会挂死 SoC**，Windows 亮屏时 PEP 否决 DRIPS 只允许更浅的 SS1（0x02000154）；jglathe #94（X1P42100，7.2.5 + PDC 系列 + Ulf v4 + domain_ss3）系统域 s2idle 下电了但 cxsd/aosd/ddr 仍 0。
- 因此我们 0.42 W 已经低于能找到的所有主线高通设备的"醒着地板"（但没有 X1E 熄屏醒着的数可比），剩下的 0.3 W 是 s2idle 级的收益，要靠 §2 的复位问题解决才碰得到。

---

## 2. 复位问题

### 2.1 时间线（全部为上游作者在 ROW 18.0.12.104 固件上的记录，除注明外）

| 日期 | 事件 | 出处 |
|---|---|---|
| 09-26 | **0031** 把 CPU6-7 拆成独立簇域（照 vendor 拓扑）。拆前 8 核一个簇域，固件拒绝系统域约 200 万次、只进约 1000 次；拆后簇/系统域空闲占比 98%/97%/95%、115 次拒绝。**cl5/ss3 从此才被高频进入，后面所有复位都在它之后**。推断（非证据）：复位是被 0031 暴露的，不是它引入的——vendor 拓扑与 0031 逐节点相同。 | 0031:7-16,41-50；PROVENANCE.md:56 |
| 09-26 | 同日一批 s2idle 修复：0049（PCIe 根口 D0/WCN7860 D3hot → 同步外部中止 panic）、0058（ath12k panic notifier 等 MHI 永不返回）、0059（USB GDSC OFF_ON → HC died）、0060/0061（s2idle 中拔 DP → 挂起的 I2C）、0062（eUSB2 唤醒极性）、0032/0050（dispcc 从不挂起、DSI PHY 钉 XO）。**均为 s2idle 路径，作者永不休眠，现在不走。** | 各补丁提交信息 |
| 09-27 | 0078 WAKE# 极性（每次 s2idle 2.5 s 后被 gpio104 唤醒）；**0103**：noirq 阶段 -EACCES 时直接拿引用开 GDSC "crashed the SoC on suspend"（上游明确记录的一次 SoC 级崩溃触发条件：供电域可能已关时碰寄存器）；0104 xHCI 掉电路径 | 0078:7-11；0103:18-25；0104:15-42 |
| 09-29 | **0106**：熄屏空闲中或正在亮屏时静默复位，无 printk/pstore，直接进固件 dump 模式；显示开/关 + s2idle 循环约 1/25。drgn 读全 DDR dump：所有 CPU 空闲，cluster0 的 CPU0-4 在 20 ms 内进 retention（`cpu-sleep-0`，PSCI 0x4）后再没离开——`call_single_queue`/`ttwu_pending` 积压 IPI、hrtimer 早已到期——**CPU5-7 继续跑约 10 s 才复位**。对照各 60 周期（禁 CPU retention / 去两个域态 / 只去系统态）合计 0/180。采用：对 `lenovo,baldur` 的 `power-domain-system` 加 `GENPD_FLAG_RPM_ALWAYS_ON`；60 周期干净，s2idle 4.8 h CX 全程塌缩。作者自评：板级 workaround，根因在固件或唤醒路径。 | 0106:7-28,47-56；PROVENANCE.md:131 |
| 10-03 | **0118**：系统态只在 s2idle 用之后，纯空闲长跑仍复位。cluster0 的 CPU 进 `CPU_SUSPEND` 后不返回，丢失时刻与 cluster0 被最后一核关掉/打开对齐。`psci_pd_power_off()` 对簇域返回 -EBUSY：3 h 零崩溃（562364 次拒绝）vs 允许时 78 min 两次（≈1.5 次/h；3 h 零次为巧合的概率约 1%）。功耗 658/659/621 mW 无差别。作者明示未知是 OSI 簇关/开竞态还是固件（PSCI 实现或 hypervisor）缺陷。同日试过 pseudo-NMI 内核（每次在 initramfs 前挂死）。README 提到开发机上有 idle flight recorder 和簇路径延迟 knob，结论未写进系列。 | 0118:7-38,83-105；kernel/README.md:144,150-157；docs/custom-kernel.md:58 |
| 10-07/08 | 0128（UFS MCQ 过不了 s2idle）、0129（UFS 时钟缩放死锁）——有 panic 痕迹，与静默复位不同类 | 0128:7-13；0129:18-22 |
| 本机 | t47 在 ROW .104 开发；本机曾 OTA 到 ROW .187（换了 xbl/tz/hyp/aop/cpucp 等 54 个分区）→ t47 在其上 fbcon 切换后约 50 ms 整机挂死、7–8 s 看门狗复位（issue #9，Open，作者 1 条回复）；10-11 刷 ColorOS 17 后本机底层为国行 ZUXOS 2.0.12.088，t47 直接能启。**本机 tz/aop/cpucp/xbl 与上游作者机器不同版本；`allow_cluster_off=1` 从未在本机试过**（README:285 的数字是转述上游）。 | README:57,99,272,285,346 |
| 本机 10-13 15:56 | 5 GHz 关联循环中整机硬复位（`failed to flush transmit queue` 后），当时簇态已被拒绝——WLAN 固件/MHI 拖死 SoC 后看门狗复位，**与簇空闲无关** | README Wi‑Fi 一节 |
| 本机 10-15 03:41 | 5 个排查脚本同时 ssh 后掉线，卡 900E 到 11:04（73%→37%）。rawdump 的 `lastkmsg.log`：164 条 `arm-scmi.1 timed out in resp`、36 次 vblank timeout、17 次 GMU fenced write 延迟、ADC/battmgr -110——所有固件路径同时挂死 = AHB/NoC 总线挂死；头号嫌疑是读 `debugfs pcie@1c00000/link_transition_count`（5 个 PARF `readl_relaxed`），但同脚本还向 Wi‑Fi 固件发了命令，触发行已被刷出缓冲，**嫌疑最大、未查实**。与空闲复位无关。 | `crash-0341-lastkmsg.log`；README:845-850；`pcie-qcom.c:1829-1849` |
| 本机 10-15 | `y700-dumpmode-off.timer` 开机 3 min 后关 download_mode → 静默复位 = 直接重启（前 3 分钟仍会卡 900E）（11-01 更正：y16 之前只对内核 panic 成立；SDI 没关，固件复位照样卡 900E，见 README「10-31 21:04 死机」；y16 起写 off 也关 SDI，见 README「内核 y16」）；22:47 只读审计；PROTOCOL 与工具提交（738c086） | `linux/power/y700-dumpmode-off.*`；本目录 |

### 2.2 两类事故要分开统计（两份研究都淡化了的关键细节）

- **0106 型**：drgn 现场里 **CPU5（同属 cluster0）还在跑**，所以 cluster0 当时不可能在 cl5；卡住的 CPU0-4 请求的只是 CPU 级 0x4 retention（OSI 下只有最后一核才请求复合态，`cpuidle-psci.c:64-107`）。这把该事故限定为：**某次 ss3/cl5 退出之后，个别核的唤醒通道失效**（到期的定时器是电平 PPI、IPI 是 SGI，正常硬件必然拉起 retention 核），然后约 10 s 后 SoC 被复位。它发生在 ss3 还允许运行时使用的阶段，触发器是开关屏 + s2idle 循环。
- **0118 型**：ss3 已封、只有簇态时，纯空闲长跑，`CPU_SUSPEND` 不返回且与 cluster0 的簇关/开时刻对齐。
- 两者都"静默"（无 printk、无 pstore 记录），这是它们区别于其它故障（0051/0110 的 TZ err-fatal、0114 的 DOG、0116/0129 的 hung task panic 都有痕迹）的共同特征，但静默本身不区分假说（§2.6）。
- 0106 说"只去系统态 60 周期干净"与 0118 说"系统态只在 suspend 用后空闲仍复位"不矛盾：触发方式不同（60 个开关屏周期 vs 78 分钟纯空闲），样本量不同。**作者的场景（熄屏不休眠几十小时）更接近 0118 的纯空闲长跑。**

### 2.3 内核在这条路上做什么、不做什么（唤醒路径事实，全部核对过源码）

- 三个状态 0x4 / 0x01000054 / 0x0200c354 的 StateType 位（bit30，旧格式 bit16）都是 0 → `psci_power_state_loses_context()` 为假 → `psci_cpu_suspend_enter()` 走 `psci_ops.cpu_suspend(state, 0)` 直接 SMC（`psci.c:94-101, 501-525`），**不保存/恢复 EL1 通用上下文**（不走 `cpu_suspend()`/`__cpu_suspend_exit()`）。apps-pc 显然断 APSS 电（GIC 也在 APSS 里），所以 CPU/GIC 上下文的保存恢复全在固件（TZ，经 Gunyah）。vendor DT 用同样的参数值，安卓同样依赖这套固件管理。
- 内核确有一条**每核**进出路径（复核对 F1 的修正）：`__psci_enter_domain_idle_state()` 每次都调 `cpu_pm_enter()/exit()`；因 `GICD_CTLR.DS=1`（dmesg:121），`gic_cpu_pm_notifier` 在进入时 `gic_enable_redist(false)`（置 `GICR_WAKER.ProcessorSleep`）、退出时清它并重写 ICC_* 寄存器（`irq-gic-v3.c:1479-1492`）；另有 arch_timer 的 CNTKCTL、PMU、FPSIMD 通知器。**ProcessorSleep=1 意味着 retention 中的核只能靠 GIC WakeRequest → APSS 电源控制器这条固件/硬件路径唤醒**——这正是 0106 现场最直接的嫌疑环节。安卓同机是否也以 DS=1 运行、redistributor 睡眠握手是否由内核做，是一个可从 vendor 内核 dmesg 核实的差异点。
- 最后一核的链：menu/TEO 选 idx1 → `psci_enter_domain_idle_state()` → `pm_runtime_put_sync_suspend` → `genpd_power_off(cpu_pd)` → 递归父域：簇域由 `pm_domain_cpu_gov.cpu_power_down_ok()` 判定（域内 CPU 最早 hrtimer、QoS、`cpus_peek_for_pending_ipi`，`governor.c:347-424`）→ `psci_pd_power_off()`（0118 在此 -EBUSY）→ 系统域（0106 在 `core.c:967` 早退；否则 `_genpd_power_off()` 先发 PRE_OFF → `rpmh_flush` → `rpmh_rsc_write_next_wakeup()` 因 `CONTROL_TCS=0` 立即返回，`rpmh-rsc.c:815`）→ 复合态 SMC。
- **内核不编程唤醒时间**（CONTROL TCS 为 0，vendor 同样为 0 加一个 type 4 fast-path TCS）、**不启用 broadcast 定时器**（DT 无 `local-timer-stop`，vendor 也无；`dt_idle_states.c:80-81`），所以 ss3/cl5 中的定时器唤醒必须由固件读各核 CNTP_CVAL 自行安排；外设唤醒只能经 PDC（`tlmm wakeup-parent=<&pdc>`；pdc-ranges 不含 timer frame0 SPI 8、不含 PCIe MSI SPI 140-148，`kaanapali.dtsi:3687-3715`）。PCIe/UFS 的 MSI 走 ITS LPI。
- 复核对 D1 的修正：上游把 retention 作为 `cpu_pd` 的 `domain-idle-states`，但那些节点 compatible 是 `arm,idle-state`，genpd 的 `genpd_iterate_idle_states` 只认 `domain-idle-state`，CPU 域解析出 0 个状态、不挂 governor；retention 只是经 `of_get_cpu_state_node` 进了 cpuidle 驱动。vendor 把 `ret` 直接挂在 CPU 节点。**两种写法在 PSCI 参数和 genpd 记账上都等价**，不是差异。
- 运行层级：`CPU: All CPU(s) started at EL1`（dmesg:181），Gunyah 在 EL2；vendor DT 有 `gunyah_hyp_region@80000000`、`/firmware/sdei method=hvc`。**安卓与 Linux 同层、同 hyp、同 OSI 拓扑，所以 hypervisor 本身不是差异点**，但 CPU_SUSPEND 经 EL2 转手、GIC 是 vGIC、定时器是 virt（dmesg:133,478），"唤醒没送到"若发生在 EL2，EL1 一无所见。x1e-sleep README 还提到"secure firmware 从 EL1 定时器算 APSS 唤醒截止期"。
- 本机 MIDR `0x512f0021`（dmesg:1）= implementer 0x51、variant 2、**part 0x002**、rev 1，即 Oryon v3；上游 `cputype.h:134` 只有 `QCOM_CPU_PART_ORYON_X1 = 0x001`，`cpu_errata.c:1012-1018` 唯一的 Oryon 条目是 CNTVOFF 勘误，只匹配 X1。

### 2.4 假说排名

排名依据：有没有旁证、能不能用本机实验判别、与两类事故现场的吻合度。置信度是对"它是本机复位根因"的置信度。

| # | 假说 | 置信度 | 判别实验（§3） |
|---|---|---|---|
| H1 | 固件/hyp 在簇或系统态进出的竞争窗口里丢掉 retention 核的唤醒（GIC WakeRequest→电源控制器握手 / CPU_SUSPEND 不返回） | 中 | E1 在本机固件重跑 + 飞行记录器抓尾部 + 复位源寄存器；`cpu_dma_latency` 与 per-簇 `state1/disable` 隔离；临时加 cl4 0x01000044（ret 不关 PLL）隔离 "pll-off" |
| H2 | Oryon 的 DC ZVA × CL5 勘误（X1E 已公开复现） | 低–中（唯一有旁证） | E2 改成 x1e-crash 序列；阳性则移植 DZE 关闭勘误到 part 0x002 做决定性对照 |
| H3 | ss3 时 AOP 按 sleep set 降档（XO/CX/带宽）而某 DMA 主设备仍在工作（亮屏静止扫描中的 MDSS、PCIe 流量、UFS） | 中（仅对 ss3 型） | E3a/b/c 用 `qcom_aoss prevent_*` 分级；亮屏静止 vs 熄屏对照；`interconnect_summary` 前后 |
| H4 | 不经 PDC 的中断（ITS LPI：PCIe/UFS MSI；GIC 直连 SPI）在 apps-pc 期间丢失 | 低（仅对 ss3 型） | 审计 `/proc/interrupts` 芯片列分类；E5 Wi‑Fi 流量 vs rfkill 对照 |
| H5 | 固件版本相关（ROW .104 的 TZ/hyp/AOP/CPUCP 缺陷），本机 088 可能不复现或表现不同 | 中（作为前置未知） | E1 本身；实验记录里写明本机 tz/aop/cpucp 版本 |
| H6 | 固件上下文恢复清单漏掉 Linux 在用、安卓不用的寄存器（SME/MPAM 等）→ 恢复后跑飞 → 看门狗 | 低 | 复位源寄存器能区分"立刻复位"与"跑飞后被咬" |
| H7 | Gunyah EL2 层（vCPU 调度、唤醒转发、安卓有 trust_ui_vm/oem_vm 而 Linux 下没有） | 低；EL1 不可观测不可修 | 无直接实验；只作为根因候选层记录 |

**H1 的证据与反证。** 为：0106 现场（hrtimer 到期、IPI 积压、核不醒、同簇另一核还在跑）；0118 的"与簇关/开对齐"；内核不保存上下文、不编程唤醒、每次进出都把 ProcessorSleep 置 1；10 s 后复位对不上 Linux 看门狗（§2.6）→ 复位源在固件侧。反：安卓同固件同拓扑运行时进 cl5/ss3 不复位，说明固件**能**正确处理某种时序；上游在开发机上加过"簇空闲路径延迟 knob"却没把结论写进系列（kernel/README.md:153）——若延迟有用他们大概会说。安卓的差异（§2.5）里 QC LPM governor 的预测/偏置（`pred-prem-cnt=2`、`sample-invalid-time` 40 ms、`use-cluster-bias-timer`）可能恰好避开了触发窗口（猜测）。可借鉴的先例：hamoa 的簇域同时有 cl4 0x01000044（ret、不关 PLL）与 cl5 0x01000054；kaanapali 只有 cl5——给两个簇域临时加 0x01000044，`pm_genpd` 的 Rejected 可看出固件是否接受，并隔离 "pll-off" 是否是因子（比改 ss3 StateID 位更有先例）。

**H2 的证据与反证。** 为：icecream95/x1e-crash（2026-08 推送）用**单线程、不绑核**的序列让 X1E80100 挂死后复位——`dc civac` 清掉两行 → `dc zva` 一行 → 经另一行的依赖读回 → 每 60 轮 `usleep(10 ms)` 让**本簇**进 CL5（注释明说时长要超过 cluster CL5 的 min-residency，CL5 是"第一个需要清 L2 的簇态"）；去掉 cl5 后四台 X1E/X1P 笔记本稳定，Dev Kit（只有 PC 模式）要 `cpuidle.off=1`；Jens Glathe 的 RFC（20260604-dc_zva_mitigation，去掉 hamoa 三簇的 cluster_cl5）零回复、dormant；x1e-sleep 树外带 `WORKAROUND_QCOM_ORYON_DC_ZVA`（清 `SCTLR_EL1.DZE`、traps.c 模拟 EL0 的 DC ZVA、clear_page/memset/mte 无条件绕开 ZVA，匹配 `MIDR_QCOM_ORYON_X1`）后重新开 CL5；Launchpad #2158523（T14s 使用中硬复位、pstore 空）Confirmed 无解；v7.3-rc4/rc5 hamoa.dtsi 仍开 cl5 且无 cpu_errata 规避。与本机的吻合：同名同参数 cluster_cl5；同为 Oryon；复位静默无 pstore；0118 的"与簇关/开对齐"。反：(1) 本机 part 0x002（Oryon v3）≠ X1 的 0x001，不同代核、不同固件；glymur/sm8750/kaanapali 主线 DT 都在运行时开 cl5+ss3，没有公开复位报告（但用户基数极小，不能当证据）；(2) **安卓在同固件上运行时进 cl5，而 bionic memset 大块同样用 `dc zva`**；x1e-crash README 也说 Windows 保持 DZE 开启却不受影响、手段未知——除非下游内核另有处理，否则需要解释；(3) vendor 把 kaanapali 的 cl5 命名为 "ret-pll-off"（簇保持 retention、PLL 关），唯一的断电态是 ss3 "apps-pc"；若 kaanapali 的 cl5 保留 L2，icecream95 的机理并不显然可迁移；(4) 0106 现场（CPU5 在跑、簇 0 未在 cl5）与 DC ZVA 无关。**结论：当作"便宜就能排除"的候选；E2 的序列必须按 x1e-crash 改（见 §3.4），cpu0 连续循环 DC ZVA 的设计会阻止簇 0 进 cl5，与复现机理相反。**

**H3 的证据与反证。** 为：0106 的触发器是开关屏 + s2idle 循环且"正在亮屏时"也复位；Lenovo C630（SDM850）2026-04 的报告同形（display 没及时 probe 时簇 idle 会复位，Dmitry 把 `psci-suspend-param` 从 0x4100b244 降到 0x41003244，Konrad 建议用 QMP `{class: cx_mol, res: cx, val: mol}` 定位，未合入）；rpmh 只对"睡时要变"的资源下命令（`is_req_valid` 要求 sleep≠wake，`rpmh.c:438-442`），regulator 只投 ACTIVE 不会被撤，会变的是 clk-rpmh（有 `_ao` 消费者时 XO sleep 位为 0）、rpmhpd（`_ao` 域 sleep=0）、icc 的 ACTIVE_ONLY 路径（kaanapali 所有 QUP 的 APPSS→SLAVE_QUP 路径是 ACTIVE_ONLY，`kaanapali.dtsi:611-969`）。反：**0118 的复位发生在 ss3 已封、簇域上没有任何带通知器的设备的情况下，H3 解释不了 0118 型**；"XO 投票竞争"在 genpd 锁下不可能（能写 rpmh 的 CPU 在跑，系统域就不能 off；`ctrlr_is_busy` 又挡在飞请求）。真正的风险形态是"亮屏画面静止、全核 idle 进 ss3、MDSS 仍在扫描"。

**H4。** apps-pc 中 GIC 掉电，能唤醒 APSS 的只有 PDC 映射的 SPI/GPIO 与固件的定时器；本 DT 的 pcie0 MSI（SPI 140-148）不在 pdc-ranges，WCN7860 WAKE#（gpio104，0078 修成低有效）经 tlmm→pdc 可以唤醒；MHI/ath12k 的 MSI 是 ITS LPI，apps-pc 期间到达会丢失、挂起还是由固件保存不可知。vendor 多出 `pdc@b370000`「qcom,pcie-pdc」正为此而设，主线没有。PDC 本身：高通 pass-through 系列 irqchip 部分已在 v7.3-rc4，cover letter 说在 kaanapali 上测过，但 SCM 切模式只对 `qcom,x1e80100-pdc` 做（`qcom-pdc.c:699-727`）；本机无 GPIO 中断风暴 → 推断出厂即 pass-through（推断非文档）。反：同样只对 ss3 型有效。

**H5。** 上游 0106/0118 的全部统计在 ROW .104；本机 .187 时 t47 50 ms 挂死（issue #9）说明这块板对固件版本极敏感；本机现跑 088。`fastboot getvar all` 的 version-baseband/bootloader 为空，版本只能从安卓 getprop 或分区字符串取。这是 E1 的"零假设"：**先确认复位在本机固件上是否复现、频率如何**，再谈根因。

### 2.5 安卓同机不同结果：vendor DT 里有、主线没有的东西

vendor_boot blob 12（CanoeP v2，msm-id 0x295 v2.0 = 本机 SM8850P）与 dtbo blob 47（board-id 0x2000b）已逐节点核对后按规则删除提取件，只留下面这些值：

- **相同**：三级 idle-states 的 PSCI 参数与延迟/驻留逐值相同；PSCI 域拓扑（cpu-pd0..5→cluster-pd0、cpu-pd6/7→cluster-pd1、两者→cluster-pd2(ss3)）= 0031；PDC（`qcom,canoe-pdc`，reg 与 24 段 pdc-ranges 相同）；apps_rsc（drv-id 2、tcs-offset 0xd00、ACTIVE 3/SLEEP 2/WAKE 2/CONTROL 0，另 FAST_PATH 1，`power-domains=cluster-pd2`）；AOSS QMP 地址/邮箱；ramoops 几何；双方都无 `local-timer-stop`。**拓扑和状态都不用改。**
- **安卓多出的、与空闲直接相关的**：
  - `qcom,lpmm` + 3 个 `qcom,lpm-cluster-dev`（QC LPM governor：`pred-prem-cnt=2`、`sample-invalid-time=0x2625a00`=40 ms、cluster-device1 有 `use-cluster-bias-timer`）——主线用 `pm_domain_cpu_gov` 无此偏置。
  - `gic-intr-routing`（class0=cpu0-1、class1=cpu2-7、`gic-runtime-cpu-class-en`）：1-of-N SPI 只路由到两个核，其余核更容易整簇空闲；主线无对应机制。E0 该看熄屏 300 次/s 的中断分布在哪些核。
  - `msm-watchdog` bark 11000 ms / pet 9360 ms + `ipi-ping` + `wakeup-enable`；Linux 用 `qcom_wdt` + systemd 30 s（§2.6）。
  - PCIe DRV `cesta` + `pcie-pdc@b370000`；WLAN 经 PDC 投电源轨（`qcom,pdc_mode_vote_table` L3K1.m、`vreg_pdc_map` S1J1/S2J1/S7F0/S8F0）；主线由 `baldur-wifi.dtsi` always-on 代替。
  - USB 用 PDC 中断唤醒（dp/dm/ss phy irq）——主线 `usb@a600000` 同样接 pdc 14/15/17，板级删了 `snps,usb3_lpm_capable`（`baldur-usb.dtsi:32`）。
  - 面板 ULPS、BLLP 低功耗、动态 fps 表、ESD 检查；主线用上游 DSI 视频模式 + 0110 内核内降刷。
  - `smp2p-sleepstate`（APPS 休眠时告知 ADSP，仅 s2idle 相关）。
- **安卓多出的取证/统计手段（主线无驱动）**：`cpuss-sleep-stats@18870000`（`qcom,cpuss-sleep-stats-v6`，num-clusters 2，APSS 硬件级 LPM 进入计数）；`sys-pm-vx@c320000`（`qcom,sys-pm-violators`，AOSS 记录谁阻止系统睡眠）；`rpmh-stats-v4`（带 `qcom,qmp` 和 7 个 ss-name）；`mpm2-sleep-counter`；`msm-imem@14680000` 的 `restart_reason@65c`/`dload_type@1c`；`mem_dump` 的 `cpuss_cpu0-7`（XBL 转储带 CPU 寄存器上下文——正是 0106 作者用 drgn 时缺的）；`qcom,cpucp_log@0x81210000`（CPUCP 固件日志，DDR 保留区，可能挺过热复位）。`dcc@100ff000` 在 vendor 里 status=disabled，rawdump 的 DCC_SRAM 不是手段。
- **主线这边的一个缺项**：`baldur-stats.dtsi` 的 `qcom,rpmh-stats` 节点没有 `qcom,qmp`，驱动读 `ddr_stats` 前不会发 `{class: ddr, action: freqsync}`，ddr 统计可能不可靠（sm8750.dtsi 同节点带 qmp）。

### 2.6 复位源：为什么"静默"本身不区分假说

- 本机 `qcom_wdt`：`pretimeout=0` → bark = bite = 30 s（`qcom-wdt.c:76-87`），bark 中断只做 `watchdog_notify_pretimeout` 且无 pretimeout governor（config 未开）→ **任何看门狗复位都没有 printk**。systemd 每 15 s 喂一次，所以 PID 1 卡死后 15–30 s 才 bite。（**11-01 更正**：y16 开了 `CONFIG_WATCHDOG_SYSFS` 后实测 `pretimeout` 是 1 s；咬测试时，咬之前 1 秒 pstore 控制台里有 `watchdog0: pretimeout event`——没有 governor 时内核默认就打这一行。所以内核还活着时的看门狗复位会留下这一行，体检靠它认（`tools/y700-checklist.py` 的 CRASH_SIGNS）；整机卡死时打不打得出来没测。见 `linux/kernel-y16/NOTES.md`。）
- 0106 现场"CPU5-7 又跑了约 10 s 才复位"对不上 30 s：更像 TZ/hyp/AOP 侧看门狗、err-fatal 或 PS_HOLD。x1e-sleep 在 AOSD 下遇到的是每 ~61 min 一次 "Reset by PSHOLD" 硬复位（XBL 日志 Reset Type: Hard Reset），靳 QMP `{class: aoss_slp, res: sleep, val: disable}` 只禁 AOSD 规避。
- **复位源其实已有现成取证通道却没用上**：03:41 的 rawdump 含 `RST_STAT.BIN` 与 `PMIC_PON.BIN`（`tools/rawdump-ls.py` 能导出），仓库只保存了 `lastkmsg.log`。应补导出并解码，作为"这台机复位源"的第一份样本（虽然那次是总线挂死不是空闲复位，但能校准解码）。IMEM `restart_reason`（0x14680000+0x65c）主线无驱动。PON 寄存器不要走 `regmap/*/registers` 全量 dump（PROTOCOL §4 禁区），只读小窗口或走 rawdump。
- pstore：热重启（PSCI SYSTEM_RESET）后 ramoops 在、头部 1–2 字节 ECC 纠正（当日 5 次热重启全部验证）；长按冷切断后 6 区 uncorrectable 全丢。**固件发起的静默复位是否走热路径未知**——E1 第一次复位即知（11-01：10-31 那次固件复位后 pstore 还在，见 README「10-31 21:04 死机」）；飞行记录器因此写 pmsg + tmpfs + UFS 三份。

### 2.7 上游已修、在修、不会修

- **已在我们基底（v7.3-rc4）里**：PDC pass-through 重构（irqchip 部分；默认 pass-through）；a6xx "Fix stale rpmh votes after suspend"（`a6xx_rpmh_stop` 的 `!test_and_clear_bit(GMU_STATUS_FW_START)` 与 CM3_SYSRESET 写入都在，复核确认，无需再核）；geni UART（d0cd9c8d0fd5）与 LPASS macro 的时钟投票修复（x1e-sleep 清单里的两项）。
- **已合入但不在 7.3，rebase 时是地雷**：Maulik "cpuidle/pmdomain: Correctly track state of excluded CPU clusters"（20260811-domain_off_ss3，linux-next 2026-09-17 以 2224d686e788 入队）把 `psci_pd_init` 的 `pm_genpd_init(pd, pd_gov, is_off)` 从 false 改为 `use_osi`；genpd 对"always-on 域初始为 off"返回 -EINVAL（`core.c:2443-2447`）→ **0106 原样会让 `psci_pd_init` 失败、整个 PSCI 域拓扑建不起来、退回 PC 模式（连 s2idle 也没有域态）**。Ulf Hansson "pmdomain/cpuidle-psci: Fix behaviours for CPU PM domains" v3（2026-09-07，superseded）同方向，v4 决定去掉 PREEMPT_RT 的 `RPM_ALWAYS_ON`。y10 的 flag 方案（§3.3）在 `pm_genpd_init` 前置同一 flag，有同一暴露。升到 7.4+ 时 0106/y10 必须改写。
- **X1E 的 cl5 问题**：主线 hamoa.dtsi 7 月底（95f827ceb21e，v5 DTS，2026-07-31）新增 `domain_ss3` 并把 cl5 延迟改成 2000/2000，cl5 仍开，commit message 不提 DC ZVA/复位；Glathe 的 drop-cl5 RFC 零回复；Marc Zyngier 的勘误只在树外、只匹配 X1；高通无公开回应（Konrad 在 Hamoa 线程："We're looking into it"）。**主线不会很快出修复；要 cl5 只能自己做勘误级规避或继续 0118。**
- **x1e-sleep 树外的可借鉴件**：`system-sleep-only` 域态属性（运行时 governor 跳过、`genpd_sync_power_off` 仍用——与 0106 等价但 DT 驱动、通用）；SS1 0x02000154 作为运行时系统态（取自 ACPI `\_SB.SYSM._LPI`，Windows 亮屏只允许它）——kaanapali 无 ACPI、vendor DT 只列了 ss3，是否存在更浅的系统态只能靠固件实验（风险等同复位实验，放最后）。
- **可以上游化的**：0031（sm8750 2025-02 有同类先例，Fixes 068c3d3c83be）；`baldur-stats.dtsi` 加 `qcom,qmp = <&aoss_qmp>`。
- **与我们无关**：Kevin Hilman "Assign domain callbacks to all CPU idle states"（每核只有 WFI+c4，不受影响）；PSCI SYSTEM_SUSPEND 语义讨论（高通 s2idle = OSI 复合态 + RPMh sleep set，无 SYSTEM_SUSPEND 可借）；"20261005 s2idle_state binding" 所有档案都找不到。
- **巡检**：`tools/upstream-check.py` 只巡检 GitHub 仓库列表，应加 justririll/x1e-sleep、icecream95/x1e-crash、jglathe/linux_ms_dev_kit 作为 Hamoa/DC ZVA 动态的代理；Ulf v4、Maulik domain_off_ss3 进主线的时间要盯（上游优先规矩）。**2026-10-16 已做**：三个仓库进了 `UPSTREAMS`；新加的 `WATCH` 表直接 grep Linus 主线 / linux-next / ath-next 的源文件（不经 lore），盯 domain_off、gcc CX、system-sleep-only、kaanapali 簇拆分与 cl5/ss3 参数、rpmh-stats qmp、hamoa cl5/SS1、Oryon 勘误、ath12k 省电（README「主线补丁观察」一节有每条的判据与后果）。首轮现场：next-20261014 已含 `psci_pd_init` 的 `is_off=use_osi` + `GENPD_FLAG_POWER_UNKNOWN`（RT 的 `RPM_ALWAYS_ON` 已去）和 kaanapali gcc 的 `power-domains = <&rpmhpd RPMHPD_CX>`，Linus 树（7.3-rc7）两者都还没有。

---

## 3. 推荐计划

原则：每一步只改一个变量；无人值守一律 `download_mode=off`（开机 ≥4 min）；有人在场才临时 `full` 拿 rawdump（y16 起这样还拿不拿得到没试过，见 README「内核 y16」副作用）；不读寄存器类 debugfs；一次只有一个代理上平板；设备掉线就停工作流（README:850 教训）。

### 3.1 第 0 步：只读审计与文档合并（不碰内核，先做）

1. **文档合并**（本机即可做）：以本目录为唯一落点；按 §3.3 裁决 y10 方案并同步修订 PROTOCOL §6 的验收判据；按 §3.4 修订 `cx-exp.sh`/`y700-flightrec.py`/`dczva-stress.c`/`cx-audit.sh`。
2. **导出并解码 03:41 rawdump 的 `RST_STAT.BIN`/`PMIC_PON.BIN`**（平板上 `rawdump-ls`，只读分区），存进本目录，建立复位源解码的第一份样本。
3. **记录本机固件版本**（tz/aop/cpucp/xbl；fastboot getvar 为空，用安卓 getprop 或分区内字符串），写进实验记录开头，与上游 ROW .104 对照。
4. **E0 熄屏电池态只读审计**：`cx-audit.sh --off`（修好 regulator 过滤；熄屏后 20 s 跑）看 (a) `mmcx`/`disp_cc_*` 是否 off-0；(b) `gcc_usb3_phy_gdsc` 拔电后是否仍 on（**10-16 补**：按 [../ALWAYS-ON.md](../ALWAYS-ON.md) §2 拔不拔电都 on，不必再查）；(c) `/proc/interrupts` 芯片列（`PDC` vs `GICv3`，注意大小写）和各核分布；(d) 谁在设 RTC 闹钟（61 次/1494 s：systemd `WakeSystem` 定时器？chrony？——**10-16 补**：更可能是失败的 `rtc_set_time()`，用 `always-on-check.sh --rtc 90` 定案，ALWAYS-ON §5b）；(e) `interconnect_summary` 的 ALWAYS 票。`y700-whoawake 60 --off` 出唤醒预算名单。`y700-offbench` 记当日基线。注意 `clk_summary` 读取会 `clk_pm_runtime_get_all()` 短暂拉起 dispcc/gpucc 等控制器，测功耗窗口内不读。
5. **取证演练 A**：`systemctl reboot` 一次，验证记录器把上一次 `pmsg-ramoops-0` 归档到 `pstore/<bootid>/` 且尾部与 UFS 份一致。

### 3.2 实验阶梯（PROTOCOL §3 的 E0–E5，这里只写裁决与修订后的要点）

- **E1 簇下电（0118 放开）**：`cx-exp.sh E1 30` × 2，再累计到 ≥3 h（上游基线 1.5 次/h → 3 h 零次为巧合的概率约 1%）。**首要交付物是记录器抓到的第一次复位**，其次才是活过去。判定簇真的下电：`power-domain-cluster{,1}` S0 **Usage** 增长、Rejected 停止增长（`pd=cl0/cl1` 字段）。复位后按 PROTOCOL §2 读尾部；若 pstore 为空而 UFS 有，说明这类复位丢 DDR，以后只靠 UFS + rawdump。连续 2 次复位停在该级，改做隔离变体：
  - `/dev/cpu_dma_latency` 持 5000 µs（放 cl5 禁 ss3；cl5 的 power_on+off = 2150+1983 = 4133，ss3 = 7200）——在 E3 阶段才有意义；E1 阶段用 per-簇 `cpu{6,7}/cpuidle/state1/disable` 让簇 1 永不进域路径，分出"簇 0 cl5 / 簇 1 cl5"（注意它同时让系统域永远到不了 off）。
  - DT 变体（需重编、作者重启）：两个簇域临时加 cl4 0x01000044 作为更浅的域态，看固件是否接受（Rejected）、"pll-off" 是否是因子。
  - 若本机 088 固件下 ≥3 h 零复位：先庆祝再怀疑——重复一轮并把浸泡延长到 24 h，再决定是否把 `allow_cluster_off=1` 写进 tmpfiles（上游说簇态本身不省电，但它是 ss3 的前提）。
- **E2 DC ZVA 判别**（H2）：`dczva-stress` 按 §3.4 改成 x1e-crash 序列后，`allow_cluster_off=1` 下跑 30 min；X1E 上数秒到数分钟即崩。阳性（复位率显著高于 E1）→ 做 y11：把 x1e-sleep 的 `WORKAROUND_QCOM_ORYON_DC_ZVA` 移植到 part 0x002（新 MIDR 宏；`cpu_enable` 清 `SCTLR_EL1.DZE`；clear_page/memset/mte 绕开 ZVA 按 cpucap 门控），再 `allow_cluster_off=1` 跑 ≥3 h 作决定性对照。代价：失去 ZVA 快路（EL0 读 `DCZID_EL0.DZP=1` 后 glibc 自己走存储循环，**不会**每条陷入），内核 clear_page 走存储循环。阴性 → H2 排除，勘误不做。
- **y10 旋钮**（§3.3）→ **E3a/b/c**：`prevent_cx_collapse`/`prevent_ddr_collapse` 各写 1 后放开 `allow_system_off=1`（配合 `allow_cluster_off=1`）。**修正**：`qmp_send()` 只等 AOP 消费消息（1 s 内 MSGRAM 长度字清零返回 0），没有状态回包，不认识的 class 照样被消费——所以 `cx-exp.sh` 的 `|| die` 几乎不会触发，分级是否生效只能靳 `qcom_stats`：E3a 期间 `apss` 涨而 `cxsd` 必须停在 0，**`cxsd` 第一次非 0 立即停**，并把 E3a 头几分钟按 E3c 风险对待。E3b（放 CX）是最可能出事的一级：APSS 侧对 CX 零投票，CX 是否塌由 AOP 按其它子系统决定，PCIe 链路由 AP 持有、无 DRV；0059/0128 为 s2idle 修过 USB/UFS 的保持。E3c 全放 = s2idle 深度。每级 30 min → ≥1 h。**现实提醒**：按上游 1.5 次/h，E1 "累计 ≥2 h 无复位"的通过概率仅 e^−3 ≈ 5%；E3 实际取决于簇下电复位在本机不复现或被 E2/y11 解决——**本协议真正的交付物是 E1 抓到的复位现场**。
- **E4 开关屏循环**（0106 的触发器，60 次，1/25 失败率下约 91% 会撞上一次 → 也是抓现场）；**E5 Wi‑Fi 流量**（H4：PCIe WAKE#/MSI 从 apps-pc 唤醒 APSS）。
- **浸泡与常驻**：E4+E5 都过 → 24 h 浸泡 → 才写 tmpfiles。

### 3.3 y10 旋钮：两份互斥设计的裁决

现状：PROTOCOL §6 要求 `allow_system_off` 照 0118 的写法在 `psci_pd_power_off()` 返回 -EBUSY、默认 0、"不要翻 pd->flags"；临时工作区里的 `y10-1043-cpuidle-psci-domain-allow_system_off.diff`（`git apply --check` 在 0106+0118 之后通过，复核独立重建确认）却是运行时翻转系统域 `GENPD_FLAG_RPM_ALWAYS_ON`、C 里默认 true、靠 cmdline 片段置 0。两者行为不同：
- -EBUSY 版：每次最后一个簇下电都会先发 PRE_OFF → `rpmh_flush`（写 sleep/wake TCS）→ 被拒 → `GENPD_NOTIFY_ON` 回滚，Rejected++。这是**新增**行为（簇域上没有带通知器的设备，0118 并没有这个副作用——复核对 PROTOCOL F2 的修正），与今天的 0106 基线不等价，给 A/B 引入混杂变量。
- flag 版：`aso=0` 时与 0106 完全等价（不尝试、Rejected 恒 0）；`aso=1` 时 = 上游行为。`genpd_sync_power_off` 不查该 flag，s2idle 不受影响；写者所在 CPU 的域链必为 on，flags 位读写无需 genpd 锁。

**裁决：采用 flag 版，做四处修改**：(1) `static bool allow_system_off;`（默认 **N**，fail-safe，不依赖 CMDLINE）；(2) `psci_system_pd_apply()` 开头 `if (IS_ENABLED(CONFIG_PREEMPT_RT)) return;`（别清掉 RT 配置刻意设的 flag；本机未开 RT 但补丁要对）；(3) `kbuild-y10.sh` 以 `kbuild-y9.sh` 为模板，CMDLINE 加 `cpuidle_psci_domain.allow_system_off=0`（我们的构建不用 `baldur.fragment`，diff 的 fragment 部分无效）【10-16 审阅推翻这一半：CMDLINE 保持与 y9 **相同**、不加该 token——C 默认 N 已是 fail-safe，加了反而显得旋钮依赖 cmdline；`kbuild-y10.sh` 见到 `allow_system_off` 字样直接退出，见 `Y10-NOTES.md`「有意不做」】，series 用 printf 列出并 `grep -q allow_system_off drivers/cpuidle/cpuidle-psci-domain.c` 断言已打上（1040 教训）；(4) `y10-verify.sh` 断言 `allow_system_off == N`、`allow_cluster_off == N`、熄屏一分钟内 `power-domain-system` Usage 不增。**PROTOCOL §6 改写**为 flag 方案，验收改成"`aso=0` 时系统域 Usage/Rejected 恒 0（与 0106 相同）；`aso=1`（且 `aco=1`）时 Usage 增长"；`cx-exp.sh` 的判据同步。编号 1043。另记：0106 去掉 `of_machine_is_compatible` 改为"无 `power-domains` 的根域"，对 baldur-kexec 片段（无该参数）意味着默认放开 ss3——我们不用那个片段，但要知道。

### 3.4 工具修订清单（复核发现，都在本目录）

- `cx-exp.sh`：(a) 从不验证屏幕真的关了——`kscreen-doctor` 以 user + 写死的 wayland/bus 路径跑且丢弃错误；sleep 15 后读 `/sys/class/drm/card*-DSI-*/dpms` 必须为 Off 否则 die，恢复时核对 On；(b) E3a 加"`cxsd` 第一次非 0 即停"；(c) `dczva-stress` 改 `runuser -u user --` 运行（DC ZVA/affinity/mmap 都不需要 root，只有 `/dev/pmsg0` 0220 需要），错误走 stderr 由记录器 `--mark` 转存；(d) 看门狗把 `WARNING:`/`BUG:` 计入阈值是保守默认，写进日志解读；(e) `lspci -vv` 加护栏：wlp1s0 不 up 或链路无就跳过（链路断开时的配置访问可能同步外部中止）。
- `y700-flightrec.py`：电池 `voltage_now/current_now` 每次读都是一次到 ADSP 的 glink 往返，改为每 5–10 s 一次；测量轮默认 `--sync 5`；补 rpmhpd 性能态（`pm_genpd_summary` 的 cx/mmcx 行）、`bi_tcxo` 的 `clk_prepare_count`、温度。`qcom_aoss` 的 prevent_* 是只写文件，状态由 `cx-exp.sh` 记。
- `dczva-stress.c`：现序列（memset → dc zva → 立即校验）抓不到 x1e 的签名。改为：`dc civac` 预清洗目标行 → `dc zva` → 经另一行的依赖读回 40 字节逐字节比对 → **让本簇空闲 >9.1 ms（ss3 需 >10.15 ms）后再校验一次 ZVA 过的块全零**（跨 cl5 丢零行的签名）；守护页全查（成本可忽略）；加 `-c 0` / `-c 6` 单簇变体；报告"损坏"与"挂死/复位"两类结果；`sync` 后再跑。E2 的判据仍只能是对照 E1 的复位率。
- `cx-audit.sh`：regulator 段直接打印 `regulator_summary` 前 60 行；头注改 `PDC`（芯片列实际大写）；别写 `/tmp/.cxa1,2`（头注说只写 stdout）。
- `y700-checklist`：加"上次复位原因 + 飞行记录是否被取回"体检项；`tools/upstream-check.py` 加 x1e 三个仓库（后者 2026-10-16 已做，连同主线补丁观察表）。

### 3.5 中止判据

- 任一级累计复位 ≥2 次 → 停在该级做分析（先产出 `runs/<step>-<time>/` 的尾部 + pstore），不往上走。
- `cx-exp.sh` 内置看门狗：12 s 内 ≥5 条 `vblank timeout` / `failed to flush transmit queue` / `timed out in resp` / `TCS Busy` / rpmh 超时 / `Unhandled fault` / `SError` / `BUG:` / `WARNING:` → 恢复并退出。
- E3a 期间 `cxsd` 非 0（分级失效）；Wi‑Fi 掉线 >60 s；电量 <40%；`download_mode` 不是 off 或开机 <240 s；记录器没在跑——任一项不满足不开始。
- 出现 03:41 型 SCMI 超时刷屏 → 立刻停，不再碰任何 debugfs。
- 若机器**挂死而不复位**（x1e-sleep 在运行时 DRIPS 遇到过）：需要人长按；无人值守实验的时长要让作者知道可能要手动恢复。
- 作者不在场不进 `download_mode=full`；作者在场的 full 实验结束后改回 off 并核对。

### 3.6 成功的样子

- **E1**：本机 088 固件下 `allow_cluster_off=1` 累计 ≥3 h（最好 24 h）零复位，簇域 Usage 增长。或者：抓到一次复位，记录器最后一行 + `console-ramoops-0`/UFS 尾部 + （有人在场时）rawdump 的 RST_STAT/PMIC_PON 齐全，能说出"哪一级刚变化、哪个中断在最后一秒还在来、谁复位了 SoC"。
- **E2**：阴性（排除 H2），或阳性且 y11 勘误后 E1 转阴（根因定位）。
- **E3a**：`qcom_stats apss` Count 增长、`power-domain-system` Usage 增长、`cxsd` 为 0、无复位 ≥1 h。**E3b**：`cxsd` 增长。**E3c**：`aosd`/`ddr` 增长且功耗可测下降。
- **E4** 60 次、**E5** 30 min 无复位 → 24 h 浸泡 → 写进 tmpfiles。
- **功耗目标**：唤醒率不变时 0.42 → 0.35–0.39 W 已算成功；配合唤醒率压到 <50/s，0.20–0.27 W（满电熄屏 130–170 h）是上限。

### 3.7 并行的零风险工作：唤醒率

ss3 的收益由唤醒率决定（§1.4），这部分不依赖复位问题：tailscaled ≈35 次/s（Tailscale 下线实测不省电，但省的是唤醒不是流量）、Claude 桌面版 22/s（熄屏仍在跑）、PowerDevil `display_recheck` 10/s、`rtc@6100` 的闹钟来源、`arch_timer` 160/s 背后的 hrtimer 持有者（`y700-whoawake` 按线程给名单）、IPI1 86/s。目标 <50/s。安卓靳 doze 批处理定时器、Wi‑Fi 固件自己收信标（DTIM 不叫醒主机）做到这一点。

---

## 4. 诚实的风险与我们修不了的事

1. **根因很可能在固件/hypervisor**。内核在簇/系统态路上不保存上下文、不编程唤醒、不参与 GIC 保存；TZ、Gunyah、AOP、CPUCP 的缺陷我们只能**避开**（0106/0118 就是避开），不能修。Lenovo 不会为 Linux 更新固件；0031 的拆簇让这些态真正可达也让问题暴露，这是正确的方向而不是错误。
2. **Gunyah EL2 不可观测**。"唤醒没送到"若在 EL2 发生，EL1 没有任何手段看见；pseudo-NMI 内核在本板启动即挂（上游 10-03 试过）。
3. **本机是 Oryon v3（part 0x002）**。上游没有它的 MIDR 和任何勘误条目；X1E 的 DC ZVA 结论不能直接迁移；同代 glymur/sm8750 没有公开报告但用户基数极小。移植勘误是本地补丁，没有上游背书。
4. **安卓同固件稳定是对所有"固件坏了"假说的反证**。差异只可能在 governor/驯化层（lpmm、gic-intr-routing、msm-watchdog ipi-ping）、GIC 睡眠握手由谁做、或时序窗口——这些都是猜测，没有一条从 DT 能直接证明。安卓熄屏是否真的运行时进 apps-pc、驻留多少，也没有测量（§5 问题 1）。
5. **即使复位解决，运行时 CX 可能仍塌不下来**：主线没有安卓的 PCIe DRV/`pcie-pdc`，链路由 AP 持有、L1.2 几乎进不去；icc ALWAYS 票（PCIe、memlat）进 sleep set 后 AOP 怎么处理无人知道；APSS 对 CX 零投票。补 PCIe runtime PM / L1ss 睡眠处理是另一项大工程，DRV 不在主线不可移植。
6. **收益上限有限**：物理地板是 s2idle 的 0.10–0.13 W；运行时 Wi‑Fi 关联地板更高（猜 ~0.2 W）；现状唤醒率下只有 0.03–0.08 W。作者若要大幅续航，休眠（约 0.1 W）才是数量级的差别，但作者已明确不休眠。
7. **实验本身的代价**：每次复位 = 重启约 8 s + Wi‑Fi/Tailscale 重连 + 应用状态丢失；开机前 3 分钟复位会卡 900E 耗 1.6 W 直到长按；可能"挂死不复位"需人工介入；复位时 UFS 有写入（ext4 journal，损坏风险低但非零）；DC ZVA 测试理论上可能损坏内存内容（校验在程序里）。E1→E3 的门槛按上游速率通过概率仅约 5%，**要做好 E3 工具长期用不上的准备**。
8. **取证的不确定**：静默复位是否热路径（pstore 保不保）未验证；复位源寄存器只有有人在场的 `full` 模式能拿；`cpuss-sleep-stats@18870000` 虽是统计块但位于 APSS 地址空间（0x17xxxxxx–0x18xxxxxx 与 rsc/wdt/cpucp 同区），不一定是纯 SRAM，按 03:41 的教训要先拿到下游驱动格式（codelinaro 抓取 429 未读到）再评估是否碰。
9. **升级基底的地雷**：linux-next 的 `is_off=use_osi` 与 Ulf v4 会让 0106/y10 的 `RPM_ALWAYS_ON` 在 `pm_genpd_init` 处 -EINVAL → PSCI 域拓扑建不起来 → PC 模式（s2idle 也丢域态）；linux-next 给 gcc 节点加 `power-domains=<&rpmhpd CX>` 后 PCIe/UFS 的 OPP 票会开始钉 CX，awake floor 会变，升级后要重测。
10. **不可读的来源**：lore/patchwork（按规则未绕过反爬）、Marc Zyngier 的原始勘误 commit（git.kernel.org 反爬）、下游 `sys_pm_vx.c`/`cpuss_sleep_stats.c`/`qpnp-power-on.c`、上游作者开发机上的 flight recorder 与延迟 knob 数据、安卓侧 `qcom_stats`。这些缺口在结论里都标了"猜测/未验证"。

---

## 5. 开放问题（三条研究线合并去重）

1. 安卓（ColorOS 17）在本机熄屏不休眠时 `cxsd`/`aosd` 是否真的计数、驻留多少？任务前提来自 vendor DT 的能力，不是测量。作者若愿意回安卓一次，root 后 `cat /sys/kernel/debug/qcom_stats/{apss,cxsd,aosd}` 熄屏前后对比即可回答。
2. 静默复位的复位源（PS_HOLD / APSS WDT / TZ 安全 WDT / PMIC 故障）？只有 `RST_STAT.BIN`/`PMIC_PON.BIN` 能答；0106 的"约 10 s"对不上 Linux 看门狗。
3. 固件发起的静默复位后 DDR/ramoops 是否保留？E1 第一次复位即知。11-01：一次样本，保留（见 README「10-31 21:04 死机」）。
4. kaanapali Oryon v3 是否有 DC ZVA × CL5 问题？E2（x1e 序列）判别；若 kaanapali 的 cl5 保留 L2（"ret-pll-off"），机理可能不同。
5. 上游 ROW .104 的复位在本机 088 固件上是否复现、频率如何？E1。
6. 0106 现场为何 CPU0-4 卡在 retention 不醒：GIC redistributor ProcessorSleep 握手（内核做）与 GIC WakeRequest → 电源控制器（固件/硬件）之间丢在哪一层？安卓是否也以 `GICD_CTLR.DS=1` 运行？
7. ss3/cl5 期间的定时器唤醒由固件读各核 CNTP_CVAL 安排（CONTROL_TCS=0、无 broadcast）——安卓同样如此，所以不应是差异，但没有文档证实；Gunyah 的 virt 定时器转译是否相关？
8. apps-pc 期间到达的 ITS LPI（PCIe/UFS MSI）会丢失还是挂起？vendor 的 `pcie-pdc` 是否为此而设？
9. 放开 ss3 后，RPMh sleep set（从未刷过）和 icc ALWAYS 票会让 AOP 做什么？`cxsd`/`ddr` 会不会跟着 `apss` 动？
10. kaanapali 的 PSCI/AOP 是否接受比 0x0200c354 浅的运行时系统态（X1E 的 SS1 0x02000154 来自 ACPI；本机无 ACPI、vendor 未列）？只能靠固件实验，放最后。
11. `qcom,lpmm` 对应什么下游驱动、是否向固件下发允许的 LPM 模式？未查到公开资料。
12. 熄屏电池态下 `gcc_usb3_phy_gdsc`、CDSP 持 XO、蓝牙 UART 时钟、`rtc@6100` 的 61 次闹钟是否依旧？（审计是亮屏充电采样。）**2026-10-16 部分结案**（[../ALWAYS-ON.md](../ALWAYS-ON.md)）：`gcc_usb3_phy_gdsc` 与充电无关、拔电也 on（§2）；CDSP 本就不持 XO（§1）；rtc 很可能不是闹钟而是失败的 `rtc_set_time()`（§5b，`always-on-check.sh --rtc 90` 定案）；蓝牙 UART 只要 hci0 Powered 就常开，熄屏不变（§3）。
13. `qcom,rpmh-stats-v4` 与上游 `qcom,rpmh-stats` 布局：偏移已由 SRAM 标签证实正确，但缺 `qcom,qmp` 时 ddr 统计是否可靠？
14. 为何 4/6 个 ramoops 区头部每次热重启都有 1–2 字节 ECC 纠正（位衰减 vs 启动链碰了前 256 KiB）？目前无害。

---

## 6. 文件与出处索引

**本目录**：[PROTOCOL.md](PROTOCOL.md)（实验协议，需按 §3.3/§3.4 修订）、`y700-flightrec.py` + `.service`、`dczva-stress.c`（需按 §3.4 重写序列）、`cx-exp.sh`、`cx-audit.sh`、`cx-audit-2247.txt`（y9 亮屏充电审计原文）、`crash-0341-lastkmsg.log`。

**仓库其它**：`README.md`（续航第三轮、熄屏对照、永不休眠、底噪研究各段；285 行 allow_cluster_off；845-850 行 03:41 事故）；`linux/kernel-y8/inventory/`（y7 dmesg、config-running、cmdline、bound-drivers）；`linux/kernel-y8/PLAN.md`、`kbuild-y9.sh`、`config-t49-y9:600`（CMDLINE）；`linux/power/y700-dumpmode-off.{service,timer}`；`tools/rawdump-ls.py`、`y700-powersample.py`（只读 qcom_stats）、`y700-whoawake.py`、`y700-offbench.sh`、`upstream-check.py`；`linux/tb323fu-linux/kernel/patches/0031,0032,0049,0050,0051,0055,0058-0062,0078,0103,0104,0106,0110,0114,0116,0118,0128,0129`；`kernel/README.md:134,144,150-157`；`kernel/PROVENANCE.md:56,131`；`docs/hardware-status.md:113-121,145,151-165`；`docs/custom-kernel.md:58`；`kernel/dts/baldur-{stats,wifi,usb,audio,touch,power}.dtsi`、`kaanapali-lenovo-baldur.dts`。

**临时工作区（不入库）**：`upstream-src/`、`upstream-src2/`（v7.3-rc4 与 linux-next 公开源码副本：psci.c、cpuidle-psci*.c、dt_idle_*.c、pmdomain/core.c、governor.c、rpmh-rsc.c、rpmh.c、qcom-pdc.c、qcom_stats.c、qcom_aoss.c、clk-rpmh.c、rpmhpd.c、qcom-wdt.c、irq-gic-v3*.c、pstore ram*.c、pcie-qcom.c、icc-rpmh.c、cpu_errata.c、cputype.h、kaanapali/hamoa/glymur/sm8750/sm8650.dtsi、jglathe_hamoa.dtsi）；`verify-dl/x1e/`（icecream95 crash.c 与 README、x1e-sleep README、zva.patch）；`y10-1043-cpuidle-psci-domain-allow_system_off.diff`、`mk-y10.py`、`y10-work/`；`fdt2dts.py`、`fdtgrep.py`（vendor DT 读取器；注意 fdt2dts 的 phandle 注解会标到任何等于某 phandle 的 u32，核对时只信已知含 phandle 的属性）。vendor DT 提取件已按规则删除，仓库未放入任何副本。

**上游/公开**（lore/patchwork 未读，均经镜像）：
- Hamoa drop-cl5 RFC：https://ratatoskr.run/b4-sent/2026/06/17090238 ；线程 https://ratatoskr.run/linux-devicetree/2026/06/17090238/t
- icecream95/x1e-crash：https://github.com/icecream95/x1e-crash （`crash.c`、README）
- justririll/x1e-sleep：https://github.com/justririll/x1e-sleep （README；`kernel/experimental/x1-dc-zva-erratum-and-cl5.patch`；`pmdomain-system-sleep-only.patch`；`dts-hamoa-add-ss1-idle-state.patch`）
- Launchpad #2158523：https://bugs.launchpad.net/bugs/2158523
- hamoa domain_ss3：https://github.com/torvalds/linux/commit/95f827ceb21e ；评审线程 https://ratatoskr.run/linux-devicetree/2026/07/17263038/t
- PDC pass-through：v1 https://ratatoskr.run/linux-devicetree/2026/03/3455839/t ；v4 https://ratatoskr.run/lkml/2026/07/17223945/t
- domain_off_ss3：https://ratatoskr.run/linux-arm-kernel/2026/08/17394853/t ；Ulf v3：https://ratatoskr.run/linux-arm-kernel/2026/09/17524641/t
- Linaro arm64-laptops issue 16（Latitude 7455 运行时 ss3 21415 次，平均驻留 1.4 ms，证据力弱）：https://gitlab.com/Linaro/arm64-laptops/linux/-/issues/16
- jglathe/linux_ms_dev_kit #94：https://github.com/jglathe/linux_ms_dev_kit/issues/94
- portareos #505/#506、ROCKNIX #3126（SM8550 cxsd 全 0）：https://github.com/portare-ch/portareos/issues/505 ；https://github.com/ROCKNIX/distribution/pull/3126
- C630 簇 idle 复位线程：https://lkml.indiana.edu/2604.3/08244.html ；https://lkml.rescloud.iu.edu/hypermail/linux/kernel/2606.1/10780.html
- sm8750 簇域拆分先例：https://lkml.rescloud.iu.edu/2502.3/04871.html ；Glymur idle-states 评审：https://lkml.iu.edu/hypermail/linux/kernel/2510.1/04662.html
- Qualcomm Dragonwing 文档（cxsd/aosd/ddr 定义与 qcom_stats 读法）：https://dragonwingdocs.qualcomm.com/System/Power/system-on-chip-sleep-states
- TF-A OSI 设计文档：https://trustedfirmware-a.readthedocs.io/en/v2.11/design_documents/psci_osi_mode.html
- tb323fu-linux issue #9：https://github.com/joonhoekim/tb323fu-linux/issues/9

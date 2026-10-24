# PCIe L1.2：为什么 WCN7860 的链路几乎进不去，以及值不值得追 — Y700 Gen5 / kaanapali，内核 y9

> 状态：**研究，2026-10-16，同日复核修订；全部只读**。没碰平板、没编译、没跑任何二进制。源码读的是 v7.3-rc4 公开副本（GitHub raw）+ 本仓库的上游补丁 0001–0130 与 1041；安卓侧读的是本地 `coloros-v17/image/` 里 vendor_boot / dtbo 的 DT（内存里解析，只记下数值，不留提取件，沿用 cx-collapse 研究的规矩）和 CodeLinaro 的 pci-msm 源码。lore / patchwork 有反爬页，没绕；邮件列表内容来自 lkml.iu.edu 镜像。CodeLinaro 的 cnss2（安卓 Wi‑Fi 平台驱动）要登录，没读到。
> 复核（第二轮，同日）：逐条对照 v7.3-rc4 源码核过第一轮的引用行号与结论；**改了原因排名**（§0 第 2 条、§3）：两条新证据把「固件把 LTR Max=0 当上限」从第一位降到第三位，把「CAM 模式下的过期数据 + 固件按活动上报 LTR」提到第一位，并新增「主机侧链路活动把固件钉在 active LTR」作为第二位。补丁 1045 的代码不变，只改了说明；探针新增一个可选的 MHI 状态采样（tracefs，只开 tracepoint）。
> 审稿（第三轮，同日，独立复核）：全部引用行号对 v7.3-rc4、pci-msm（CodeLinaro 重新拉取，sha 一致）、lkml.iu.edu 原页（重新拉取，与存档一致）、pciutils 复核，`git apply --check` 重做（偏移 6 行一致）。改了四处：§1 把「4 h 计数」的 /s 数字出处写实（03:41 排查脚本 10 s 差分，原始输出没进仓库）；§2.3/§7.1 和 1045 说明里 resume 路径的顺序写反了（`post_init` 先于端点的 `pci_restore_state()`，PERST 后 Max 读 0 会再写一次，结论「安全」不变）；aspm.c `pcie_aspm_override_default_link_state` 的行号 857→885；探针的 `[ -s set_event ]` 在 tracefs 上永远为假（tracefs 文件 stat 都是 0 字节），改成读内容判空，否则「y700-wakeups 在跑就跳过」从未生效。
> 读者：作者，以及下一个接「熄屏 0.42 W 里 Wi‑Fi+PCIe 那 0.06 W」的人。
> 相关：[cx-collapse/RESEARCH.md](cx-collapse/RESEARCH.md)（§1.2 常开外设、§2.5 安卓 DRV/cesta）、[WAKEUPS.md](WAKEUPS.md)（唤醒率；本题的 R2 和它是同一根杠杆）、[ALWAYS-ON.md](ALWAYS-ON.md) §6、README「续航第三轮」。
> 产出：本文；`tools/y700-l1ss-probe.sh`（只读探针，可选 `MHI_SECS=` 采 MHI 状态）；`tools/y700-l1ssbench.sh`（熄屏 A/B）；`linux/kernel-y8/1045-pcie-qcom-l1ss-t-power-on-ltr-max.patch`（**未编译未验证**，`git apply --check` 在 0049/0056 之后通过，见 §7）。

## 0. 一页纸

1. **问题**：lspci 两端都是 `ASPM L0s+ L1+`、`L1SubCtl1: ASPM_L1.2+ ASPM_L1.1+`、`DevCtl2: LTR+`，看起来 L1.2 万事俱备；但 4 小时的 `link_transition_count` 是 L0s ≈700/s、L1 134/s、**L1.1 113/s、L1.2 总共 31 次**。
2. **最可能的原因（复核后的排序）**：
   - **R1 那 4 小时是 1041 之前、固件省电关着（CAM 常醒）时测的，而固件的 LTR 是按自己的活动状态上报的。** L1.1 和 L1.2 的进入条件只差「端点最近一次 LTR ≥ Root Port 的 `LTR_L1.2_THRESHOLD`」这一条（§2.1）；L1.1 每秒进 113 次说明 CLKREQ#/refclk/能力位/使能位全通，卡住的只能是 LTR 门槛。固件的 LTR 策略不是一个常数：ath12k 的 WMI 参数表里有 `LTR_AC_LATENCY_BE/BK/VI/VO`、`LTR_SLEEP_OVERRIDE`、`LTR_RX_OVERRIDE`、`LTR_TX_ACTIVITY_TIMEOUT`（`wmi.h:957-965`，ath12k 不用但名字就是固件模型的说明书）——有收发活动时上报各 AC 的「active」延迟，睡着时上报「sleep」延迟。CAM 模式 = 永远 active = 永远 L1.1。**31 次 L1.2 不是 0 次**，说明固件确有上报 ≥ 阈值的时刻（§3.1）。1041 之后固件 100 ms 无流量就打盹，LTR 应该已经变了，但没再测过，计数器又禁读（§3.1）。
   - **R2 主机侧链路活动把固件钉在 active。** L1 每秒退出 134 次 = 平均 7.5 ms 一次 TLP 往返；若固件的 `TX_ACTIVITY_TIMEOUT`/Rx 覆盖量级是几十 ms，它的 LTR 永远回不到 sleep 值，1041 之后也进不了多少 L1.2。而且每次 L1 退出都要付 L0 的电，是 Wi‑Fi 这 0.06 W 里更大的一块（§3.2）。这和 WAKEUPS.md 的唤醒率是同一根杠杆（tailscaled、Claude 桌面版、`station dump` 轮询、CE 中断）。
   - **R3 端点的 LTR Max Snoop/No‑Snoop Latency 寄存器为 0、固件把 0 当上限（Kioxia 形态）。** Linux 在 DT 平台**从不**写这两个寄存器（x86 由 BIOS 写），上电是 0；先例是 2022 年高通调 Kioxia NVMe（§3.3）。但本机有两条反证：(a) 31 次 L1.2——若固件把 Max=0 当「只许上报 0 ns」，L1.2 该是 0 次；(b) 安卓的 pci-msm 同样只置 `DEVCTL2.LTR_EN`、不写 Max（`pci-msm.c:8261-8322`，本地源码实读），而安卓的 DRV 以 L1.2 为前提。所以 R3 只剩「cnss2 可能写了 Max（源码读不到）」这一个缺口。它便宜、可一次实验定夺（§6 状态 7），但不再是主嫌。
   - **已排除**：CLKREQ#/refclk/PHY 配置、L1SS 能力位与使能位、`ltr_path`、ath12k 的 ASPM 禁用（只在固件下载期间）、MHI「M0 持锁」（是逐次访问的瞬态，不是持锁）、0049/0072/0078（和进入条件无关）（§3.4）。
   - **旁注，不是原因但关系安全**：Root Port 的 `T_POWER_ON` 是 0（kaanapali DT 没有 `t-power-on-us`），aspm.c 算出的阈值和 `T_PwrOn` 都偏小——L1.2 一旦真的进了，退出时序可能出错（高通自己说会报 AER）。想让 L1.2 真的发生，先把这个补上（§3.5）。
3. **安卓对照（本地 vendor DT + pci-msm 源码实读）**：`qcom,l1-2-th-scale = <2>`、`qcom,l1-2-th-value = <150>` → 阈值 **153.6 µs**，由 pci-msm 直接写进两端 CTL1；`qcom,drv-l1ss-timeout-us = <5000>`、`qcom,drv-name = "cesta"`、`qcom,aux-clk-freq = <20>`、`qcom,ep-latency = <10>`（PERST 后等 10 ms，和 LTR 无关）。安卓的 apps‑pc 以「链路进 L1.2 → 5 ms 后 CESTA 关 PCIe 资源」为前提，说明 WCN7860 固件空闲时**能**上报 ≥154 µs——而我们的阈值比它低（§2.2、§4）。主线没有 DRV/cesta/pcie‑pdc，所以即使进了 L1.2，SoC 侧的 `gcc_pcie_0_*`、GDSC、aux clk 也照旧开着（§4）。
4. **值多少钱，先说实话**：Wi‑Fi+PCIe 熄屏残余一共约 0.06 W（0.42 vs rfkill 0.36）。L1.1→L1.2 省的是两端 PHY 的共模电压/接收检测这一点，估计 **≤ 0.01–0.02 W**，低于电池测量 ±0.03 W 的噪声（§7.3）。所以这题是「纠正性 + 便宜」而不是「省电大项」。Wi‑Fi 这块真正的杠杆是把 L1 退出 134 次/秒压下去（R2），那也是 WAKEUPS.md 的目标。
5. **怎么做**：① 平板上跑 `y700-l1ss-probe.sh`（只读，§5；加 `MHI_SECS=30` 顺带看固件多久进一次 MHI M2）→ 看 EP 的 `Max snoop latency` 是否 0ns、两端 `PortTPowerOnTime`、`LTR1.2_Threshold`、M2 次数；② 电池熄屏跑 `y700-l1ssbench.sh`（§6）；③ 状态 1「L1.2 off」若明显高于基线 → R1 成立，L1.2 已经在进，收工（只留 DT 一行）；若 ≈ 基线且探针 Max=0 → 带 `LTR_US=3000` 再跑一次（R3）；有差才用 1045 的模块参数部分（§7）。④ 不论结果，R2 的治法在 WAKEUPS.md。

---

## 1. 现场事实（来源：README 续航第三轮、inventory、任务书）

| 项 | 值 | 出处 |
|---|---|---|
| 链路 | `0000:00:00.0` [17cb:0123] Root Port ↔ `0000:01:00.0` [17cb:110e] WCN7860，`PCIe Gen.3 x2 link up`（上游 hardware-status 说实际跑 x1） | `inventory/dmesg` 1078–1094、`docs/hardware-status.md` |
| ASPM | 两端 `L0s+ L1+`；`L1SubCtl1: ASPM_L1.2+ ASPM_L1.1+`；`DevCtl2: LTR+` 两端 | 任务书（lspci -vvv） |
| 内核日志 | `pci 0000:01:00.0: ASPM: default states L0s L1`（4.3557 s）→ 之后 pcie-qcom 把全部状态打开（§2.3）；`ath12k_wifi7_pci 0000:01:00.0: MSI vectors: 16` | dmesg 1096、1114 |
| 4 h 计数 | 累计（开机约 4 h）：L1.1 163 万次、**L1.2 31 次**；10 s 差分：L0s ≈700/s、L1 134/s、L1.1 113/s | README 续航第三轮「已知的平台缺口」只记了 31 / 163 万两个数；/s 的数字来自 **2026-10-15 03:41** 的排查脚本（`audit-periph-2.sh`，两次 `cat` 隔 10 s 作差）当场回显，平板一分钟后死机，原始输出没进仓库。**1041 之前（1041 在当天 14:26 之后才做），固件 CAM** |
| 之后 | `debugfs pcie@1c00000/link_transition_count` 读 5 个 PARF 调试寄存器（`pcie-qcom.c:1832-1849`，`readl_relaxed(pcie->mhi + 0xc84/0xc88…)`），03:41 死机与之吻合 → **禁读** | README:875、PROTOCOL §5 |
| 配置 | `CONFIG_PCIEASPM=y`、`PCIEASPM_DEFAULT=y`（policy=default）、`PCIE_QCOM=y`（内建，模块参数前缀 `pcie_qcom.`）、`ATH12K=m`、`MHI_BUS=y`、`MHI_BUS_DEBUG`/`ATH12K_TRACING` 未开、`TRACEPOINTS=y`（MHI 的 tracepoint 不依赖 `MHI_BUS_DEBUG`，§5） | `inventory/config-running` |
| DT | `qcom,kaanapali-pcie`,`qcom,pcie-sm8550` → `cfg_1_9_0`（`ops_1_9_0`，不带 `no_l0s`）；`pcie_port0` 只有 phys/wake/reset，**没有 `t-power-on-us`** | `kaanapali.dtsi:2315-2460`、`baldur-wifi.dtsi:190-196` |
| 固件省电 | 1041 修好 `BSS_CHANGED_PS` 下发后 0.48 → 0.42 W；Wi‑Fi 全关 0.36 W | README 续航第三轮 |
| 固件 | `WLAN.GNG.2.0-01365.1`，`fw_version 0x200a8555`（安卓 GNG 固件借用） | dmesg 1140 |

## 2. L1.2 的进入条件：规范和内核各做了什么

### 2.1 规范（PCIe r4.0+ §5.5.1/5.5.4/6.18，结合 aspm.c 的注释）
- L1 进入后，由 **Downstream Port（这里是 Root Port）决定**走 L1.1 还是 L1.2：两端 L1.x 使能、CLKREQ# 两端都放开（refclk 可关）→ 至少 L1.1；要进 L1.2 还需要**端点最近一次 LTR 消息里的 snoop/no‑snoop 延迟 ≥ `LTR_L1.2_THRESHOLD`**（aspm.c 569–572 行注释原话：「Ports enter L1.2 when the most recent LTR value is greater than or equal to LTR_L1.2_THRESHOLD」）。
- ASPM L1.2 要求整条路径 LTR 使能（aspm.c 803–809：`if (!child->ltr_path) child_l1ss_cap &= ~PCI_L1SS_CAP_ASPM_L1_2`）。
- LTR 消息里 value/scale 全 0 的含义，PCIe 4.0 §6.18：「the device will be impacted by any delay and that the best possible service is requested」——即 **0 = 一点延迟都不能忍**，不是「无要求」。Max Snoop Latency **寄存器**为 0 的含义规范没写明（Matthias Kaehlcke 2022-12-05 的原话：「The PCIe spec doesn't say specifically what a value of 0 in those registers means」），所以固件怎么解释是固件的事（§3.3）。
- LTR 消息是端点**主动**发的（延迟要求变化时），Downstream Port 只记最近一次。所以「能不能进 L1.2」最终由端点固件的上报策略决定，主机只能定阈值、开使能、写 Max 上限。

### 2.2 aspm.c 怎么算阈值（v7.3-rc4 `drivers/pci/pcie/aspm.c`）
- `aspm_calc_l12_info()` 677–781：`t_common_mode = max(两端 CM_RESTORE_TIME)`、`t_power_on = max(两端 T_POWER_ON)`，**`l1_2_threshold = 2 + 4 + t_common_mode + t_power_on` µs**（T_POWER_OFF ≤ 2 µs，T_L1.2 ≥ 4 µs），`encode_l12_threshold()`（576–606）向上取整到 1/32/1024/32768… ns 刻度，写进**两端** CTL1；`T_PwrOn` 写进两端 CTL2；写之前先清 L1.2 使能位（规范要求，732–746）。
- 阈值完全由两端能力寄存器决定，**和端点的 LTR Max 寄存器无关**（高通 2022 年想按 Max 值夹阈值的 v7 补丁被 Mani 撤回 Ack，没有合入；见 §3.3）。
- LTR 使能：`pci_configure_ltr()` 1297–1352，只置 `DEVCTL2.LTR_EN`、设 `ltr_path`；**全文件唯一碰 `PCI_LTR_MAX_SNOOP_LAT` 的地方是 30–67 行的 save/restore**（注释「Some broken devices only support dword access to LTR」，所以 1045 和 bench 都按 dword 写）。`drivers/pci/probe.c`、`pci.c`、`quirks.c` 也没有写它的地方。→ DT 平台端点的 LTR 上限寄存器就是上电值 0。
- 对比安卓阈值 153.6 µs：我们的阈值是 `6 + CM + T_POWER_ON`，RP 的 T_POWER_ON 是 0（§2.4），所以**我们的阈值比安卓低**（几十到一百多 µs，具体等探针）。「阈值太高」不是原因。

### 2.3 DT 平台的默认策略与 pcie-qcom 的「全开」
- `pcie_aspm_override_default_link_state()`（aspm.c 885–932）：DT 平台默认只把 L0s/L1 记为默认态（dmesg 那行「ASPM: default states L0s L1」，commit df5192d9bb0e 2025-10-23），L1SS 不在默认里；`aspm-no-l0s`/`aspm-no-l1`/`aspm-no-l1ss` 三个 DT 属性可以关（eacf92a29af9）。
- `qcom_pcie_host_post_init_2_7_0()` → `pci_walk_bus(…, qcom_pcie_enable_aspm)`（`pcie-qcom.c:1110-1127`）：枚举完成后对总线上每个设备 `pci_set_power_state_locked(D0)` + **`pci_enable_link_state_locked(pdev, PCIE_LINK_STATE_ALL)`**——L1.1/L1.2/PCI‑PM L1.x/ClockPM 全部打开。这就是 lspci 里 `ASPM_L1.2+` 的来源。`dw_pcie_host_init()` 里 `pci_host_probe()` 之后才调 `post_init`（`pcie-designware-host.c:671-676`），所以此时 LTR 已使能、阈值已算好、但 L1SS 位还没置——§7 的补丁利用了这个窗口。
- **复核补充（和 1045 的正确性直接相关）**：`pci_walk_bus` 先回调 Root Port（00:00.0）再递归进子总线回调端点（`bus.c:408-424`）。对 Root Port 调 `pci_enable_link_state_locked()` 是 **no-op**：`pcie_aspm_get_link()` 用 `pci_upstream_bridge(pdev)` 找链路状态（aspm.c 1463–1474），Root Port 没有上游桥 → 返回 NULL → `__pci_enable_link_state()` 直接 `-EINVAL`（1557–1561）。链路的 L1SS 只在**端点**那一次回调里被打开。所以「端点回调时 L1SS 还没使能」成立，1045 在那里先写 LTR Max 再让 `pci_enable_link_state_locked` 开 L1SS，顺序合规。
- `dw_pcie_resume_noirq()` 也会再调 `post_init`（`pcie-designware-host.c:1322-1323`）。注意顺序：控制器的 `resume_noirq` 在子设备之前跑，所以此时端点**还没**经过自己的 `pci_restore_state()`。两种情形：(a) resume 走了 PERST / D3cold（`qcom_pcie_host_init` 会重新拉 PERST）→ 端点配置空间复位，Max 读回 0、L1SS 也还没使能 → 1045 再写一次，稍后 `pci_restore_ltr_state()` 写回的是同一个值，无害；(b) 配置空间保住了 → Max 非 0 → 直接返回。两种情形下都不会在 L1.2 开着时去动 LTR_EN。
- `qcom_pcie_init_2_7_0()` 1077–1082：清 `PARF_PM_CTRL.REQ_NOT_ENTR_L1`，`pci->l1ss_support = true` → `dw_pcie_hide_unsupported_l1ss()`（`pcie-designware.c:1216-1238`，commit a00bba406b5a 2025-11-18「Advertise L1 PM Substates only if driver requests it」）保留 L1SS 能力位。sm8550 系这一路有 L1SS，没问题。

### 2.4 T_POWER_ON 系列（已在 7.3）
- `PCI: qcom: Program T_POWER_ON`（e9769bb17269，2026-04-28）：从每个 Root Port 节点读 **`t-power-on-us`**（`pcie-qcom.c:2056`），`qcom_pcie_configure_ports()`（1376–1382）在链路训练前调 `dw_pcie_program_t_power_on()`（`pcie-designware.c:1241-1266`，d697e9067248）经 DBI 写进 Root Port 的 L1SS CAP；`t_power_on == 0` 直接 return（1247–1248）。配套 `pcie_encode_t_power_on()`（aspm.c 529–560，c93db4619277）。
- 系列的起因（v1，2025-11-04，Krishna Chaitanya Chundru）：「the root port exposes a T_POWER_ON value of zero in the L1SS capability registers, leading to incorrect LTR_L1.2_THRESHOLD calculations. This can result in improper L1.2 exit behavior and can trigger AER's」，v1 直接硬编 **80 µs（scale 1, value 8）**；Bjorn 当天回复引用 PCIe r7.0 §5.5.4（「based on the components and AC coupling capacitors … design implementation specific」）要求改成 DT 属性，于是有了 `t-power-on-us`（v4 3/3，2026-04-04，cover 说 dtschema 补丁已发：lore 2026-02-05，合入状态没查到）。
- **v7.3-rc4 里没有任何 DT 用它**（查了 kaanapali、kaanapali-mtp、sm8750、sm8650、sm8550、hamoa、glymur）；`make dtbs_check` 最多告警，不影响构建。

### 2.5 其它相关
- `broken_l1ss_resume`（ced835ae1f62，`pcie-qcom.c:1472-1488`）：系统睡眠期间 RC 关 PHY/撤票，端点在 L1SS 里拉 CLKREQ# 唤醒时可能超时 → 告诉设备驱动别指望状态保留。**只影响系统 suspend/resume**，与运行时 L1.2 无关。
- `cfg_1_9_0` 没有 `no_l0s`，所以 L0s 开着（700/s 的 L0s 进入）；sa8775p/sc8280xp 那类才禁 L0s。
- 主线 pcie-qcom 不写 DWC 的 `AUX_CLK_FREQ`（0xb40，安卓 pci-msm 写 20）；L1.1 每秒进 113 次、链路 4 小时没掉，说明 L1SS 定时器用的 aux 时钟频率默认值能用，不追。

## 3. 原因逐条

### 3.1 R1：数据过期——CAM 模式下固件的 LTR 是「active」值（最可能）
**证据链**
1. L1.1 进了 163 万次、L1.2 31 次。L1.1 的全部前提（两端 L1SS 使能、CLKREQ# 握手、refclk 可关、T_COMMONMODE/T_POWER_ON 已编程）L1.2 都共用，**唯一多出来的条件是 LTR ≥ 阈值**。能稳定进 L1.1 而几乎不进 L1.2，排除法只剩这一条。
2. 阈值不高：`2 + 4 + CM + T_POWER_ON`，RP 的 T_POWER_ON 还是 0（§2.4），比安卓的 153.6 µs 低。一个在 DTIM 之间睡着的 Wi‑Fi 固件本应轻松上报毫秒级。**所以问题在固件上报的值，不在阈值。**
3. 固件的 LTR 不是常数而是状态机。ath12k 的 WMI 参数枚举（`wmi.h:957-965`）里有 `WMI_PDEV_PARAM_LTR_ENABLE / LTR_AC_LATENCY_BE / _BK / _VI / _VO / LTR_AC_LATENCY_TIMEOUT / LTR_SLEEP_OVERRIDE / LTR_RX_OVERRIDE / LTR_TX_ACTIVITY_TIMEOUT`，还有 `L1SS_ENABLE`、`L1SS_TRACK`、`WMI_PDEV_L1SS_TRACK_EVENTID`、`WMI_TLV_SERVICE_L1SS_STAT`（730、966、993、2097）。**ath12k 任何地方都不用它们**（mac.c/wmi.c/core.c 零引用，固件走默认），但名字就是固件 LTR 模型的说明：按 AC 的 active 延迟、发送活动超时、Rx 覆盖、睡眠覆盖。这是从枚举名推断的，没有固件文档；但和「CAM 常醒 → 几乎不进 L1.2 → 偶尔 31 次」完全吻合。
4. **31 ≠ 0**。若固件把 Max=0 当「只许上报 0 ns」（R3 的 Kioxia 形态），L1.2 应该一次都进不去；31 次说明固件在 4 小时里至少有 31 个时刻上报了 ≥ 阈值（或「无要求」）的 LTR——最合理的解释是它偶尔真的睡了一下（扫描间隙、短暂断联之类）。
5. README 续航第三轮的时间线：03:28 第一次电池实测并抓到 L1.2 计数 → 03:41 死机 → 14:26 第二轮发现 Wi‑Fi 不省电 → 1041 修好 PS（`BSS_CHANGED_PS` 下发，ping 6.7 → 19.8 ms，0.48 → 0.42 W）。1041 之后固件 100 ms 无流量就打盹，LTR 应该跟着变大。**但没有再测**，计数器又禁读。这正是 §6 的 bench 要回答的第一个问题。

**预测**：1041 之后 L1.2 已在进，但进多少取决于 R2。bench 状态 1「L1.2 off」若比基线高出可测的量 → R1 成立；探针的 `MHI_SECS` 采样若看到 M2 以 DTIM 量级（每秒几次）进出 → 固件确实在睡，L1.2 的前提具备。

### 3.2 R2：主机侧链路活动把固件钉在 active（叠加在 R1 上，决定 1041 之后能进多少）
- 134 次/s 的 L1 退出 = 平均 7.5 ms 就有一次 TLP 往返。来源（按 README/RESEARCH/WAKEUPS 的唤醒清单推断，未逐一验证）：tailscaled 35 次/s 的网络活动、Claude 桌面版 22 次/s、CE 中断约 40/s（`ce2`，WAKEUPS §3 判断多半是到达的广播包）、NetworkManager/plasma‑nm 周期性 `station dump`（→ `ath12k_mac_op_sta_statistics` → WMI → 固件唤醒）、QRTR/MHI 控制通道、mDNS/IPv6 RA。
- 固件侧：若 LTR 的 `TX_ACTIVITY_TIMEOUT`/Rx 覆盖量级是几十 ms（名字只说有这个机制，值不知道），每 7.5 ms 一次主机活动意味着固件**永远在超时窗口内**，LTR 不会回到 sleep 值——即使 1041 让它在 DTIM 间打盹，PCIe 这一侧也看不到 sleep LTR。链路侧：L1.0 → L1.1 → L1.2 本身要先过 CLKREQ# 握手和 T_COMMONMODE，7.5 ms 的间隙里能进 L1.1（113/s 证明），但 L1.2 的窗口更短。
- ath12k 对 MHI 的「唤醒」是**逐次访问的瞬态**，不是持锁：寄存器偏移 ≥ `ACCESS_ALWAYS_OFF`（0xFE0，`pci.c:37`）的读写走 `ath12k_wifi7_pci_bus_wake_up()` = `mhi_device_get_sync()`，完事 `mhi_device_put()`（`wifi7/pci.c:61-72`、`pci.c:1170-1176/1206`）；`dev_wake` 0→1 才写 wake doorbell（`mhi/host/pm.c:1081-1116`），放掉就清。数据通路的 ring doorbell 走 shadow 寄存器 `0x8fc + 4n`（`wifi7/hal.h:18-23`，< 0xFE0；WCN7860 的 hw params `supports_shadow_regs = true`，0024），不触发唤醒。`ath12k_wifi7_mhi_config_wcn7850` 没设 `m2_no_db`（`wifi7/mhi.c:125-134`）→ `db_access = M0|M2`（`mhi/host/init.c:906-909`）→ `wake_toggle` 是 nop（`pm.c:1157`）：主机排包不会把设备从 M2 拉回 M0。0058 只改 panic 路径。**结论：MHI 侧没有「把链路按在 M0」的持锁；但每一次 WMI/统计/控制面访问都是一次真实的链路往返。**
- 这些活动决定的是 L1 的驻留率和退出次数，也（经固件的活动超时）决定 L1.1/L1.2 的选择。对功耗来说，减少退出次数比 L1.1→L1.2 值钱得多（§7.3）。治法全在 WAKEUPS.md（tailscaled portlist、helperd 轮询、PowerDevil、冻结桌面应用）和路由器侧的广播。

### 3.3 R3：端点 LTR Max 寄存器为 0、固件把 0 当上限（Kioxia 形态；可测，但证据偏弱）
- 事实：端点的 LTR Max Snoop/No‑Snoop Latency 在 DT 平台上没人写（§2.2），上电为 0。
- 先例（lkml 2022-09/12，`[PATCH v7] PCI/ASPM: Update LTR threshold based upon reported max latencies`）：Kioxia NVMe 在高通平台上 L1.2 进不去，Matthias Kaehlcke 调试结论「It seems the Kioxia firmware has a bug which interprets all 0 values as a max latency of 0ns … the Kioxia NVMe can enter L1.2 if the max latencies are set to values ≥ the LTR threshold」，并指出「there are NVMe models that don't have issues with entering L1.2 with max (no-)snoop latencies of 0」；Mani 的看法「if the device reports snoop/no-snoop scale/value as 0, then it implies that the device won't tolerate any additional delays from the host」，并同意「it is a firmware issue」。高通把阈值夹到 Max 值的补丁因「covering up for the device firmware issue」没合入——所以主线至今就是：**Max = 0 → 看固件心情**。
- **本机的两条反证**：(a) 31 次 L1.2（§3.1 第 4 条）：Kioxia 形态下应为 0；(b) 安卓同机：pci-msm 的 `msm_pcie_config_l1ss()`（`pci-msm.c:8261-8322`，CodeLinaro `kernel.lnx.6.6.r1-rel`）对每个设备只做 `DEVCTL2 |= LTR_EN` 和 L1SS CTL1 四个使能位，**全文件没有任何写 LTR Max 的地方**（grep `ltr` 只命中 `MSM_PCIE_INT_EVT_LTR` 枚举）；而安卓的 DRV/CESTA 链以 L1.2 为前提（§4）。剩下的缺口是 cnss2（安卓 Wi‑Fi 平台驱动，要登录）或 WLAN host 驱动是否写了 Max——读不到，所以 R3 没法彻底排除。
- 处置：探针看 Max 是否 0ns 只是前提；真正定夺的是 §6 状态 7 的 setpci 实验（Max 写成 3 ms，看功耗有没有差）。有差 → 1045 的模块参数部分固化；无差 → R3 出局。

### 3.4 已排除
| 嫌疑 | 为什么排除 |
|---|---|
| CLKREQ#/refclk/PHY | L1.1 需要两端放开 CLKREQ#、refclk 关掉再恢复，每秒进 113 次 → 这条路通。`clkreq-n-pins` = gpio103 `pcie0_clk_req_n` 上拉（`baldur-wifi.dtsi:79-84`），和安卓 `qcom,pcie-clkreq-pin = <0x67>`（=103）一致；`gcc_pcie_0_aux_clk` 19.2 MHz 开着（审计 414 行）。 |
| 能力位/使能位 | lspci：`L1SubCtl1 ASPM_L1.2+`、`DevCtl2 LTR+` 两端；`aspm_l1ss_init()` 没剥掉 L1.2（否则 sysfs 里不会有 `l1_2_aspm`，lspci 也不会显示使能）。 |
| 阈值太高 | 我们的阈值 `6 + CM + 0` 比安卓的 153.6 µs 低（§2.2）。 |
| ath12k 禁 ASPM | `ath12k_pci_aspm_disable()`（`pci.c:900-917`）只在 `power_up` 固件下载期（1448–1451）清端点 LnkCtl 的 L0s/L1，`ath12k_pci_start()`（1148–1157）在多 MSI 向量（dmesg「MSI vectors: 16」）时 `ath12k_pci_aspm_restore()`（939–946，`supports_aspm` 为 WCN7860 由 0024 设 true）写回；失败路径 1477–1478 也写回。只动 LnkCtl，不碰 L1SS CTL1。瑕疵：绕开 aspm.c 的记账（`link->aspm_enabled` 在那一瞬不准），无关结果。 |
| 0049 槽位热插拔位 | 只影响 `pci_bridge_d3_possible()`（s2idle 走 D3cold），与运行时 L1.x 无关。 |
| 0072 FORCE_MEM_CORE_ON | 让 pipe clk 的 mem/periph core 常开，解决入站 DMA 完成超时；不改 L1SS 行为。保留。 |
| 0078 WAKE# 低有效 | 只影响 `wake-gpios` 的唤醒中断极性（s2idle 2.5 s 假醒）。 |
| MHI M3 / runtime PM | ath12k 的 `runtime_get/put` 是空函数（`ath12k/mhi.c:103-110`）；没有 runtime suspend，也就没有 M3 相关的链路动作。 |
| pcie-qcom 运行时 PM | probe 里 `pm_runtime_get_sync` 后不 put（2160、2334 只在出错路径），控制器永远 active。这决定 SoC 侧时钟不关，但不影响链路自己的 L1.x 选择。 |
| `pci_walk_bus` 对 Root Port 的那次 `pci_enable_link_state_locked` | no-op（§2.3 复核补充），不影响使能顺序。 |

### 3.5 旁注：Root Port 的 T_POWER_ON = 0（安全项）
- kaanapali DT 没有 `t-power-on-us` → `dw_pcie_program_t_power_on(pci, 0)` 直接 return（`pcie-designware.c:1247-1248`）→ Root Port 报 `PortTPowerOnTime=0us`（高通自己的描述）。
- 后果：`t_power_on = max(0, EP 的值)` 只剩端点那一份 → `T_PwrOn` 和阈值都比真实 PHY/refclk 恢复时间小。L1.2 退出时端点按较短的 T_PwrOn 开始驱动链路，而 Root Port 这边 PHY 还没好 → 「improper L1.2 exit behavior … AER」（高通原话）。
- 目前几乎不进 L1.2，所以还没撞上；**一旦 1041 之后 L1.2 真的在进（R1 的预测），这就从旁注变成前提**。修法就是 DT 一行 `t-power-on-us = <80>`（§7.1）。方向上它让阈值变大约 80 µs（更难进 L1.2），对睡着的固件无关紧要——安卓阈值 153.6 µs 下固件照样进。

## 4. 安卓对照（本地 vendor DT，`coloros-v17/image/vendor_boot_a.img` 内 blob 12「CanoeP v2 SoC」msm-id 0x295 v2；dtbo blob 47 board-id 0x2000b 只给 `pcie` 加了 `gdsc-phy-vdd` 电源域、给 `pcie_rp` 挂了 `cnss_pci0`，没改下面任何值）

| vendor `pcie@1c00000` 属性 | 值 | 含义（pci-msm 6.6 源码） |
|---|---|---|
| `compatible` | `qcom,pci-msm` | 高通下游驱动，自己管 L1SS，不靠 aspm.c |
| `qcom,l1-2-th-scale / value` | 2 / 0x96 (150) | `msm_pcie_config_l1_2_threshold()`（8350–8382）把 `scale<<29 \| value<<16` 直接写进每个设备的 CTL1 → **LTR_L1.2_THRESHOLD = 150 × 1024 ns = 153.6 µs** |
| （LTR） | 无属性 | `msm_pcie_config_l1ss()`（8261–8322）只置 `DEVCTL2.LTR_EN`，**不写端点 LTR Max**（R3 的反证之一） |
| `qcom,drv-l1ss-timeout-us` | 0x1388 = 5000 | `msm_pcie_cesta_enable_l1ss_to()`（3937–3950）：`PARF_L1SUB_AHB_CLK_MAX_TIMER` = 5 ms × aux 时钟频率；链路在 L1SS 里待满 5 ms → 给 CESTA 发 L1SS 超时 → 状态机关 PCIe 资源（apps‑pc 期间由硬件托管）|
| `qcom,drv-name` | `cesta` | DRV 由硬件 CESTA 实现（非 `cesta` 名字才走软件 DRV）|
| `qcom,aux-clk-freq` | 0x14 = 20 | 写 `PCIE20_AUX_CLK_FREQ_REG`（0xb40），aux 时钟档 |
| `qcom,ep-latency` | 0xa = 10 | PERST 释放后 `usleep_range(10 ms)` 再枚举（6391 行），**与 LTR 无关** |
| `qcom,target-link-speed` | 3 | Gen3，和主线 `max-link-speed = <3>` 一致 |
| `qcom,pcie-clkreq-pin / offset` | 0x67 (103) / 0x2c48 | CLKREQ# 走 GPIO103，安卓把它设成 PDC 唤醒源（4056–4066 行） |
| `pdc@b370000` | `qcom,canoe-pcie-pdc` | 安卓独有的 PCIe PDC |
| `qcom,cnss-peach@b0000000`（dtbo） | 无 LTR 相关属性 | 只有 PDC 电源轨投票表、bus-bw 表、iommu 等 |

读法：
- 安卓的阈值 153.6 µs **比我们 aspm.c 算出的大**。安卓能进 L1.2 而我们几乎不能，说明不是「我们阈值太高」，而是**端点在我们这边（CAM 时）上报的值连较低的阈值都不到**——回到 R1/R2。
- 安卓的 pci-msm 和主线一样不写端点 LTR Max，却指望 L1.2——除非 cnss2/WLAN host 写了（读不到），这就是固件**不**按 Kioxia 形态解释 Max=0 的证据（R3 降级）。
- 安卓 DRV 的收益链是「L1.2 → 5 ms → CESTA 关资源 → apps‑pc 期间 CX 可塌」。主线没有这一整条，所以 L1.2 在我们这边的收益只有链路两端 PHY 那一点（§7.3）。RESEARCH.md §2.5/§4 的判断不变。
- 03:41 那次死机读的 `link_transition_count`，主线和 pci-msm 一样是从 `mhi` 寄存器区（0x01c03000）读 0xc84/0xc88（pci-msm 2676–2683 行也用 `pcie_dev->mhi`），地址没错，挂死原因仍不清楚（怀疑读时 PCIe AHB/GDSC 在低功耗态）。**禁令不变。**

## 5. 平板上怎么验证——不读寄存器

**工具**：`tools/y700-l1ss-probe.sh`（root 运行，纯 PCI 配置空间读 + sysfs；`lspci -vvv` 的 ecap 解码要 root；可选 `MHI_SECS=30` 开一个 tracepoint 采 30 s）。装到 `/usr/local/libexec/`。

| 看什么 | 在哪 | 怎么读 |
|---|---|---|
| EP 的 LTR 上限 | `lspci -vvv -s 01:00.0` → `Latency Tolerance Reporting` → `Max snoop latency: Nns / Max no snoop latency: Nns` | **0ns = 没人写过**（预期）→ R3 的前提成立，但不是证据；要靠 §6 状态 7。非 0 → 有东西（bootloader？）写过，R3 出局。 |
| 两端 T_POWER_ON / 共模恢复 | `L1SubCap: … PortCommonModeRestoreTime=Aus PortTPowerOnTime=Bus`（两端） | RP 预期 B=0（§3.5）。记下 EP 的 A、B。 |
| 实际阈值 | EP/RP 的 `L1SubCtl1: … T_CommonMode=Cus LTR1.2_Threshold=Nns`、`L1SubCtl2: T_PwrOn=Dus` | 应等于 `2+4+max(A)+max(B)` µs 向上取整（探针自己算并对比）。这就是固件 LTR 必须 ≥ 的门槛；和安卓的 153.6 µs 比一下。 |
| 使能 | `L1SubCtl1: PCI-PM_L1.2- PCI-PM_L1.1- ASPM_L1.2+ ASPM_L1.1+`、`LnkCtl: ASPM L0s L1 Enabled; … ClockPM±`、`DevCtl2: … LTR+` | 任一不对 → 回头查 aspm.c 路径。PCI‑PM L1.x 只在 D3hot 有意义，运行时 EP 在 D0，`-` 是正常的。 |
| 固件多久睡一次（新） | `MHI_SECS=30`：tracefs `events/mhi_host/mhi_tryset_pm_state`（`pm.c:135`，每次主机侧 MHI PM 状态切换：`M0` 醒、`M2` 设备空闲、`M3` 挂起）。tracepoint 由 `CONFIG_TRACEPOINTS` 编入（`init.c:22-23` `CREATE_TRACE_POINTS`），**不需要** `MHI_BUS_DEBUG`。只开事件、不读任何寄存器；用完还原 `tracing_on`/事件开关并清缓冲；若 `set_event` 已有人在用（y700-wakeups 在跑）就跳过。 | `M2` 每秒几次（DTIM 量级）→ 固件确实在打盹，L1.2 的前提具备，剩下看 R2；≈0 → 固件没离开 M0，先查 1041 是否生效（`iw dev wlp1s0 get power_save` 只反映 mac80211 标志，不算证据）和主机活动。注意 M2 是「MHI 层空闲」，不等于「链路进了 L1.2」，后者无法直接观测。 |
| sysfs 旋钮 | `/sys/bus/pci/devices/0000:01:00.0/link/{clkpm,l0s_aspm,l1_aspm,l1_1_aspm,l1_2_aspm,l1_1_pcipm,l1_2_pcipm}`（挂在端点上，`aspm_ctrl_attrs_are_visible` 只显示 `aspm_capable` 的） | 全 1 = 现状。写 0/1 是配置空间写，安全。注意 aspm.c 的语义（1716–1745）：`l1_aspm=0` 会连带禁 L1SS，但 `l1_aspm=1` **不会**把 L1.1/L1.2 带回来，要再写各自的文件（bench 已照此恢复）。 |
| 策略 | `/sys/module/pcie_aspm/parameters/policy` | `default`。不必改 `powersupersave`（多出来的只是 PCI‑PM L1.x，运行时无用）。 |
| 出错迹象 | `dmesg \| grep -iE 'AER\|Link Down\|aspm'` | 做 LTR 实验时盯着：出现 `AER: Corrected/Uncorrected error … 01:00.0` 或 link down 就停。 |

**L1.2 驻留率本身在不读寄存器的前提下无法直接观测**（唯一的计数器就是被禁的 debugfs；没有 ASPM tracepoint；`ATH12K_TRACING` 没编）。只能用功耗 A/B 间接推断，见 §6。

## 6. 测量计划：`tools/y700-l1ssbench.sh`

前提（脚本自检：电池放电（`FORCE=1` 可绕）、Wi‑Fi 关联着；**只记录不校验**：`iw dev wlp1s0 get power_save`——它显示的是 mac80211 自己的标志，1041 之前也是 on（README 续航第三轮），固件省电是否真开只能靠「内核带 1041」这一事实保证）、屏幕由脚本自己 DPMS 关、`systemd-run` 独立运行、期间不 ssh（更别从 tailnet 上去，WAKEUPS §1 的规矩）。每个状态只动一个旋钮，测完立即还原；基线首尾各一次看漂移；默认 `SECS=120`（电池电流 5–8 s 才更新一次，比 offbench 的 75 s 长），`SETTLE=15`。日志 `/var/log/y700-l1ssbench.txt`，前后各附一份探针快照。

| 状态 | 动作 | 预期 / 读法 |
|---|---|---|
| 0 基线 | 熄屏、全开 | |
| 1 L1.2 off | `l1_2_aspm=0` | **明显高于基线 → 1041 之后 L1.2 其实在进且有价值（R1 成立）**；≈ 基线（±0.03 W 内）→ L1.2 要么没在进（R2/R3），要么不值一测 |
| 2 L1.1 off | `l1_1_aspm=0`（链路只能 L1.0 或 L1.2） | 比基线高多少 = 子状态总共值多少（refclk/PLL 关不关）；若和状态 1 一样高 → 现在确实靠 L1.1 过日子 |
| 3 L1 off | `l1_aspm=0`（只剩 L0s） | 上界参考：L1 全家值多少 |
| 4 L0s off | `l0s_aspm=0` | L0s 700/s 的进出值不值；若关了反而省电（L0s 进出开销 > 收益），这是一个零风险的 DT 改法（`aspm-no-l0s`） |
| 5 ClockPM off | `clkpm=0` | 预期无差（L1SS 自己管 CLKREQ#） |
| 6 基线 | | 漂移 |
| 7 LTR 实验（`LTR_US=3000` 时） | 两寄存器都读到 0 才做：`l1_2_aspm=0` → DevCtl2 LTR_EN 清 → `setpci ECAP_LTR+4.L = 0x0c5c0c5c`（3 ms：scale 3 ×32768 ns，value 92）→ LTR_EN 回 → `l1_2_aspm` 回 → 等 5 s 看 dmesg → 测 → 还原 → 再测一次基线 | **比基线低 ≥0.03 W → R3 证实，固件把 Max=0 当上限**，上 §7 的补丁固化；无差 → R3 出局（固件无视 Max，或 L1.2 本就不值钱），收工 |

解释时的三条底线：(1) 噪声 ±0.03 W（README 实测），单次差值小于它不作数，可做 ABAB 或把 `SECS` 拉到 180；(2) 状态 7 期间任何 AER/link down → 脚本自动还原并记录，之后别再用那个值，先补 §7.1 的 DT 再试；(3) R2 的预测是「主机越安静，状态 1 和基线的差越大」——装了 WAKEUPS.md 的 drop-in 之后值得重跑一次状态 0/1/6。

## 7. 内核改动：值不值、改什么、能省多少

### 7.1 `linux/kernel-y8/1045-pcie-qcom-l1ss-t-power-on-ltr-max.patch`（**未编译、未上机**；`git apply --check` 在 v7.3-rc4 + 0049 + 0056 + tb323fu dts 上通过，两个 C 文件 hunk 偏移 6 行）
两部分，相互独立，可以只收一半：
- **DT**：`arch/arm64/boot/dts/qcom/baldur-wifi.dtsi` 的 `&pcie_port0` 加 `t-power-on-us = <80>;`。用的是 7.3 已合入的机制（§2.4），值是高通 v1 补丁里的 80 µs。它只在链路真的进 L1.2 时才有作用（退出时序正确、阈值 +80 µs），平时零影响。**建议无论实验结果如何都收**：R1 的预测就是 L1.2 已经在进，这是让它安全发生的前提。
- **pcie-qcom.c**：模块参数 `pcie_qcom.ltr_max_latency_us`（默认 0 = 不动任何东西）。非 0 时在 `qcom_pcie_enable_aspm()` 的总线遍历里、`pci_enable_link_state_locked(ALL)` 之前，对 LTR Max 寄存器为 0 的端点：清 `DEVCTL2.LTR_EN` → 以 dword 写 Max Snoop/No‑Snoop（编码：scale n = 2^(5n) ns，向上取整）→ 恢复 LTR_EN。顺序合规性已复核（§2.3 补充）：Root Port 那次回调是 no-op，端点回调时 L1SS 还没开；resume 路径 `post_init` 先于端点的 `pci_restore_state()`——PERST 之后 Max 读 0 且 L1SS 未使能，再写一次无害；配置保住时读到非 0 直接返回。端点是焊死的，没有热插拔路径要管。等价于 x86 BIOS 做的事。审稿补注：代码读 `pdev->ltr_path`，而 `include/linux/pci.h:439-445` 把它放在 `#ifdef CONFIG_PCIEASPM` 里——我们的配置有 `PCIEASPM=y`，编得过；但这样写不能直接上游（上游 pcie-qcom.c 在无 ASPM 配置下也要编过），真要用再改成读回 `DEVCTL2.LTR_EN` 原值。**只有 §6 状态 7 测出差值才用它**，命令行加 `pcie_qcom.ltr_max_latency_us=3000`（内核内建，参数前缀是 `pcie_qcom`）。
- 另一种写法（没采用，记下理由）：`DECLARE_PCI_FIXUP_EARLY(17cb, 110e, …)` 在 `pci_setup_device()`（`probe.c:2084`）时写 Max，那时 `pci_configure_ltr()`（2457，在 `pci_device_add` 2730 里）还没置 LTR_EN，不需要来回切。但 quirks.c 是全系统通用文件、要再加 `of_have_populated_dt()` 和模块参数的判断，而且规范层面两种写法等价；放在 pcie-qcom.c 里和我们其它 y 补丁同一位置，更好接盘。
- 没做 / 不建议做：
  - 改 aspm.c 的阈值公式去迎合 Max=0（上游 2022 年明确拒绝，理由是掩盖固件问题）。
  - 用 `WMI_PDEV_PARAM_LTR_*` 让固件改上报值：ath12k 不用这些参数，WCN7860 固件是否接受未知，而且这是「让固件谎报能忍的延迟」，有丢包/延迟风险；留作下一步实验，不进补丁。倒是 `WMI_PDEV_PARAM_L1SS_TRACK` + `WMI_PDEV_L1SS_TRACK_EVENTID`（固件上报 L1SS 统计）如果固件支持，是一条不读寄存器就能看 L1.2 的路——需要在 ath12k 里加事件解析，下一轮再说。
  - 移植 DRV/cesta/pcie‑pdc 或给 pcie-qcom 加运行时 PM：不在主线、工程量大、收益要等 ss3 问题解决（RESEARCH §4）。
  - `pcie_aspm.policy=powersupersave`：只多开 PCI‑PM L1.x，运行时端点在 D0，无用。
  - 把 1045 直接编进 y10：规矩是先本地验证。建议在 y10 构建时作为可选项带上 DT 一行（零风险），模块参数部分等实验结果。

### 7.2 预期顺序
1. 探针（5 分钟，只读；`MHI_SECS=30` 多等 30 s）→ 2. bench 不带 `LTR_US`（约 20 分钟）→ 3. 状态 1 明显高于基线 → R1 成立，只收 DT 一行，本文 §8 记结论，L1.2 这题收工，剩下的全是 WAKEUPS 的事；状态 1 ≈ 基线且探针 Max=0 → 带 `LTR_US=3000` 再跑 → 4. 有差 → 1045 两部分都收，y10 验证时看 `dmesg` 有无 AER、ping 延迟是否变化（L1.2 退出比 L1.1 多 T_POWER_ON ≈ 80 µs，对 ping 不可见）；无差 → 只收 DT 一行。

### 7.3 能省多少（要说实话）
- 可动的总盘子：Wi‑Fi 关联 vs rfkill 的差 **0.06 W**（0.42 − 0.36，1041 之后）。里面大致是：WCN7860 芯片省电睡眠本身（AON 轨、XO、每 DTIM 醒一次）、链路两端 PHY 在 L1.x 里的静态功耗、SoC 侧 PCIe 控制器时钟/GDSC（主线永远开着，与 L1.x 无关）、每秒 134 次 L1 退出 + 对应的主机/固件工作。
- L1.1 → L1.2 多关的只有两端的共模电压保持和接收检测电路（refclk/PLL 在 L1.1 就已经关了）。按 PCIe PHY 的一般数量级，x2 链路两端合计 **≤ 0.01–0.02 W**，很可能在 ±0.03 W 噪声里测不出来。所以这项的意义是「与安卓对齐、为将来任何需要 L1.2 的事（DRV 类）打底、而且便宜」，不是续航数字。
- 对比：L1 退出从 134/s 压到 30/s（治 tailscaled/Claude/轮询统计）可能省的更多，而且同时服务于 RESEARCH §3.7 / WAKEUPS 的唤醒率目标——那才是 Wi‑Fi 这块该追的主线。

## 8. 结论、风险、开放问题、周期性义务
- **结论**：L1.2 几乎进不去的最可能解释是**那组数据测于固件 CAM 常醒时，固件按活动状态上报的 LTR 一直是 active 值**（R1），1041 之后应已改观但没测；1041 之后能进多少由主机侧链路活动决定（R2，每 7.5 ms 一次往返）。「DT 平台没人写 LTR Max、固件把 0 当上限」（R3）有先例但本机有两条反证，降为可一次实验排除的备选。链路硬件和内核配置这一侧（CLKREQ#、能力位、aspm.c 的使能、遍历顺序）没有问题。Root Port T_POWER_ON=0 是必须先补的安全项。收益上限很小，先测后改。
- **风险**：L1.2 真的发生后若 T_POWER_ON 不补，可能出 AER/链路掉（固件会被 ath12k 复位恢复，不是死机）；setpci 写的是端点配置空间，不是 03:41 那种 AHB 寄存器读，没有总线挂死风险；探针的 tracefs 采样只开 tracepoint，不读寄存器。
- **开放问题**：(1) WCN7860 固件到底上报什么 LTR——没有寄存器就看不见，只能靠 A/B 推，或等 `L1SS_TRACK` 事件解析；(2) 安卓 cnss2 / WLAN host 是否写 Max 寄存器（源码要登录，没读到）；(3) 固件 LTR 的活动超时量级（R2 的强弱全看它）；(4) dtschema 何时收 `t-power-on-us`；(5) 上游会不会给 kaanapali.dtsi 加 `t-power-on-us`（加了就删我们 DT 那一行）。
- **周期性义务（给 upstream-check 的关注词建议，别改我没改的文件）**：`pcie-qcom` 的 `l1ss|L1.2|LTR|t-power-on|DRV|cesta`、`ath12k` 的 `LTR|L1SS|aspm`、`PCI/ASPM` 的 `LTR_L1.2_THRESHOLD|Max Snoop`。每次升基线内核：grep `arch/arm64/boot/dts/qcom/kaanapali*.dts*` 有没有 `t-power-on-us`。

## 9. 出处索引
- 源码（v7.3-rc4，GitHub raw torvalds/linux，复核时逐条重读）：`drivers/pci/pcie/aspm.c`（30–67 LTR save/restore；514–560 T_PwrOn 编解码；569–606 阈值编码；677–781 `aspm_calc_l12_info`；783–832 `aspm_l1ss_init`；885–932 DT 默认态；1297–1352 `pci_configure_ltr`；1463–1474 `pcie_aspm_get_link`；1557–1583 `__pci_enable_link_state`；1716–1745 sysfs store）、`drivers/pci/bus.c`（408–424 `__pci_walk_bus`）、`drivers/pci/probe.c`（2084 early fixup；2452–2457 `pci_configure_device`→`pci_configure_ltr`；2730/2746；2897 `pcie_aspm_init_link_state`）、`drivers/pci/controller/dwc/pcie-qcom.c`（1077–1082 L1SS 使能；1110–1127 全开遍历；1376–1382 `configure_ports`；1472–1488 `broken_l1ss_resume`；1832–1849 debugfs 计数；2056 `t-power-on-us`；2160 `pm_runtime_get_sync`）、`pcie-designware.c`（1216–1266）、`pcie-designware-host.c`（671–676、1322–1323）、`drivers/net/wireless/ath/ath12k/pci.c`（37、900–947、1148–1157、1170–1260、1448–1478）、`wifi7/pci.c`（61–77）、`wifi7/mhi.c`（125–134）、`wifi7/hal.h`（18–23）、`wmi.h`（730、957–971、993、2097）、`drivers/bus/mhi/host/{pm.c,main.c,init.c,trace.h}`（pm.c 135/805/1081–1116/1157；main.c 504；init.c 22–23/906–909；trace.h 120/150/257）、`include/uapi/linux/pci_regs.h`（687、1008–1014、1133–1153）、`arch/arm64/boot/dts/qcom/{kaanapali,kaanapali-mtp,sm8750,sm8650,sm8550,hamoa,glymur}.dts*`。
- 上游提交（GitHub API）：e9769bb17269 / c93db4619277 / d697e9067248（T_POWER_ON，2026-04-28）、ced835ae1f62（broken L1SS resume）、a00bba406b5a（L1SS 只在驱动声明时广播）、df5192d9bb0e（DT 默认只开 L0s/L1）、eacf92a29af9（DT `aspm-no-*` 属性）。
- 邮件（lkml.iu.edu 镜像，本地存档复读）：`[PATCH] PCI: qcom: Program correct T_POWER_ON value for L1.2 exit timing`（2025-11-04，80 µs）及 Bjorn 同日回复（引 PCIe r7.0 §5.5.4）；`[PATCH v4 3/3] PCI: qcom: Program T_POWER_ON`（2026-04-04）；`[PATCH v7] PCI/ASPM: Update LTR threshold based upon reported max latencies`（2022-09-16）及 Mani（2022-12-05/22）、Matthias Kaehlcke（2022-12-05）的讨论。lore/patchwork 的原帖有反爬，没读。
- 安卓：`coloros-v17/image/vendor_boot_a.img`（blob 12，CanoeP v2）、`dtbo_a.img`（blob 47，board 0x2000b）内存解析；pci-msm 下游源码 `git.codelinaro.org clo/la/kernel/qcom` 分支 `kernel.lnx.6.6.r1-rel` `drivers/pci/controller/pci-msm.c`（8261–8322 `msm_pcie_config_l1ss`、8350–8382 `msm_pcie_config_l1_2_threshold`、3937–3956 CESTA L1SS 超时；6.12 分支 404；cnss2 平台仓库需登录——拿到的是 auth0 跳转页）。
- pciutils（GitHub pciutils/pciutils master）`ls-ecaps.c`（72/77 `Max snoop latency`、1470–1506 L1SubCap/Ctl 字段）/ `ls-caps.c` / `setpci.c`（355 `CAP_EXP`、381 `ECAP_LTR`）：lspci 字段措辞与寄存器名。
- 本仓库：README 续航第三轮、`linux/power/cx-collapse/{RESEARCH,PROTOCOL}.md`、`linux/power/WAKEUPS.md`、`cx-audit-2247.txt`、`linux/kernel-y8/inventory/`、`linux/tb323fu-linux/kernel/{patches,dts}`、`tools/y700-offbench.sh`（bench 的模板）。

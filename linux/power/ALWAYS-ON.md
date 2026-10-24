# 熄屏不休眠时的常开外设 —— 逐项裁决（y9 审计 2026-10-15 22:47 → 2026-10-16）

**范围**：`cx-collapse/cx-audit-2247.txt`（y9，亮屏、充电中）里的 pm_genpd / clk_summary / interconnect / wakeup_sources 汇总，
加 [RESEARCH.md §1.2 B](cx-collapse/RESEARCH.md) 列出的常开项，逐项问三件事：**它为什么开着、能不能关、关了值多少**。
全部结论来自只读阅读：仓库审计原文、`kernel-y8/inventory/`、上游 tb323fu-linux 的补丁/DT/用户态文件，以及 v7.3-rc4 公开源码
（GitHub raw；行号均指 v7.3-rc4，本机 y9 = v7.3-rc4 + 上游 0001–0130 + 我们的 y 补丁，涉及的文件没有被这些补丁改动，除注明外）。
**没有碰平板、没有编译、没有安装任何东西**；下面写的规则/补丁文件都放在本目录，等作者点头再装。

> 诚实的总帐：六项里**没有一项能单独测出功耗差**（电池电流 5–8 s 更新一次，<0.03 W 不可测）。它们的意义分两层：
> (a) 外设本地功耗，全部是毫瓦级；(b) **是否挡着 XO 关断（aosd）/ CX 塌缩（cxsd）**——这层只在 ss3（apps-pc）放开之后才有意义
> （RESEARCH §1.3：今天 APSS 运行时根本不进 ss3，所以 cxsd/aosd 全 0 与这些外设无关）。做它们的理由是"方向对、顺手、零风险"，不是数字。

## 0. 一页纸

| # | 审计里的现象 | 真相（证据见各节） | 能做什么 | 预估 | 风险 | 本目录产物 |
|---|---|---|---|---|---|---|
| 1 | CDSP running，`bi_tcxo` 的 consumer 列写着 `26300000.remoteproc xo` | **CDSP 不持 XO**：`bi_tcxo enable_cnt 2` = 两个使能的子时钟（`dsi0vco_clk`+`bi-tcxo-div2`），consumer 列只是"注册过的用户"不是"使能者"；PAS 驱动在 handover 后已 `clk_disable_unprepare(xo)`。CDSP 开机 13 s 后一直睡，没有任何用户（fastrpc 0 引用，hexagonrpcd 只用 ADSP） | 不启动它：`tb323fu-dsp.service` 的 drop-in 只起 adsp。**不**在运行时 `echo stop` | ≈0 W（它本来就 100% 在睡）；少 4.9 MB 固件加载、少 3 个 fastrpc 节点、少一个 QRTR/glink 边 | 极低；代价是以后想试 NPU 要手动 `echo start` | `tb323fu-dsp-no-cdsp.conf`（未装） |
| 2 | `gcc_usb3_phy_gdsc on`，`88e8000.phy active`，控制器已挂起 | 三重原因叠加：(a) qmp-combo probe 里 `pm_runtime_forbid()`（上游策略，power/control 默认 on）；(b) 同域里还挂着 `aux_bridge.aux_bridge.0`，它没有 runtime PM（"unsupported"），genpd 永远不会把域关掉；(c) 0059 把该 GDSC 改成 `PWRSTS_RET_ON`，`gdsc_disable()` 直接 return——**genpd 显示 off 也不会真的掉电**（`gcc_usb30_prim_gdsc off-0` 同理，硬件其实开着）。PHY 自己的时钟/稳压器在 dwc3 挂起时的 `phy_exit` 里已经关了 | 什么都不装：udev 把 PHY 改 auto 是零效果 | 0 | — | 无（写明不做的理由） |
| 3 | 蓝牙 UART `gcc_qupv3_wrap3_s5_clk` 51.2 MHz 常开 | geni 串口有 runtime PM，但引用在 `startup()` 拿、`shutdown()` 放：hci0 只要 Powered，serdev 一直 open，SE 就一直醒。hci_qca 的 IBS 睡眠投票 `__serial_clock_on/off()` 是**空的 TODO 存根**，到不了串口驱动。DT 的 uart18 没有 RX 唤醒中断 | 现成的只有"蓝牙关"（已实测 0.54 vs 0.55 W，噪声内）。真修要三层内核工作 + DT（§3） | <0.01 W；它是 XO 关断的阻塞者之一（经 gpll0） | 中（BT 掉事件） | 无；§3 给了设计 |
| 4 | UFS ICE 403 MHz（`1d88000.crypto`）、`gcc_ufs_phy_gdsc on` | ICE 时钟跟 UFS 主机 runtime PM 走（`ufs_qcom_suspend()` 末尾 `qcom_ice_suspend()` 关它），**不**跟 150 ms 的 clk gating 走；审计时脚本自己在写盘，UFS 当然 active。真问题：kaanapali 的 ICE 节点带 `power-domains = GCC_UFS_PHY_GDSC`，而 `ice.c` 没有 runtime PM → pm_genpd 里 `1d88000.crypto unsupported` → **UFS 主机的 GDSC 永远关不掉**，主机挂起了也没用（sm8550/sm8650/sm8750 的 ICE 节点同样带 power-domains，binding 对这几代 SoC 还把它列为**必需**——通病，不是 kaanapali 特有；主线上这些 SoC 的 UFS GDSC 运行时也从未关过，linux-next 无人在修） | 内核：给 ice.c 加 runtime PM（草案补丁，未编译未测） | 一个 CX 内 GDSC 的漏电，毫瓦级；是 E3b（CX 真塌）的前置条件之一 | 中：运行时让 UFS GDSC 真掉电是本机新行为，要 trial 内核 + 作者在场 | `soc-qcom-ice-runtime-pm.DRAFT.patch` |
| 5a | LPASS 6 个 19.2 MHz codec 时钟 | 五个 lpass macro 全部 runtime-active（`LPASS_HW_MACRO/DCODEC` 各 5 票）。macro 自己 100 ms 就会自动挂起，能把它们按住的是 soundwire 主控（`swclk_gate_enable()` 对 macro `pm_runtime_resume_and_get`，主控 3 s 自动挂起）或正在跑的 PCM。亮屏充电时谁按着没法离线判断 | 只读核对（§5a）；查出来再说 | 毫瓦级（在 LPASS 岛内，ADSP 93% 时间在 island） | — | `always-on-check.sh` 的 LPASS 段 |
| 5b | `rtc@6100` 唤醒源 25 分钟 61 次 | **最可能不是闹钟，是 61 次失败的 `rtc_set_time()`**：`CONFIG_RTC_SYSTOHC=y` + chrony `rtcsync` → 每次 chrony 调 `adjtimex()` 内核就试写 RTC → pm8xxx 没有 `nvmem-cells`/`allow-set-time` 返回 `-ENODEV` → 但 `rtc_set_time()` 无条件 `pm_stay_awake()` 计一次。每次 ~0.08 ms（total_time 5 ms/61 次吻合） | 60 s tracepoint 抓现行（脚本 `--rtc`）；确认后 chrony.conf 去掉 `rtcsync`（RTC 本来就写不进去，零功能变化） | ≈0 W；只是去掉唤醒帐里的噪声 | 零 | `y700-rtc-sync-off.sh`（未装） |
| 6 | pcie0 GDSC/pipe clk | 交叉引用 PCIe 专题。补一个这里看到的共性：`1c06000.phy unsupported`（qmp-pcie 无 runtime PM）→ `gcc_pcie_0_phy_gdsc` 永远 on；`pcie-qcom` probe 后 `pm_runtime_get_sync` 不放 → `gcc_pcie_0_gdsc` 永远 on | 见 PCIe 专题 | — | — | — |

**读审计前先纠正两个读法**（影响全部六项）：

1. `clk_summary` 每个时钟后面的 `consumer / connection id` 列是 `hlist_for_each_entry(clk_user, &c->clks, …)`——**所有 `clk_get()` 过的用户**，第一个印在同一行，其余各占一行（`drivers/clk/clk.c: clk_summary_show_one()`）。它不表示谁在使能。审计脚本用 `$2>0` 过滤只留下了每个时钟的第一行，于是"`bi_tcxo … 26300000.remoteproc xo`"被读成了"CDSP 持 XO"。真正的使能者看 `enable_cnt` 怎么分：父时钟的 enable_cnt = 使能的子时钟数 + 直接 `clk_enable` 它的用户数。
2. `pm_genpd_summary` 设备行的 `runtime status` 里 **`unsupported` = 该设备 `disable_depth > 0`，即驱动没启用 runtime PM**（`drivers/pmdomain/core.c: rtpm_status_str()`）。而 `genpd_power_off()` 对域内每个设备查 `pm_runtime_suspended()`，没启用 runtime PM 的设备永远算 "not suspended"（`core.c:984-996`）→ **凡是挂着 unsupported 设备的域，永远关不掉**。审计里这样的域有四个：`gcc_usb3_phy_gdsc`（aux_bridge）、`gcc_ufs_phy_gdsc`（1d88000.crypto）、`gcc_ufs_mem_phy_gdsc`（1d80000.phy）、`gcc_pcie_0_phy_gdsc`（1c06000.phy）。这是本轮最有价值的结构性发现：四个 CX 内的 GDSC 被驱动的 PM 缺口钉死，与负载无关。

---

## 1. CDSP：running，但不是 XO 的持有者

### 证据

- 审计 `cx-audit-2247.txt:375-377`：`xo-board 2 / clk1 1 (wcn7860-pmu) / bi_tcxo 2 2 … 26300000.remoteproc xo`，紧随其后的子时钟 `dsi0vco_clk 1`（`:378`）和 `bi-tcxo-div2-clk 9`（`:396`）各贡献 1 → `bi_tcxo` 的 enable_cnt 2 **已被两个子时钟占满**，CDSP 的 `xo` 句柄此刻没有使能。
- `drivers/remoteproc/qcom_q6v5_pas.c`：`qcom_pas_start()` 在 `:293` `clk_prepare_enable(pas->xo)`；固件起来发 handover 中断后 `qcom_pas_handover()`（`:391-402`）`clk_disable_unprepare(pas->xo)` 并 `qcom_pas_pds_disable()` 放掉代理电源域。审计 pm_genpd 里 CDSP 的三个代理域全在 suspended：`nsp` `:73-74`、`mxc` `:81`、`cx` `:115` → handover 已发生，XO 已放。
- `qcom_stats` `:209`：`cdsp Count 0, Last Entered 256662417 (=13.4 s), Accumulated 28596417115 ticks ≈ 1489 s` ≈ 整个 uptime → 开机 13.4 s 进低功耗态后再没醒（RESEARCH §1.2 已指出）。
- 谁在用 CDSP：`inventory/lsmod` `fastrpc 40960 0`（0 引用）；`inventory/bound-drivers` `rpmsg qcom,fastrpc 2`（adsp + cdsp 两条 glink 通道）、`platform qcom,fastrpc-cb 15`；`inventory/class-members` misc 里有 `fastrpc-adsp-secure / fastrpc-cdsp / fastrpc-cdsp-secure`；上游 `userspace/platform/systemd/system/hexagonrpcd.service.d/tb323fu.conf:11` `hexagonrpcd_device=/dev/fastrpc-adsp-secure`——传感器走 ADSP；音频走 ADSP（q6apm）。helper 文档 `docs/helper.md:250` 把"remoteproc restart、NPU"列为有意不碰。**本机 Linux 上没有任何 CDSP 用户。**
- 谁把它启动的：`inventory/dmesg:747-751` initramfs 阶段 `qcom_q6v5_pas` 自启失败（固件 -2，不在 initramfs 里）；`:1142-1153` 5.05 s 由 `tb323fu-dsp.service` 写 `start` 拉起（上游单元 `userspace/platform/systemd/system/tb323fu-dsp.service` 的 ExecStart 对 adsp、cdsp 各写一次 `start`）。ABL/XBL 不启动 CDSP。

### 停还是不启

- `echo stop > /sys/class/remoteproc/remoteproc2/state` → `state_store()` → `rproc_shutdown()` → `qcom_pas_stop()`（`qcom_q6v5_pas.c:404-437`）：先 `qcom_q6v5_request_stop()`（smp2p 停机请求 + sysmon 优雅关机），再 `qcom_scm_pas_shutdown()`，解映射 carveout。这是安卓 SSR 每天走的路径，机制上没问题。
- 但上游 `docs/hardware-status.md` 的 Known issues 写着 "Do not stop the audio DSP at runtime: it takes the SoC down"，`helper.md:250` 泛化成 "a stopped remoteproc kills the SoC"。ADSP 的情形有解释（音频/传感器/soundwire/q6prm 时钟全是它的客户端，被拔掉就乱）；**CDSP 没有客户端，理论上无此问题，但本机没有任何人试过**。
- 所以推荐**不启动**而不是**运行时停**：drop-in 让 `tb323fu-dsp.service` 只起 adsp。零运行时风险（CDSP 从未上电，与 initramfs 阶段的状态一致）。想做实验再 `echo start`。

### 预估与风险

- 省电 ≈ 0：它已经 100% 在睡，NSP 轨从 APSS 看是 off；差别只剩 CDSP 的 TCM 保持与岛内 AON（估计 1–3 mW，猜测，不可测）。
- 省掉的是别的：开机少 1.2 s（4.9 MB 固件 + 启动）、少三个 fastrpc 杂项设备、少一条 QRTR 节点和 `qcom_pd_mapper` 的一个服务对象、`qcom_stats` 里少一个要解释的条目。
- 对 XO/aosd：无关（它不持 XO）。对 cxsd：一个在睡的子系统不投票，不启动与睡着对 AOP 等价。
- 风险：以后 NPU/fastrpc 实验要先 `echo start`。`hexagonrpcd` 不受影响（只用 ADSP）。

### 只读核对（熄屏）

```sh
for r in /sys/class/remoteproc/*; do echo "$(cat $r/name) $(cat $r/state)"; done   # 期望：soccp attached / adsp running / cdsp offline（装 drop-in 后）
ls /dev/fastrpc-*                                                                  # 装后只剩 fastrpc-adsp-secure
grep -n "^ *bi_tcxo \| dsi0vco_clk \| bi-tcxo-div2" /sys/kernel/debug/clk/clk_summary  # 熄屏时 dsi0vco 应消失，bi_tcxo enable_cnt 应等于仍使能的子时钟数
```

---

## 2. USB3 PHY：`gcc_usb3_phy_gdsc on` 是三重原因，而且"off"也不会掉电

### 证据

- 审计 `:55-59`：`gcc_usb3_phy_gdsc on` 下挂 `88e8000.phy active` 和 `aux_bridge.aux_bridge.0 unsupported`；`gcc_usb30_prim_gdsc off-0` 下 `a600000.usb suspended`。
- (a) `drivers/phy/qualcomm/phy-qcom-qmp-combo.c:5295-5304`：probe 里 `pm_runtime_get_noresume(); pm_runtime_set_active(); devm_pm_runtime_enable(); pm_runtime_forbid(dev)`，注释 "Prevent runtime pm from being ON by default. Users can enable it using power/control in sysfs." → PHY 设备永远 active，是上游有意的默认。
- (b) `:5286` `drm_aux_bridge_register(dev)` → `drivers/gpu/drm/bridge/aux-bridge.c: drm_aux_bridge_register()` 用 `device_set_of_node_from_dev(&adev->dev, parent)` 让 auxiliary 设备**复用 PHY 的 of_node**；`drivers/base/auxiliary.c: auxiliary_bus_probe()` 一进门 `dev_pm_domain_attach(dev, PD_FLAG_ATTACH_POWER_ON|…)` → `genpd_dev_pm_attach()` 看到 of_node 里有一个 `power-domains` 就把它挂进 `gcc_usb3_phy_gdsc`（`kaanapali.dtsi:3280`）。aux_bridge 没有 runtime PM → unsupported → 域永远关不掉（§0 读法 2）。
- (c) 上游补丁 0059 把 `gcc_usb30_prim_gdsc`/`gcc_usb3_phy_gdsc` 从 `PWRSTS_OFF_ON` 改成 `PWRSTS_RET_ON`（为了 s2idle 后 xHCI 不死、DP PLL 能锁）。`drivers/clk/qcom/gdsc.c: gdsc_disable()`：`if (sc->pwrsts == PWRSTS_RET_ON) return 0;`——**不切 GDSC_OFF**，注释说明保持态只由父域进低功耗时硬件自己进。所以运行时这两个 GDSC 的开关永远是 ON，`gcc_usb30_prim_gdsc off-0` 只是 genpd 的记账。
- PHY 本体：dwc3 在 device 模式 runtime suspend 时 `dwc3_suspend_common()` → `dwc3_core_exit()`（`drivers/usb/dwc3/core.c:994`）→ `phy_power_off/phy_exit` → qmp-combo `com_exit` 关自己的时钟和稳压器。审计里确实没有任何 `gcc_usb3_prim_phy_*` / `gcc_usb30_prim_*` 时钟在使能表里 → PHY 的时钟已经关了，只剩 GDSC 这块"电"。
- 0098（DP 每个 plug 只持一个 runtime 引用）已生效：`9ad2000.displayport-controller suspended`（`:99`），不是嫌疑。

### 能做什么

- `echo auto > /sys/bus/platform/devices/88e8000.phy/power/control`：PHY 设备会变 suspended（`qmp_combo_runtime_suspend()` 在 `init_count==0` 时直接 return，无副作用），但域仍被 aux_bridge 钉着，而且因为 RET_ON 域就算"off"硬件也不变。**零效果，不写 udev 规则**。
- 真要省这块电，要两处内核改动且互相独立：① 让 aux_bridge 不挂电源域（auxiliary/aux-bridge 的上游问题：复用 of_node 的子设备不该再 attach 一次 PM domain）；② 放弃 0059 的 RET_ON、改回 OFF_ON 并靠 `RETAIN_FF_ENABLE` 保持——0059 作者实测这条路不通（xHCI "HC died"、DP PLL 锁不上），所以 ② 目前无解，① 做了也白做。**结论：接受，记为"已理解、不做"。**
- DP altmode 检测与 PHY 供电无关：HPD 由 `pmic_glink_altmode_worker()`（`drivers/soc/qcom/pmic_glink_altmode.c:349-377`）从充电固件消息转成 `typec_mux_set/typec_switch_set` + `drm_aux_hpd_bridge_notify`，msm_dp 收到后才 `phy_init` 把 PHY 拉起来。即使 PHY 哪天真能挂起，拔插检测也不受影响。

### 预估

0。唯一的收获是把 RESEARCH §1.2 B 里"需拔电熄屏复查 usb3_phy_gdsc"这条关掉：拔不拔电都是 on，原因在驱动不在充电。

### 只读核对

```sh
grep -A3 "gcc_usb3_phy_gdsc\|gcc_usb30_prim_gdsc" /sys/kernel/debug/pm_genpd/pm_genpd_summary
cat /sys/bus/platform/devices/a600000.usb/power/runtime_status /sys/bus/platform/devices/88e8000.phy/power/control
grep -n "usb3_prim\|usb30_prim" /sys/kernel/debug/clk/clk_summary | awk '$2>0'      # 期望：空（PHY/控制器时钟都关着）
```

---

## 3. 蓝牙 UART：51.2 MHz 跟着 hci0 的 Powered 走，IBS 到不了串口

### 证据

- 审计 `:418-421`：`gcc_gpll0 → gcc_gpll0_out_even → gcc_qupv3_wrap3_s5_clk_src 51.2 MHz → gcc_qupv3_wrap3_s5_clk 1 (1994000.serial se)`；`:364-365` wrap3 的 m/s AHB 时钟也开着（其它四个 QUP wrapper 没有 AHB 时钟使能 → I2C 的 SE 都正常挂起了，**只有这一个 SE 醒着**）。3.2 Mbps × 16 = 51.2 MHz，就是 `max-speed = <3200000>` 的位时钟（`kernel/dts/baldur-wifi.dtsi` bluetooth 节点）。
- `drivers/tty/serial/qcom_geni_serial.c`（v7.3-rc4 已有 runtime PM）：`qcom_geni_serial_startup()` `:1410` `pm_runtime_resume_and_get(uport->dev)`，`qcom_geni_serial_shutdown()` `:1336` `pm_runtime_put_sync()`；`SET_RUNTIME_PM_OPS(qcom_geni_serial_runtime_suspend/resume)` `:2148-2152`，suspend 回调就是 `geni_se_resources_off`（关 SE 时钟 + ICC）。**引用在 open 期间一直持着**：hci_qca 的 serdev 在 hci0 power on 时 `serdev_device_open()`，power off 时才 close。
- `drivers/bluetooth/hci_qca.c:278-292`：`__serial_clock_on()` / `__serial_clock_off()` 的函数体是 `/* TODO: Some chipset requires to enable UART clock on client side to save power consumption … */`——空的。`serial_clock_vote()`（`:295-345`）在 IBS 进入睡眠时调用它们（`:454/:471`），所以**IBS 只让 BT 控制器和主机的 TX 状态机睡，SE 时钟从来没被投票关过**。而且 serdev 模式下传进去的 `hu->tty` 是 NULL。
- DT：`kaanapali.dtsi:1994-2014` uart18 只有一个 `interrupts = <GIC_SPI 587>`，没有第二个（唤醒）中断，也没有 `wakeup-source`；geni 驱动的 `wakeup_irq = platform_get_irq_optional(pdev, 1)`（`:1951`）+ `dev_pm_set_dedicated_wake_irq()`（`:1976-1985`）因此没启用。helper 文档 `helper.md` 也写了"蓝牙键盘唤醒：串口没有唤醒中断"。RX 脚是 TLMM gpio27（`qup_uart18_default` `:4370-4376`，TX gpio26）。
- 0130（BT 地址）与此无关；0030 的 IBS 处理只在 115200 初始速率时暂不启用 IBS，运行态 IBS 是开着的（dmesg 里 `Received HCI_IBS_WAKE_ACK` 是初始化时的噪声）。

### 能做什么

1. **现成的**：hci0 power off（`bluetoothctl power off` / rfkill）→ `qca_close()` → `qca_power_off()` → `pwrseq_disable()`（`hci_qca.c:2267-2270`，WCN7860 的 BT 电源经 pwrseq_qcom_wcn 关掉）+ serdev close → geni `shutdown()` 放引用 → SE 时钟、wrap3 AHB、ICC 全关。作者 10-15 的 offbench 已测过：蓝牙关 0.54 W vs 基线 0.55 W，**噪声内**。所以这一项的本地功耗 <0.01 W。熄屏自动关蓝牙会让 BT 键盘/耳机在熄屏时断掉，不推荐。
2. **真修（内核，不在本轮）**，三件事缺一不可：
   - hci_qca：把 `__serial_clock_off/on` 实现成对 serdev 控制器的 runtime PM 投票（`serdev_device_open()` 本身对 `ctrl->dev` 做了 `pm_runtime_get_sync`，所以路径上要新增一个"端口开着但允许挂起"的 serdev/uart 接口）；
   - qcom_geni_serial：端口 open 期间允许 runtime suspend（停 RX 引擎、关 SE、再恢复时重编程），现在的驱动假定 open = active；
   - DT：uart18 加第二个中断 = RX 脚 gpio27 的下降沿（经 TLMM/PDC），否则 SE 睡着时控制器的 `HCI_IBS_WAKE_IND` 第一个字节到不了主机，BT 入向事件（键盘按键）会丢。QCA 固件会重发 WAKE_IND，所以 RX 唤醒 → 开 SE → 第二次 WAKE_IND 被收到，这是安卓 `msm_geni_serial` 的做法。
   上游没有现成补丁（lore/patchwork 本机读不到，GitHub 上的几个 SM8x50 兄弟仓也没见到）。linux-next master（2026-10-16 取自 web.git.kernel.org）复核：`hci_qca.c` 的两个存根原样未动；`qcom_geni_serial.c` 在 next 里新增的 runtime PM 调用只是 console setup/exit 的取放引用和 RX 路径重排，端口 open 期间仍持引用——没有可拣的补丁。工作量和风险都是"一个专题"的量级，收益 <0.01 W + 解除 gpll0 对 XO 的一条引用。**放到 ss3 放开之后再评估。**

### 只读核对

```sh
cat /sys/bus/platform/devices/1994000.serial/power/runtime_status /sys/bus/platform/devices/19c0000.geniqup/power/runtime_status
grep -n "qupv3_wrap3_s5\|qupv3_wrap_3" /sys/kernel/debug/clk/clk_summary          # hci0 Powered 时 enable_cnt 1；power off 后应为 0
bluetoothctl show | grep Powered
```

---

## 4. UFS：ICE 时钟跟主机 runtime PM 走；真问题是 ICE 设备把 UFS 的 GDSC 钉死

### 证据

- 审计 `:60-64`：`gcc_ufs_phy_gdsc on (perf 56)` 下 `1d88000.crypto unsupported`、`1d84000.ufs active 56`；`gcc_ufs_mem_phy_gdsc on` 下 `1d80000.phy unsupported`。`:415-417` `gcc_gpll4 → gcc_ufs_phy_ice_core_clk_src 403 MHz → gcc_ufs_phy_ice_core_clk 1 (1d88000.crypto core)`；`:363` `gcc_ufs_phy_ahb_clk 1 (1d84000.ufs iface_clk)`。审计脚本当时正在往文件写输出，UFS 主机 active 是必然的，这一行不能当"常开"证据。
- 时钟归谁管：`drivers/ufs/host/ufs-qcom.c` 里 `ufs_qcom_setup_clocks()`（clk gating 的钩子）只碰 PHY power、lane clock、设备 ref clk、ICC，**不碰 ICE**；ICE 在 `ufs_qcom_suspend()` 末尾 `return ufs_qcom_ice_suspend(host)`（`:800`）、`ufs_qcom_resume()` 末尾 `ufs_qcom_ice_resume()`（`:830`）→ `drivers/soc/qcom/ice.c: qcom_ice_suspend()`（`:334-342`）`clk_disable_unprepare(core_clk/iface_clk)`。即：**ICE 403 MHz 在 UFS 主机 runtime suspend 时才关，clk gating（150 ms，`ufshcd.c:2238`）期间仍在转**。主机 runtime suspend 的条件：LUN/wlun 空闲 2 s（`RPM_AUTOSUSPEND_DELAY_MS 2000`，`ufshcd.c:95`）后逐级挂起，`rpm_lvl` 默认 = 设备 SLEEP + 链路 HIBERN8（`:11182-11186`）。熄屏无 I/O 时主机应当挂起、ICE 时钟应当为 0——**这要在熄屏电池态核对，审计没覆盖**。注意：`y700-flightrec`（每秒 fdatasync）在跑时 UFS 永远挂不起，测底噪时要 `--sync 10` 或停掉（PROTOCOL §2 已写）。（10-19 核对，X44：「每秒 fdatasync」是旧 Python 版；Rust 版 10-17 起实验时每 1 s 一行/每 5 行落盘，平时每 10 s 一行/每 6 行落盘（旧 Python 版曾每秒写、每 5 s 落盘），`linux/power/flightrec/src/main.rs:16-22`——平时约每 1 min 才落盘一次，「永远挂不起」要按新节奏重核，未测）
- GDSC 为什么关不掉：`kaanapali.dtsi:2612-2622` `ice: crypto@1d88000 { … power-domains = <&gcc GCC_UFS_PHY_GDSC>; }`，与 UFS 主机同一个域（`:2555`）。`ice.c` 全文没有 `pm_runtime`（probe `:736-762` 只是 ioremap + `qcom_ice_create()` + xa_store），所以它是 unsupported，`genpd_power_off()` 永远数到一个 not-suspended 设备（§0 读法 2）。**UFS 主机 runtime suspend 了，GDSC 也不会关。** **更正（10-16 二核，初稿写成"sm8650 没有 power-domains"是错的）**：v7.3-rc4 的 `sm8650.dtsi`、`sm8750.dtsi` 的 ICE 节点同样是 `power-domains = <&gcc UFS_PHY_GDSC>`（审阅复核：`sm8450.dtsi`、`sm8550.dtsi` 亦同）；binding `Documentation/devicetree/bindings/crypto/qcom,inline-crypto-engine.yaml` 的 allOf 对 sm8450/sm8550/sm8650/sm8750/kaanapali/sa8775p/sc7180/sc7280/qcs8300 把 `power-domains` + `clock-names` 列为**必需**（注释 "New SoCs must provide both clocks and power domains"）。所以这是 binding/DT 与驱动能力之间的通用错位：凡是独立 ICE 节点挂在 UFS GDSC 下的主线高通 SoC，UFS 主机 GDSC 在运行时都从未真正关过——没人注意，因为 CX 不塌时一个 GDSC 的开关从外面看不出来。修法只能在驱动侧（下面的草案），对这些 SoC 全部通用，值得报上游：linux-next master（2026-10-16 取）的 `ice.c` 与 rc4 逐字节相同，kaanapali 的 ICE 节点也没变，没有人在修。
- `gcc_ufs_phy_gdsc` 在 `gcc-kaanapali.c:3172-3182` 是 `PWRSTS_OFF_ON | POLL_CFG_GDSCR | RETAIN_FF_ENABLE`（关掉时保持触发器，寄存器状态可保），与 sm8650 同款，运行时真关是设计内的行为。0128（UFS AXI PHY 时钟 FORCE_MEM_CORE_ON）、0129（clk scaling 死锁）、0012（lane clock）都在这条链路上，说明上游也在动它，trial 时要盯 `ufshcd` 报错。
- `gcc_ufs_mem_phy_gdsc`（UFS PHY 本体）同理被 `phy-qcom-qmp-ufs.c`（无 runtime PM，grep 为 0）钉死；`phy_power_off` 关的是 PHY 内部，GDSC 这块电一直在。修法同类（给 qmp-ufs 加 runtime PM，在 `phy_power_on/off` 里 get/put），本轮不写。

### 提案：`soc-qcom-ice-runtime-pm.DRAFT.patch`（草案，未编译、未测）

对 `drivers/soc/qcom/ice.c`：
- 只对**独立 DT 节点**的 ICE（`qcom_ice_probe()` 路径）启用 runtime PM；legacy 绑定（ICE 寄存器在 UFS 节点里、`engine->dev` 就是 UFS 主机设备）不碰，避免在主机自己的挂起路径里动主机的引用计数。
- probe：`pm_runtime_get_noresume(); pm_runtime_set_active(); devm_pm_runtime_enable()`，持一个引用——与 `qcom_ice_create()` 在 probe 就把时钟打开的现状对齐（时钟 enable_cnt 也是从 probe 起为 1，直到消费者第一次 `qcom_ice_suspend()`）。
- `qcom_ice_suspend()` 末尾 `pm_runtime_put(ice->dev)`；`qcom_ice_resume()` 开头 `pm_runtime_resume_and_get()`，失败路径配对放回。ICE 设备不需要自己的回调：它挂在 genpd 下，`genpd_runtime_suspend/resume` 在没有驱动回调时返回 0，只做域的开关记账。
- 时序：主机 runtime suspend → `ufs_qcom_suspend()` → ICE put（异步）→ 主机自己的 `genpd_runtime_suspend()` 以 `one_dev_on=true` 调 `genpd_power_off()`；谁最后挂起谁把域关掉，所以 put 不必 sync。
- 生成方式：一个未入库的脚本对 v7.3-rc4 的 ice.c 做文本替换后 `diff -u`，反向 `patch -R --dry-run` 通过；**没有编译**。y9 的补丁栈没有动 ice.c（0001–0130 里无 soc/qcom/ice），应能直接打上。

预估：一个 CX 内 GDSC 关掉的漏电，毫瓦级，不可测。真正的价值是 E3b：CX 要能塌，CX 里不能有开着的 GDSC 还指望寄存器活着；今天四个被钉死的 GDSC 里，UFS 主机这个是唯一一个驱动改几行就能放开的。

风险（中）：运行时让 UFS 主机 GDSC 真掉电是本机的新行为——而且不只本机：主线上凡是独立 ICE 节点挂在 UFS GDSC 下的 SoC 都没真发生过（同一个驱动缺口）；按代码推断只有 legacy 绑定（ICE 寄存器是 UFS 节点里的一段 reg、没有独立设备，如 sm8250）的 SoC 在运行时真关过这个 GDSC。失败形态 = 熄屏后第一次 I/O 时 UFS 恢复失败 → 根分区挂死 → 需要硬复位。只能走 trial 内核（自动回滚）、作者在场、先在亮屏下 `echo 1 > …/power/autosuspend_delay_ms` 之类的方式反复触发挂起/恢复几十次，再过夜。

### 只读核对（熄屏电池态）

```sh
D=/sys/bus/platform/devices/1d84000.ufs
cat $D/power/runtime_status $D/power/runtime_suspended_time $D/rpm_lvl $D/clkgate_enable $D/clkgate_delay_ms
grep -A3 "gcc_ufs_phy_gdsc\|gcc_ufs_mem_phy_gdsc" /sys/kernel/debug/pm_genpd/pm_genpd_summary   # 装补丁后 1d88000.crypto 应从 unsupported 变 suspended，域 off-0
grep -n "ufs_phy_ice_core\|ufs_phy_ahb\|ufs_phy_axi\|gcc_gpll4 " /sys/kernel/debug/clk/clk_summary  # 主机挂起时 enable_cnt 全 0
awk '$3=="sda"{print $4, $8}' /proc/diskstats; sleep 30; awk '$3=="sda"{print $4, $8}' /proc/diskstats   # 熄屏 30 s 内有多少读/写
```

---

## 5a. LPASS 六个 19.2 MHz：五个 macro 全醒着，按住它们的多半是 soundwire 主控

### 证据

- 审计 `:352-358`：`LPASS_HW_DCODEC 5 / LPASS_HW_MACRO 5`（五个 macro 各投一票）、`WSA2_CORE_TX_MCLK 1 (6aa0000)`、`WSA_CORE_TX_MCLK 1 (6b00000)`、`RX_CORE_TX_MCLK 1 (6ac0000)`、`TX_CORE_MCLK 3 (6ae0000)`、`fsgen 4`（VA macro 7660000 输出，四个 macro 消费；`kaanapali.dtsi:2947-2963`）。这些是 q6prm 的软件时钟——APSS 对 ADSP 的投票，不是 GCC 分支。
- macro 驱动自己会睡：`lpass-tx-macro.c:2339-2341` `pm_runtime_set_autosuspend_delay(dev, 100)`、`lpass-va-macro.c:1632-1634` 同。能让五个一起醒着的只有两类持有者：(1) **soundwire 主控**——`lpass-rx-macro.c:3673-3703` `swclk_gate_enable()` 对 macro `pm_runtime_resume_and_get()`，`drivers/soundwire/qcom.c:1692-1696` 主控 autosuspend 3 s，`swrm_runtime_suspend()`（`:1787`）关 `hclk` 才放掉 macro；(2) 正在 open 的 PCM（`soc-pcm.c:978` `snd_soc_pcm_component_pm_runtime_get()` 对链路上每个 component 取引用）。wsa/wsa2 macro 在本板没有 DAI 链路，它们也醒着 → 更像 (1)，或者 wcd939x 这个 soundwire 从设备没让主控睡。
- 本机用户态：上游扬声器保护 filter-chain 的 playback 侧是 `node.passive = true`（`60-tb323fu-speakers.conf:80-84`），不会单独把硬件 sink 拉着；`y700-speaker-guard` 已改事件驱动。麦克风路径（WCD Capture = tx/va macro + wcd939x）只要有应用开着麦（Chrome/Claude/Telegram 的权限）就会 RUNNING。

### 能做什么

离线判断不了，先核对（下面）。若是 soundwire 主控/wcd939x 不睡：看 `/sys/bus/soundwire/devices/*/power/runtime_status`，怀疑 MBHC（DT 里配了 `qcom,mbhc-*` 阈值，但本机没有 3.5 mm 口，耳机检测经 FSA4480/USB-C）；可试把 wcd939x 的 MBHC 阈值属性去掉（DT，y10 内核）看主控能否挂起。若是某应用开着麦：那是应用问题，不是平台问题。

预估：LPASS 在自己的岛里，ADSP 97% 时间在睡、93% 在 island（审计 `:205-206`），这些 19.2 MHz 的代价是毫瓦级。对 XO：q6prm 时钟是对 ADSP 的投票，ADSP 自己会把 XO 票合并进 AOP，APSS 这边不直接持 `bi_tcxo`。

### 只读核对

```sh
for d in /sys/bus/platform/devices/*.codec /sys/bus/platform/devices/*soundwire* /sys/bus/soundwire/devices/*; do printf '%-48s %s\n' "${d##*/}" "$(cat $d/power/runtime_status 2>/dev/null)"; done
grep -H . /proc/asound/card0/pcm*/sub0/status | grep -v closed          # 哪个 PCM 开着
fuser -v /dev/snd/pcm* 2>&1 | head                                       # 谁开的
sudo -u user env XDG_RUNTIME_DIR=/run/user/1000 pw-cli ls Node | grep -B4 'state = "running"'   # PipeWire 里谁在 running
grep -n "LPASS_\|fsgen" /sys/kernel/debug/clk/clk_summary | awk '$2>0'
```

---

## 5b. `rtc@6100` 61 次唤醒：很可能是 61 次写不进去的 `rtc_set_time()`

### 证据

- 审计 `:426`：`c426000.spmi:pmic@0:rtc@6100 active_count 61 event_count 61 wakeup_count 0 total_time 5 ms`，uptime 1494 s → 平均每 24.5 s 一次、每次 0.08 ms。
- 这个 wakeup source 的计数来自 `pm_stay_awake(rtc->dev.parent)`，在 rtc core 里有三处：`rtc_update_irq()`（闹钟中断，`drivers/rtc/interface.c:751-759`）、`rtc_timer_enqueue/remove` 的 `-ETIME` 分支（`:900/:953`）、**`rtc_set_time()`**（`:162`，在调用驱动 `set_time` **之后无条件执行**，不管驱动成功失败）。
- `kernel/time/ntp.c:869-909` `sync_hw_clock()`：只要 `ntp_synced()`（chrony 用 `adjtimex()` 清掉 STA_UNSYNC，Ubuntu 的 chrony.conf 默认带 `rtcsync`），就 `update_rtc()` → `rtc_set_time()`；返回 `-ENODEV` 时**不再重排定时器**，下一次由 `ntp_notify_cmos_timer()` 触发——它在每次 `adjtimex()` 调用里被调。chrony 每拿到一次测量就 `adjtimex()` 一次，4 个源 × 64–128 s 轮询 ≈ 每 16–32 s 一次，**与 24.5 s 吻合**。
- 为什么写不进去：`pmk8850.dtsi:48-55` 的 `rtc@6100` 没有 `nvmem-cells`、`allow-set-time`、`qcom,uefi-rtc-info`，`drivers/rtc/rtc-pm8xxx.c:622-626` → `allow_set_time=false` → `pm8xxx_rtc_set_time()` → `pm8xxx_rtc_update_offset()`（`:243-280`）第一句 `if (!nvmem_cell && !use_uefi) return -ENODEV`。README 第 131 行（"时间：RTC（pm8xxx）只读且每次开机从 1970 起步"）早就记着。配置：`config-t49-y9:5580` `CONFIG_RTC_SYSTOHC=y`，`RTC_SYSTOHC_DEVICE="rtc0"`。
- 不是 alarmtimer：`kernel/time/alarmtimer.c` 只在 `alarmtimer_suspend()`（`:218-286`）才 `rtc_timer_start()`，本机永不休眠。不是 UIE 仿真：`CONFIG_RTC_INTF_DEV_UIE_EMUL` 未开。仓库里没有任何 `wakealarm`/`WakeSystem`/`hwclock` 的使用（grep 全仓）。
- 代价：每次 = 一次 workqueue + `pm_stay_awake/relax` + `schedule_work(irqwork)`，不碰 SPMI（在读寄存器之前就返回了）。**≈0 W**，只是唤醒帐上的噪声，以及 `y700-whoawake` 里多出的 kworker。
- 与 [WAKEUPS.md](WAKEUPS.md) §2.5 的关系：那里把这 61 次按"闹钟/UIE"列了候选（chrony `rtcfile`、`WakeSystem=` 定时器、fake-hwclock）；本节的结论是**更可能根本没有闹钟**——`y700-wakeups --timer-list` 若看到 `/proc/driver/rtc` 的 `alarm_IRQ: no`、IRQ 表里没有 `pm8xxx_rtc_alarm`，就印证这里；`--rtc 90` 的 tracepoint 一次定案。（10-19 核对，X19：WAKEUPS.md §0.4 :25 已补同一句——不是闹钟，是失败的 `rtc_set_time()`；定案仍待 `--rtc 90`）

### 提案

1. 先抓现行（脚本 `always-on-check.sh --rtc 90`）：在独立 tracefs 实例里开 `rtc:rtc_set_time`、`rtc_set_alarm`、`rtc_alarm_irq_enable`、`rtc_timer_fired` 90 s。期望看到 `rtc_set_time … err=-19` 每 20–30 s 一条、comm=kworker，没有 set_alarm/alarm_irq。
2. 确认后：`/etc/chrony/chrony.conf` 注释掉 `rtcsync`（`y700-rtc-sync-off.sh`，备份 + 重启 chrony）。RTC 本来就写不进去，功能零变化；fake-hwclock 继续负责开机时间。chrony 的 conf.d 不能"取消"主配置里的指令，只能改主文件。
3. 想让 RTC 真的能保存时间：给 `rtc@6100` 加 `nvmem-cells = <&rtc_offset>` 指向 pmk8850 的 SDAM（vendor DT 的做法，需要查 vendor 用的是哪个 SDAM 偏移）——另一个专题，收益是开机时间正确、NTS 不再因 1970 失败（README 131 行的痛点）。
4. **WK-4 代理裁决（PLAN §2.11 WK-4 :292-293，10-19 定，阶段 N2）**：功耗 ≈0 W，不出功耗裁决，只看代理指标——先 `DIAG:` 步跑 `always-on-check.sh --rtc 90` 确认 `rtc_set_time … err=-19` 每 20–30 s 一条；再在 N2 夜跑 `E3a+K=rtcsync:15 / E3a+K=noop:15` 两臂，比较 `rtc@6100` 的 wakeup 计数（`/sys/kernel/debug/wakeup_sources` 的 event_count 差分），关 `rtcsync` 臂比 noop 臂少 ≥30% 即「代理有效」（≥30% 这个阈值来自 10-19 任务书，PLAN 本文只写「只看代理」）；`y700-rtc-sync-off.sh` 10-19 时没有 `--undo`，上线前要加（回退手段）；体检新增 `check_rtc_sync`。

---

## 6. PCIe（交叉引用）

PCIe 专题（[PCIE-L1SS.md](PCIE-L1SS.md)：L1.2 进不去的原因、`y700-l1ss-probe.sh`、`1045-pcie-qcom-l1ss-t-power-on-ltr-max.patch`）负责；这里只记两条共性：`1c06000.phy unsupported` 把 `gcc_pcie_0_phy_gdsc` 钉死（`phy-qcom-qmp-pcie.c` 无 runtime PM，`kaanapali.dtsi:2485`），`pcie-qcom` probe 后不 put 把 `gcc_pcie_0_gdsc on 256` 钉死（RESEARCH §1.2 B 已记）。PCIe 还是熄屏时 XO 的最大持有者（下一节）。

---

## 7. 熄屏时谁还持着 XO（`bi_tcxo` 非 `_ao` 版 = 睡眠集里也投票，是 aosd 的阻塞者）

从审计 `:375-423` 的时钟树去掉亮屏才有的 disp_cc/DSI 子树后，`bi-tcxo-div2` 的剩余用户：

| 用户 | 谁 | 熄屏时状态 | 本文件对应节 |
|---|---|---|---|
| `gcc_pcie_0_phy_aux_clk`、`gcc_pcie_0_aux_clk`（19.2 MHz）、`gcc_gpll0 → gcc_pcie_0_phy_rchng_clk` 100 MHz | PCIe 根口 + PHY | 常开 | §6 / PCIe 专题 |
| `gcc_gpll0 → gcc_qupv3_wrap3_s5_clk` 51.2 MHz | 蓝牙 UART | hci0 Powered 就常开 | §3 |
| `gcc_gpll4 → gcc_ufs_phy_ice_core_clk` 403 MHz | UFS ICE | 跟 UFS 主机 runtime PM | §4 |
| （已排除）`26300000.remoteproc xo` | CDSP | 不持 | §1 |

所以 aosd 的三道门按顺序是：PCIe（3 条引用，运行时无 PM）> 蓝牙 UART > UFS。今天 APSS 不进 ss3，这张表只是地图；放开 ss3（PROTOCOL E3）后它决定 `aosd` 能不能动。

---

## 8. 产物与安装（全部未装、未在平板验证）

| 文件 | 作用 | 装法 | 撤回 |
|---|---|---|---|
| [`always-on-check.sh`](always-on-check.sh) | 熄屏态只读核对六项（`--off` 关屏 20 s 后测；`--rtc N` 在独立 tracefs 实例里抓 N 秒 rtc 事件；`--no-clk` 不读 clk_summary）。不开任何寄存器类 debugfs；写的只有 tracefs 实例目录（结束即删） | `install -m 755 always-on-check.sh /usr/local/libexec/; always-on-check.sh --off --rtc 90 > /var/log/y700-always-on-$(date +%H%M).txt` | 删文件 |
| [`tb323fu-dsp-no-cdsp.conf`](tb323fu-dsp-no-cdsp.conf) | `tb323fu-dsp.service` 的 drop-in：只起 adsp，不起 cdsp | `install -D -m 644 tb323fu-dsp-no-cdsp.conf /etc/systemd/system/tb323fu-dsp.service.d/no-cdsp.conf; systemctl daemon-reload`（下次开机生效；本次开机的 cdsp 不动） | 删 drop-in + daemon-reload；立即要用 CDSP：`echo start > /sys/class/remoteproc/remoteproc2/state` |
| [`y700-rtc-sync-off.sh`](y700-rtc-sync-off.sh) | chrony.conf 注释 `rtcsync`（备份到 `chrony.conf.y700bak`），重启 chrony | 先跑 `--rtc 90` 确认是 set_time；再 `sh y700-rtc-sync-off.sh` | 还原备份 + `systemctl restart chrony` |
| [`soc-qcom-ice-runtime-pm.DRAFT.patch`](soc-qcom-ice-runtime-pm.DRAFT.patch) | ice.c runtime PM 草案（§4） | 只能进 trial 内核（y10+），作者在场；验证清单在补丁头部 | `kernel rollback` |

**有意不做的**：USB3 PHY 的 udev auto（零效果，§2）；蓝牙 UART 的 power/control（驱动 open 期间持引用，写 auto 无效）；熄屏自动关蓝牙（功能损失 > 0.01 W）；运行时 `echo stop` CDSP（能不启就不停）；给 `y700-checklist` 加项——等上面任何一件真装了再加（装 drop-in 后加"cdsp 应 offline"、装 rtcsync-off 后加"chrony.conf 无 rtcsync"）。

**周期性义务**：(1) `tools/upstream-check.py` 的 WATCH 表新增 `ice-rpm`（`ice.c` 出现 pm_runtime，或 kaanapali ICE 节点去掉 power-domains）与 `hci-qca-serial-clock`（`__serial_clock_on/off` 不再是 TODO 存根）两条，落地即报：前者撤本目录草案改 cherry-pick 上游版本，后者重评 §3（看它怎么与 geni 的 runtime PM 配合、是否要求 RX 唤醒中断）。(2) 若 ICE 草案进了某个 trial 内核，trial 期间每天看 `journalctl -k | grep -i "ufshcd\|ufs_qcom\|ice"`，并在该内核的 verify 脚本里加 `gcc_ufs_phy_gdsc` 熄屏 off-0 的断言。

---

## 9. 对 RESEARCH.md / PROTOCOL.md 的修正

- RESEARCH §1.2 B "CDSP 持 `bi_tcxo` → XO 常开"：**不成立**（§1，读法 1）。已在 RESEARCH.md 该行加注。
- RESEARCH §1.2 B "USB：审计时在充电，需拔电熄屏复查"：**不必**，on 的原因与充电无关（§2）。
- RESEARCH §3.1 第 4 条 (d) "谁在设 RTC 闹钟"：很可能没人设闹钟，是 `rtc_set_time` 失败（§5b），用 `--rtc` 抓一次即可结案。
- PROTOCOL E3b 的风险描述可以具体化：四个被 unsupported 设备钉死的 GDSC（§0 读法 2）在 CX 塌缩时寄存器会丢，其中 UFS 主机的那一个有草案修法。
- RESEARCH §1.2 B 的蓝牙 UART / UFS / LPASS / rtc 四行和 WAKEUPS §2.5 的 rtc 段已加注指向本文件；README 新增「熄屏常开外设逐项裁决」一节；`tools/upstream-check.py` 加了两条 WATCH（§8）。

## 10. 出处

- 仓库：`cx-collapse/cx-audit-2247.txt`（行号如文中）、`cx-collapse/RESEARCH.md §1.2–1.4`、`cx-collapse/PROTOCOL.md §2/§4`、`linux/kernel-y8/inventory/{lsmod,bound-drivers,class-members,dmesg,units-enabled,packages,config-running}`、`linux/kernel-y8/config-t49-y9`、`README.md` 续航第三轮/熄屏对照第二轮（蓝牙关 0.54 W、USB 控制器 auto）。
- 上游 tb323fu-linux：`kernel/patches/{0030,0059,0098,0100,0128,0129,0130}`、`kernel/dts/{baldur-cdsp,baldur-usb,baldur-wifi,baldur-audio,baldur-power,baldur-dp}.dtsi`、`userspace/platform/systemd/system/tb323fu-dsp.service`、`hexagonrpcd.service.d/tb323fu.conf`、`pipewire/pipewire.conf.d/60-tb323fu-speakers.conf`、`docs/hardware-status.md`（Known issues）、`docs/helper.md:250`。
- v7.3-rc4（raw.githubusercontent.com/torvalds/linux/v7.3-rc4/…）：`drivers/remoteproc/qcom_q6v5_pas.c`、`remoteproc_sysfs.c`、`drivers/clk/clk.c`、`drivers/clk/qcom/{gdsc.c,gcc-kaanapali.c}`、`drivers/pmdomain/core.c`、`drivers/base/{auxiliary.c,power/common.c}`、`drivers/gpu/drm/bridge/aux-bridge.c`、`drivers/phy/qualcomm/phy-qcom-qmp-{combo,ufs,pcie}.c`、`drivers/usb/dwc3/{core.c,dwc3-qcom.c}`、`drivers/soc/qcom/{ice.c,pmic_glink_altmode.c}`、`drivers/tty/serial/qcom_geni_serial.c`、`drivers/bluetooth/hci_qca.c`、`drivers/ufs/host/ufs-qcom.c`、`drivers/ufs/core/ufshcd.c`、`drivers/rtc/{interface.c,rtc-pm8xxx.c}`、`kernel/time/{ntp.c,alarmtimer.c}`、`sound/soc/codecs/lpass-{tx,va,rx}-macro.c`、`sound/soc/soc-pcm.c`、`drivers/soundwire/qcom.c`、`arch/arm64/boot/dts/qcom/{kaanapali,pmk8850}.dtsi`。本地副本（不入库）。
- linux-next master（2026-10-16 取，树为 next-20261015；web.git.kernel.org 的 cgit plain；当时 raw.githubusercontent.com 对本机 429 限速）：`drivers/soc/qcom/ice.c`（与 rc4 相同）、`drivers/bluetooth/hci_qca.c`、`drivers/tty/serial/qcom_geni_serial.c`、`arch/arm64/boot/dts/qcom/kaanapali.dtsi`（ICE 节点不变；`gcc` 节点已带 `RPMHPD_CX`，RESEARCH §1.3 已记）；v7.3-rc4 的 `Documentation/devicetree/bindings/crypto/qcom,inline-crypto-engine.yaml`。本地副本（不入库）。
- 读不到的：lore.kernel.org / patchwork（反爬页，未绕过）——所以"上游有没有 hci_qca/geni 的 runtime PM 补丁在飞"没有确认，只查了 GitHub 上的兄弟仓。

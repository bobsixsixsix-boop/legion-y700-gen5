# Y700 深度省电方案（设计稿，2026-10-19，未动平板）

> **状态：设计稿，等作者按 §7 逐条拍板后才进入执行。** 本稿写作期间**没有在平板上做任何写动作**（只在 10-19 13:27 做过一次只读快照），没有重启、没有改旋钮、没有装东西。
>
> 给谁看：没有上下文的下一个接盘者。读法：先 §0（现状、最大损失、硬规则），再 §7（要作者定的事），然后按 §4 的分期顺序去 §2 找每条候选的细节；§3 是每次测量前必须对照的规程；§6 是对旧研究结论的核对结果。
>
> 约定：数字一律带日期与出处（`文件:行` 或章节名）；没数据写「待测」；拿不准写「存疑」。路径、命令、标识符原样。
>
> 来源：本仓库（HEAD `07e1a7b`，10-19）；`runs/status-20261019.md`、`runs/audit-20261019.md`；10-19 13:27 只读快照；作者定下的工作规矩。设计过程的中间稿与 52 条矛盾核实的全文在工作笔记里（仓库外），结论已经全部并进本稿 §6。

---

## §0 总览

### 0.1 现状与当前最大的实际损失

- 设备：Y700 五代 TB323FU，Kaanapali SoC，Ubuntu 26.04 KDE Wayland，现役内核 `7.3.0-rc4-tb323fu-t49-y12`（10-19 快照）。电池满充 8886 mAh（10-17，README「续航速查」:1316）/ 8813 mAh（10-19，`runs/status-20261019.md:40`）≈ **34 Wh**（估算值，固件不报 energy_full）。
- 熄屏地板（电池、Wi‑Fi+Tailscale 在线、蓝牙开、不休眠）：
  - 旋钮全关（内核 cmdline 默认 `cpuidle_psci_domain.allow_cluster_off=0`）：**0.33 W**（10-17 00:50，5 min，README:1320）；10-18 白天切片 331 mW（README:1565）。
  - E3a 生效（`allow_cluster_off=1 + allow_system_off=1`，AOSS `prevent_cx_collapse=1 / prevent_ddr_collapse=1`）：**0.27–0.30 W**（10-17 夜 30 min，README:1548）；**0.24 W**（10-19 04:27–05:59 小时均值，`runs/status-20261019.md:69`）。
  - E3a **单项**收益 **0.03–0.06 W，准数 0.05 W**（10-17 同晚 A/B 0.27–0.30 vs 0.33；10-18 切片 26–64 mW，README:1565）。10-16 记的「0.1 W」（README:1526）是 apps-pc + 两个 drop-in 的合计、且受 ssh 轮询污染（PROTOCOL.md:89），**不是** E3a 单项（§6 X21）。
- **当前最大的实际损失：E3a 生效不稳定。** 10-19 12:55 重启后熄屏 26 min，`y700-cx-auto` 已 armed（aco=Y aso=Y），但 apps-pc 只进了 4 次共 63 ms，`power-domain-system` 计数不涨，cluster0 20 s 只下电 18 次；功耗 0.33–0.39 W 而不是 0.24 W。熄屏下 plasmashell 占 1.2 % CPU，cpu0 `arch_timer` 107/s、cpu1 45/s、cpu4 76/s，IPI1 101/s（10-19 13:27 只读快照）。症状与 10-18 查过的 plasma-nm 转圈动画根因一致（README「熄屏省电开着却没生效」），但这次没有 CarPlay 热点触发，触发源未知。按 0.1 W × 10 h/夜算，这一项的损失 ≈ 1 Wh/夜，占熄屏底噪 30–40 %，**比任何新旋钮都大**。本稿把它排在最前（§2.2 CPU-1/2/3/6、§2.11 WK-8，§4 P1/P1.5/N2′/N3）。
- 亮屏（电池）：静止桌面最低背光 1.13 W（10-14，README:1321）；实际用机小时均值 2.6–3.7 W，10-18 14 点 4.9 W（`runs/status-20261019.md:118`，背光/负载不受控）。Chrome 看 YouTube 真会话 4.96 → 3.64 W（垫片）→ 3.30 W（守护）（10-18，`status:116`）。游戏「从来没在电池上系统测过」（`status:61`），CarPlay、屏幕键盘、外屏都没测过。

### 0.2 已有的熄屏数字一览（按日期）

| 日期 | 条件 | 数值 | 出处 | 备注 |
|---|---|---|---|---|
| 10-15 | Wi‑Fi rfkill 关，旋钮全关，y9 | 0.36 W | README:1432 | 当时基线下 −0.19 W；E3a 下**待测** |
| 10-15 22:30 | 零风险 A/B 四窗 | 0.43/0.41/0.40/0.43 W | README:1444 | ±0.03 W 量级即此 |
| 10-16 04:08–04:38 | E3a 第二轮，y10 | 309 mW（分钟均值 183–430） | README:1526 | 含两个 drop-in，ssh 轮询污染 |
| 10-17 00:50 | 旋钮全关，5 min | **0.33 W**（0.28–0.53） | README:1320 | 续航速查基线 |
| 10-17 01:51–02:21 | E3a 30 min | 0.30/0.27/0.27 W | README:1548 | 同晚全关 0.33 → ≈ −0.05 W |
| 10-18 00:48 | E0（`runs/E0-20261018-0048/summary.txt`） | 353 mW / 1201 行 | runs | 头行 `aco=Y aso=Y`，**存疑**，别当纯全关基线 |
| 10-18 01:24 | E4@E3a 面板 20 s 亮灭 | 723 mW / 2404 行 | runs | 亮灭本身的功耗 |
| 10-18 02:19 / 03:04 | E3b / E3c | 318 / 307 mW（各 1803 行） | runs | cxsd 仍 0 |
| 10-18 03:50 | E5@E3c Wi‑Fi 流量 | 511 mW / 1202 行 | runs | ping/iperf 期间 |
| 10-18 04:25 | E4@E3c | 651 mW / 1202 行 | runs | — |
| 10-18 07:10 / 07:58 / 08:15 | E3a / E3b / E3c | 310 / 275 / 286 mW（各 902 行） | runs | README:1565 另给 305/274/285 与 cx-auto 267（4.5 min） |
| 10-19 04:27–05:59 | cx-auto E3a 生效 | **0.24 W** | `runs/status-20261019.md:69` | 189+219 行小时均值，唯一的 E3a 长窗 |
| 10-19 13:00–13:27 | cx-auto armed 但无效 | 0.33–0.39 W | 10-19 快照 | 本稿要治的损失 |

### 0.3 方法原则（本稿硬规则）

1. **三档收益口径**：≥0.1 W 主线；0.03–0.1 W 是 A/B 能分辨的次线（电池电流 5–8 s 更新一次，<0.03 W 测不出，`status:79`）；**<0.03 W 的候选不下功耗裁决**，只用代理指标（唤醒/s、`pd=sys` 次/s、apps-pc 驻留 %、中断计数）判「代理有效/无效」，零风险的几项捆成一臂一夜测完（§3.3）。
2. **测量期间不 ssh**：root 无 linger，每次 ssh 登录拉起/拆掉 `user@0`，熄屏 trace 4.8 次/s cgroup 释放、22 次/s `kick_all_cpus_sync` 全核 IPI（`linux/power/cx-collapse/PROTOCOL.md:89`）。夜测一律走持久 timer + 计划文件（§2.16 TL-1）或白天短 ssh 预排的 `systemd-run` 单元，跑完一次收。**每日体检定时任务是从 Win11 经 ssh 跑的**（README:65），测量夜必须改期或改成平板本地 timer（TL-3）。
3. **每个修复配体检项**：`tools/y700-checklist.py` 的新增/改动见 §2.19 总表。
4. **重启只在两种窗口**：P1 现场 ssh 窗口（白天、亮屏、≤10 min、作者点头）与 P3 重启窗口（作者在场或我在同一局域网能物理重启）。P3/P5 的重启只排在「当晚没有 P2 单元、前一夜裁决已出」的日子；重启当晚只跑 N1 式空 A/B 做对照。重启前先说一声、确认没人在用。
5. **作者已定、本稿不再列候选**：日常 E3a 不升档（10-18）；不休眠（s2idle 不做）；wiliwili「低质量播放」不开；熄屏杀 Claude 的定时器已删，用 BFS 开关治。
6. **发布边界**：报上游 bug / PR、推公网、改 sudoers/sshd/防火墙、切系统、重启，每次单独点头。
7. **常驻程序 Rust**：Win11 无 cargo；平板上用 apt 的 `librust-*` 离线编。Python 常驻按实测 CPU 排队移植（§2.12 UP-1）。
8. **单元命名**：`y700-cx-auto` 把任何 `y700-cx-*`（除自己和 `y700-cx-status*`）和 BENCHES（`y700-offmeasure y700-offbench y700-l1ssbench y700-powerbench y700-wakeups y700-standby-now`，`linux/power/cx-auto/src/main.rs:46-48`）视为实验、立即 disarm（`experiment_running()` :107-115）。所以：实验单元 `y700-cx-<name>`（被 disarm 是期望）；**诊断单元一律 `y700-diag-<name>`**，绝不用 `y700-cx-` 前缀、绝不进 BENCHES；场景记录 `y700-scn-rec-<scene>-<ts>`。
9. **作者报 bug 先停实验**：附录 B「中止」给出具体命令；此时允许 ssh。
10. **上游优先**：改法先查 tb323fu-linux / armadaos / linux-next；新依赖记进上游清单（现无 UPSTREAMS 文件，位置待 §7-28）。

### 0.4 本稿要保护、不能被实验弄坏的三件事

1. Chrome waitboost 垫片（`/etc/ld.so.preload` 里的 `/usr/local/lib/y700-no-waitboost.so`，5.0 → 3.6 W，10-18）。
2. 1041 Wi‑Fi 省电修复与 `tailscaled` drop-in（熄屏 Wi‑Fi 不掉、Tailscale 在线）。
3. `y700-cx-auto` 日常 E3a 的稳定性：所有新 Rust 改动走 `.prev` + `rollback.sh`（§4 P1.5），出事先回滚再研究。

---

## §1 场景矩阵

### 1.1 熄屏（电池；Wi‑Fi+Tailscale 在线、蓝牙开，除非另注）

| # | 场景 | 现状功耗 | 日期/出处 | 主要去向 | 候选 | 备注 |
|---|---|---|---|---|---|---|
| 1 | 熄屏、E3a armed 且**有效** | 0.24–0.30 W | 10-17 夜 README:1548；10-19 04:27–05:59 `status:69` | apps-pc 驻留逐次不同：67 %（10-16 y10，上限）/ 40 %（10-17 夜 y12）/ 34–39 %（10-18 有效段）；Wi‑Fi 关联残余 ≈0.06 W（10-15 rfkill 口径，E3a 下**存疑**）；rtc@6100 失败写 ≈0 W（只是唤醒计数噪声，`linux/power/ALWAYS-ON.md` §5b） | CPU-1/2/3/6、WK-8、WIFI-1/2 | 本稿的「正常」地板 |
| 2 | 熄屏、E3a armed 但**无效** | 0.33–0.39 W | 10-19 13:27 快照 | plasmashell 1.2 % CPU；`arch_timer` cpu0 107/s；IPI1 101/s；cxsd=0 | CPU-2（T0 判卡）、CPU-3（T1/T2）、CPU-6（根因）、WK-8 | **当前最大损失** |
| 3 | 熄屏、旋钮全关 | 0.33 W | 10-17 00:50 README:1320；10-18 331 mW README:1565 | 同 1 减 E3a | — | 对照臂；也是 cx-auto 自禁用后的实际状态 |
| 4 | 纯待机（Wi‑Fi rfkill、蓝牙关） | 0.36 W（y9，旋钮全关） | 10-15 README:1432 | 非无线部分的地板 | WIFI-1 | **E3a 下待测**；只作判断 Wi‑Fi 残余的锚，日常不关 Wi‑Fi |
| 5 | 夜间 8 h+ 长熄屏 | **待测** | 10-18 23:30–04:27 因充电作废；只有 1.5 h 窗 0.24 W | — | §3.5 周 soak | X48：305 vs 267 是窗口噪声；两种续航口径并存（≈100 h @0.33 W，≈140 h @0.24 W） |
| 6 | 熄屏 + Wi‑Fi 接收流量 | +0.2 W（580 KB/s） | 10-18 `linux/video/wifi-rx-cost.sh` 头注 | ath12k/PCIe 退出低功耗 | WIFI-2/4、PCIE-1/2 | E5@E3c 511 mW（10-18 03:50，runs） |
| 7 | 熄屏 + 蓝牙连接（音箱/手柄） | **待测** | — | hci0 唤醒、A2DP 编码 | BT-1 | scn-rec 触发 `hci0` 连接 |
| 8 | 熄屏 + 充电 | **整机 W 不可测**（含充电损耗） | 10-18 夜作废即此 | 插电时系统域一次都进不去（PROTOCOL.md:92） | CHG-1 | cx-auto 只在放电 arm；B2 `charger_at` bug → §7-6 |
| 9 | 熄屏 + 外接 DP | **待测** | — | card1-DP-1 | DSP-6 | scn-rec 触发 `status=connected` |
| 10 | 熄屏 + s2idle | **作者已定不做** | README:1328/:1449；10-13 PCIe L2 超时 README:1135；s2idle 唤醒后 ath12k 整卡重初始化、先连 2.4G 约 35 s 后切 6G README:240 | — | — | cmdline 仍 `mem_sleep_default=s2idle`，但 suspend 已 mask（`linux/power/y700-no-suspend.sh`） |

### 1.2 亮屏（电池）

| # | 场景 | 现状功耗 | 日期/出处 | 主要去向 | 候选 | 备注 |
|---|---|---|---|---|---|---|
| 1 | 桌面静置，最低背光 | 1.13 W（y7）/ 0.93 W（y9） | 10-14/10-15 README:1321、:677 | 背光、30 Hz 合成 | DSP-1 | bl99 静置 **待测**（§3.5） |
| 2 | 桌面静置，背光 10/50/100 % | 1.38 / 2.75 / 4.50 W | 10-15 README:1322 | 背光（最低到最高 ≈3.4 W，README:1465） | — | 背光是亮屏最大单项 |
| 3 | 网页 / Claude 会话 | 5.31 W 前台 / 4.59 W 最小化（高背光，120 Hz） | 10-15 README | 背光、120 Hz 合成、Chrome 渲染、GPU 加频（垫片只认 `comm==chrome`） | SHIM-1/2、GPU-1/2 | 静态网页 bl99 **待测** |
| 4 | 面板钉死 120 Hz vs 自动降刷 | +0.5 W（5.01 vs 4.50） | 10-15 13:04 y7 README:1462/:1465 | 静止桌面 80–85 % 时间在 30 Hz | DSP-2/3 | **没有**「固定 120 vs 60 桌面」数据；60 Hz 是磁贴可选项，默认 120 是作者两次要求（README:392、:709） |
| 5 | 本地 mpv 1080p30 HEVC | ≈1.6 W（30 Hz 模式 1.33 W） | 10-16 y12 README:1323（表中「1080p60」是笔误，应为 1080p30，§6 c23）；`status:114` | 解码 + 背光 99 | VID-5 | 1080p60 无有效数据；2160p60 2.74 W（README:924） |
| 6 | wiliwili 看 B 站（60 帧、背光≈760/4095、扬声器） | ≈2.7 W | 10-16 README:1324、`status:115` | 背光、解码、扬声器 | VID-1（不做）、DSP-3 | 「低质量播放」−0.17 W（README:1326），作者不开 |
| 7 | Chrome YouTube 真会话 | 4.96 → 3.64 W（垫片）→ 3.30 W（守护） | 10-18 22:1x–22:32 五对 `status:116`、README:985-994 | 背光、GPU 加频风暴、扬声器、Wi‑Fi | GPU-1、VID-2 | 受控 kiosk 3.8–3.9 → 2.4–2.7 W（`status:117`）；真会话（S）与 kiosk（O）绝不互比 |
| 8 | 游戏（Steam / FEX） | **待测** | `status:61` | GPU/CPU、HUD | GPU-4/5 | scn-rec `FEXInterpreter|steam` |
| 9 | CarPlay（LIVI + MFi 认证组件） | **待测** | — | USB 网口/热点、音频、显示 | AUD-1、USB-1、§7-11 | 作者磁贴触发记录；身份材料不公开 |
| 10 | 屏幕键盘 y700-osk / 输入法 | **待测** | README「屏幕键盘 y700-osk」:1964；熄屏 e2e 未做 :2108 | QML 重绘、fcitx5 | UP-9 | scn-rec `osk` 场景：`y700-osk` 窗口可见时 |
| 11 | 外接 DP 双显 | **待测** | — | 双合成 | DSP-6 | — |
| 12 | 亮屏 + 蓝牙音频 | **待测** | — | A2DP 编码 | BT-1 | 与 1.1-7 共用触发 |
| 13 | 实际用机小时均值（不受控） | 2.6–3.7 W，峰 4.9 W | 10-18 14–22 点 `status:118` | — | — | 只作换算基数，不作 A/B |

### 1.3 矩阵使用规则

- 每个候选必须落到 1.1/1.2 至少一行；落不到行的进 §5。
- 「现状功耗」缺失的行 = §3.5 的基线补齐任务；基线超过 8 天未更新，体检 WARN（`check_flightrec` 改动）。
- 真会话（S）与 kiosk（O）数值绝不互比，只比各自的 A/B 差（§3.3）。
- 能量换算（给作者看收益用）：熄屏一夜 10 h × 0.05 W = 0.5 Wh ≈ 电池 1.5 % ≈ 亮屏 8–11 min（按 2.6–3.7 W）。没有任何候选有「十倍」量级的证据。

---

## §2 候选清单

### 2.0 字段规则

- **进 P1–P5 的候选写 10 个字段**：收益 / 依据 / 风险 / 文件·服务 / 验证 / 重启·重编 / 授权 / 体检项 / 回退 / 阶段。
- **§5 与 P6 的候选写 3 个字段**：收益 / 理由 / 出处。
- 「收益」一律写区间 + 日期 + 出处；没测过写「待测（代理：…）」。「授权」写「否」表示不重启、不改安全设置、不对外；写「是」时指向 §7 的条目号。
- 候选编号沿用设计时的子系统前缀：M 测量基础设施、CPU、GPU、DSP 显示、VID 视频、WIFI/PCIE、USB、AUD、MOD 5G、SEN 传感器、WK 唤醒源、UP 常驻、SHIM 垫片、KCF 内核固件、CHG 充电、TL 定时、SCN 场景记录。

### 2.1 M — 测量基础设施

**M-1 飞行记录器切片工具 `tools/fr-slice.py`（新）**
- 收益：无功耗收益；所有夜测裁决的前提。依据：现在切窗靠手算（README:1565 的数字就是手切的）。
- 风险：无（Win11 离线解析）。文件：`tools/fr-slice.py`；输入 `/var/log/y700-flightrec/flightrec-<boot>.log`（`t= at= up= bat=±mW dpms= wifi= … pd=cl0:u/r,cl1:u/r,sys:u/r qs=`，空闲 10 s/行、实验 1 s/行）。
- 验证：解析 10-17/10-18 两夜日志，复现 README:1548/:1565 的数字（±5 mW）；认两种行格式（M-6 加列前后）；按 `MARK` 行切窗；输出每窗 mean/median/N/作废原因。
- 重启·重编：否。授权：否。体检：无（Win11 工具）；配 `tools/ab-index-check.py` 扫 `runs/` 里有切片无裁决的夜。回退：删文件。阶段：P0。

**M-2 `cx-exp.sh` 的 MARK 语义固定**
- 收益：统一裁决口径。依据：`cx-exp.sh:37` 已有 `mark()` 走 `y700-flightrec --mark`；`exp-collect.sh` 按 start/end MARK 汇总。
- 风险：改 `cx-exp.sh` 误触 EXIT trap（它写 ACO/ASO 0、AOSS 0）。文件：`linux/power/cx-collapse/cx-exp.sh`、`PROTOCOL.md`。
- 验证：只认三种 `MARK <STEP>:<N>` / `MARK ABORT:<原因>` / `MARK DIAG:<name>`；fr-slice 用同一套。重启·重编：否（复制脚本）。授权：否。体检：`check_cx_knobs`（guard :783）改动。回退：git revert。阶段：P1.5。

**M-3 `--blink` 亮屏自检（仅 cx-exp 梯度用）**
- 收益：区分「E3a 卡住」与「真有效」。依据：E4 已有面板 20 s 亮灭（`cx-exp.sh:163`，夜跑时背光最低）。
- 风险：无人值守亮屏→幽灵触点（README:1051）；与 CPU-3 T1 功能重复。文件：`cx-exp.sh`。
- 验证：只在梯度步之间用；亮前经 `org.kde.ScreenBrightness` 调暗，≤10 s；NVT 触摸 `/sys/class/input/inputN/inhibited` 写 1，trap 恢复。**日常只用 T1，绝不两者同夜。** 重启·重编：否。授权：否。体检：`check_touch_inhibit`（新）保证 inhibited 不残留。回退：不传。阶段：P2 N2 以后。

**M-4 阶梯脚本 `cx-when-idle.sh` 加 `DIAG:` 步**
- 收益：诊断包在 idle 门槛、dpms Off、电池三条件下跑（脚本已做这三条等待，头注 :9-12），不再 `--on-active=15min` 盲跑撞上作者用机。
- 风险：诊断包自身唤醒污染窗口（R12 剔除）。文件：`linux/power/cx-collapse/cx-when-idle.sh`（现有 `[--idle MIN] [--from HH:MM] [--until HH:MM] STEP:MIN ...`）。
- 验证：`DIAG:5` 执行 `always-on-check.sh --rtc 90 --no-clk`（屏已 Off **不加 `--off`**；`--rtc` 会建 tracefs 实例 `instances/y700-always-on`，是它唯一的写动作，跑完删）+ `y700-whoawake 60`（**不加 `--off`**）+ `MHI_SECS=0 y700-l1ss-probe.sh`（只读，无参数）。重启·重编：否。授权：否。体检：`check_trace_leftovers`（新）。回退：阶梯不写 `DIAG:`。阶段：P1.5。
- 出处：`linux/power/always-on-check.sh:2-12`；`tools/y700-whoawake.py:1-7`；`tools/y700-l1ss-probe.sh:1-6`。

**M-5 诊断包的 ExecCondition 备选**
- 收益：没有阶梯时也能安全跑一次诊断。风险：条件误判即空跑。文件：`linux/power/y700-diag-pack.sh`（新）。
- 验证：ExecCondition：dpms On → 跳过；10 min 内 NVT/power 中断有增量 → 跳过；充电 → 跳过。重启·重编：否。授权：否。体检：无（一次性单元）。回退：删脚本。阶段：P1.5。

**M-6 状态页扩列**
- 收益：Win11 每日一条 curl 就能判断 `cx_stuck` / `cx_disabled` / 夜计划是否在跑，不用 ssh。
- 依据：状态页只读、不解析请求（`linux/power/cx-collapse/y700-cx-status:6-7`、PROTOCOL.md:91）；`ListenStream=100.64.0.10:8766`（socket :11）；`DynamicUser=yes`、`ProtectSystem=strict`（`y700-cx-status@.service:13-14`）→ 不能跑 systemctl/loginctl，脚本靠 cgroup 目录判单元。
- 风险：无（仍只读）。文件：`y700-cx-status`（sh）。
- 验证：新字段 `cx_disabled`（`/var/lib/y700/cx-auto.disabled` 存在）、`armed_since`、`u0`（`/run/user/0` 存在）、`ssh_sessions`（数 `/run/systemd/sessions/*` 里 `SERVICE=sshd`，**DynamicUser 下可读性存疑，P1 现场验**）、`e3a_fail_rate_3d`（读 CPU-2 T0 计数器）、`night_plan_next`（`/etc/y700/night-plan` 首行）、`experiment_unit` 已有。重启·重编：否（`systemctl restart y700-cx-status.socket` 不需要，socket 激活每次新起）。授权：§7-17。体检：`check_status_page`（新：本机 curl，字段齐全）。回退：git revert 脚本。阶段：P1（纯 sh 的 `cx_disabled`/`armed_since`）/ P1.5（其余）。

**M-7 Win11 侧每日巡检合并**
- 收益：周期性义务机器化。风险：Tailnet 不通→误报，只在三种值异常时通知。文件：Win11 现有每日巡检任务（加一条 `curl http://100.64.0.10:8766/`）。验证：`cx_stuck`、`cx_disabled`、「夜计划有行但 `experiment_unit` 为空」三种才通知。重启·重编：否。授权：§7-18。体检：平板侧 `check_status_page`。回退：删任务行。阶段：P0。

### 2.2 CPU — 簇/系统下电（apps-pc）与唤醒

**CPU-1 apps-pc 票数诊断 `live-ro3.sh`（新）**
- 收益：定位 E3a 无效时谁在投反对票。依据：10-19 快照的 `live-ro.sh`/`live-ro2.sh` 已能读 `pm_genpd/*/idle_states`、`qcom_stats/apss`、`/proc/interrupts` 20 s 差分、按进程 CPU tick、cpuidle usage；缺的是 plasmashell 线程级 `schedstat`、`cpuidle/state*/usage` 60 s、`iio` buffer、`CONFIG_RTC_SYSTOHC|PSI`、`kernel.watchdog_thresh`、memlat `polling_interval`、chrony `rtcsync` 行。
- 风险：无（只读 sysfs/procfs/debugfs 摘要文件；**仍不读** `/sys/kernel/debug/pcie@*`、regmap、dri、clk_summary——10-15 03:41 挂死总线）。文件：`linux/power/live-ro3.sh`。
- 验证：`systemd-run --unit y700-diag-cx-votes --collect -p KillMode=mixed /usr/local/libexec/live-ro3.sh`（**不是** `y700-cx-votes`，否则 cx-auto 当实验 disarm，看到的是全关态）；产物 scp 回 `runs/diag/`。重启·重编：否。授权：§7-1（P1 窗口）。体检：无。回退：无。阶段：P1。

**CPU-2 cx-auto T0：卡住判定与自动取证**
- 收益：把「armed 但无效」从人工发现变成机器判定并留证据；无功耗收益。依据：10-19 快照；`main.rs` 只在 arm 时查 `download_mode`、uptime≥240 s、flightrec 在跑，arm 后**不回读**是否生效。
- 风险：判错→多一次取证；Rust 改动要平板离线编（apt `librust-*`）。文件：`linux/power/cx-auto/src/main.rs`（头注 :1-29，Usage :28-29）。
- 验证：armed+120 s 起，5 min 滑窗读 `power-domain-system` 进入次数（`/sys/kernel/debug/pm_genpd/power-domain-system/idle_states`），**连续两窗 <1/s** 判 `cx_stuck`（避开熄屏头几分钟 Chrome/Claude 合成线程未停的假卡，体检 :800 附近注释）。判卡即自跑 `systemd-run --unit y700-diag-stuck-<ts> --collect …`：`y700-whoawake 60` + plasmashell `/proc/<pid>/task/*/schedstat` 60 s 差分 + `/proc/interrupts` 60 s 差分 → `/var/log/y700-cx-auto/stuck-<ts>.txt`；计数器落 `/var/lib/y700/`（给 M-6 的 `e3a_fail_rate_3d`）。
- 重启·重编：**重编 + `systemctl restart y700-cx-auto`，不重启系统**。授权：§7-2。体检：`check_cx_effect`（guard :849，改为读 T0 计数器）、`check_cx_stuck_marker`（新：一夜 >3 次 WARN）。回退：`cp <bin>.prev <bin> && systemctl restart y700-cx-auto`。阶段：P1.5。

**CPU-3 cx-auto T1/T2：卡住后的处置**
- 收益：若 T1（≤10 s 调暗亮屏再灭）或 T2（重启 plasmashell）能让 apps-pc 恢复，夜间从 0.33–0.39 W 回到 0.24–0.30 W，≈0.05–0.1 W（10-19 vs 10-17/10-19 凌晨，**待验**）。依据：10-18 README「熄屏省电开着却没生效」里一次亮灭屏让合成线程停下。
- 风险：T1 亮屏误触（NVT inhibited 保护；PowerDevil 再亮时恢复自身亮度的行为**存疑**，`linux/video/video-mpv-ab.sh:63` 的 sleep 4 教训，N2′ 观察）；T2 丢小程序运行态（窗口归 KWin 不丢）、夜里 plasmashell 起不来 = 早上没面板；两者都**治标**，根因在 CPU-6。
- 文件：`main.rs`；`/etc/default/y700-cx-auto`（新键 `STUCK_ACTION=none|blink|restart-shell`）。
- 验证：每次熄屏 T1/T2 **至多一次**、两次动作间隔 ≥30 min、刚发生「亮屏后又卡」时不动作；T2 后 15 s 验 `systemctl --user -M user@ is-active plasma-plasmashell`，失败重试一次，再失败写 `plasmashell_down=1` 到 stuck 文件、状态页可见、体检 WARN。
- 重启·重编：重编 + restart 服务。授权：§7-7（T1）、§7-8（T2）、§7-9（频率）。体检：`check_cx_stuck_marker`、`check_cx_auto_config`（新：键合法）。回退：`STUCK_ACTION=none`。阶段：N3 起。

**CPU-4 `--keep-cx`：BENCHES 在 E3a 下跑**
- 收益：让 offbench/powerbench 等能测日常地板而不是全关地板。依据：10-15/10-16 的 bench 全跑在旋钮全关（早于 cx-auto 10-17 上线，是 cmdline 默认关，**不是**被 disarm，§6 c12）；10-17 后没再跑过任何 bench。
- 风险：忘记恢复→旋钮残留（`check_cx_knobs` 兜底）。文件：`cx-exp.sh`（`--keep-cx`：不写 ACO/ASO/AOSS，trap 也不恢复）；`main.rs`（BENCHES 单元存在时不 disarm）。
- 验证：P2 的 K= 夜一律用方案 (a)：`E3a+K=<knob>:15 / E3a+K=noop:15`，两臂都由 cx-exp 持 E3a，**不依赖新 Rust**；`--keep-cx` 只留给 BENCHES。重启·重编：重编 cx-auto。授权：§7-14。体检：`check_cx_knobs` 改动。回退：不传选项。阶段：P1.5。

**CPU-5 `arch_timer` cpu0 107/s 归因** → 并入 WK-8。

**CPU-6 plasma-nm 根因（plasmashell 熄屏 1.2 % CPU）**
- 收益：若根因即此，T1/T2 可退役，夜间地板稳定在 0.24–0.30 W（待验）。依据：10-18 README「熄屏省电开着却没生效」查到 plasma-nm 转圈动画（BusyIndicator）；10-19 再现但无 CarPlay 热点触发。
- 风险：本地 QML 补丁随系统升级失效；报上游属对外发布。文件：待定位（P1 只读定位 plasma-nm 包内 QML/插件文件，不改）。
- 验证：P1 取 plasmashell 线程 `schedstat` 60 s 差分 + `arch_timer`/IPI 差分；定位后在 N2′ 的 stuck 取证里再确认一次。重启·重编：补丁落地要重启 plasmashell（不重启系统）。授权：§7-10。体检：`check_plasma_nm_patch`（新，若落地）。回退：删补丁。阶段：P1 定位 / P3 落地。

**CPU-7 充电时 apps-pc 进不去** → §5（PROTOCOL.md:92；整机 W 不可测）。

**CPU-8/9/10 调度器与 cpuidle 旋钮（teo 参数、`y700-cpuidle.conf`、`90-y700-uclamp.conf` 再调）** — 收益 <0.03 W 预期，无数据；理由：不下功耗裁决，代理 `cpuidle/state*/usage`，N5 捆臂；出处：`linux/power/y700-cpuidle.conf`、`90-y700-uclamp.conf`。→ P6。

**CPU-11/12 内核侧 CX 预研（cxsd 为什么永远 0、AOP 投票）** → §7-29，P6。

### 2.3 GPU

**GPU-1 waitboost 垫片保持 + 体检**
- 收益：Chrome 真会话 5.0 → 3.6 W（10-18 22:40，README:985 结论 7）。依据：README「视频播放功耗」的 waitboost 风暴排查。
- 风险：全局 `/etc/ld.so.preload` 让测试进程也带垫片（A/B 要 `unshare -m` 隔离）。文件：`linux/gpu/{y700-no-waitboost.c,install-no-waitboost.sh,no-waitboost-ab.sh}`；开关 `/run/user/1000/y700-no-waitboost.ctl`（`Y0` = 关）。
- 验证：`no-waitboost-ab.sh`。重启·重编：否（已上线）。授权：否。体检：`check_waitboost_shim`（新：preload 行存在、.so 可加载、ctl 文件状态）= 审计 C3，**无条件做**。回退：删 preload 行。阶段：P1.5。

**GPU-2 gpu-floor 与 gpu-dvfs 两份配置可见**
- 收益：无功耗；防混淆。依据：`/etc/default/y700-gpu-floor` 只有 `FLOOR_MHZ=342 CEIL_MHZ=500 RELEASE_S=3 USER_UID=1000`（可选 `CEIL_WHEN`）；`UPTHRESHOLD=80 DOWNDIFFERENTIAL=10` 在**另一份** `/etc/default/y700-gpu-dvfs`，由 `y700-gpu-dvfs.service` 开机写 `/sys/kernel/debug/dri/1/devfreq/`（§6 c27、X32）。
- 风险：无。文件：两份 default + `linux/power/gpu-floor/`、`linux/power/gpu-dvfs/`。验证：无。重启·重编：否。授权：否。体检：`check_gpu_dvfs`（guard :675，已有，读 80/10）；`check_gpu_floor`（新：四键）。回退：无。阶段：P1.5。

**GPU-3 上限与垫片的关系（X31，已定案）** — `linux/power/gpu-floor/src/main.rs:93-95` `ceil = !shim && …`；`shim_on()` :237-239 在 ctl 以 `Y0` 开头时返回 false → **上限重新生效**；`test-gpu-floor.sh` 断言「Y0 → ceiling comes back」；头注 :9-13 说明上限只是无垫片 Chrome 的兜底。README:1000「把上限放回来」措辞按此修（§6.2）。无实验。

**GPU-4 无人值守游戏 kiosk 上限试探**
- 收益：待测（游戏从未在电池上测，`status:61`）。依据：README:1759 Chrome GPU 挂死 → `hangcheck recover!`，三次后 Chrome 放弃硬件加速（`GL_GUILTY_CONTEXT_RESET_KHR`）。
- 风险：GPU hang 后整臂作废、功耗反升、夜里无人发现。文件：`linux/games/`、`/etc/default/y700-gpu-floor`。
- 验证：R14——日志出现 `context lost` / `GL_GUILTY_CONTEXT_RESET` 即 `MARK ABORT`；**无人值守不试 <422 MHz 上限**；事后验 `chrome://gpu` 仍硬件加速。重启·重编：否。授权：§7-5。体检：`check_gpu_floor`。回退：恢复 `CEIL_MHZ=500`。阶段：P5。

**GPU-5 HUD `linux/games/hud/y700-power` 孤儿脚本（审计 B4）与第 2/3 名次（B11）** → §7-19 / §7-20。

**GPU-6 gpu-dvfs 80/10 再调** — 收益 <0.03 W 预期；理由：DVFS 由 CPUCP 固件做（README:1402）；→ P6。
**GPU-7 preload 垫片自身开销** — 预期 ≈0（每进程一次 dlsym，无常驻）；出处 `linux/gpu/y700-no-waitboost.c`；→ P6。

### 2.4 DSP — 显示、刷新率与 DPMS

**DSP-1 桌面静置 bl99 基线** → §3.5 基线补齐（kiosk `--desktop-idle 5min`），无实验。

**DSP-2 默认刷新率** → §5（作者两次要求默认 120：README:392、:709；X33 判为产品决策；磁贴切 60 即成新基准 README:716）。§7-26 只是确认。

**DSP-3 refresh-auto 30 Hz 档的真实收益**
- 收益：自动降刷整体 +0.5 W（10-15 y7，README:1462/:1465）；30 Hz 单档 **待测**，P6 出口判据「30 Hz 相对 60 Hz ≥0.03 W」。风险：低刷观感。文件：`linux/display/refresh-auto/`（Python）。验证：kiosk 固定内容 60 vs 30 各 5 min × 3 轮镜像。重启·重编：否。授权：否。体检：`check_refresh_auto`（guard :667，已有）。回退：无。阶段：P6。

**DSP-4 审计 A 项处置（`runs/audit-20261019.md` §4）**
- A2 看门狗 vs 刷新守护 D-Bus suspend → §7-22。
- A5 磁贴按当前模式猜下一步 → 改读守护的 `base_hz`，P3 顺手。
- A6 `hz == vt` 例外 → 删除，P3 顺手。
- A7 输入护盾 存疑 → P6。
- A9 睡眠锁 → suspend 已 mask，失效议题，不做。
- A10 FIFO open、A11 触摸路径只取一次、A13 `y700-autobright-ctl` 返回码 → P3 顺手。
- 每项配 `linux/display/refresh-auto/test-*.py` 桩测试（审计已建 `test-retry-offline.py` 先例）。

**DSP-5 PowerDevil 在 DPMS 下恢复亮度** — 无功耗；T1/kiosk 的前提知识；`video-mpv-ab.sh:63` PowerDevil 唤醒后 sleep 4 恢复自身亮度；T1 调暗→灭→再亮时行为**存疑**，N2′ 观察。

**DSP-6 外接 DP** — 待测；scn-rec `--trigger sysfs:/sys/class/drm/card1-DP-1/status=connected`；P4。

**DSP-7 自动亮度 `y700-autobright`** — 体检内联 :642-644 已有；无功耗实验；触感档恢复见 UP-3。

**DSP-8 DPMS 后 KWin 合成是否真停** — 代理：熄屏后 `kwin_wayland` 线程 `schedstat` 60 s 差分应 ≈0；P1 的 `live-ro3.sh` 顺带读；异常才立项。

### 2.5 VID — 视频

**VID-1 wiliwili 低画质补丁** — 作者已定不开；`linux/video/wiliwili-*.patch` 仅保留；§5。
**VID-2 YouTube 入口（mpv + yt-dlp）**
- 收益：净收益 **待测**，上限 ≤0.5 W（kiosk v1.4 YouTube 2.4–2.7 W vs 真会话 3.3–3.9 W 口径不同不能直接减，§6 c23）。风险：yt-dlp 失效、无字幕/弹幕、作者体验。文件：`linux/video/`（入口脚本待定）。验证：S/O 各自 A/B；scn-rec `yt`。重启·重编：否。授权：§7-25。体检：`check_yt_entry`（新）。回退：删入口。阶段：P4。
**VID-3 Chrome 真会话 waitboost** → GPU-1。
**VID-4 视频时自动降刷** → DSP-3（已上线，README:709）。
**VID-5 mpv 基线修正** — 1080p30 HEVC ≈1.6 W；README:1323「1080p60」改「1080p30」；无实验（§6.2）。

### 2.6 WIFI / PCIE — Wi‑Fi 省电、Tailscale、PCIe L1.2

**WIFI-1 Wi‑Fi 关联残余 ≈0.06 W 归因**
- 收益：若归因到 beacon/DTIM 周期，可能 0.03–0.06 W（**存疑**）。依据：10-15 rfkill 对照 0.36 vs 0.55 W（README:1432，y9，旋钮全关）；E3a 下从未重测。风险：无（只测不改 AP）。文件：`tools/y700-l1ss-probe.sh`（只读）；knob 脚本 `linux/power/knobs/rfkill.sh`（新，on/off/自检）。验证：N4 `E3a+K=rfkill:15 / E3a+K=noop:15`；代理 ce2 中断/s。重启·重编：否。授权：否。体检：无。回退：knob off。阶段：N4。

**WIFI-2 ath12k 省电参数（power_save 已开，`iw dev wlp1s0 get power_save` 体检 :912）**
- 收益：待测。风险：Tailscale 掉线→状态页不可达到早上。文件：`linux/power/knobs/<knob>.sh`。验证：on/off 后 60 s 内 `tailscale status --json` BackendState=Running 且 dpms 仍 Off，否则回滚 + `MARK ABORT`；**每个旋钮白天先 15 min 试一次**。重启·重编：否。授权：§7-15。体检：无。回退：脚本 off。阶段：N4。

**WIFI-3 Tailscale 唤醒** — `linux/power/tailscaled-wakeups.conf` 已上线（10-16，README:1694）；R13：tailscaled/powerdevil 重启 ±60 s 的行剔除；无新实验。

**WIFI-4 AP 拆 SSID（2.4G 独立 / DTIM）** — 需作者改 AP（§7-27）；收益待测；P4。

**PCIE-1 L1SS 探针** — `tools/y700-l1ss-probe.sh` 只读；P1 诊断。研究结论见 `linux/power/PCIE-L1SS.md`（10-16）。
**PCIE-2 PCIe runtime PM / 1049 DT `t-power-on-us`** — 进 KCF-4（y13）；P6 出口：`runtime_status` 60 s 内 suspended 且 Wi‑Fi 不掉。

### 2.7 USB

**USB-1 USB 控制器 runtime PM** — 已上线（`linux/power/90-y700-usb-rpm.rules`，10-15；体检内联 :884-888）；5 s 自动挂起（README:1445）。**X11 真矛盾**：规则头注说「OTG 设备识别已验证」，README:1445 同一 commit 说「没有验证」→ 以 README 为准，OTG 识别**待作者下次插 U 盘/键盘时验证**（体检 :888 已提示识别不了就 `echo on`）。无新实验；P4 顺带。
**USB-2 CarPlay 的 USB 网口/热点功耗** → 1.2-9，scn-rec `carplay`。

### 2.8 AUD — 音频 PipeWire

**AUD-1 扬声器挂起钩子** — `linux/audio/{y700-speaker-suspend.lua,y700-speaker-suspend.conf,61-y700-speaker-raw-virtual.conf}` 已上线（`linux/audio/SUSPEND.md`）；体检 `check_speaker_suspend_hook`（新：三文件在位）；无实验。
**AUD-2 `y700-audio-watch` / `y700-speaker-guard` 常驻** — CPU 待测；进 UP-1 队列。
**AUD-3 蓝牙音频熄屏** → BT-1（1.1-7）。

### 2.9 MOD — 5G 模组

**MOD-1 调制解调器单元** — 现状：`tb323fu-dsp-no-cdsp.conf` 在 `linux/power/`；remoteproc 状态由 `live-ro2.sh` 读；收益待测（快照 cdsp 睡 ~100 %，§6 X20）；体检 `check_modem_units`（新：remoteproc/mhi 单元状态只读）；→ P6。

### 2.10 SEN — 传感器

**SEN-1 IIO 传感器** — P1 读 `iio:device*/buffer/enable`；若为 1 则 N5 做 `K=iio-off` 代理测（唤醒/s）；收益 <0.03 W 预期；autorotate 依赖加速度计，白天不动。

### 2.11 WK — 唤醒源与定时器

**WK-1 memlat/mbox 轮询（`linux/power/90-y700-memlat-poll.rules`）**
- 收益：mbox 中断 ≈10/s → ≈1/s（10000 ms）或 0（关）；是 **deferrable 定时器，不是唤醒源**；DDR/LLCC 调频由 CPUCP 固件做，轮询只抄统计（README:1402）→ 功耗 ≈0，代价只是 `trans_stat` 变粗（§6 c30）。风险：仅 trans_stat 分辨率。文件：规则文件。验证：代理指标，不需要 `burst-ab`。重启·重编：否（udev reload）。授权：否。体检：`check_memlat_poll`（**新**：体检现无 memlat 项，期望值从规则文件读）。回退：规则改回。阶段：N5 捆臂。

**WK-2 tailscaled** → WIFI-3。
**WK-3 PowerDevil ddcutil** — `linux/power/plasma-powerdevil-no-ddcutil.conf` 已上线（README:1685-1694）；体检 WAKEUPS 块 :1005-1031 已有；无实验。

**WK-4 chrony rtcsync（rtc@6100 失败写）**
- 收益：≈0 W（`ALWAYS-ON.md` §5b：写失败 -ENODEV 但仍计一次唤醒，61 次/25 min）；代理 −2.4 唤醒/min。风险：无功能变化（RTC 本来写不进，fake-hwclock 保持）。文件：`linux/power/y700-rtc-sync-off.sh`（备份到 `/etc/chrony/chrony.conf.y700bak`；**无 `--undo`，撤销只在注释里——本稿要求加 `--undo`**）。验证：先 `DIAG:` 步的 `always-on-check.sh --rtc 90` 确认 `rtc_set_time … err=-19` 每 20–30 s 一次；N2 `E3a+K=rtcsync:15 / E3a+K=noop:15` 只看代理。重启·重编：否。授权：否。体检：`check_rtc_sync`（新）。回退：`--undo`。阶段：N2。

**WK-5 helperd 熄屏慢轮询** — `linux/power/helperd-slow-poll.patch` + drop-in `/etc/systemd/system/tb323fu-helperd.service.d/y700-local.conf`（ExecStart 指到 `/usr/local/libexec`，**绝不替换厂商二进制**）已上线；体检**已有**（内联 :1019-1025，升级提示 :67-68）；无新实验。

**WK-6 keyhold 事件驱动**
- 收益：代理唤醒；功耗 <0.03 W。风险：**紧急键（音量键 10 s 回安卓）失效**。文件：`linux/power/keyhold-event-driven.patch`、`y700-keyhold-local.conf`、`keyhold.c`、`keyhold-model-test.py`；上游草稿**已有**（未入公开仓库）。验证：`keyhold-model-test.py` 桩 + 平板上长按音量键 10 s 仍触发。重启·重编：否（drop-in + restart）。授权：§7-24（提交上游另点头）。体检：`check_keyhold`（新）。回退：删 drop-in。阶段：P3。

**WK-7 温控守护轮询** — 风险：温控响应慢；只做 drop-in；收益 <0.03 W；→ P6。

**WK-8 `arch_timer` cpu0 107/s + IPI1 101/s 归因**
- 收益：若归因到 plasmashell/plasma-nm 即 CPU-6；否则待测。风险：无（只读）。文件：`live-ro3.sh`、`tools/y700-whoawake.py`、`tools/y700-wakeups.py`（tracefs 靶子，熄屏用）。验证：`/proc/interrupts` 60 s 差分 + `y700-whoawake 60`，与 `cx_stuck` 标记对照。重启·重编：否。授权：§7-1。体检：`check_cx_stuck_marker`。回退：无。阶段：P1。

**WK-9 `install-wakeups.sh` 两个 drop-in** — 已上线；回退 = 删两个 drop-in + disable timers。

### 2.12 UP — 用户态常驻进程

**UP-1 Python 常驻 → Rust 移植清单**
- 收益：待测（代理：进程 CPU 时间/唤醒）。风险：移植回归。文件：`linux/display/refresh-auto/`（Python；低于基准时每秒查屏，README:715，CPU 待测）；`linux/audio/y700-audio-watch`、`y700-speaker-guard`（30 s 体检）；**不移植** `linux/net/y700-kmsg-watch`（`poll(-1)` 零唤醒，§5）。验证：移植前后 `schedstat` 24 h 差分。重启·重编：否。授权：否。体检：各自现有项。回退：保留 Python 版。阶段：P6（24 h CPU ≥1 % 才排）。

**UP-2 看门狗 15 min 安全阀** — `linux/net/y700-watchdog-safety.conf`（装进 `y700-wifi-watchdog.timer.d/` 与 `y700-display-watchdog.timer.d/`）；体检 :600 `--selftest`；无实验。
**UP-3 autobright 触感档恢复 + A13 返回码** — 无功耗；文件 `linux/display/y700-autobright{,-ctl}`；P3 顺手；体检内联 :642-644。
**UP-4 helperd** → WK-5。
**UP-5 控制面板 `linux/controlpanel/`（C++/QML）** — 与 cx-exp **无任何引用**（不是触发通道）；交互另有硬要求（操作不收起面板、危险操作二次确认）；无功耗实验。
**UP-6 claude-desktop / Chrome BFS** — `linux/power/{claude-desktop-bfs,chromium-bfs.py,bfs-cycle-watch.py}`（README:1616）；作者已定用 BFS；亮屏→熄屏→亮屏验证等作者在场；无新实验。
**UP-7 BFS 通知丢失** — 可靠性议题；P6。
**UP-8 `y700-screen-off-freeze`** — 与 BFS 关系存疑；X9：10-15 否定的是常驻冻结（只省 0.01 W、Telegram 收不到）；P6 核对后决定删或留。
**UP-9 屏幕键盘 y700-osk** — 亮屏场景待测（1.2-10）；熄屏下 e2e 未做（README:2108）；scn-rec `osk`。

### 2.13 SHIM — Chrome 加频垫片

**SHIM-1** = GPU-1。**SHIM-2 覆盖范围（`comm==chrome` 之外的 GL 进程）** — 待测；风险误伤；P6。**SHIM-3 README:1000 措辞** → 按 X31 修（§6.2）。

### 2.14 KCF — 内核配置与固件

**KCF-1 y12 现役** — `7.3.0-rc4-tb323fu-t49-y12`；编内核用 `kbuild-y12.sh` 模板；clang 18 必需（BTI）。
**KCF-2 E1 簇下电** — 088 固件上零复位；已在 E3a 内。
**KCF-3 GPU 门槛 80/10** — `y700-gpu-dvfs` 开机服务；体检 :675。

**KCF-4 y13 试装（= y12 + 1049 PCIe DT `t-power-on-us=<80>` + `CONFIG_PSI_DEFAULT_DISABLED=y`，可选 `CONFIG_RTC_SYSTOHC=n`）**
- 收益：PCIe L1SS 进入率待测；PSI 关 <0.03 W 预期。依据：`linux/power/PCIE-L1SS.md`；`ALWAYS-ON.md` §5b。
- 风险：**1049 改的是 WCN7860 所在 PCIe 链路的 DT，链路训练失败 = 没 Wi‑Fi = 没 Tailscale/ssh**；`tb323fu-ctl kernel install-local --trial` 两次没确认才自动回滚（README:505），要两次物理重启。
- 文件：内核树 + `kbuild-y12.sh` 模板；`tb323fu-ctl`。
- 验证：**作者在场或我在同一局域网能物理重启**；trial 装好后 `systemd-run --on-active=10min --unit y700-diag-trial-watchdog`：`uname -r` 为 trial 且 `tailscale status` 非 Running → `systemctl reboot`；重启后附录 A；`check_psi_off`、`check_pcie_l1ss`（新）；次夜 E3a 地板不劣于 y12（±0.03 W）。
- 重启·重编：**重编内核 + 重启**。授权：§7-3（窗口）、§7-4（看门狗自动 reboot）。体检：同上。回退：两次非 keep 重启自动回 y12。阶段：P3。

**KCF-5 y14：ICE runtime PM 单独一版** — 草稿已有 `linux/power/soc-qcom-ice-runtime-pm.DRAFT.patch`；UFS PHY GDSC 常开（`ALWAYS-ON.md` §UFS）→ P6 CX-B，出口：挂起进入且无 I/O 错误。
**KCF-6 s2idle** → §5。
**KCF-7 `CONFIG_RTC_SYSTOHC=n`** — 与 WK-4 二选一（WK-4 用户态即可，不必动内核）；若 N2 代理有效则不进 y13。

### 2.15 CHG — 充电

**CHG-1 `charger_at` B2 bug** — `main.rs:332,358-368`：`on_battery` 只在熄屏 ≥30 s 后每 60 s 读一次，`charger_at` 不随亮屏复位 → 插电后最长 ~30 s 还按「放电」处理（审计 B2）。修法随 CPU-2 一起 P1.5 发布；授权 §7-6。
**CHG-2 充电夜不做 A/B** → §5。

### 2.16 TL — 定时与阶梯

**TL-1 `y700-cx-night.timer` + `/etc/y700/night-plan` 持久化调度**
- 收益：P2 夜测不靠 transient timer（复位即丢，次晨 `experiment_unit` 为空就是没跑）。风险：计划文件写错→跑错臂（状态页 `night_plan_next` 可见）。文件：`/etc/systemd/system/y700-cx-night.{timer,service}`（每日 00:30；service 读计划首行执行 `cx-when-idle.sh`，完成后把该行移到 `/var/log/y700-cx-auto/night-done.log`）。验证：格式见附录 D；空文件 = 当晚不测；**编辑计划只在白天亮屏 ≤10 min 的 ssh 窗口，退出 ≥30 min 后才允许窗口开始**。重启·重编：否。授权：§7-16。体检：`check_night_plan`（新）。回退：disable timer。阶段：P1.5。
**TL-2 现有做法** — `systemd-run --unit y700-cx-night --collect -p KillMode=mixed --on-calendar=… cx-when-idle.sh --idle 30 --until 06:00 …`（脚本头注 :7-8）；TL-1 上线前的过渡。
**TL-3 本地体检 timer `y700-checklist-local.timer`（新）**
- 收益：体检不污染夜测（现在体检每天从 Win11 经 ssh 跑，README:65；体检本身会跑 `y700-kmsg-watch --selftest` :600 拉起看门狗、读 rawdump、几十次 systemctl）。风险：体检被推迟。文件：timer + ExecCondition 脚本。验证：`/run/y700-cx-auto.armed` 存在、或任一 `y700-cx-*`/`y700-scn-rec*`/`y700-diag-*` cgroup 存在 → 跳过并顺延 1 h；结果写 `/var/log/y700-checklist/`，Win11 巡检改为 curl 状态页的 `checklist_last`。重启·重编：否。授权：§7-18。体检：`check_local_checklist_timer`（新）。回退：disable，恢复 ssh 跑。阶段：P1.5。
**TL-4 周 soak timer** → §3.5。**TL-5** → CPU-4。

### 2.17 SCN — 场景记录器（事件驱动，不轮询）

**SCN-1 `linux/power/scn-rec/`（新）**
- 收益：补齐 §1 的待测行。风险：记录单元自身唤醒（R12）。文件：systemd `.path` 单元 `PathExistsGlob=/run/user/1000/y700-video/chrome-*`（gpu-floor/refresh-auto 已依赖这些状态文件）→ `systemd-run --unit y700-scn-rec-<scene>-<ts>`；`--trigger sysfs:<path>=<value>`（DP、`hci0` 连接、dpms）；`--require-dpms off|on`；游戏/CarPlay/osk 由作者磁贴或窗口出现触发。场景：`web`、`claude`、`yt`、`games`（`FEXInterpreter|steam`）、`carplay`、`osk`、`wifi-rx`（`K=wifi-rx:3` 包 `linux/video/wifi-rx-cost.sh`）、`dp`、`bt`。验证：复用 cx-exp 触摸守卫；每窗记 `NVT-ts-spi` 中断差分（R15）；记录只写 flightrec MARK + 1 s/行。重启·重编：否。授权：否。体检：`check_cx_knobs` 排除 `y700-scn-rec*`。回退：删 .path 单元。阶段：P4。

### 2.18 N6 — 无人值守亮屏 kiosk 夜的保护

- 收益：补 1.2 行 1/3/8 基线。风险：幽灵触点（README:1051）、本机自动锁屏是关的（README:155）、烧屏、Chrome hang。文件：`cx-exp.sh --bright`（新）。验证：NVT `inhibited=1`（trap 恢复）、控制面板折叠、每窗记 `NVT-ts-spi` 差分、亮前调暗；**≤2 h，起始电量 ≥60 %**；R14。重启·重编：否。授权：§7-5。体检：`check_touch_inhibit`（新）。回退：trap。阶段：P5。

### 2.19 体检项总表（`tools/y700-checklist.py`）

现有 guard 行号（10-19 HEAD）：`check_home_gesture` :533、`check_bfs` :581、`check_stale_binaries` :640、`check_refresh_auto` :667、`check_gpu_dvfs` :675、`check_volume_keys` :691、`check_hud` :715、`check_panic_records` :739、`check_rawdump` :763、`check_cx_knobs` :783、`check_cx_auto` :800、`check_cx_effect` :849、`check_flightrec` :872、`check_carplay` :1003；内联：autobright :642-644、USB rpm :884-888、Wi‑Fi power_save :912、kmsg-watch selftest :600、helperd 慢轮询 :1019-1025、WAKEUPS 块 :1005-1031。**体检现在没有 memlat 项、没有 keyhold 项、没有垫片项。**

| 函数 | 新/改 | 候选 | 判据 |
|---|---|---|---|
| `check_waitboost_shim` | 新 | GPU-1（审计 C3） | preload 行 + .so 可加载 + ctl 状态 |
| `check_gpu_floor` | 新 | GPU-2 | `/etc/default/y700-gpu-floor` 四键 |
| `check_memlat_poll` | 新 | WK-1 | `polling_interval` 与规则文件一致 |
| `check_keyhold` | 新 | WK-6 | drop-in 在位、紧急键仍触发（selftest） |
| `check_rtc_sync` | 新 | WK-4 | chrony.conf 状态与备份一致 |
| `check_speaker_suspend_hook` | 新 | AUD-1 | 三文件在位 |
| `check_trace_leftovers` | 新 | M-4 | 无 `instances/y700-always-on` 残留 |
| `check_cx_stuck_marker` | 新 | CPU-2/3 | 一夜 >3 次 WARN；`plasmashell_down` FAIL |
| `check_cx_auto_config` | 新 | CPU-3 | `/etc/default/y700-cx-auto` 键合法 |
| `check_status_page` | 新 | M-6 | 本机 curl 字段齐全 |
| `check_night_plan` | 新 | TL-1 | timer enabled、计划行语法、done.log 无重复 |
| `check_local_checklist_timer` | 新 | TL-3 | timer enabled + ExecCondition |
| `check_touch_inhibit` | 新 | N6/M-3 | inhibited 不残留 |
| `check_psi_off` / `check_pcie_l1ss` | 新 | KCF-4 | cmdline/sysfs；只读探针 |
| `check_modem_units` | 新 | MOD-1 | remoteproc/mhi 状态 |
| `check_plasma_nm_patch` | 新 | CPU-6 | 补丁在位（若落地） |
| `check_yt_entry` | 新 | VID-2 | 入口可执行 |
| `check_cx_effect`（:849） | 改 | CPU-2 | 读 T0 计数器，不再自己切窗 |
| `check_cx_knobs`（:783） | 改 | M-2/CPU-4/SCN-1 | 排除 `y700-diag-*`/`y700-scn-rec*` |
| `check_cx_auto`（:800） | 改 | CPU-2 | 显示 `cx-auto.disabled` 与 `STUCK_ACTION` |
| `check_flightrec`（:872） | 改 | §3.5 | 最近基线 >8 天 WARN |

新增 18 个函数（`check_psi_off`/`check_pcie_l1ss` 算两个）、改动 4 个。每个新函数都进 `tools/y700-checklist-selftest.py`（现 123 项）。

---

## §3 测量规程

### 3.1 前置条件（每夜开跑前由单元自检；任一不满足 → 不跑并写 `MARK ABORT:<条>`）

1. 电池放电中（插电系统域进不去，PROTOCOL.md:92；cx-auto 只在放电 arm）。
2. dpms Off 且 ≥30 min 无 NVT/power/volume 中断（`cx-when-idle.sh --idle 30`）。
3. **触发通道只有两种**：持久 `y700-cx-night.timer` + `/etc/y700/night-plan`（TL-1）；或白天亮屏 ≤10 min 的 ssh 里 `systemd-run … --on-calendar`（TL-2）。状态页永远只读，控制面板与 cx-exp 无关——**不存在**不用 ssh 的临时触发通道。ssh 退出 ≥30 min 后窗口才能开始（`user@0` 停稳，22/s IPI 消失）。
4. 无 ssh 会话、`/run/user/0` 不存在（M-6 字段；M-6 之前靠 fr 行无 `u0=` 列的旧格式，fr-slice 两种都认）。**Win11 每日体检 ssh 任务当夜改期**（TL-3 上线前手动，上线后自动）。
5. Wi‑Fi+Tailscale 在线（`tailscale status --json` BackendState=Running），蓝牙按场景行。
6. 没有 `y700-scn-rec*`/`y700-diag-*` 单元在跑（除非计划含 `DIAG:` 步）。
7. `y700-flightrec` 活着（体检 :872）；`download_mode=off` 且开机 ≥4 min（PROTOCOL.md:86）。
8. 旋钮在期望初值（`check_cx_knobs`）。
9. **`/var/lib/y700/cx-auto.disabled` 存在 → ABORT**（cx-auto 上次开机以 armed 结束时自禁用，说明出过事，先看日志）。
10. 起始电量 ≥40 %（熄屏夜）/ ≥60 %（亮屏夜）。

### 3.2 单元与命名

- 实验 `y700-cx-<name>`（被 cx-auto disarm 是期望，两臂由 cx-exp 自己持旋钮）；BENCHES 在 CPU-4 交付后不 disarm。
- 诊断 `y700-diag-<name>`；场景 `y700-scn-rec-<scene>-<ts>`。全部 `systemd-run --collect -p KillMode=mixed`。
- 旋钮脚本 `linux/power/knobs/<knob>.sh on|off|check`：切换后 60 s 内 Tailscale Running 且 dpms 仍 Off，否则回滚 + `MARK ABORT`；每个新旋钮白天亮屏先 15 min 试一次。
- 现有工具与用途：`tools/y700-offbench.sh`（熄屏状态 0–6：基线/USB rpm/BT 关/Tailscale down/rfkill/helperd 停/基线）、`y700-offmeasure.sh`（20 s 稳定 → wakeups 30 s → powersample 90 s）、`y700-powerbench.sh`（STATES A–J，I 熄屏、J 熄屏+冻结）、`y700-l1ssbench.sh`、`y700-idle-ab.sh`、`y700-power-ab.sh`、`y700-service-cost.sh`、`y700-hud-cost-ab.sh`、`y700-memlat-ab.sh`、`burst-ab.sh`、`y700-wakeups.py`（tracefs 靶子）、`y700-whoawake.py`、`y700-powerwhy.py`、`y700-powersample.py`；`linux/power/cx-collapse/{cx-exp,cx-ladder,cx-when-idle,exp-collect,cx-audit,cx-wakeprobe}.sh`；`linux/video/{chrome-video-power-ab,video-mpv-ab,wifi-rx-cost,wiliwili-power}.sh`。

### 3.3 噪声与显著性

- 熄屏：电池电流 5–8 s 更新；**±0.03 W 是 A/B 可分辨下限**（offbench 用 75–120 s 窗均值比，10-15 四窗 0.43/0.41/0.40/0.43，README:1444）；阶梯窗口间漂移 ±20 mW（10-18 305/274/285/267，`status:73`）。
- kiosk（O）：相邻同条件窗 ±0.03–0.1 W，一轮内 ±0.2 W，不定期 +1 W 平台（Chrome 重绘/GC）→ 只用同轮镜像顺序 A W W A 的差值，不用绝对值。
- 真会话（S）：±0.2–0.3 W；只比 S 内部差、O 内部差，**S/O 绝不互比**。
- 判定：每臂 ≥6 窗（熄屏 15 min/窗取中位数），符号检验 6/6 同号双侧 p=0.031，裁决口径「双侧 p ≤0.05」；≥0.1 W 的差 3 窗可初判，仍要 6 窗定案。
- <0.03 W 候选：不出功耗裁决；代理指标差 ≥30 % 记「代理有效」；零风险项捆成一臂（N5）。
- 作废：任一窗内出现 ssh、充电、亮屏、`cx_stuck`、单元重启 → 该窗作废不补；一夜最多作废 2 窗，否则整夜作废。

### 3.4 剔除规则 R1–R15

R1 窗首 60 s 丢弃（切换瞬态）· R2 `bat=` 缺失行丢弃 · R3 电流跨 0 的行丢弃 · R4 温度 >45 °C 窗作废 · R5 窗内 dpms 变化作废 · R6 窗内 NVT 中断 ≥3 作废 · R7 Tailscale 掉线窗作废 · R8 `MARK ABORT` 之后全部作废 · R9 同夜重复臂取中位数 · R10 作废规则见 3.3 · R11 两种 fr 行格式混杂按时间戳对齐 · R12 `DIAG:` 步窗口不计功耗只出诊断文件 · R13 tailscaled/powerdevil 重启 ±60 s 剔除 · R14 `context lost`/`GL_GUILTY_CONTEXT_RESET` → ABORT · R15 每窗记 `NVT-ts-spi` 差分，>0 的亮屏窗标「可能误触」。

### 3.5 基线与周期义务（全部机器化）

| 义务 | 机制 | 通知 |
|---|---|---|
| 每周整夜 E3a soak（补 1.1-5） | `y700-cx-soak.timer`（周日 00:30，计划行 `E3a:480`） | fr-slice 周报 |
| 桌面静置 bl99、静态网页 bl99、游戏、CarPlay、osk | kiosk `--desktop-idle 5min`（N6）、scn-rec（P4） | — |
| 基线新鲜度 | `check_flightrec` 最近基线 >8 天 WARN | 体检 |
| 裁决完整性 | Win11 `tools/ab-index-check.py`：有切片无裁决 → 列出 | 本地 |
| 状态页巡检 | Win11 每日 curl | `cx_stuck` / `cx_disabled` / 计划有行无单元 |
| 体检 | `y700-checklist-local.timer`（TL-3） | FAIL |

### 3.6 内核门槛（KCF-4）

只在 P3 重启窗口；作者在场或我同网可物理重启；trial 后 10 min 网络看门狗；两次非 keep 重启自动回 y12（README:505）。过门槛：`check_pcie_l1ss`、`check_psi_off` 通过；Tailscale 60 s 内 Running；次夜 E3a 地板不劣于 y12（±0.03 W）；三夜 `e3a_fail_rate_3d` 不高于 y12 期。

---

## §4 执行顺序与分期

顺序：**P0 → P1 → N1 → P1.5 → N2′ → N2 → N3 → N4 → N5 → N6 → P3 → P4 → P5 → P6**。
并行/串行：P0 与一切并行（Win11）；P1 单次窗口；P1.5 的各项可同一窗口内串行装；N1–N6 每夜一题、串行；**P3/P5 的重启只在当晚无 P2 单元、前夜裁决已出的日子**；P4 场景记录与 P2/P3 并行（事件驱动，不占夜）；P6 不排期。

### P0（Win11，不碰平板）
- M-1 `fr-slice.py`、`tools/ab-index-check.py`、M-7 巡检合并。
- 审计 C23（`tools/upstream-check.py:404,619,759`）修复 + `tools/test-upstream-check.py` 回归（§7-21）。
- §6.2 的文档修订（README/PROTOCOL/头注）。
- 验收：fr-slice 复现 README:1548/:1565 的数字（±5 mW）；selftest 全绿。

### P1（现场只读 + 一次白天亮屏 ≤10 min ssh 窗口，§7-1）
- 跑 `live-ro3.sh`（CPU-1/WK-8/PCIE-1/CPU-6 定位/SEN-1/DSP-8），产物入 `runs/diag/`。
- 只复制不执行：`always-on-check.sh`、`live-ro3.sh`、`y700-diag-pack.sh` → `/usr/local/libexec/`。
- M-6 的 sh 字段（`cx_disabled`/`armed_since`）；验 `ssh_sessions` 可读性。
- 读 `tb323fu-ctl kernel` 状态（y13 是否试装过，当前 slot）。
- 验收：10-19 快照的 107/s、101/s、1.2 % 三个数有归因，或明确「待 N2′」。

### N1（空 A/B 夜）
- 计划行 `noop:15 ×12`，cx-auto armed，不切旋钮；验证 3.3 的噪声假设与 fr-slice 流程。验收：12 窗中位数极差 ≤40 mW，否则先修流程。

### P1.5（重编 + 重启服务，不重启系统，§7-2）
- CPU-2 T0、CHG-1 B2、CPU-4 `--keep-cx`（cx-exp + cx-auto）、M-2、M-4、M-5、M-6 其余字段、TL-1、TL-3、WK-1 体检、GPU-1/GPU-2 体检、§2.19 首批新函数 + selftest。
- 安装约定：`cp <bin> <bin>.prev`，附 `rollback.sh`；每项验证过即 commit（英文消息），不推。
- 验收：体检全绿；状态页新字段齐；cx-auto 重启后 30 s 内重新 armed。

### N2′（纯观察夜）
- cx-auto armed，T0 只判不动（`STUCK_ACTION=none`）；计划 `DIAG:5 noop:15 ×8`。目的：拿到 `cx_stuck` 首批计数与 `stuck-<ts>.txt`，看 PowerDevil 亮度行为（DSP-5）。验收：有/无卡住都出一份归因。

### N2（K= 夜，方案 a，§7-14）
- `E3a+K=rtcsync:15 / E3a+K=noop:15` ×3 镜像；只看代理（WK-4）。验收：rtc@6100 唤醒计数降 ≥30 % 记「代理有效」。

### N3（T1/T2 夜，§7-7/8/9）
- T0 判卡后执行 T1（或 T2）；比较卡前/后 apps-pc 驻留与功耗。验收：动作后 5 min 内 `pd=sys` ≥1/s 且功耗回到 ≤0.30 W。

### N4（Wi‑Fi 夜，§7-15）
- WIFI-1 rfkill 对照（补 1.1-4）、WIFI-2 旋钮（白天已试）。验收：rfkill 差值给出 Wi‑Fi 残余的 E3a 口径数。

### N5（捆臂夜）
- CPU-8/9/10 + SEN-1 + WK-1 + WK-7 等 <0.03 W 零风险项捆成一臂 vs noop；只出代理裁决。

### N6（亮屏 kiosk 夜，§7-5）
- 2.18 保护全开；≤2 h；补 1.2 行 1/3/8。

### P3（重启窗口，§7-3/4）
- KCF-4 y13 trial + 看门狗；CPU-6 补丁（若 §7-10 选本地）；DSP-4 顺手项、UP-3；WK-6 drop-in；§7-19/20/22/23 落地。重启后先跑附录 A。验收：附录 A 全过 + 当晚 N1 式对照不劣于前。

### P4（场景记录，与 P2/P3 并行）
- SCN-1 上线；VID-2 入口（§7-25）；WIFI-4（§7-27）；BT-1、DSP-6、UP-9；USB-1 的 OTG 识别顺带验证。验收：§1 待测行各至少 3 窗。

### P5（亮屏与游戏）
- GPU-4 kiosk 上限（无人值守 ≥422 MHz）；N6 第二夜。

### P6（长尾，出口判据明确才立项）

| 项 | 出口判据 |
|---|---|
| PCIE-2 | `runtime_status` 60 s 内 suspended 且 Wi‑Fi 不掉 |
| DSP-3 | 30 Hz 相对 60 Hz ≥0.03 W |
| CX-B（UFS PHY / ICE runtime PM，y14） | 挂起进入且无 I/O 错误 |
| UP-1 refresh-auto | 24 h CPU ≥1 % 才排移植 |
| GPU-6/7、WK-7、MOD-1、SEN-1、UP-7/8、SHIM-2、KCF-5/7、CPU-8–12、A7 | 代理 ≥30 % 或 ≥0.03 W |

---

## §5 有意不做的事及原因

| 项 | 原因 | 出处 |
|---|---|---|
| s2idle / 休眠（KCF-6） | 作者已定不休眠（10-15 晚原话，README:1446）；10-13 PCIe L2 超时（README:1135）；唤醒后 ath12k 整卡重初始化、约 35 s 才回 6G（README:240） | §6 c18 |
| E3a 升到 E3b/E3c 日常 | 作者已定维持不升档（10-18）；cxsd 在 E3b/E3c 下仍为 0，收益未证 | runs 10-18 |
| wiliwili 低画质（VID-1） | 作者已定不开；补丁仅保留 | README:1326 |
| 熄屏杀 Claude 的定时器 | 作者已删；用 BFS 开关治 | README:1616 |
| 默认 60 Hz（DSP-2） | 作者两次要求默认 120（README:392、:709）；产品决策，磁贴可切 | §6 X33 |
| 充电夜 A/B（CHG-2） | 整机 W 含充电损耗不可测；系统域进不去 | PROTOCOL.md:92 |
| 常驻冻结桌面应用 | 只省 0.01 W、Telegram 收不到 | README:1473、X9 |
| kmsg-watch 移植 Rust | `poll(-1)` 零唤醒 | `linux/net/y700-kmsg-watch` |
| scn-rec 常驻轮询 | 用 `.path`/inotify 事件驱动 | SCN-1 |
| 替换厂商二进制（helperd/温控） | 只做 drop-in + /usr/local 自编版；成品系统走官方渠道 | 项目约定 |
| `--on-active=15min` 盲跑诊断 | 会在作者用机时跑；改 `DIAG:` 步/ExecCondition | M-4/M-5 |
| 读 `/sys/kernel/debug/pcie@*`、regmap、clk_summary（测量窗内） | 10-15 03:41 挂死总线；clk_summary 会 runtime-resume 时钟控制器 | `always-on-check.sh:11-12` |
| 无人值守 <422 MHz GPU 上限 | Chrome 三次 GPU 挂死后放弃硬件加速 | README:1759 |
| M-3 `--blink` 与 T1 同夜 | 互相污染 | §2.1/2.2 |
| 改 AP 的 DTIM/PS | 需作者（§7-27） | WIFI-4 |
| 睡眠锁 A9 | suspend 已 mask，失效议题 | 审计 A9 |
| 手算 E3a 失败率 | 由 T0 计数器出 `e3a_fail_rate_3d` | M-6 |
| 报上游 / PR 作为默认动作 | 对外发布每次单独点头 | §7-24 |
| 本稿期间任何平板写动作 | 设计阶段只读 | TASK 约束 |

---

## §6 已有研究结论核对

### 6.0 方法与结果

核对对象：`linux/power/cx-collapse/RESEARCH.md`、`PROTOCOL.md`、`linux/power/WAKEUPS.md`、`PCIE-L1SS.md`、`ALWAYS-ON.md`、README「熄屏唤醒治理」「底噪研究·执行记录」「续航速查」「续航第三轮」「视频播放功耗」、`linux/video/VIDEO-POWER-MEMO.md`、`runs/status-20261019.md`。从 26 路读仓汇总出 52 条疑似矛盾，每条由独立核实者读双方原文裁决。

结果：**confirmed-contradiction 1（X11）、stale-superseded 28、not-a-contradiction 23。** 另对本稿前一版的 36 条数字断言做了反查，14 条改正（c03/c10/c11/c12/c14/c17/c18/c19/c23/c24/c27/c28/c30/c33），已全部并入 §0–§5。

**唯一的真矛盾 X11**：`linux/power/90-y700-usb-rpm.rules` 头注写「Verified: … an OTG device still detected with the controller suspended」，README:1445 同一 commit（092bca5，10-15 22:41）写「OTG 设备（U 盘/键盘）的识别没有验证」。处置：以 README 为准，改规则头注为「未验证」；P4 顺带验证（USB-1）。

### 6.1 52 条裁决一览（X1–X52）

说明：「说法」是被质疑的旧表述，「文档怎么改」是核实者给的修法（截断，完整文字在工作笔记里，仓库外）。stale-superseded 的条目都应在原位加「过时，见 …」。
| # | 裁决 | 说法 | 在哪 | 与之冲突 | 文档怎么改（截断） |
|---|---|---|---|---|---|
| X1 | stale-superseded | y8 含 1040 memlat | README.md L640 | L656/L682 memlat 实为 y9（1042）；PLAN.md 写 1040 文件名 | 在 README L640–641 的"一句话"后加括注「（原计划；实际 y8 未含 memlat，补丁改名 1042 随 y9 编入，见下"1040 为什么没进 y8"与"最终状态"）」，L645 与 PLAN.md L5/L29 的文件名改为 `1042-memlat-android-tuning.patch`（或在 PLAN.md… |
| X2 | stale-superseded | 1042 memlat +0.39 W / −24% | README.md L664–672 | L678–679 熄屏无差；burst-ab y9 +0.11 vs y8 +0.10 | 在 L670、L672 两格的 +0.39 W 与 14.6 nJ（−24%）上加删除线或「已作废：亮屏干扰，见 22:18 熄屏对照 +0.11 vs +0.10」标注，并在 L664 表头注明「亮屏初测，功耗增量行已被下方 burst-ab 熄屏结果取代，仅 DDR 地板占比与追逐延迟两行仍有效」。 |
| X3 | not-a-contradiction | 息屏 658/659/621 mW | README.md L393 | 本机实测 0.24–0.42 W | 把 L393 括号改成“上游作者在 ROW .104 机器上的数（补丁 0118，10-03），本机 088 固件熄屏实测见‘续航速查’：0.33–0.42 W，开 CX 旋钮后约 0.27–0.31 W”，并把句末“不要打开它”改为“已过时：10-16 E1 本机零复位后，10-17 起由 y700-cx-auto 在熄屏+电池时自动打… |
| X4 | stale-superseded | 亮屏 2.6 W | README.md L1393 | L1464 1.13 W / y9 0.93 W | 把 L1393 改为"（凌晨误测 2.6 W 已作废：窗口没隐藏成、面板钉 120 Hz，见下文「第二次实测」关键修正——真值 1.13 W（y7）/ 0.93 W（y9），比安卓只多约 0.45 W）"，并在其后"已知的平台缺口"列表前加一句"下列缺口仍成立，但不再是 1.5–1.9 W 差距的解释"。 |
| X5 | stale-superseded | 底噪 0.6–0.7 W | README.md L1423 | 0.42（10-15）/0.33（10-17）/0.24（10-19） | 在 README.md L1423 的「约 0.6–0.7 W」后加括注「（10-15 中午、Wi‑Fi 省电修复前的估值，已过时：同日修复后 0.42 W，10-17 y12 旋钮全关 0.33 W，10-19 cx-auto/E3a 0.24 W，以「续航速查」表和 runs/status-20261019.md 为准）」，并把 L1… |
| X6 | stale-superseded | USB 没挂起 | README.md L1412 | L1445 5 s 挂起；快照 rt=suspended | 把 README.md:1429 表格行括注改为"0.52 W（当时 3 s 就读状态误判为仍 active，实际 5 s 后已挂起，见下 22:45 条；差值在噪声里）"。 |
| X7 | stale-superseded | TEO / RCU_LAZY 未做 | README.md L1399、L1451 | L1444 已做；快照 governor=teo | L1399 行尾加"（10-15 晚 y8 起已编进 TEO + RCU_LAZY，见"内核 y8"与下文零风险 A/B）"，L1451 改为只剩"DPU 带宽投票跟随实际刷新率（0110）"，其余四项标注"已在 y8/y9 落地"。 |
| X8 | stale-superseded | 0.79 / 0.59 W | README.md L1449/1457/1474 | 0.33 / 0.24 W | 在 L1449 把"不休眠是 0.79 W"改成"不休眠当时 0.79 W（10-15 凌晨），现 y12 旋钮全关 0.33 W、cx-auto 开 E3a 约 0.24–0.31 W"，在 L1470 表头加"（10-15 13:21，当日中途值）"，并在 L1474 开头加"【10-15 当时结论，已过时：同日 Wi‑Fi 省电修复… |
| X9 | not-a-contradiction | 冻结 app 不做 | README.md L1473 | 仓库存在 y700-screen-off-freeze 草案 | 在 README L1473 句末补一句交叉引用：「（10-16 为唤醒预算另写了可选的 `linux/power/y700-screen-off-freeze`，不冻 Telegram、不为省电、默认不装，见「熄屏唤醒治理」）」。 |
| X10 | stale-superseded | dumpmode 没做 | README.md L1450 | y700-dumpmode-off.timer 已装（快照 12:58 触发） | 把 L1450 改为「~~`download_mode=full` 换成死机直接重启~~ → 已做（同日 15:10 作者点头）：`y700-dumpmode-off.timer` 开机 3 min 后写 off，cmdline 仍是 full、需要转储时临时 `echo full`，见"内核 y8"配套用户态与体检项」，并在 L1449… |
| X11 | confirmed-contradiction | OTG 已验证 | linux/power/90-y700-usb-rpm.rules 头注 | README.md L1445 未验证 | 把 90-y700-usb-rpm.rules 头注第 4–5 行改为 "Verified: charger plug/unplug (PD 9 V) with the controller suspended; OTG host device (USB stick / keyboard) enumeration NOT verified… |
| X12 | stale-superseded | 看门狗每分钟 timer | README.md L1136/1152 | 10-16 起 kmsg-watch 触发，timer 关（快照无 y700 timer） | 在 README L1136 与 L1154 的"每分钟"后各加一句过时标注：「（10-13 的部署；10-16 起 timer 已 disable --now、文件保留，改由 y700-kmsg-watch 监听 /dev/kmsg 事件触发同一 oneshot .service，见「熄屏唤醒治理」第二批与 linux/net/KMSG… |
| X13 | stale-superseded | TS_PORTLIST 待点头 | README.md:60 | README.md:1694 已装；快照 drop-in 在 | 把 README.md:60 状态列改为："PowerDevil / tailscaled 两个 drop-in **已装（2026-10-16 04:03，`install-wakeups.sh --powerdevil/--tailscale`，体检已纳入）**；冻结服务 `y700-screen-off-freeze` 默认不装（只… |
| X14 | not-a-contradiction | helperd 7+3/s | README.md L1685 | 实测 2.6/s（service-cost）vs 9.9/s | L1685 把「tb323fu-helperd 7+3/s」改为「tb323fu-helperd 7+3/s（whoawake 的上下文切换口径；10-16 21:18 service-cost 同口径测得 9.9/s；y700-wakeups 报的 2.6/s 只是其中定时器自醒的部分，不可并排比）」，L1694 的「它现在只占 2.6… |
| X15 | not-a-contradiction | Claude 22/s | README | 9.6/s；viz 线程 120/s | 在 README:1685「(4) Claude 桌面版 22/s」和 WAKEUPS.md §2.3 标题处加一句括注："22/s 为 10-15 whoawake 整程序唤醒（插电）；10-16 y700-wakeups 的 9.6/s 只数自身定时器超时；10-18 的 120/s 是重启后 VizCompositorThread… |
| X16 | stale-superseded | 基线 285/s 中断 | README WAKEUPS | 实测 467 idle 退出/s、IRQ 552/s（10-16）；快照 arch_timer 25… | 在 README:1683/1687 和 WAKEUPS.md §0.2/§0.5/§3 表把"现状 285/s"改为"285 = 10-15 whoawake 的 idle 进入/s（中断另为 300–400/s），10-16 y700-wakeups 首测基线为 idle 退出 467/s、IRQ 552/s（装前，装后数据被 ssh… |
| X17 | not-a-contradiction | drop-in 后 0.58 W | README 10-16 | 装前 0.45；非 A/B，ssh 污染 | 在 README.md:1695 的"0.58 W"后就地加括注"（作废：ssh 每 10 s 轮询抬高，见下 10:12）"，并把"真正的 A/B 等系统安静后再测"改为"至今未补测"，免得读者只扫数字时把 0.58 W 当成装后结果。 |
| X18 | stale-superseded | apr 17/s 音频不挂起 | README.md L1695 | L1700 撞 5 s 窗（偶发） | 把 README L1696「新进名单」里的"音频图熄屏不挂起（apr 17/s + pipewire 7.5/s + LPASS 时钟常开，与 ALWAYS-ON §5a 同源）"改成"~~音频图熄屏不挂起~~（已推翻，见下"第二批"/SUSPEND.md：30 s 样本折合约 5 s 打开窗口，与 ALWAYS-ON §5a 无关；待… |
| X19 | stale-superseded | rtc 闹钟唤醒 | ALWAYS-ON | 实为失败的 rtc_set_time（RTC_SYSTOHC+rtcsync）；快照 rtc 73… | 把 X19 的出处改成 WAKEUPS.md:25 与 README.md:1686，并给这两处补一句「10-16 补：更可能是失败的 rtc_set_time()，见 ALWAYS-ON.md §5b，待 --rtc 90 定案」；同时把工作笔记（仓库外）里的 `journalctl -k \| grep… |
| X20 | stale-superseded | CDSP 持 XO | ALWAYS-ON | 误读；快照 cdsp 睡 ~100% | 把 RESEARCH.md:10 的"CDSP 持着 XO"加删除线并注"10-16 更正：不持，见 ALWAYS-ON §1"，PROTOCOL.md:150 的"bi_tcxo 被 cdsp 占着"改为"bi_tcxo consumer 列显示 cdsp，实为两个子时钟使能，CDSP 不持（ALWAYS-ON §1）"；审计条目 X2… |
| X21 | not-a-contradiction | E3a 收益 0.1 / 0.05 / 0.035 / ±20 mW | README、cx-collapse、status | 四口径 | 把 README:1565 和 status:73 的"差别在 ±20 mW 以内"改成"E3b/E3c 相对 E3a 的差在 ±20 mW 以内（升档无增量）；E3a 相对旋钮全关仍省 26–64 mW，与 10-17 的约 0.05 W 一致"，并在 README:1526 的"省约 0.1 W"后加一句"E3a 单独的 A/B 见… |
| X22 | not-a-contradiction | E3a 驻留 67% | cx-collapse | 40% | 在 PROTOCOL.md 10-16 第二轮条目（或 §5 模型段）加一句"apps-pc 驻留随内核与唤醒源状态逐次变化：10-16 y10 67%、10-17 夜 y12 40%（README 10-17 夜，exp-collect 算法）、10-18 白天 y12 17%（仅 7 分钟有效）——67% 是单次最好值不是常态"，并在… |
| X23 | stale-superseded | PROTOCOL 头「E3 待 y10 / 不改默认值」 | linux/power/cx-collapse/PROTOCOL.md 头 | cx-auto 日常开（10-17 起） | 把头部状态改为「E1/E3a 10-16 通过，E3b/E3c 10-18 已跑但 CX 未真睡；E3a 自 10-17 起由 y700-cx-auto 在熄屏+电池时日常开启，作者 10-18 定不升档」，并把 §7「不改默认值」改写为「不改内核默认值/cmdline/tmpfiles；运行时旋钮由 cx-auto 按作者 10-17… |
| X24 | not-a-contradiction | 阶梯门槛 E3b/c ≥1 h | PROTOCOL | 10-18 只跑 15 min | 在 PROTOCOL §3「通过/不通过」加一句：「≥1 h 是晋级 E4/E5/常驻的门槛，白天 ≤15 min 的短测只做探路、不计入门槛，累计只认 ≥30 min 的完整轮次」，免得再把门槛读成最短时长。 |
| X25 | not-a-contradiction | E3b「最可能出事」 | PROTOCOL | 从未被证伪（cxsd 从未进）；10-19 快照 apps-pc 也只进 4 次 | 在 PROTOCOL.md 第 119 行「先停」后补一句：「（10-18 两轮 E3b 零复位但 cxsd 均为 +0，此风险尚未被实际检验，见 §9 10-18 条；7.4 起 gcc 挂到 CX 后风险形态要重评，见 RESEARCH §1.3）」；status-20261019.md 第 102 行「零复位」后加「（cxsd 始终… |
| X26 | stale-superseded | 风暴最多 0.3 W | README.md L916 | 实测 1.1–1.3 W（10-18） | 把 L916 末句改为"~~作者那次会话里的 GPU 加频风暴最多再多约 0.3 W~~（15:50 的预算推算，已被结论 6/7 推翻：真会话实测风暴占 1.1–1.3 W，见结论 7）"。 |
| X27 | stale-superseded | shim 不上 | README.md L929 | 10-18 22:40 已装（快照 ld.so.preload） | 把 L929 结尾的"**shim 和内核开关都先不上**；下次作者看 YouTube 时再做一次只读诊断"改成"~~shim 和内核开关都先不上~~ → 10-18 22:00 在真会话里抓到风暴，垫片已于 22:40 经 /etc/ld.so.preload 持久安装（见结论 7）；受控 kiosk 里仍未复现风暴这一点不变"。 |
| X28 | stale-superseded | VIDEO-POWER-MEMO O7「不建议垫片」、2.17 W 旧基线、行号 | linux/video/VIDEO-POWER-MEMO.md | 垫片已装；README 行号全部失效 | 在 VIDEO-POWER-MEMO.md 首行注释后加一段过时标记：「10-18 起：Chrome syncobj 等待加频风暴已证实（README 视频播放功耗 结论 6/7），`y700-no-waitboost.so` 已经 /etc/ld.so.preload 全局装上、只对进程名 chrome 生效、不碰 KWin——§0"加… |
| X29 | not-a-contradiction | 726 上限叠加不测 | README.md L897 | Chrome 28% 时间在 1200 MHz | README.md:897 末尾补一句限定："此结论仅限 wiliwili/mpv 工况；10-18 Chrome YouTube 下门槛 80 仍有 28 % 的秒在 1200（均频 600-680 MHz，见结论 2/4），726 上限在该场景值得补做 balanced/power-saver ABAB（备忘未解决问题 4 仍开）"。 |
| X30 | not-a-contradiction | y12 门槛 80 ≈ 0 | README.md L902 | 0.15 W（tune2） | README.md:902 句尾补一句"（y12 那格 50 没跳频、基线失真，见"内核 y12"一节：不拿来比，不等于 80 在 y12 无收益；y12 上 80 vs 50 未重测）"，并在 README.md:29 的"实测省约 0.15 W"后加"（y10 真实 wiliwili 实测；y12 未重测）"。 |
| X31 | not-a-contradiction | Y0 =「放回」 | README.md L1000 | Y0 实为施加上限 | 把 README L1000 的"守护在下一个状态文件事件或 10 s 定时器时把上限放回来"改成"守护在下一个状态文件事件或 10 s 定时器时重新压上 500 MHz 上限（兜底风暴）"，全文把"放回"只用于"解除限制、还给 helper"这一个意思。 |
| X32 | not-a-contradiction | 默认 FLOOR 282 | gpu-floor 源码默认 | 配置 342（快照） | README 守护条目（README.md:971）和 main.rs:33 注释各加一句："生效值以 /etc/default/y700-gpu-floor 的 FLOOR_MHZ=342 为准；代码里的 282 只是配置缺失/越界时的兜底"（或直接把 main.rs 兜底改成 342 消除歧义）。 |
| X33 | not-a-contradiction | 留 120 Hz 不费电 | README.md:709 | :740 装时把作者 60 换成 120；固定 120 vs 30 +0.5 W | 在 README.md:712 把"这类片子不省电，但绝不比原来差"改成"这类片子不省电（比 60 基准约多 1 W，见 :392），但绝不比基准 120 差；想省电可在控制中心磁贴把基准切成 60（:716）"，并在 :711 补一句"静止画面的 +0.5 W（:1462）是固定 120、空闲降频关掉时的数，基准 120 下空闲降频仍在… |
| X34 | stale-superseded | 可抠项不含 flightrec | README.md L706 | flightrec 旧 Python 0.56% | 在 L707 结论句末尾（或 L694 标题下）加一句过时标注："本表是 Python 版飞行记录器 1 Hz 时的值；2026-10-17 起已换 Rust 并平时降到每 10 s 一行，实测约 0.02–0.03 %，见下文「飞行记录器」节"，并把"能抠的只有…"改为"除 flightrec（次日已抠）外，能抠的只有…"。 |
| X35 | stale-superseded | 风暴「压住一部分」 | README.md L731 | 结论 7：垫片已压住 −1.3 W | 把 README.md L734 末句改为「那个 22:05 先用 GPU 上限压住一部分（结论 6），22:10 起已查明根因并用 y700-no-waitboost 垫片治本（同视频 5.0 → 3.6 W，已装进 /etc/ld.so.preload，见结论 7）」。 |
| X36 | stale-superseded | trans_stat 数据 | README.md L833 | trans_stat 不可信 | 无需改动——L835 已原地标注作废并指向后文；若想更醒目，可把 L835 的数字串包在 ~~删除线~~ 里，并把索引中的行号 L833 更正为 L835。 |
| X37 | not-a-contradiction | CarPlay gst 25% | carplay README（真机 10-17） | 40%（测试片） | 在 carplay README 第 154 行表格标题处加一句「这是 60 fps 噪声片压测上限；真机 10-17 23:49 约 25%，但当时主屏只有 30 帧，10-18 改成 60 帧后未重测」，并把主 README 1116 行的「约 25% 单核」补成「约 25% 单核（真机、当时 30 帧；60 fps 测试片压测约 4… |
| X38 | stale-superseded | 控制中心 3 s / HUD 5 s / 浮层磁贴 systemctl / 休眠… | control-center/HUD README | 实为 5 s / 6 s / y700-hud-toggle / sleep masked / Ru… | 在 README:1037「每 3 秒刷新」、:1054「改成显式 systemctl」、:1352–1354「每 5 s」、:277「Python…LD_PRELOAD」各加一句括注"（已改：现为 5 s / y700-hud-toggle <档位> / 6 s / Rust 无 preload，见 L1044/L283/L1363/L… |
| X39 | not-a-contradiction | 旧 Plasma 小组件已删 | README | 仓库仍保留 | 把 1049 行 ⑥ 改写成"旧的 Plasma 小组件包已从平板 `~/.local/share/plasma/plasmoids/` 卸掉；源码仍留在仓库 `linux/controlpanel/fyi.y700.controlpanel/` 作历史备份，不再维护"，同时给 1053 行 ④ 加"（已于第七轮删除，此条过时）"并在仓库… |
| X40 | stale-superseded | kernel inventory = y7 快照；目录表 y6/y7；「当前有效… | linux/kernel-y8/ inventory、README 内核段 | 现役 y12、cx-auto 开 | 把「当前有效状态」1839/1851 两条改为 good = y12（10-16 19:3x keep，= y10 + 1046–1048，编内核模板 kbuild-y12.sh），1847 改为「内核默认值仍 N，但 10-17 起 y700-cx-auto 在熄屏+电池时日常打开（E3a），10-18 定不升档」；目录表补一行 `li… |
| X41 | stale-superseded | kbuild-y10 CMDLINE allow_system_off 前后版本… | linux/kernel-y8/ | y12 已编并跑 | 在 Y10-NOTES.md:6 与 :73 的「没编译过」处加一句"（已过时：10-16 03:13 编译、03:27 keep，60/60 PASS；y12 继承本栈，见 README「内核 y10/y12」）"，并把 README.md:1518 的「尚未在平板上编译/启动」改为"已于 10-16 编译并 keep"、README.… |
| X42 | not-a-contradiction | 1045 头 L1.2 计数条件不明；x2/x1 链路宽度；y11 归属 | PCIE-L1SS、1045 头 |  | 1045 头第 22 行把「which today it almost never does」改成「which the pre-1041 (firmware CAM) count says it almost never did」；PCIE-L1SS.md:188 把「x2 链路两端」改成「x2 训练/实际 x1 运行，按两 lane 估… |
| X43 | stale-superseded | KEYHOLD §10 待合并、y10 版本号、0.5–1.3 vs 4–7 m… | KEYHOLD.md |  | KEYHOLD.md §10 标题改为"README 已合并段落（提交 1814212，2026-10-16，位于 README「熄屏唤醒治理」第二批）"，并在 §1/§9 的"y10"旁加一句"现役 y12 的 config 与 y10 相同、1046–1048 不碰 evdev/input/gpio-keys，结论不变"；mW 包络表… |
| X44 | stale-superseded | flightrec 每秒 fdatasync；cx-auto「即刻关充电器」；d… | flightrec README、cx-auto 头注、deploy.sh | 实为 10 s/6 行；60 s LINGER；BENCHES 不一致 | 把 README.md:1483、PROTOCOL.md:13、ALWAYS-ON.md:130、always-on-check.sh:82 的"每秒 fdatasync"改成"实验时每 1 s 一行/每 5 行落盘，平时每 10 s 一行/每 6 行落盘（10-17 起；旧 Python 版曾每秒写、每 5 s 落盘）"，并在 cx-a… |
| X45 | stale-superseded | 崩溃取证未实跑；体检「只读」；selftest S13–S17 vs S19；L… | README.md L1823 等 | 已实跑；selftest 写 kmsg；已加项 | README.md:1829 把"平板上尚未实跑"改为"10-16 12:4x 起随体检装上平板、每日实跑（10-19 rc=0、34 项 OK），真实死机分支仍只有合成数据覆盖"；README.md:1800"只读"后加"装了 y700-kmsg-watch 后会往 /dev/kmsg 写一行自检并各 start 两个看门狗 onesh… |
| X46 | not-a-contradiction | autobright 熄屏不动 | linux/display/y700-autobright README | 代码 ReleaseLight + 1 Hz tick 照跑 | 把 README:1733 改成"熄屏时亮度不动（进程仍每秒查一次 DPMS，熄屏即释放光感、亮屏再申请并立刻按当前光照调一次；见续航第三轮 §3 与常驻服务开销表）"，让 §自动亮度 一节自洽。 |
| X47 | stale-superseded | SUSPEND「渐入渐出」；61-raw-virtual 已装；wait-tun… | 音频文档 | fade-flag 0；POPS 称提案；实为 kded6 | 在 SUSPEND.md:87/:165/:166 各加括注"（10-16 下午更正：平板 fade-flag=0、DT 无此键，渐入渐出不生效，见 POPS.md §1.2-1）"，POPS.md §5(b) :254 加"（已于 10-16 16:2x 作为 61-y700-speaker-raw-virtual.conf 装上，10… |
| X48 | not-a-contradiction | status 后半夜 0.30–0.35；满电 4.5–6 天；E3a 305… | runs/status-20261019.md | 充电器插着作废；3.7 天另一口径；差 38 mW 未解释 | status 第 73 行改为"E3a 305（7 分钟 441 行）与 cx-auto E3a 267（4.5 分钟仅 27 行）是同一档位的两个时间窗，38 mW 差就是窗口间噪声（±20 mW），别读成 cx-auto 更省"；并在 README「续航速查」熄屏一行加注"10-17 旋钮全关的数，cx-auto 日常 E3a 后为… |
| X49 | not-a-contradiction | upstream hardware-status：799 vs 762 容量、h… | upstream 文档副本 | 本机 8809 mAh、0.4.2、已测、不覆盖 s2idle、视频 PM QoS | 在 README 目录表给 `linux/tb323fu-linux/` 加一行："上游 0c7c0c4（2026-10-09）只读快照，hardware-status 自标 10-04、helper/README 仍写 0.3.0、OpenCL 以其 performance.md 为准；当前版本看巡检基线与 tools/upstream… |
| X50 | not-a-contradiction | DDR 熄屏停 ~600 MHz | README cx 段 | 快照 10-19 13:27 DDR cur 1555 MHz / 13:29 2092 MHz（m… | README.md:1564 把「DDR 一直停在约 600 MHz」改成「DDR 75 s 均值约 600 MHz（powersample 每秒读 cur_freq，地板 547 加零星拉高；瞬时值随 CPU 负载 1 s 内可到 1.5–2 GHz，ssh 内读数不作数）」，并在工作笔记（仓库外）的 X50 行… |
| X51 | not-a-contradiction | y700-guestos active | 体检输出 | 快照 running 列表无 | 在 README「Steam x86 Linux 原生游戏：FEX guest rootfs」第 1021 行补一句"该服务是 oneshot+RemainAfterExit，正常状态为 active (exited)，不会出现在 running 列表，看是否生效用 `findmnt /usr/share/guestos/fex-mesa… |
| X52 | not-a-contradiction | 每日 10:00 ssh 体检 | Win11 计划任务 | 规矩「测量期间别 ssh」 | 在 README L1832 与体检操作说明第 8 步加一句「ssh 前先 `curl http://100.64.0.10:8766/`，状态页报阶梯/实验单元在跑就跳过当天体检（不通知）；长期方案见 TL-3 改平板本地 timer、Win11 只取结果」，并在规矩「测量期间别 ssh」末尾注明每日体检的单次登录… |

### 6.2 文档修订映射（P0 做，按文件）

| 文件 | 位置 | 修订 |
|---|---|---|
| README.md | :1526 | 「0.1 W」注明是 apps-pc + 两个 drop-in 合计、受 ssh 轮询污染；E3a 单项 ≈0.05 W 见 :1548/:1565（X21） |
| README.md | :1000 | 「把上限放回来」改「垫片关（`Y0`）时守护重新施加上限」（X31，`gpu-floor/src/main.rs:93-95,237-239`） |
| README.md | :1402 附近 | 明示 `/etc/default/y700-gpu-dvfs`（80/10）与 `/etc/default/y700-gpu-floor`（342/500/3）是两份文件两个服务（X32、c27） |
| README.md | :392/:709/:716 | 60 Hz 是磁贴可选项、默认 120 是作者要求；不存在「否决 120→60」（X33、c33） |
| README.md | :1565 | 305 vs 267 为窗口噪声；两种续航口径并列（X48） |
| README.md | :1323 | 「本地 mpv 1080p60」改「1080p30 HEVC」；1080p60 无有效数据（c23） |
| README.md | :1445 与 `linux/power/90-y700-usb-rpm.rules` 头注 | OTG 识别「未验证」为准，规则头注改掉「Verified」（X11） |
| README.md | :640-641、:1393、:1399、:1412、:1423、:1449-1451、:1457、:1473-1474、:706、:734、:833-835、:916、:929 等 | 按 6.1 表 stale-superseded 行加「过时，见 …」 |
| README.md | :65 | 体检「每天定时任务经 ssh 跑」加注：测量夜改期 / TL-3 本地 timer 后改 curl |
| `linux/power/cx-collapse/PROTOCOL.md` | :3、:192 | 头部「E3 待 y10 上机」「不写进 tmpfiles/cmdline」已过时：cx-auto 10-17 起日常开 E3a（X23） |
| 同上 | :89、:90 | ssh 污染段加 M-6 字段说明；触摸守卫段加 R15；新增 MARK 三型与 `--keep-cx` 语义 |
| `linux/power/cx-auto/src/main.rs` | 头注 :1-29 | 加 T0/T1/T2、`STUCK_ACTION`、`--keep-cx`、B2 修复说明；没有 README.md，中文说明在根 README:1528-1534（c28） |
| `linux/power/ALWAYS-ON.md` | §5b | 加「WK-4 代理裁决」入口；X19：不是闹钟，是失败的 `rtc_set_time` |
| `linux/power/WAKEUPS.md` | §2.5 | memlat 轮询是 deferrable、不是唤醒源；1000→10000 只省 ≈9/s（c30、X2） |
| `linux/video/VIDEO-POWER-MEMO.md` | 头 | 标「10-16 写成，之后以 README 视频节为准；垫片已装；行号失效」（X28） |
| `linux/video/wifi-rx-cost.sh`、`video-mpv-ab.sh:63` | 头注 | 加 `K=wifi-rx:3` 包装说明；PowerDevil 亮度行为「存疑，N2′ 观察」 |
| `linux/display/refresh-auto/` | README:715 | 每秒查屏加「CPU 待测（UP-1）」；A5/A6 修订 |
| `runs/audit-20261019.md` | §9 | C3 改「P1.5 无条件做」；B2/B4/B11/A2 按 §7 决策回填 |
| `runs/status-20261019.md` | :61/:79 | 保留原话；加「游戏/CarPlay 待测 → SCN-1」 |
| `tools/y700-checklist.py` | — | §2.19 表 |
| 上游清单 | — | 无 UPSTREAMS 文件；位置待 §7-28 |

### 6.3 冲突时的裁决顺序

现场代码与运行状态 > 项目文档（README、`PROTOCOL.md`、头注）> 本稿 > 工作笔记。README 与 `main.rs` 冲突以代码为准；本稿与 6.1 表冲突以 6.1 为准。

---

## §7 需要作者拍板的点（编号清单）

默认建议 = 不回复时我按它准备，但**任何一条不点头就不执行**。「挡」= 该决定卡住哪一步。

**A. 窗口与授权**

| # | 决策 | 选项 | 默认建议 | 挡 |
|---|---|---|---|---|
| 1 | P1 现场 ssh 窗口：白天、亮屏、≤10 min 一次；只读 + 三个复制（`live-ro3.sh`、`always-on-check.sh`、`y700-diag-pack.sh` 到 `/usr/local/libexec/`）+ 状态页两个 sh 字段 | 允许 / 不允许 | 允许 | P1 |
| 2 | P1.5 不重启小版本：重编 `y700-cx-auto`（T0 判卡 + 自动取证、`--keep-cx`）、状态页字段、night-plan timer、本地体检 timer、体检新函数；只 `systemctl restart` 相关服务，不重启系统；`.prev` + `rollback.sh` | 允许 / 不允许 / 拆开批 | 允许 | P1.5 |
| 3 | P3 重启窗口：作者在场或我在同一局域网能物理重启；重启前说一声、确认没在用 | 允许 / 不允许 | 允许 | P3 |
| 4 | y13 trial（1049 PCIe DT + PSI 默认关）+ 10 min 网络看门狗自动 `systemctl reboot` | 允许 / 不允许 / 只装不加看门狗 | 允许（看门狗是断网保险） | P3 |
| 5 | 无人值守亮屏 kiosk 夜 N6：触摸 `inhibited=1`、≤2 h、起始电量 ≥60 %、控制面板折叠 | 允许一夜 / 不允许 / 只在作者在场的白天做 | 允许一夜 | N6/P5 |

**B. cx-auto 卡住的处置（当前最大损失）**

| # | 决策 | 选项 | 默认建议 | 挡 |
|---|---|---|---|---|
| 6 | 审计 B2：`charger_at` 不随亮屏复位（插电后 ~30 s 仍按放电）——修法随 P1.5 发布 | 修 / 不修 | 修 | P1.5 |
| 7 | T1：判卡后自动亮屏一下（≤10 s、先调暗、触摸 inhibited）再灭 | 允许 / 不允许 | 允许（N3 起） | N3 |
| 8 | T2：判卡后自动重启 plasmashell（验 is-active，失败两次停手并报 WARN） | 允许 / 只记录 / 只在 T1 失败后 | 只在 T1 失败后 | N3 |
| 9 | T1/T2 频率：每次熄屏至多一次、两次间隔 ≥30 min | 接受 / 改参数 | 接受 | N3 |
| 10 | plasma-nm 根因（plasmashell 熄屏 1.2 % CPU）：P1 先只读定位；落地选 | 本地 QML 补丁 / 报上游（对外发布，另点头）/ 不做 | 先定位，落地另议 | P1/P3 |
| 11 | CarPlay 会话结束后重启 plasmashell | 自动 / 手动磁贴 / 不做 | 手动磁贴，等 CarPlay 基线 | P4 |

**C. 测量口径与机制**

| # | 决策 | 选项 | 默认建议 | 挡 |
|---|---|---|---|---|
| 12 | <0.03 W 的候选不出功耗裁决，只看代理指标，零风险项捆成一臂 | 接受 / 改 | 接受 | P0 |
| 13 | 裁决口径：每臂 ≥6 窗、符号检验双侧 p ≤0.05；一夜最多作废 2 窗 | 接受 / 改 | 接受 | P0 |
| 14 | N2 的 K= 夜用方案 a（两臂都由 cx-exp 持 E3a，不等新 Rust） | 是 / 等 `--keep-cx` 上线再测 | 是 | N2 |
| 15 | WIFI-2 旋钮白天亮屏先试 15 min（可能短暂掉 Tailscale） | 允许 / 不允许 | 允许 | N4 |
| 16 | 三个常驻 timer：`y700-cx-night.timer`（读 night-plan）、`y700-cx-soak.timer`（周日整夜 E3a soak）、`y700-checklist-local.timer` | 允许 / 只要前两个 / 不允许 | 允许 | P1.5 |
| 17 | 状态页新字段（含 `ssh_sessions`，DynamicUser 下可读性存疑则删） | 接受 / 删 `ssh_sessions` | 接受 | P1 |
| 18 | Win11 每日巡检加一条 curl，只在 `cx_stuck` / `cx_disabled` / 计划有行无单元时通知；**每日体检的 ssh 任务在测量夜改期**（TL-3 上线后改 curl） | 接受 / 改 | 接受 | P0 |

**D. 10-19 审计遗留（原「待作者决定」3–8，逐条）**

| # | 决策 | 选项 | 默认建议 | 挡 |
|---|---|---|---|---|
| 19 | 审计 3：`linux/games/hud/y700-power` 孤儿脚本（B4） | 删 / 改成 I×V 并进 install.sh | 删 | P3 |
| 20 | 审计 4：HUD 最忙进程没日志时（B11） | 宁可不显示 / 显示第 2、3 名 | 宁可不显示 | P3 |
| 21 | 审计 5：C3 体检加垫片检查（`check_waitboost_shim`）我按「无条件做」排在 P1.5；C23 upstream-check 残余在 P0 修并加回归 | 确认 / 改 | 确认 | P0/P1.5 |
| 22 | 审计 7：显示看门狗与刷新率守护（A2） | 看门狗恢复前停守护、结束再起 / 守护加 D-Bus `suspend(seconds)` | 守护加 suspend | P3 |
| 23 | 审计 8：刷新率守护只存作者选的键，不再把默认值写回 `~/.config/y700-refresh-auto.json` | 改 / 保留 | 改 | P3 |

**E. 对外、产品与长尾**

| # | 决策 | 选项 | 默认建议 | 挡 |
|---|---|---|---|---|
| 24 | keyhold 事件驱动补丁上游 PR：草稿已写好（未入公开仓库）；**提交 = 对外发布，另点头** | 先把 PR 文本定稿入库 / 不做 | 定稿入库，提交另问 | P3 |
| 25 | YouTube 入口 mpv + yt-dlp（P4，净收益待测、上限 ≤0.5 W） | 做 / 不做 | 做 | P4 |
| 26 | 默认刷新率维持 120（磁贴可切 60；静止桌面不省，持续重绘内容约省 1 W 但噪声大） | 维持 120 / 改 60 | 维持 120 | — |
| 27 | AP 拆 SSID / 调 DTIM（作者改 AP） | 改 / 不改 | 作者定 | P4 |
| 28 | UPSTREAMS 记录位置 | 新建 UPSTREAMS 文件 / 并入现有基础设施笔记 | 新建 UPSTREAMS 文件；过渡期用 `tools/upstream-state.json` | P0 |
| 29 | CPU-11/12 内核侧 CX 预研（cxsd 永远 0 的原因、AOP 投票） | 做（P6）/ 不做 | P6，不排期 | P6 |

---

## 附录 A 重启后清单（P3 每次）

1. `uname -r` 确认内核；trial 时看 `tb323fu-ctl kernel` 状态（两次非 keep → 自动回 y12，README:505）。
2. `tailscale status --json` BackendState=Running；`curl http://100.64.0.10:8766/` 字段齐全、`cx_disabled` 为空。
3. `y700-checklist` 全跑，FAIL 先处理；`--selftest`（kmsg-watch :600）。
4. 待验证项：`check_cx_knobs`、`check_cx_auto`、`check_cx_effect`、`check_night_plan`、`check_status_page`、`check_touch_inhibit`、`check_trace_leftovers`、`check_waitboost_shim`。
5. 熄屏 2 min 后状态页 `armed_since` 有值、`pd=sys` 在涨（不涨 = 又卡，先 T0 取证）。
6. 重启当晚计划行写 N1 式 `noop:15 ×12`。
7. 一切验证过即 commit，不推。

## 附录 B 角色与中止

| 角色 | 职责 |
|---|---|
| Win11（我） | P0 工具、fr-slice 裁决、巡检、文档修订；测量期不 ssh |
| 平板单元 | timer + night-plan 执行、自检、ABORT |
| 作者 | §7 决策、磁贴触发 CarPlay/场景、AP 改动、在场重启、OTG 验证 |
| 命名 | `y700-cx-*` 实验 / `y700-diag-*` 诊断 / `y700-scn-rec*` 场景；诊断绝不进 BENCHES |
| **中止** | 作者报 bug → 立即停实验，此时**允许 ssh**：`systemctl stop y700-cx-night 'y700-scn-rec*' 'y700-diag-*'` → 旋钮由 cx-exp trap 归零（核对 `check_cx_knobs`）→ `y700-flightrec --mark ABORT:<原因>` → 先修 bug 再排实验 |

## 附录 C 裁决记录格式（`runs/ab/INDEX.md`，新）

`- [<日期> <主题>](<切片文件>) — <一句话结论>；<裁决口径（双侧 p / 代理）>；<未决>`

## 附录 D `/etc/y700/night-plan` 格式

- 每行一夜，按顺序消费；空文件 = 当晚不测；`#` 注释。
- 行格式：`<DATE|*> <STEP:MIN> [<STEP:MIN> ...] [--idle MIN] [--from HH:MM] [--until HH:MM]`
  - STEP ∈ `noop | E3a | E3a+K=<knob> | DIAG | B=<bench>`；`K=` 的 knob 脚本在 `linux/power/knobs/<knob>.sh`（`on|off|check`）。
  - 例：`* E3a+K=rtcsync:15 E3a+K=noop:15 E3a+K=noop:15 E3a+K=rtcsync:15 --idle 30 --from 00:30 --until 06:00`
- 消费后整行追加到 `/var/log/y700-cx-auto/night-done.log`（含 `OK|ABORT:<原因>`）；状态页 `night_plan_next` 显示下一行。
- 编辑只在白天亮屏 ≤10 min 的 ssh 窗口；`check_night_plan` 校验语法。

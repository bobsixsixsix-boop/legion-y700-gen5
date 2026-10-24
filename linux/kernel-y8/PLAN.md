# 内核 y8 计划（2026-10-15）

作者要求：「内核里用不到的功能、为了支持某些硬件绕大弯的东西都去掉，不影响正常使用就行；动态内存频率优化抄安卓的逻辑。」
四个方面各由一个分析代理做、一个独立复核代理挑错（只读本机 inventory 和上游源码，没碰平板）。本文是汇总后的最终清单；
每条的依据在 `inventory/`、`y8-trim.fragment`、`y8-power.fragment`、`1040-*.patch`、`1041-*.patch` 的注释里。

## 一、要改的

### 1. 裁掉用不到的驱动和功能（`y8-trim.fragment`，538 项关、10 项降为模块）
- 虚拟化（xen/virtio/vfio）、其他高通 SoC 的时钟/引脚/互连/电源域驱动（约 1–2 MB 数据表）、老 SoC 的 PHY/总线/稳压器、
  8250 串口（4 个假 ttyS）、PCI 热插拔/SR-IOV、不存在的 USB 主机/UDC/gadget 功能、PS/2/红外/串口输入、HDMI 和别的面板/桥、
  老视频编解码（venus）和兄弟型号的摄像头传感器、别的板子的声卡/编解码/SOF、内核 IIO 传感器（本机传感器走 ADSP）、
  有线网卡/PTP/其他 Wi‑Fi 厂商、32 位兼容层（Oryon 没有 AArch32）、SELinux/AppArmor（从未初始化）、kexec/kdump、
  zswap/KSM、ramdisk、CoreSight 硬件追踪、PM_AUTOSLEEP/WAKELOCKS。
- 降为模块：NFS、F2FS、三个内建 qdisc。
- **收益要说实话**：这些驱动没绑设备，**几乎不省电**。收益是内核小 3–5 MB、启动少一两百个驱动注册、编译更快、攻击面更小。
- 保留清单 `y8-must-keep.txt`（570 个符号）由构建脚本机械核对，少一个就停。

### 2. 省电相关的配置（`y8-power.fragment`）
| 项 | 做法 | 预期 |
|---|---|---|
| RT 任务不再把 CPU 拉到最高频 | `UCLAMP_TASK=y` + sysctl `sched_util_clamp_min_rt_default=128`（安卓用 0；这里先 128，PipeWire 跑着扬声器保护 DSP 链，太低会爆音） | 触摸、音视频时省几十到上百 mW（猜测） |
| TEO 空闲调度器 | 编进去，默认仍是 menu；运行时 `echo teo > current_governor` 做 A/B | 0 到几十 mW |
| 惰性 RCU | `RCU_NOCB_CPU_DEFAULT_ALL` + `RCU_LAZY` | 空闲时少唤醒（ChromeOS 数据：−5–10%） |
| 关 SCHED_CACHE | 7.3 新增的多缓存调度，给服务器设计的 | 少一点记账 |
| 关 FW_LOADER_DEBUG | 每次加载固件白算一遍 SHA‑256 | 开机快一点 |
| 挂死超时 60 → 180 s | 插 U 盘写大文件时不再误重启；panic 保留 | 稳定性 |

### 3. 内存调频抄安卓（`1040-memlat-android-tuning.patch`）
- 现状：补丁 0126 给每个延迟监视器设 `ipm_ceil = 20000000`，等于"每个 CPU 永远算访存受限"，DDR/LLCC 跟着 CPU 频率走。
- 安卓（从 ColorOS 17 固件的 vendor 分区读出，副本已删）：同一份 CPUCP 固件、同样的监视器和映射表，只是门限不同：
  DDR gold 3000 / prime 13000（prime 另有 25% 频率缩放，1500–2800 MHz）/ latfloor 300000；DDR_QOS 700 / 350 / 300000；LLCC 400；
  采样 8 ms。
- 补丁只改数据和把 RFC 协议里已定义但驱动没发的 6 个参数发出去；写回投票路径有意设为不生效（固件事件表格式有未解的疑点）。复核逐行核过映射。
- **预期要说实话**：待机不省（内存 88% 时间本来就在最低档）；省在游戏、滑动这类 CPU 冲高但不缺内存的场景，估计 100–300 mW。
  风险：访存密集的代码可能变慢；所以要做内存延迟微基准和游戏帧数对比。

### 4. Wi‑Fi 固件省电（`1041-ath12k-sta-ps-vif-cfg.patch`，已作为模块在 y7 上验证）
- 熄屏 0.48 → 0.42 W；y8 编进内核。

### 5. 启动参数
- 删 3 个从来没生效的：`icc-rpmh.qos_disable=1`、`icc_rpmh.qos_disable=1`、`keep_bootcon`。
- 加 `msm.idle_refresh_ms60=500 msm.idle_refresh_ms30=2000`（现在靠 helper 预设，内核默认直接带上；helper 各预设仍可改）。
- 其余保留，含两个防复位参数和 `download_mode=full`（见下）。

## 二、需要作者点头的（默认按"不用的都去掉"执行，不同意就说）
1. **binder 关掉**：只有 Waydroid 用，没装。以后想试 Waydroid 要重开。
2. **容器网络（bridge/veth/vlan/vxlan…）关掉**：Docker/Podman/虚拟机才用。
3. **AUDIT 关掉**：运行时本来就是禁用的，sudo/sshd 不受影响。
4. **死机不再卡在转储模式**：`linux/power/y700-dumpmode-off.timer`（开机 3 分钟后关），同时 `hung_task_panic` 保留。
   代价：以后死机只有 pstore 日志，没有整块内存转储（要抓时临时 `echo full`）。昨晚那种 7 小时耗掉 35% 电的事不会再有。

## 三、有意不做的
- 补丁栈不拆：没有"纯为别的硬件绕大弯"的补丁。看似一加 15 专用的 0007/0008 含本机屏幕需要的修复；0106/0118 防复位必须留；
  摄像头补丁是在用的硬件；0010+0080 互相抵消但拆了零收益。
- 0110 降刷新时 DPU 投票不随刷新率降：复核指出这是正确的（VFP 拉伸不改行速率），不写补丁，README 原来那条已改正。
- 大页保持 always（游戏/FEX 受益）、autogroup 保留（一边编内核一边用桌面）、所有调试/pstore/BTF/ftrace 保留。
- 运行时允许簇/系统下电（真正的熄屏大头）：复位根因未修，这轮不碰。

## 四、怎么验证
1. `kbuild-y8.sh` 在平板上编（约 16 分钟全量），配置检查双向核对（保留清单一个不少、裁剪清单一个不回来）。
2. `tb323fu-ctl kernel install-local … --trial`，**作者重启**；起不来再重启一次自动回 y7。
3. `y8-verify.sh`：内核版本、启动参数、RCU offload、uclamp、TEO、裁掉的东西确实没了、memlat 参数发送成功、Wi‑Fi 省电、
   屏幕/触摸/震动/声卡/相机/蓝牙/USB gadget/zram/ntsync/exfat/FUSE/TUN/传感器/我们的用户服务。
4. 功耗：`y700-powerbench`（亮屏各状态）+ `y700-offbench`（熄屏）各跑一遍和 y7 比；内存微基准和一局游戏的帧数。
5. 通过才 `kernel keep`；任何退步 `kernel rollback`。

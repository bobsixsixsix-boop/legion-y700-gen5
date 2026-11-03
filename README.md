# y700：联想拯救者 Y700 第五代（TB323FU）上的 Linux 与 Android 个人调校

> **非官方个人项目。** 与联想、高通、OPPO、vivo、Apple 及其他任何厂商都没有关系，也没有得到它们的认可或赞助。刷机和改写分区可能让设备变砖、失去保修、丢失全部数据，一切操作风险自负。没有支持承诺。详见下文「免责声明」。
>
> **Unofficial personal project.** Not affiliated with or endorsed by Lenovo, Qualcomm, OPPO, vivo, Apple or any other vendor. Flashing and partition writes can brick the device, void the warranty and destroy data; use at your own risk. No support is promised. See [English](#english) below.

[中文](#中文) · [English](#english)

## 中文

### 这是什么

作者在自己的一台联想拯救者 Y700 第五代平板（Legion Tab Gen 5，型号 TB323FU，高通 SM8850，SoC 代号 kaanapali，板级代号 baldur）上日常使用 Linux 与 Android 双系统。这个仓库是期间积累的脚本、配置、补丁和笔记的公开版本，不定期从作者的工作仓库导出：

- **Linux 一侧**：Ubuntu 26.04 + KDE Plasma 6.6，装在单独的 `baldur-root` 分区上，可以和 Android 互相切换。内核、helper 守护进程和平台文件都来自上游 [tb323fu-linux](https://github.com/joonhoekim/tb323fu-linux)。本仓库是它的下游补充，放的是作者自己的内核补丁和随附的第三方内核补丁（作者与来源见 [PATCHES.md](PATCHES.md)），省电、显示、音频、输入和视频方面的调校，桌面组件，以及测量工具。
- **Android 一侧**：在一个第三方 ColorOS 17 移植包上做的精简、KernelSU 模块、刷新率与音频修正，以及对联想原厂固件的研究。移植包本身不提供，也不给链接。
- **刷机、恢复与切换**：EDL 刷写和救砖的工具与笔记；在两个系统之间切换的工具（Android App、设备端脚本、Linux 端入口）。
- **车载**：借助 LIVI，让平板作为 iPhone 无线 CarPlay 和无线 Android Auto 接收端的集成脚本。不含任何 MFi 认证组件。

本仓库不发布内核、helper 或其他二进制文件，也不提供更新源。`tb323fu-linux` 和 `tb323fu-*` 是上游项目的名字。这里提到它们只是为了说明来源；本仓库不是上游项目，也不是它的官方构建。

### 现状

截至 2026 年 11 月初的实际情况：

- **只在一台设备上验证过**，就是作者自己的 TB323FU。恢复工具只在 ROW 18.0.12.187 固件上验证过。其他型号、其他固件版本都没有试过。
- **Linux 一侧日常在用。** 当前内核是 y17，即上游 `kernel-t52`（Linux v7.3）加 28 个补丁（顺序见 `linux/kernel-y16/patches/series`），内置 initramfs 用上游 t54 的 init 加开机磁盘检查，2026-11-01 起作为日常内核。y14–y16 是它的前几代，y1–y13 基于 Linux v7.3-rc4（上游 t47 / t49），都保留作历史记录。
- **很多内容是实验和测量**：带日期的工作笔记、A/B 测试脚本、只在某次实验里用过的工具。文件名带 `DRAFT` 的补丁没有编译过，或者没有上机验证过。CarPlay 部分仍在进行中。
- **没有统一的安装器。** 各目录的 `install*.sh` 按作者的环境写死：桌面用户名 `user`（uid 1000）、安装路径、tailnet 地址的占位符等。**这些脚本都不检查机型**，多数要在平板上以 root 运行。用之前请先读一遍脚本。
- **文档以中文工作笔记为主**，写给没有上下文的下一个接手者。文中提到的「仓库 README 的某一节」和 `runs/` 下的日志，指的是未公开的开发日志和原始测量数据（见「有意不包含的内容」），在本仓库里找不到。文档里的第一人称多半是执笔的 AI 助手，「作者」指项目作者。
- **作者自己的内核补丁大多没有提交给上游。**

### 从哪里读起

先把上游 tb323fu-linux 装好，确认能正常启动。本仓库里的东西都以它为前提。然后按需要读：

| 想了解 | 先读 |
|---|---|
| 当前内核、补丁栈和装机后的体检 | [linux/kernel-y17/NOTES.md](linux/kernel-y17/NOTES.md)，补丁的变化见 [linux/kernel-y15/NOTES.md](linux/kernel-y15/NOTES.md) 和 [linux/kernel-y16/NOTES.md](linux/kernel-y16/NOTES.md)；上一代见 [linux/kernel-y14/NOTES.md](linux/kernel-y14/NOTES.md)；y8 起的背景见 [linux/kernel-y8/PLAN.md](linux/kernel-y8/PLAN.md) 和 [Y10-NOTES.md](linux/kernel-y8/Y10-NOTES.md) |
| 熄屏但不休眠时的省电 | [linux/power/PLAN-deep-powersave.md](linux/power/PLAN-deep-powersave.md) 的 §0，然后是 [WAKEUPS.md](linux/power/WAKEUPS.md)、[ALWAYS-ON.md](linux/power/ALWAYS-ON.md)、[KEYHOLD.md](linux/power/KEYHOLD.md) |
| 运行时 CX / 系统域下电实验 | [linux/power/cx-collapse/PROTOCOL.md](linux/power/cx-collapse/PROTOCOL.md)，背景见 [RESEARCH.md](linux/power/cx-collapse/RESEARCH.md) |
| 视频硬解与功耗 | [linux/video/VIDEO-POWER-MEMO.md](linux/video/VIDEO-POWER-MEMO.md) |
| 扬声器链路、爆音与挂起 | [linux/audio/README.md](linux/audio/README.md)，然后是 [POPS.md](linux/audio/POPS.md)、[SUSPEND.md](linux/audio/SUSPEND.md) |
| 事件驱动的看门狗 | [linux/net/KMSG-WATCH.md](linux/net/KMSG-WATCH.md) |
| 「电池」页（各应用的用电统计） | [linux/power/BATTERY-PAGE.md](linux/power/BATTERY-PAGE.md)，设计见 [linux/power/battery/DESIGN.md](linux/power/battery/DESIGN.md) |
| 后摄自动对焦与镜头供电（libcamera） | [linux/camera/README.md](linux/camera/README.md) |
| 无线 CarPlay / Android Auto | [linux/carplay/README.md](linux/carplay/README.md) |
| Android 一侧的精简与 KernelSU 模块 | [android-debloat/README.md](android-debloat/README.md) |
| 原厂 ZUI 固件研究、在移植系统上恢复杜比 | [stock-zui/README.md](stock-zui/README.md) |
| 删掉 Android、换回联想原版系统、升级底层固件的调研 | [android-remove-zui.md](android-remove-zui.md)、[firmware-upgrade-research.md](firmware-upgrade-research.md) |
| EDL 刷写与救砖 | [y700-recovery/README.md](y700-recovery/README.md)，以及上游文档的副本 [y700-recovery/notes/recovery.md](y700-recovery/notes/recovery.md) |

很多目录没有自己的 README，说明写在脚本开头的注释里。

### 目录

| 路径 | 内容 |
|---|---|
| `flash_coloros.py`、`prep_pkg.py`、`analyze_pkg.py`、`coloros16-plan.md`、`coloros17-analysis.md`、`*.sha256`、`patched/` | ColorOS 移植包的分析与 EDL 刷写。刷写分阶段进行（plan / probe / backup / flash / verify / setslot / reset）；准备包时把 userdata 定为 128 GiB，并新建 `baldur-root` 分区。**扇区号按作者那台设备写死。** 移植包不提供也不链接，只有哈希。`patched/SHA256SUMS` 是用官方 KernelSU 修补过的 init_boot 的哈希 |
| `android-remove-zui.md`、`firmware-upgrade-research.md` | 调研笔记（没有动手）：删掉 Android 后还能不能开机、能否换成联想原版系统；底层固件升级 |
| `android-debloat/` | ColorOS 17 移植的精简（经 adb 运行 `apply.sh` / `restore.sh`）；KernelSU 模块 `ksu-y700-hide`、`ksu-y700-vrr`、`ksu-y700-audio`；刷新率、桌面布局、音频崩溃分析、Play 商店笔记 |
| `stock-zui/` | 联想原厂 ZUI 固件的只读研究；KernelSU 模块 `ksu-y700-dax`，在移植系统上恢复联想的杜比服务（厂商 APK 和配置文件不随附） |
| `switcher/` | Android 与 Linux 之间的切换：Android App「Y700 Switcher」（`build.sh` 不用 Gradle；签名密钥不在仓库里）、设备端脚本（把 Linux 启动镜像写进 `boot_a`，带哈希校验）、Linux 端的 `y700-to-android` |
| `tools/` | 平板体检 `y700-checklist.py` 及其自测、功耗与帧率测量工具（熄屏功耗、唤醒源、PCIe L1SS、帧时间）、A/B 测试脚本 |
| `y700-recovery/` | EDL 恢复：`sahara_min.py`、bkerler/edl 的包装 `edl.sh`、Python 环境脚本、上游 `boot-repack-kernel.py` / `build-boot.sh` 的副本。loader 本身（`qsahara_device_programmer.xml` 和它列出的镜像）不随附 |
| `linux/audio/` | 扬声器保护守护 `y700-speaker-guard`（Rust）、调音链的接口约定（作者的调音配置不随附）、爆音与挂起的研究、EQ 测试、`DRAFT` 补丁 |
| `linux/camera/` | 给 libcamera 0.7.0 打的后摄自动对焦补丁，和修镜头一直上电的补丁；构建、安装、检查脚本，镜头功耗 A/B |
| `linux/carplay/` | LIVI 集成：热点调优、启动器、systemd 与 NetworkManager 集成，`aptest/` 下是离线调试热点的工具 |
| `linux/controlpanel/` | Qt/QML 控制中心 `y700-control-center`、自动旋转 |
| `linux/daily/` | 日常使用的配置（输入法、播放器、刷新率与功耗等） |
| `linux/devaccess/`、`linux/usbstick/` | USB gadget 网络上的 ssh 配置；用 U 盘一次性开启 ssh 的脚本（必须换成你自己的公钥） |
| `linux/display/` | 环境光自动亮度（Rust）；刷新率跟随视频（Rust 守护进程、KWin 脚本、Chrome 扩展和 native host） |
| `linux/dock/` | Dock 与状态栏 `y700-shellbar`（含通知和下拉面板）及其设计稿 |
| `linux/gamepad/` | 把手柄的 Home 键当作系统键；熄屏时关掉 G9 手柄的灯、按手柄键亮屏（都是 Rust） |
| `linux/games/` | 用 FEX 运行 x86 Steam 游戏所需的 rootfs 挂载、性能 HUD、移植给 kwin-effect-upscale 的 SGSR 超分 |
| `linux/gesture/` | 底边上滑回桌面的 KWin 脚本；基于 Plasma Mobile 任务切换器的多任务卡片；测试 |
| `linux/gpu/` | 给 Chrome 用的 LD_PRELOAD 垫片 `y700-no-waitboost`、drirc、复现脚本 |
| `linux/kernel-y1/` … `linux/kernel-y8/`、`linux/kernel-y14/` … `linux/kernel-y17/` | 各代内核的构建脚本、补丁、配置、体检脚本和笔记（y9–y13 在 `kernel-y8/` 里）。补丁的来源见 [PATCHES.md](PATCHES.md) |
| `linux/net/` | 事件驱动的看门狗 `y700-kmsg-watch`（Rust）、Wi‑Fi 与显示看门狗、Tailscale 安装脚本 |
| `linux/osk/`、`linux/osk-design/` | Qt6/QML 屏幕键盘 `y700-osk`（fcitx5 插件、KWin 效果、可选的语音输入），以及它的设计稿和拼音词表 |
| `linux/power/` | 熄屏不休眠时的省电：唤醒源治理、常开外设、PCIe L1.2、事件驱动的紧急组合键、几个 Rust 守护进程。`battery/` 是「电池」页（记录器、报告生成器、页面），`flightrec/` 是功耗飞行记录器，`cx-collapse/` 是运行时 CX 下电实验 |
| `linux/sensors/` | 修正传感器 hub 开机时的竞争问题 |
| `linux/streaming/` | Moonlight 120 fps 串流的调校和分析脚本 |
| `linux/usbport/` | 上游 `tb323fu-usb-port` 的本地替换（两个 USB-C 口共用一个控制器） |
| `linux/video/` | VA-API、Chrome、wiliwili 的视频功耗工作；`yuv709` 垫片；对 libva-v4l2 和 wiliwili 的补丁 |
| `linux/wifi/` | 6 GHz 优先、监管域 udev 规则、ath12k 参数补丁、5 GHz 评估 |
| `linux/serve_script.py`、`linux/restore-coloros-boot.sh` | 早期调试用的小工具（经 USB 网络下发脚本、在 9008 模式下写回 ColorOS 启动镜像） |

### 有意不包含的内容

- **开发日志和提交历史。** 原仓库的主 README（逐日的开发记录）和 git 历史里有个人环境、使用习惯以及与本项目无关的内容。本仓库不带原仓库的历史：每次发布都从工作仓库导出一份去掉了这些内容的版本，在这里记为一个提交。各子目录的笔记保留了，但其中指向开发日志的引用打不开。子目录笔记和源码注释里的提交哈希（如 `git 1814212`）指工作仓库的历史，在本仓库里查不到。本仓库上一次发布的提交 4372fdb 里还有 kmsg-watch、speaker-guard、autobright、refresh-auto 的旧 Python/bash 版，但那是 10-24 的版本，不一定是被 Rust 版替换掉的最后一版。
- **原始测量数据。** `runs/` 下的原始输出、飞行记录器日志等，里面有使用时段、系统日志、窗口标题和高通固件日志。公开的只有汇总和结论。「电池」页报告生成器的部分测试要用一份平板上的原始采集（`linux/power/battery/report/tests/fixtures/real-1030/`），这份采集只公开了三个文件，其余测试会自动跳过。
- **车上的胎压与 OBD 工具。** 还在开发，暂不公开。
- **CarPlay / MFi 认证组件与认证材料。** Apple MFi 认证材料不能公开，也不应由第三方再分发。自己部署时需要合法取得的 MFi 认证协处理器。
- **专有文件以及由专有文件派生的内容。** 包括固件、厂商 APK 与配置文件、ROM 包、EDL loader 镜像、原厂分区镜像，以及从联想杜比调音参数换算出来的扬声器配置（要自己提供什么，见 [linux/audio/README.md](linux/audio/README.md)）。需要的地方只给哈希和说明。
- **维护者自用的上游巡检与定时任务。** `tools/upstream-check.py`、`upstream-discover.py` 和调度它们的定时任务脚本跟作者的工作站绑在一起，不随附。笔记里提到的「巡检」「WATCH 表」指的就是它们。
- **设备唯一的数据和密钥。** 包括序列号、HWID、解锁数据、MAC 与蓝牙地址、Wi‑Fi 名称和密码、真实的 IP 和主机名、签名密钥（Android App 的 keystore、Chrome 扩展的私钥）。文中这类值都换成了占位符，例如 `100.64.0.x`、`02:00:00:00:00:xx`、`example-tailnet.ts.net`、用户名 `user`。使用时换成你自己的值。
- **二进制文件。** 内核 Image、模块、APK、压缩包等一律不收。

### 免责声明

- 这是非官方的个人项目，与联想、高通、OPPO、vivo、Apple 及其他任何厂商都没有关系，也没有得到它们的认可或赞助。
- Lenovo、Legion、Qualcomm、Snapdragon、OPPO、ColorOS、vivo、OriginOS、Jovi、Apple、iPhone、CarPlay、Google、Android、Android Auto、Chrome、Dolby、Steam、Ubuntu、KDE、Plasma、Tailscale 等名称是各自所有者的商标，这里只用来指明设备、与之配合的软件和设计参照。TB323FU 是联想的型号。
- 控制中心、Dock、屏幕键盘和多任务卡片的观感参照了 vivo OriginOS 6。一部分数值（尺寸比例、时长、缓动曲线、弹簧参数、键位、配色和按键音参数等）是从 vivo 的系统应用里测出或读出的参数，其余是自己调的；本仓库不含 vivo 的代码、布局文件、图片或音频。
- **刷机、EDL 写入和改写分区可能让设备变砖，可能使保修失效，也可能丢失全部数据。** 文中的扇区号、分区名和镜像哈希只对作者那台设备、那个固件版本成立。动手之前请自己核对，风险自负。
- 所有内容按现状提供，不附带任何明示或暗示的担保，具体以各许可证中的免责条款为准。
- 这是个人项目，没有支持承诺，见 [SUPPORT.md](SUPPORT.md)。

### AI 参与说明

本仓库的大部分代码和文档由 AI 编程助手 Claude Code（Anthropic）在作者的指导下编写，并在作者的真机上测试过；也有一部分出自其他 AI 编程工具。做什么、采纳什么由作者决定。AI 写的东西也会出错，使用之前请自己读一遍。

### 许可证

文件里自带的 SPDX 头优先；没有 SPDX 头的文件，按 [REUSE.toml](REUSE.toml) 确定。许可证全文在 `LICENSES/` 目录。

| 范围 | 许可证 |
|---|---|
| 默认：脚本、程序、配置等 | GPL-3.0-or-later |
| 文档正文（`*.md`） | CC-BY-SA-4.0 |
| 内核补丁和内核配置（`linux/kernel-*/` 下，以及其他目录里针对内核的补丁） | GPL-2.0-only，与 Linux 内核一致；`linux/audio/` 下只改设备树的那个补丁草稿为 BSD-3-Clause，与上游设备树一致 |
| 来自 tb323fu-linux 的副本和改写（平台脚本、USB 口路由、切换脚本、keyhold、y17 的 initramfs init） | MIT，与上游相同 |
| 针对上游 helper 的补丁 | GPL-3.0-or-later，与上游 helper 相同 |
| 其他第三方派生代码 | 各自沿用原项目的许可证，见 [NOTICE.md](NOTICE.md) |

内核补丁的作者和来源见 [PATCHES.md](PATCHES.md)，第三方致谢见 [NOTICE.md](NOTICE.md)。

### 参与、支持与安全

- 提交改动：见 [CONTRIBUTING.md](CONTRIBUTING.md)（需要 DCO 签名）。
- 支持：见 [SUPPORT.md](SUPPORT.md)。
- 安全问题请私下报告，见 [SECURITY.md](SECURITY.md)，里面也列了已知问题。

### 致谢

上游 tb323fu-linux 是这一切的基础。也感谢 ArmadaOS、Kettle、code002-2、Radxa 的 libva-v4l2、h0cheung、Shenghan Gao、mzakamin-hub/iceland-mainline（Osilvfe、mzak）、justririll、icecream95、LIVI、kwin-effect-upscale、Plasma Mobile 等项目和作者。完整清单见 [NOTICE.md](NOTICE.md) 和 [PATCHES.md](PATCHES.md)。

## English

### What this is

The author uses Linux and Android side by side, every day, on one Lenovo Legion Y700 5th generation tablet (Legion Tab Gen 5, model TB323FU, Qualcomm SM8850, SoC codename kaanapali, board codename baldur). This repository is the public edition of the scripts, configuration, patches and notes collected along the way, exported from the author's working repository from time to time:

- **Linux side**: Ubuntu 26.04 with KDE Plasma 6.6 on its own `baldur-root` partition, switchable with Android. The kernel, the helper daemon and the platform files come from the upstream project [tb323fu-linux](https://github.com/joonhoekim/tb323fu-linux). This repository is a downstream companion to it. It holds the author's own kernel patches and the third-party kernel patches it carries (authors and sources in [PATCHES.md](PATCHES.md)), tuning for power, display, audio, input and video, desktop components and measurement tools.
- **Android side**: debloating, KernelSU modules, refresh-rate and audio fixes on top of a third-party ColorOS 17 port, plus research on Lenovo's stock firmware. The port itself is neither provided nor linked.
- **Flashing, recovery and switching**: EDL flashing and unbricking tools and notes, and tools to switch between the two systems (an Android app, on-device scripts and a Linux entry point).
- **In the car**: integration scripts that use LIVI to turn the tablet into a wireless CarPlay (iPhone) and wireless Android Auto receiver. No MFi authentication component of any kind is included.

This repository ships no kernel, helper or other binaries and runs no update channel. `tb323fu-linux` and `tb323fu-*` are the upstream project's names. They appear here only to say where things come from; this repository is not the upstream project and not an official build of it.

### Status

As of early November 2026:

- **Tested on one device only**: the author's own TB323FU. The recovery tools were verified only on firmware ROW 18.0.12.187. No other model or firmware version has been tried.
- **The Linux side is in daily use.** The current kernel is y17: upstream `kernel-t52` (Linux v7.3) plus 28 patches (order in `linux/kernel-y16/patches/series`), with upstream t54's initramfs init plus a boot-time disk check built in, the daily kernel since 2026-11-01. y14–y16 are its predecessors; y1–y13 were based on Linux v7.3-rc4 (upstream t47 / t49). All are kept as history.
- **Much of the content is experiments and measurement**: dated working notes, A/B test scripts and tools used for a single experiment. Patches with `DRAFT` in the name have not been compiled or not been tested on the device. The CarPlay work is still in progress.
- **There is no unified installer.** The `install*.sh` scripts in each directory assume the author's setup: the desktop user `user` (uid 1000), install paths, a placeholder tailnet address and so on. **None of them checks the device model**, and most of them must run as root on the tablet. Read a script before you run it.
- **The documentation is mostly working notes in Chinese**, written for the next person picking the work up without context. References to "a section of the repository README" and to logs under `runs/` point at the unpublished development log and raw measurement data (see "What is intentionally not included"); they cannot be found here. "I" in the notes is usually the AI assistant that wrote them; "the author" is the project's author.
- **Most of the author's own kernel patches have not been submitted upstream.**

### Where to start

Install upstream tb323fu-linux first and make sure it boots. Everything here assumes it. Then read what you need:

| Topic | Read first |
|---|---|
| Current kernel, patch stack and post-install checks | [linux/kernel-y17/NOTES.md](linux/kernel-y17/NOTES.md), the patch changes in [linux/kernel-y15/NOTES.md](linux/kernel-y15/NOTES.md) and [linux/kernel-y16/NOTES.md](linux/kernel-y16/NOTES.md); the previous generation in [linux/kernel-y14/NOTES.md](linux/kernel-y14/NOTES.md); background from y8 on in [linux/kernel-y8/PLAN.md](linux/kernel-y8/PLAN.md) and [Y10-NOTES.md](linux/kernel-y8/Y10-NOTES.md) |
| Power saving with the screen off but the system awake | §0 of [linux/power/PLAN-deep-powersave.md](linux/power/PLAN-deep-powersave.md), then [WAKEUPS.md](linux/power/WAKEUPS.md), [ALWAYS-ON.md](linux/power/ALWAYS-ON.md), [KEYHOLD.md](linux/power/KEYHOLD.md) |
| Runtime CX / system-domain power-collapse experiments | [linux/power/cx-collapse/PROTOCOL.md](linux/power/cx-collapse/PROTOCOL.md), background in [RESEARCH.md](linux/power/cx-collapse/RESEARCH.md) |
| Hardware video decoding and its power cost | [linux/video/VIDEO-POWER-MEMO.md](linux/video/VIDEO-POWER-MEMO.md) |
| The speaker chain, pops and suspend | [linux/audio/README.md](linux/audio/README.md), then [POPS.md](linux/audio/POPS.md), [SUSPEND.md](linux/audio/SUSPEND.md) |
| Event-driven watchdogs | [linux/net/KMSG-WATCH.md](linux/net/KMSG-WATCH.md) |
| The "Battery" page (energy use per app) | [linux/power/BATTERY-PAGE.md](linux/power/BATTERY-PAGE.md), design in [linux/power/battery/DESIGN.md](linux/power/battery/DESIGN.md) |
| Rear-camera autofocus and lens power (libcamera) | [linux/camera/README.md](linux/camera/README.md) |
| Wireless CarPlay / Android Auto | [linux/carplay/README.md](linux/carplay/README.md) |
| Android-side debloating and KernelSU modules | [android-debloat/README.md](android-debloat/README.md) |
| Stock ZUI firmware research, Dolby on the port | [stock-zui/README.md](stock-zui/README.md) |
| Research on removing Android, going back to Lenovo's stock system and upgrading the low-level firmware | [android-remove-zui.md](android-remove-zui.md), [firmware-upgrade-research.md](firmware-upgrade-research.md) |
| EDL flashing and unbricking | [y700-recovery/README.md](y700-recovery/README.md) and a copy of the upstream document, [y700-recovery/notes/recovery.md](y700-recovery/notes/recovery.md) |

Many directories have no README of their own; the comments at the top of each script explain it.

### Layout

| Path | Contents |
|---|---|
| `flash_coloros.py`, `prep_pkg.py`, `analyze_pkg.py`, `coloros16-plan.md`, `coloros17-analysis.md`, `*.sha256`, `patched/` | Analysis and EDL flashing of the ColorOS port. Flashing runs in stages (plan / probe / backup / flash / verify / setslot / reset); package preparation sets userdata to 128 GiB and adds a `baldur-root` partition. **Sector numbers are hard-coded for the author's device.** The packages are neither provided nor linked, only their hashes. `patched/SHA256SUMS` holds the hash of the init_boot patched with official KernelSU |
| `android-remove-zui.md`, `firmware-upgrade-research.md` | Research notes, nothing carried out: whether the tablet still boots with Android removed, going back to Lenovo's stock system, upgrading the low-level firmware |
| `android-debloat/` | Debloating the ColorOS 17 port (`apply.sh` / `restore.sh` over adb); KernelSU modules `ksu-y700-hide`, `ksu-y700-vrr`, `ksu-y700-audio`; refresh rate, launcher layout, an audio crash analysis, Play Store notes |
| `stock-zui/` | Read-only research on Lenovo's stock ZUI firmware; the KernelSU module `ksu-y700-dax` restores Lenovo's Dolby service on the port (vendor APK and configuration not included) |
| `switcher/` | Switching between Android and Linux: the Android app "Y700 Switcher" (`build.sh` without Gradle; the signing key is not in the repository), on-device scripts (write the Linux boot image to `boot_a`, with hash checks) and `y700-to-android` on the Linux side |
| `tools/` | The on-tablet health check `y700-checklist.py` and its self-test; power and frame-rate measurement tools (screen-off power, wakeup sources, PCIe L1SS, frame times); A/B test scripts |
| `y700-recovery/` | EDL recovery: `sahara_min.py`, `edl.sh` (a wrapper around bkerler/edl), a Python environment script, copies of upstream `boot-repack-kernel.py` / `build-boot.sh`. The loader itself (`qsahara_device_programmer.xml` and the images it lists) is not included |
| `linux/audio/` | The speaker protection guard `y700-speaker-guard` (Rust), the interface of the tuning stage (the author's tuning configuration is not included), research on speaker pops and suspend, EQ tests, `DRAFT` patches |
| `linux/camera/` | Patches for libcamera 0.7.0: rear-camera autofocus, and a fix for the lens staying powered; build, install and check scripts, a lens power A/B test |
| `linux/carplay/` | LIVI integration: hotspot tuning, launcher, systemd and NetworkManager integration; `aptest/` holds offline hotspot debugging tools |
| `linux/controlpanel/` | The Qt/QML control center `y700-control-center`, auto-rotation |
| `linux/daily/` | Everyday configuration (input method, media player, refresh rate and power, and so on) |
| `linux/devaccess/`, `linux/usbstick/` | ssh over the USB gadget network; a script that enables ssh once from a USB stick (you must put in your own public key) |
| `linux/display/` | Automatic brightness from the ambient light sensor (Rust); refresh rate that follows the video (a Rust daemon, KWin script, Chrome extension and native host) |
| `linux/dock/` | The dock and status bar `y700-shellbar` (with notifications and a pull-down panel) and its design mockups |
| `linux/gamepad/` | Uses the gamepad's Home key as a system key; turns a G9 pad's lights off with the screen and the screen on from a pad button (both Rust) |
| `linux/games/` | Rootfs mounts for running x86 Steam games with FEX, a performance HUD, an SGSR upscaler port for kwin-effect-upscale |
| `linux/gesture/` | A KWin script for the bottom-edge swipe home; task cards based on the Plasma Mobile task switcher; tests |
| `linux/gpu/` | The LD_PRELOAD shim `y700-no-waitboost` for Chrome, drirc, reproducer scripts |
| `linux/kernel-y1/` … `linux/kernel-y8/`, `linux/kernel-y14/` … `linux/kernel-y17/` | Build scripts, patches, configuration, check scripts and notes for each kernel generation (y9–y13 live in `kernel-y8/`). Patch provenance is in [PATCHES.md](PATCHES.md) |
| `linux/net/` | The event-driven watchdog `y700-kmsg-watch` (Rust), Wi‑Fi and display watchdogs, a Tailscale install script |
| `linux/osk/`, `linux/osk-design/` | The Qt6/QML on-screen keyboard `y700-osk` (fcitx5 add-on, KWin effect, optional voice input), its design mockup and pinyin word list |
| `linux/power/` | Power saving with the screen off but the system awake: wakeup-source control, always-on peripherals, PCIe L1.2, an event-driven emergency key chord, several Rust daemons. `battery/` is the "Battery" page (recorder, report generator, page), `flightrec/` a power flight recorder, `cx-collapse/` the runtime CX power-collapse experiments |
| `linux/sensors/` | Fixes for a sensor-hub race at boot |
| `linux/streaming/` | Tuning and analysis scripts for 120 fps Moonlight streaming |
| `linux/usbport/` | A local replacement for upstream `tb323fu-usb-port` (two USB-C ports share one controller) |
| `linux/video/` | Video power work for VA-API, Chrome and wiliwili; the `yuv709` shim; patches against libva-v4l2 and wiliwili |
| `linux/wifi/` | 6 GHz preference, a regulatory-domain udev rule, an ath12k parameter patch, a 5 GHz evaluation |
| `linux/serve_script.py`, `linux/restore-coloros-boot.sh` | Small early debugging tools (serving a script over the USB network, writing the ColorOS boot image back in 9008 mode) |

### What is intentionally not included

- **The development log and commit history.** The original repository's main README (a day-by-day development record) and its git history contain details of the author's environment and habits and material unrelated to this project. This repository does not carry that history: each release exports a version of the working repository with that material removed, recorded here as one commit. The notes in the subdirectories are kept, but their references into the development log cannot be followed. Commit hashes in the subdirectory notes and source comments (e.g. `git 1814212`) refer to the working repository's history and cannot be resolved here. This repository's previous release commit 4372fdb still has older Python/bash versions of kmsg-watch, speaker-guard, autobright and refresh-auto, as of 10-24, not necessarily the last versions the Rust ports replaced.
- **Raw measurement data.** Raw output under `runs/`, flight-recorder logs and similar files contain usage times, system logs, window titles and Qualcomm firmware logs. Only summaries and conclusions are published. Some tests of the "Battery" page's report generator need a raw capture from the tablet (`linux/power/battery/report/tests/fixtures/real-1030/`); only three of its files are published, and the other tests skip themselves.
- **The tyre-pressure and OBD tools for the car**: still in development, not published yet.
- **CarPlay / MFi authentication components and material.** Apple MFi authentication material must not be published and should not be redistributed by third parties. To deploy this yourself you need a legitimately obtained MFi authentication coprocessor.
- **Proprietary files and anything derived from them**: firmware, vendor APKs and configuration files, ROM packages, EDL loader images, stock partition images, and the speaker configuration converted from Lenovo's Dolby tuning values (what you need to supply instead is in [linux/audio/README.md](linux/audio/README.md)). Where they are needed, only hashes and instructions are given.
- **The maintainer's upstream watch and scheduled job**: `tools/upstream-check.py`, `upstream-discover.py` and the scheduled-job script that runs them are tied to the author's workstation and are not included. References in the notes to the "upstream watch" or its "WATCH table" mean these.
- **Device-unique data and keys**: serial numbers, HWIDs, unlock data, MAC and Bluetooth addresses, Wi‑Fi names and passwords, real IP addresses and host names, signing keys (the Android app's keystore, the Chrome extension's private key). Such values in the text have been replaced with placeholders such as `100.64.0.x`, `02:00:00:00:00:xx`, `example-tailnet.ts.net` and the user name `user`. Substitute your own.
- **Binaries**: kernel Images, modules, APKs, archives and the like are never included.

### Disclaimer

- This is an unofficial personal project. It is not affiliated with, endorsed by or sponsored by Lenovo, Qualcomm, OPPO, vivo, Apple or any other vendor.
- Lenovo, Legion, Qualcomm, Snapdragon, OPPO, ColorOS, vivo, OriginOS, Jovi, Apple, iPhone, CarPlay, Google, Android, Android Auto, Chrome, Dolby, Steam, Ubuntu, KDE, Plasma, Tailscale and other names are trademarks of their respective owners. They are used here only to identify the device, the software it works with and design references. TB323FU is Lenovo's model number.
- The look of the control center, dock, on-screen keyboard and task cards takes vivo OriginOS 6 as its reference. Some numeric values (size ratios, durations, easing curves, spring constants, key positions, colours and key-sound parameters) were measured from or read out of vivo's system apps; the rest were tuned by hand. No vivo code, layout files, images or audio are included.
- **Flashing, EDL writes and partition changes can brick the device, void the warranty and destroy all data.** The sector numbers, partition names and image hashes in this repository hold only for the author's device and firmware version. Check everything yourself before you act; you do so at your own risk.
- Everything is provided as is, without warranty of any kind, express or implied; the disclaimers in the respective licenses apply.
- This is a personal project with no support promise; see [SUPPORT.md](SUPPORT.md).

### AI participation

Most of the code and documentation in this repository was written by an AI coding assistant, Claude Code (Anthropic), under the author's direction, and tested on the author's real hardware; some parts came from other AI coding tools. The author decides what is done and what is kept. AI-written material can be wrong; read it before you use it.

### Licensing

A file's own SPDX header takes precedence; files without one are covered by [REUSE.toml](REUSE.toml). The full license texts are in `LICENSES/`.

| Scope | License |
|---|---|
| Default: scripts, programs, configuration | GPL-3.0-or-later |
| Documentation prose (`*.md`) | CC-BY-SA-4.0 |
| Kernel patches and kernel configuration (under `linux/kernel-*/`, and kernel patches in other directories) | GPL-2.0-only, as the Linux kernel; the device-tree-only draft patch in `linux/audio/` is BSD-3-Clause, as the upstream device trees |
| Copies and adaptations of tb323fu-linux files (platform scripts, USB port routing, switch script, keyhold, y17's initramfs init) | MIT, as upstream |
| The patch against the upstream helper | GPL-3.0-or-later, as the upstream helper |
| Other third-party derived code | The license of the original project; see [NOTICE.md](NOTICE.md) |

Kernel patch authorship and origin are listed in [PATCHES.md](PATCHES.md); third-party credits are in [NOTICE.md](NOTICE.md).

### Contributing, support and security

- To propose changes, see [CONTRIBUTING.md](CONTRIBUTING.md) (DCO sign-off required).
- For support, see [SUPPORT.md](SUPPORT.md).
- Report security problems privately, as described in [SECURITY.md](SECURITY.md), which also lists known issues.

### Acknowledgements

Upstream tb323fu-linux is the foundation of all of this. Thanks also to ArmadaOS, Kettle, code002-2, Radxa's libva-v4l2, h0cheung, Shenghan Gao, mzakamin-hub/iceland-mainline (Osilvfe, mzak), justririll, icecream95, LIVI, kwin-effect-upscale, Plasma Mobile and their authors. The full list is in [NOTICE.md](NOTICE.md) and [PATCHES.md](PATCHES.md).

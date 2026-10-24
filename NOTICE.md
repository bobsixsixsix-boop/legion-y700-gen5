# NOTICE

[English](#english)

y700：联想拯救者 Y700 第五代（TB323FU）上的 Linux 与 Android 个人调校。
版权归 2026 bobsixsixsix-boop 以及下文和各文件中列出的其他权利人所有。

非官方项目，与联想、高通、OPPO、vivo、Apple 及其他任何厂商都没有关系，也没有得到它们的认可或赞助。它们的名称只用来指明设备和与之配合的软件，均为各自所有者的商标。本仓库是上游 [tb323fu-linux](https://github.com/joonhoekim/tb323fu-linux) 的下游补充，不是上游项目，也不是它的官方构建；`tb323fu-linux` 和 `tb323fu-*` 是上游的名字。

## 许可证

文件里自带的 SPDX 头优先；没有 SPDX 头的文件按 [REUSE.toml](REUSE.toml) 确定。许可证全文在 `LICENSES/` 目录。

| 范围 | 许可证 | 权利人 |
|---|---|---|
| 下面没有单独列出的文件（脚本、程序、配置等） | GPL-3.0-or-later | bobsixsixsix-boop |
| 文档正文（`*.md`） | CC-BY-SA-4.0 | bobsixsixsix-boop；`y700-recovery/notes/recovery.md` 是上游文档的副本，权利人为 Joonhoe Kim and contributors（改动：开头加了说明，相对链接改为指向上游仓库） |
| `linux/kernel-*/` 下的内核补丁（`*.patch`、`*.patch.upstream`） | GPL-2.0-only | 各补丁 `From:` / `Signed-off-by:` 中的作者，见 [PATCHES.md](PATCHES.md) |
| `linux/kernel-*/` 下的内核配置（`config-*`、`inventory/config-*`、`*.fragment`） | GPL-2.0-only | Joonhoe Kim and contributors；bobsixsixsix-boop |
| 其他目录里针对内核的补丁：`linux/audio/aw882xx-*.DRAFT.patch`、`linux/power/soc-qcom-ice-runtime-pm.DRAFT.patch`、`linux/wifi/ath12k-wcn7860-mlo-param.patch` | GPL-2.0-only | bobsixsixsix-boop |
| 针对上游设备树的补丁：`linux/audio/1050-arm64-dts-qcom-baldur-audio-aw882xx-fade-flag.DRAFT.patch` | BSD-3-Clause（与上游设备树相同） | Joonhoe Kim and contributors；bobsixsixsix-boop |
| 内嵌了 Linux 内核源码片段（用作定位锚点）的脚本：`linux/kernel-y6/make-1032.py`、`linux/kernel-y7/make-1033.py`、`linux/kernel-y8/make-1041.py`、`linux/carplay/aptest/txdbg-patch.py`、`linux/carplay/aptest/noenc-patch.py` | GPL-2.0-only | bobsixsixsix-boop；Linux 内核的贡献者 |
| tb323fu-linux 文件的原样副本：`y700-recovery/tools/boot-repack-kernel.py`、`y700-recovery/tools/build-boot.sh`、`linux/usbport/tb323fu-usb-port.upstream-0.4.2` | MIT | Joonhoe Kim and contributors |
| 改写自 tb323fu-linux 的文件：`linux/usbport/y700-usb-port`、`linux/usbport/70-tb323fu-usb-port.rules`、`switcher/device/switch-to-linux.sh`、`linux/power/keyhold.c`、`linux/power/keyhold-event-driven.patch`、`linux/power/keyhold-model-test.py`、`linux/power/tb323fu-dsp-no-cdsp.conf` | MIT | Joonhoe Kim and contributors；bobsixsixsix-boop |
| 针对上游 helper 的补丁：`linux/power/helperd-slow-poll.patch` | GPL-3.0-or-later（与上游 helper 相同） | Joonhoe Kim and contributors；bobsixsixsix-boop |
| `linux/carplay/livi/`（LIVI 的集成脚本和 `y700-gst-colorimetry.c`） | GPL-3.0-or-later | bobsixsixsix-boop |
| kwin-effect-upscale 的补丁和改写脚本：`linux/games/sgsr/kwin-effect-upscale-sgsr.patch`、`add-sgsr.py`、`add-rotation-aspect.py` | GPL-2.0-or-later（与 kwin-effect-upscale 相同） | Jens Koehler；bobsixsixsix-boop |
| `linux/games/sgsr/kwin-upscale-x11.sh` | GPL-2.0-or-later（文件头） | Jens Koehler |
| `linux/games/sgsr/sgsr.frag` | BSD-3-Clause（文件头） | Qualcomm Innovation Center, Inc.（Snapdragon Game Super Resolution 1，文件第一行是上游原文的版权声明）；bobsixsixsix-boop（移植部分） |
| 多任务卡片：`linux/gesture/taskswitcher/y700-taskswitcher.patch`、`ui/`、`metadata.json` | GPL-2.0-or-later（与 Plasma Mobile 的任务切换器相同） | Devin Lin 及 Plasma Mobile 的贡献者；bobsixsixsix-boop |
| Wayland 协议描述：`linux/controlpanel/y700-control-center/protocol/blur.xml`、`fake-input.xml`，`linux/gesture/tests/ftouch/fake-input.xml` | LGPL-2.1-or-later（文件头） | Martin Gräßlin、Marco Martin（KDE plasma-wayland-protocols） |
| `linux/power/cx-collapse/dczva-stress.c` | GPL-2.0-or-later | bobsixsixsix-boop |
| 带桌面壁纸的截图：`linux/dock/tests/shots/` 里的 `01-desktop.png`、`c2-notes.png`、`c3-swiped.png`、`c4-cleared.png`、`h-widget-grid.png`、`r1-notes-real.png`、`r4-banners-real.png`、`r8-notes-real.png` | CC-BY-SA-4.0（与壁纸相同） | bobsixsixsix-boop；壁纸「Sub-Arctic」（KDE Plasma 6.6 默认壁纸）的作者 Krystian Zajdel |

对其他项目的补丁（`linux/video/wiliwili-*.patch`、`linux/video/libva-v4l2-patches/`）只包含为该项目写的改动和少量上下文行；上下文行仍属于原项目，适用原项目的许可证。

## 第三方代码与来源

- **tb323fu-linux**（Joonhoe Kim and contributors，<https://github.com/joonhoekim/tb323fu-linux>）：本仓库的基础。上面列出的副本和改写文件来自上游的 helper 0.4.2 与 main 分支（`0c7c0c4`）；`linux/kernel-y2/upstream-patches/` 里的 0097、0117 和 `linux/kernel-y8/t51/` 里的 0131、0132 是上游内核补丁；`linux/kernel-y5/baldur-extra.fragment` 与 `config-tb323fu-t49`、`linux/kernel-y8/inventory/config-t49.release` 是上游 t49 的配置。
- **内核补丁的其他来源**：ArmadaOS（armada-os/armada）、Kettle（gennro）、Diogo Trindade（armada-os/armada PR #718）、code002-2/sm8750-video-accel、radxa-pkg/libva-v4l2（Xilin Wu）、h0cheung/tb322fc-linux-kernel 以及 xiaqinghuan 发到 lore 的补丁、justririll/x1e-sleep 和 Marc Zyngier 的 arm-platforms 树外勘误补丁、linux-next 中 Akhil P Oommen（Qualcomm）的 a6xx 补丁、SuperTurtleDev/iceland-mainline-kernel-linux（Yibo Wang）。逐个补丁的说明见 [PATCHES.md](PATCHES.md)。
- **LIVI**（GPL-3.0，<https://github.com/f-io/LIVI>）：CarPlay 与无线 Android Auto 的接收端，原样运行，不随附。集成脚本针对 9.4.0 和 10.0.0 编写，用到了上游提交 `b82707ad`（经 Wi‑Fi 使用 Siri 的修复）。
- **hostapd / wpa_supplicant**（<https://w1.fi/>）与 Linux 的 **ath12k** 驱动：热点调试工具参照和修补的对象。
- **kwin-effect-upscale**（Jens Koehler，JensKSP/kwin-effect-upscale，GPL-2.0-or-later）：SGSR 移植的宿主。
- **Snapdragon Game Super Resolution 1**（Qualcomm Innovation Center, Inc.，BSD-3-Clause）：`sgsr.frag` 的来源，即 SnapdragonGameStudios/snapdragon-gsr 的 `sgsr/v1/include/glsl/sgsr1_shader_mobile.frag`。
- **KDE Plasma 默认壁纸「Sub-Arctic」**（Krystian Zajdel，CC-BY-SA-4.0，KDE breeze 仓库的 `wallpapers/Next`）：出现在 `linux/dock/tests/shots/` 的部分截图里。截图里的应用图标是各自所有者的商标。
- **Plasma Mobile** 的任务切换器 mobiletaskswitcher（Devin Lin 等，GPL-2.0-or-later）：多任务卡片的基础。
- **KDE plasma-wayland-protocols**（LGPL-2.1-or-later）：`blur.xml`、`fake-input.xml`。
- **研究参考**（没有复制代码）：icecream95/x1e-crash（`dczva-stress.c` 独立重写了它的触发指令序列）、justririll/x1e-sleep、TF-A 的 PSCI OS-initiated 模式文档（<https://trustedfirmware-a.readthedocs.io/en/v2.11/design_documents/psci_osi_mode.html>）、CodeLinaro 的 msm 内核（pci-msm，<https://git.codelinaro.org/clo/la/kernel/qcom>）、pciutils、systemd。

## 使用但不随附的外部项目

下面这些由脚本在设备上下载、构建或调用，本仓库不包含它们的代码或二进制，它们各自适用自己的许可证：bkerler/edl、KernelSU、LIVI、FEX 及其 x86 rootfs、Steam、Moonlight、wiliwili、kwin-effect-upscale、libva-v4l2、fcitx5、Plasma Mobile、Tailscale。

## 不随附的专有文件

固件、厂商 APK 与配置文件、ROM 包、EDL loader 镜像、原厂分区镜像、Apple MFi 认证材料都不随本仓库发布。需要的地方只给哈希和说明，请从合法渠道自行获取。

## English

y700: personal Linux and Android tuning for the Lenovo Legion Y700 5th generation (TB323FU).
Copyright 2026 bobsixsixsix-boop and the other holders named below and in individual files.

Unofficial project, not affiliated with, endorsed by or sponsored by Lenovo, Qualcomm, OPPO, vivo, Apple or any other vendor. Their names are used only to identify the device and the software it works with, and are trademarks of their respective owners. This repository is a downstream companion to upstream [tb323fu-linux](https://github.com/joonhoekim/tb323fu-linux); it is not that project and not an official build of it. `tb323fu-linux` and `tb323fu-*` are upstream's names.

### Licenses

A file's own SPDX header takes precedence; files without one are covered by [REUSE.toml](REUSE.toml). Full license texts are in `LICENSES/`.

- Everything not listed below: GPL-3.0-or-later, bobsixsixsix-boop.
- Documentation prose (`*.md`): CC-BY-SA-4.0. `y700-recovery/notes/recovery.md` is a copy of an upstream document by Joonhoe Kim and contributors (changes: a note at the top; relative links now point to the upstream repository).
- Kernel patches under `linux/kernel-*/`: GPL-2.0-only, held by the authors named in each patch (see [PATCHES.md](PATCHES.md)). Kernel configuration there: GPL-2.0-only.
- Kernel patches elsewhere (`linux/audio/aw882xx-*.DRAFT.patch`, `linux/power/soc-qcom-ice-runtime-pm.DRAFT.patch`, `linux/wifi/ath12k-wcn7860-mlo-param.patch`): GPL-2.0-only. The device-tree patch `linux/audio/1050-…-fade-flag.DRAFT.patch`: BSD-3-Clause, as the upstream device trees.
- Scripts that embed Linux kernel source excerpts as anchors (`make-1032.py`, `make-1033.py`, `make-1041.py`, `aptest/txdbg-patch.py`, `aptest/noenc-patch.py`): GPL-2.0-only.
- Verbatim copies of tb323fu-linux files (`y700-recovery/tools/boot-repack-kernel.py`, `build-boot.sh`, `linux/usbport/tb323fu-usb-port.upstream-0.4.2`): MIT, Joonhoe Kim and contributors. Adaptations of them (`linux/usbport/y700-usb-port`, `70-tb323fu-usb-port.rules`, `switcher/device/switch-to-linux.sh`, `linux/power/keyhold.c`, `keyhold-event-driven.patch`, `keyhold-model-test.py`, `tb323fu-dsp-no-cdsp.conf`): MIT, with bobsixsixsix-boop.
- The patch against the upstream helper (`linux/power/helperd-slow-poll.patch`): GPL-3.0-or-later.
- `linux/carplay/livi/`: GPL-3.0-or-later.
- kwin-effect-upscale patch and edit scripts (`linux/games/sgsr/`): GPL-2.0-or-later (Jens Koehler, bobsixsixsix-boop); `kwin-upscale-x11.sh`: GPL-2.0-or-later (Jens Koehler); `sgsr.frag`: BSD-3-Clause (Qualcomm Innovation Center, Inc., whose notice is the file's first line; the port by bobsixsixsix-boop).
- Task cards (`linux/gesture/taskswitcher/` patch, `ui/`, `metadata.json`): GPL-2.0-or-later (Devin Lin and the Plasma Mobile contributors, bobsixsixsix-boop).
- Wayland protocol files `blur.xml` and `fake-input.xml`: LGPL-2.1-or-later (Martin Gräßlin, Marco Martin; KDE plasma-wayland-protocols).
- `linux/power/cx-collapse/dczva-stress.c`: GPL-2.0-or-later.
- Screenshots in `linux/dock/tests/shots/` that show the desktop wallpaper (`01-desktop.png`, `c2-notes.png`, `c3-swiped.png`, `c4-cleared.png`, `h-widget-grid.png`, `r1-notes-real.png`, `r4-banners-real.png`, `r8-notes-real.png`): CC-BY-SA-4.0, bobsixsixsix-boop and Krystian Zajdel (the KDE Plasma 6.6 default wallpaper "Sub-Arctic").

Patches against other projects (`linux/video/wiliwili-*.patch`, `linux/video/libva-v4l2-patches/`) contain only the changes written for that project plus a few context lines; the context lines remain the original project's and fall under its license.

### Third-party code and sources

- **tb323fu-linux** (Joonhoe Kim and contributors): the base of this work. The copies and adaptations listed above come from upstream helper 0.4.2 and the main branch (`0c7c0c4`); patches 0097, 0117, 0131 and 0132 and the t49 configuration files are upstream's.
- **Other kernel patch sources**: ArmadaOS (armada-os/armada), Kettle (gennro), Diogo Trindade (armada-os/armada PR #718), code002-2/sm8750-video-accel, radxa-pkg/libva-v4l2 (Xilin Wu), h0cheung/tb322fc-linux-kernel and xiaqinghuan's patch on lore, justririll/x1e-sleep and Marc Zyngier's out-of-tree erratum patch in arm-platforms, Akhil P Oommen's (Qualcomm) a6xx patches in linux-next, SuperTurtleDev/iceland-mainline-kernel-linux (Yibo Wang). See [PATCHES.md](PATCHES.md) for each patch.
- **LIVI** (GPL-3.0, <https://github.com/f-io/LIVI>): the CarPlay and wireless Android Auto receiver, run unmodified and not included. The integration targets 9.4.0 and 10.0.0 and relies on upstream commit `b82707ad` (the Siri-over-Wi-Fi fix).
- **hostapd / wpa_supplicant** (<https://w1.fi/>) and the Linux **ath12k** driver: referenced and patched by the hotspot debugging tools.
- **kwin-effect-upscale** (Jens Koehler, JensKSP/kwin-effect-upscale, GPL-2.0-or-later): host of the SGSR port.
- **Snapdragon Game Super Resolution 1** (Qualcomm Innovation Center, Inc., BSD-3-Clause): source of `sgsr.frag`, which ports `sgsr/v1/include/glsl/sgsr1_shader_mobile.frag` from SnapdragonGameStudios/snapdragon-gsr.
- **KDE Plasma default wallpaper "Sub-Arctic"** (Krystian Zajdel, CC-BY-SA-4.0; `wallpapers/Next` in KDE's breeze repository): appears in some screenshots under `linux/dock/tests/shots/`. App icons in the screenshots are their owners' trademarks.
- **Plasma Mobile** mobiletaskswitcher (Devin Lin and others, GPL-2.0-or-later): base of the task cards.
- **KDE plasma-wayland-protocols** (LGPL-2.1-or-later): `blur.xml`, `fake-input.xml`.
- **Research references** (no code copied): icecream95/x1e-crash (`dczva-stress.c` independently reimplements its instruction sequence), justririll/x1e-sleep, the TF-A PSCI OS-initiated mode documentation, the CodeLinaro msm kernel (pci-msm), pciutils, systemd.

### External projects used but not included

The scripts download, build or call the following on the device; none of their code or binaries is included here, and each comes under its own license: bkerler/edl, KernelSU, LIVI, FEX and its x86 rootfs, Steam, Moonlight, wiliwili, kwin-effect-upscale, libva-v4l2, fcitx5, Plasma Mobile, Tailscale.

### Proprietary files not included

Firmware, vendor APKs and configuration files, ROM packages, EDL loader images, stock partition images and Apple MFi authentication material are not distributed with this repository. Where they are needed, only hashes and instructions are given; obtain them yourself through legitimate channels.

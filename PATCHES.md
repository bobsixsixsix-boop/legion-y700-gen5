# 内核补丁的来源

[English summary](#english-summary)

本文列出 `linux/kernel-y*/` 下每个内核补丁的作者、来源，以及本项目对它做过的处理。

- 外来补丁保留原作者的 `From:` 和 `Signed-off-by:`。在本地查不到原作者时，`From:` 行是占位名，出处一般写在补丁里加的一行 `Originally from:`；例外是 y15 起收的 1053、1054，它们原样保留 armada 的占位名 `From: Armada`，出处写在提交说明里的 `y700 (kernel y15): source …` 段落。
- `From:` 写作 `bobsixsixsix-boop` 或 `y700 workspace` 的补丁出自本项目，这是同一作者的两种署名。例外是表中注明「`From:` 为本项目的占位名」的 00y1、1049、1050：它们是外来补丁，原作者和出处见「作者」「来源」两列和补丁里的 `Originally from:`。
- `y700.patch`、`y700-y*.patch` 是某一代内核相对上游基线的**累积 diff**，不是单个补丁；其中各部分的来源见同一表格里的单个补丁。
- 「自有」指本项目自己写的补丁。除非另有说明，自有补丁都没有提交给上游。

各代内核的基线：

| 内核 | 基线 |
|---|---|
| y1–y4 | 上游 tb323fu-linux `kernel-t47`（Linux v7.3-rc4 加上游补丁 0001–0130） |
| y5–y13 | 上游 `kernel-t49`：源码与 t47 相同，配置改用 t49 的（多了 `baldur-extra.fragment`） |
| y14 | 上游 `kernel-t52`（Linux v7.3），2026-10-23 至 10-29 日常使用 |
| y15–y17 | 上游 `kernel-t52`（Linux v7.3）；y16、y17 的内置 initramfs 换成上游 `kernel-t54` 的 init。y17 在 2026-11-01 至 11-04 日常使用 |
| y18–y20 | 仍是 `kernel-t52`，加上上游 `kernel-t58` 的 0144、0147–0153（y19、y20 不带 0153）。y20 从 2026-11-04 起日常使用 |

## linux/kernel-y1

| 补丁 | 作者 | 来源 | 处理 |
|---|---|---|---|
| `y700.patch` | 本项目 | 自有：ath12k 的 wcn7860 MLO 模块参数、qcom_battmgr 修正 | 累积 diff，无邮件头 |

## linux/kernel-y2

| 补丁 | 作者 | 来源 | 处理 |
|---|---|---|---|
| `y700-y2.patch` | 混合 | y1 的内容，加上 iris 解码顺序 / 去块控制（见下一行） | 累积 diff |
| `upstream-patches/iris-decode-order-deblock-t47.patch` | Xilin Wu（原补丁） | code002-2/sm8750-video-accel 的 `0001-decode-order-deblock` | 本项目变基到 t47；无邮件头 |
| `upstream-patches/sm8750-video-accel-0001-decode-order-deblock.patch` | Xilin Wu | code002-2/sm8750-video-accel `0001-decode-order-deblock`（与 radxa-pkg/libva-v4l2 附带的内核补丁相同） | 加了 `Originally from:` |
| `upstream-patches/iceland-22011391.patch`、`iceland-a6e51c9c.patch`、`iceland-c0e9662b.patch`、`iceland-cb23870f.patch` | Yibo Wang | SuperTurtleDev/iceland-mainline-kernel-linux（一加 Pad 4 的主线内核）的对应提交 | 借鉴评估时保存的参考副本，原样 |
| `upstream-patches/tb323fu-0097-dpu-slave-first.patch` | Joonhoe Kim | tb323fu-linux 0097 | 与上游逐字相同 |
| `upstream-patches/tb323fu-0117-cpu-capacity.patch` | Joonhoe Kim | tb323fu-linux 0117 | 与上游逐字相同 |

## linux/kernel-y3

| 补丁 | 作者 | 来源 | 处理 |
|---|---|---|---|
| `y700-y3.patch` | 本项目 | y2 的内容，加上自有改动：qcom_battmgr 的 POWER_NOW 一律按电流 × 电压计算 | 累积 diff |

## linux/kernel-y4

| 补丁 | 作者 | 来源 | 处理 |
|---|---|---|---|
| `0540-arm64-signal-reapply-the-ssbs-policy-on-sigreturn-sm8850.patch` | 原作者未查明（`From:` 为占位名 Armada） | armada-os/armada 0540 | 本项目把 SM8850 的 Oryon part 0x002 加进默认开启的名单；加了 `Originally from:` |
| `0620-drm-msm-a6xx-hfi-irq-clears-only-the-cm3-fault.patch` | gennro | Kettle，经 armada-os/armada 0620 | 加了 `Originally from:` |
| `0621-drm-msm-a6xx-bound-the-gmu-wait-for-a-fault-devcoredump.patch` | gennro | Kettle，经 armada-os/armada 0621 | 加了 `Originally from:` |
| `0622-drm-msm-a6xx-mask-the-hfi-interrupt-before-booting-the-gmu.patch` | 原作者未查明（`From:` 为占位名 Armada） | armada-os/armada 0622 | 加了 `Originally from:` |
| `y700-y4.patch` | 混合 | y3 的内容，加上自有改动（ath12k 站点模式不再使用备用的 beacon-miss 定时器）和上面四个补丁 | 累积 diff |

## linux/kernel-y5

| 补丁 | 作者 | 来源 | 处理 |
|---|---|---|---|
| `y700-y5.patch` | 混合 | 与 y4 内容相同，改用上游 t49 的配置构建 | 累积 diff |

本目录的 `baldur-extra.fragment` 和 `config-tb323fu-t49` 是上游 t49 配置的副本。

## linux/kernel-y6

| 补丁 | 作者 | 来源 | 处理 |
|---|---|---|---|
| `1030-media-iris-send-the-stream-POC-type.patch` | Diogo Trindade | armada-os/armada PR #718（`b35cabd2`） | 原样 |
| `1031-media-iris-stop-AV1-tier-overwriting-HEVC-tier.patch` | Diogo Trindade | armada-os/armada PR #718（`b35cabd2`） | 原样 |
| `1032-media-iris-send-the-decoder-the-colour-info-the-firmware-reported.patch` | bobsixsixsix-boop | 自有，生成脚本为 `make-1032.py` | — |
| `y700-y6.patch` | 混合 | y5 的内容，加上 1030–1032 | 累积 diff |

## linux/kernel-y7

| 补丁 | 作者 | 来源 | 处理 |
|---|---|---|---|
| `1033-media-iris-send-the-decoder-the-bitstream-resolution-the-firmware-reported.patch` | bobsixsixsix-boop | 自有，生成脚本为 `make-1033.py` | — |
| `y700-y7.patch` | 混合 | y6 的内容，加上 1033 | 累积 diff |

## linux/kernel-y8（y8–y13）

| 补丁 | 作者 | 来源 | 处理 |
|---|---|---|---|
| `1041-ath12k-sta-ps-vif-cfg.patch` | 本项目（`y700 workspace`） | 自有，生成脚本为 `make-1041.py` | — |
| `1042-memlat-android-tuning.patch` | bobsixsixsix-boop | 自有；调优数值取自在厂商 Android BSP 上观察到的值 | — |
| `1043-cpuidle-psci-domain-allow_system_off.patch` | bobsixsixsix-boop | 自有；说明见 `Y10-NOTES.md` | — |
| `1044-arm64-errata-qcom-oryon-dc-zva-workaround.patch` | bobsixsixsix-boop | 参照 justririll/x1e-sleep 的 `x1-dc-zva-erratum-and-cl5.patch`，其中带有 Marc Zyngier 的树外勘误补丁（arm-platforms.git `7d6ed4b78a0c`） | 加了 `Originally from:`；草稿，未收进 y14 |
| `1045-pcie-qcom-l1ss-t-power-on-ltr-max.patch` | 本项目（`y700 workspace`） | 自有 | 草稿，未收进 y14 |
| `1046-drm-msm-a6xx-honor-perfmode_bw-threshold-on-a8x.patch` | Akhil P Oommen | linux-next（Qualcomm 的 `20260923-hawi-gpu-v1` 系列） | 原样 |
| `1047-drm-msm-a6xx-fix-secondary-rail-vote-in-arc-votes.patch` | Akhil P Oommen | 同上 | 原样 |
| `1048-drm-msm-a6xx-fix-rpmh-dependency-votes.patch` | Akhil P Oommen | 同上 | 原样 |
| `1049-media-iris-psc-last-not-error.patch` | 原作者未查明（`From:` 写 ArmadaOS 1370-iris-psc-last） | armada-os/armada `1370-iris-psc-last` | 加了 `Originally from:` |
| `1050-drm-msm-dpu-reject-undersized-gamma-lut.patch` | 原作者未查明 | h0cheung/tb322fc-linux-kernel `816d1a26`，它基于 xiaqinghuan 2026-10-13 发到 lore 的补丁 | 本项目变基；加了 `Originally from:` |
| `1051-media-iris-preserve-timestamps-on-error-buffers.patch` | Xilin Wu | radxa-pkg/libva-v4l2 `d5df780` 的 `patches/0004` | 原样 |
| `t51/0131-drm-msm-dpu-only-force-a-modeset-for-colour-manageme.patch` | Joonhoe Kim | tb323fu-linux kernel-t51 | 原样 |
| `t51/0132-power-supply-qcom_battmgr-expose-the-charge-current-l.patch` | Joonhoe Kim | tb323fu-linux kernel-t51 | 上下文变基（提交说明里写明）；`.patch.upstream` 是原文 |
| `y700-y8.patch` | 混合 | code002-2 的 iris 补丁、armada 0540 / 0622、gennro 0620 / 0621、Diogo Trindade 1030 / 1031，以及自有的 ath12k / battmgr 改动、1032、1033、1041 | 累积 diff；开头加了组成说明 |
| `y700-y9.patch` | 混合 | 与 `y700-y8.patch` 相同，再加 1042 | 累积 diff；开头加了组成说明 |

## linux/kernel-y14

按 `patches/series` 的应用顺序：

| 补丁 | 作者 | 来源 | 处理 |
|---|---|---|---|
| `00y1-media-iris-decode-order-display-delay-and-deblock-controls.patch` | Xilin Wu（原补丁；`From:` 为本项目的占位名） | code002-2/sm8750-video-accel `0001-decode-order-deblock`（与 radxa-pkg/libva-v4l2 附带的内核补丁相同） | 本项目变基；加了 `Originally from:` |
| `00y2-power-supply-qcom_battmgr-status-power_now-and-charge-units-on-kaanapali.patch` | bobsixsixsix-boop | 自有 | — |
| `00y3-wifi-ath12k-wcn7860-no-mlo-unless-asked.patch` | bobsixsixsix-boop | 自有 | — |
| `00y4-wifi-ath12k-wcn7860-5g-160-knob.patch` | bobsixsixsix-boop | 自有 | — |
| `00y5-wifi-ath12k-no-backup-beacon-miss-timer-for-stations.patch` | bobsixsixsix-boop | 自有 | — |
| `0540-arm64-signal-reapply-the-ssbs-policy-on-sigreturn-sm8850.patch` | 原作者未查明（`From:` 为占位名 Armada） | armada-os/armada 0540 | 扩展到 SM8850 的 part 0x002；加了 `Originally from:` |
| `0620-drm-msm-a6xx-hfi-irq-clears-only-the-cm3-fault.patch` | gennro | Kettle，经 armada-os/armada | 原样（`From:` 是原作者 gennro，补丁里没有 `Originally from:` 行） |
| `0621-drm-msm-a6xx-bound-the-gmu-wait-for-a-fault-devcoredump.patch` | gennro | Kettle，经 armada-os/armada | 原样（`From:` 是原作者 gennro，补丁里没有 `Originally from:` 行） |
| `0622-drm-msm-a6xx-mask-the-hfi-interrupt-before-booting-the-gmu.patch` | 原作者未查明（`From:` 为占位名 Armada） | armada-os/armada 0622 | 加了 `Originally from:` |
| `1030-media-iris-send-the-stream-POC-type.patch` | Diogo Trindade | armada-os/armada PR #718（`b35cabd2`） | 原样 |
| `1031-media-iris-stop-AV1-tier-overwriting-HEVC-tier.patch` | Diogo Trindade | armada-os/armada PR #718（`b35cabd2`） | 原样 |
| `1032-media-iris-send-the-decoder-the-colour-info-the-firmware-reported.patch` | bobsixsixsix-boop | 自有 | — |
| `1033-media-iris-send-the-decoder-the-bitstream-resolution-the-firmware-reported.patch` | bobsixsixsix-boop | 自有 | — |
| `1041-ath12k-sta-ps-vif-cfg.patch` | 本项目（`y700 workspace`） | 自有（`make-1041.py`） | — |
| `1042-memlat-android-tuning.patch` | bobsixsixsix-boop | 自有；调优数值取自在厂商 Android BSP 上观察到的值 | — |
| `1043-cpuidle-psci-domain-allow_system_off.patch` | bobsixsixsix-boop | 自有 | — |
| `1046-drm-msm-a6xx-honor-perfmode_bw-threshold-on-a8x.patch` | Akhil P Oommen | linux-next | 原样 |
| `1047-drm-msm-a6xx-fix-secondary-rail-vote-in-arc-votes.patch` | Akhil P Oommen | linux-next | 原样 |
| `1048-drm-msm-a6xx-fix-rpmh-dependency-votes.patch` | Akhil P Oommen | linux-next | 原样 |
| `1049-media-iris-psc-last-not-error.patch` | 原作者未查明（`From:` 为本项目的占位名） | armada-os/armada `1370-iris-psc-last` | 加了 `Originally from:` |
| `1050-drm-msm-dpu-reject-undersized-gamma-lut.patch` | 原作者未查明（`From:` 为本项目的占位名） | h0cheung/tb322fc-linux-kernel `816d1a26`，基于 xiaqinghuan 2026-10-13 发到 lore 的补丁 | 本项目变基；加了 `Originally from:` |
| `1051-media-iris-preserve-timestamps-on-error-buffers.patch` | Xilin Wu | radxa-pkg/libva-v4l2 `d5df780` 的 `patches/0004` | 原样 |

`prep/` 下是把补丁栈搬到 t52 时用的准备脚本，不是补丁。

## linux/kernel-y15

y14 的补丁去掉 1049，加上 1052–1057（顺序见 `patches/series`）。从 y14 沿用的补丁与 `linux/kernel-y14/patches/` 里的文件逐字节相同，作者和来源见上一节；下表只列新增的：

| 补丁 | 作者 | 来源 | 处理 |
|---|---|---|---|
| `1052-media-iris-recycle-decoder-buffers-for-non-display-pictures.patch` | Xilin Wu | radxa-pkg/libva-v4l2 `v1.1.1`（`35eff37`）的 `patches/0005` | 提交说明里加了一段来源说明；取代 1049（两者改同一处判断，不能叠加） |
| `1053-soc-qcom-smp2p-reset-inbound-state-only-on-restart.patch` | 原作者未查明（`From:` 为 armada 的占位名 Armada） | armada-os/armada 0569，由提交 `dac08dfe0a72`（virtudude）加入 | 原样；提交说明里加了一段来源说明 |
| `1054-HID-uhid-read-the-output-queue-under-qlock.patch` | 原作者未查明（`From:` 为 armada 的占位名 Armada） | armada-os/armada 1008，由提交 `f19400c38f65`（FeralAI）加入 | 原样；提交说明里加了一段来源说明 |
| `1055-wifi-ath12k-fix-single-pdev-frequency-ranges.patch` | Shenghan Gao | 发到 lore 的补丁（`20260715065218.41232-1-gsh20040816@gmail.com`），经 armada-os/armada 1021 | 原样；提交说明里加了一段来源说明 |
| `1056-arm64-dts-qcom-baldur-wifi-root-port-t-power-on-80us.patch` | bobsixsixsix-boop（`From:` 写作 `y700 workspace`） | 自有 | — |
| `1057-media-iris-vpu4x-size-the-AV1-line-buffer-for-10-bit-output.patch` | bobsixsixsix-boop（`From:` 写作 `y700 workspace`） | 自有 | — |

## linux/kernel-y16

y15 的补丁加上 1058；配置多开一项 `CONFIG_WATCHDOG_SYSFS`；内置 initramfs 的 `init` 换成上游 `kernel-t54` 的（`a9b1d5f`，构建时从上游取，不随附）。

| 补丁 | 作者 | 来源 | 处理 |
|---|---|---|---|
| `1058-firmware-qcom-scm-disable-SDI-when-download-mode-is-switched-off.patch` | bobsixsixsix-boop（`From:` 写作 `y700 workspace`） | 自有 | — |

## linux/kernel-y17

没有新补丁：内核与 y16 相同（同一棵树、同样的补丁和配置），只换了内置 initramfs 里的两个文件。

- `init`：上游 `kernel-t54` 的 init 加上挂根之前的磁盘检查 `rootfsck`。与上游一样以 MIT 发布，版权归 tb323fu-linux 的作者和本项目所有；`test-root-selection.sh` 是它的离线测试，同样派生自上游。
- `/bin/e2fsck`：构建时取自 Ubuntu 的 `e2fsck-static` 包，不随附。

## linux/kernel-y18

y16 的补丁加上上游 `kernel-t58` 的 8 个补丁；配置去掉命令行里的 `no_console_suspend`（随 0148），并设 `CONFIG_BOOTPARAM_HUNG_TASK_PANIC=0`（同 t58 的配置）。从 y16 沿用的补丁与 `linux/kernel-y16/patches/` 里的文件逐字节相同，下表只列新增的：

| 补丁 | 作者 | 来源 | 处理 |
|---|---|---|---|
| `0144-drm-panel-nt36523-baldur-report-the-panel-physical-size.patch` | Joonhoe Kim | 上游 tb323fu-linux `kernel-t58` 的同名补丁 | 原样 |
| `0147-usb-typec-ucsi-Leave-the-mux-to-the-altmode-driver-f.patch` … `0152-mmc-sd-Keep-the-card-when-its-extension-registers-fa.patch`（6 个） | Joonhoe Kim | 同上 | 原样 |
| `0153-input-nt36536-report-the-pen-tilt-in-the-screen-s-ax.patch` | Joonhoe Kim | 同上 | 改动的两行逐字节相同，只有上下文不同：上游是在 0145 之上切的，本项目没收 0145，所以对着 t52 的 `nt36xxx.c` 重切；提交说明里加了一段来源说明 |

## linux/kernel-y19

y18 去掉 0153（这台平板没有笔，验不了），其余补丁和配置与 y18 相同。

## linux/kernel-y20（当前内核）

没有新补丁：源码树与 y19 相同，配置多开一项 `CONFIG_HID_MAGICMOUSE=m`（来自 `linux/kernel-y8/owner-devices.fragment`，给 Magic Mouse 2 用）。

## linux/kernel-next（排队，还没编进任何内核）

| 补丁 | 作者 | 来源 | 处理 |
|---|---|---|---|
| `1059-arm64-dts-qcom-baldur-stats-hand-qcom_stats-the-AOSS-QMP.patch` | bobsixsixsix-boop（`From:` 写作 `y700 workspace`） | 自有 | — |

## 其他目录里的补丁

这些补丁不在 `linux/kernel-y*/` 下，许可证随它们所修改的项目：

| 补丁 | 修改的对象 | 许可证 | 状态 |
|---|---|---|---|
| `linux/audio/1050-arm64-dts-qcom-baldur-audio-aw882xx-fade-flag.DRAFT.patch` | 上游设备树 `baldur-audio.dtsi` | BSD-3-Clause | 草稿 |
| `linux/audio/aw882xx-mute-on-trigger.DRAFT.patch`、`aw882xx-quiet-stream-log.DRAFT.patch` | 上游的树外 aw882xx 驱动 | GPL-2.0-only | 草稿 |
| `linux/power/soc-qcom-ice-runtime-pm.DRAFT.patch` | 内核 `drivers/soc/qcom/ice.c` | GPL-2.0-only | 草稿，没有编译，也没有上机验证 |
| `linux/wifi/ath12k-wcn7860-mlo-param.patch` | 内核 ath12k 驱动 | GPL-2.0-only | — |
| `linux/power/helperd-slow-poll.patch` | 上游 helper（`helper-v0.4.2`） | GPL-3.0-or-later | 没有编译、没有安装；没有提交给上游 |
| `linux/power/keyhold-event-driven.patch` | 上游 `userspace/platform/src/keyhold.c` | MIT | 没有编译，也没有上机验证；没有提交给上游 |
| `linux/games/sgsr/kwin-effect-upscale-sgsr.patch` | kwin-effect-upscale | GPL-2.0-or-later | — |
| `linux/gesture/taskswitcher/y700-taskswitcher.patch` | Plasma Mobile 的 mobiletaskswitcher | GPL-2.0-or-later | — |
| `linux/video/wiliwili-*.patch` | wiliwili（其中一个改的是它内嵌的 glfw） | 本项目的改动按仓库默认许可证；上下文行属于原项目 | — |
| `linux/video/libva-v4l2-patches/retired/0001-*.patch` | libva-v4l2 | 同上 | 已退役：y15 的 1052 在内核一侧修好了同一个问题 |
| `linux/camera/patches/y700-0001-*.patch` … `y700-0005-*.patch` | libcamera 0.7.0（Ubuntu 26.04 的包） | LGPL-2.1-or-later，与 libcamera 相同 | 0001–0004 来自 mzakamin-hub/iceland-mainline `990a0597` 的 `packaging/libcamera/`（作者 Osilvfe、mzak，见各补丁的 `Author:` 和 `Origin:`），其中 0002 手工移植到 0.7.0；0005 自有 |
| `linux/audio/osk-click-stream-mute.DRAFT.patch` | 本仓库自己的代码 | GPL-3.0-or-later | 草稿 |

## 许可证

`linux/kernel-*/` 下的补丁（包括累积 diff 和 `.patch.upstream` 原文）以及内核配置，与 Linux 内核一样以 GPL-2.0-only 发布，版权归各补丁 `From:` 和 `Signed-off-by:` 中列出的作者所有。补丁所修改的文件保留各自原有的许可证标识，例如设备树文件的 BSD-3-Clause；作为整体，这些补丁按 GPL-2.0-only 提供。许可证全文见 `LICENSES/GPL-2.0-only.txt`，各文件的许可证见 [REUSE.toml](REUSE.toml)。

## English summary

This file records, for every kernel patch under `linux/kernel-y*/`, its author, its origin and what this project did to it. Imported patches keep their original `From:` and `Signed-off-by:` lines; where the original author could not be found locally, the `From:` line is a placeholder and an `Originally from:` line names the source (for 1053 and 1054, which keep armada's placeholder `From: Armada`, the `y700 (kernel y15): source …` paragraph of the commit message does). Patches signed `bobsixsixsix-boop` or `y700 workspace` are this project's own, except 00y1, 1049 and 1050, whose `y700 workspace` From: is a placeholder for an imported patch (origin in the table); most of the project's own patches have not been submitted upstream. `y700.patch` and `y700-y*.patch` are cumulative diffs of one kernel generation against its upstream base, not single patches.

Bases: y1–y4 on upstream tb323fu-linux `kernel-t47` (Linux v7.3-rc4 plus upstream patches 0001–0130); y5–y13 on upstream `kernel-t49`, which is the t47 source with the t49 configuration (adding `baldur-extra.fragment`); y14, in daily use from 2026-10-23 to 10-29, and y15–y20 on `kernel-t52` (Linux v7.3). y15 drops 1049 and adds 1052–1057; y16 adds 1058, `CONFIG_WATCHDOG_SYSFS` and upstream `kernel-t54`'s initramfs init; y17, in daily use from 2026-11-01 to 11-04, is y16's kernel unchanged with a boot-time root file system check added to that init (MIT, like upstream). y18 adds upstream `kernel-t58`'s 0144 and 0147–0153 (Joonhoe Kim; 0153 re-cut against t52 because 0145 is not carried), drops `no_console_suspend` from the command line and sets `CONFIG_BOOTPARAM_HUNG_TASK_PANIC=0`; y19 is y18 without 0153; y20, in daily use since 2026-11-04, is y19's tree with `CONFIG_HID_MAGICMOUSE=m`. `linux/kernel-next/` queues patches for the next kernel (1059, this project's own); none of them is built yet.

Third-party sources: tb323fu-linux (Joonhoe Kim: 0097, 0117, 0131, 0132, 0144, 0147–0153), armada-os/armada (0540, 0622, 1049; also the channel for gennro's 0620 / 0621 from Kettle and Diogo Trindade's 1030 / 1031 from PR #718), code002-2/sm8750-video-accel (Xilin Wu: the iris decode-order / deblock controls, 00y1), radxa-pkg/libva-v4l2 (Xilin Wu: 1051, and 1052 from tag v1.1.1), armada-os/armada 0569 and 1008 (1053, 1054; original authors unknown), Shenghan Gao's ath12k patch on lore, carried by armada as 1021 (1055), h0cheung/tb322fc-linux-kernel after xiaqinghuan's lore patch (1050), justririll/x1e-sleep with Marc Zyngier's out-of-tree erratum (1044), linux-next (Akhil P Oommen: 1046–1048), and reference copies from SuperTurtleDev/iceland-mainline-kernel-linux (Yibo Wang).

License: the patches under `linux/kernel-*/` (including cumulative diffs and `.patch.upstream` originals) and the kernel configuration are released under GPL-2.0-only, like the Linux kernel, with copyright held by the authors named in each patch's `From:` and `Signed-off-by:` lines. The files they touch keep their own license identifiers (for example BSD-3-Clause for device-tree files); taken as a whole, the patches are offered under GPL-2.0-only. Patches in other directories follow the license of the project they modify, as listed in the table above; the libcamera patches under `linux/camera/patches/` are LGPL-2.1-or-later, 0001–0004 by Osilvfe and mzak from mzakamin-hub/iceland-mainline (0002 hand-ported to 0.7.0) and 0005 this project's own.

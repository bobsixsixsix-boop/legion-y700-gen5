# 内核补丁的来源

[English summary](#english-summary)

本文列出 `linux/kernel-y*/` 下每个内核补丁的作者、来源，以及本项目对它做过的处理。

- 外来补丁保留原作者的 `From:` 和 `Signed-off-by:`。在本地查不到原作者时，补丁里加了一行 `Originally from:` 写明出处，`From:` 行则是占位名。
- `From:` 写作 `bobsixsixsix-boop` 或 `y700 workspace` 的补丁出自本项目，这是同一作者的两种署名。例外是表中注明「`From:` 为本项目的占位名」的 00y1、1049、1050：它们是外来补丁，原作者和出处见「作者」「来源」两列和补丁里的 `Originally from:`。
- `y700.patch`、`y700-y*.patch` 是某一代内核相对上游基线的**累积 diff**，不是单个补丁；其中各部分的来源见同一表格里的单个补丁。
- 「自有」指本项目自己写的补丁。除非另有说明，自有补丁都没有提交给上游。

各代内核的基线：

| 内核 | 基线 |
|---|---|
| y1–y4 | 上游 tb323fu-linux `kernel-t47`（Linux v7.3-rc4 加上游补丁 0001–0130） |
| y5–y13 | 上游 `kernel-t49`：源码与 t47 相同，配置改用 t49 的（多了 `baldur-extra.fragment`） |
| y14 | 上游 `kernel-t52`（Linux v7.3），2026-10-23 起日常使用 |

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

## linux/kernel-y14（当前内核）

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

## 其他目录里的补丁

这些补丁不在 `linux/kernel-y*/` 下，许可证随它们所修改的项目：

| 补丁 | 修改的对象 | 许可证 | 状态 |
|---|---|---|---|
| `linux/audio/1050-arm64-dts-qcom-baldur-audio-aw882xx-fade-flag.DRAFT.patch` | 上游设备树 `baldur-audio.dtsi` | BSD-3-Clause | 草稿 |
| `linux/audio/aw882xx-mute-on-trigger.DRAFT.patch`、`aw882xx-quiet-stream-log.DRAFT.patch` | 上游的树外 aw882xx 驱动 | GPL-2.0-only | 草稿 |
| `linux/power/soc-qcom-ice-runtime-pm.DRAFT.patch` | 内核 `drivers/soc/qcom/ice.c` | GPL-2.0-only | 草稿，没有编译，也没有上机验证 |
| `linux/wifi/ath12k-wcn7860-mlo-param.patch` | 内核 ath12k 驱动 | GPL-2.0-only | — |
| `linux/power/helperd-slow-poll.patch` | 上游 helper（main `0c7c0c4`） | GPL-3.0-or-later | 没有提交给上游 |
| `linux/power/keyhold-event-driven.patch` | 上游 `userspace/platform/src/keyhold.c` | MIT | 没有编译，也没有上机验证；没有提交给上游 |
| `linux/games/sgsr/kwin-effect-upscale-sgsr.patch` | kwin-effect-upscale | GPL-2.0-or-later | — |
| `linux/gesture/taskswitcher/y700-taskswitcher.patch` | Plasma Mobile 的 mobiletaskswitcher | GPL-2.0-or-later | — |
| `linux/video/wiliwili-*.patch` | wiliwili（其中一个改的是它内嵌的 glfw） | 本项目的改动按仓库默认许可证；上下文行属于原项目 | — |
| `linux/video/libva-v4l2-patches/0001-*.patch` | libva-v4l2 | 同上 | — |
| `linux/audio/osk-click-stream-mute.DRAFT.patch`、`linux/net/y700-checklist-kmsg-watch.patch` | 本仓库自己的代码 | GPL-3.0-or-later | 草稿 / — |

## 许可证

`linux/kernel-*/` 下的补丁（包括累积 diff 和 `.patch.upstream` 原文）以及内核配置，与 Linux 内核一样以 GPL-2.0-only 发布，版权归各补丁 `From:` 和 `Signed-off-by:` 中列出的作者所有。补丁所修改的文件保留各自原有的许可证标识，例如设备树文件的 BSD-3-Clause；作为整体，这些补丁按 GPL-2.0-only 提供。许可证全文见 `LICENSES/GPL-2.0-only.txt`，各文件的许可证见 [REUSE.toml](REUSE.toml)。

## English summary

This file records, for every kernel patch under `linux/kernel-y*/`, its author, its origin and what this project did to it. Imported patches keep their original `From:` and `Signed-off-by:` lines; where the original author could not be found locally, an `Originally from:` line names the source and the `From:` line is a placeholder. Patches signed `bobsixsixsix-boop` or `y700 workspace` are this project's own, except 00y1, 1049 and 1050, whose `y700 workspace` From: is a placeholder for an imported patch (origin in the table); most of the project's own patches have not been submitted upstream. `y700.patch` and `y700-y*.patch` are cumulative diffs of one kernel generation against its upstream base, not single patches.

Bases: y1–y4 on upstream tb323fu-linux `kernel-t47` (Linux v7.3-rc4 plus upstream patches 0001–0130); y5–y13 on upstream `kernel-t49`, which is the t47 source with the t49 configuration (adding `baldur-extra.fragment`); y14, in daily use since 2026-10-23, on `kernel-t52` (Linux v7.3).

Third-party sources: tb323fu-linux (Joonhoe Kim: 0097, 0117, 0131, 0132), armada-os/armada (0540, 0622, 1049; also the channel for gennro's 0620 / 0621 from Kettle and Diogo Trindade's 1030 / 1031 from PR #718), code002-2/sm8750-video-accel (Xilin Wu: the iris decode-order / deblock controls, 00y1), radxa-pkg/libva-v4l2 (Xilin Wu: 1051), h0cheung/tb322fc-linux-kernel after xiaqinghuan's lore patch (1050), justririll/x1e-sleep with Marc Zyngier's out-of-tree erratum (1044), linux-next (Akhil P Oommen: 1046–1048), and reference copies from SuperTurtleDev/iceland-mainline-kernel-linux (Yibo Wang).

License: the patches under `linux/kernel-*/` (including cumulative diffs and `.patch.upstream` originals) and the kernel configuration are released under GPL-2.0-only, like the Linux kernel, with copyright held by the authors named in each patch's `From:` and `Signed-off-by:` lines. The files they touch keep their own license identifiers (for example BSD-3-Clause for device-tree files); taken as a whole, the patches are offered under GPL-2.0-only. Patches in other directories follow the license of the project they modify, as listed in the table above.

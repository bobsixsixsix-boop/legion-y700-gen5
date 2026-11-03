# 内核 y15：y14 去掉 1049，加 1052–1057

2026-10-28 在 Win11 上**离线准备**：补丁、建分支脚本、构建脚本、体检脚本都写好并在本机模拟过。10-29 凌晨在 y14 上跑了 AV1 10-bit 探针，据此加了 1057。**10-29 01:0x 体检 ALL PASS 后已 keep，现役 good 是 `7.3.0-tb323fu-t52-y15`；熄屏过一夜后 09:33 再体检也 ALL PASS**（见下「上机结果」）。y14 的产物还在 `/usr/local/src/y700-kernel-y14/`，回退办法见「回滚」。

y15 = y14 的 22 个补丁 **去掉 1049**，再加六个：

- **1052**：radxa 的 iris NOSHOW 回收（顶替 1049）；
- **1053**：smp2p；
- **1054**：uhid；
- **1055**：ath12k 频段范围；
- **1056**：Wi‑Fi 根端口 `t-power-on-us = <80>`，只有 DT 这一行；
- **1057**：vpu4x 的 AV1 LINE 缓冲按 10-bit 加大（本仓自写，见下文「1057」）。

底座不变，仍是 v7.3 + 上游 joonhoekim/tb323fu-linux `kernel-t52`（`t52-base`）。配置除了标识版本的那一行，和 y14 完全一样。release 名是 `7.3.0-tb323fu-t52-y15`。

## 上机结果（10-29）

- 00:4x 编好（`/root/y700-kernel-y15.log` 末行 `KFULL_OK`），trial 安装后 00:43 重启进 y15（开机后 `uname -r` = `7.3.0-tb323fu-t52-y15`，trial「start 1 of 2」）。
- **第一次体检**（00:45，`runs/kernel/y15-verify-20261029-0045.log`）：110 PASS、1 FAIL、1 SKIP。挂的是 `1055: connected to HOME_6G by itself`，**体检脚本自己的错**：
  - 根因：平板 root 的语言是 `LANG=zh_CN.UTF-8`，`nmcli -t -f ACTIVE,SSID` 即使在 terse 模式下也把 ACTIVE 翻译成「是/否」，打出 `是:HOME_6G`，脚本找的是 `yes:HOME_6G`。同一份日志的 INFO 行里 `iw` 显示正连着 HOME_6G（6295 MHz、320 MHz EHT）。同一个变量还让 60 s ping 被 SKIP 了。
  - 同一次还发现 1056 的 AER 计数把开机那行 `AER: enabled with IRQ` 也算了进去（计数 1，其实没有任何 AER 错误）。
  - 修法：那一行 nmcli 前加 `LC_ALL=C`；AER 计数排除 `AER: enabled with IRQ`。`nmcli -t -f DEVICE,STATE` 那一项（y14 带过来的）实测仍打英文 `connected`，没动。
- **第二次体检**（00:47，同一次开机，`runs/kernel/y15-verify-20261029-0047.log`）：**ALL PASS，111 项 PASS**，rc 0。和第一次比只有计数、耗时之类的正常抖动（vblank timeout 0 → 2，y14 一次开机是 4）。要点：
  - **1052**：vp9-hidden-check 自己选了 `mode=recycle`，在现装的 2de1857 上全过。`clean` 两项里 empty CAPTURE 和 no-show matched 都是 0，说明内核把每个干净的 NOSHOW 都回收了；`error-hidden` 恰好 1 帧灰、没有超时。也就是 NOTES 下文「和 VA 驱动的耦合」里推理的那条路径，这次实测成立。vaapi-check 7 条流逐帧一致，error-recovery 34 PASS（和 y14 一样）。
  - **1057**：AV1 10-bit 五个合成流 **5/5** 起播并和 dav1d 逐字节一致（y14 是 1/5），c1440p10-sb128 也过了；8-bit 两个对照照旧。
  - **1053**：10 s 里 smp2p-adsp +45、q6v5 ready +0；开机以来 smp2p-adsp 1102 次，ready 一直是 1。rc4 上两者同涨（10-21：60 s 各 273）。
  - **1055**：JP、HOME_6G、三个频段都扫得到；`ping -c 300 -i 0.2 192.168.0.1` **0 % 丢包**（rtt 平均 12.2 ms、最大 62 ms）。
  - **1056**：活动设备树里恰好一个 `t-power-on-us`，在 Wi‑Fi 根端口下，值 80；lspci 根端口 `PortTPowerOnTime=80us`，两端 `LTR1.2_Threshold=156672ns`、`T_PwrOn=80us`，和按 aspm.c 公式算的一样；AER 错误 0 行。
  - y14 的其余检查（GMU/RPMh、1043/0118 默认值与切换、t52 的 USB-C/DP/UFS、外设）全部照过。
- **keep 之前的独立复核**（3 个视角各读日志和脚本、每条发现再由一个反驳者核对，不连平板）：12 条发现，1 条被驳回，11 条全是 note，没有挡 keep 的。要点和处理：
  - **两次体检都在开机后 6 分钟内、亮屏时跑**，y14 是开机 1.4 h、cx-auto 已经开过 E3a 之后才 keep 的。实际上 y15 在 00:49:43–00:57:51 已经被 cx-auto 开过一次 E3a（熄屏 8 分钟），期间内核 err 级只有 3 行 GMU `delay in fenced register write`（y10 基线约 16/h），没有 AER、remoteproc、q6v5、ath12k 错误；亮屏时一对 `vblank timeout` + `wait for commit done returned -110`，和 y14 在亮灭屏时成对出现的一样（0204 留着没收）。熄屏过夜后的体检仍列为待办（README「内核 y15」）。
  - **vp9-hidden-check 的 `error-hidden-export` 现在走 0001 的 1 s 兜底**（y14 557 ms，y15 约 2.0 s，`no-picture fallback 1`）。这是「和 VA 驱动的耦合」里预计的：recycle 内核 + 2de1857 时，隐藏帧 token 上的画面出错，在持久导出（Chrome 那种）表面上要多卡约 1.3 s，直到装上 v1.1.1。装完 v1.1.1 重跑时，应当变成 `no-picture fallback 0`、耗时接近 clean-export。
  - 其余（探针退出码、ath12k 模块身份、物理层监管域、平板上 vaapi-check.sh 是 10-23 旧版没有 AV1 流、fenced-write 速率按取整后的小时数算）记在下文「体检脚本的已知不足」。
- **01:0x `tb323fu-ctl kernel keep`**：good = `7.3.0-tb323fu-t52-y15`，state idle。
- **按复核改进体检脚本后的第三次体检**（01:04，`runs/kernel/y15-verify-20261029-0104.log`）：新加的几项全部 PASS（探针跑完且标着本内核、探针期间 iris err 0 行、ath12k 和 uhid.ko 是这次编的、Wi‑Fi 物理层 JP），也打出了「平板上的 vaapi-check.sh 是旧版」的提示；1043/0118 开机默认值那几项因为 cx-auto 开过一次 E3a 而按设计 SKIP（改查「现在没 armed、两个旋钮都关着」，PASS）。
  - **冒出一项 FAIL：`1050: KWin reports no failed atomic test/commit this boot (got 1)`**。查明不是回归：那一行是 00:59:42 平板正被使用（任务切换器）时 KWin 的 `atomic commit failed: 设备或资源忙`（EBUSY，上一帧没翻完又提交）。之前几次开机也有：y14 上一次（10-27～10-29）0 次、再上一次 2 次（EBUSY 1、`权限不够` 1），y13 两次开机 3 次和 1 次，都是 EBUSY 为主。1050 只会让 atomic check 返回 EINVAL（gamma LUT 长度不对）。
  - **修法**：这一项改成只有 EINVAL（`Invalid argument` / KWin 中文 locale 下的 `无效的参数`）才 FAIL，其余失败按原因计数打 INFO。原来的写法开机后只要有人用过平板就可能误报。在平板上用真日志和两组假数据（含一条中文 EINVAL、空日志）测过，结论都对。
  - 这次体检开跑时（01:04）平板正在播放视频，体检里的解码测试和播放重叠了，结果照样都过。此后**不在平板被使用时跑整套体检**；改好的脚本留到熄屏过一夜后再跑（README「内核 y15」待办）。
  - 同一段时间里的 vblank timeout 对（00:58:11、01:02:08、01:02:18、01:03:57）都落在亮屏、切应用、开始播放视频（刷新率跟随视频会切模式）的时刻，kmsg-watch 在 01:02:13 按设计起了一次显示看门狗。y15 没动显示路径（1050 是 y13 起就有的）；上一次 y14 开机 30 h 里是 14 行，要在熄屏过夜后的体检里再比一次。
- **熄屏过一夜后的第四次体检**（09:33，`runs/kernel/y15-verify-20261029-0933.log`）：**ALL PASS，106 PASS、1 SKIP**，rc 0。
  - 条件：
    - 同一次开机，已开 8.8 h；用的是最终版脚本，平板上的 sha256 `ca1af1c6…` 和仓库一致。
    - 03:00:53 起 cx-auto 一直开着 E3a（熄屏、用电池），夜里还跑了镜头熄屏功耗对比（`linux/camera/README.md`）。
    - 体检时屏幕仍熄着，平板没人在用。
  - **cx-auto 那一支**：1043/0118 开机默认值那几项按设计 SKIP（本次开机 armed 过 2 次）。改查「现在 armed、两个旋钮都开着」，PASS。
  - **夜里没复位**：开机 id 没变，「no previous-boot crash」PASS。
  - **vblank timeout 一行没加**：计数仍是 10，全是 00:47–01:03:57 亮屏操作时的那 5 对（y14 上一次开机 30 h 里 14 行）。
  - **GMU fenced-write**：01:04 时 8 行，09:33 时 10 行，夜里 8.5 h 只多 2 行。整次开机 1.1/h（y14 2.1/h，y10 基线约 16/h）。
  - **AER 0 行**。remoteproc 都正常（soccp attached，adsp、cdsp running）。
  - **1053**：开机以来 smp2p-adsp 34847 次，q6v5 ready 仍是 1。00:47 那次是 1102 次对 1，夜里 ADSP 又通知了三万多次，ready 一次没重放。体检那 10 s 里 ADSP 恰好没通知，INFO 判 inconclusive，不影响结论。
  - **装上 v1.1.1 之后第一次跑整套**：
    - vaapi-check 8 条流（含 AV1）PASS。
    - vp9-hidden-check recycle PASS，所有用例 `no-picture fallback 0`。`error-hidden-export` 559 ms，和 clean-export 的 552 ms 持平；01:04 在 2de1857 上是 3152 ms、fallback 1。也就是上面「和 VA 驱动的耦合」里预计的收尾，这次实测成立。
    - error-recovery 34 PASS（20 s）。
    - 1057 探针 10-bit 5/5。
  - **1055**：HOME_6G 6295 MHz、320 MHz EHT；`ping -c 300` 0 % 丢包，rtt 平均 13.7 ms、最大 32 ms。
    - 缓存扫描 2.4/5/6 GHz 是 0/0/1，和 01:04 那次一样；00:47 那次是 15/9/2。`--rescan no` 读的是 NetworkManager 的缓存，开机一阵后缓存里多半只剩连着的网络。这个数不代表扫不到别的频段，判据本来也只是 INFO。
  - **1050**：本次开机 KWin 有 1 次 atomic 失败，就是 00:59 那次 EBUSY，打 INFO；EINVAL 0，PASS。
  - 到此 y15 的上机验证做完：熄屏一夜，解码、Wi‑Fi、GPU、ADSP 都没出问题。

10-29 00:3x 在平板上跑了 `prep/y15-branch.sh`：`Y15_BRANCH_OK`，`Y15_HEAD=77a55c5a723e99fc847feb6afcbb706427c4106b`，`Y15_TREE=9a591ab91e1e80714587b233ad7459b07928c26e`，已钉进 `kbuild-y15.sh` 第 37 行（之前是占位符 `__FILL_AFTER_PREP__`，脚本拒绝运行）；`CHECK_ONLY=1` 得到 `CHECK_ONLY_OK`。第一次跑在导出比对上停过一次，原因和修法见「为什么用 cherry-pick 重放」一节末尾。

## 内容

| 编号 | 提交标题 | 来源 | 做什么 | 运行时怎么看（`y15-verify.sh`） |
|---|---|---|---|---|
| ~~1049~~ | media: iris: don't flag an empty PSC_LAST buffer as an error | 我们 y13 起的自有补丁 | **y15 去掉**。1052 改的是同一处空负载判断，新条件已经覆盖 1049 的情形，两者叠不上 | 补丁存档里不能再有 1049 那行 |
| 1052 | media: iris: Recycle decoder buffers for non-display pictures | radxa-pkg/libva-v4l2（现名 qcom-va-driver）tag **v1.1.1（35eff37）** 的 `patches/0005`，作者 Xilin Wu | 解码器收到干净的 NOSHOW CAPTURE 缓冲（VP9 的 alt-ref、AV1 的隐藏参考帧）时，在驱动里直接重新排队，不再作为「空的 ERROR 缓冲」交给用户态；真损坏和 overflow 照旧报错；LAST 缓冲不再被当成空错误 | `vp9-hidden-check.sh` 自己按 `uname -r` 选出 `mode=recycle` 并 PASS；`vaapi-check.sh` 全过；补丁存档里有对应的几行 |
| 1053 | soc: qcom: smp2p: reset inbound state only on restart | armada-os/armada 提交 `dac08dfe0a72` 加的 `0569`，补丁标注「upstream: not submitted」 | `qcom_smp2p_check_ssr()` 只在真检测到远端重启时，才清入站项的 last_value。之前每来一次 ADSP 通知都清，于是每个已置位的位都被当成新的上升沿重放一遍 | INFO：10 s 内 `smp2p-adsp` 照常涨，`q6v5 ready (adsp)` 不涨。CHECK：开机以来没有 "Handover signaled, but it already happened"，没有 remoteproc 处于 crashed |
| 1054 | HID: uhid: read the output queue under qlock | armada 提交 `f19400c38f65` 加的 `1008`，标注「upstream: local」 | `uhid_char_read()` 改成在 qlock 下读队列槽位。原来不加锁地读，在弱内存序 CPU 上可能读到 NULL，进而在 `copy_to_user` 里 oops | 只有 INFO（CONFIG_UHID、模块、`/dev/uhid`）。这里没有复现手段，是预防性修复 |
| 1055 | wifi: ath12k: fix frequency range for single-pdev devices | armada main 上的 `1021`（= lore `20260715065218.41232-1-gsh20040816@gmail.com`，作者 Shenghan Gao） | `cap.band[]` 改用 `NL80211_BAND_*` 作下标（WMI 的位标志不是下标）；单 pdev 同时覆盖 5/6 GHz 时也把 5 GHz 的范围算进去 | CHECK：监管域 JP，HOME_6G 自动连上。INFO：三个频段各扫到几个网、`ping -c 300 -i 0.2 192.168.0.1` 的结果。全照 `linux/wifi/5GHZ-ARMADA-594-EVAL.md` |
| 1056 | arm64: dts: qcom: baldur-wifi: give the Wi-Fi root port T_POWER_ON = 80 us | 本仓 `linux/kernel-y8/1045-pcie-qcom-l1ss-t-power-on-ltr-max.patch` 的**第一部分**，即 `baldur-wifi.dtsi` 那一块，逐字节照搬 | 给 `&pcie_port0` 加 `t-power-on-us = <80>;`。v7.3 的 pcie-qcom（`e9769bb17269`）会把它写进根端口的 L1SS capability | CHECK：活动设备树里恰好一个 `t-power-on-us`，挂在 `wifi@0` 为 `pci17cb,110e` 的那个根端口下，值是 `0x00000050`；`lspci` 显示根端口 `PortTPowerOnTime=80us`。INFO：L1.2 阈值和 T_PwrOn、AER 行数 |
| 1057 | media: iris: vpu4x: size the AV1 line buffer for 10-bit output | **本仓自写**（作者 `y700 workspace`），10-29 由 `av1-10bit-probe.sh` 在 y14 上的结果定下 | vpu4x 的 AV1 LINE 缓冲原来直接用共用的 `hfi_buffer_line_av1d()`，不看位深；改成 `hfi_vpu4x_buffer_line_av1d()`，10-bit 输出时再加每管线一份 DPB/OPB（按 128×128 超块算）。8-bit 和其他编码格式的尺寸不变 | CHECK：补丁存档里有对应行；`av1-10bit-probe.sh` 的两个 8-bit 对照照常起播、和 dav1d 逐字节一致。INFO：五个 10-bit 合成流有几个起播并一致（y14 是 1/5，5/5 说明修好了） |

`patches/series` 的顺序：

1. y14 的前 19 个（`00y1` … `1048`），文件逐字节就是 y14 的；
2. `1050`、`1051`；
3. `1052` … `1057`。

一共 27 个。

## 1057：AV1 10-bit 的 LINE 缓冲（10-29）

**现象**（10-28，y14 + qcom-va-driver v1.1.1 测试构建，上游 `tests/decoder/av1.py` 逐个跑）：1080p10、tiles10、still10 三个 10-bit 用例在 START 时被固件拒绝，日志依次是 `session error received 0x1000005`、`0x4000005: insufficient resources`、之后每个缓冲都是 `0x4000004`。4k10、1080p10-lookahead 却能起播。这和 0111（HEVC Main10 / VP9 p2 的 LINE 缓冲）修好前的样子一模一样。

**读码**：`iris_vpu4x_dec_line_size()` 给 H265、VP9 传了 `ten_bit`，它们的 vpu4x 公式里有 `size_dpb_opb(h, lcu, ten_bit) * num_vpp_pipes` 这一项；AV1 那一支直接调共用的 `hfi_buffer_line_av1d()`，既不看位深，也没有这一项（split 模式下它把整个缓冲翻倍）。

**探针**（`av1-10bit-probe.sh`，10-29 00:30 在 y14 上跑，平板本机 ffmpeg 8.0.1 / libaom 3.13.1 编 5 帧实时流，经 VA-API 用测试构建硬解，和 dav1d 比）：

| 用例 | 超块 | 结果 | 按「LINE 缓冲少一项」模型的预测 |
|---|---|---|---|
| c720p8-sb64（对照） | 64 | 起播，和 dav1d 一致 | 起播 |
| c720p10-sb64 | 64 | START 失败 | 失败 |
| c720p10-sb128 | 128 | START 失败 | 失败 |
| c1080p8-sb128（对照） | 128 | 起播，一致 | 起播 |
| c1080p10-sb64 | 64 | 起播，一致 | 起播 |
| c1080p10-sb128 | 128 | START 失败 | 失败 |
| c1440p10-sb128 | 128 | START 失败 | 起播（余量只有 13 KB） |
| 原来的 1080p10 / tiles10 / still10 | — | START 失败 | 失败 |
| 原来的 4k10 / 1080p10-lookahead | — | 起播 | 起播 |

- **关键对照**：同是 1080p 10-bit，64 超块能起、128 超块不能。缺口随超块和高度变，不随整帧大小变（4K 反而能起，因为内核那份翻倍主要随宽度涨）。这符合 LINE 缓冲；按整帧算的缓冲（BIN、COMV 等）应该是 4K 先挂。
- **没拿到固件自己的话**：动态调试打开了 `iris_hfi_gen2_flush_debug_queue`，但没有 `Attach Internal Memory type 8 … calculated/assigned` 那种行，所以「是 type 8」是推断。
- **模型偏小一点**：1440p 预测余量 13 KB 能起，实际挂了，说明真实需求比拟合的略大。1057 加的量是 0.57 MiB（720p）到 1.6 MiB（4K），是模型缺口的几十倍，盖得住。
- **为什么敢收**：只有 10-bit AV1 会话的 LINE 尺寸变了，而这些会话现在本来就起不了播；8-bit 和别的编码格式一个字节都不变。代价是每个 10-bit 会话多占不到 2 MiB。
- **上游**：mainline 大概也有同样的缺口（0085 来自 infiniti-mainline，同样走共用函数），没核实。补丁没有 Signed-off-by，要往外发得作者点头。
- **怎么确认修好**：y15 体检里会再跑一遍探针（INFO 应该是 5/5），装 v1.1.1 后再跑 `tests/decoder/av1.py --extended`。
- 修不好也不是回归：体检只把 8-bit 对照当 CHECK。Chrome 本来就只放行 8-bit AV1（扩展 no-av1.js v1.6）。

## 文件

| 路径 | 是什么 |
|---|---|
| `patches/` | 27 个补丁和 `series`。其中 21 个（00y1…1048、1050、1051）**逐字节等于** `linux/kernel-y14/patches/` 里的同名文件。1052–1056 是 Win11 模拟仓库里提交后 `git format-patch` 的导出件（`--abbrev=9`，同 y14），之后 1053 的 y700 段落又手改过一次（只改说明文字，见下文「1053 说明的更正」）。1057 是在 y14 子集副本上提交后 `git format-patch` 的导出件 |
| `prep/y15-branch.sh` | 在平板上建 y15 分支（一个补丁一个提交，checkout 好），导出到 `/root/y15-export/`，再和输入逐个比。最后打印 `Y15_HEAD=`、`Y15_TREE=` 和 `Y15_BRANCH_OK`。内嵌 28 个文件的 sha256（`SUMS`），输入不是 Win11 上审过的这一份就当场停 |
| `kbuild-y15.sh` | 构建脚本，由 `kernel-y14/kbuild-y14.sh` 派生。差别见下文 |
| `y15-verify.sh` | 装上 y15 重启后的体检，由 `kernel-y14/y14-verify.sh` 派生。末行必须是 `ALL PASS` |
| `av1-10bit-probe.sh` | AV1 10-bit 起播探针（root，约 1 分钟）：用平板的 ffmpeg/libaom 编 5 帧流，经 VA-API 用 `/root/qva-av1test/build` 里**没安装的** v1.1.1 测试构建硬解，和 dav1d 比；临时打开一个动态调试点抓固件日志，退出时恢复。结果在 `/tmp/av1probe/summary.txt`。y15 体检会调用它（拷到 `/root/av1-10bit-probe.sh`） |
| `NOTES.md` | 本文件 |

### 来源与 sha256

源文件都在本机临时目录下（`radxa/`、`src/`、`dl2/`）。这个目录不持久，所以下面把哈希记全。

| 补丁 | 源文件 sha256 | 本目录文件 sha256 |
|---|---|---|
| 1052 | radxa `0005-media-iris-Recycle-decoder-buffers-for-non-display-p.patch`：`f8cf222758c711a3589e76d49bf9d6bdb83c16365890b6e3aa9890aae3dc17f2` | `6ef812c7ccd616caae2f50dc305537a41a225834c3e3fa2a584f8b8dfd6f2fd4` |
| 1053 | armada `0569-…`（从 `dac08dfe.patch` 里截出，blob `ca3894883` 对得上）：`8d8e569d0397f56dc3bfa741921c8cdb0501a2f274b6e19de1b24cc3fc5afcc5` | `b34192b7aed9168c0cf9e67094329de899ae41802bf2706ce715f66495b2ff11` |
| 1054 | armada `1008-…`（从 `f19400c3.patch` 里截出，blob `b1f842f17` 对得上）：`d58afee6b20e8b357eaeb992ba3f2550ecc5af3c32ebd08e3251fd41edc58f48` | `7896671574942d4824042e4fb3f4acb8eae433fcfdda05ac79d208cd82ee5c51` |
| 1055 | armada `1021-…`（raw.githubusercontent.com，10-28 取，和 `21316f049f14` 时的拷贝相同）：`96c1094f2403d73304adfc79d6eee6e38f1b055175b40d4e5982c04a2d53d25c` | `bf8f943402ad49e6061c5dd82f0e4933a69ce0554b43c2ac9b249daa300d8516` |
| 1056 | `kernel-y8/1045` 的 DT 部分（`1045-dt-only.diff`）：`41ef165616e5f928de7abb082bc0112edca75172a609b8493544677236b5eb9f` | `829a9a65eb24bfed93a67ea5308503d7f3160e0e53d5beb2810f387ba1f05fc5` |
| 1057 | 本仓自写 | `0750bdad09fb525fa904cb641d68fa52d5075517eda6df355e64d2538f71c333` |
| series | — | `772ec0a7503f1fda5a022ce504ed2865382b3f97d788b58b21943bbba7430f3c` |

（最后一列是作者工作副本的哈希。公开版补丁改过邮件头（作者邮箱、UTC 日期、来源行），所以 1056、1057 和沿用补丁的几行与公开文件的 sha256 不同。）

1052–1056 每个的提交说明都**原样保留**源文件的正文和 trailer，在 trailer 前面加一段 `y700 (kernel y15): …`（1057 是自写的，同样有这一段，写的是探针证据和模型的局限），内容包括：

- 来源、rebase 情况（都是行号偏移或原位，代码没改）、为什么收；
- 一行 `y700 patch file: <文件名>`。

`check_msgs.py` 核过两点：

- 正文和 trailer 逐字保留；
- `+`/`-` 行和源文件相同（只规整了 hunk 头和 index 行）。

1054 的源文件没有 `diff --git` 头，所以 hunk 头是 git 生成的。1053、1054 的源文件作者是 armada 的占位作者（`Armada <noreply@armada.local>`），也没有 Date，都照原样保留；日期取 armada 那次提交的。1055 的 Date 取的是 lore Message-ID 里的发送时间。

### 1053 说明的更正（10-28）

导出后，把 1053 y700 段落的最后一句改掉了。原来写的是「没必要的中断线程唤醒确实存在」，这句不对。依据是 `runs/upstream/20261028-deep-read.md` 的反驳二：

- ready 是在 smp2p 自己的 IRQ 线程里，经 `handle_nested_irq` 同步调用的；
- 处理函数只做 `complete(&start_done)`；
- 所以不会多唤醒线程或 CPU。

同一份材料的「小纠正」还指出：10-21 的 273/273 计数是在 7.3-rc4（y13）上抓的，不是 y14；不过 rc4 和 v7.3 的 `check_ssr()` 一样。

现在的说法是：剩下的 ready 重放无害；这是**正确性修复，随下次编内核顺带收，不是省电修复**。

- 代码没动。
- `SUMS`（`prep/y15-branch.sh`）和本表里的 1053 哈希已经改成新值。
- 改完后重跑了 `check_msgs`、sim3、sim4、assert_test，全过。

## 1052 读码要点（v1.1.1 的 0005，套在 t52 上只有行号偏移）

- **`iris_hfi_gen2_get_driver_buffer_flags()`**：去掉了 NOSHOW→`V4L2_BUF_FLAG_ERROR` 的映射。
- **`iris_hfi_gen2_handle_output_buffer()`**：当 `inst->domain == DECODER` 且帧类型含 `HFI_GEN2_PICTURE_NOSHOW` 时：
  - `data_size` 清 0；
  - 实例处于 `IRIS_INST_ERROR` 时加上 ERROR；
  - **既没有 ERROR 也没有 LAST** 时，交给 `iris_hfi_gen2_requeue_output_buffer()`。
- **空负载判断**：从 `!(hfi_buffer->flags & HFI_BUF_FW_FLAG_LAST)` 改成 `!(buf->flags & V4L2_BUF_FLAG_LAST)`。旗标映射对 `HFI_BUF_FW_FLAG_LAST` 和 `…PSC_LAST` 都会置 `V4L2_BUF_FLAG_LAST`，所以 1049 处理的「空的 PSC_LAST」也被豁免了。这就是 1049 可以去掉的原因。
- **`iris_hfi_gen2_requeue_output_buffer()`**：
  - 先清掉 `data_size`、`timestamp`、`flags`，把 DEQUEUED 换成 DEFERRED；
  - 在两种情况下**只留着不下发**：
    - `output_stopping` 为真（CAPTURE 的 STOP 正在等响应，那段等待会放掉 `inst->lock`）；
    - 状态不是 `STREAMING` / `OUTPUT_STREAMING`。
    
    留下的缓冲交给 streamoff 清理，或者下次 streamon 时再用。
  - 否则直接 `iris_queue_buffer()`。
  - 下发失败时，缓冲变成 ERROR + DEQUEUED，并恢复**原来的时间戳**，之后由 dequeue 路径交给用户态。效果等同 y14 的 errts 模式：v1.1.1 会把这一帧刷灰。
- **`iris_hfi_gen2_session_stop()`**：在 CAPTURE 平面上，等待响应期间把 `output_stopping` 置位。
- **剩下的 ERROR**：`iris_hfi_gen2_response.c` 里只剩一处 `driver_flags |= V4L2_BUF_FLAG_ERROR;`（kbuild 断言恰好 1 处）。

## 为什么用 cherry-pick 重放，不用 rebase（`prep/y15-branch.sh`）

y15 从 1049 的父提交（`y14~3`，22 个里的第 19 个）开始：

1. 按**完整哈希** cherry-pick 1050（`4b2962817…`）和 1051（`5a21a30d2…`）；
2. 用 `git am` 打上六个新文件。

不用 `git rebase --onto aca532577^ aca532577 y15` 的理由：

- 那样得先有一个等于 y14 的 y15，再原地改写它；
- 只要配置里有 `rebase.updateRefs`，指向被改写范围的分支会被一起挪走，而 y14 本身就指着 1051；
- 重放只**读** y14，从不 checkout、移动或改写它；冲突时停在一个有名字的提交上。

其他要点：

- **可复现**：committer 固定为 `y700-kbuild <y700-kbuild@localhost>`，日期 `Wed, 28 Oct 2026 12:00:00 +0900`；author、author date 和提交说明由 cherry-pick 和 am 原样保留。所以 `Y15_REDO=1` 重建出来的是**同一个** `Y15_HEAD`。
- **建好后的自查**：
  - 27 个提交，`y15~8 == C1049^`；
  - `y15~6` 的树必须等于「y14 的树反向打掉 1049」，用临时 index 算；
  - `git diff --stat y14 y15` 恰好 8 个文件；
  - response.c 里没有 1049 那行，有 1052 的 requeue 行；`iris_vpu_buffer.c` 里有 1057 的调用行；
  - 导出件和输入逐个比：19 个逐字节相同；另外 8 个（1050、1051、1052–1057）去掉第 1 行、index 行和末尾版本 trailer 后相同；
  - 再用临时 index 把导出件重放一遍，结果必须等于 y15 的树。
- **安全重跑**：
  - y15 已完整：只核对并重新导出；
  - y15 只建了一半：拒绝，给出清理办法；`Y15_REDO=1` 会中止进行中的操作，删掉 y15 后重建；
  - 「进行中」除了 rebase-apply / rebase-merge / `CHERRY_PICK_HEAD`，还包括 **sequencer 目录**：一次挑两个提交（1050、1051）时，第一个冲突、手工解决后用 `git commit` 收尾，`CHERRY_PICK_HEAD` 没了，sequencer 还在（第二个还没挑）。这种状态同样被拒绝；`Y15_REDO=1` 先 `cherry-pick --abort`，再 `cherry-pick --quit` 清掉残留的 sequencer。修复前这种状态会让每次 REDO 都卡住：sim4 里 git 2.55 在删 y15 前的 `git switch` 就报 `cannot switch branch while cherry-picking`（换个顺序也会在 cherry-pick 那行报 `already in progress`）；
  - 写操作一律带 `gc.auto=0`、`maintenance.auto=0`，因为 linux-t52 是和 linux-t47 共用对象库的 worktree。
- **输入核对**：任何输入文件含 CR 就拒绝（Git Bash 下的坑：`$'\r'` 必须写在顶层，`grep -U`）；`series` 必须正好是那 27 行；28 个文件的 sha256 必须对上 `SUMS`。
- **平板上第一次跑停在导出比对（10-29，已修）**：分支建得没问题（am 用的就是输入文件），但 1054 的导出件有一个 hunk 头和输入不同：输入是 `@@ -696,21 +697,31 @@ try_again:`，平板导出是 `@@ … @@ static ssize_t uhid_char_read(…`。
  - 根因：内核树的 `.gitattributes` 有 `*.[ch] diff=cpp`，git 按 C 的规则挑 hunk 头后面那段函数名；1052–1057 是在 Win11 的子集副本里导出的，子集没有 `.gitattributes`，用的是默认规则。git 版本（2.55 对 2.53）不是原因。
  - 修法：`norm()` 把 hunk 头里第二个 `@@` 之后的文字去掉再比，行号照比；后面的「导出件重放等于 y15 的树」本来就兜底。gawk 和平板的 mawk 都测过这句 awk。
  - 修完重跑（y15 已完整，只核对、重新导出）：19 个逐字节相同，8 个等价，`EXPORT_REPLAY_OK`，`Y15_BRANCH_OK`。
  - 以后在子集副本里做补丁，要么给子集加一份内核的 `.gitattributes`，要么接受这里的比法。

## kbuild-y15.sh 与 kbuild-y14.sh 的区别

- **`Y15_TREE` 占位符**：值不是 40 位十六进制时，在 `exec > $LOG` 之前就打印原因并退出（同时 tee 到日志）。
- **名字**：
  - `NAME=-tb323fu-t52-y15`；
  - `OUT=/usr/local/src/y700-kernel-y15`；
  - 模块目录 `y700-mods-y15`；
  - 补丁目录 `/root/y15-patches`；
  - 日志 `/root/y700-kernel-y15.log`；CHECK_ONLY 时写 `/root/y700-kernel-y15-check.log`。
- **树检查**：
  - 分支是 y15，工作区干净；
  - `HEAD~8` 等于 `y14~3`；
  - HEAD 的树等于 `Y15_TREE`；
  - 27 个提交；
  - 补丁目录用临时 index 重放后等于 HEAD 的树；
  - 带 1044，或带 1045 的第二部分（`ltr_max_latency_us`），就拒绝。
- **grep 断言**：y14 的整套照搬，只去掉 1049 那条，改成反向断言（1049 那行必须**不在**）。另加 `# ==== y15 assertions BEGIN … END` 一节：
  - **1052**：requeue 行、NOSHOW 判断、`buf->flags & V4L2_BUF_FLAG_LAST`、旧的 `hfi_buffer->flags & HFI_BUF_FW_FLAG_LAST` 判断已不在、ERROR 映射只剩 1 处、`output_stopping` 字段及两处赋值；
  - **1053**：`check_ssr()` 里 `restart = …` 后紧跟 `if (!restart)` / `return false;`；
  - **1054**：在锁内取 `ev`，`copy_to_user(buffer, ev, len)`，旧写法已不在；
  - **1055**：EVAL 文档要求的两条，加上 5 GHz 那条，旧的 `cap.band[WMI_HOST_WLAN_` 已不在；
  - **1056**：`baldur-wifi.dtsi` 里只有一个 `t-power-on-us`，并且就在 `&pcie_port0 {` 块里；pcie-qcom 读取和下发这个属性的两行都在；
  - **1057**：`hfi_vpu4x_buffer_line_av1d()` 的定义和 `size_dpb_opb(frame_height, AV1D_LCU_MAX_SIZE_PELS, true)` 都在；`iris_vpu4x_dec_line_size()` 函数体里调的是它，不再直接调共用的 `hfi_buffer_line_av1d()`。只查这个函数体，因为老 VPU 的路径（第 831 行附近）本来就该继续调共用函数。
- **配置**：配方一字不改，所以：
  - `CONFIG_LOCALVERSION` 必须是 y15 的名字；
  - 编译前与 `config-t52-y14.pre-build` 的差异、结束时与 `config-t52-y14` 的差异，都必须为**空**（`cfgcmp` 不比注释和 LOCALVERSION / INITRAMFS_SOURCE 两行）。
- **内置 DTB（1056 只通过它生效）**：上游 0021 用 `CONFIG_ARM64_BUILTIN_FDT` 把 DTB 编进 Image，bootloader 给的 DTB 被忽略。脚本做四件事：
  - 编译前确认 `CONFIG_ARM64_BUILTIN_FDT=y`，并确认 `CONFIG_ARM64_BUILTIN_FDT_NAME` 指向的 dts 直接 `#include "baldur-wifi.dtsi"`；
  - 最后一次 `make Image` 之后，用 dtc 反编译那个 DTB，要求恰好一处 `t-power-on-us = <0x50>;`；
  - 再用 python3 确认 DTB 的字节就在 `arch/arm64/boot/Image` 里；
  - 把 DTB 拷到 `$OUT`。

  这同时兜住了一个可能的 `-j8` 竞态：第一遍 make 里 `builtin_fdt.o` 可能 incbin 到旧的 DTB。DTB 是最后那次 `make Image` 的依赖，会重新汇编；即使没有，事后检查也会拦下。
- **CHECK_ONLY=1**：查完树、断言和编译前配置就以 `CHECK_ONLY_OK` 结束，不编译。

## y15-verify.sh 与 y14-verify.sh 的区别

y14 的检查**全部保留**，名字换成 y15 的。改动：

- **1049 那几项改成 1052**：
  - iris 没有 err 级日志（解码前、解码后各查一次）；
  - `vaapi-check.sh` 退出码为 0；
  - `vp9-hidden-check.sh` 两项：
    - 先 `env -u IRIS_NOSHOW_MODE -u LIBVA_EXPECT_ERRTS` 再运行，让脚本自己按 `uname -r` 选模式；
    - 首行必须恰好是 `vp9-hidden-check: mode=recycle kernel=7.3.0-tb323fu-t52-y15`；
    - 退出码 0，末行 `vp9-hidden-check: PASS`；
    - 首行不符合契约时，提示拷当前的 `linux/video/vp9-hidden-check.sh` 过去。

  INFO 行会打印当前装的 VA 驱动（读 `/root/libva-v4l2.installed`）。
- **「y15」一节**，相当于 y14 的身份检查：
  - 跑的就是 `Image-t52-y15`；
  - `/proc/config.gz` 等于 `config-t52-y15`，并且除那两行外等于 y14 的 `config-t52-y14`；
  - 构建日志末行是 `KFULL_OK`；
  - 加载的 `qcom-iris.ko` 就是 `y700-mods-y15` 里那个；
  - 补丁存档 `y700-y15.patch` 里：有 0620–0622、1051，有 1052–1057 的特征行，**没有** 1049；
  - 内置 DTB 已拷到 `$OUT`。
- **1057**：`/root/av1-10bit-probe.sh` 和 `/root/qva-av1test/build` 都在时跑一遍探针（约 1 分钟）。CHECK 两个 8-bit 对照起播且和 dav1d 一致（1057 不该碰 8-bit）；INFO 五个 10-bit 合成流里起播并一致的个数（y14 是 1/5）。缺任何一个就只打一行 INFO，不算 FAIL。
- **1053**：
  - `/proc/interrupts` 按字段而不是正则匹配。格式取自 `runs/diag/20261021-2045-cx-votes.txt:243/273`：
    - `ipcc 196610 Edge smp2p-adsp`
    - `smp2p-adsp 1 Edge q6v5 ready`
  - 采 10 s 前后的差值，给出结论（INFO）：
    - smp2p-adsp 在涨、ready 不涨 → 与 1053 一致；
    - 两者一起涨 → 1053 没生效？
    - 都不涨 → 没法判断（传感器闲着）。
  - CHECK：没有 "Handover signaled, but it already happened"，以及没有 crashed 的 remoteproc。前者只是护栏：v7.3 的 q6v5 在第一次 handover 后就屏蔽了这个中断，y14 本来也没有。
  - remoteproc 状态打成 INFO。
  - 理由：SoCCP 是 smp2p v2 的另一个用户（early_boot，开机 attach），挂着 pmic_glink 和 USB‑C。它的 attach 读的是电平，不是 last_value（deep-read 反驳三）。它的下游（battmgr、ucsi、角色切换）前面的检查本来就覆盖。
- **1054**：只有 INFO。
- **1055**：
  - CHECK：`iw reg get` 有 `country JP`；`nmcli` 显示 HOME_6G 处于活动状态。
  - INFO：
    - 当前链路；
    - 缓存扫描结果里 2.4 / 5 / 6 GHz 各几个网；
    - `ping -c 300 -i 0.2 192.168.0.1`（60 s）。EVAL 的标准是 0 % 丢包，但单次丢一个包也可能是环境，所以只记 INFO，要和 y14 对比；
    - `Y15_NO_PING=1` 时跳过 ping，不在 HOME_6G 上也跳过。
- **1056**：
  - CHECK：
    - `find /sys/firmware/devicetree/base -name t-power-on-us` 恰好一个（kaanapali DT 本来没有这个属性，README 与 `linux/power/PCIE-L1SS.md` 都核过）；
    - 它所在节点的 `wifi@0/compatible` 是 `pci17cb,110e`；
    - 值的字节是 `00000050`；
    - 根端口（`0000:01:00.0` 在 sysfs 里的父设备，即 `0000:00:00.0`）的 `lspci -vvv` 里有 `PortTPowerOnTime=80us`（y14 10-23 的探针是 0us）。
  - INFO：两端的 `LTR1.2_Threshold` / `T_PwrOn`，以及开机以来的 AER 行数。
    - 按 aspm.c 的公式，y15 应是 2+4+70+80 = 156 µs，向上取整到 1024 ns 刻度，即 `LTR1.2_Threshold=156672ns`、两端 `T_PwrOn=80us`（前提是 L1.2 已使能）。
    - y14 是 76800 ns、0us。
  - 全程只用 lspci 和 sysfs，**不碰** PCIe debugfs（10-15 读 PARF 寄存器把平板读挂过）。
- **环境变量**：`Y15_NO_RECOVERY=1` 跳过 error-recovery（原来叫 `Y14_NO_RECOVERY`）；`Y15_NO_PING=1`；`Y10_NO_TOGGLE=1` 不变。
- **最后的配置打印**：说明改成「这两行勘误是 y14 引入的，y15 没变」。
- **初稿怎么来的**：由临时目录里的 `tools/make_verify.py` 从 y14-verify.sh 生成。每处替换都要求原文恰好出现一次，y14 的其它行逐字带过来。之后又手改过几处：1053 的基线归属、remoteproc 那项、1052 注释里关于 vaapi-check 覆盖面的说法、1056 的期望值。

## Win11 上的模拟证据

都在本机临时目录，不持久。

- **输入**：`y14tree`（本机临时目录里的子集仓库）是 y14 HEAD `5a21a30d2c6b` 的子集仓库，内含补丁涉及的所有文件。没有改动它，只 clone 出来用。

| 步骤 | 做了什么 | 结果 |
|---|---|---|
| sim1 | 子集反向打掉 1051、1049 得到 base；base + 1049 + 1051 必须等于子集的树；base + 1051 后，对每个新补丁 `--check -v`，记下行号偏移 | `SIM1_OK` |
| sim2 | 在模拟仓库按原作者、原日期和 y700 说明提交五个新补丁，用 `format-patch --abbrev=9` 导出，组装 `patches/` | `SIM2_OK` |
| sim3 | 对**最终文件**照任务第 7 步来：新 clone，`apply -R` 1051 和 1049，正向 apply 1051，再按 series 顺序逐个 `--check -v` + `apply -v`；所有被改文件都在子集里；结果树等于 sim1/sim2 的；series 格式正确。1053 手改后重跑过 | `SIM3_OK`，树 `7637d258b5af14b77baa37a0d35d255951cdf73a` |
| check_msgs | 五个新补丁的说明正文和 trailer 逐字保留，`+`/`-` 行和来源相同 | `CHECK_MSGS_OK` |
| sim4 | 在合成的 linux-t52 上跑 `y15-branch.sh` **本身**（测试拷贝，只替换路径、root 检查、钉住的哈希）。t52-base 是子集反向打掉 1051/1050/1049 后加 19 个假提交，再 am 真的 1049/1050/1051 当作 y14。12 个场景见下 | `SIM4_OK`，y14 一次都没动 |
| assert_test | 把 `kbuild-y15.sh` 的 y15 断言块原样抽出来跑。y15 过；y14 停在 1049 反向断言；对 1052–1056 中的每一个，「y15 减去它」都停在它自己那一节 | `ASSERT_TEST_OK` |
| b1051 | y14 带过来的 1051 断言在模拟 y15 上通过 | `B1051_OK` |
| verify_ptest | `y15-verify.sh` 的补丁存档检查，跑在模拟仓库的累计 diff 上：y15 的 7 项全过；y14 只有 1051 过，其余 6 项失败 | `VERIFY_PTEST_OK` |
| verify_rt | `y15-verify.sh` 新增运行时块的假数据测试，见下 | `VERIFY_RT_OK` |

sim4 的 12 个场景：

1. 首跑；
2. 重跑（完整，只导出）；
3. 完整 y15 上 `Y15_REDO=1`（得到同一个 HEAD）；
4. 半成品 y15（拒绝）；
5. 半成品 y15 加 `Y15_REDO=1`；
6. am 进行中（拒绝）；
7. am 进行中加 `Y15_REDO=1`；
8. 残留 sequencer（拒绝）：在 1049 的父提交上先改一下 dpu_crtc.c，`cherry-pick 1050 1051` 停在 1050 的冲突上，手工解决后 `git commit`，于是 `CHERRY_PICK_HEAD` 没了、sequencer 还在（todo 里还有 1051）；
9. 残留 sequencer 加 `Y15_REDO=1`：清掉后重建，得到同一个 HEAD。修复前的脚本（`SIM4_ORIG=1 SIM4_SRC=<旧副本>`）在这一步卡死：git 2.55 先在 `git switch` 报 `cannot switch branch while cherry-picking`（审查意见预计会在 cherry-pick 那行报 `already in progress`，同一个根因），每次 REDO 都一样（`SIM4_ORIG_SEQ_BUG_REPRODUCED`）；
10. 1053 含 CR（拒绝；提示改成「用 scp 重新拷 LF 文件并比 sha256，不在平板上改」）；
11. series 里有 1049（拒绝）；
12. 1055 被篡改且加 `Y15_REDO=1`（sha256 拒绝），然后换回真输入。

verify_rt 用假数据测的内容：

- `/proc/interrupts` 的 y14 型、y15 型、闲置三种快照（cdsp 的 ready 行不计入；多 CPU 列求和）；
- handover 护栏在有、无那行日志时的结果；
- 频段计数；
- 设备树的四种情况：正常、值为 70、多出一个属性、属性缺失；
- vp9-hidden-check 输出的四种情况：recycle PASS、gray 模式、FAIL、旧脚本。

**1057 是模拟之后加的**（10-29），补做的检查：

- `patch --dry-run` 打到 y14 子集副本上，干净；
- kbuild 的 1057 断言块抽出来跑：y14 的 `iris_vpu_buffer.c` 停住，y14 + 1057 通过；
- `y15-verify.sh` 的两条 1057 正则：补丁存档那条对补丁文件本身匹配；探针那两条对 y14 真实的 `summary.txt` 算出 8-bit 2/2、10-bit 1/5；
- **sim4 带 1057 重跑**（`tools/sim4b.sh`，与 sim4 只差四处：拷最后 8 个文件、期望 19 + 8、模拟 y15 树加上 1057 再比、日志范围 `y15~6`）：12 个场景全过，`SIM4_OK`，8 个文件、`y15~6` 等于 y14 反向打掉 1049，y14 没动；
- assert_test 没有重跑：它的模拟 y15 树不含 1057，整块跑会停在 1057 那节。1052–1056 的断言一个字没改。

另外：

- 三个脚本都过了 `bash -n`；
- `kernel-y15/` 下所有文件 0 个 CR、无 BOM；
- `sim4` 里合成仓库的 `Y15_TREE`（`af803bc0…`）只属于那个合成仓库，**不是**平板上的值。

## 风险，以及每一项怎么测

1. **1052 对所有编码格式回收 NOSHOW**。
   - 判断条件只有「解码器 + NOSHOW」，不区分 VP9/AV1。H.264/HEVC 码流里固件什么时候报 NOSHOW 没有文档。
   - 以前这种图会以空 ERROR 缓冲（y14 上带时间戳）回到用户态；现在直接在内核里消失。
   - 如果用户态按 token 等这一帧（v1.1.1 没有兜底），会等满 5 s 的 surface sync timeout。
   - 测法：
     - 体检里 vaapi-check 的 H.264、HEVC 8/10-bit 每条流从头解到尾；
     - **手测**：HEVC open-GOP（x265 默认 `open-gop=1`，CRA 后带 RASL）用 mpv/ffmpeg 的 VA 硬解跳转几次，看有没有约 5 s 的卡顿，以及有没有 `timeout` / `surface sync` 日志；
     - Chrome 里 YouTube（VP9/AV1）来回拖进度条，看有没有 5 s 冻结；
     - `journalctl --user -b | grep -ciE "surface sync timeout|replaced damaged picture"`，装 v1.1.1 前后各看一次。
   - FFmpeg 和 Chrome 从 CRA 起播时自己就会丢掉 RASL，正常不会送进固件；这只是推理，没有实测。
2. **1052 的 requeue 绕过 vb2 `buf_queue` 的 DRC_LAST / DRAIN_LAST 闸门**。
   - 回收路径只看 `output_stopping` 和 STREAMING / OUTPUT_STREAMING，直接 `iris_queue_buffer()`；不看 `sub_state` 里的 DRC_LAST / DRAIN_LAST。
   - 正常从 vb2 进来的 CAPTURE 缓冲在这两个子状态下会被立刻带 LAST 返回。
   - 所以，如果固件在 LAST / PSC_LAST **之后**又回了一个干净的 NOSHOW，那个缓冲会在分辨率切换或 drain 期间被重新交给固件。上游提交说明没讨论这种次序。
   - 测法：
     - EOS / drain：vaapi-check 每条流都走到结尾；
     - 分辨率切换：本仓没有现成的流和脚本。手测时拿两段不同分辨率、带隐藏帧的 VP9 拼成一个 webm 硬解，再试 YouTube 画质切换，看有没有 `qcom-iris` / `iris_` 的 err 级日志、卡死或冻结。
   - 我们的播放器都走 VA。分辨率变化时 FFmpeg / Chrome 一般会重建 VA 上下文，iris 内部的 DRC 序列是否会被走到，取决于 libva-v4l2 的实现，**没核实**。
3. **requeue 失败或延期**。
   - 失败：缓冲以 ERROR + 原时间戳返回，v1.1.1 把那帧刷灰，不卡。vp9-hidden-check 的 `error-hidden` 用例覆盖了同样形态的缓冲。
   - 延期（STOP 期间）：缓冲留给 streamoff 清理或下次 streamon，跳转时理论上可能少一个缓冲。上游在 X1E80100 上测过；我们是 SM8850，固件不同。
4. **1053**：
   - SSR / 重启分支在这里测不到，我们从不做 ADSP SSR。
   - SoCCP 是 early_boot 的 smp2p v2 用户，它的 attach 读电平、不靠 last_value（deep-read 反驳三），理论上不受影响；但 armada 只在 SM8550 上测过。
   - 体检看 remoteproc 没有 crashed，以及电池、ucsi、USB 角色。头几天再留意自动旋转、自动亮度、扬声器（都走 ADSP），以及 USB‑C 充电。
5. **1054**：预防性修复，这台机器上没出现过，也没有复现手段。BlueZ 的 HID-over-GATT 设备（BLE 键盘、手柄）的输出报告和 feature 报告走这条队列。有 BLE HID 设备时连一下、用一下即可。
6. **1055**：在 JP 监管域下，各范围的并集不变，下发给固件的信道表也不变（EVAL 文档），所以预期零差异。它也**不**解决 5 GHz 丢 beacon 的问题。体检看 JP、HOME_6G 和 ping。
7. **1056**：
   - 不进 L1.2 就没有任何效果（4 小时里 L1.2 只进了 31 次，L1.1 是 163 万次）。
   - 它会把 L1.2 阈值从 76.8 µs 提到约 156.7 µs，T_PwrOn 从 0 改成 80 µs，L1.2 的进入条件因此变严。
   - 研究估计 L1.2 最多值 0.01–0.02 W，低于测量噪声，所以不打算测功耗。
   - 要留意的是 AER：体检 INFO 里有行数，头几天再看 `dmesg | grep AER`。
8. **内置 DTB 没更新**：构建后有检查兜底，见上文 kbuild 一节。体检再从活动设备树核一遍。
9. **1057**：
   - 尺寸规则是拟合的，不是从固件源码推出来的；加的量远大于拟合缺口，但如果真正缺的是别的缓冲，它就没用（不会更坏）。
   - 只有 10-bit AV1 会话多占不到 2 MiB 的 LINE 缓冲。
   - 测法：体检里的探针（8-bit 对照 CHECK，10-bit INFO），装 v1.1.1 后 `tests/decoder/av1.py --extended`。

## 和 VA 驱动的耦合（重要）

- **qcom-va-driver v1.1.1（35eff37）依赖 y15**。它假定内核会回收 NOSHOW（1052 = radxa 0005），自己没有用户态兜底。10-28 在 y14 上测过：每个 VP9 隐藏帧都被刷灰（vp9-hidden-check 7 帧中 7 帧）。`libva-v4l2-update.sh` 的 GUARD 在非 recycle 内核上、又没有本地补丁时会拒绝安装。
- **现装的 2de1857（6d03c3f + 本地 0001）在 y14 上实测过** vp9-hidden-check（10-23，errts 模式，README「vp9-hidden-check (build) 全部 PASS」）；**在 y15 上只是预期能过**。依据是读码推理（`linux/video/vp9-hidden-check.sh` 头部原话是「Expected to PASS in recycle mode with both 2de1857 … and v1.1.1」），**recycle 模式还没在任何内核上跑过，y15 体检是第一次**：
  - `clean` 用例：内核回收了 NOSHOW，0001 等的那只空缓冲根本不来，它的分支不触发；
  - `error-hidden` 用例：注入的空 ERROR 缓冲落在画面上，0001 会把它误当成 no-show 缓冲，等到下一帧画面回来、或 1 s 兜底时才刷灰（v1.1.1 是当场刷灰）。判据「恰好 1 帧灰、没有超时」照样成立，但这条路径是推理，没跑过。
  - 即便如此，**y15 的试装和体检仍在 2de1857 上做**，keep 之后才装 v1.1.1。体检里这一项 FAIL 时先分清是 1052 还是 0001，见「执行顺序」第 8 步。
  - 这样 trial 期间（包括没确认时的自动回滚）VA 驱动始终是两边都能用的那一版。
- **装了 v1.1.1 之后要回 y14，必须先把 VA 驱动退回 2de1857，再回内核**：
  - `libva-v4l2-update.sh` 只会往前走，装 v1.1.1 时它会把旧驱动备份成 `/root/v4l2_drv_video.so.bak-<时间>-2de1857`。**这个备份不能删。**
  - 回退：
    ```
    cp -a --remove-destination /root/v4l2_drv_video.so.bak-<…>-2de1857 /usr/local/lib/aarch64-linux-gnu/dri/v4l2_drv_video.so
    ```
    `--remove-destination` 是为了不改写播放器正在映射的那个文件。
  - 之后 `/root/libva-v4l2.installed` 还记着 v1.1.1，已经过时，要在 `linux/video/` 那边修正。
  - 顺序反过来（先回内核）也不危险，只是在 VA 退回之前，y14 上的 VP9 隐藏帧会是灰的。
  - 0001 的来龙去脉见 `linux/video/libva-v4l2-patches/retired/README`。

## 平板上的执行顺序

前提：

- y14 是 good；
- 作者知道这件事；
- 构建期间平板不做测量（先看 8766 状态页，测量期间别 ssh）；
- 往平板放文件一律「scp 过去，再和本地比 sha256」，**远端不跑 sed**。本目录的文件都已经是 LF。

1. **下发文件**：
   - `patches/*`（28 个文件）→ 新建的空目录 `/root/y15-patches/`；
   - `prep/y15-branch.sh` → `/root/y15-branch.sh`；
   - `kbuild-y15.sh`、`y15-verify.sh`、`av1-10bit-probe.sh` → `/root/`；
   - 当前的 `linux/video/vp9-hidden-check.sh` → `/root/vp9-hidden-check.sh`（如果平板上那份不是同一个 sha256）。
   
   逐个比 sha256。
2. 运行 `bash /root/y15-branch.sh 2>&1 | tee /root/y15-branch.log`。末行必须是 `Y15_BRANCH_OK`。看一遍 `git diff --stat y14 y15`（8 个文件）和 `/root/y15-export/`。
3. **钉住 `Y15_TREE`**：从日志里取 `Y15_TREE=` 那一行的值，在 **Win11 仓库里**改 `kbuild-y15.sh` 第 37 行，把 `__FILL_AFTER_PREP__` 换成这 40 位，然后 scp 到 `/root/kbuild-y15.sh` 并比 sha256。不在平板上用 sed 改。
4. 运行 `CHECK_ONLY=1 bash /root/kbuild-y15.sh; tail -3 /root/y700-kernel-y15-check.log`。末行必须是 `CHECK_ONLY_OK`。
5. 运行：
   ```
   systemd-run --unit=y700-kbuild-y15 --collect -p Nice=19 -p CPUWeight=20 -p IOWeight=20 /bin/bash /root/kbuild-y15.sh
   ```
   完成后 `tail -1 /root/y700-kernel-y15.log` 必须是 `KFULL_OK`。
   - 树里还是 y14 的产物，所以这次是增量编译。不过 LOCALVERSION 变了，全部模块要重新 modpost / 链接，估计几分钟（**没实测**；y14 全量 7 分钟可作为上限参考）。
   - unit 名不能以 `y700-cx-` 开头。
6. 安装：
   ```
   tb323fu-ctl kernel install-local /usr/local/src/y700-kernel-y15/Image-t52-y15.gz --trial --name "y700 y15: y14 - 1049 + iris NOSHOW recycle 1052, smp2p 1053, uhid 1054, ath12k ranges 1055, wifi T_POWER_ON 1056, AV1 10-bit line buffer 1057" --yes
   ```
   安装和重启分两步。
7. **重启**：先确认平板空闲，然后 `systemctl reboot`。
8. 重启后以 root 运行 `bash /root/y15-verify.sh 2>&1 | tee /root/y15-verify-$(date +%Y%m%d-%H%M).log`，末行必须是 `ALL PASS`。
   - 想测 1043/0118 的开机默认值，要开机后亮着屏、插着电马上跑（cx-auto armed 时这几项会 SKIP）。
   - 体检时要有用户处于登录状态（KDE 会话），vaapi-check、vp9-hidden-check、error-recovery 都以 user 身份跑。
   - **vp9-hidden-check 在 y15 + 2de1857 上 FAIL 时，别直接 rollback 归罪 1052**。recycle 模式这是第一次真跑（见「和 VA 驱动的耦合」），先看输出里是哪个用例挂的（`FAIL  <用例>: …`，下面跟着该用例的 trace 摘要）：
     - `clean` / `clean-export` 挂，且 `empty CAPTURE` 或 `no-show matched` 大于 0：内核把 NOSHOW 交了出来，1052 没起作用，算内核的问题（先核 kbuild 日志里 1052 的断言和体检的补丁存档检查）。
     - 只有 `error-hidden` / `error-hidden-export` 挂（`clean` 过了）：先怀疑 0001 与 recycle 的交互，不是 1052。拿没安装的 v1.1.1 测试构建再跑一次：`bash /root/vp9-hidden-check.sh /root/qva-av1test/build`（参数是放 `v4l2_drv_video.so` 的 build 目录，10-28 在 y14 上就是这样对它跑的；只加载，不安装）。v1.1.1 过、2de1857 不过，就是 0001 的问题，不是 1052。这时体检末行不会是 `ALL PASS`：先别 rollback，也别自己 keep，把这一项的两份输出交给作者决定是否 keep；之后再决定是装 v1.1.1 还是改 0001。两者都不过，再查 1052。
     - 其他情况（`corrupt-arf` 挂，或 `clean` 挂但 `empty CAPTURE` 和 `no-show matched` 都是 0，比如有灰帧或 timeout）：两边都可能。同样先用 v1.1.1 测试构建对照一次再下结论。
     - 体检脚本在这一项 FAIL 时也会打印同样的提示。
9. 全过后运行 `tb323fu-ctl kernel keep`。把体检日志拷回 `runs/kernel/`，结果写进 README「内核 y15」。
10. keep 之后：
    - 才能用 `bash /root/libva-v4l2-update.sh 35eff37` 装 v1.1.1；
    - 装完在 y15 上重跑 `vp9-hidden-check.sh`（依然应是 recycle + PASS），再把上面「风险」第 1、2 条的手测做一遍。

## 回滚

- **trial 期间（没 keep）**：运行 `tb323fu-ctl kernel rollback`，把 good 的 y14 写回 boot_a，然后自己 `systemctl reboot`（`--reboot` 不会真的重启）。不管它的话，两次启动没确认，第三次也会自动回 y14。这个阶段 VA 驱动还是 2de1857，不用动。
- **keep 之后，并且已经装了 v1.1.1**：
  1. 先按上节把 VA 驱动 cp 回 2de1857 的备份；
  2. 再运行 `tb323fu-ctl kernel install-local /usr/local/src/y700-kernel-y14/Image-t52-y14.gz --trial --name "y700 y14: y13 on kernel-t52 (v7.3) + iris error-buffer timestamps 1051" --yes`；
  3. 重启，`y14-verify.sh` 全过后 `kernel keep`。
- **试用中的内核不能直接被 `install-local` 覆盖**：要先 `kernel rollback`，再 install-local。
- **linux-t52 里的分支**：y14 分支一直在，没被动过。回 y14 不需要这棵树，它只用于重编。真要用 y14 重编，`git -C /usr/local/src/linux-t52 switch y14` 后跑 `kbuild-y14.sh` 即可：y14 的产物目录是 `y700-kernel-y14/`，和 y15 的分开。

## 有意不做的事

- **不收 t53 的 0142（144 Hz 面板模式）**：这是新功能，不是修复。它和 `msm.idle_refresh_ms60/30`、KWin 选模式之间怎么配合没验证，和 y14 时的理由一样。
- **不收 1045 的第二部分**（`pcie_qcom.ltr_max_latency_us` 模块参数）：这是预备方案，要先有 bench 证据。kbuild 遇到它会拒绝。1044 同样拒绝。
- **不改配置**：六个新补丁都不新增 Kconfig 符号，配置差异保持为空，方便 A/B 时归因。
- **1057 不往上游发**：没有 Signed-off-by，规则是拟合的；要发得作者点头，并且先在 y15 上确认 10-bit 全过。
- **没在 Win11 上编译**：本机没有 arm64 工具链和 clang 18 的那套环境。编译和链接只能在平板上验证。
- **准备阶段只写本目录**：没碰 `tools/upstream-check*` / `*-state.json` / `linux/carplay/` / `runs/`；`linux/video/*` 只读。本目录在上平板前单独提交一次（10-29），README 等平板上有结果再写。
- **没有改动 `y14tree`**，只 clone 出来用。

## 没验证的

- **编译、链接、模块和启动都没做过**：Win11 上没有 arm64 工具链。
- ~~`Y15_TREE` 和 `Y15_HEAD` 的真实值~~：10-29 已在平板上跑出并钉住（见开头）。
- ~~平板上的 git 是 2.53.0，本机是 2.55.0~~：10-29 在 2.53 上真跑过；版本 trailer 由 norm 兜住，hunk 头的差别是 `.gitattributes` 造成的（见上文）。
- ~~**awk 用的是 gawk**~~：10-29 `y15-branch.sh` 的 `norm()`、kbuild 的断言、`y15-verify.sh` 的 awk 都已在平板 mawk 上跑过（体检 ALL PASS）。
- **`kbuild-y15.sh` 的 include 检查**：要求显示用 dts `#include "baldur-wifi.dtsi"`。子集里没有那份 dts，只在 tb323fu-linux 的 `kernel-t52` tag 上看到第 14 行是这么写的。
- **`y14tree` 子集**：默认它忠实反映平板上的 y14（`5a21a30d2c6b`）。sim1 核对过子集自己的提交和 1049/1051 的往返，但没和平板逐字节比过。
- ~~**`lspci -vvv` 的输出格式**~~：10-29 体检实测就是 `PortTPowerOnTime=80us`、`LTR1.2_Threshold=156672ns`、`T_PwrOn=80us`。
- ~~**`nmcli -t -f ACTIVE,SSID` 的 `yes:HOME_6G`、`iw reg get` 的 `country JP`**~~：`iw` 那条对了；nmcli 那条**错了**，root 的中文 locale 让它打出 `是:HOME_6G`，第一次体检因此 FAIL，已加 `LC_ALL=C`（见开头「上机结果」）。
- **1052 风险第 1、2 条的手测脚本**没有写，只给了测法。
- ~~**2de1857（带本地 0001）在 recycle 内核上的行为**~~：10-29 y15 体检第一次实测，vp9-hidden-check 在 recycle 模式下全过（`error-hidden` 恰好 1 帧灰、没有超时；`error-hidden-export` 走了 1 次 no-picture 兜底，2.0 s，也没有超时）。

## 待作者决定

1. **0142（144 Hz）**：y15 不收。要收就作为之后单独的一步。
2. **平板导出件要不要拷回来**：y15 建好后，`/root/y15-export/` 里 1050–1057 八个文件的 `From <sha>` 行和 index 行会和本目录的不同（内容相同，`y15-branch.sh` 核过）。要不要用平板导出件替换本目录的文件，让仓库里的补丁和真实分支逐字节一致（y14 就是这么做的）？替换后 `SUMS` 和本文的哈希表要跟着更新。
3. **1055 的 ping**：现在只记 INFO，因为单次丢包可能是环境。要不要按 EVAL 的字面标准（0 % 丢包）升成 CHECK？

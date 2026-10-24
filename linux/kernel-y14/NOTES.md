# 内核 y14：把 y13 的补丁搬到上游 kernel-t52（v7.3）

2026-10-22 准备，10-23 00:18 编好（`KFULL_OK`），02:36 trial 装上重启，**04:03 keep，现役 good 是 `7.3.0-tb323fu-t52-y14`**（经过见下文「试装与 keep」）。「平板上的现状（10-23 00:20）」等小节是编好、还没装时写的。

y14 的内容 = y13 的全部自有补丁 + **1051**（10-23 加，iris 错误缓冲保留时间戳，见下文「1051」）。基线从 v7.3-rc4 + 上游 t49/t51 换成 **v7.3 + 上游 joonhoekim/tb323fu-linux `kernel-t52`**。
release 名是 `7.3.0-tb323fu-t52-y14`。v7.3 没有 `-rc4`，命令行上的 `LOCALVERSION=` 让版本号不带 `+`。

## 10-23 编译结果

- 产物 `/usr/local/src/y700-kernel-y14/`：
  - `Image-t52-y14.gz`（30157490 字节，sha256 `904fe3ce35f6c2ee480af0f8e2a900ae65527465f75ebb30a823bcd6adbc7904`）——安装用这个；
  - `Image-t52-y14`（65325064 字节，sha256 `9a3289ae9da98eae1a3a6722ea1ef7769e5dfed4944a477c8f4e0315e5b93b6c`；y13 是 65327112）；
  - `initramfs.cpio.gz`（16771481 字节，已链进 Image）、`initramfs.list`、`initramfs.d/`；
  - `config-t52-y14`、`config-t52-y14.pre-build`、`y700-y14.patch`（= `git diff t52-base y14`，54097 字节）。
  - 本目录 `Image-t52-y14.sha256` 记了两个镜像的 sha256。
- 模块 `/usr/local/src/y700-mods-y14/lib/modules/7.3.0-tb323fu-t52-y14/`：330 个 `.ko`，**文件清单与 y13 完全一样**；aw882xx 在 `updates/snd-soc-aw882xx.ko`；36 MB。
- `make kernelrelease` = `7.3.0-tb323fu-t52-y14`；Image 里是 `Linux version 7.3.0-tb323fu-t52-y14 (root@y700-ubuntu) (clang version 18.1.3 …, LLD 18.1.3)`。
- 日志 `/root/y700-kernel-y14.log`，末行 `KFULL_OK`。脚本里的断言全过：
  - 树哈希、补丁重放、22 个文件的 series 清单；
  - grep 断言（含新加的 1051）；
  - check_config；
  - 编译前和最终配置相对 y13 的差异都**恰好是那两行勘误**；
  - 330 个模块 vermagic 全对；`ath12k.ko` version = `y700-1041`；
  - Image 里有 `allow_system_off` 的两条字符串。
- initramfs 清单和 y13 的**形状相同**（把版本号、目录名换掉后逐行一样）。
- 编译警告只有两条：
  - aw882xx 的 `unused variable 'g_algo_auth_dsp_lock'`，y12/y13 就有；
  - `dsi_phy_7nm.c:507` misleading indentation。代码来自上游 t52 的 b247e8f5d（AA601 DSC 修复），y13 树里一字不差，只是 y13 是增量编译没重编这个文件。逻辑是两个独立的 `if … return 0`，只是缩进不对。
- 用时：第一次全量编译 00:09–00:16（7 分钟，Nice 19、CPUWeight 20、电池供电），**在 initramfs 一步失败**；修好后重跑是增量，00:17:51–00:18:47。
- **第一次失败的根因**：上游 `kernel/initramfs/build.sh` 用 `$repo = kernel/initramfs/../..`，从仓库根取两个**不在 `kernel/` 里**的文件：
  - `android/back-to-android`
  - `userspace/platform/src/keyhold.c`

  `/usr/local/src/tb323fu-linux-t52` 当初只放了 `kernel/` 目录。
  - 修法：从本机上游克隆 `linux/tb323fu-linux` 的 `kernel-t52` tag 取出这两个文件，放到 `/usr/local/src/tb323fu-linux-t52/` 的对应位置。
  - 两者从 t47 起没改过，和旧 `/usr/local/src/tb323fu-linux` 的逐字节相同（sha256 `4649391b…` / `c5a97de4…`）。y13 的 initramfs 用的就是同样两个文件。
  - 平板上 t52 的 `kernel/` 也和本机克隆的 `kernel-t52` tag 对过：`build.sh`、`init`、`README.md` 的 sha256 一致。
  - kbuild-y14 现在**在编译之前**就用 sha256 核对这两个文件，缺了当场停，不会再白编 7 分钟。

## 文件

| 路径 | 是什么 |
|---|---|
| `patches/` | 22 个补丁和 `series`（应用顺序），每个是 y14 分支上一个提交的 `git format-patch`，文件名沿用原名。10-23 重新导出：前 21 个与 10-22 的导出逐字节相同，新增 1051 |
| `kbuild-y14.sh` | 构建脚本，由 `linux/kernel-y8/kbuild-y13.sh` 派生；差别见下文。10-23 全量编译通过（`KFULL_OK`） |
| `y14-verify.sh` | 装上 y14 重启后的体检，由 `linux/kernel-y8/y13-verify.sh` 派生，见下文「y14-verify.sh」。平板上的拷贝是 `/root/y14-verify.sh` |
| `Image-t52-y14.sha256` | 两个镜像的 sha256，格式同 `kernel-y8/Image-t49-y13.sha256` |
| `../kernel-y8/1051-media-iris-preserve-timestamps-on-error-buffers.patch` | 1051 的原件（上游 mbox，提交说明里加了 y700 来源段落）。`patches/` 里的同名文件是 y14 提交的导出件 |
| `prep/t52-prepare.sh` | 在平板上建 `/usr/local/src/linux-t52`：linux-t47 仓库的新 worktree，停在 v7.3，`git am` 上游 134 个补丁，打 tag `t52-base` |
| `prep/split_base.py` | 把 y13 里没有单独补丁文件的「底座」改动拆成 00y1–00y5。输入是 `linux/kernel-y1..y5` 存档的累计 diff，输出到脚本旁边的 `in/` |
| `prep/y14-dryrun.sh` | 空跑：在临时分支上逐个 `git apply --check`，不行就退到 `--3way`，再和 linux-t47 逐文件比对 |
| `prep/y14-branch.sh` | 建 y14 分支（每个补丁一个提交）并导出 `patches/`。最后用临时 index 重放导出件，必须等于 y14 的树 |
| `prep/y14-config.sh` | 在 O= 目录里空跑配置。四项：t49 配置在 v7.3 上的变化、y13 配方 vs y13、上游配方 vs t49 release、片段符号是否还在 |
| `prep/y14-add-1051.sh` | 10-23 在 y14 上 `git am` 1051 并重新导出 22 个补丁（输入 `/root/y14-in-1051/`，输出 `/root/y14-export/`，两者用完已删）。只认 10-22 的树，重跑会拒绝 |

原工作区里另有一个 `candidates/` 草稿目录（10-22 23:53 另外放进来，不是本次准备写的）。它不在 `series` 里，kbuild-y14 也不读它，没有随本仓库发布。

## 平板上的现状（10-23 00:20）

- `/usr/local/src/linux-t52`：linux-t47 仓库的 worktree，检出 `y14`，跟踪文件无改动；**里面是 y14 的编译产物**（`.config`、`vmlinux`、`arch/arm64/boot/Image` 等，都是 ignored 文件）。
  - `t52-base` = `bd67eaaef7d1`（tree `ef2f8b3397ef`）= v7.3 `c03c1a14507d` + 134 个上游补丁。
  - `y14` = **`5a21a30d2c6b`（tree `3ebb70be1ebb`）** = t52-base + 22 个提交。
    - 10-22 的 `4b29628178a5`（tree `2f676d5be31b`，21 个）是它的父提交。
    - 1051 用 `git am` 提交：作者 Xilin Wu，committer `y700-kbuild <y700-kbuild@localhost>`。
  - 临时分支 `y14-dry` 已删。
  - 这个仓库是浅克隆（grafted 在 v7.3），1051 的 `Fixes: b791dcfcba3a` 在这里查不到。
- `/usr/local/src/tb323fu-linux-t52/`：上游 t52 tag 的 `kernel/` 目录（aw882xx、initramfs、配置片段、补丁）。
  - 10-23 补了 initramfs 要用的 `android/back-to-android` 和 `userspace/platform/src/keyhold.c`，都取自 t52 tag，见上文。
  - 和旧 `/usr/local/src/tb323fu-linux` 比：initramfs/、aw882xx 源码和这两个文件逐字相同。
- `/root/y14-patches/`：本目录 `patches/` 的拷贝（22 个 + series），sha256 逐个一致。
- `/root/kbuild-y14.sh`、`/root/y14-verify.sh`：本目录脚本的拷贝（已去 CRLF）。
- `/root/t52-upstream-patches/`（134 个）和 `/root/t53-upstream-patches/`（只有 0142）留着，重建 t52-base 用得上。
- **`/usr/local/src/linux-t47`（y13 现役树）的工作区没动**，未提交的 y13 补丁仍在。
  - 只往它的仓库里 fetch 过 v7.3 tag 的对象，worktree 共享这个对象库。
  - 所以**别在 linux-t47 里 `git gc --prune`** 掉 y14 的提交：它们挂在 `y14` 分支和 `t52-base` tag 上，正常 gc 不会删。
- 日志：
  - `/root/y700-kernel-y14.log`：成功的那次（末行 `KFULL_OK`）；
  - `/root/y700-kernel-y14-check.log`：10-23 的 `CHECK_ONLY` 日志（`CHECK_ONLY_OK`）。
  - 第一次失败的日志看完已删，根因见上文。

## 上游 t49 → t52 变了什么

- **基线 v7.3-rc4 → v7.3**。0067–0071 和 0140 已经在 v7.3 里，被上游删掉；0115 本来就故意不在系列里。
  - 本地树 y13 → y14 共 1545 个文件不同，约 +30k / −8.6k 行，几乎全是 rc5…final 的通用修复。
  - 我们碰过的 msm/adreno、iris、battmgr、cpuidle、devfreq 文件在 rc4 与 v7.3 之间**没变**。
  - ath12k：v7.3 删了 panic notifier（core.c/core.h/hif.h/pci.c）。
- **t51 的 0131/0132**：y10–y13 里我们自己带着，现在在基线里。
- **t52 新增**：
  - 0133–0139：USB-C 上的四通道 HBR3 DisplayPort。具体是：
    - DP-only 模式下 PHY 不碰 USB PCS；
    - FSA4480 保持 USB2 开关；
    - dwc3 在 DP-only 模式用 UTMI 时钟；
    - DP 不对已建立的 sink 重做插入处理；
    - dts 里 PHY 标成 Type-C mode switch，baldur 改成四通道。

    上游例子是 5120×2160@75 Hz。**只有接外接显示器才用得到。**四通道模式下 USB3 的线被 DP 占用，那个口上只剩 USB2。
  - 0141：UFS 主机控制器复位（错误处理）后重设 MCQ 的 ESI 中断。只在出错复位时起作用。
- **0023 改了**：去掉 `dsiN: pclk=… byteclk=…` 这条 `pr_info`，改回 DBG。
  - 每次显示模式切换少两行 kmsg。`linux/net/KMSG-WATCH.md` 把它列为开机一小时后 kmsg 的主要来源之一，所以这是好事。
  - 仓库里没有脚本或体检项依赖这行。
- 上游 `config/` 下的 4 个 baldur 片段和 `reference.config`，t49 → t52 **逐字未变**。
- **t53 已出**：t52 + 0142（nt36523 面板加 144 Hz 模式）+ helper 0.4.3。
  - 0142 能干净打在 y14 上（`git apply --check` rc=0）。
  - **y14 没收 0142**，留给作者决定（见文末）。

## 补丁清单（应用顺序 = `patches/series`）

| # | 文件 | 来源 | 在 y14 里 |
|---|---|---|---|
| 1 | 00y1 iris 解码顺序 / 去块控制 | code002-2/sm8750-video-accel，即原 `/root/va-iris.patch` = `kernel-y2/upstream-patches/iris-decode-order-deblock-t47.patch` | 逐字同 y13 |
| 2 | 00y2 battmgr：status、I×V 的 power_now、mAh 单位 | y1 + y3 | **改基**：放到上游 0132 之上（原来是 0132 改基到它之上）。3-way 合并干净，结果与 y13 的 `qcom_battmgr.c` 逐字节相同 |
| 3 | 00y3 WCN7860 默认不报 MLO（`wcn7860_mlo=1` 才开） | y1 | 偏移 −23（v7.3 删了 panic notifier），内容同 y13 |
| 4 | 00y4 `wcn7860_5g_160` 开关 | y2 | 同 y13 |
| 5 | 00y5 信标丢失不挂备用断线定时器 | y3（`@1982` 那块） | 同 y13 |
| 6 | 0540 sigreturn 重设 SSBS | y4 | 偏移 +6（v7.3 的 SVE 恢复修复 `fpsimd_only`），内容同 y13 |
| 7–9 | 0620–0622 a6xx GMU/HFI 三条 | y4（armada-os/armada；作者见各补丁 From 行） | 同 y13 |
| 10–13 | 1030–1033 iris 四条 | y6/y7 | 同 y13 |
| 14 | 1041 ath12k 站点省电（`MODULE_VERSION("y700-1041")`） | y8（make-1041.py 生成） | 同 y13；提交说明是新写的，原文件只有 diff |
| 15 | 1042 memlat Android 调参 | y9 | 同 y13 |
| 16 | 1043 `allow_system_off` 开关 | y10 | 同 y13，仍排在 0106/0118 之后（它们在基线里） |
| 17–19 | 1046–1048 A8xx GMU 投票修复 | y12（linux-next） | 同 y13 |
| 20 | 1049 iris PSC_LAST 不当错误 | y13（ArmadaOS 1370） | 同 y13 |
| 21 | 1050 DPU 拒绝长度不对的 gamma LUT | y13（h0cheung 816d1a26） | 同 y13 |
| 22 | **1051 iris 错误缓冲保留时间戳** | **y14 新增**（radxa-pkg/libva-v4l2 d5df780 的 `patches/0004`，Xilin Wu） | 偏移 −66（hunk 起始行 965→899），内容同上游 |

- **00y1–00y5 是新拆出来的**。y1–y5 时代这些改动直接改在树上，只存了累计 diff（`y700-y5.patch`），没有单独的补丁文件。现在各自成为一个带说明的提交。
  - 拆分时核对过：y5 累计 diff 里 iris 那部分 = va-iris.patch（忽略 index 行）。
  - y13 树上改过的 20 个文件，在 y14 上逐个与 linux-t47 比对过。其中 19 个是 y14 补丁栈改的，另一个是 0131 改的 `msm_atomic.c`，现在在基线里。
  - 比对结果：除 signal.c 和 ath12k/core.c 只差上游偏移外，其余 18 个**逐字节相同**。
- **作者**：
  - 有 mbox 头的补丁原样 `git am`。
  - 只有 diff 的，作者记为 `y700 workspace <304558835+bobsixsixsix-boop@users.noreply.github.com>`。
  - 1049/1050 原文件 From 行没有邮箱，来源写进了提交说明的 `Origin (as recorded in the patch file): …`。
- **去掉的**：0131、0132。上游 t51 的补丁，已在 t52 基线里；0131 与我们带的逐字相同，0132 我们带的是改基版。
- **不在 y14 里**：1044（Oryon DC ZVA，y11 的 A/B 预留）、1045（PCIe L1SS）。
  - 10-22 核对过，两者在 y14 上都能带偏移干净打上，以后要做 A/B 时可以直接加提交。
  - kbuild-y14 会拒绝带着它们的树。

**冲突只有一处**：00y2 的 `@454` 那块上下文，碰上了 0132 往 `sm8350_bat_prop_map` 里新加的两项。用 `git am -3` 三方合并，结果与 y13 相同。

10-23 加 1051 前又核对了一遍 y13 的栈都在：
- kbuild-y13 的 18 个补丁 + va-iris，加上 y1–y5 的底座改动，在 y14 里都有对应：00y1–00y5、0540、0620–0622、1030–1033、1041、1042、1043、1046–1050。0131/0132 在基线里。
- 1044/1045 不在 series 里，树里也没有它们的标记。
- `git diff --stat`：y13（linux-t47 未提交改动）动了 20 个文件，y14（`t52-base..y14`）动了 20 个。
  - y14 少 `msm_atomic.c`（0131 已进基线）；
  - y14 多 `iris_buffer.c`（1051）；
  - `dpu_crtc.c`、`qcom_battmgr.c` 的行数比 y13 少，少的正是 0131/0132 那部分。
- 逐文件比对 y13 动过的 20 个文件（y14 HEAD 对 linux-t47 工作区）：18 个逐字节相同，其中 `msm_atomic.c` 是基线里的 0131。
  - 剩下 `signal.c`、`ath12k/core.c` 两个，去掉 `@@`/`index` 行后补丁内容和 y13 一样，只差上游偏移。

## 1051：iris 错误缓冲保留时间戳

- 改的是 `drivers/media/platform/qcom/iris/iris_buffer.c` 里 `iris_vb2_buffer_done()` 的 `V4L2_BUF_FLAG_ERROR` 分支：`vb2->timestamp = 0;` → `vb2->timestamp = buf->timestamp;`。错误状态和零 payload 不变。
- 来源：radxa-pkg/libva-v4l2 提交 d5df780 带的 `patches/0004-media-iris-Preserve-timestamps-on-error-buffers.patch`。作者 Xilin Wu，`Fixes: b791dcfcba3a`。
- **为什么要**：码流有坏帧时（例如 HEVC 切片被截断），HFI gen2 固件返回该帧时带 `HFI_INFO_DATA_CORRUPT` 和原时间戳，但驱动把时间戳清零后才交给用户态。
  - libva-v4l2 从 785fd3d/d5df780 起按时间戳找回坏的是哪一帧，用中性灰帧顶上（`replaced damaged picture`）。
  - 时间戳是 0 就找不到，`vaSyncSurface` 一直等到 5 s 的 `surface sync timeout`：画面卡 5 秒，然后报解码错误。
- 主线 v7.3、上游 kernel-t52 都还是 `= 0`。补丁在 t52 上只有偏移 −66：hunk 起始行 radxa 原件 `@@ -965,7` → 我们的导出件 `@@ -899,7`，改动的那一行 968 → 902。
- 原件 `linux/kernel-y8/1051-media-iris-preserve-timestamps-on-error-buffers.patch` 是上游 mbox。提交说明里，`Fixes:` 前插了一段 `y700 (kernel y14): …`，写来源、原因和 `y700 patch file:` 行，所以 `git log` 里也看得到。
- kbuild-y14 的断言：
  - 抽出这个 `if (buf->flags & V4L2_BUF_FLAG_ERROR) {` 块（全文件只有一个）；
  - 块里必须有 `state = VB2_BUF_STATE_ERROR;` 和 `vb2->timestamp = buf->timestamp;`，不能有 `vb2->timestamp = 0;`；
  - 整个文件也不能再有 `= 0;` 的时间戳赋值。
  - 拿 10-22 的 y14（1051 之前）的 `iris_buffer.c` 反测过：断言能抓到。
- 运行时没有日志字符串，所以 y14-verify 用 libva-v4l2 上游的 `tests/decoder/error-recovery.py` 实测，见下文。

## 怎么核对的

1. `t52-prepare.sh`：134 个上游补丁 `git am` 全部干净。
2. `y14-dryrun.sh`（10-22，当时 21 个）：补丁逐个 check/apply。只有 00y2 需要 3-way，结果逐文件与 linux-t47 比对。
3. `y14-branch.sh`：建分支并导出。用临时 index 把导出件重放到 t52-base，结果必须等于 y14 的树（`EXPORT_REPLAY_OK`）。
4. 仓库里的 `patches/` 拷到 `/root/y14-patches` 后再重放一次：`REPO_REPLAY_OK`。
5. `CHECK_ONLY=1 /root/kbuild-y14.sh` 跑通（`CHECK_ONLY_OK`）。它覆盖了：
   - 树的固定哈希；
   - 补丁文件重放；
   - y13 那套 grep 断言全过（1042、0131/0132、1043 × 11、1046–1048、1049/1050）；
   - check_config：bad=0，must-keep 一个不少，裁剪项没有被救回，片段全部生效；
   - 编译前的配置差异恰好是预期的两行。
6. 10-23 加 1051：`prep/y14-add-1051.sh`。
   - 先确认 y14 还是 10-22 的树（`2f676d5be31b`），再 `git am` 1051 原件。
   - 重新导出全部 22 个提交：前 21 个与 10-22 的导出 `cmp` 逐字节相同；
   - 导出件在临时 index 上重放，等于新树 `3ebb70be1ebb`（`EXPORT_REPLAY_OK`）；
   - 拷回本目录 `patches/`、再拷到 `/root/y14-patches/` 后 sha256 逐个一致。
   - 改 `Y14_TREE` 后重跑 `CHECK_ONLY=1`：`CHECK_ONLY_OK`。
7. 全量编译 `KFULL_OK`（见上文「10-23 编译结果」），编完树仍干净（跟踪文件 0 改动）。

## 配置

- **基础配置**：默认还是 `/root/config-t49.release`，可以用 `BASECFG=` 换掉。
  - 上游 t52 的 release 资产 `config-tb323fu-t52`（约 245 KB）**没下载**：下载要作者点头。
  - 空跑证明不下载也一样：在 t52 树上按上游 README 的配方生成配置（`defconfig` + `kaanapali-oneplus-infiniti_defconfig` + baldur、display、netfilter、extra 四个片段 + olddefconfig），结果与「t49 release + olddefconfig」**除 LOCALVERSION、INITRAMFS_* 外逐行相同**。片段本身 t49→t52 也没变。
  - 所以 t49 release 在 v7.3 上就等价于 t52 的配置。要是以后拿到 t52 release 配置，用 `BASECFG=/root/config-t52.release` 跑，脚本的差异检查会说明它是否真等价。
- **t49 release 在 v7.3 上 olddefconfig 后的变化**：
  - 真正的新选项只有两个：`CONFIG_ARM64_ERRATUM_3821522=y`（Cortex-A725 勘误），和隐藏项 `CONFIG_ARM64_WORKAROUND_BROKEN_AMU_CONSTCNT=y`（由 2457168/3821522 选中；它取代了原来 2457168 专用的 cpucap 名）。
  - 两者都是开机按 MIDR 匹配才生效，对 Oryon 核不起作用。
  - 其余差异是工具链和主机环境的探测行：`CC_VERSION_TEXT`、`PAHOLE_VERSION`、`RUSTC_*`、`OPENSSL_SUPPORTS_ML_DSA`、`DEBUG_INFO_COMPRESSED_ZSTD`、`DRM_MSM_VALIDATE_XML`。y13 是同一套平板工具链，这些行与 y13 相同，不算差异。
- **y14 配方 vs y13**（编译前对编译前）：**恰好那两行勘误**，别的一行不差。CMDLINE 与 y13 相同。
  - kbuild-y14 把它写成 `EXPECTED_DELTA`，编译前和最终配置各查一次，多一行少一行都停。
- **v7.3 新增的 Kconfig 符号**（相对 rc4）共 6 个：上面两个勘误开着；`CC_OPT_INLINE_MEMSET`、`DIMLIB_KUNIT_TEST`、`ERRATA_SIFIVE_MAL_9092`、`REFCOUNT_INTERRUPT_KUNIT_TEST` 依赖不满足，不出现。
- **片段在 t52 上仍然成立**：y8-trim / y8-power / y8-must-keep 里点名的 1132 个符号，在 t52 的 Kconfig 里**一个都没消失**。
- **顺带发现的旧缺口（y8 起就有）**：`apply_fragment` 和 check_config 的正则是 `[A-Z0-9_]`，名字里带小写字母的符号会被跳过。
  - y8-trim 的 `# CONFIG_ARM_CCI5xx_PMU is not set`：被依赖关掉了，结果对。
  - y8-trim 的 `# CONFIG_SENSORS_SHT4x is not set`：**从来没生效**，y8–y13 里 `SENSORS_SHT4x=m` 一直在，只是个用不到的 hwmon 模块。
  - must-keep 里 `FONT_TER16x32`、`FONT_8x16` 两行从来没被检查过，实际两项都在。
  - kbuild-y14 的处理：
    - must-keep 的正则改成 `[A-Za-z0-9_]`。检查变严了，配置不变。
    - 片段正则为了和 y13 对齐**保持原样**，在日志里把这两行打印出来。
  - 修掉片段正则 = 多一行差异（SHT4x 模块没了），影响可以忽略。修不修见文末。

## kbuild-y14.sh 和 kbuild-y13.sh 的区别

- `SRC=/usr/local/src/linux-t52`，`UP=/usr/local/src/tb323fu-linux-t52`（aw882xx、initramfs/build.sh 都取 t52 的拷贝），`MODS=/usr/local/src/y700-mods-y14`，`OUT=/usr/local/src/y700-kernel-y14`，`NAME=-tb323fu-t52-y14`。
- **不再做「线性栈探测」+ 现场 `git apply`**，改成只认一棵固定的树，在写任何东西之前检查：
  - 检出的是 `y14`；
  - 跟踪文件无改动；
  - v7.3 提交号对；
  - `v7.3..t52-base` = 134、`t52-base..HEAD` = 22；
  - 两个 tree 哈希与钉住的一致；
  - `/root/y14-patches/series` 必须**逐行等于**脚本里的 `EXPECTED_SERIES`（22 个文件名，顺序也要对），不对就打印 diff 停下；
  - `/root/y14-patches` 的补丁文件能重放出同一棵树。

  要改补丁栈：在 y14 上提交 → 重新导出 `patches/` → 改脚本里的 `Y14_TREE` 和 `EXPECTED_SERIES`（照 `prep/y14-add-1051.sh` 的做法）。**不要手改 worktree。**
- **编译前核对上游仓库里 initramfs 要用的两个文件**（`android/back-to-android`、`userspace/platform/src/keyhold.c`）的 sha256，以及 `kernel/initramfs/build.sh`、`kernel/out-of-tree/aw882xx` 在不在。这是 10-23 第一次编译失败后加的。
- va-iris 那行 `git apply` 去掉了，它现在是 00y1 提交。
- 1044/1045 的拒绝保留。grep 断言照 y13 抄，0131/0132 那几条现在检查的是基线。
- 新增 1051 的 grep 断言（见上文「1051」）。
- 「config 必须等于 y12」改成「相对 y13 的差异必须恰好是 `EXPECTED_DELTA`」。差异会打印进日志，编译前查一次，最终配置再查一次。
- must-keep 正则修了（见上）。片段里被跳过的小写行打印出来。
- `export LC_ALL=C`：保证排序稳定，日志里是英文。
- 补丁存档：`git diff t52-base HEAD > $OUT/y700-y14.patch`；产物 `Image-t52-y14[.gz]`、`config-t52-y14[.pre-build]`。
- 新增 `CHECK_ONLY=1` 模式：做完全部树检查和编译前的配置检查就退出，不编译，日志写 `/root/y700-kernel-y14-check.log`。
  - 它会在树里留下 `.config` 和 kconfig 工具。真编译会直接覆盖；想恢复干净用 `make LLVM=/opt/llvm-18/bin/ mrproper`。
- 没变的：
  - CMDLINE，和拒绝 `allow_system_off` 进 CMDLINE 的那条；
  - 片段配方和 check_config 的固定项；
  - aw882xx 分三次 make；
  - vermagic 逐个检查；
  - `ath12k.ko` 的 version = `y700-1041`；
  - initramfs 的生成方式；
  - Image 里 `allow_system_off` 的两条字符串。

## 构建时间与跑法

实测（10-23）：全量编译 **7 分钟**（00:09:15–00:16:17，到 initramfs 那步失败为止，Image 和 330 个模块都已编完），修好后增量重跑 **1 分钟**（00:17:51–00:18:47）。条件是 8 核、Nice 19、CPUWeight/IOWeight 20、电池供电，同时平板上还在编 libva-v4l2。参考：y5 全量 16 分钟（830 个模块），y8 接近全量 6 分钟，y12/y13 增量 4 分钟、1 分钟。

跑法（树里已有 y14 的编译产物，再跑是增量）：

```
cp linux/kernel-y14/kbuild-y14.sh /root/; sed -i 's/\r$//' /root/kbuild-y14.sh
# patches/ 拷到 /root/y14-patches/，同样去 CRLF
CHECK_ONLY=1 bash /root/kbuild-y14.sh          # 只查树和配置，末行 CHECK_ONLY_OK
systemd-run --unit=y700-kbuild-y14 --collect -p Nice=19 -p CPUWeight=20 -p IOWeight=20 /bin/bash /root/kbuild-y14.sh
tail -1 /root/y700-kernel-y14.log              # 必须是 KFULL_OK
```

同名 unit 还在跑时 systemd-run 会拒绝再起；`--collect` 让失败的 unit 也能被回收，不用 `reset-failed`。

## 装上之后要留意的事

- helper：
  - `serial_of_release("7.3.0-tb323fu-t52-y14")` 解析不出数字，得 0。和 y13 一样：install-local 时会警告「不是 -tb323fu-tNN 发布版」，官方 t52/t53 发布版会一直显示为「更新」。
  - 控制中心的 SeriesTag 来自 `/etc/tb323fu/series` 文件，不来自内核名，不受影响。
- `tools/y700-checklist.py` 的 `GOOD_KERNEL_TAG`（`-tb323fu-t\d+-y\d+$`）认得新名字，不用改。
- ath12k：`/etc/modprobe.d/y700-ath12k.conf` 只在 `/usr/local/lib/modules/y700/<uname -r>/` 存在时才用自编模块。y14 没有这个目录，所以用树内模块（带 1041，kbuild 断言了版本），和 y13 一样。
- 安装（名字照 y12/y13 的写法「y700 yN: 上一版 + 改了什么」）：`tb323fu-ctl kernel install-local /usr/local/src/y700-kernel-y14/Image-t52-y14.gz --trial --name "y700 y14: y13 on kernel-t52 (v7.3) + iris error-buffer timestamps 1051" --yes`，然后在平板空闲时重启。
- 重启后跑 `bash /root/y14-verify.sh`（root），见下一节；全过（`ALL PASS`，含 1051 两条 truncated 的 PASS）再 `tb323fu-ctl kernel keep`。
- 回退：y13 的镜像还在 `/usr/local/src/y700-kernel-y13/Image-t49-y13.gz`。
  - trial 期间（还没 keep）：`tb323fu-ctl kernel rollback` 把 good 的 y13 写回 boot_a，然后自己 `systemctl reboot`（`--reboot` 不会真重启）。不管它，两次启动不确认，第三次也会自动回 y13。
  - 已 keep 之后照 README「内核 y13」回 y12 的写法：`tb323fu-ctl kernel install-local /usr/local/src/y700-kernel-y13/Image-t49-y13.gz --trial --name "y700 y13: y12 + iris PSC_LAST 1049 + dpu gamma LUT check 1050" --yes`，重启，确认后 `kernel keep`。
  - 试用中的内核不能直接被 `install-local` 覆盖：要先 `kernel rollback`，再 install-local（README y4 的「坑 2」）。
- 装上之后**不要**再用 `/usr/local/src/linux-t47` 编东西去覆盖 y14 的产物目录；两棵树的产物目录是分开的（`y700-kernel-y13/` 与 `y700-kernel-y14/`），互不影响。

## y14-verify.sh

由 `linux/kernel-y8/y13-verify.sh` 派生。y13 的 72 项**全部保留**（drm/msm、iris、battmgr、cpuidle、devfreq 的文件在 rc4 与 v7.3 之间没变，日志字符串一样）。改动：

- uname 期望值改成 `7.3.0-tb323fu-t52-y14`。
- vaapi-check.sh：它 10-23 起流失败时退出码非 0。体检把它的输出缩进打印，**退出码非 0 就是 FAIL**；`/root/vaapi-check.sh` 不存在也算 FAIL（y13-verify 是 SKIP）。
  - 10-23 还在继续收紧它（任何 `iris-vaapi:` stderr 行也算失败，并加一条 VP9 流），所以检查项名字不再写「三条流」。体检只看它的退出码，流的数目变了不用改体检。
  - **已知偶发**：10-23 升级前在 libva-v4l2 `ef18ba0` 上，`hevc-main-vui.265` 第一次就报了一行 `Failed to destroy decode context 0x6: 38`（38 = VA_STATUS_ERROR_TIMEDOUT，销毁上下文时还有没出完的帧，帧数仍是 90/90），之后约 90 次只又出现一次；`6d03c3f` 上约 40 次 HEVC 8-bit 解码都干净（见 libva-v4l2 升级那条 README）。所以 y14 上如果 vaapi-check 是**唯一**的 FAIL、打印的错误行就是这一行，**先单独重跑一次 `bash /root/vaapi-check.sh`**，再过就记下频率，不要马上怪内核、回滚。体检在这一项 FAIL 时会打印同样的提示。
- 新增「y14」一节：
  - **跑的就是编出来的那个**：`uname -v` 必须出现在 `Image-t52-y14` 的字符串里；`/proc/config.gz` 与 `config-t52-y14` 逐字节相同；构建日志末行 `KFULL_OK`；加载的 `qcom-iris.ko` 与 `y700-mods-y14` 里的逐字节相同（y13 上同样的三项都核实过成立）。
  - **补丁存档**（`y700-y14.patch`）里有 0620（HFI 中断只清 CM3_FAULT）、0621（两处 2 s 等待）、0622（GMU 启动前屏蔽 HFI）和 1051 的那几行。和上面几项连起来，就证明运行中的内核带着它们。
  - **0620–0622 运行时**：`/proc/interrupts` 里 `hfi` 计数为 0 且 `gpu-irq` > 0；`gmu` 计数为 0。y13（同样三条补丁）跑 10.5 小时、300 万次 GPU 中断后两者都是 0。
  - **1051 运行时**：以 user 身份跑 libva-v4l2 上游的 `tests/decoder/error-recovery.py`（原样，不改），对**已安装的** `/usr/local/lib/aarch64-linux-gnu/dri/v4l2_drv_video.so`。
    - 三个测试文件拷进 `mktemp -d /tmp/y14-recovery.XXXXXX`，chown 给 user，跑完删。
    - `timeout -k 10 180`：最多 3 分钟。退出码必须是 0（124 = 超时）。
    - `8bit-b0-truncated`、`10bit-b0-truncated` 两项必须是 `PASS` 行：截断切片的 HEVC，固件以 `HFI_INFO_DATA_CORRUPT` 返回那一帧；只有带 1051，错误缓冲上才有时间戳，libva-v4l2 才能用灰帧顶上。
    - **原样的上游测试没有任何「预期失败」处理，也不会打印 XFAIL。** 没有 1051 时（y13、或回滚后的内核）：跑完 8bit-b0 的 11 个注入用例（11 行 PASS）后，`8bit-b0-truncated` 卡满 5 s 的 surface sync timeout（销毁上下文再超时约 5 s），ffmpeg 非 0 退出，`decode()` 里的 `assert result.returncode == 0` 抛 AssertionError，脚本带 traceback 以 rc=1 结束。后面 22 个用例（8bit-b0 的两个失败注入、10bit-b0 全部含 `10bit-b0-truncated`、8bit-b3 全部）**根本不跑**。所以在没有 1051 的内核上这一块的预期是：「ran to the end」FAIL（rc 1）、两条 truncated 都是 FAIL（no PASS line）、末尾打印 traceback。
    - `XFAIL` 只出自 `linux/video/libva-v4l2-update.sh`：它在 y13 及更早的内核上（`uname -r` 以 `-yN` 结尾且 N≤13）跑的是**改写过的测试副本**，给 truncated 那段包上 `except AssertionError`：只有该用例自己的日志（`out/<label>-truncated.log`）里有 `surface sync timeout`（y13 的已知特征）才打印 XFAIL 并继续；子进程超时（单次解码 ≥ 30 s 的 `subprocess.TimeoutExpired`）和其它任何失败照样往上抛，算真 FAIL。`LIBVA_EXPECT_ERRTS=0|1` 可以覆盖按内核名的判断。体检不用这个包装。
    - 判定（不变）：退出码 0（34 个用例全部跑完且通过，6d03c3f 是 34 个）**并且**有 `PASS 8bit-b0-truncated:`、`PASS 10bit-b0-truncated:` 两行。检查项名字里写的是「PASS line present」或「no PASS line」。
    - **y13 基线**：`runs/upstream/20261023-libva-v4l2-6d03c3f-update.log`（10-23 00:14，升级 libva-v4l2 时在 y13 上跑的，带上面的 XFAIL 包装）：32 PASS + 2 XFAIL（`8bit-b0-truncated`、`10bit-b0-truncated`，都是 AssertionError，surface sync timeout）+ 0 XPASS。也就是说，**非截断的 32 个用例在 y13 + 已安装的 6d03c3f 驱动上全过**；y14 上多出的只该是那两行 truncated 由 XFAIL 变 PASS。那次之后平板 `dmesg -k -l err` 没有 iris 行。
    - 其余用例通过 LD_PRELOAD 垫片注入 V4L2 错误，测的是 libva-v4l2 自己的灰帧恢复；它们任何一个失败、或单次解码超过脚本自带的 30 s，测试以非 0 退出。
    - 需要 libva-v4l2 ≥ d5df780（平板上 10-23 00:14 装的是 6d03c3f，带这个测试）。找不到测试或驱动 = FAIL，提示先更新 libva-v4l2。
    - iris 把 `HFI_INFO_DATA_CORRUPT` 只记在 debug 级，所以跑完再查一遍「iris 没有 err 级日志」。
    - **用时没实测**：3 次 x265 生成 + 37 次 320×240×120 帧的小 HEVC 解码（3 次干净参考 + 34 个用例），其中一次（`IRIS_TEST_ZERO_TIMESTAMP`）故意等 5 s 超时，估计 1–2 分钟。上面那份 y13 基线日志没有逐用例时间，不能拿来推算。y14 上第一次跑体检时看 INFO 行的秒数补进这里。
    - 这一节的体检本身（原样测试）没在 y13 上跑过：10-23 00:25 平板正在播放视频，不想抢 iris 解码器。在 y13 上跑它也只会得到上面说的 rc=1 + traceback，没有新信息；y13 的对照用上面那份包装后的基线日志即可。
    - `Y14_NO_RECOVERY=1` 跳过这一块（会打印 SKIP）。
  - **t52 新内容里不需要外接显示器、也不需要 UFS 出错就能查的**：
    - 0023：dmesg 里不再有 `dsiN: pclk=` 行（y13 开机 10 小时约 1000 行）；
    - 0138：设备树 `phy@88e8000/mode-switch` 存在；
    - 0139：`usb@a600000/mode-switch` 存在，DP 输出端点 `data-lanes` 是 4 通道（16 字节）、`link-frequencies` 4 项（32 字节）；
    - 0136：`/sys/class/typec_mux/a600000.usb-mux` 存在（dwc3-qcom 注册的 Type-C mux）；
    - DP 连接器存在（只有接显示器才算真测了 0133–0139）；
    - 0141：开机有 `1d84000.ufs: ESI configured` 和 `MCQ configured`，且没有 err 级 UFS 日志（0141 本身只在错误处理复位后起作用）。
  - 最后打印 y14 相对 y13 多出的两行勘误配置。
- 环境变量：`Y10_NO_TOGGLE=1` 跳过 1043 开关的运行时切换测试（同 y13）；`Y14_NO_RECOVERY=1` 跳过 error-recovery。
- 在 y13 上空跑过（预期部分 FAIL；那次没有跑 error-recovery，见上）：补丁存档、irq 计数、UFS 几项 PASS；身份、设备树、0023 几项 FAIL，因为跑的是 y13。逻辑符合预期。
- 1051 那几行的判定（PASS 行 + 退出码）在 PC 上用假日志测过三种情况：y13 原样输出（11 行 PASS + traceback、rc 1）→ 三项 FAIL；y14 正常（两条 truncated PASS、rc 0）→ PASS；只有 `XFAIL …-truncated` 行（包装的格式）→ 两条 truncated FAIL，不会被当成通过。
- 设备树检查读的是 `/proc/device-tree`，不碰 debugfs 里的 dri 寄存器。

## 试装与 keep（10-23）

- **02:3x trial 安装，02:36 重启进 y14。** 第一次体检（`runs/kernel/y14-verify-20261023-0236.log`）90 项 PASS，只挂 vaapi-check 一项：两条 VP9 流各打 7 行 `iris-vaapi: replaced damaged picture`。
- **那一项不是内核回归**，是 1051 把 libva-v4l2 的一个问题暴露了：libva-v4l2 把 VP9 隐藏帧包成「隐藏帧 + show_existing」超帧提交，Iris 先对隐藏的那半回一个空的 NOSHOW CAPTURE（内核标 `V4L2_BUF_FLAG_ERROR`），再回真画面。没有 1051 时那个错误缓冲的时间戳是 0、匹配不上任何帧；有了 1051 它带上了这帧的 token，libva-v4l2 就把 surface 换成灰帧、再把随后到的真画面丢掉。只有码流后来用 show_existing_frame 显示那个槽位时，灰帧才会上屏。
- **修在 libva-v4l2 这一侧**：本地补丁 `linux/video/libva-v4l2-patches/0001-…patch`（只吃隐藏帧的第一个 bytesused=0 的 ERROR CAPTURE；真错误、更晚的帧先回来、NOSHOW 后 1 s 没画面这三种情况照旧灰化），03:58 由 `libva-v4l2-update.sh` 装上（`2de1857` = 6d03c3f + 0001）。没改内核：iris 标 ERROR 的地方分不清 NOSHOW 和真错误，要往缓冲上加状态，还得编 y15；radxa 自己的 0004 配上游 libva 也有同样的问题，修在 libva 一侧对上游更有用。完整记录在仓库 README「视频硬解」一节的「2026-10-23 y14 上 VP9 隐藏帧被刷成灰帧」。
- **体检跟着加强**（`y14-verify.sh`）：
  - vaapi-check 是 7 条流（加了两条 `-sef`，让隐藏帧真的上屏），逐帧 framemd5 和软解比；
  - 新加一项 `/root/vp9-hidden-check.sh`（`linux/video/vp9-hidden-check.sh`）：VP9 隐藏帧的故障注入，判据「只在真坏时灰、永远不等 sync 超时」；
  - **cx-auto 分支**：03:59 重跑时另有 6 项 FAIL，全是 1043/0118 旋钮的开机默认值：y700-cx-auto 03:04 熄屏用电池时按设计打开了两个旋钮（E3a 日常省电），体检却还按「开机后没人动过」去查。现在本次开机 `journalctl -b -u y700-cx-auto` 里有 `armed` 行时，那几项（开机默认 N、system 域没进过、apss 为 0、切换测试、旋钮没被留开）打一行 SKIP，改查「现在 armed 就两个旋钮都是 Y，没 armed 就都是 N」。「cluster domains refused (0118)」那项挪到分支前面，照常检查。想测那几项就开机后亮着屏、插着电马上跑（02:36 那次就是这样，都 PASS）。
- **04:01 ALL PASS**（84 项 PASS，`runs/kernel/y14-verify-20261023-0401.log`），**04:03 `tb323fu-ctl kernel keep`**，good 是 `7.3.0-tb323fu-t52-y14`。
- **keep 后按体检的 CHANGED 核对**：
  - 内核是我们编的（体检 OK 行）；
  - vermagic：`ath12k`（version `y700-1041`）、`ath12k_wifi7`、`snd_soc_aw882xx`（`updates/`）都是 `7.3.0-tb323fu-t52-y14`；
  - 看门狗字符串在 y14 树里都还在：`drivers/net/wireless/ath/ath12k/mac.c:12737` `failed to flush transmit queue`、`drivers/gpu/drm/msm/disp/dpu1/dpu_encoder_phys_vid.c:583` `vblank timeout`。本次开机 kmsg-watch 真匹配到 4 行 vblank timeout（869 s、1340 s 各两行，熄屏/亮屏时），起了显示看门狗，没到重设面板的门槛；上一次开机（还是 y13）是 10 行。selftest 正常；
  - kscreen-doctor 模式名不变：`1904x3040@120/164/90/60/30`；
  - **没 `--save`**：同一次体检里还有 LIVI 9.4.0 → 10.0.0 的 CHANGED（CarPlay 相关的改动），`--save` 会一起确认掉；PC 端每天的体检任务会带 `--save` 跑。
- **顺带发现并修了飞行记录器的 bug**：体检 WARN「flightrec-6be57ad2.log 不存在」。记录器启动时按 mtime 清理旧日志，开机时 RTC 在 1970，本次的新日志被当成最旧的删了。与 y14 无关，只是这次开机日志目录刚好第一次凑满 12 份。修法和测试见 README 飞行记录器一节（提交 `5c4af3e`）。

## 有意不做的事

- ~~**编了，没装、没重启**~~：10-23 02:36 已 trial 装上重启，04:03 keep，见下「试装与 keep」。
- **没在 y13 上跑原样的 error-recovery.py**：平板当时正在放视频，不想抢 iris 解码器；而且没有 1051 时原样测试只会在 `8bit-b0-truncated` 处 rc=1 中止。y13 基线用 10-23 00:14 带 XFAIL 包装跑的 `runs/upstream/20261023-libva-v4l2-6d03c3f-update.log`（32 PASS + 2 XFAIL）。体检给了 3 分钟上限。**y14 上实测 19–20 s**（10-23：02:36 20 s、03:59 20 s、04:01 19 s，都是 34 PASS）。
- **没下载 t52 的 release 配置**：没有作者的同意不下载。空跑已经证明用不着它。
- **没收 t53 的 0142（144 Hz）**：这是新功能，不是修复，会多出一个刷新率档。它和我们的 `msm.idle_refresh_ms60/30` 空闲降频、KWin 选模式怎么相处，没验证。要收，就作为 y14 之后单独的一步。
- **没修片段正则**：为了让 y14 和 y13 的配置差异只剩 v7.3 本身带来的那两行，A/B 时好归因。
- **没碰 1044/1045、`candidates/` 里的草稿**，也没碰 README 与 `tools/upstream-state.json`。

## 待作者决定

y14 已经 keep（10-23 04:03）。剩下的：

1. ~~trial 装、重启、体检、keep、体检的 CHANGED 核对、y14 上的 libva 两个 `-truncated`~~：10-23 都做完了，见上「试装与 keep」。还要做的：
   - 头几天留意 USB-C（gadget usb0/ttyGS0、角色切换、充电，0133–0139 动了 PHY/dwc3/FSA4480）、UFS（err 级日志，0141）和 vblank 超时次数（体检的 INFO 行）；10-23 04:2x 第一次看过，都正常，见 README「内核 y14」待办；
   - 在 Chrome 里播放过 YouTube 视频后，查 `journalctl --user -b | grep -c "replaced damaged picture"` 应为 0；
   - libva 补丁 0001 报上游要作者同意。
2. 停在 t52，还是加上 t53 的 0142（144 Hz 面板模式）。要加就作为 y14 之后单独的一步（y15），先想清楚它和 `idle_refresh_ms60/30`、KWin 选模式的关系。
3. ~~1044（Oryon DC ZVA）/ 1045（PCIe L1SS）的 A/B~~：10-23 评估后暂不做（1044 没有复位证据：cx-auto 每天开 E3a 没出过复位；1045 只读探针与研究预期一致，L1.2 最多值 0.01–0.02 W、低于测量噪声）。1045 的 DT 一行等下次编内核时顺带加。理由全文在 README「内核 y14」待办。
4. 要不要下载 t52 release 配置做交叉核对（可选，空跑已说明等价）。
5. 要不要修片段正则（`[A-Z0-9_]` 跳过带小写字母的符号：`SENSORS_SHT4x` 从 y8 起没被裁掉，must-keep 的 `FONT_TER16x32`/`FONT_8x16` 以前没被检查）。修了 y14 之后的内核会多一行差异（SHT4x 模块消失），留到以后和别的配置改动一起做。

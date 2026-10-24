# Y700 五代刷 ColorOS（16 或 17）＋ 给 Linux 留盘

写于 2026-10-11，最后更新同日。读者：到时候在 Windows 电脑上执行刷机的人。

> **警告**：仓库根目录的 `flash_coloros.py` 会经 EDL 重写全部 6 个 LUN 的分区表和几乎所有分区（约 21 GiB），扇区号按一台特定平板写死；`prep_pkg.py` 会改刷机包里的分区表和补丁 XML。用在别的设备、别的包或别的固件上，或刷写中途断开，都可能让平板变砖、丢失全部数据、失去保修，并可能永久影响 Play Integrity / Widevine（见第 4 节）。本仓库不提供、也不链接任何 ROM 包或 loader；非官方项目，与联想、OPPO、高通无关，按现状提供、无任何担保，风险自负。
> **Warning: `flash_coloros.py` rewrites the partition tables and nearly every partition of the tablet over EDL with sector numbers hard-coded for one device; misuse can brick it and erase all data. No warranty, use at your own risk.**

## 0. 已定的事

- 作者确认：**Android 数据全部不要**；**不解锁 BL**（据移植作者和其他用户反馈，同型号设备上实刷验证过）。
- 分区：**Android userdata 固定 128 GiB，LUN0 剩余全部给新分区 `baldur-root`**（Linux 用，上游 initramfs 按这个分区名找根）。
- 刷机由我在本机用命令行 bkerler/edl 执行，不用作者的刷机匣 GUI。原因是命令行能完整记日志、能回读校验，而且要改分区表。写入内容与刷机匣按作者图选 12 个 XML 时完全一致，差异见第 3 节。
- 2026-10-11 作者决定：**刷 17**（分析见 [coloros17-analysis.md](coloros17-analysis.md)），**efisp 用包里的**。实际命令用 `--pkg v17 --efisp package`。

## 1. 包

- 7z：第三方移植包（ColorOS 16.0.8.301 移植，底包 ZUXOS 2.0.11.076，第九版；本仓不提供、不链接，文件名从略），sha256 `a6bc9606…a319`。
- 已解到 `coloros-v9\image\`（133 个文件，22 GB）；`coloros-v9\image.SHA256SUMS` 是解包后的清单（含我改过的文件）。
- 标准高通 9008 全量包，底包 ZUXOS 2.0.11.076（PRC），只写 slot A，自带 KernelSU 3.2.5 LKM 的 init_boot。
- 作者流程：9008 发引导 → 刷机匣选 patch0-5 + rawprogram_save_persist_unsparse0 + rawprogram1-5 → 刷完进 recovery 格式化 data → 开机装 KernelSU APK → 刷附加模块。

## 2. 写入范围（逐条解析 XML 得出）

- LUN1：xbl/xbl_config/multi_image/apdp/tme/xbl_ac_config + GPT。
- LUN2/3/5：GPT；LUN3 另把 `ddr` 分区清零。
- LUN4：slot A 的全部固件与系统引导分区（abl、tz、hyp、aop、modem、dsp、boot、init_boot、vendor_boot、vbmeta、dtbo、recovery 等 43 项）+ **efisp** + GPT。布局与平板 2026-10-10 快照逐项一致（99 项起止全同）。
- LUN0：super（20 GiB）、vbmeta_system_a、metadata、dataext_a + GPT。
- **不碰**（XML 里 filename 为空，QFIL/edl/刷机匣都跳过）：persist、oemowninfo、ssd、misc、keystore、frp、rawdump、dataext_b、vbmeta_system_b。persist 等设备独有校准数据保留。
- 槽位属性：包里 LUN4 GPT 的 A/B 属性全是 0（工厂态），由 ABL 默认选 A。平板现在“A 不可启动、B 活动”的标记会随新 GPT 消失。

## 3. 相对作者流程的改动（都在 `coloros-v9\image\`，原件留 `.orig`）

| 文件 | 改动 | 原因 |
|---|---|---|
| `gpt_main0.bin` / `gpt_backup0.bin` | userdata 结束扇区固定为 39215911（起点 5661480，正好 128 GiB）；新增第 15 项 `baldur-root`（Linux 文件系统类型 GUID，起点 39216128＝1 MiB 对齐）；重算两份 CRC | 给 Linux 留盘 |
| `patch0.xml` | 4 条“最后一个分区撑到盘尾”的补丁从 userdata（字节偏移 1704）改指 baldur-root（1832） | 让 baldur-root 而不是 userdata 吃掉剩余空间 |
| `flash_lun0.xml` | 由 `rawprogram_save_persist_unsparse0.xml` 去掉 11 条 userdata 写入 | 和刷机匣 `configure.ini` 的 SkipPart=userdata 一致；反正刷完要在 recovery 格式化 |
| `flash_lun4.xml` | 由 `rawprogram4.xml` 去掉 vm-bootsys_a、vm-persist 两条 | 包里没带这两个镜像；刷机匣遇缺文件跳过，别人实刷时这两个分区也没写 |
| `flash_lun4_keep-efisp.xml` | 同上，再去掉 efisp | 第 4 节的备选 |
| `flash_lun1/2/3/5.xml` | 原样复制 | — |

改后的 LUN0 GPT 已在模拟盘上跑过全部补丁验证：两份表头和分区数组 CRC 正确，所有分区有序不重叠，userdata＝128.00 GiB，baldur-root 到可用区末尾。userdata 原本的写入块都落在分区开头约 320 MB 内，缩小无影响。

## 4. 待作者决定：efisp

包里的 `efisp.img`（sha256 `3e6b7da9…f390`；17 版包里的 efisp 去掉填充后与它逐字节相同，含 `ABL_with_superfastboot` 字样，即 superturtlee 那一系）是 gbl_root_canoe 一系的补丁版 LinuxLoader。它让锁着的 BL 跳过签名校验，ColorOS 就是靠它在不解锁的情况下启动的。我把它和 miner7222/gbl_root_canoe（LTBox 采用的，平板现在用的是其中 6.2.192-mod2 ROW 版）全部 20 个发布，以及 superturtlee/gbl_root_canoe 的 5 个 efi 逐字节比过，**都不是同一个文件**。

LTBox 官方排障页原文要点：在锁 BL 的五代上刷 superturtlee 版 gbl_root_canoe 的 efi，Google 会停止给设备签发远程密钥；解锁再回锁、擦 efisp 都恢复不了；Play Integrity 三项全挂，Widevine 迟早掉 L3。上游 tb323fu-linux 的 rooting.md 也明确写了“不要手动往 efisp 写 GBL efi”。

| 选项 | 结果 |
|---|---|
| **A. 用包里的 efisp**（`--efisp package`） | 和作者及其他人实刷一致，ColorOS 能起来。代价可能是 Play Integrity 和 Widevine 永久受损（这个文件不是 LTBox 校验过的那种）。银行、谷歌钱包、Netflix 高清之类可能用不了。 |
| B. 保留平板现在的 LTBox efisp（`--efisp keep`） | TEE 不冒这个险。但上游实测 LTBox 那版只放行 boot 分区，ColorOS 还改了 vbmeta、dtbo、vendor_boot、super，**大概率红屏起不来**，之后再进 9008 补写包里的 efisp（多一轮，可回退）。 |

## 5. 到时候的操作（作者进 9008、接线后）

前置（一次性）：
1. 平板关机 → 按住音量加 → 插 USB，继续按约 10 秒，屏幕黑着即可。
2. **Zadig 装 WinUSB 驱动（作者点）**：打开 `y700-recovery\edl\Drivers\Windows\zadig-2.8.exe`（sha256 与官方发布一致）→ Options 勾 *List All Devices* → 下拉选 `QUSB__BULK` 或 `Qualcomm HS-USB QDLoader 9008`（USB ID 显示 `05C6 9008`）→ 右侧选 **WinUSB** → *Replace/Install Driver*。这一步会往系统装一张 Zadig 自签名证书，所以由作者自己点。

然后我依次跑（全部在 `C:\Users\me\AI\y700\`，日志在 `flash-logs\<时间>-<阶段>\`）：

```
python flash_coloros.py probe                        # 只读：存储信息、活动槽、6 个 LUN 的主备 GPT；确认 LUN0 够大
python flash_coloros.py backup                       # 只读：persist/devinfo/modemst1/2/fsg/fsc/keystore/secdata/uefivarstore/efisp 等
python flash_coloros.py flash --pkg v17 --efisp package --yes  # 写：一次 qfil 写完 6 个 LUN 并打补丁，约 21 GiB
python flash_coloros.py verify --pkg v17 --efisp package       # 只读：回读关键分区＋efisp 比 sha256，解析新 LUN0 GPT
python flash_coloros.py reset
```

- Sahara 用 `y700-recovery\loader\`（这台平板上实测成功过的那套）。如果 Sahara 握手失败，先换线换口、重进 9008，不改协议。
- `verify --super` 可以把 20 GiB super 也回读比对（多几分钟）。
- 只有开机卡死、确认是没选上槽 A 时才跑 `setslot --yes`。

刷完：
1. 平板重启后立刻按住 **音量下 + 电源**，进 recovery → 格式化 data。若已卡在 ColorOS logo，拔线强制关机再这样进。
2. 首启 ColorOS → 开发者选项开 USB 调试 → 本机 `adb devices` 授权。
3. 装 `color-rom-probe\v9\helpers\KernelSU_v3.2.5_32525-release.apk`，确认 Working；再刷移植包附带的附加模块 zip。
4. 验收：触控、刷新率、旋转、相机、麦、扬声器/杜比、Wi‑Fi、蓝牙、充电、休眠唤醒、Google 服务、Play Integrity、Widevine 等级、32 位应用、发热、待机掉电。
5. `adb shell ls -l /dev/block/by-name/baldur-root` 确认 Linux 分区在。

## 6. 回退与风险

- **槽 B 不是退路**：这台是虚拟 A/B，刷完 super 里只有 ColorOS 的系统，槽 B 没有可启动的系统。
- 刷写中途失败：重进 9008 重跑 `flash`（qfil 可整体重来）。
- 想回 ZUI：需要 ZUI 全量 9008 包。本机没有；别处另存有 ROW104 全量包（6.4 GB）和国行 088 原始整盘备份（25 GB）。届时 LUN0 分区表要用对应包的原版或再改。
- `backup` 阶段导出的设备独有分区要另存一份到别处，它们是救砖时唯一无法从固件包恢复的东西。
- Linux：分区只是留好了，**Linux 本身没验证过**。之前 kernel-t47 在 ROW187 固件上挂死；ColorOS 包换成 PRC 076 底层固件，能不能起要重新测。上游方案用 boot_a 装 Linux、boot_b 放 Android 引导，与 ColorOS 的槽位关系也要重新设计。

## 7. 本机素材

公开仓库只含三个脚本和两份文档；下面其余目录（解包镜像、改过的 GPT、edl-win、gbl-compare、color-rom-probe 等）都不随仓库发布。

```
C:\Users\me\AI\y700\
├── flash_coloros.py            刷机脚本（plan/probe/backup/flash/verify/setslot/reset，--pkg v16|v17）
├── prep_pkg.py                 给包改 LUN0 分区表、生成 flash_lun*.xml（可重复执行）
├── analyze_pkg.py              拆解一个 9008 包：写入清单、分区表、efisp、AVB、设备独有镜像
├── coloros17-analysis.md       17 版包分析与 16/17 对比
├── coloros-v17\image\          17 版解包 + 改过的 GPT/patch + flash_lun*.xml
├── coloros16-plan.md           本文
├── coloros-v9\image\           解包后的镜像 + 改过的 GPT/patch + flash_lun*.xml（原件 *.orig）
├── coloros-v9\image.SHA256SUMS
├── edl-win\                    bkerler/edl 上游最新（1cda1a6），默认缓冲区，venv 已装（跳过 pylzma）
├── gbl-compare\                两个 gbl_root_canoe 仓库的 efi 发布，比对用
├── color-rom-probe\v9\helpers\ 刷机匣、KernelSU APK、附加模块、作者说明与 XML 选择图
└── y700-recovery\              上一轮 Linux 工作的工具、loader、原厂 boot、Zadig
```

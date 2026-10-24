# ColorOS 17 包（OPPO Pad Mini 移植 第二版）分析

写于 2026-10-11。与 16 版的对照和刷机命令见 [coloros16-plan.md](coloros16-plan.md)，两个包共用同一套刷机脚本（`--pkg v16|v17`）。

## 包是什么

- 文件：第三方移植包（ColorOS 17 移植，OPPO Pad Mini 第二版；本仓不提供、不链接，文件名从略），12.5 GB，sha256 `a13d2202…04cf6`（全值在 `coloros17-7z.sha256`）。
- 解到 `coloros-v17\image\`（158 个文件，24.6 GB），清单 `coloros-v17\image.SHA256SUMS`。
- 包里只有 `image\` 和 KernelSU 3.3.0 APK，**没有作者说明、没有刷机工具、没有 9008 引导文件**。引导用我们自己那套 `y700-recovery\loader\`，刷机流程同 16 版。
- **性质：作者从自己那台平板整机导出的分区备份**，不是 16 版那种按官方格式重打包的刷机包。证据：
  - 文件按分区名命名，A/B 两槽、各种状态分区都有。
  - LUN4 分区表里带着作者机器运行时的槽位状态（A 活动且已成功启动）。
  - 包里有只属于作者那台机器的数据（见下）。
- 槽 A：ColorOS 17，内核 6.12.30，boot/init_boot/vendor_boot/dtbo/recovery 指纹是国行 **ZUXOS 2.0.12.088**。vbmeta_a 和 vbmeta_system_a **不带签名**（algo=0）。init_boot_a 已内嵌 KernelSU。
- 槽 B：只有 boot/init_boot/vendor_boot/vbmeta 有内容，指纹是国行官方 **ZUXOS 2.0.12.255**（2026-09-19，安全补丁 2026-08-05）。**xbl_b、abl_b、tz_b、hyp_b、aop_b、modem_b、dsp_b 全部是零。**
- 分区布局：6 个 LUN 都和 16 版包完全一致；LUN4 和你平板 10-10 的快照也一致。
- super：20 GiB 原始镜像，里面是 OPLUS 的 my_* 分区，确认是 ColorOS。

## efisp：和 16 版是同一个程序

17 版的 efisp（3 MB 整分区导出）去掉末尾填充后，和 16 版的 efisp **逐字节相同**。两者都带 `ABL_with_superfastboot` 和 gbl_root_canoe 的 GitHub 编译路径。`ABL_with_superfastboot` 这个名字和 superturtlee/gbl_root_canoe 1.1 版给联想 Y700 发布的文件名一致，但字节和那个发布不同。所以：

- 选 16 还是 17，efisp 的风险完全一样。
- LTBox 排障页说的“在锁 BL 的五代上刷 superturtlee 那版 efi，会永久损伤谷歌远程密钥”，适用于这个文件的可能性很大。

## 原包直接刷会出的问题

原包 `rawprogram*.xml` 会写下面这些。我生成的 `flash_lun*.xml` 已全部排除：

| 类别 | 分区 | 照搬的后果 |
|---|---|---|
| 作者机器的基带校准 | modemst1、modemst2、fsg（各 4 MB，有内容） | 覆盖你平板自己的射频校准 |
| 作者机器的安全数据 | secdata（含 “Baldur Attestation CA” 证书）、uefivarstore、spunvm、keystore | 克隆别人的设备认证数据 |
| 作者机器的状态 | frp（恢复出厂保护）、misc、qweslicstore | frp 可能让开机要求验证作者的谷歌账号 |
| 作者机器的日志 | logdump（512 MB）、logfs、xbl_sc_logs | 无用 |
| 全零的板级配置 | cdt | 清掉你这块主板的配置表，有变砖风险 |
| 作者机器的内存训练数据 | ddr | 改为写零，让平板重新训练，与 16 版做法相同 |
| 槽 B 全零固件 | xbl_b、abl_b、tz_b 等 | 槽 A 连续启动失败自动切 B 时，会反复掉进 9008 |
| 槽 A 的全零镜像 | vm-bootsys_a、qtvm_dtbo_a、pvmfw_signed_a | 清掉现有内容；16 版不写这三个 |
| 缺文件 | rawdump、last_parti | edl 会报错 |

排除后，17 版写的分区集合与 16 版基本相同。差异只有一处：16 版多写一份全新的 logfs 和 metadata。17 版不写 metadata，刷完后在 recovery 里格式化 data 时会一起清掉。

## 改动与验证

- `prep_pkg.py v17` 改 LUN0 分区表：userdata 固定 128 GiB，后面新增 `baldur-root` 占满剩余空间；`patch0.xml` 改为让它撑到盘尾，原件留 `.orig`。在模拟盘上执行全部补丁后，两份分区表的校验和都正确，分区有序、不重叠。
- `flash_lun*.xml` 由同一个脚本生成，规则写在脚本开头。`flash_lun4_keep-efisp.xml` 是不写 efisp 的备选。
- edl 刷完按 `xbl_a` 所在的 LUN1 设启动盘，确认无误。
- 写入量约 21.4 GiB（排除槽 B 后）。

## 16 和 17 怎么选

| | 16（第九版） | 17（OPPO Pad Mini 第二版） |
|---|---|---|
| 系统 | ColorOS 16.0.8.301 移植 | ColorOS 17 移植 |
| 底层固件 | 国行 ZUXOS 2.0.11.076 | 国行 ZUXOS 2.0.12.088（更新） |
| 包的来源 | 官方格式重打包，带作者说明、附加模块、刷机匣 | 作者整机导出，无说明、无附加模块 |
| efisp | 同一个程序 | 同一个程序 |
| 实刷验证 | 据称其他设备验证过 | 未知 |
| 需要我额外处理 | 少 | 多：排除别人机器的数据、全零镜像和槽 B |

我的看法：处理过的两个包，写入风险已经拉平，选哪个主要看你要 16 还是 17。17 版底层固件更新，但缺作者说明。它的附加修复模块是给 16 写的，我不确定能不能用在 17 上。如果能确认 17 第二版有人在五代上实刷成功，选 17 没问题。

## 两个包共同的未知风险

两个包的引导固件都比你平板现在的 ROW 187 旧（076 和 088 早于 187）。如果 187 那次 OTA 抬高了硬件防回滚版本，旧引导会起不来，平板掉进 9008。9008 本身总能进，但那时要刷 187 或更新的全量包才能救，本机没有这种包。我没能从这一代签名格式里解析出防回滚号。如果其他设备实刷验证时也是从 187 或更新版本刷过去的，这个风险基本可以排除。

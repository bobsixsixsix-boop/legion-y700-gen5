# Y700 Linux 双系统：转到 Windows 继续救砖的交接记录

写于 2026-10-11，由 AI 助手整理，供在 Windows 电脑上接着做的人参考。
设备是 Lenovo Legion Tab Y700 五代（TB323FU）；之前做 EDL 主机的另一台 Linux 设备不一定在身边。

## 1. 设备现状（2026-10-10 17:05 最后确认）

| 项目 | 状态 |
|---|---|
| Android | ROW `TB323FU_ROW_OPEN_USER_Q00020.0_A16_ZUI_18.0.12.187_ST_260907`（Android 16, ZUI 18.0.12.187），**正常启动，可用** |
| 活动槽 | `_b`。槽 A 已被标记不可启动（GPT 属性 0xf3），不是退路 |
| bootloader | `unlocked:no`、`secure:yes`，verified boot `green`。efisp 里有 LTBox 写入的 GBL 补丁（让 ABL 接受改过的 boot/init_boot，但不等于解锁） |
| root | KernelSU（LKM）在 `init_boot_b`，`adb shell su` 可用，manager 显示 Working |
| boot_b | **已写回原厂 ROW187 boot**（sha256 `16195638…e392`） |
| baldur-root（LUN0, 8 GiB） | Codex 做的 Ubuntu 26.04 KDE 根文件系统，已部署，未动 |
| USB 调试 | 已授权（授权密钥在原主机的 `~/.android/adbkey`；换电脑要在平板上重新允许） |
| 危险物 | Android 里 Codex 装的 KernelSU 模块 `tb323fu-row187-b-switch`：**不要点它的 Action**，会把一个坏的 Linux 镜像写进 boot_b。建议在 KernelSU 管理器里删除 |
| OTA | 一定不要再让 ZUI OTA。能禁就禁：`adb shell pm disable-user --user 0 com.lenovo.ota`，`com.tblenovo.center` 同理（上游 after-install.md 的做法，反向） |

## 2. 结论：为什么 Linux 还没起来

- 用的是上游 https://github.com/joonhoekim/tb323fu-linux 的方案（mainline 内核 kernel-t47，GBL root，根在 `baldur-root`）。
- 上游开发机固件是 ROW **18.0.12.104**。这台在 Codex 操作期间被 OTA 到了 **.187**，官方 OTA 包换掉了 54 个分区，包括 xbl/tz/hyp/aop/cpucp/devcfg/qupfw/pdp/tme 等全部底层固件。
- kernel-t47 原版装进 ROW187 原厂 boot 容器后，内核在控制台切到 simpledrm 之后约 50 ms **整机挂死**（屏幕冻结、光标不闪），7–8 秒后被 bootloader 预先武装的硬件看门狗复位，循环。没有 panic。
- 十轮命令行诊断全部无效：跳过 24 个驱动（tsens、watchdog、PMIC 温度报警、UFS、cpufreq、sdhci、msm_drm、pwrkey、geni_i2c、restart/pon、dwc3、SCMI、osm_l3、optee、llcc_edac）、`cpuidle.off=1`、`nosmp maxcpus=1 nohz=off highres=off irqchip.gicv3_nolpi=1`、`clk_ignore_unused pd_ignore_unused`、`nomodeset`、拔线启动。结果表见 `README.md`。
- 已向上游报告：https://github.com/joonhoekim/tb323fu-linux/issues/9 （2026-10-10 05:32 提交，截至 10-10 17:00 无回复）。**请继续关注这个 issue**；作者回复里要的材料（initcall 顺序、OTA 分区清单、照片）当时都在 `notes/`（公开仓库只保留 initcall 顺序和上游 recovery.md）。
- Codex 当初的第一次失败还有另一个独立原因：它改内置 initramfs 时用 gzip FCOMMENT 填充，内核自带 gunzip 不支持 FCOMMENT。所以 Codex 那套镜像和它的 KernelSU 模块不要再用。

## 3. 下一步（按优先级）

1. **官方申请解锁 bootloader**（https://www.zui.com/iunlock，机型选"拯救者Y700 第五代"）。
   - 需要登录联想账号；表单对 Y700 分支只提交 序列号 + Bootloader_SN + 邮箱 + 验证码，IMEI 留空（已读过前端 unlock.js 确认）。
   - 10-10 遇到"今日解锁数量已达限额"（服务端状态 8，按天的全局名额），日切后尽早提交；别连点（状态 3 是频率限制）。
   - 联想说明：解锁不可逆、清数据、此后不能 FOTA、AI 功能不可用、保修作废；一个账号每年 3 台；Gmail 可能收不到 sn.img。
   - 解锁命令：`adb reboot bootloader`，`fastboot flash unlock sn.img`，`fastboot oem unlock-go`，按音量键选 UNLOCK、电源键确认。
2. **解锁之后**，两条路：
   - a. 刷回 ROW104 全量包（上游验证过的固件），禁用 OTA，然后按上游文档装 Linux（解锁后直接 fastboot 刷 boot，不再依赖 GBL）。ROW104 包来自第三方镜像，不随仓库发布（6.4 GB，包里 rawprogram/patch 是 LTBox 加密的 `.x`，Codex 当时自己解析出了 82 段写入清单，也未随仓库发布）。**未解锁时降级会因回滚保护无限重启**（第三方刷机教程明确说过；104 的 vbmeta_system 回滚计数 1783209600 低于 187）。
   - b. 等上游适配 .187，现有一切直接复用。
   - 作者还想换第三方 ROM（ColorOS/澎湃 移植包）。那也需要解锁；对 Linux 的影响取决于移植包的底层固件基线（接近 .104 可能可用）。
3. 只有在没有其他办法时才继续盲切分内核命令行；真正有用的是作者重编译加打点，或硬件串口。

## 4. 工具与材料（即本目录，当时在原主机的 `~/y700-recovery/`，打包见第 6 节；镜像、loader 二进制和日志不随公开仓库发布）

```
README.md                      现状、故障结论、EDL 操作要点、恢复 Android 的完整命令、十轮诊断表
HANDOFF-windows.md             本文
tools/sahara_min.py            极简 Sahara v3 多镜像 loader 上传器（pyusb），每个包都打印；PIECE 环境变量控制分片
tools/edl.sh                   bkerler/edl 包装（--memory=ufs --sectorsize=4096 + loader）；reset 子命令要直接调 edl.py
tools/setup-venv.sh            建 Python venv（pyusb pyserial docopt pycryptodome(x) colorama lxml capstone）
tools/boot-repack-kernel.py    上游工具原文件：把内核装进原厂 boot 容器（保留签名块和 AVB footer）
tools/build-boot.sh            上游构建脚本（参考）
tools/fb_getvar.py             pyusb 直连读 fastboot 变量（Fedora 的 fastboot 命令在原主机上会卡死）
edl/                           bkerler/edl 3.62 检出，已改 usblib MAX_USB_BULK_BUFFER_SIZE=2048、firehose MaxPayloadSizeToTargetInBytes=16384
loader/                        8 镜像 Sahara loader（qsahara_device_programmer.xml 和它列出的镜像，来自 CN 固件工具包；上游说 loader 只认机型不认区域；公开仓库不含这些文件，需从自己的固件包取，见 loader/README.md）
materials/row187-stock-boot_b.img              原厂 ROW187 boot（恢复 Android 用）
materials/linux-t47-row187-upstream-boot.img   上游 t47 原版内核 + ROW187 容器（会挂死）
materials/linux-t47-row187-diag{,2..10}-boot.img  十个诊断镜像（命令行见 README 表）
materials/Image-tb323fu-t47.gz                 上游发布的内核原文件
materials/gpt-lun4-{primary,backup}-0225.bin   LUN4 GPT 快照（当前设备仍与之一致）
materials/SHA256SUMS
notes/upstream-bug-report.md   发给上游的报告草稿（已作为 issue #9 提交；草稿和预填网址不随公开仓库发布）
notes/initcall6-order.txt      从内核镜像 kallsyms 解出的 level-6 initcall 真实顺序
notes/edl-log-20261010.txt, sahara-trace-20261010.txt   当晚全部 EDL / Sahara 包级日志（含设备信息，不随公开仓库发布）
notes/recovery.md              上游 docs/recovery.md 副本
```

Codex 的全部工作目录（固件包、OTA 包、8 GiB KDE 镜像、ROW104/187 提取的 31 个固件文件等）留在原主机上，总量太大，不随包转移，也不随公开仓库发布。

## 5. 在 Windows 上做 EDL 的注意事项

- 进 EDL（上游 recovery.md 第三种方法）：拔线 → 电源+音量减 8 秒以上强制关机 → 只按住音量加，按住的同时插线，继续约 10 秒 → 设备枚举为 `05c6:9008`。
- Windows 驱动：bkerler/edl 的 README 推荐 Qualcomm 9008 串口驱动 + UsbDk；上游作者当时用 Zadig 换 WinUSB 也成功过（之后 LTBox 看不到设备，要在设备管理器里卸驱动）。LTBox 自带 Windows 版，Flash Partitions 功能可直接写 boot_b。
- 原主机上遇到的 USB 问题（SuperSpeed 下 Sahara OUT 超时、USB 2.0 下大块丢字节、Type-C 角色翻转）是那台主机的 Type-C 口特有的，Windows PC 上大概率不存在；但如果 Sahara 一半失败，优先怀疑线和端口，不要改协议代码。
- Sahara 一旦被设备拒绝（status 34）或超时，必须重新进 EDL，不能续传。
- 写 boot_b 的参考命令（edl）：

```
python edl.py --loader=loader/qsahara_device_programmer.xml --memory=ufs --sectorsize=4096 w boot_b materials/<image>.img --lun=4
python edl.py --loader=loader/qsahara_device_programmer.xml --memory=ufs --sectorsize=4096 r boot_b readback.img --lun=4   # 回读比对 sha256
python edl.py --loader=loader/qsahara_device_programmer.xml reset
```

- 从 Android 里写 boot_b 更简单（上游"Switch to Linux"模块就是这么干的）：
  `adb push x.img /data/local/tmp/ && adb shell su -c 'dd if=/data/local/tmp/x.img of=/dev/block/by-name/boot_b bs=4096 conv=fsync && sha256sum /dev/block/by-name/boot_b'`，然后 `adb reboot`。
- 做诊断镜像的方法：解压 `Image-tb323fu-t47.gz`，在原始镜像里**原地等长**替换内置命令行（出现 2 处，286 字节，用空格补齐），`gzip -9 -n` 重压，再用 `boot-repack-kernel.py row187-stock-boot_b.img Image.gz out.img`。原命令行：
  `icc-rpmh.qos_disable=1 icc_rpmh.qos_disable=1 fw_devlink.sync_state=timeout fbcon=font:TER16x32 panic=10 oops=panic console=tty1 keep_bootcon qcom_scm.download_mode=full baldur.end=hold consoleblank=120 no_console_suspend mem_sleep_default=s2idle cpuidle_psci_domain.allow_cluster_off=0`
  想看 `calling …` 行必须带 `ignore_loglevel`。
- 不要信 Codex 封印的写入器（GPT 逐字节门禁 + compile-time seal），也不要用它改过的 Sahara 代码。

## 6. 把材料拿到 Windows

原主机上已打包：`~/y700-recovery-20261011.tar.gz`（不含 edlvenv；282 MB，sha256 以转交时给的值为准）。拿法任选：
- 同一局域网或 Tailscale：`scp user@<ip>:~/y700-recovery-20261011.tar.gz .`（原主机的 sshd 只认密钥）。
- 或插 U 盘复制。
- 最小必需集只有 `loader/`、`materials/row187-stock-boot_b.img`、`materials/Image-tb323fu-t47.gz`、`tools/boot-repack-kernel.py`、`notes/`；bkerler/edl 可以在 Windows 上重新 `git clone https://github.com/bkerler/edl`。

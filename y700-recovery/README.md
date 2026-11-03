# Y700 (Lenovo Legion Tab TB323FU, ROW 18.0.12.187) Linux 双系统：恢复工具与现状

整理时间：2026-10-10 凌晨（Claude 接手 Codex 的工作之后）。EDL 主机：另一台 ARM Linux 设备（Fedora）。

> **警告**：本目录的工具和命令（`tools/edl.sh`、`tools/sahara_min.py` + bkerler/edl 的 `w`/`ws`、`dd` 写 `boot_b`）会直接改写平板分区。写错分区、用错镜像、固件版本不符或中途断开都可能让设备变砖、丢失数据或失去保修。这里只在一台 TB323FU（ROW 18.0.12.187）上验证过；动手前核对固件版本和每个镜像的哈希，按现状提供、无任何担保，风险自负。非官方项目，与联想、高通无关。
> **Warning: these tools write raw partitions on the tablet over EDL/adb; a mistake can brick the device or wipe its data. No warranty, use at your own risk.**

## 现状（2026-10-10 05:20）

- Android：ROW `TB323FU_ROW_OPEN_USER_Q00020.0_A16_ZUI_18.0.12.187_ST_260907`，活动槽 `_b`，
  bootloader locked / verified boot green，KernelSU root 可用（init_boot_b），efisp 里有 LTBox 写入的 GBL。
- **boot_b 已写回原厂镜像，Android 正常启动**（05:17 经 ADB 确认 boot_completed=1）。
- `baldur-root`（LUN0，8 GiB）里是 Codex 做的 Ubuntu 26.04 KDE 根文件系统，已在设备上完成文件部署，未动。
- 槽 A 已被标记不可启动（GPT 属性 0xf3），不是退路。LUN4 的 GPT 与 02:25 快照逐字节一致。
- Android 里 Codex 装的 KernelSU 模块 `tb323fu-row187-b-switch` 的 Action 会把坏镜像写进 boot_b：**不要点，建议删除**。

### 今晚的诊断轮次（全部同一结果：屏幕冻结、光标停、7–8 s 后看门狗复位）

| 镜像 | 命令行改动 | 结果 |
|---|---|---|
| upstream | 上游原版命令行 | 挂死 |
| diag1 | `initcall_debug ignore_loglevel` | 最后一行 `calling ambakmi_driver_init` |
| diag2 | 跳过 tsens、qcom_watchdog | 挂死 |
| diag3 | `cpuidle.off=1` + 跳过 qpnp_tm、adc_tm5 | 挂死 |
| diag4 | 跳过 ufs_qcom、qcom_cpufreq、sdhci_msm | 挂死 |
| diag5 | `nomodeset` + 跳过 msm_drm_register | 挂死，最后一行仍是 ambakmi |
| diag6 | 跳过 pm8941_pwrkey、geni_i2c、msm_restart、qcom_pon | 挂死 |
| diag7 | 跳过 dwc3_qcom、dwc3 | 挂死 |
| diag8 | 跳过 scmi_smc、scmi、osm_l3、qcom_generic_ext、optee、llcc_edac | 挂死 |
| diag9 | `nosmp maxcpus=1 nohz=off highres=off irqchip.gicv3_nolpi=1 cpuidle.off=1` | 挂死 |
| diag10 | `clk_ignore_unused pd_ignore_unused` | 挂死，最后一行 gpio_sbu_mux |

屏幕显示的是挂死前最后一次刷新的内容，真正挂死点在其后 ≤50 ms；再往下盲切分性价比低，下一步应该是向上游报告
（已提交，见文末「上游」）或把 Android 降回 ROW104。

## 故障结论

1. Codex 的 Linux 首次启动失败有两个独立原因。其一是它拆开上游内核内置 initramfs、换掉 `init` 后用 gzip FCOMMENT
   字段补齐大小；内核自带 gunzip 只跳过 FNAME，不支持 FCOMMENT，initramfs 必然解包失败。其二（真正先发作的）是下面第 2 条。
2. **上游 kernel-t47 原版在 ROW187 固件上，在内核时间约 1.45 秒（不开 initcall_debug）硬复位**，没有 panic 输出。
   上游开发机固件是 ROW 18.0.12.104，作者明确写"其他固件版本未检查"。104→187 的官方 OTA 换掉了 xbl、tz、hyp、aop、cpucp、
   devcfg、pdp 等全部底层固件（54 个分区，见 `notes/` 里的解析）。
3. 用 `initcall_debug` 抓到屏幕最后一行是 `calling ambakmi_driver_init`，屏幕刷新约 50 ms 延迟。
   从内核镜像 kallsyms 解出的真实 initcall 顺序见 `notes/initcall6-order.txt`。ambakmi 之后依次是
   input 杂项、pm8941_pwrkey、i2c、poweroff/restart/pon、qcom_battmgr、tsens、adc_tm5/qpnp_tm（PMIC 温度报警）、
   qcom_watchdog、cpufreq-hw、psci_idle、mmc、UFS……
4. 已排除：tsens、qcom_watchdog（诊断镜像 2 跳过它们，仍复位）。USB 线插不插无关。
5. 待验证（诊断镜像 3，`materials/linux-t47-row187-diag3-boot.img`）：`cpuidle.off=1` + 跳过 `qpnp_tm`、`adc_tm5`。
   若仍复位，下一轮跳过 `qcom_cpufreq_init`、`dt_cpufreq_platdrv_init`，再下一轮看 UFS（`ufs_qcom_pltform_init`）。

诊断镜像的做法：解压上游 `Image-tb323fu-t47.gz`，在原始镜像里原地等长替换内置命令行（出现 2 处，286 字节），
重新 gzip，再用上游 `tools/boot-repack-kernel.py` 装进 ROW187 原厂 boot 容器。原命令行：

```
icc-rpmh.qos_disable=1 icc_rpmh.qos_disable=1 fw_devlink.sync_state=timeout fbcon=font:TER16x32 panic=10 oops=panic console=tty1 keep_bootcon qcom_scm.download_mode=full baldur.end=hold consoleblank=120 no_console_suspend mem_sleep_default=s2idle cpuidle_psci_domain.allow_cluster_off=0
```

## EDL 操作要点（另一台 Linux 设备作主机）

- 进 EDL：拔线 → 电源+音量减 8 秒以上强制关机 → 只按住音量加，按住的同时插线，继续约 10 秒。上游 recovery.md 第三种方法。
- 这台主机只有一个 Type-C 口，角色切换有时不会自动变成 host：
  `echo host | sudo tee /sys/class/usb_role/a600000.usb-role-switch/role`。
- 设备节点 ACL 由 `/etc/udev/rules.d/99-user-y700-edl.rules` 自动加；没加就 `setfacl -m u:user:rw /dev/bus/usb/00X/00Y`。
- Sahara 阶段（上传 loader）用 `tools/sahara_min.py`，它会打印每个包。**只能走 USB 2.0**：
  好线会以 USB 3.0 枚举到 bus 4，PBL 在 SuperSpeed 下 OUT 传输超时；禁用 SS 端口让它退回 USB 2.0：
  `echo 1 | sudo tee /sys/bus/usb/devices/4-0:1.0/usb4-port1/disable`（设备会自动在 bus 3 重新枚举，不必重进 EDL）。
  USB 2.0 下大块 OUT 传输会丢字节（Codex 遇到的"哈希校验失败 status 34"和"发送未完成"都是这个），
  用 `PIECE=2048` 或 `512` 分片。Sahara 一旦被设备拒绝就得重进 EDL。
- Firehose 阶段用 bkerler/edl（`tools/edl.sh` 包装，需要 `tools/setup-venv.sh` 建环境），已把
  `MAX_USB_BULK_BUFFER_SIZE` 改为 2048、`MaxPayloadSizeToTargetInBytes` 改为 16384。`reset` 子命令不能带 `--memory`。
- Codex 自己封印的写入器带 GPT 逐字节门禁和 compile-time seal，不要再用；它的 KernelSU 模块
  `tb323fu-row187-b-switch` 的 Action 会把坏的 FCOMMENT 镜像写进 boot_b，**不要点**，有空删掉。

## 恢复 Android 的完整步骤

```bash
cd ~/y700-recovery && tools/setup-venv.sh            # 首次
# 平板进 EDL、插线后：
PIECE=2048 edlvenv/bin/python tools/sahara_min.py loader/qsahara_device_programmer.xml notes/sahara-trace.txt
tools/edl.sh w boot_b materials/row187-stock-boot_b.img --lun=4
tools/edl.sh r boot_b /tmp/boot_b-readback.img --lun=4 && sha256sum /tmp/boot_b-readback.img materials/row187-stock-boot_b.img
cd edl && ../edlvenv/bin/python edl.py --loader=../loader/qsahara_device_programmer.xml reset
```

`tools/edl.sh` 退出码就是 edl 的（10-31 审计 A8）。原来脚本最后一条是 `echo … | tee`，不管 edl 成没成功都退 0：
回读那步 USB 掉线时 `&&` 照样往下走，`sha256sum` 读的是 /tmp 里上一次留下的回读文件，两个哈希一致就会误以为写回成功。
现在先存 `${PIPESTATUS[0]}`（edl 的，不是 tee 的），记进 `notes/edl-log.txt` 后 `exit` 它。
离线测试：`bash tools/test-edl-sh.sh`（假 python 按 `FAKE_RC` 退出，临时目录里放一份 edl.sh，不碰真的 notes/），
3 项，打印 ALL PASS；旧版过不了「edl 退 3 → edl.sh 退 3」这一项。

Android 里也可以直接 `adb shell su -c 'dd if=... of=/dev/block/by-name/boot_b bs=4096 conv=fsync'`，
这是上游模块的做法（Android 自己正从 boot_b 运行，内核已在内存里）。

## 文件

- `materials/`：原厂 boot_b、上游原版内核装进 ROW187 容器的 boot（`linux-t47-row187-upstream-boot.img`）、
  三个诊断镜像、02:25 的 LUN4 GPT 快照、上游 `Image-tb323fu-t47.gz`；`SHA256SUMS` 为准。镜像本身不随仓库发布，只留 `SHA256SUMS`。
- `loader/`：放 CN 固件工具包里的 8 镜像 Sahara loader（`qsahara_device_programmer.xml` 和它列出的镜像），上游说 loader 只认机型不认区域。公开仓库不含这些文件，从自己的固件包里拷进来，见 [loader/README.md](loader/README.md)。
  仓库里只有这份 XML；8 个 loader 镜像是厂商专有文件，需从自己的固件包里取。
- `notes/`：上游 recovery.md、initcall 顺序。当晚的 edl 日志和 Sahara 包级 trace 含设备信息，不随仓库发布。
- Codex 当时的工作目录（ROW104/187 固件、KDE 镜像、OTA 包）不随仓库发布。

## 上游

- https://github.com/joonhoekim/tb323fu-linux （2026-10-03 起发布，kernel-t47 为 2026-10-08；Discussions 已开）。
- 已向作者报告（2026-10-10 05:40）：https://github.com/joonhoekim/tb323fu-linux/issues/9 （报告草稿不随仓库发布，以 issue 原文为准）。

# 删掉安卓 / 换成联想最新版：调研（2026-11-01，没动手）

作者 10-31 问：「顺带研究一下彻底删除安卓以后，是不是就无法开机了？或者我想把安卓换成联想 zui 最新版的。」11-01 再问：「那我问的那个完全删除安卓的事呢？」

这份文档只是调研，**平板上什么都没动**，也没下载任何 ROM。调研分两轮：

1. 10-31 夜：四路代理分头查（删安卓、联想最新版，加 y17 的两路），结论当晚报给作者。
2. 11-01：再派 5 个代理逐条去驳（开机链、槽位与救砖、回安卓入口、Linux 依赖与空间、联想版本），加 1 个代理专找漏项。这一轮驳倒或改准了 9 处，其中 2 处会改变「怎么删」，已经全部改进本文（见文末「第二轮改了什么」）。

路径基准：
- 仓库 = `C:\Users\me\AI\y700`。
- UP = 上游本地克隆 `linux/tb323fu-linux`（工作区是 10-09 的；`origin/main` 到 10-22，行号以它为准）。
- T54 = 上游 kernel-t54 的 initramfs（平板 `/usr/local/src/tb323fu-linux-t54/kernel/initramfs/`；我们的 `linux/kernel-y17/init` 除了 rootfsck 和它一字不差）。
- 平板现场事实是 10-31 在 y16 上只读采的（会话草稿，没入库，里面有 UUID 等不能进仓库的东西）。

## 一句话结论

- **删安卓本身（数据区 + 系统区），Linux 很可能照样开机；删到开机用的分区就开不了。** 不过删安卓系统之前，有三件事必须先做（见下面「真要删的话」），否则会留下「一按就砖」的陷阱，或者丢掉救砖的路。
- **建议不删**：得到的只是用不上的空间，丢掉的是安卓专属功能和一条重要的后备路线。
- **联想最新版不建议换**：官方更新会连底层固件一起换，和「088 底层不升」冲突，187 那次已经让 Linux 起不来过。想要联想原生界面，较稳的是原版 ZUXOS 088，但官方 088 包可能根本拿不到。

## 一、删安卓：分四层看

平板开机像接力：芯片 → 联想的开机程序 ABL（efisp 里的补丁在内存里改了它，让它把自己当成已解锁）→ `boot_a` 里我们的 Linux 内核 → Linux 系统盘 sda15。Linux 内核只从开机程序那里拿内存布局，设备树、命令行、initramfs 都是自带的；开起来以后不挂任何安卓分区。

| 删到哪一层 | 是什么 | 删了 Linux 还能开机吗 | 代价 |
|---|---|---|---|
| ① 安卓数据 `userdata`（128 GB） | 安卓的应用、照片、设置、KernelSU 模块、「切回 Linux」App | **很可能能**（上游清过 userdata 和 metadata，槽位和 boot 都没变；本机没试） | 安卓变回出厂状态；只清 userdata 不清 `metadata`，安卓会停在恢复模式（`init_user0_failed`，10-11 见过）；KernelSU 的授权表和切回 Linux 的 App 要重装；重新联网前要先关掉 OTA（它会按 Pad Mini 去改分区） |
| ② 再删安卓系统 `super`（20 GB） | ColorOS 系统和联想 vendor | **大概率能**（道理上开机程序不读它；没有出处直接写，本机没试） | 安卓彻底没了；「回安卓」的几个入口变成陷阱（见下）；电脑上有 `coloros-v17/image/super.img` 原件（20 GiB），要恢复能用 9008 写回 |
| ③ 开机用的小分区 | `vendor_boot_a`、`init_boot_a`、`vbmeta_a`、`dtbo_a`、`recovery_a`；**还有 `boot_b`** | A 槽这几块：**很可能开不了机**（开机程序要靠它们拼出这次开机，本机没试）；**`boot_b` 也不能删**（见下） | 开机失败会把整个 A 槽标成不可启动，上游那次是靠 9008 改分区表才救回来的 |
| ④ 底层固件和本机专属数据 | xbl、abl、tz、hyp、aop、soccp（充电固件）、efisp、devinfo、persist、modemst/fsg、keystore、misc、frp 等；还有 `rawdump`（每日体检读它取证） | **绝对不能碰** | efisp 没了 Linux 和 root 都起不来；persist、基带校准等是这台机器独有的，只能从 10-11 的自家备份写回（那份备份**只在这台电脑上**，README「另存一份到别处」一直没勾） |

### `boot_b` 为什么不能删（第二轮新发现，最重要）

`boot_b` 里放的是安卓的开机镜像。以前以为它只用于「回安卓」，删了无非少条路。其实**以后装每一个新内核都要用它**：

- 上游的 helper 是把新内核**装进 `boot_b` 那份原厂开机镜像的外壳里**（联想的头、签名块都在里面），再写进 `boot_a`。
- 写之前它先核对 `boot_b` 和记下的安卓哈希（`/etc/tb323fu/android-boot.sha256`）对得上。对不上就拒绝：「not writing boot_a (no way back)」。
- 出处：UP `helper/crates/tb323fu-helper-core/src/kernel.rs` 第 18–21 行（说明）、`find_device()`（`boot_a`、`boot_b` 必须各有一个、一样大）、`stock_image()`（哈希核对）；`docs/helper.md`「What you install」。
- 我们装 y17 用的 `tb323fu-ctl kernel install-local` 走的就是这条路。
- 所以：删了 `boot_b` 的内容 → 以后装不了任何内核；连分区条目一起删 → helper 连现在的内核都管不了，回滚也不行。

### 删 `super` 后「回安卓」会变成陷阱

现在有四个地方能把 `boot_b`（安卓开机镜像）写进 `boot_a` 再重启。它们都只核对 `boot_b` 的哈希，不管安卓系统还在不在：

1. initramfs 里的组合键（音量上下一起按 10 秒）。我们的镜像构建时用 `-a` 把哈希编进去了（`kbuild-y17.sh:344`），删哈希文件也关不掉它。
2. 进系统后的 `tb323fu-emergency-key.service`，同样的组合键。
3. Linux 这边的「切换到 Android」按钮（`y700-to-android`）和 helper 的 Android.SwitchToAndroid。
4. 手动 `sudo back-to-android`。

`super` 没了以后，按下去就会切进一个起不来的安卓，只能接电脑进 9008 救。而且**不能靠「让 `boot_b` 对不上哈希」来一次关掉它们**：那样内核也装不了了（上一小节）。所以要逐个关掉：在我们自己的 init 里去掉组合键（我们现在本来就维护自己的 init）、停用 emergency-key 服务、去掉切换按钮和 helper 的切换入口。

### 电脑上的救砖路线，现在通向的是安卓，不是 Linux

- 仓库的 `linux/restore-coloros-boot.sh` 用 9008 把 **ColorOS 的开机镜像**写进 `boot_a`；上游的救法也是「先回安卓，再从安卓切回 Linux」（UP `docs/helper.md`、`docs/recovery.md`）。
- 安卓没了，这条路就断了。电脑上目前**没有当前能用的 Linux 开机镜像**：y16/y17 只有哈希，`linux/round1/linux-t47-coloros17-boot.img` 是 10-11 的 t47，和现在的系统没配过。
- 所以删之前要先在电脑上存一份当前的 `linux-good.img`，并写好「9008 把它写进 `boot_a`」的脚本，最好再做一张 microSD 救援盘（initramfs 找不到能用的系统盘时，会自己去试 SD 卡上的 `baldur-root-sd`）。

### 删安卓会丢什么

- **只有安卓能做的**：HDR 和杜比视界视频（作者定过 Linux 不做 HDR，这类视频去安卓看）、安卓应用、安卓那边联想闭源的杜比 DSP 处理。
  - 第一轮写「丢 165 Hz」不对：Linux 也能 164 Hz，是作者自己选的 120 Hz（README「刷新率」）。
  - 第一轮写「丢联想杜比音效」说重了：联想的扬声器调音已经搬到 Linux 的 PipeWire 滤波链上了（README「移植联想的杜比扬声器调音」），丢的只是安卓那边的闭源处理。
- **一条后备路线**：Linux 坏到桌面起不来时，现在可以回安卓、用 root 修 Linux 再切回去。删了以后只剩：新内核失败自动退回旧内核、microSD 救援盘（还没做）、接电脑 9008。上游的一键安装器也要靠有 root 的安卓，没了安卓，以后重装只能走 9008 或 SD 卡。
- **对照参考**：以前查 Wi‑Fi 毛病，靠「安卓下 5G/6G 都稳」才断定问题在 Linux 驱动。
- **重新提取固件的来源**：影响不大。电脑上的 ColorOS 包里有 `modem_a`、`dsp_a`、`bluetooth_a`、`super.img`，`persist` 在 10-11 的备份里。
- 不丢：Wi‑Fi/蓝牙 MAC（由 Linux 盘上的 machine-id 生成，不读 persist）；运行时的固件（全在 Linux 盘上）。

### 删安卓能得到什么

- **空间**：数据区 128 GiB + 系统区 20 GiB。但 Linux 盘 317 GiB 只用了 99 GiB，还空着两百多 GiB，不缺。
- 数据区紧挨在 Linux 系统盘**前面**（userdata 是 4K 扇区 5661480–39215911，baldur-root 从 39476224 开始，中间空着约 1 GiB）。ext4 只能往后长，所以并不进系统盘，只能单独格式化成第二块盘挂上。
  - 第二块盘的 GPT 分区名不能叫 `baldur-root`、`baldur-root-sd`，也不能用 `tb323fu-` 开头，否则开机程序会把它当成系统盘的候选去试。
  - 系统区 20 GB 不挨着，基本用不上。
- **不会更快、不会更省电**：用 Linux 时安卓本来就没在跑。
- 折中做法（上游做过）：从 Linux 里用 `sgdisk` 把 userdata 缩小，安卓留着，代价是安卓重置；空出来的也只能当第二块盘。Linux 空间充足，现在不值。

### 建议

**不删。** 如果以后还是想删，只删 ① 和 ②，按这个顺序：

1. ✅ 系统盘先修干净（11-01 y17 已做到，每次开机都查）。
2. 电脑上存一份当前的 `linux-good.img`，写好「9008 写 Linux 进 `boot_a`」的脚本，并实测一次 9008 能进（按键进 9008 在现在的国行 088 开机程序下还没记录过实测；10-11 以后用的是 `adb reboot edl`，那要靠安卓）。
3. 做一张 microSD 救援盘（`baldur-root-sd`）。
4. 把 10-11 的本机专属分区备份另存一份到别处。
5. 关掉所有回安卓的入口（init 里的组合键、emergency-key 服务、切换按钮、helper 的切换），重编一次内核镜像并验证。
6. 删的时候只清内容、**不删分区条目**（helper 要 `boot_b` 条目，0.4.4 起的传感器单元会等 `super` 设备），走 `/dev/disk/by-partlabel/...`，userdata 紧挨着 sda15，千万别写错；改 LUN0 分区表前先 `sgdisk -b` 备份。
7. `boot_b`、③ 的其他分区、④ 全部不动。别用联想 Software Fix 的「救援」，也别用刷机工具的「清除数据」，它们会清掉 efisp 和 Linux。

清分区是不可逆的写盘操作，要作者逐步同意。

## 二、换成联想最新版

### 「最新版」是哪个（11-01 查，有几条没能核实）

- 国行叫 ZUXOS，海外叫 ZUI。
- 国行正式版：在线升级链到 **2.0.12.236**（lenovo-ota-tool 列出的是增量包，236 约 263 MB）。11-01 后续查到联想官方刷机接口也给 236 的 9008 整包（11.59 GB），详见 [firmware-upgrade-research.md](firmware-upgrade-research.md)。**2.0.12.255**（09-19 构建）只在 ColorOS 移植包的开机镜像指纹里见过，没找到官方升级记录。
- 国行内测：ZUXOS 2.5（安卓 17）**2.5.02.198**，要内测白名单。
- 海外：ZUI **18.0.12.187**。「Software Fix 只给 187」出自 XDA，第二轮打不开 XDA（403），没能复核。
- 本机：上层 ColorOS 17，底层国行 ZUXOS 2.0.12.088（06-10 构建）。

### 为什么不建议

- **联想没有「只换安卓」的官方方式**：在线升级和整包都会写那个版本自己的底层固件。104→187 那次在线升级改写了 54 个分区，包括 xbl、tz、hyp、aop、abl。
- **Linux 可能起不来**：10-10 底层是海外 187 时，Linux 一开机就挂死；10-11 换回 088 底层后才起来。那次同时换了好几样（底层、地区、开机镜像外壳、槽位、efisp），仓库认为根因在底层固件，但没做过 A/B 实验。上游 issue #9 还开着，作者 10-28 指派给了自己。
- **可能回不去**：上游写「固件更新会抬高防回滚号，不能再降」；不过这台从 187 刷回 088 是成功的，所以「可能」比较准确。一加今年 1 月用过熔丝式防回滚（降级直接硬砖），联想五代没有公开先例。
- **免解锁的漏洞可能被补**：高通 2026-03 初已把 GBL 漏洞的修复发给厂商。联想 236/255/2.5 用没用上，查不到。用上了，efisp 就不灵了，Linux 和 root 都会失效，只能走联想官方解锁（会清空、有名额限制）。上游的规矩是升级前先确认新 ABL 还会加载 efisp。
- **官方整包刷机会抹掉 Linux**：官方包会把 LUN0 分区表恢复成出厂样子，`baldur-root` 那一项就没了。我们 10-11 刷 ColorOS 用的是自己的 `prep_pkg.py` / `flash_coloros.py`，保住了 sda15；拿它刷官方 ZUXOS 包要改脚本、重新模拟验证。

### 折中：原版 ZUXOS 088

底层和现在一样，换上联想原生界面，有原生杜比开关（杜比的处理现在靠我们的模块已经在用，多出来的主要是开关界面）。代价和障碍：

- 安卓数据全清，先备份照片和文件；
- ~~官方 088 包可能拿不到~~（11-01 更正）：联想官方 CDN 上 088 的 9008 整包还在（10.05 GB，HEAD 200，没下载），出处见 [firmware-upgrade-research.md](firmware-upgrade-research.md) B 节。Software Fix 救援装的仍是「最新固件」，别用。另存在别处（另一台机器上）的那份 088 是约 25 GB 的分区备份，里面有个没合并完的升级快照，系统部分可能新旧混杂，不能直接用；
- 下载任何包都要先问作者；
- 要用自己的脚本刷，不能用官方工具。

### 建议

**继续「088 底层不升」。** 真想用最新版，至少等三件事都成立：上游 Linux 宣布支持新底层；有人确认新 ABL 还认 efisp（或者作者决定走官方解锁）；完整备份已经存到别处。

## 第二轮改了什么（11-01 核对）

| 第一轮说法 | 第二轮结论 |
|---|---|
| `boot_b` 可以删，只是少了回安卓的路 | **错**：helper 装每个新内核都要用 `boot_b` 当外壳并核对哈希，删了以后装不了内核 |
| 关掉回安卓入口：重编不带 `-a`，或删哈希文件 | **不够**：入口有四个（initramfs 组合键、emergency-key 服务、切换按钮/helper、手动命令）；镜像里编进了哈希，删文件关不掉组合键；哈希文件 helper 还要用 |
| 删了还有 9008 兜底 | **只对一半**：9008 本身不靠安卓，但电脑上现成的救法是先写回安卓、再切 Linux；安卓没了，要先在电脑上备好当前的 Linux 开机镜像 |
| 丢 165 Hz | 错：Linux 能 164 Hz，作者选的 120 Hz |
| 丢联想杜比音效 | 说重了：扬声器调音已搬到 Linux，丢的是安卓闭源 DSP 处理 |
| 本机专属分区丢了就再也拿不回来 | 说重了：能从 10-11 自家备份用 9008 写回，但备份只在这台电脑上 |
| fastboot 只读 | 上游在海外 104 上测的；这台国行 088 只用过 `getvar`，别指望它 |
| baldur-root 从 39216128 开始 | 实际 39476224（10-11 刷写时保留了原起点），和 userdata 之间空着约 1 GiB；结论不变 |
| A 槽小分区：开机程序只放宽了 `boot` 的检查 | 前提不对：这台的 efisp 连没签名的 vbmeta 和改过的 init_boot 都接受。结论不变（开机程序要靠这些分区拼出开机），理由换了 |
| 国行 9008 整包最新 236 | 没找到整包出处，lenovo-ota-tool 里 236 是增量包；255 只见于指纹。**第三轮（11-01 底层调研）更正**：联想刷机接口给的就是 236 Tool 整包，地址在 `zsk-cdn.lenovows.com` |
| 漏了 | 清 userdata 要连 metadata 一起清；`rawdump` 体检要读，不能当安卓垃圾删；`misc`、`frp`、`keystore` 等也在 LUN0；按键进 9008 在现在的开机程序下没实测过；电脑上有 `super.img` 原件，删 ② 可以撤回 |

## 没核实的

- 本机没试过清空 userdata 或 super 以后开 Linux。
- 清空 vendor_boot / init_boot / dtbo 以后开机程序具体怎么失败；单清 recovery_a 会不会影响正常开机。
- 现在这份 efisp 的确切检查范围；当前的 AVB 防回滚号门槛。
- 按住音量上进 9008 在国行 088 开机程序下的实测。
- 联想 236/255/2.5 的 ABL 还认不认 efisp、有没有熔丝防回滚；2.0.12.255 之后还有没有更新的正式版；海外 187 是不是最新。（深入调研见 [firmware-upgrade-research.md](firmware-upgrade-research.md)，仍没定论。）
- ~~`zsk-cdn.lenovows.com`（第三方索引里的国行整包地址）是不是联想的~~：11-01 已核实，是联想官方刷机接口 `ptstpd.lenovo.com.cn` 返回的下载地址。

## 出处

- 仓库：`README.md`（「当前方向：刷 ColorOS 16」「Linux 现状」里 efisp、`boot_b`、切换 App 几条；「移植联想的杜比扬声器调音」；「刷新率」；「安卓上层跟进 OPPO 官方更新」的 088 不升）、`coloros16-plan.md`、`coloros17-analysis.md`、`prep_pkg.py`、`flash_coloros.py`、`linux/restore-coloros-boot.sh`、`linux/fastboot-getvar-all.txt`、`stock-zui/README.md`、`y700-recovery/notes/upstream-bug-report.md`、`tools/y700-checklist.py`（rawdump）、`linux/kernel-y17/kbuild-y17.sh`、`linux/kernel-y17/init`（其中 `linux/fastboot-getvar-all.txt` 和 `y700-recovery/notes/upstream-bug-report.md` 不随公开仓库发布）。
- 上游（UP，origin/main）：`docs/rooting.md`、`docs/recovery.md`、`docs/helper.md`、`docs/distros.md`、`docs/hardware-status.md`、`kernel/patches/0021-arm64-carry-a-devicetree-inside-the-kernel-image.patch`、`kernel/README.md`、`kernel/initramfs/README.md`、`firmware/README.md`、`userspace/platform/README.md`、`android/back-to-android`、`helper/crates/tb323fu-helper-core/src/kernel.rs`。
- 网上：[aweiyry/lenovo-ota-tool](https://github.com/aweiyry/lenovo-ota-tool)、[tb323fu-linux issue #9](https://github.com/joonhoekim/tb323fu-linux/issues/9)、[Android Authority：高通回应 GBL 漏洞](https://www.androidauthority.com/qualcomm-gbl-exploit-fix-statement-3649176/)、[Notebookcheck：一加熔丝式防回滚](https://www.notebookcheck.net/New-OnePlus-software-updates-add-Samsung-style-ARB-with-permanent-brick-risk.1208015.0.html)、XDA 国行帖与海外帖（第二轮 403 打不开）。

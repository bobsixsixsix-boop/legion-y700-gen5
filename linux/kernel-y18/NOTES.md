# 内核 y18：y17 搭车上游 kernel-t58 的 8 个补丁（USB-C 外接屏与睡眠、面板物理尺寸、microSD），hung task 只报不重启

2026-11-04 下午。作者对 README「上游 tb323fu-linux 跟进」11-04 10:05 巡检那 5 项的裁决：「这 12345 都值得吃，开始猛攻」。**上机结果见下一节。**

y18 = **y17 的内核**（y16 的树 + y17 的 initramfs：init 带 `rootfsck`、静态 e2fsck，一字不改）**+ 上游 kernel-t57/t58 的 8 个补丁 + 2 处配置**：

- 树：分支 `y18` = `y16`（`82bf9859f5f6`）+ 0144、0147、0148、0149、0150、0151、0152、0153 这 8 个提交，`Y18_TREE c2c65206c1be3b0c4a49956990d44ae3d054ec37`（HEAD `ed3d84c8`；改提交说明 HEAD 会变、tree 不变，脚本只钉 tree）。`t52-base` 不动（见「有意不做」的路线 B）。y16→y18 变了 9 个文件，和我们自己 28 个补丁碰的文件**没有交集**。
- 配置：CMDLINE 去掉 `no_console_suspend`（0148）；`CONFIG_BOOTPARAM_HUNG_TASK_PANIC=0`（t58 的 `kernel/config`）。和 y17 的配置比**正好差这 4 行**（两行 `<`、两行 `>`），kbuild 编前编后各核一次。
- release 名 `7.3.0-tb323fu-t52-y18`。

## 上机结果

全部 11-04 JST：

- 16:47 `tb323fu-ctl kernel install-local /usr/local/src/y700-kernel-y18/Image-t52-y18.gz --trial --name … --yes`：`state pending-reboot`、`start 0 of 2`。
- 16:49 重启。先看 8766 页（dpms Off、ssh 会话 0、测量单元全停、u0=no），先说了一声，然后重启。
- 16:54 `y18-verify.sh`：**ALL PASS**（副本 `runs/kernel/y18-verify-20261104-1654.log`）。要点：`/proc/cmdline` 没有 `no_console_suspend`，`console_suspend` = Y；`hung_task_panic` 0 / `hung_task_timeout_secs` 180 / `softlockup_panic` 1，本次开机 hung-task 行 0；kscreen 看到 DSI 118 × 190 mm @1.9，kwinrc 的 Xwayland 1.9、Xft.dpi 182 没动；DP-1 连接器注册了（disconnected，没接显示器）；mmc0 host 在、没卡；运行配置和 y17 的正好差那 4 行；补丁归档含 0144/0153；initramfs 是 y17 的 init + 静态 e2fsck，两次 e2fsck 都 exit 0；SDI 关、看门狗 30 s。INFO：`HS-PHY not in L2` 本次开机 1 行（y7 起每次开机 3 行，不是 y18 引入的）。
- 16:56 `tb323fu-ctl kernel keep`：「kept 7.3.0-tb323fu-t52-y18: it is the good kernel now」；`kernel status`：running y18、state idle、good y18。
- 17:00 新体检装到 `/usr/local/bin/y700-checklist`（换前的旧版在 `/root/y700-checklist.bak-20261104`），不带 `--save` 跑一次（输出 `/root/y700-checklist-20261104-y18.out`）：59 OK、0 WARN、2 CHANGED（内核 y17→y18 本就该报；LIVI 10.0.0→10.3.0 是 CarPlay 部分另装的、状态没 `--save`），「面板尺寸」OK，没有「基线 … 坏了」。实机踩到：`kscreen-doctor -j` 在体检的最小用户环境里要 `WAYLAND_DISPLAY=wayland-0`，不然 Qt 走 xcb 连不上显示就退、这项变 INFO——自测的假命令测不出，当场补上（`check_panel_size` 里 `env WAYLAND_DISPLAY=wayland-0 kscreen-doctor -j`）。
- 没验证的（见最后一节）：USB-C 显示器那四条（Claude 没有显示器，作者验）；0153 笔倾角（没笔）；0152 microSD（没卡）；去掉 `no_console_suspend` 对多夜睡眠的影响（看 8766 页 / 体检）。
- **同晚作者拍板**（原话「1不做，2选B，3 等我回去测」）：0153 不要 → 去掉重编成 **y19**（`linux/kernel-y19/`；y18 的 keep 记录不动，y19 重走 trial→keep）；zram 走 B（和 y19 一起做，文件在 `linux/zram/`）；外接屏等作者回来自己测。

## 为什么要它、它改了什么（逐条）

巡检原文在开发日志里（未公开）。下面每条：上游为什么改 → 对本机意味着什么。

### ① 0147–0151：USB-C 显示器（DP alt mode）与睡眠

本机接 USB-C 外接屏时有用。四个补丁治的是同一类事：睡眠前后插拔显示器，USB 或 DP 坏掉。

- **0147 `usb: typec: ucsi: Leave the mux to the altmode driver for alt mode partners`**：上游 226ff2e681d0 把「伙伴标志恰好是 USB」改成了「有 USB 位」，于是同时报 USB + alt mode 的伙伴也被设成 `TYPEC_STATE_USB`。pmic_glink 平台上 altmode 驱动编的是同一条 mux 链，两份通知顺序不定；UCSI 的后到时 FSA4480 把 SBU 线切掉，DP 的 AUX 不通，显示器永远认不出来——睡眠中插显示器、醒来两份通知一起处理就是这个顺序。改法：伙伴没报 alt mode 才设 `TYPEC_STATE_USB`。
- **0148 `arm64: configs: baldur: drop no_console_suspend from the command line`**：`no_console_suspend` 让 PM core 每次睡眠都切到 suspend console，虽然 DRM 的 fbdev 仿真声明过自己不需要这一切。切换时 fbcon 把它早先保存的 fbdev 配置恢复回去，里面可能还有一台已经拔掉的 DP 显示器；DP 控制器就在睡眠前对着空气训练链路，醒来后 AUX 不工作，睡眠中插上的显示器认不出来。
  - 本机：我们的 CMDLINE 不用树里的 `baldur.fragment`（BASECFG 是 `config-t49.release`，命令行在 `kbuild-y18.sh` 里写死），所以**命令行是 kbuild 自己去掉的**；树里的 0148 一并带上只为和上游一致。y18 起 `/sys/module/printk/parameters/console_suspend` 该是 `Y`（y17 是 `N`）。代价：睡眠过程中内核不再往 tty1 打字——屏幕本来就熄着，没损失；哪天要调试「睡下去不醒」，临时在命令行加回去就行。
- **0149 `usb: dwc3: qcom: Leave DP-only mode from the mux callback`**：原来只在角色变化时切回 PIPE 时钟，重插时角色通知先于 mux 状态就漏掉；DP 开着时引脚分配从 C/E 换成 D/F 会清掉 `dp_only`，可 PHY 还在 DP-only 模式，下一次角色变化就选了已停的 PIPE 时钟。改法：安全态之后第一个 DP 状态才置 `dp_only`，安全态之后的 USB 状态清它，时钟两个方向都从 mux 回调切。睡眠中（glue 已挂起）被 mux 调用时只记状态，resume 时在 core 之前选时钟。顺带 Kconfig 加 `depends on TYPEC || TYPEC=n`，没有 TYPEC 就不注册 mux——我们 `TYPEC=y`，无变化（kbuild 断言）。效果之一：DP-only 显示器拔掉后 USB 3 回到 SuperSpeed。
- **0150 `drm/msm/dp: Track the PHY power and link clock state`**：链路时钟起不来时 PHY 留在上电态且以后不会关；训练失败路径又把 PHY 关两次。现在记着 PHY 电源和链路时钟是否持有，时钟失败就关 PHY，没持有就不重复关。
- **0151 `drm/msm/dp: Release the PHY init when the link is not powered`**：DP 的 PHY init 和 USB 共用 QMP combo PHY；DP 占着时 USB 侧跳过公共块初始化，一次掉电的睡眠之后 USB PHY 等 PHYSTATUS 超时。两条路径漏释放：训练失败的 enable（拿了 init 但 `power_on` 还是 false，disable 提前返回）；显示关着时拔 USB-C（`sink_count` 不变）。两处都释放 init，只释放 init、不碰已经掉下去的链路寄存器。

### ② 0152 microSD：扩展寄存器 / 缓存开启失败也保留卡

`mmc_sd_init_card()` 原来在读扩展寄存器或开 SD 缓存失败时把卡丢掉。两步都是可选项（电源管理、性能扩展、缓存），卡没有它们也能用。有的卡在 tuning 刚结束的单块传输上出 CRC 错，两步随机失败，卡就一直不见，拔了重插才回来（core 不重试 init）。现在：读不到就告警继续；开缓存失败回读 Cache Enable 位（卡可能已经开了，那缓存就得当开着的刷），回读也失败才假定关着。本机 mmc0 槽现在是空的（dmesg `mmc0: … cards: 0`），插卡才走到这段。

### ③ 0153 笔倾角轴向

控制器把沿屏幕 Y 轴的倾角放在字节 73、沿 X 轴（符号反）放在 74；驱动反过来用，倾角转了 90°。改法：`ABS_TILT_X = -(int8_t)byte74`、`ABS_TILT_Y = (int8_t)byte73`。**本机没笔，测不了**，为和上游一致带上，只改笔路径的两行。

**y700 版补丁文件是重切的**：上游在 0145（笔报文越界丢弃）之后切的，hunk 上下文里有 0145 的 `goto XFER_ERROR`；我们没收 0143/0145/0146（README 上游日志 11-02：0143 会把垃圾报文变成随机笔点击），所以按 t52 的 `nt36xxx.c` 重切上下文，改的两行和上游**逐字节相同**，补丁文件里有一段说明（纯 ASCII，见踩坑 3）。**没有顺手加 0143**；kbuild 断言树里没有 `pen_format_id == 0x02`、`pen_x > ts->abs_x_max`、`0xF1`。

### ④ `CONFIG_BOOTPARAM_HUNG_TASK_PANIC=0`

上游 t58 的 `kernel/config` 把它从 1 改成 0，起因是 USB 盘读写中拔掉：卡在 D 状态的任务只记日志、不 panic。本机 `panic=10` 自动重启，所以 y8–y17 一个任务卡 D 状态超过 180 秒（`y8-power.fragment` 的 `DEFAULT_HUNG_TASK_TIMEOUT=180`，当初从 60 放宽就是因为 OTG 优盘和 FUSE）整机就重启一次。y18 起只打一行 `INFO: task …:… blocked for more than 180 seconds`，每日体检的 KMSG 规则已经 grep `blocked for more than|hung_task`，出现会 WARN。保留的：`DETECT_HUNG_TASK=y`（没它连那一行都没有）、`BOOTPARAM_SOFTLOCKUP_PANIC=1`（CPU 真锁死还是重启）、`DPM_WATCHDOG`（睡眠挂死）。`y8-must-keep.txt` 第 429 行和 `y8-power.fragment` 的注释改成了 y18 的说法（两个文件 sha256 变了，kbuild-y18.sh 钉新值）。

### 0144 面板物理尺寸（顺手，巡检没列）

TB323FU 是 8.8 寸、有效区 118 × 190 mm（vendor DT 的 `qcom,mdss-pan-physical-*-dimension`）；驱动一直报 168 × 268，那是 12.4 寸屏的。合成器用它算默认缩放、把数位板/触摸设备映射到对应输出（Mutter 把 libwacom 不认识的笔按物理尺寸配给屏幕）。本机：KWin 对这块屏**有保存的输出配置**（scale 1.9），保存的配置优先于按尺寸算的默认值，所以缩放不该动；Xwayland `Scale=1.9`、`Xft.dpi: 182` 也不动。`y18-verify.sh` 用 `kscreen-doctor -j` 核 `sizeMM` 118×190 且 scale 仍 1.9；体检脚本加了同样的项（见「文件」）。

### ⑤ helper 0.4.6 的 zram：评估结论，没动手

0.4.6 的 `tb323fu-zram`（platform 包）默认开 zram：zstd、大小 = 内存、swappiness 100。查平板现状：**已经有 zram** —— `systemd-zram-generator` 1.2.1-2，`/etc/systemd/zram-generator.conf`（10-11 写的，不是包文件）：`[zram0]` `zram-size = ram / 2`、`compression-algorithm = zstd`、`swap-priority = 100`；`/dev/zram0` 7.4 G 在 `/proc/swaps`；`vm.swappiness` 60、`vm.page-cluster` 3。读 0.4.6 的 `tb323fu-zram start()`：发现任何 zram swap 已存在就直接返回（`already swap (another service): leaving it`），**在设 sysctl 之前**——所以装 platform 0.4.6 对本机 swap **零变化**，还要吃 0.4.4 起 hexagonrpcd 数据目录切换可能弄坏传感器的风险和一整套演练（`tb323fu-sensors-tree` 预演、预建目录、三个分区链接、`systemd-analyze verify graphical.target`、`critical-chain hexagonrpcd.service`）。给作者的两条路：

- **A. 装 `tb323fu-platform` 0.4.6**：代价是整套 0.4.4 升级演练加传感器风险，swap 收益为零（它看见我们的 zram 就让路）。
- **B. 自己改两个文件**（推荐）：`/etc/systemd/zram-generator.conf` 里 `zram-size = ram`；新建 `/etc/sysctl.d/90-y700-zram.conf` 写 `vm.swappiness = 100`、`vm.page-cluster = 0`。零包风险，两分钟，重启或 `systemctl restart systemd-zram-setup@zram0` 生效。10-31 巡检的 iceland（同 SM8850、只有 zram）用的是 swappiness 180、page-cluster 0、`watermark_boost_factor 0`、`watermark_scale_factor 125`，可作参考，但 180 对有 Steam/FEX 大程序的机器偏激进，先 100。

**两条都没做**，等作者挑——11-04 晚作者选 B，做在 y19（`linux/kernel-y19/NOTES.md`、`linux/zram/`）。

## 文件

- `patches/`：36 个补丁 + `series`。前 28 个和 `linux/kernel-y16/patches/` 逐字节相同；0144、0147–0152 是上游 kernel-t58 的文件逐字节拷贝（sha256 见 `prep/y18-branch.sh` 的 SUMS 段）；0153 是重切的（上文③）。
- `prep/y18-branch.sh`：在平板上从 y16 建分支 y18（`git am` 8 个），然后导出 36 个补丁和 `patches/` 比对（放宽到 hunk 行号、Subject 折行、index 行；见踩坑 1–3），再用临时 index 把 36 个补丁打回 `t52-base` 必须等于 `y18^{tree}`。打印 `Y18_HEAD=`、`Y18_TREE=`、`Y18_BRANCH_OK`。`Y18_REDO=1` 重建。
- `kbuild-y18.sh`：从 `kbuild-y17.sh` 来。新加：三个 fragment 的 sha256 钉住；`t52-base..y16` 的 diff 必须等于 `y700-y17.patch`（28 个没动）；8 个补丁各有 grep 断言，0143/0145 的痕迹不得出现；`BOOTPARAM_HUNG_TASK_PANIC=0`；CMDLINE 和 y17 的只差 `no_console_suspend` 一词（字符串替换核对）；编前编后和 y17 的配置差异必须正好是那 4 行；`y700-y18.patch` 不得等于 y17 的、y16→HEAD 正好 9 个文件；镜像里有 0152 的新字串、没有 y9 那条带 `no_console_suspend` 的命令行；Image 大小和 y17 差在 ±1 MiB 内。`CHECK_ONLY=1` 只查不编。
- `y18-verify.sh`：从 `y17-verify.sh` 来。新加：运行配置和 y17 的差异正好那 4 行；补丁归档不等于 y17 的且含 0144/0153 的行；`/proc/cmdline` 没有 `no_console_suspend`；`console_suspend` = Y；`hung_task_panic` 0 / `hung_task_timeout_secs` 180 / `softlockup_panic` 1；`kscreen-doctor -j` 的 DSI 输出 `sizeMM` 118×190、scale 1.9；kwinrc Xwayland Scale 1.9、`~/.Xresources` Xft.dpi 182；DP-1 连接器、mmc0 host 存在；INFO 行：hung-task 行数、DP-1 状态、`HS-PHY not in L2` 行数（y7 起每次开机 3 条，不是 y18 的）、mmc0 卡数。y17 的根分区检查、y16 的 SDI/看门狗/健康项照旧。
- `Image-t52-y18.sha256`：编好后填。
- 改了的别处：`linux/kernel-y8/y8-power.fragment`（hung task 注释）、`linux/kernel-y8/y8-must-keep.txt`（第 428–429 行）；`tools/y700-checklist.py` 新体检项「面板尺寸」（y18 起 118×190，更早的内核 INFO）；README「内核 y18」「上游跟进」「当前有效状态」。
- 平板上：`/root/y18-patches/`、`/root/y18-branch.sh`、`/root/y18-branch.log`、`/root/kbuild-y18.sh`、`/root/y700-kernel-y18[-check].log`、`/root/y18-verify.sh`、`/usr/local/src/y700-kernel-y18/`、`/usr/local/src/y700-mods-y18/`、`/root/y8-fragments/`（三个文件已是 11-04 版）；上机后多了 `/root/y18-verify-20261104-1654.log`（副本在仓 `runs/kernel/`）、`/root/y700-checklist.bak-20261104`（换体检前的旧版）、`/root/y700-checklist-20261104-y18.out`（新体检第一次实跑）。`/root/y18-upstream/`（44 KiB）是评估时放上游 8 个原件的草稿目录，内容都在 `/root/y18-patches/` 和仓里了，可删。

## 构建结果

- CHECK_ONLY 11-04 16:40 通过：输入 sha、树、36 个补丁回放、全部 grep 断言、编前配置差异正好 4 行。
- 11-04 16:42 JST `KFULL_OK`（`/root/y700-kernel-y18.log`）：`uname -v` = `#12 SMP PREEMPT Wed Nov  4 16:42:18 JST 2026`，在 y17 的目标上增量编译 75 秒。编后配置和 y17 的也正好差 4 行（`BOOTPARAM_HUNG_TASK_PANIC` 1→0、`CMDLINE` 去 `no_console_suspend`）。
- Image 和 y17 一样大（差 0 字节，kbuild 的 ±1 MiB 检查过）：Image 按 64 KiB 对齐（y16→y17 多的 851968 字节 = 13 × 64 KiB），8 个补丁的增量没跨过对齐边界。不是编了个旧树：`strings` 里有 0152 的 `error %d reading SD ext regs, ignoring them`、0150 的 `DP PHY power on failed. ret=%d` 和新 CMDLINE，`y700-y18.patch` 不等于 y17 的，y16→y18 正好 9 个文件。
- sha256 在 `Image-t52-y18.sha256`（Image `376baabe…`、Image.gz `09dc978e…`）；dtb `kaanapali-lenovo-baldur-display.dtb` `836938bc…`。

## 验证过的（上机前）

- Win11 上：0144、0147–0152 依次 `git apply --check` 到 y16 的树（临时 index）全部干净；0153 只有上下文不同，重切后两行改动逐字节等于上游。
- 平板上 `y18-branch.sh`：`EXPORT_MATCHES_INPUT`（19 个逐字节相同、17 个只差第 1 行/index/版本尾）、`EXPORT_REPLAY_OK c2c65206…`、`Y18_BRANCH_OK`；y16 分支未动。
- 平板上 `CHECK_ONLY=1 kbuild-y18.sh`：输入 sha、树、36 个补丁回放、y14–y16 和 y18 的全部 grep 断言、配置检查、编前配置差异 4 行，`CHECK_ONLY_OK`。

## 风险与怎么测

1. **外接屏 + 睡眠（0147–0151 的正题）**：本机没有 USB-C 显示器，Claude 测不了，**请作者真机验收**：(a) 接着显示器熄屏睡下去 → 睡眠中拔掉 → 唤醒：USB-C 口还能用（插键盘/优盘认得出）；(b) 熄屏睡眠中插上显示器 → 唤醒：外屏有画面；(c) 接 DP-only 显示器再拔，`lsusb -t` 里优盘回到 5000M/10000M。没显示器时这些代码路径都是闲着的（`y18-verify.sh` 只能确认连接器、驱动、type-c 端口都在）。
2. **睡眠本身**（去掉 `no_console_suspend` 影响每一次 suspend）：熄屏 s2idle 过几夜，看 8766 状态页和体检有没有复位；cx-auto 夜里照常开 E3a。出问题先回 y17（trial 自动回）。
3. **microSD（0152）**：插一张卡，`dmesg | grep mmc0` 看是否正常识别；若有 `reading SD ext regs, ignoring them` 行说明走到了新路径，卡仍该能挂。
4. **hung task 只报不重启**：不主动制造。真出现时体检 WARN `blocked for more than`；那时平板可能半卡着不重启，要人工处理——这是和 y17 行为的实质差别，作者知道即可。
5. **缩放（0144）**：`y18-verify.sh` 核 118×190 + scale 1.9 + Xft.dpi 182。若 KWin 真按新尺寸重算了缩放（字突然变小），`kscreen-doctor output.DSI-1.scale 1.9` 设回去，然后看 kwinrc Xwayland 和 Xft.dpi 是否跟着错了（README「Steam 字太小」）。
6. **笔（0153）**：没笔，不可测。

## 平板上的执行顺序

1. `y8-fragments/` 三个文件 scp + sha256 比对（11-04 已做）。
2. `bash /root/y18-branch.sh` → `Y18_BRANCH_OK`（已做，HEAD ed3d84c8）。
3. `CHECK_ONLY=1 bash /root/kbuild-y18.sh` → 日志里 `CHECK_ONLY_OK`（已做；注意最后一行是 set -x 的 `+ exit 0`，别拿 `tail -1` 判）。
4. 看 8766 状态页没人用、没实验在跑，`systemd-run --unit=y700-kbuild-y18 --collect -p Nice=19 -p CPUWeight=20 -p IOWeight=20 /bin/bash /root/kbuild-y18.sh` → `tail -1 /root/y700-kernel-y18.log` = `KFULL_OK`。
5. `tb323fu-ctl kernel install-local /usr/local/src/y700-kernel-y18/Image-t52-y18.gz --trial --name "y700 y18: y17 + t58 0144 0147-0153 (USB-C DP sleep, panel size, microSD), hung task report only, no no_console_suspend" --yes`。
6. 重启和安装分两步：先说一声、看 8766 页确认没人在用，再 `reboot`。
7. 开机 ≥ 4 分钟后 `bash /root/y18-verify.sh | tee /root/y18-verify-$(date +%Y%m%d-%H%M).log` → `ALL PASS`；日志拷到 `runs/kernel/`。
8. `tb323fu-ctl kernel keep`。
9. 新版 `y700-checklist` 装到 `/usr/local/bin/`（旧版留 `.bak-20261104`，比 sha256），不带 `--save` 跑一次。
10. 请作者做「风险与怎么测」第 1 条。

## 回滚

- trial 两次开机没 keep 自动回 y17；手动：`tb323fu-ctl kernel rollback`。
- y17 的镜像、模块、配置都在 `/usr/local/src/y700-kernel-y17/`、`/usr/local/src/y700-mods-y17/`。
- 分支 y16、y17 的来源都没动；`y18-branch.sh` 可随时重建 y18。

## 有意不做的事

- **不收 0143/0145/0146**（笔报文格式 0x02、越界丢弃、相关）：11-02 的判断不变——没笔、0143 会把垃圾报文变成随机点击。0153 因此重切上下文，没有顺手带它们。
- **不 rebase 到 t58-base（路线 B）**：那会让 `T52_TREE`、`Y16_HEAD` 等全部钉子和 y14–y17 的工具链作废，还得重新核对 t52 之后 100+ 个上游补丁和我们 28 个的关系；为 8 个无冲突的补丁不值。路线 A（t52-base + 我们 28 + 挑的 8）保留一切已验证的东西。
- **不带 0133 的 t58 版**：t54→t58 它只改了提交说明，代码没变。
- **不装 helper/platform 0.4.6**，zram 走选项 B（11-04 晚作者已点头，做在 y19）；详见上文⑤。
- **不改 `DEFAULT_HUNG_TASK_TIMEOUT`**：仍 180 秒（上游是默认 120）；现在只是报告时限，没必要动。
- **不动 `console=tty1` 等其余命令行**。
- **不查 ArmadaOS 的 FEX thunk、不碰 LIVI 10.3**：巡检同日的其他两条，不在这次的范围内。
- **0142**：巡检之前的待定项，这次不碰（见 README 上游日志）。

## 踩坑（根因）

1. **导出比对 hunk 行号对不上**：上游补丁是在带 0142 等更多补丁的树上切的，同一处改动在我们树里行号差 1（0144 的 `@@ -1431,8` vs `@@ -1430,8`）。`norm()` 把 hunk 头统一成 `@@` 再比；内容仍逐行比。
2. **Subject 折行位置不同**：平板 git 2.43 `format-patch` 对长 Subject 的折行点和上游不同。`norm()` 把头部的续行（以空格开头）接回上一行再比。
3. **非 ASCII 提交说明带来 MIME 头**：0153 的说明段原来有中文，`format-patch` 导出时自动加 `MIME-Version/Content-Type/Content-Transfer-Encoding`，比对失败。说明改成纯 ASCII。**教训：进内核树的补丁说明只写 ASCII**。
4. **`grep -x` 的方括号**：`point_data[74]` 不加 `-F` 时 `[74]` 是字符集，只匹配 `point_data7`/`point_data4`，CHECK_ONLY 在这停了。加 `-F`。
5. **CHECK_ONLY 的成功判断**：`set -x` 下日志最后一行是 `+ exit 0`，`tail -1` 不是 `CHECK_ONLY_OK`；`KFULL_OK` 没这个问题（它后面没有 exit）。要 grep。
6. **镜像里的 `no_console_suspend`**：printk 的 `__setup("no_console_suspend", …)` 让这个词出现在每个内核镜像里，不能用它判命令行；改成找 y9 那条命令行的片段 `consoleblank=120 no_console_suspend`。
7. **Win11 Bash**：heredoc 写脚本会报 `unexpected EOF`，`perl -pi` 替换含 `$` 的模式会报 `Substitution pattern not terminated`——用 Write / Edit 工具；`comm` 要配 `LC_ALL=C sort`。

## 没验证的（待确认）

- 外接屏插拔 + 睡眠的四个场景（作者，风险 1）。
- microSD 插卡（风险 3）。
- hung task 不再重启（不制造）。
- 笔倾角（没笔）。
- 去掉 `no_console_suspend` 后若需要调试睡眠挂死，命令行要临时加回——没演练。

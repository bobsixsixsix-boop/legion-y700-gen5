# 内核 y16：y15 加 1058（download mode 关掉时一并关 SDI）、看门狗 sysfs、t54 的 initramfs

2026-11-01 在 Win11 上准备：补丁、建分支脚本、构建脚本、体检脚本都写好，并在本机模拟过断言。起因是 README「10-31 21:04 死机」，11-01 决定编 y16。**上机结果见下一节。**

y16 = **y15 原封不动**（分支 y15 `77a55c5a723e`，27 个补丁）**再加一个提交**：

- **1058**（本仓自写）：`qcom_scm` 的 `download_mode` 参数在开机后被改成 `off` 时，顺手调用 `qcom_scm_disable_sdi()`，并把 SCM 调用的返回值打进内核日志：`download mode off, SDI disable: <结果>`。

另外两处改动：

- **配置**：多开一项 `CONFIG_WATCHDOG_SYSFS=y`。别的配置和 y15 逐行相同（标识版本的 LOCALVERSION / INITRAMFS_SOURCE 两行除外）。
- **initramfs**：换成上游 `kernel-t54` 的 `init`（a9b1d5f）。state 根分区只读挂不上时，它会说一声，不再悄悄地不读 boot-next / boot-default / boot-menu。编译要读的其余文件和 t52 逐字节相同。

内核底座不变：v7.3 + 上游 joonhoekim/tb323fu-linux `kernel-t52`（`t52-base`）。release 名 `7.3.0-tb323fu-t52-y16`。

## 上机结果

11-01 凌晨在平板上建分支、编译（增量约 1 分钟，`KFULL_OK`），01:12 前后以 trial 装进 boot_a，随即重启。

- trial 第 1 次启动：`uname -r` = `7.3.0-tb323fu-t52-y16`。
- 开机第 182 秒，内核日志：`qcom_scm firmware:scm: download mode off, SDI disable: 0`。SCM 调用在 Kaanapali 上返回 0，机器没出事（风险 1、2 没发生）。
- `watchdog0`：`qcom_wdt`，active，超时 30 秒；bootstatus 0（上次是正常重启，符合预期）。
- 体检：`runs/kernel/y16-verify-20261101-0118.log` 有 1 项 FAIL（「no err-level qcom_scm kernel line」），是体检脚本的误报，见下；改完重跑 `y16-verify-20261101-0119.log`：47 项 PASS，`ALL PASS`。
  - **误报的根因**：initramfs 的 `init`（上游，t52 / t54 都一样）用 `say()` 往 `/dev/kmsg` 写 `<1>baldur: …`，也就是 alert 级。其中「cmdline: …qcom_scm.download_mode=full…」和「-- qcom_scm download_mode: full, bound: firmware:scm --」两行含 `qcom_scm`。y14、y15 每次开机都有这两行。原来的检查按 `qcom_scm|firmware:scm` 子串搜，把它们算成了驱动报错。改成只认驱动自己的行：`grep -E "^qcom_scm[ :]"`（驱动的 `dev_*` 行以 `qcom_scm firmware:scm:` 开头，`pr_*` 行以 `qcom_scm:` 开头）。
- **看门狗咬测试（第 1、2 步连做）：通过。** 脚本 scp 到 `/tmp` 比过 sha256 再跑：
  - 第 1 步 busctl 把 `RuntimeWatchdogUSec` 设成 0，`watchdog0/state` 立刻变 `inactive`（drop-in 办法没用上）；
  - 第 2 步用一次性单元 `y700-wdbite` 打开 `/dev/watchdog0` 不喂（state active，timeleft 29），之前先 `logger -t y700-wdbite` 打了一行记号；
  - 上一次开机的日志：记号在 812.185 s，`watchdog0: pretimeout event` 在 840.556 s（看门狗 pretimeout 是 1 秒，咬之前 1 秒叫一声），之后再没有记录，没有关机行；
  - 01:27:41 状态页断开，01:28:16 新开机的状态页就回来了；按新开机的 uptime 倒推，内核在 01:28:01 左右起来，咬到重新开机约 23 秒。**没有停在转储界面。**
  - rawdump 分区的 sha256 和 10-31 的备份 `/var/tmp/rawdump-20261031-2104.img` 完全一样（7d1709013ff9…）：这次没进转储模式。体检报「新的崩溃转储」是因为它的基线还是 10-31 10:04 存的，报的是 10-31 那份。
- **`watchdog0/bootstatus` 被咬以后读到 0，不是 32**：这块 SoC 上 qcom_wdt 在 probe 时看不出上一次是被咬的。所以不能用它判断。能用的是 pstore 控制台尾部那行 `watchdog0: pretimeout event`：这次的控制台尾巴里就有，飞行记录器把它存进了 `/var/log/y700-flightrec/pstore/<新开机>/console-ramoops-0`。体检 `CRASH_SIGNS` 已加这一条（下面「体检」）。
- **意外发现 1：咬完那次开机，trial 计数没加。** initramfs 日志：`kernel … on trial: the state root is not writable, start not counted`，状态一直是「start 1 of 2」。根因见 README「10-31 21:04 死机」里的「trial 计数漏记」：被硬复位后，状态根分区（sda15）的 ext4 带着孤儿 inode 链表，initramfs 只读挂上以后 `mount -o remount,rw` 被内核拒绝（`Couldn't remount RDWR because of unprocessed orphan inode list. Please umount/remount instead`）。为什么只读挂载没把孤儿链表清掉：正常的 ext4 会清（`orphan cleanup on readonly fs`），带着错误标记时才跳过——就是下面的意外发现 2。这次开机的内核日志也没有 `orphan cleanup` 那行。所以发现 1 是发现 2 引起的，跑 e2fsck 清掉标记应该就好（还没核实；干净重启后开机本来就照常计数，要在 trial 里碰上一次非正常复位才核实得了，见 README 同一节）；`ktrial()` 改成 umount 再读写挂只是加固。（起初误写成上游 init 的通病，11-01 审查指出。）
- **意外发现 2：sda15 带着「有错误」标记**（`tune2fs -l`：`clean with errors`，`FS Error count: 1`，`ext4_orphan_get:1429`，EFSCORRUPTED，时间是 1970 年＝开机早期没对时）。journal 里还留着的 22 次开机，最早那次就已经有了，和 10-31、和咬测试都无关；意外发现 1 就是它引起的。处理办法另议（README 同一节）。
- 01:30 `tb323fu-ctl kernel keep`：y16 成为 good 内核（「kept 7.3.0-tb323fu-t52-y16: it is the good kernel now」）。keep 的依据是第 1 次启动那轮体检（ALL PASS）加咬测试。
- 体检（`tools/y700-checklist.py`）：
  - y16 起，download_mode 是 off 时再看本次开机有没有 `download mode off, SDI disable: 0`：有且都是 0 → OK；有非 0 → WARN；y16 以上却没有这一行 → WARN（1058 没生效）；y15 及以前照旧；
  - `CRASH_SIGNS` 加 `watchdog\d+: pretimeout event` →「硬件看门狗到点…被看门狗复位」；
  - 自测 S36a–d（新代码全过，拿旧版跑 S36a/b 4 项 FAIL）；装到平板 `/usr/local/bin/y700-checklist`（旧版 `/root/y700-checklist.bak-20261101`），不带 `--save` 跑：上一次开机判成看门狗复位，SDI 那项 OK。

## 为什么要 1058

10-31 21:04 那次死机的经过（详见 README「10-31 21:04 死机」）：

1. 显示驱动的中断处理 `msm_mdss_irq` 读 MDSS 中断状态寄存器时撞上同步外部中止（SEA）。
2. CPU0 在打 oops 的半路停住，`panic()` 没跑到，所以「panic 后 10 秒重启」没生效。
3. 复位由固件接手，走了 SDI（Secure Debug Image），进 XBL 的 rawdump，最后停在转储界面耗电，直到被强制关机。

当时 `download_mode` 早已被 `y700-dumpmode-off`（开机 3 分钟）设成了 `off`，为什么还进转储模式？读 y15 的 `drivers/firmware/qcom/qcom_scm.c` 得到这几点：

- `qcom_scm_probe()` 只在**probe 那一刻** `download_mode` 已经是 off、或者设备树写了 `qcom,sdi-enabled` 时，才调 `qcom_scm_disable_sdi()`。
- 我们的 `CONFIG_CMDLINE_FORCE` 命令行里带着 `qcom_scm.download_mode=full`。所以 probe 时它是 full，SDI 一直开着。
- 之后往参数里写 `off`，走的是 `set_download_mode()` → `qcom_scm_set_download_mode()`，只清 TCSR 里的 dload 位，不碰 SDI。
- 内核自己 panic 时仍会 10 秒后重启：PSCI 重启路径会写 NODUMP。但 CPU 卡死后看门狗咬，复位由固件接手，SDI 开着就进转储模式。

平板上 systemd 用着硬件看门狗（`RuntimeWatchdogSec=30`，`/dev/watchdog0` = `qcom_wdt`，11-01 现场看到 PID 1 打开着它）。所以「内核整个卡死 → 30 秒后看门狗咬 → SDI → 转储模式」这条路（B）是现成的，1058 管的就是它，咬测试也只测它。

10-31 是 SEA 当场被固件判成致命错误（A′），还是 CPU 卡死后看门狗咬（B），README 里写了还分不清。**A′ 那条路看不看 SDI 的开关，没人知道**：10-31 只说明「TCSR 的 dload 位清了，照样进了 rawdump」，说明不了固件判致命时查不查 SDI。所以 1058 对 A′ 可能没用，要等 y16 上真再撞一次 SEA 才知道。在那之前，`y700-checklist` 的 rawdump 检查项照旧留着，它是发现「又进过转储」的唯一办法。

### 为什么改 C 代码，不在设备树里加 `qcom,sdi-enabled`

- 设备树办法会让 probe 时就关 SDI，开机头几分钟也就没有转储了。
- 我们**有意保留**开机头 3 分钟的转储：如果新内核开机就反复崩，停在转储界面能止住重启循环。不然 ABL 数到几次失败启动，可能把槽位切回安卓。
- 改 C 代码以后：开机 → 3 分钟内 SDI 照旧开着 → `y700-dumpmode-off` 写 off → 1058 当场关 SDI。之后看门狗咬（B）应该直接重启，不再干等；固件判致命（A′）是否也这样，见上一节，还不知道。

### 副作用

- 写回 `full` / `mini` **不会**重新打开 SDI，要重启才行（提交说明里写了）。平时没人这么写。
- 所以开机 3 分钟后临时 `echo full` 时被咬或 panic，还进不进转储不知道：固件复位写 rawdump 要经过 SDI（10-31 的分析），可 dload 位置着的热复位也可能照样进转储。见「没验证的」。
- `qcom_scm_disable_sdi()` 本身是上游代码，有的板子每次 probe 都调。我们是第一次在这块 SoC 上真调它；结果看日志里的返回值（见「风险」）。

## 文件

- `patches/`：28 个补丁 + `series`。前 27 个和 `linux/kernel-y15/patches/` 逐字节相同。`1058-…patch` 是 Win11 上对着 y15 的 `qcom_scm.c`（平板上 y15 的 blob `3eaa4c9ccf3c`）改完后用 `git format-patch` 导出的；作者、日期固定，说明里有 `y700 patch file:` 一行。
- `prep/y16-branch.sh`：在平板 `/usr/local/src/linux-t52` 建分支 y16 = y15 的 HEAD + `git am` 1058。
  - 输入文件按 sha256 钉住（27 个照抄 y15-branch.sh 的值）。
  - 导出 28 个提交，和输入逐份比（只允许第 1 行、index 行、版本 trailer、hunk 头函数名不同）。
  - 再从 t52-base 回放一遍，确认得到同一棵树。
  - y15 分支只读，不动。
- `kbuild-y16.sh`：从 `kbuild-y15.sh` 改来。
  - 树必须是钉住的 `Y16_TREE`，并且 `HEAD~1` = y15。
  - y15 的全部 grep 断言原样保留（115–202 行原文），再加 1058 的断言。
  - 配置在 y15 的配方上多开 `WATCHDOG_SYSFS`。编译前、编译后各和 y15 的配置比一次，差别必须**恰好**是 `> CONFIG_WATCHDOG_SYSFS=y`。
  - `UP` 换成 `/usr/local/src/tb323fu-linux-t54`。它要读的 36 个文件全部按 sha256 钉住（initramfs 目录、out-of-tree 的 aw882xx、back-to-android、keyhold.c）。编完再确认 initramfs 里的 `/init` 和 t54 的 `init` 是同一个文件。
  - 镜像里要有 1058 的日志格式串。
- `y16-verify.sh`：开机 4 分钟后跑。查这些：
  - 构建身份：内核、配置、iris / ath12k 模块是这次编的，补丁存档带 1058，initramfs 的 init 是 t54 的；
  - 1058：`download_mode` 是 off，本次开机的内核日志里有 `download mode off, SDI disable: 0`，并且没有别的返回值；
  - 看门狗：`watchdog0` 是 `qcom_wdt`，active，超时 30 秒；bootstatus 只打 INFO；
  - y15-verify.sh 的健康检查（120–154 行原文）。

## kbuild-y16.sh 与 kbuild-y15.sh 的区别

- 名字和路径：y15 → y16；`Y15_HEAD` 取代 `Y14_HEAD`。树检查改成 `t52-base..HEAD` 共 28 个提交、`HEAD~1` = y15、`HEAD^{tree}` = `Y16_TREE`，并从仓库里的补丁文件回放一遍。
- `UP`：t52 副本 → t54 副本；外面那两个文件的 sha256 还是 y15 的值，另外钉了 34 个 initramfs / out-of-tree 文件。
  - **为什么不用 `diff -rq` 去比 t52 副本**：y15 编 aw882xx 时在 t52 副本的 `out-of-tree/aw882xx/` 里留下了编译产物，diff 会被它们干扰。按文件列表钉 sha256，多出来的产物不影响。
  - Win11 上算过：同一份列表，t52 只在 `kernel/initramfs/init` 和 `kernel/initramfs/test-root-selection.sh`（测试脚本，不进 initramfs）两项上不同。
- 断言：y15 那段原样保留，第一行注释改成「carried from y14/y15」。新增「y16 assertions」一段，只看 `qcom_scm.c`：
  - `set_download_mode()` 里 `if (scm) {` 包住原来那行调用；
  - `if (download_mode == QCOM_DLOAD_NODUMP) {` 下一行是 `ret = qcom_scm_disable_sdi();`；
  - 日志行的格式；
  - probe 那条原来的 SDI 判断还在；
  - 全文件 `qcom_scm_disable_sdi();` 正好 2 处。
- 配置：olddefconfig 前多一行 `scripts/config --enable WATCHDOG_SYSFS`。`check_config` 多查 `WATCHDOG_SYSFS=y`、`QCOM_WDT=y`、`QCOM_SCM=y`。临时文件改名 `/tmp/y16-*`。
- 编完多两项：initramfs 列表里 `/init` 指向 `$OUT/initramfs.d/init`，并且这个文件和 t54 的 `init` 相同；`strings` 里有 `download mode off, SDI disable: %d`。

## Win11 上的模拟证据（11-01）

- 1058 断言段单独抽出来跑：
  - 对 y15 的 `qcom_scm.c`：**停**；
  - 对 y15 + 1058：**过**；
  - 对 y15 + 1058 但删掉 `qcom_scm_set_download_mode(scm, download_mode);` 那一行的变体：**停**。
- `UPSUMS` 校验：本地 t54 子集**过**；拿 t52 子集冒充：**停**。
  - t54 子集来自 GitHub 上 `kernel-t54` tag 的归档：`t54.tar.gz`，sha256 `bc82d7e0d25a3013f14d8098402e29ce5f99e0b67f1c7cb2cd1f43874a7de161`。
  - t52 子集来自 `linux/tb323fu-linux` 的 `git archive kernel-t52`（只读）。
- 三个脚本 `bash -n` 通过；全部 LF，没有 CR。

## 风险，以及每一项怎么测

1. **SDI 关不掉**（固件不认这个 SCM 调用，或返回非 0）：日志里会是 `SDI disable: <非 0>`，体检那一项 FAIL。此时 y16 和 y15 一样，没有变坏，只是没修好。先别 keep，回头查。
2. **SCM 调用本身让机器出事**：只在开机 3 分钟那一刻调一次。1058 先清 TCSR 的 dload 位，再调 SDI_CONFIG；如果卡在这个调用里，机器正好处在 10-31 的状态（dload 关、SDI 开），之后的复位**会停在转储界面**，不会自己重启。trial 机制要等第三次启动才回 y15，而前两次每次都得有人长按电源 + 音量+。所以：
   - 第 1 次启动时，开机 3 分钟前后有人守着平板（同时看日志那一行）；死了就马上长按强制重启；
   - 第 1 次启动出过事的话，第 2 次启动照样守过 3 分钟；
   - 没人守着时别重启进 y16 的 trial。
3. **SDI 说关了，看门狗咬了还是进转储**：只有真咬一次才知道。见下面「看门狗咬测试」。
4. **WATCHDOG_SYSFS**：只多几个只读 sysfs 属性，不改看门狗行为。体检读 `identity` / `state` / `timeout` / `bootstatus`。
5. **t54 的 init**：只多一条警告，正常开机时什么也不打印。启动成功本身就说明它没坏事。

## 平板上的执行顺序

前提：作者知道这件事；构建期间不做测量（先看 8766 状态页）；文件一律「scp 过去，和本地比 sha256」，远端不跑 sed。

1. **建 t54 副本**：scp `t54.tar.gz` 到 `/root/`，比 sha256（上面那个值），然后：
   ```
   mkdir /usr/local/src/tb323fu-linux-t54
   tar -xzf /root/t54.tar.gz -C /usr/local/src/tb323fu-linux-t54 --strip-components=1 tb323fu-linux-kernel-t54/kernel tb323fu-linux-kernel-t54/android/back-to-android tb323fu-linux-kernel-t54/userspace/platform/src/keyhold.c
   ```
   t52 副本不动。
2. **下发文件**：`patches/*` → 新建的空目录 `/root/y16-patches/`；`prep/y16-branch.sh`、`kbuild-y16.sh`、`y16-verify.sh` → `/root/`。逐个比 sha256。
3. `bash /root/y16-branch.sh 2>&1 | tee /root/y16-branch.log`，末行必须是 `Y16_BRANCH_OK`。看一眼 `git diff --stat y15 y16`（只有 `qcom_scm.c`）。
4. **钉 `Y16_TREE`**：在 Win11 仓库里把 `kbuild-y16.sh` 的 `PASTE-Y16_TREE-HERE` 换成日志里的 40 位值，提交，scp 过去比 sha256。
5. `CHECK_ONLY=1 bash /root/kbuild-y16.sh; tail -3 /root/y700-kernel-y16-check.log`，末行 `CHECK_ONLY_OK`。
6. 编译（树里是 y15 的产物，这次是增量；y14 全量 7 分钟，增量 1 分钟）：
   ```
   systemd-run --unit=y700-kbuild-y16 --collect -p Nice=19 -p CPUWeight=20 -p IOWeight=20 /bin/bash /root/kbuild-y16.sh
   ```
   `tail -1 /root/y700-kernel-y16.log` 必须是 `KFULL_OK`。
7. 安装（安装和重启分两步）：
   ```
   tb323fu-ctl kernel install-local /usr/local/src/y700-kernel-y16/Image-t52-y16.gz --trial --name "y700 y16: y15 + SDI off with download mode 1058, watchdog sysfs, t54 initramfs" --yes
   ```
8. **重启由作者来**，并守过开机 3 分钟（风险 2）。开机后 Claude 用 ssh 看：`uname -r`、开机 3 分钟时日志里那一行。
9. 开机满 4 分钟后：`bash /root/y16-verify.sh 2>&1 | tee /root/y16-verify-$(date +%Y%m%d-%H%M).log`，末行 `ALL PASS`。平板正被使用时不跑。**keep 的依据就是这一次（trial 第 1 次启动）的结果。**
10. 看门狗咬测试（下一节，作者在场、逐步同意）。
11. 都过了：`tb323fu-ctl kernel keep`。日志拷回 `runs/kernel/`，结果写进本节开头和 README。
    - 咬测试之后（第 2 次启动）如果再跑 `y16-verify.sh`，「上一次开机正常结束」那项必然 FAIL：上一次开机就是被故意咬断的。这一项在这里不算数，其余各项照看。

## 看门狗咬测试（作者在场、每一步都同意才做）

目的：确认 SDI 关掉以后，看门狗咬会**直接重启**，不再停在转储界面。

前提：
- y16 已开机满 4 分钟，体检里 1058 那项是 `SDI disable: 0`；
- 作者在场，同意，手头的东西已经保存（平板会被硬复位，正在跑的程序全丢）；
- 屏幕亮着，充电器最好插着。

**第 1、2 步一起征得同意，紧接着连做**。第 1 步做完以后，这次开机就没有硬件看门狗了（它是卡死后唯一的自动恢复），不能停在那儿。

步骤：
1. 让 systemd 放开 `/dev/watchdog0`：
   - 首选 `busctl set-property org.freedesktop.systemd1 /org/freedesktop/systemd1 org.freedesktop.systemd1.Manager RuntimeWatchdogUSec t 0`；
   - 如果这个属性不可写，就在 `/run/systemd/system.conf.d/` 放一个排在最后的 `RuntimeWatchdogSec=off`，再 `systemctl daemon-reexec`；
   - 确认 `/sys/class/watchdog/watchdog0/state` 变成 `inactive`。
   - 这个设置重启才会自动消失，`daemon-reload` 不会让它恢复。所以凡是没咬成（作者改主意、第 2 步没反应），都要走第 6 步恢复。
2. 打开看门狗但不喂，90 秒后自己正常关掉：`sh -c 'exec 3>/dev/watchdog0; sleep 90; printf V >&3; exec 3>&-' &`。打开就会按 30 秒超时启动看门狗；写 `V` 再关是「正常关闭」，看门狗停下，不会留下一个没人喂的看门狗。
3. 预期：约 30 秒后平板直接重启，**不出现转储界面**。重启后 y16 是 trial 的第 2 次启动。
4. 重启后查：
   - `watchdog0/bootstatus`：期望 32（`WDIOF_CARDRESET`）。这块 SoC 上从没读过这个值（y15 没有 sysfs），读到 0 不算失败，以「直接重启、没进转储」为准；
   - 上一次开机的日志应该是突然中断的；
   - 体检（`y700-checklist`）的 rawdump 那一项不该有新记录。
5. 如果停在转储界面：说明 SDI 关了也不够，或者不是这条路。长按电源 + 音量+ 强制重启（仍是 y16 的第 2 次启动），我再查。
6. **没咬成时恢复**（作者在第 2 步前改主意，或 90 秒内没重启）：
   - busctl 办法：`busctl set-property org.freedesktop.systemd1 /org/freedesktop/systemd1 org.freedesktop.systemd1.Manager RuntimeWatchdogUSec t 18446744073709551615`（无穷大 = 撤掉覆盖，systemd 按配置的 30 秒重新打开）；
   - drop-in 办法：删掉那个 drop-in，再 `systemctl daemon-reexec`；
   - 确认 `watchdog0/state` 回到 `active`，然后再查为什么没咬。

## 回滚

- **trial 期间（没 keep）**：`tb323fu-ctl kernel rollback` 把 good 的 y15 写回 boot_a，然后重启。不管它的话，两次启动没确认，第三次自动回 y15。
- **keep 之后**：`tb323fu-ctl kernel install-local /usr/local/src/y700-kernel-y15/Image-t52-y15.gz --trial --name "y700 y15: …" --yes`，重启，`y15-verify.sh` 过了再 keep。
- **linux-t52 里的分支**：y15 分支一直在，没被动过。

## 有意不做的事

- **不在设备树里加 `qcom,sdi-enabled`**：那样开机头 3 分钟也没有转储了，开机就反复崩时止不住重启循环（见上文）。
- **不收 qrtr v3**：它在上游的状态不明（lore / patchwork 拒绝自动抓取）。10-30 定的前提是 netdev 接收或出 v4，并且先在 y15 上拿到 `qrtr-lookup` 和 sensor-core 就绪时间的基线。
- **不收 t54 的 0143（笔的 0x02 报告格式）**：本项目没有用到那种笔。
- **不收 t53/t54 的 0142（144 Hz 面板模式）**：新功能，和 `idle_refresh` / KWin 选模式的配合没验证，理由同 y14、y15。
- **不收 1044、1045 第二部分**：同 y15，kbuild 遇到会拒绝。
- **体检不重跑 y15 的功能测试**：y16~1 就是 y15，那些代码 10-29 已全过，1058 不碰它们的文件。y15-verify.sh 读 debugfs（pm_genpd、qcom_stats），新代码按规矩不读。
- **1058 不往上游发**：没有 Signed-off-by。要发得作者点头，先在 y16 上把咬测试做完。
- **不在 Win11 上编译**：本机没有 arm64 工具链。

## 没验证的

11-01 上机后已验证：编译、启动；`qcom_scm_disable_sdi()` 在 Kaanapali 上返回 0；看门狗咬以后直接重启（约 23 秒）；`RuntimeWatchdogUSec` 能用 busctl 在运行时改；`bootstatus` 被咬后读 0（没用）。还没验证的：

- 固件当场判致命（A′，10-31 可能就是这条路）时会不会照样进转储：咬测试测不到，只能等 y16 上真撞一次，靠 `y700-checklist` 的 rawdump 项发现。
- 内核整个卡死（不只是用户态没喂狗）时的咬：这次咬的时候内核还活着（还打出了 pretimeout）。走的是同一个硬件复位，按理一样，但没测。
- 开机 3 分钟后再 `echo full`（dload 位置上、SDI 仍关）时被咬或内核 panic，还进不进转储（见「副作用」）。cx-collapse PROTOCOL §1.4 那种「临时 full 拿现场」的用法要靠它，用之前先在有人在场时试一次。

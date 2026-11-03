# 内核 y17：y16 原样的内核，initramfs 开机先给根分区跑 e2fsck

2026-11-01 清晨在平板上编好，06:48 装成 trial，两次开机体检都 ALL PASS，**07:00 keep，现役 good**。起因是 README「10-31 21:04 死机」末尾的两件事：系统盘 sda15 带着 ext4 错误标记；带着它，死机后的开机 trial 计数会漏记。那里列了三个修法，11-01 定了第 1 个：让 initramfs 在挂根之前先 `e2fsck -p`。**上机结果见下一节。**

y17 = **y16 的内核一字不改**（同一棵树 `Y16_TREE ea8ec0f24f3d`、同样的补丁、同样的配置和 CMDLINE），只换 initramfs 里的两个文件：

- `/init`：上游 kernel-t54 的 init 加一个 `rootfsck`（本目录的 `init`）；
- `/bin/e2fsck`：Ubuntu 的静态版 e2fsck（包 `e2fsck-static` 1.47.2-3ubuntu4，`/usr/sbin/e2fsck.static`，不依赖任何库）。

release 名 `7.3.0-tb323fu-t52-y17`。

## 上机结果

11-01 这次由 Claude 先确认平板没人在用，再自己重启、测试。日志在 `runs/kernel/y17-verify-20261101-0653.log`（第 1 次开机）和 `-0700.log`（第 2 次）。

- **第 1 次开机（06:49，trial 第 1 次）**，和上面「第一次开机会怎样」逐条对上：
  - 只查日志：exit 0（clean），0 秒。
  - 状态根只读挂上、ktrial `remount,rw` 时内核说了一次 `mounting fs with errors`（标记还在，预期的），**remount 没被拒**，记上了「start 1 of 2」。
  - 完整检查：exit 1（errors fixed），**3 秒**。之后 `tune2fs -l` 是 `clean`，`FS Error count` 那几行没了。
  - `y17-verify.sh` ALL PASS（62 行）。
- **第 2 次开机（06:56，trial 第 2 次，磁盘已经干净）**：两次检查都是 exit 0（clean）、0 秒，没有 `mounting fs with errors`；`y17-verify.sh` 又是 ALL PASS。然后 `tb323fu-ctl kernel keep`，good = y17。
  - 多重启这一次是为了看「平时」的样子（干净的盘一闪而过）再 keep；trial 两次机会正好用完，过不了的话下一次开机自动回 y16。
- **修掉了什么**（第 1 次开机的 `/var/log/baldur-fsck.log`）：6 个「已删除的 inode 没有删除时间」（`Deleted inode … has zero dtime. FIXED`），就是死机时还开着、已经删掉的文件，没收完尾；e2fsck 把它们收完，空间回来了。**没丢任何还在用的文件**。另有 25 条 `extent tree … could be narrower. IGNORED`，只是「这个文件的块索引可以更紧凑」的优化提示，`-p` 照规矩不做，不是错误。
- **`Last checked` 没变成 1970**，和上面原先写的预期不一样：它还是 10-09 那次。原因是 e2fsck 发现系统时间早于 2010 年就认定钟不可信（源码 `e2fsck_allocate_context()` 里的 `E2F_FLAG_TIME_INSANE`），不写这个时间。所以 `Last checked` 以后会一直停在 10-09，看它判断不了查没查过；要看 `/var/log/baldur-fsck.log` 和 kmsg 里的结果行。（`Last mount time` 是 1970，那是内核在 initramfs 里挂载时按 1970 的钟写的，y17 之前就这样。）
- **日志增长**：干净的开机每次在 `baldur-fsck.log` 追加约 130 字节（`clean, …` 一行），1 MB 上限够七千多次开机。
- **每日体检**（新版 06:54 第 1 次开机体检过了以后装上，比计划的「和 keep 一起」早几分钟，中间没有每日任务跑过；`/usr/local/bin/y700-checklist`，旧版留 `y700-checklist.bak-20261101b`）：不带 `--save` 跑了两次。第 1 次开机后：INFO「本次开机是头一次带开机磁盘检查，修掉了 y17 之前留下的错误」+ OK「根分区 clean」；keep 之后：INFO 说开机 -1 是头一次 + OK「1 次开机根分区都查过、干净」+ OK「clean」。其他 WARN / CHANGED 都是旧事（10-31 21:04 和 11-01 01:27 两次复位、rawdump 转储、内核从 y15 换成 y17），因为最后一次 `--save` 还在 y15 时；按规矩交互会话不手动 `--save`，留给每日任务。

## 为什么要它

经过详见 README「10-31 21:04 死机」末尾，这里只放要点：

1. sda15 的 ext4 超级块记着「有错误」（`tune2fs -l`：`clean with errors`，`FS Error count: 1`，孤儿链表里有一个坏 inode 号）。10-16 以前就有了。
2. 这台的根分区**从来不会被自动检查**：initramfs 直接读写挂根，systemd 看到根已经可写就跳过 `systemd-fsck-root`；initramfs 里也没有 e2fsck。
3. 带着这个标记，内核只读挂载时不处理孤儿链表。于是硬复位以后，initramfs 的 `ktrial()` 要 `remount,rw` 记一次 trial 启动，被内核拒绝（`Couldn't remount RDWR because of unprocessed orphan inode list`），这次启动就没记上（11-01 咬测试之后那次开机就是这样）。
4. 后果：标记清掉之前，「两次没确认就自动回旧内核」对桌面起来后才死的坏内核不管用；死机后孤儿文件占的空间也收不回来。

修法只能在根分区没挂上时跑 e2fsck。三个办法里，(a)「initramfs 里放 e2fsck，挂根前先查」一劳永逸：以后每次开机都查，不用人动手；(b) 一次性救援镜像、(c) 从安卓查，都只修这一次。

## 开机时它做什么

`rootfsck` 在两个地方被调用（init 第 489、545 行）：

1. **只查日志**（`e2fsck -p -E journal_only`）：在状态根（baldur-root）只读挂上去读 boot-next / boot-default / trial 状态**之前**。它重放日志、清掉孤儿链表，于是后面 `ktrial()` 的 `remount,rw` 不再被拒，trial 计数能记上。一般和那次只读挂载一样快。
   - 例外（11-01 审查查 e2fsprogs 源码）：超级块或块组描述符有 `-p` 能修的毛病时，e2fsck 修完不会就此停下，会接着整个查一遍（`check_if_skip()` 里「修过东西」的判断排在 journal_only 之前）。要真有元数据损坏才会这样，硬复位加日志重放不会；就算卡住，600/660 秒的上限之后照样往下走、照样记 trial。
   - 不管的情况：带 `orphan_file` 特性的分区（较新的 mke2fs 默认会加）。带着错误标记时 e2fsck 只清孤儿**链表**、不碰孤儿**文件**，`remount,rw` 照样被拒。sda15 没有这个特性（`tune2fs -l` 的特性表里没有），不受影响；哪天重新格式化了根分区，要回来看这一条。
2. **完整的 `e2fsck -p`**：在选中的根真正挂上**之前**，也就是 ktrial 记过这次启动**之后**——检查本身要是把机器弄死了，也算一次失败的 trial 启动。`-p` 只在文件系统带标记（有错误、没正常卸载）时才整个查一遍，平时一闪而过；11-01 量过 99 GB 已用整个查一遍约 2 秒。

细节：

- **从不拦开机**。不管 e2fsck 说什么，后面的 mount 照常进行；结果只记下来（下面），由体检报告。
- **时间上限**：600 秒给 TERM（e2fsck 收到会干净地停下，标记留着下次再查），660 秒给 KILL。`timeout -s KILL 660 timeout 600`，busybox 的 timeout 嵌套在平板上试过。
- **屏幕**：检查期间屏幕保持亮着（`consoleblank=120` 本来 2 分钟会黑），查完恢复。屏幕上（不是 splash 模式时）有一行英文 `fsck baldur-root (/dev/sda15): e2fsck -p, usually seconds; do not power off`。
- **按住音量+**：本来就是「停在 initramfs」，选根那个循环不跑，所以第 2 次（完整检查）也跳过。第 1 次（只查日志）跳不过：它在读按键之前，而且很快。
- **结果行**：每次 e2fsck 结束，kmsg 里一行 `baldur:  fsck baldur-root (/dev/sda15): exit N (WHAT), T s`。WHAT：0 = `clean`；1–3 = `errors fixed`；4–7 = `ERRORS LEFT, needs e2fsck -f by hand`；8–15 = `e2fsck could not check it`；其他（32 取消、137/143 被杀）= `stopped`；到了 600 秒再加 ` at the 600 s limit`。e2fsck 的输出前后各 20 行也进 kmsg。
- **完整输出**：本次开机的 e2fsck 输出整份追加到选中根的 `/var/log/baldur-fsck.log`（每段开头 `== boot <boot_id> fsck-NAME[-journal].out`），只留最后 1 MB。
  - 只写进普通文件（11-01 审查后加）：`/var/log` 组 syslog 也能写，要是有人在那儿放了链接，init 以 root 身份写过去就会改到别的文件（比如 `/etc/passwd`）；放的是管道（fifo），开机会一直卡在打开它那一步。所以 `baldur-fsck.log` 是链接或别的非普通文件就不写，写之前先删掉残留的 `baldur-fsck.log.tmp`（删链接本身，不跟过去）。
- **钟是 1970 年**：initramfs 里还没对时。e2fsck 的配置（`/tmp/e2fsck.conf`）设 `broken_system_clock = 1`，跳过按时间判断的检查；再让 `0x010036`、`0x010037` 两个问题在 `-p` 下也能修（1970 的钟会让已删 inode 的 dtime 看着「太早」，不放开的话 `-p` 会停在那儿要人回答）。代价是 `tune2fs -l` 的 `Last checked` 不再更新：原先以为会写成 1970，上机一看是停在旧值，因为 e2fsck 见钟早于 2010 年就不写它（见「上机结果」）。
- **只查要挂的根**：只查日志只给状态根做；完整检查只给真正要挂的那个根做（boot-next 指到 SD 卡上的根就查 SD 卡那个），回退到下一个根时下一个根也在挂之前查一次。

## 第一次开机会怎样（预期）

- 只查日志：exit 0（clean）。
- 只读挂载、`ktrial()` 记 trial 第 1 次：这时标记还在，`remount,rw` 会让内核说一句 `warning: mounting fs with errors, running e2fsck is recommended`。这是预期的，体检脚本只把它算 INFO。
- 完整检查：带着标记，会整个查一遍并修，多半 exit 1（errors fixed），几秒到几十秒。修完以后 `tune2fs -l` 应该是 `clean`，没有 `FS Error count` 那几行。
- 之后的开机：`-p` 看到干净的文件系统，一闪而过，exit 0。
- 每日体检第一次看到它会报 INFO「头一次带开机磁盘检查，修掉了 y17 之前留下的错误」，不报 WARN。

## 文件

- `init`：上游 t54 的 init（`/usr/local/src/tb323fu-linux-t54/kernel/initramfs/init`）加 `rootfsck` 和上面两处调用、日志追加。sha256 `b450a91a…90ce`（kbuild-y17.sh 和 y17-verify.sh 都钉着这个值；11-01 审查前那版是 `ea85b340…`，平板上留在 `/root/y17-init.ea85`）。
- `test-root-selection.sh`：t54 的测试床加 e2fsck 桩和「fsck:」那几组用例。mount 桩在带 `DEV.orphans` 的盘上拒绝 `remount,rw`，桩里的 journal-only 会把它删掉（就是 10-31 那种标记加孤儿链表）。要 Linux（busybox sh / dash），在平板上跑。
- `kbuild-y17.sh`：由 `kbuild-y16.sh` 改来。
  - 树还是钉住的 `Y16_TREE`，补丁目录还是 `/root/y16-patches/`；y16 的产物（`/usr/local/src/y700-kernel-y16/`）必须在，用来比对。
  - 输入检查：`/root/y17-init` 的 sha256 必须是仓库里 init 的值；`e2fsck-static` 必须是钉住的版本、`dpkg --verify` 干净、没有程序解释器、没有动态库、是 AArch64、`-V` 是 1.47.2。
  - 编译前、编译后的配置和 y16 比，除了标识版本的行必须一字不差；`y700-y17.patch` 必须和 `y700-y16.patch` 一样。
  - 上游 t54 的 `build.sh` 照 y16 那样跑完以后，再改它留下的暂存目录：换 `/init`、放 `/bin/e2fsck`、列表加一行，用内核的 `gen_init_cpio` 重做 cpio；再把新 cpio 解开逐字节比这两个文件，并确认这份 cpio.gz 原样在 Image 里。
  - `LC_ALL=C`（readelf 的输出会被翻成中文，「Machine」那行就对不上了）。
  - `CHECK_ONLY=1` 只查不编。
- `y17-verify.sh`：装上后、trial 第 1 次开机满 4 分钟跑。查：
  - 构建身份：跑的是 y17、配置和补丁同 y16、iris / ath12k 模块是这次编的；initramfs 里 init 的哈希、`/bin/e2fsck` 解开比对、cpio 在 Image 里；
  - 本次开机：init 切到的根就是 `/` 挂的那个设备；两次 e2fsck（先只查日志、后完整），都是 exit 0 或 1；顺序是「只查日志 → 第一次挂载 → trial 记数 → 完整检查 → 切根」；没有 10-31 那串（`Couldn't remount RDWR`、`clearing orphan list`、`start not counted`、`no e2fsck in this image`）；完整检查之后内核不再报这个根的 ext4 问题；`tune2fs -l` 是 `clean`、没有错误计数；
  - y16-verify 的 SDI、看门狗和健康检查，原样。
- `y17-verify-bed.sh`：y17-verify 的测试床。在平板上把本次（y16）开机的真日志改成 y17 开机的样子，用假的 journalctl / tune2fs 喂给体检：正常 0 FAIL，10 个变异各挂对应那一项。
- `Image-t52-y17.sha256`：两个镜像的 sha256（`.gz` 是 `a207541c…`）。
- 体检（`tools/y700-checklist.py`）「开机磁盘检查」一项，见 README「每日体检」。
- **平板上的产物**：`/usr/local/src/y700-kernel-y17/`（`Image-t52-y17.gz`、`Image-t52-y17`、`config-t52-y17`、`y700-y17.patch`、`initramfs.cpio.gz`、`initramfs.d/`），模块在 `/usr/local/src/y700-mods-y17/`。脚本副本 `/root/kbuild-y17.sh`、`/root/y17-init`、`/root/y17-verify.sh`。

## 构建结果（11-01 05:26 第一次；06:47 审查后改了 init 重编，平板）

- `KFULL_OK`。配置和补丁与 y16 一字不差（脚本里两处比对都是空）。
- Image 比 y16 大 851968 字节，就是压缩后的 e2fsck。
- 06:47 那次（现在用的）：`Image-t52-y17.gz` sha256 `a207541c054028fa…`，`Image-t52-y17` sha256 `3b5896897bc404bf…`；构建日志里 initramfs 解出来的 init 就是 `b450a91a…`，增长还是 851968 字节（对齐到页，init 多的几行不显）。05:26 那次（审查前的 init）是 `8af8d902…` / `e55f1055…`，已被覆盖。

## 验证过的（上机前）

- `init`：自带测试床 276/276（busybox sh 和 dash 各 138），上游 t54 的测试床跑它 180/180（原有行为没变）。审查后加的 3 个用例（`.tmp` 是链接、日志本身是链接、日志是 fifo）拿审查前的 init 跑：两个链接用例挂，fifo 那个直接卡死（300 秒超时掐断）——也就是旧版碰上 fifo 开机会一直卡住。
- 测试床有没有用：拿 t54 原版 init 跑 y17 的测试床，挂 26 项（全是 fsck 那几组）；再拿 6 个故意改坏的 y17 init（去掉只查日志、去掉完整检查、去掉配置、完整检查挪到 mount 之后、只查日志不带 `-E journal_only`、退出码一律当 clean），每个都挂对应的用例（11-01 平板，busybox sh）。
- `kbuild-y17.sh`：Win11 上先空跑过 initramfs 那段；平板上 `CHECK_ONLY=1` 过了，4 个故意弄错输入的变异都被拦下；然后全量编译 `KFULL_OK`。
- `y17-verify.sh`：在 y16 上跑按设计 FAIL；测试床 11 种情况各自对。
- 体检：自测 S37 共 18 个场景，全套 456 项过；9 个变异（「头一次」判定两个方向、600 秒上限、检查后的范围、开机范围、没有 e2fsck、没有结果行、错误计数、本次内核版本兜底）全被抓到；审查后加的 S37l 拿旧版跑会挂。

## 审查（11-01 06:xx，装之前）

5 个审查代理分头看 init 的开机安全、init 的数据安全和 e2fsck 语义、kbuild-y17.sh、y17-verify.sh 和它的测试床、体检那一项；每条发现再由另一个代理专门去驳。共 10 条，复核后属实 2 条，都在装之前改了：

1. **体检重报**（中）：本次开机修过一次根分区，到下次重启前每天的 `--save` 都会重报一遍、发通知。改成上次 `--save` 就在本次开机里跑过的话，本次开机不再读（留下的错误标记仍由 tune2fs 那项报）。自测 S37l。
2. **日志写到链接上**（轻）：见上面「完整输出」。init 改了，所以重编了一次（见「构建结果」）。

被驳掉、但写下来的：
- 只查日志那一步极少数情况下会变成整查；带 `orphan_file` 的分区不在修复范围内：都是注释说得太绝对，init 注释和上面「开机时它做什么」已改准。
- `gen_init_cpio | gzip` 没有 pipefail，gen_init_cpio 失败会被吞：机制属实，但列表里每个文件刚被上游 `build.sh`（`set -euo pipefail`）读过一遍，触发不了；而且新 cpio 会解开比对 init 和 e2fsck。没改。
- e2fsck 静态版只按包版本钉、没按文件 sha256 钉：编译那几分钟里有人手动 `apt upgrade` 才会变；这台没有自动升级。没改。
- initramfs 里除了 init 和 e2fsck 以外的文件没和 y16 逐个比（busybox、固件等是现场取的）：和 y16 对 y15 的做法一样；两次构建隔了几个小时、期间没装过别的包，Image 增长正好是 e2fsck 的大小。没改。
- 如果新体检在 y17 keep 之前就被装上，y16 上每天会为那个已知标记报 WARN：按执行顺序是和 keep 一起装，这里、README 两处都写了。没改代码。
- y17-verify-bed.sh 只能拿 y16 的开机日志喂（在 y17 上跑会出两个假 FAIL）、开机不满 4 分钟时全都显示 0 FAIL：都是在测试床说明的前提之外用它，而且错了一眼看得出来（变异全都不挂）。没改。
- 装之前把根分区整份打包备份到了 PC 上（旁边有 sha256）。

## 平板上的执行顺序

前提：作者知道；先看 8766 状态页没在测量；安装和重启分两步，重启由作者来。

1. 安装（trial）：
   ```
   tb323fu-ctl kernel install-local /usr/local/src/y700-kernel-y17/Image-t52-y17.gz --trial --name "y700 y17: y16 + e2fsck -p of the roots in the initramfs" --yes
   ```
2. **作者重启**：插着充电器，人在旁边。第一次开机会整个查一遍 sda15，屏幕亮着、写着 do not power off，一般几秒到几十秒，别关机。
3. 开机满 4 分钟：`bash /root/y17-verify.sh 2>&1 | tee /root/y17-verify-$(date +%Y%m%d-%H%M).log`，末行 `ALL PASS`。
4. 过了：`tb323fu-ctl kernel keep`。把新体检装到 `/usr/local/bin/y700-checklist`（旧版留 `.bak`），不带 `--save` 跑一次看「开机磁盘检查」那两项。日志拷回 `runs/kernel/`，结果写进上一节和 README。
   - 新体检要和 keep 一起装：装早了，它会在 y16 上每天为那个已知的标记报 WARN。

## 回滚

- **trial 期间（没 keep）**：`tb323fu-ctl kernel rollback` 把 good 的 y16 写回 boot_a，然后重启。不管它的话，两次启动没确认，第三次自动回 y16。
- **keep 之后**：`tb323fu-ctl kernel install-local /usr/local/src/y700-kernel-y16/Image-t52-y16.gz --trial --name "y700 y16: …" --yes`，重启，`y16-verify.sh` 过了再 keep。
- 回到 y16 不会把修好的文件系统弄坏；只是又回到「开机不查」。

## 有意不做的事

- **不用 `-y`、不用 `-f`**：`-y` 什么都答「是」，碰上 `-p` 不敢自动修的严重问题也会硬修，可能丢数据；那种情况宁可 exit 4 报给人。`-f` 会让每次开机都整个查一遍，没必要（`-p` 只在带标记时整个查）。
- **不做「跳过检查」的开关**（命令行参数、标记文件）：检查从不拦开机，又有 600 秒上限；要跳过完整检查就按住音量+（本来就有的功能）。多一个开关就多一个忘了关的地方。
- **不按根分别开关**：哪个根要挂就查哪个，规则只有一条。
- **`ktrial()` 不改成 umount 再读写挂**：只查日志那一步已经把孤儿链表清了，remount 能过。改 ktrial 是动上游的 trial 逻辑，等真看到 y17 上还漏记再说。
- **不改上游的 `build.sh` / `spec.list`**：照 y16 那样跑上游的，再改它的暂存目录；这样上游文件还是钉住的原样，y17 和 y16 的差别只在两个文件。
- **不在 initramfs 里对时、不修 `Last checked`**：板上 RTC 开机读出来是 1970，对时要网络。代价只是 `Last checked` 不再更新（停在 10-09）、按时间的强制检查不做，`-p` 按标记查不受影响。
- **完整检查时屏幕上没有进度、没有心跳**：e2fsck 的 `-C` 进度条要往终端刷，量过的整查只要 2 秒，不值得。
- **只查日志那一步按音量+跳不过**：它在读按键之前，又快，跳过反而会让 trial 漏记回来。
- **不往上游报**：rootfsck 是在上游 init 上打的我们自己的补丁；要报得作者点头（README「待办」）。

## 踩坑（根因）

- `set -e` 下，`[ a ] && [ b ]` 这种链，第一个测试失败时 shell **不会**退出（`&&` 前面的命令失败不触发 `set -e`）。kbuild-y17.sh 里一律拆成一条一条的测试；`kbuild-y16.sh` 里有同样的写法，它已经编完、keep 了，只在 kbuild-y17.sh 的注释里记一笔，没去改它。
- journald 把 init 写进 kmsg 的 `<1>baldur: …` 当成 `SYSLOG_IDENTIFIER=baldur`，`journalctl -o cat` 显示的是去掉前缀的 ` fsck …`（前面一个空格）。grep `^baldur:` 什么也找不到：要么 `-t baldur`，要么 `-o short --no-hostname`，要么像体检那样只 grep 消息本身。
- readelf 的输出跟着系统语言翻译，`Machine:` 那行在中文环境下对不上，脚本要 `LC_ALL=C`。
- 内核 `usr/Makefile`：`INITRAMFS_SOURCE` 给的是 `.cpio.gz` 时原样塞进 Image，所以能在 Image 里逐字节找到它，用来证明编进去的就是我们改过的那份。
- 早先的设计稿写「安卓不挂 sda15」，不对：安卓的 `switch-to-linux.sh` 会 `ro,noload` 挂它读 `linux-current.img`。结论不变——`noload` 不重放日志、什么也不写——待在安卓里不会改动 sda15。

## 没验证的（待确认）

- **trial 漏记修好了没有**：干净重启后开机本来就照常计数，所以 y17 第一次开机证明不了。要在 y17（或之后某个内核）的 trial 里碰上一次非正常复位，看到只读挂载前只查日志 exit 0、`remount,rw` 没被拒、计数往前走了，才算核实。可以做一次受控的看门狗咬测试，但那要作者在场、每一步同意，没安排。
- ~~第一次整查要多久~~ 11-01 实测 3 秒（见「上机结果」）。
- ~~那个坏 inode 修完以后丢了什么~~ 11-01 看过：6 个死机前就删掉的文件收尾，没丢在用的文件（见「上机结果」）。
- 如果哪天 e2fsck 报 exit 4（修不了），要从别的系统里 `e2fsck -f`；办法同 README「10-31 21:04 死机」的 (b)(c)，现在没准备。

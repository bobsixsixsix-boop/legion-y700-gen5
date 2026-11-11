# 内核 y19：y18 去掉 0153（笔倾角）重编；同轮落地 zram 方案 B（2026-11-04）

## 为什么有 y19

y18（11-04 16:56 keep）= y17 + 上游 kernel-t58 的 8 个补丁 + 两处 config（`linux/kernel-y18/NOTES.md`）。同晚作者拍板（原话「1不做，2选B，3 等我回去测」）：

1. 0153（nt36536 笔倾角按屏幕轴向上报：x 取反、x/y 互换）**不要**。没笔验不了，作者不想带一个验不了的输入行为改动。
2. zram 走 **B**：自己改 zram-generator.conf 与 sysctl，不装 tb323fu-platform 0.4.6。
3. USB-C 外接屏那四条（0147/0149–0151）作者回来自己测，Claude 不动。

去掉一个补丁就是一个新内核：y18 的 keep 记录不改，y19 重新走 trial→keep。版本号按 y14–y18 的钉子规则起新号而不叫「y18 修订」：每个 yNN 对应唯一的 tree / Image / config 三元组，README 和 8766 页上一眼能对上。

## y19 是什么

- **源**：分支 `y19` = y16（`82bf9859f5f6`）+ 0144、0147、0148、0149、0150、0151、0152 这 7 个 = **`y18~1`**。y18-branch.sh 用固定的 committer 身份和日期（`Wed, 04 Nov 2026 17:00:00 +0900`）打补丁，y19-branch.sh 原样沿用，所以这 7 个 commit 就是 y18 自己的前 7 个；`git rev-parse y19` 必须等于 `git rev-parse y18~1`，y19-branch.sh 和 kbuild-y19.sh 都断言。`drivers/input/touchscreen/nt36536/nt36xxx.c` 回到 t52-base 的内容。
- **config**：**与 y18 完全相同**（CMDLINE 去 `no_console_suspend`、`BOOTPARAM_HUNG_TASK_PANIC=0`）。kbuild-y19.sh 对 y18 的 pre-build / final config 要求 delta 为空，对 y17 的仍要求是 y18 那 4 行——两道钉。
- **initramfs**：与 y17 / y18 相同（t54 build.sh，再换 /init = y17-init、加 /bin/e2fsck = e2fsck.static）。
- 发行号 `7.3.0-tb323fu-t52-y19`。构建是增量：只重编 nt36536 模块（`CONFIG_TOUCHSCREEN_NT36536_SPI=m`）、版本串和链接，Nice 19 下约一分钟。**Image 本身与 y18 的只差版本串**（nt36xxx.o 在模块里），所以 Image 不当 0153 的证据，源码和 `y700-y19.patch` 的断言才是。

## 相对 y18 的脚本改动（`diff linux/kernel-y18/*.sh linux/kernel-y19/*.sh` 能看全）

- `prep/y19-branch.sh`：NEW 列表 7 个；series 的 sha 换成去掉 0153 那行后的 `414aecb8…`（35 个补丁的 sha 不变）；`complete()` 查 35 个 commit、`y19~7` 是 y16、最后一个 commit 的 Subject 是 0152 的；y18 分支在时断言 `y19 == y18~1`；改动文件清单 8 个（没有 nt36xxx.c）；输入里不许有任何笔补丁——series 名含 0153 / nt36536 / tilt、或任何 patch 碰 nt36xxx.c 都拒。**不用 `*pen*` 匹配**：0148 的文件名 `drop-no_console_suspend` 里 sus**pen**d 含 pen。
- `kbuild-y19.sh`：`Y19_TREE` 先是占位 `PIN_ME_FROM_Y19_BRANCH_LOG`，跑完 y19-branch.sh 从日志抄进来；多了 `$Y18` 参照（它的四个产物都得在）；35 个 commit、`HEAD~7`；0153 那块换成反向断言——nt36xxx.c 与 t52-base 无 diff，t52 原文 `pen_tilt_x = (int32_t)point_data[73]` / `pen_tilt_y = (int32_t)point_data[74]` 两行还在，`-(int8_t)point_data[74]` 不在；config delta 对 y18 为空、对 y17 为 4 行；`y700-y19.patch` 既不等于 y17 的也不等于 y18 的、不含 nt36xxx.c；改动文件 8 个；Image 大小与 y18 的、y17 的差都在 ±1 MiB 内。
- `y19-verify.sh`：新增「运行中的 config 与 y18 的完全相同」；补丁归档不含 nt36xxx.c；笔那条措辞改为「t52 的笔代码：0153 去掉」；**新增 zram B 五条**（见下）。

## zram 方案 B

作者选 B（README「内核 y18」⑤ 列过 A / B）。改两个文件，仓里的原件在 `linux/zram/`，平板上的路径与仓里一一对应：

| 平板上 | 仓里 | 内容 |
|---|---|---|
| `/etc/systemd/zram-generator.conf` | `linux/zram/zram-generator.conf` | `zram-size = ram`（原 `ram / 2`）；zstd、优先级 100 不变 |
| `/etc/sysctl.d/90-y700-zram.conf` | `linux/zram/90-y700-zram.conf` | `vm.swappiness = 100`、`vm.page-cluster = 0`（内核默认 60、3） |

- **为什么不装包**：tb323fu-platform 0.4.6 的 `tb323fu-zram` 发现已有 zram swap 就让路（README「内核 y18」⑤ 读过它的脚本），装了等于没装；装包还会把 0.4.6 其他东西一并带上，这轮不碰。
- **为什么是这两个值**：swap 只有 zram、没有寻道成本，所以 page-cluster 0 一次换入一页，不像默认那样预读 8 页；swappiness 100 让内核更愿意把冷的匿名页压进 zram 换出 page cache——这也是 tb323fu-zram 自己设的值。`zram-size = ram` 是上限：zram 实际占多少内存由压缩后的用量决定，不是先占满。
- **怎么生效**（一次 restart，不重启系统）：
  ```
  cp -a /etc/systemd/zram-generator.conf /root/zram-generator.conf.bak-20261104
  install -m 644 /root/zram-generator.conf /etc/systemd/zram-generator.conf
  install -m 644 /root/90-y700-zram.conf /etc/sysctl.d/90-y700-zram.conf
  systemctl daemon-reload && systemctl restart systemd-zram-setup@zram0 && sysctl --system
  ```
  restart 先 swapoff（unit 的 ExecStop 复位设备），swap 里的页要能放回内存，动手前 `free -m` 看一眼。
- **怎么验**：`swapon --show --bytes`（zram0 ≈ MemTotal）、`cat /sys/block/zram0/disksize`、`sysctl vm.swappiness vm.page-cluster`；y19-verify.sh 的 5 条；体检「zram」一项（自测 S39a–g：正常 / 半内存 / 60-3 / 没 swap / 多一个 swap / 不是 zstd / 读不到 MemTotal）。
- **回滚**：`/root/zram-generator.conf.bak-20261104` 装回 `/etc/systemd/`，删 `/etc/sysctl.d/90-y700-zram.conf`，再 `systemctl daemon-reload && systemctl restart systemd-zram-setup@zram0 && sysctl -w vm.swappiness=60 vm.page-cluster=3`。删 sysctl 文件不会自己回到 60 / 3，要手动写或重启。

## 文件清单（linux/kernel-y19/）

- `patches/`：35 个补丁 + `series`（y18 的去掉 0153；每个补丁的 sha 不变）
- `prep/y19-branch.sh`：造分支 y19
- `kbuild-y19.sh`：构建
- `y19-verify.sh`：首次开机验证（含 zram B）
- `NOTES.md`：本文件
- `Image-t52-y19.sha256`：构建产物的 sha256（11-04 20:19 的产物）
- 相关：`linux/zram/`（两个配置原件）、`tools/y700-checklist.py` 的 `check_zram`、`runs/kernel/y19-verify-*.log`

## 执行顺序（平板可达、8766 页空闲时）

1. zram B：`scp -O` 两个文件到 `/root/`，比 sha256；按上面「怎么生效」做；验。
2. `scp -O` `patches/*` → `/root/y19-patches/`、`prep/y19-branch.sh` 和 `y19-verify.sh` → `/root/`，比 sha；`bash /root/y19-branch.sh 2>&1 | tee /root/y19-branch.log` → `Y19_BRANCH_OK`；把日志里的 `Y19_TREE=` 抄进仓里的 kbuild-y19.sh，再 scp 上去。
3. `CHECK_ONLY=1 bash /root/kbuild-y19.sh`，日志里 grep `CHECK_ONLY_OK`（别 tail -1：最后一行是 set -x 的 `+ exit 0`）。
4. `systemd-run --unit=y700-kbuild-y19 --collect -p Nice=19 -p CPUWeight=20 -p IOWeight=20 /bin/bash /root/kbuild-y19.sh` → 日志末 `KFULL_OK`；`sync`。
5. `tb323fu-ctl kernel install-local /usr/local/src/y700-kernel-y19/Image-t52-y19.gz --trial --name "y700 y19: y18 minus 0153 (pen tilt), = y17 + t58 0144 0147-0152, hung task report only, no no_console_suspend" --yes`。
6. 看 8766 页没人用（units 全 stopped、ssh_sessions 0）、先说一声，再 `systemctl reboot`——装和重启分两步。
7. 开机 ≥ 4 分钟后 `bash /root/y19-verify.sh | tee /root/y19-verify-$(date +%Y%m%d-%H%M).log` → `ALL PASS`；`tb323fu-ctl kernel keep`；日志拷回 `runs/kernel/`。
8. 装新体检（`scp -O tools/y700-checklist.py`，先备份旧的、比 sha），跑一遍不带 `--save`。

## 上机前审查（11-04 晚，只读，5 个方面，每条发现再核一遍）

- **高**（已修）：`y19-verify.sh` 的 zram conf 那条带了 `! grep -q "ram / 2"`，而仓里 conf 第一行注释就写着 `was ram / 2`——装上去必 FAIL，verify 永远到不了 ALL PASS。去掉这个反向 grep（`grep -qx "zram-size = ram"` 已经钉死指令行）。教训：**反向 grep 要锚定到指令，不能对整个文件**。
- **低**（已修）：kbuild 里 `cmp Image-y19 Image-y18` 是废话（版本串不同必不等）、注释还把差异归到 nt36xxx.o——nt36536 是模块，不在 Image 里；删掉 cmp、改注释。体检 zstd 那条没自测也没点名文件，补 S39f；MemTotal / disksize 读不到时原来静默当 0 过关，改成 WARN，补 S39g。本文件执行顺序漏了 scp `y19-verify.sh`。y18 的 NOTES / README 里「zram 等作者点头」几处过时，补上指向。
- 没发现问题的：y19-branch.sh（35 个 sha 重算一致、LAST_SUBJECT 对、改动文件表对）、kbuild 其余断言、两个 conf 文件语法、README 与 NOTES 的命令 / 路径一致性。

## 有意不做

- 不给 0153 留开关或分支：作者说不要就整个不带；以后想要，按 y18 的 `patches/` 加回来再重编一个新号。
- 不动 USB-C 外接屏验收（作者自己测）。
- 不装 tb323fu-platform 0.4.6（见 zram 一节）。
- 不改 zram 的 compression-algorithm / swap-priority：原值够用。
- 不配 zram writeback / backing device：没有合适的盘，UFS 寿命优先。
- 不改 README 里 y18 的 keep 记录，只在 y18 节加一句「同晚被 y19 接替」。

## 上机结果（11-04 20:16–20:30，平板回线后一口气做完）

- **y19-branch.sh**：20:17 `Y19_BRANCH_OK`（`/root/y19-branch.log`）。HEAD `05c8bc5831e59f00ccd7f003d6f21e33f2e3490d` = `git rev-parse y18~1`，tree `e007de00615d2baa0bd258582fab3e24f3094d15`（已钉进 kbuild-y19.sh）；35 个补丁回导出：19 个 byte-identical、16 个只差首行 / index / 版本尾（y16 的 28 个是 19 + 9）；y16 未动。
- **CHECK_ONLY**：`CHECK_ONLY_OK`（`/root/y700-kernel-y19-check.log`，5706 行）。
- **构建**：20:18:54 起 unit `y700-kbuild-y19`，20:19 `KFULL_OK`，约 75 秒（`/root/y700-kernel-y19.log`）。产物 sha 在 `Image-t52-y19.sha256`。0153 确实不在的证据：`/usr/local/src/y700-mods-y19/lib/modules/7.3.0-tb323fu-t52-y19/kernel/drivers/input/touchscreen/nt36536/nt36536_ts.ko` sha `04e56fcd…`，y18 的 `5840c58e…`；`y700-y19.patch` 的 `diff --git` 文件列表 = y18 的减 `nt36xxx.c` 一行；`config-t52-y19` 与 y18 的 `diff` 只有 `CONFIG_LOCALVERSION` 和 `CONFIG_INITRAMFS_SOURCE` 两行（kbuild 的 cfgdelta 把这两行归一化后 delta 为空）。
- **trial / verify / keep**：20:21 `install-local --trial`（boot_a，start 0 of 2）；8766 页空闲、说过一声后 20:22:07 `systemctl reboot`，20:22:18 页面已带新 boot id `c7367dfb`、`uname -r` = `7.3.0-tb323fu-t52-y19`、state trial；开机 249 秒后 20:26 `y19-verify.sh` **ALL PASS**（70 条 PASS、0 FAIL，`/root/y19-verify-20261104-2026.log`，副本 `runs/kernel/`）；20:26:57 `tb323fu-ctl kernel keep` → `kept 7.3.0-tb323fu-t52-y19: it is the good kernel now`。
- **zram B**：20:17 按「怎么生效」做（`free -m` 时 swap 用量 0，放心 swapoff）。之后 `/sys/block/zram0/disksize` 15869149184 B，MemTotal 15869775872 B（差 626688 B，在 2 MiB 内），`/proc/swaps` 只有 zram0、prio 100，`comp_algorithm` `[zstd]`，swappiness 100、page-cluster 0；重启进 y19 后全部仍在（开机 generator 读的就是新 conf）。**坑**：restart 的命令刚返回时 `swapon --show` 还是空、`dev-zram0.swap` 显示 `activating`——swap 单元排在 service 之后才起，journal 里前后都在 20:17:41 同一秒；隔一两秒再看，别当失败。
- **体检**：新 `y700-checklist` 装到 `/usr/local/bin/`（sha `2616844c…` 两边一致，旧版 `/root/y700-checklist.bak-20261104b`），不带 `--save` 跑（`/root/y700-checklist-20261104-y19.out`，退出码 10）：61 OK、0 WARN、2 CHANGED——内核 y17→y19（状态自 y17 起没 `--save`，本就该报）、LIVI 10.0.0→10.3.0（CarPlay 线装的，归那条线 `--save`）；「zram」一项 OK：「zram0 14.8 GiB = 整个内存，zstd，优先级 100；swappiness 100、page-cluster 0」。
- **平板上多出的文件**：`/root/y19-patches/`、`/root/y19-branch.sh`、`/root/y19-branch.log`、`/root/kbuild-y19.sh`、`/root/y700-kernel-y19[-check].log`、`/root/y19-verify.sh`、`/root/y19-verify-20261104-2026.log`、`/usr/local/src/y700-kernel-y19/`、`/usr/local/src/y700-mods-y19/`、`/root/zram-generator.conf`、`/root/90-y700-zram.conf`（两个原件副本）、`/root/zram-generator.conf.bak-20261104`（回滚用，留着）、`/root/y700-checklist.py.new`（可删）、`/root/y700-checklist.bak-20261104b`、`/root/y700-checklist-20261104-y19.out`。

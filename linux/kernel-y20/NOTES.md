# 内核 y20：y19 + `CONFIG_HID_MAGICMOUSE=m`（Magic Mouse 2 驱动进内核；2026-11-04）

## 为什么有 y20

- 作者 11-04 晚用 Magic Mouse 2 / Magic Keyboard 接平板办公。上游 `config-t49.release` 把 `HID_MAGICMOUSE` 关着（`# CONFIG_HID_MAGICMOUSE is not set`，y5–y19 全沿用），鼠标落到 hid-generic：能动、能点，没滚轮、没中键。
- 平板侧的 Claude 当晚先做了不动内核的过渡方案：按 y19 的树在平板上树外编了一份 `hid-magicmouse.ko`，放 `/usr/local/lib/y700-extra-modules/7.3.0-tb323fu-t52-y19/`；udev 规则 `90-y700-magicmouse.rules` 见到鼠标的 hid 设备（MODALIAS `hid:b0005g*v0000004Cp00000269` 等四个）就跑 `/usr/local/sbin/y700-extra-modules hid-magicmouse`——内核自带就 `modprobe`，没有就 `insmod` 树外那份并带上 `/etc/modprobe.d` 里的 options。配 `hid_magicmouse.conf`（`scroll_acceleration=1`）和 `hid_apple.conf`（`fnmode=2`，键盘 F 键是 F 键）。同时写好了 `/root/y8-fragments/owner-devices.fragment`（就一行 `CONFIG_HID_MAGICMOUSE=m`）留给下一个内核，并在 `config-t52-y19.pre-build` 上试过 scripts/config + olddefconfig：只动这一行。
- 树外模块每换一个内核都得重编、带 `(O)` taint，udev 规则只是补丁。作者问「新的内核是不是也该上了」，于是编 y20 把它收进内核。按 y14–y19 的钉子规则（一个 yNN 对应一个 tree + 一份 config）起新号，不叫「y19 修订」。

## y20 是什么

- 源码**与 y19 一字不改**：分支 `y20` = y19 的那个 commit（`05c8bc5831e5` = `y18~1`，tree `e007de00615d`）。`prep/y20-branch.sh` 只建分支、不导出不打补丁；kbuild-y20.sh 照旧用 `/root/y19-patches` 回放一遍、断言 tree，并断言 `git rev-parse y19` 仍是那个 commit。
- 配置 = y19 的 + `owner-devices.fragment`（`CONFIG_HID_MAGICMOUSE=m`）。`HID_MAGICMOUSE` 是 tristate、只 `depends on HID`、不 `select` 任何东西，olddefconfig 后对 y19 的 delta 应恰好一行 `> CONFIG_HID_MAGICMOUSE=m`（y19 里的 `# ... is not set` 是注释，cfgcmp 过滤掉）。kbuild 对 y19、y18（pre-build 和最终各一次）都断言这一行，对 y17 是 y18 的 4 行 + 这一行。
- 产物差别：`CONFIG_HID=y`，`drivers/hid/hid-quirks.c` 的 `hid_have_special_driver[]` 里 Magic Mouse/Trackpad 那几条在 `IS_ENABLED(CONFIG_HID_MAGICMOUSE)` 下；Image 里嵌的 initramfs cpio 的 `modules.sqfs` 多了 `hid-magicmouse.ko` 和重生成的 depmod 索引，`/proc/config.gz` 也变——所以 **Image 和 y19 的除版本串外还差几十 KB**，是正常的。Image 检查沿用 y19 的做法（±1 MiB 上限 + 注释，参照从 y18 换成 y19）；y19 的 README 说「Image 与 y18 只差版本串」只是观察（nt36536 是 `=m`），y19 也从没拿 Image 当证据。真正的证据是 config delta、`$MODS/.../hid/hid-magicmouse.ko`（`intree=Y`、alias `hid:b0005g*v0000004Cp00000269` 和 USB 的 `hid:b0003g*v000005ACp00000269`、parm `scroll_acceleration`）、initramfs 的 `modules.sqfs` 里有它（`unsquashfs -l`），以及 `y700-y20.patch` 与 `y700-y19.patch` `cmp` 相同。
- 版本串 `7.3.0-tb323fu-t52-y20`；initramfs 同 y17–y19（t54 build.sh + y17 init + 静态 e2fsck）。

## 相对 y19 的脚本改动（`diff linux/kernel-y19/kbuild-y19.sh linux/kernel-y20/kbuild-y20.sh` 能看全）

- `prep/y20-branch.sh`：全新小脚本：断言 y19 在钉死的 commit/tree、35 个 commit、`y19~7` = y16、是 `y18~1`；工作树干净、没半截 am/cherry-pick；`git branch y20 <y19 commit>` + `switch`；打印 `Y20_HEAD=` / `Y20_TREE=` / `Y20_BRANCH_OK`。可重跑；y20 已在别的 commit 上则拒绝。写 git 都带 `-c gc.auto=0 -c maintenance.auto=0`（linux-t52 与 linux-t47 共用对象库）。
- `kbuild-y20.sh`（+ 约 50 行）：`Y20_HEAD` / `Y20_TREE` 钉死（值 = y19 的）；FRSUMS 多一行 `owner-devices.fragment` 的 sha，并按 apply_fragment 自己的 pattern 断言它只含 `CONFIG_HID_MAGICMOUSE=m`（文件注释里也有 CONFIG_ 字样，用 `^(# )?CONFIG_` 会误判）；要求 y19 的四个产物 + `initramfs.d/modules.sqfs` 在、y19 config 和 `config-t49.release` 里该项 is not set、y19 的 MODS 里没有 hid-magicmouse.ko；树检查多 `HEAD == Y20_HEAD`、`y19 == Y20_HEAD`；`apply_fragment $FR/owner-devices.fragment`（在 y8-power 之后）；check_config 多 HID 一组（`HID=y`、`HID_MAGICMOUSE=m`、`HID_APPLE=m`、`HID_GENERIC=m`、`UHID=m`、`BT_HIDP=m`、`HID_BATTERY_STRENGTH=y`），fragment 循环含它；config delta 三组（y19 / y18 各一行、y17 五行，pre-build 和最终各一次）；编完后 hid-magicmouse.ko 存在、`intree=Y`、两个 alias、两个 parm；`unsquashfs -l` 断言 sqfs 里有它（顶部 `command -v unsquashfs`，`/usr/bin/unsquashfs` 平板上有）；`cmp y700-y20.patch y700-y19.patch` 必须相同（原来的「不等于 y17/y18、不碰 nt36xxx.c、8 个文件」照留）；Image 增长对 y19 / y17 ±1 MiB；临时名（`/tmp/y20-kbuild-index`、`/tmp/y20-check-bad`、`/tmp/y20-cpio`）全换。
- `y20-verify.sh`（+ 约 30 行）：config 对 y19 / y18 一行、对 y17 五行，另单独一条 `grep -x CONFIG_HID_MAGICMOUSE=m`；patch 与 y19 `cmp` 相同；新增 `skip()`；Magic 一组：模块文件在 `/lib/modules/$REL/kernel/drivers/hid/hid-magicmouse.ko` 且 `intree=Y`、与构建的那份 cmp 相同；`modinfo -n` / `modprobe -n` 解析到它；alias；`/usr/local/lib/y700-extra-modules/$REL/` 不存在；四个过渡文件在；手跑 `y700-extra-modules hid-magicmouse` 退出 0 且模块已载；**`/proc/modules` 该行没 `(O)`、`/sys/module/hid_magicmouse/taint` 为空**（整机 `/proc/sys/kernel/tainted` 是 4096（bit 12 = O），只来自音箱功放的树外模块 `snd_soc_aw882xx`，每个内核都有，基线如此，与它无关；这才是「内核自带、不是 insmod 树外那份」的直接证据——y19 上树外那份 taint 是 `O`）；`scroll_acceleration=Y`；鼠标接着才查 hid 设备 `driver` → `magicmouse`，没接 SKIP；hid_apple 载了才查 `fnmode=2`，没载 SKIP；INFO 打 `journalctl -b -t y700-dp-source` 的行数和 `port0/power_role`（接着外接屏时该是 `[source] sink`）。y19 的 70 条照跑。
- verify 的副作用：会把 hid_magicmouse 载进来（没载的话）——和配对鼠标时发生的事一样，别的不写。

## 过渡文件进仓（`linux/owner-devices/`）

平板上的原件是平板侧 Claude 写的，**只拷回不改**（scp -O 回来 sha256 比对一致）：

| 平板 | 仓 | 权限 |
|---|---|---|
| `/etc/udev/rules.d/90-y700-magicmouse.rules` | `90-y700-magicmouse.rules` | 644 |
| `/usr/local/sbin/y700-extra-modules` | `y700-extra-modules` | 755 |
| `/etc/modprobe.d/hid_magicmouse.conf` | `hid_magicmouse.conf` | 644 |
| `/etc/modprobe.d/hid_apple.conf` | `hid_apple.conf` | 644 |
| `/root/y8-fragments/owner-devices.fragment` | `../kernel-y8/owner-devices.fragment`（和另外三个 fragment 放一起） | 644 |

`install.sh`（新写）：四个文件 `install` 到位 + `udevadm control --reload` + `cmp` 回查；**不装树外 .ko**（那是按 y19 的树编的，只给 y19）；最后按 `modprobe -n` 报这个内核的 hid-magicmouse 是内核自带 / 树外 / 都没有。幂等。

## 体检项「Magic 鼠标驱动」（`tools/y700-checklist.py`，自测 S41a–i）

只读文件：没有规则也没有加载脚本就不出这一项（这台平板没配过）；两个只缺一个 → WARN 点名 install.sh；`/lib/modules/<当前内核>/kernel/drivers/hid/hid-magicmouse.ko` 和 `/usr/local/lib/y700-extra-modules/<当前内核>/hid-magicmouse.ko` 都没有 → WARN「换内核忘了带」；`/sys/bus/hid/devices/*/uevent` 里 `HID_ID` 是 `0005:0000004C:00000269`（或 USB 的 `0003:000005AC:00000269`）而 `DRIVER` 不是 `magicmouse` → WARN；`scroll_acceleration` 读得到却不是 Y、`hid_apple fnmode` 读得到却不是 2 → WARN 点名各自的 conf；否则 OK 报接着几个、驱动来源（内核自带 / 树外）。自测里 hid 设备目录名不用冒号（Windows 文件名不许），体检本来就只看 uevent 内容。

## 文件清单（`linux/kernel-y20/`）

- `prep/y20-branch.sh`、`kbuild-y20.sh`、`y20-verify.sh`、`NOTES.md`（本文）、`Image-t52-y20.sha256`（构建后填）。
- 补丁不另放：与 y19 完全一样，用 `linux/kernel-y19/patches/`（平板上 `/root/y19-patches/`）。

## 执行顺序（平板可达；构建等 8766 页空闲或作者说「编吧」）

1. 仓里：`bash -n` 三个脚本、`python -X utf8 tools/y700-checklist-selftest.py`、只读审查、commit（含过渡文件）。
2. `scp -O` 三个脚本到 `/root/`，sha256 比对（Git Bash 的 sha256sum 输出带 `*`，比对前去掉）。
3. `bash /root/y20-branch.sh 2>&1 | tee /root/y20-branch.log` → 末行 `Y20_BRANCH_OK`，`Y20_HEAD=` / `Y20_TREE=` 与 kbuild 钉的值一致。
4. `CHECK_ONLY=1 bash /root/kbuild-y20.sh; grep CHECK_ONLY_OK /root/y700-kernel-y20-check.log`（日志末行是 set -x 的 `+ exit 0`，别 tail -1）。
5. 8766 页空闲（`dpms=Off`、实验 unit 全 stopped、`ssh_sessions` 只有自己）：`systemd-run --unit=y700-kbuild-y20 --collect -p Nice=19 -p CPUWeight=20 -p IOWeight=20 /bin/bash /root/kbuild-y20.sh`，等 `/root/y700-kernel-y20.log` 末行 `KFULL_OK`，`sync`。
6. `sha256sum` 七个产物 → 仓 `Image-t52-y20.sha256`。
7. `tb323fu-ctl kernel install-local /usr/local/src/y700-kernel-y20/Image-t52-y20.gz --trial --name "y700 y20: y19 + HID_MAGICMOUSE=m (Magic Mouse 2), same source as y19" --yes`；**说一声**。
8. 8766 页仍空闲、先说一声，再 `reboot`（11-01 的授权：装和重启分两步）。
9. 开机 ≥ 4 min：`bash /root/y20-verify.sh 2>&1 | tee /root/y20-verify-<时刻>.log` → 末行 `ALL PASS`；若接着外接屏，看 `journalctl -b -u tb323fu-usb-port -t y700-dp-source` 与 `cat /sys/class/typec/port0/power_role`（该 `[source] sink`），结果写进本文「上机结果」。不用再手跑 `/usr/local/libexec/y700-dp-source`：开机路径已补上（`tb323fu-usb-port.service.d/y700.conf` 的 `ExecStartPost=-/usr/local/libexec/y700-dp-source`）。作者 22:08 已拔外接屏，重启时多半不带屏，那就只记 power_role。
10. `tb323fu-ctl kernel keep`；**说一声**。
11. `gio trash /usr/local/lib/y700-extra-modules/7.3.0-tb323fu-t52-y19/`（规则和 y700-extra-modules 留着：y20 上是 no-op）。
12. 装新体检（备份旧的、sha 比对），跑一遍**不带 `--save`**（CarPlay 线 20:57 存过基线；「内核」一项 CHANGED 是预期）。
13. README（本节现状、y19 标题「被 y20 接替」、「当前有效状态」good = y20、「每日体检」）、本文「上机结果」、`Image-t52-y20.sha256`，commit。

## 有意不做

- 不做 Mac 式多指手势、惯性滚动：上游 hid-magicmouse 不支持（给的是滚轮 + 中键 + 可选 MSC_RAW）。
- 不碰 Touch ID 键盘的指纹部分；`hid_apple` 只设 `fnmode=2`。
- 不删 udev 规则和 `y700-extra-modules`：y20 上它们是 no-op（modprobe 分支），留着以后再有树外模块还能用；y19 的树外 `.ko` 目录 keep 后 `gio trash`。
- 不把 `HID_MAGICMOUSE` 编进 Image（`=y`）：fragment 写的 `=m`，与 hid-apple / hid-generic 一样做模块。
- 不动 y19 的 keep 记录；y20 不夹带别的 config / 源码变化（要改另起号）。
- 体检、kbuild、verify 只认产品号 `0269`（作者这只蓝牙 `004C:0269` Magic Mouse 2 的两种 HID_ID 形态都认）：udev 规则多覆盖的 `0323`（USB-C 版）作者没有，等有了再加一条自测。
- dock 部分的 shellbar 补丁 `/usr/local/src/y700-shellbar/kbd-dnd-mouse-20261104.patch`（键盘拖放 / 鼠标）归 dock 部分，这里只记「待合」。

## 上机结果（11-04 22:49–22:59，平板空闲时一口气做完）

- **审查**：进平板前做了一轮只读审查（kbuild、verify、prep/install、体检、文档一致、内核领域六个方面，每条发现再核一遍）。确认 4 条，都是低级别，已在 89dd998 改掉：verify 的 `journalctl` 加 `-q`（不加的话没匹配会把 `-- No entries --` 算成一行）；y20-branch 的恢复提示先 `git switch --detach` 再删分支；kbuild 注释改说 Image 差异来自 initramfs 和 config.gz；本文不再说 y19 拿 Image 当证据。被驳回 3 条：体检只认 `0269`（`0323` 作者没有，写进「有意不做」）、加载脚本只查可读、S41 只测蓝牙形态。
- **y20-branch.sh**：22:49 `Y20_BRANCH_OK`（`/root/y20-branch.log`）。分支 `y20` = `05c8bc5831e59f00ccd7f003d6f21e33f2e3490d`（= y19），tree `e007de00615d2baa0bd258582fab3e24f3094d15`，已检出、工作区干净；y19 没动。
- **CHECK_ONLY**：`CHECK_ONLY_OK`（`/root/y700-kernel-y20-check.log`）。pre-build 对 y19 / y18 的 config delta 恰好 `> CONFIG_HID_MAGICMOUSE=m`。
- **构建**：22:50:21 起 unit `y700-kbuild-y20`，22:51 `KFULL_OK`，约 1 分钟（`/root/y700-kernel-y20.log`，8754 行）。增量：只重编 `drivers/hid/hid-quirks.o` 和 `hid-magicmouse.ko`、链接和 initramfs。产物 sha 在 `Image-t52-y20.sha256`。
  - 最终 config 对 y19 的 `diff` 只有 3 行：`LOCALVERSION`、`INITRAMFS_SOURCE`（两者 kbuild 本就滤掉）和 `CONFIG_HID_MAGICMOUSE=m`。
  - `y700-y20.patch` 与 `y700-y19.patch` `cmp` 相同（sha `8b3c2345…`）。
  - **Image 大小与 y19 一样**，都是 66179080 字节，kbuild 报 growth 0。嵌的 initramfs.cpio.gz 大了 7229 字节（17642501 对 17635272），被对齐吸收了。内容从嵌的 cpio.gz 起整段不同（`cmp -l` 1858 万字节）。kbuild-y20.sh 注释里「tens of KB」说的是内容变化，不是大小。脚本按跑过的原样留着，不改。
- **trial / 重启 / verify / keep**：
  - 22:52 `install-local --trial`（boot_a，start 0 of 2）。
  - 22:53 8766 页仍空闲，说一声后 22:53:50 `systemctl reboot`。
  - 新 boot id `80f411a3`，`uname -r` = `7.3.0-tb323fu-t52-y20`，state trial。
  - 开机 270 秒 `y20-verify.sh` **ALL PASS**：80 PASS、0 FAIL、2 SKIP（鼠标、键盘没接）。日志在 `/root/y20-verify-20261104-2258.log`，仓里有一份 `runs/kernel/y20-verify-20261104-2258.log`。
  - Magic 一组全过。`modinfo -n hid_magicmouse` 指向 `/lib/modules/7.3.0-tb323fu-t52-y20/kernel/drivers/hid/hid-magicmouse.ko`。手跑加载脚本后 `/proc/modules` 是 `hid_magicmouse 20480 0 - Live …`，没有 `(O)`，`/sys/module/hid_magicmouse/taint` 为空，`scroll_acceleration=Y`。taint 4096 只来自 aw882xx（`snd_soc_aw882xx (O)` 是 `/proc/modules` 里唯一带 `(O)` 的），hid_magicmouse 无 `(O)`；23:0x 复核时又核过一遍。
  - ath12k 是 y20 构建的那份，wifi 连着且省电开着，声卡和 aw882xx 功放都在，`systemctl --failed` 为空。
  - 22:58:56 `tb323fu-ctl kernel keep` 后 good = y20、state idle。
- **USB-C**：重启时没接外接屏（作者 22:08 拔了）。本次开机 `y700-dp-source` 0 行（verify 已加 `-q`，没有 `-- No entries --` 误计），power_role `source [sink]`，DP-1 disconnected，都符合没接屏的预期。接屏的情况这轮没测到。
- **树外模块**：22:59 `gio trash /usr/local/lib/y700-extra-modules/7.3.0-tb323fu-t52-y19`，现在在 `/root/.local/share/Trash/files/7.3.0-tb323fu-t52-y19`；`/usr/local/lib/y700-extra-modules/` 空着。规则和加载脚本留着。
- **体检**：新 `y700-checklist` 装到 `/usr/local/bin/`，两边 sha 都是 `ba8afc37…`。旧版备份在 `/root/y700-checklist.bak-20261104c-2259`（sha `d585bce4…`；`-20261104c` 这个名字早被占了）。不带 `--save` 跑，输出在 `/root/y700-checklist-20261104-y20.out`，退出码 10：62 OK、0 WARN、1 CHANGED（内核 y19→y20，预期；状态 20:57 由 CarPlay 部分存过）。「Magic 鼠标驱动」报 OK「没接；hid-magicmouse 内核自带，规则和加载脚本在」。
- **鼠标真机验收**：作者 11-04 23:1x 在 y20 上接 Magic Mouse 2，原话「鼠标接上了，滚轮能用」。本次开机 journal 23:00:35 有 `magicmouse 0005:004C:0269.0001: unknown main item tag 0x0` 和 `input: Magic Mouse … input9`，说明绑的是树内驱动。
- **还没验到的**：键盘接着时 `fnmode=2`。y20-verify 那两条 SKIP 不专门起实验，下次键鼠接着时顺手重跑就会 PASS。体检接着时也会查。
- **平板上多出的文件**：`/root/y20-branch.sh`、`/root/y20-branch.log`、`/root/kbuild-y20.sh`、`/root/y700-kernel-y20[-check].log`、`/root/y20-verify.sh`、`/root/y20-verify-20261104-2258.log`、`/root/y700-checklist-20261104-y20.out`、`/root/y700-checklist.bak-20261104c-2259`、`/usr/local/src/y700-kernel-y20/`、`/usr/local/src/y700-mods-y20/`；`linux-t52` 里的分支 `y20`（已检出）。

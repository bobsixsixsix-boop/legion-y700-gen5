# Y700 后摄自动对焦与镜头供电（libcamera，2026-10-28 起；10-29 01:50 装上平板，验收 PASS）

> 交接文档：写给没有上下文的下一个接手者。**10-29 01:50 已装上平板并 hold 住，装后检查 `RESULT: PASS`，镜头漏电修好了**。还差作者实拍一次近物，看锁焦对不对（前提 3）。熄屏功耗对比 10-29 夜里测完了：测不出差别，只能给上界。原版状态熄屏多耗电的 95 % 置信上界约 9 mW，约占熄屏平均功耗 233 mW 的 4 %。按器件估算，真值多半只有 1–4 mW，台架分辨不出来，所以不为它再测第二夜。现状见「验证状态」。

## 要做的事与原因

主 README 里有两条，本目录一起处理：

- **后摄自动对焦**（主 README「libcamera 后摄自动对焦」一条）：
  - Ubuntu 26.04 的 libcamera 0.7.0-1ubuntu2 没有任何对焦代码。后摄 s5kjns 配了 VCM 镜头，镜头驱动是 dw9719（同时驱 GT9764），但在 libcamera 里镜头一直不动。
  - mzakamin-hub/iceland-mainline `990a0597` 的 `packaging/libcamera/` 有 4 个补丁，给 simple pipeline 加上了反差式对焦，是对 0.7.1 写的。
  - 主 README 给这件事列了三个前提：
    1. 0002 要手工移植到 0.7.0；
    2. 必须自己补「停流后镜头归位」；
    3. 第一次锁焦和后摄约 3 s 的自动曝光收敛重叠，要专门看锁得对不对。
  - 主 README 还写了：**受益面很窄**（前摄没有 VCM，只有用后摄拍近物时才用得上），先问作者用不用。到 10-28 为止，作者还没表态，所以装之前要先问。
- **镜头 VCM 漏电**（主 README「待验证」那条疑点）：
  - 疑点是 libcamera 打开镜头子设备后就不关，PipeWire 又常驻，于是 VCM 和 l6b（2.8 V）一直上电。
  - 查下来这个漏电**在 Ubuntu 原版 libcamera 上就存在**，和对焦补丁无关。根因见下一节。
  - 补丁 0005 修它；同时它也满足了上面的前提 2。

## 根因：镜头子设备被常驻进程一直打开着

- **内核 dw9719 驱动**（主线 `drivers/media/i2c/dw9719.c`，加上 GT9764 的 vio 电源补丁，见 `linux/kernel-y8/inventory/upstream-patches` 的 0047）：
  - 子设备节点一 `open` 就 `pm_runtime_resume_and_get`，给 VCM 上电（vdd 接的是 `vreg_l6b_2p8`，vio 接的是 `vreg_l10b_1p8`，0047 先开 vio 再开 vdd），然后把镜头每次走 16 步、每步间隔 1 ms，慢慢移到当前控件值。
  - 最后一个 `close` 时 `pm_runtime_put_autosuspend`。autosuspend 延迟 1 s，之后的 runtime suspend 把镜头同样一步 16 地降到 0，发 SHUTDOWN，再关稳压器。
  - 也就是说：**节点开着，VCM 就上电；节点关掉 1 s 左右，镜头自己归零、断电**。
- **libcamera 0.7.0**：
  - `CameraSensorLegacy`/`CameraSensorRaw::discoverAncillaryDevices()` 给每个带镜头的传感器建一个 `CameraLens`，并调用 `init()`。
  - 原版 `CameraLens::init()` 打开子设备之后一直不关，直到整个 `CameraManager` 销毁才关。这一点与 pipeline handler 无关，任何 pipeline 都一样。
- **桌面会话**：PipeWire 的 libcamera SPA 插件和 WirePlumber 的 libcamera monitor 各持有一个 `CameraManager`，整个会话期间都在。
  - 结果：后摄镜头节点从登录起就被打开着，dw9719 一直 runtime active，l6b 和 l10b 一直开着。熄屏也是如此。
  - 原版不动镜头，所以镜头停在位置 0；VCM 驱动的码值就是线圈电流，位置 0 时线圈不吃电，吃电的是驱动芯片和 LDO。
  - 加上对焦补丁 0001–0004 但不带 0005 时更糟：镜头会**停在最后一次对焦的位置，带着线圈电流挂一整个会话**。这正是主 README 前提 2 担心的情况。
- **仓库里已有的证据**：`linux/power/cx-collapse/runs/cx-audit-0324-y10-screen-off.txt:438-440`。这是 10-16 03:25 的记录，熄屏、开机 430 s，y10 内核。
  - 当时 `regulator_summary` 里 `vreg_l6b_2p8` 的 use 是 1；它的两个用户中，`5-000c-vdd`（镜头）为 1，`5-0056-afvdd`（传感器）为 0。
  - 也就是熄屏时镜头的 vdd 开着。表里的 `0mA` 是负载请求，不是实测电流。**这一项耗多少电没有测过**。
- **l6b 只有这两个用户，都属于后摄**：传感器的 afvdd 只在后摄出流时打开。所以「后摄闲着时 l6b 应当是关的」可以直接拿来当判据，检查脚本 a 项就是这么判的。
- **l10b（1.8 V）也被镜头拉着**，这一点 10-29 熄屏功耗测完后才补核：
  - 它的用户是 `5-000c-vio`（镜头）、`5-0056-vddio`（后摄）、`8-0031-dovdd`（前摄）。两个传感器只在出流时开。
  - 10-29 在 y15 上用 regulator sysfs 实看（不是 debugfs）：拿着镜头节点时 l6b、l10b 都 enabled、users 1；放开后两路一起关。
  - 两路由同一次 runtime resume/suspend 成对开关，所以检查脚本只判 l6b 就够了。

## 设计

- **补丁做法与 Ubuntu 打包一致**：
  - 在 Ubuntu 的源码包上加 5 个 quilt 补丁，版本号 `0.7.0-1ubuntu2+y700.1`。
  - 在平板上用 `dpkg-buildpackage` 编出 7 个 .deb，用 `dpkg -i` 装，再 `apt-mark hold`。
  - 不用 /usr/local 另装一份：PipeWire、GStreamer、`cam` 都按包依赖找 `libcamera0.7`，替换包是唯一不改它们的办法。
- **版本号为什么要 hold**：按 dpkg 的版本比较，`0.7.0-1ubuntu2+y700.1` 高于 `0.7.0-1ubuntu2`，但低于 Ubuntu 以后的任何更新（`0.7.0-1ubuntu2.1`、`0.7.0-1ubuntu3`，`+` 排在 `.` 前面）。
  - 不 hold 的话，下一次 `apt upgrade` 就会把原版装回来，对焦没了，漏电也回来了。
  - 代价是 Ubuntu 的 libcamera 安全更新也会被挡住，见「周期性义务」。
- **补丁 0005 的思路**：镜头节点只在出流期间打开。
  - `init()` 读完控件后就关上节点。
  - simple pipeline 在 `start()` 里、streamon 之前打开节点，在 `stopDevice()` 的最后关上。
  - 归位和断电交给 dw9719 自己的 runtime suspend，用户态不写归位值。

## 文件

| 位置 | 是什么 |
|---|---|
| `patches/y700-0001-simple-manual-focus-control.patch` | iceland 0001（作者 Osilvfe，本身是 `2f4cf4a4` 的 cherry-pick）。<br>在 simple pipeline 加 draft 控件 `FocusAbsolute`，单位是执行器的原生码值（这些模组没有屈光度标定，没法用 `LensPosition`），请求里带上它就移动镜头。<br>只为 fuzz 0 重生成了上下文，加进来的代码没改 |
| `patches/y700-0002-softisp-gradient-focus-metric.patch` | iceland 0002（`9afba3cd`）。<br>CPU 统计累加每条统计行上相邻亮度采样的差的绝对值（`SwIspStats` 新增 `focusSum`、`focusSamples` 两个字段），soft IPA 把它作为 `FocusFoM` 元数据报出来。<br>**手工移植**：0.7.1 的统计按工作线程各算一份，最后在 `finishFrame()` 里合并；0.7.0 只有一个 `SwStatsCpu::stats_`。所以行宏直接写 `stats_`，`startFrame()` 清零两个新字段，`finishFrame()` 那段删掉。指标本身没改。<br>这个补丁改变了 `SwIspStats` 的内存布局，所以 `libcamera0.7` 和 `libcamera-ipa` 必须来自同一次构建 |
| `patches/y700-0003-simple-contrast-detect-autofocus.patch` | iceland 0003（`1b79c817`）。<br>加上 `AfMode`（手动、自动、连续）、`AfTrigger`、`AfState`：先把镜头行程分十步粗扫，再在最好的那一步附近细扫，依据是 `FocusFoM`。<br>连续模式下，`FocusFoM` 连续三次低于锁定值的 65% 就重扫。只重生成了上下文 |
| `patches/y700-0004-simple-autofocus-defaults-settling.patch` | iceland 0004（作者 mzak，`aa2be227`）。写给经 PipeWire 或 GStreamer 用相机、不会去设 `AfMode` 的应用：<br>· 有镜头时默认连续对焦（`LIBCAMERA_SIMPLE_AF_MODE=manual\|auto\|continuous` 可改）；<br>· 每次 `start()` 后的第一个请求就开始扫；<br>· 镜头移动后至少隔两帧才用新的 `FocusFoM`；<br>· `LIBCAMERA_SIMPLE_AF_RANGE=<min>-<max>` 把扫描范围收窄到模组的标定范围；<br>· soft IPA 把 `FocusFoM` 除以平均亮度，单纯的曝光变化不会触发重扫。<br>0.7.0 里 `soft_simple.cpp` 的上下文不同（`auto const &algo`），所以重生成了上下文 |
| `patches/y700-0005-lens-open-only-while-streaming.patch` | 我们自己写的，修漏电（根因见上）。<br>`CameraLens`：<br>· `init()` 验完驱动、记下型号和控件后关上节点。这个实例以后不再打开，只用来提供 `controls()`，所以 `ControlId` 指针一直有效；<br>· 新增 `open()`、`close()`、`isOpen()`，`open()` 另开一个新的 `V4L2Subdevice` 实例；<br>· `setFocusPosition()` 在节点没开时自己打开。<br>simple pipeline：<br>· `start()` 在 streamon 前打开节点，失败只记 Warning，照常出流，AF 报 Failed；<br>· `stopDevice()` 在 soft ISP 停下、送完积压的元数据之后，最后才关节点；<br>· `moveFocus()` 遇到节点没开时拒绝移动，不在 `start()` 到 `stop()` 之外把节点重新打开；<br>· 镜头出错不再让整个请求失败（`handleFocusControls()` 改成 void），帧照出，`AfState` 报失败；<br>· `resetAutoFocus()` 同时清 `afCurrentFrame_` 和 `afMoveFrame_`（修 0004 的一个 bug，见踩坑三）；<br>· `updateAutoFocus()` 在没有镜头时直接返回，和 `handleFocusControls()` 一样（**偏离 iceland**，修 0003/0004 的一个 bug，见踩坑八） |
| `libcamera-af-build.sh` | 平板 `/root/`，root，用 systemd-run 在后台低优先级跑。下载并校验源码包（三个 sha256 写死在脚本里），解包，加补丁和 changelog，`dpkg-source --before-build` 按 fuzz 0 打补丁，`apt-get build-dep`，`dpkg-buildpackage -B`，最后在新 .so 里找 0001 和 0005 各自独有的字符串。**它不装、也不碰已装的 libcamera**。步骤、为什么不用 build profile、产物，都写在脚本头注释里 |
| `libcamera-af-install.sh` | 平板 `/root/`，root。三个模式：<br>· `--install`：先备份 Ubuntu 原版 .deb，再 `dpkg -i`，再 hold；<br>· `--rollback`：unhold，装回原版；<br>· `--status`：只读，看版本、hold、哪些进程映射着哪个 libcamera，以及镜头节点被谁打开着、runtime PM 状态、l6b 状态。<br>`--restart-wireplumber` 让它最后重启 user 的 pipewire、pipewire-pulse、wireplumber，**声音会断一下，正在用的相机流会断**；不加就不重启，常驻进程继续用旧库，漏电要等它们重启才消失。细节见脚本头 |
| `libcamera-af-check.sh` | 平板 `/root/`，root，只读（`cam` 以 user 身份跑）。检查五项，每项给 PASS/FAIL，最后一行是 `RESULT:`：<br>a 空闲时镜头 suspended、没人打开节点、l6b 关；<br>b 后摄 `cam --metadata`：锁焦、镜头动过、出流时上电、退出后 ≤3 s 断电；<br>c 前摄：c1 出流且不带 AF 元数据（踩坑八）；c2 从前摄第一帧之后 1.5 s 起到结束，后摄镜头一直 suspended，证明 `init()` 关了节点；<br>b、c、e 都按 `CHECK_SIZE`（默认 1280x720）出流，不用全尺寸，免得 CPU ISP 太慢、超时误判；<br>d （装了 python3-numpy 时）扫描时与锁焦后的清晰度对比，只报 INFO；<br>e （`--pipewire`）经 PipeWire 出一次后摄流，客户端走后 15 s 内镜头 suspended，而 pipewire 还在跑。这正是漏电的实际场景。<br>原始输出和 0.1 s 采样留在 `/tmp/libcamera-af-check-<时间>/`。**用前先关掉所有相机应用** |
| `lens-power-ab.sh` | 熄屏功耗对比（10-29）。平板 `/root/`，root，**电池、熄屏**，用 `systemd-run --unit y700-lensab` 跑，测量期间没人 ssh。同一次开机里交替测两种状态：<br>· A：镜头不动。修好以后就是这样：节点没人开，镜头 suspended，l6b 关；<br>· B：脚本自己把镜头节点开着，对焦控件为 0。这就是修之前原版 libcamera 的样子：驱动芯片和 LDO 通电，线圈不吃电流。<br>每对按 A B、B A 交替（ABBA，抵消线性漂移）。每个窗口切换后等 30 s，再用 `y700-powersample` 采 120 s；采样前后都核对镜头和 l6b 是不是该有的状态，B 还要对焦控件是 0。<br>熄屏、10 分钟没碰才开始。作者一碰（触摸、电源键、音量键、亮屏、后摄出流、插电），这一对作废，镜头立刻回 A，等下一个空闲窗口重做。<br>**不在 cx-auto 的 BENCHES 名单里**：cx-auto 照常开着 E3a，测的就是每天熄屏时的状态。<br>日志 `/var/log/y700-lensab.txt`，状态页 8766 会显示最后几行；原始数据 `/var/log/y700-lensab-raw.tsv`，只收完整的对。<br>**已知毛病**（10-29 夜里暴露，脚本没改，修法见「踩坑」十）：<br>· 零读数作废和作者打断用同一个返回码，作废一次就白等 10 分钟；<br>· 作废窗口的逐秒数据不落盘；<br>· `ok_state` 只核 l6b，不核 l10b；<br>· SUMMARY 行的区间是 ±2·se，不是 t 区间 |
| `lens-power-ab-report.py` | Win11 上跑，只用标准库：`tools/venv/Scripts/python -X utf8 -I -B lens-power-ab-report.py <raw.tsv> [<log>]`。算的是：<br>· 每对 B−A 的均值，带 t 区间和 bootstrap 区间；中位数；<br>· 去掉离群对（5 MAD 以外）之后的结果；<br>· 先后顺序效应，前后两半各自的均值；<br>· 两臂的 CPU 忙、中断、AOSS/CX 睡眠是否一致。<br>用合成数据测过。10-29 测完后按复核意见加了：<br>· 单侧 95 % 上界；<br>· 零读数三种口径（剔除、按地板、按 0）下的 B−A；<br>· 两臂零读数个数；<br>· 日志里两臂作废窗口数和空闲等待次数。<br>在当夜数据（数字和复核一致）、不带日志、只有两对这几种情况下跑过 |
| `README.md` | 本文件 |

平板上的目录 `/root/libcamera-y700/`（build 脚本建）：

- `patches/`：从仓库 scp 过去的 5 个补丁；
- 三个下载件，以及解开的源码树 `libcamera-0.7.0/`。源码树每次重编都整个重解，里面没有手改的东西；
- 7 个 .deb 和 `-dbgsym` .ddeb；
- `build-<时间>.log`；
- `builddeps-installed.txt`：为编译新装了哪些包，卸载时用；
- `orig-0.7.0-1ubuntu2/`：install 备份的 Ubuntu 原版 .deb，回滚用，**别删**；
- `install-state.txt`：第一次安装前各包的版本。

## 用法（平板上，按顺序）

Win11 的 Git Bash 里，在仓库根目录 `C:/Users/me/AI/y700` 下（下发的做法：scp 后比 sha256）：

```
ssh -i ~/.ssh/y700_ed25519 root@100.64.0.10 mkdir -p /root/libcamera-y700/patches
scp -i ~/.ssh/y700_ed25519 linux/camera/patches/y700-000*.patch root@100.64.0.10:/root/libcamera-y700/patches/
scp -i ~/.ssh/y700_ed25519 linux/camera/libcamera-af-{build,install,check}.sh root@100.64.0.10:/root/
sha256sum linux/camera/patches/y700-000*.patch linux/camera/libcamera-af-*.sh
ssh -i ~/.ssh/y700_ed25519 root@100.64.0.10 'sha256sum /root/libcamera-y700/patches/y700-000*.patch /root/libcamera-af-*.sh'
```

平板上（root）：

1. 基线：`bash /root/libcamera-af-check.sh --pipewire`。
   - 原版上预期 FAIL：a 和 b4（pipewire/wireplumber 打开着镜头节点，l6b 一直开着，这就是漏电）、b1 和 b2（没有 AF 元数据）、c2、e。
   - e 要 GStreamer 的 `pipewiresrc`（包 `gstreamer1.0-pipewire`）。平板上原来没有这个包，所以基线里 e 是 SKIP；验收前先 `apt-get install --no-install-recommends gstreamer1.0-pipewire`（Ubuntu 官方包，只是测试用）。10-29 验收前装了（1.6.2-1ubuntu1.2），现在还在，卸载见「回滚」。
   - 如果 a 是 PASS，说明漏电在当前内核上不成立，回头看「根因」那一节。
   - 结果先记下来。
2. 编译：`systemd-run --unit=y700-libcamera-build --collect -p Nice=19 -p CPUWeight=20 -p IOWeight=20 /bin/bash /root/libcamera-af-build.sh`（写明 `/bin/bash`，不依赖 scp 保留执行位），用 `journalctl -fu y700-libcamera-build` 看进度。
   - 成功时结尾有 `OK: libcamera 0.7.0-1ubuntu2+y700.1 built …`、.deb 清单和 `next:` 一行；失败时有 `FAILED` 和出错的阶段，已装的 libcamera 不受影响。
   - 要求至少 4 GB 空闲磁盘；并行数按每 1.5 GB 可用内存一个 job 封顶。耗时没测过。
3. **先问作者用不用对焦、现在方不方便断一下声音**，再安装：`bash /root/libcamera-af-install.sh --install --restart-wireplumber`。
4. 验收：`bash /root/libcamera-af-check.sh --pipewire`。
   - 要求 a、b1–b4、c1–c2、e 全 PASS。
   - d 是 INFO：把后摄对着 20–50 cm 外有细节的东西，看锁焦后的清晰度是否明显高于扫描时（主 README 前提 3）。
5. 作者在真机上实拍一次近物（合成测试不算数）。
   - 平板上没有单独的相机应用。作者用摄像头是在 Chrome 里：启动参数带 `--enable-features=WebRtcPipeWireCamera`，摄像头经 PipeWire 走 libcamera。
   - 做法：在 Chrome 里打开一个用摄像头的网页，在摄像头选项里选后摄，对着 20–50 cm 外有字的东西，看几秒内能不能对清。
6. 熄屏功耗：`systemd-run --unit y700-lensab --collect /root/lens-power-ab.sh --idle 10 --until 09:30`，测量期间不 ssh，用 `curl http://100.64.0.10:8766/` 看进度。
   - 结束后把 `/var/log/y700-lensab.txt` 和 `/var/log/y700-lensab-raw.tsv` 拷回 `runs/camera/`，用 `lens-power-ab-report.py` 算。
   - 不用卸补丁：B 臂在电气上就是修之前的状态。差值预计只有几 mW，比单个窗口约 20 mW 的波动小得多，要靠很多对平均。
   - 10-29 已经测过一夜，结论见「验证状态」。**不用再测**（见「有意不做」）。要复用这个台架去测别的 A/B，先按「踩坑」十把脚本改了，再试跑一次。

## 回滚

- `bash /root/libcamera-af-install.sh --rollback --restart-wireplumber`：先 unhold，再装回 `orig-0.7.0-1ubuntu2/` 里的原版。
  - 备份不在时它会重新下载，但只有 Ubuntu 仓库里还有这个版本才下得到。
  - 第一次安装前就没装的包（见 `install-state.txt`）会留在 Ubuntu 版本，回滚时打印出来，要删就手动 `apt-get purge`。
- 编译依赖：先 `apt-get purge --simulate $(cat /root/libcamera-y700/builddeps-installed.txt)` 看会连带删掉什么，确认后去掉 `--simulate` 执行，再 `apt-get autoremove --purge`。
- 回滚之后漏电也回来了（原版的行为）。
- 验收用的 `gstreamer1.0-pipewire`（10-29 装的）不是编译依赖，不在 `builddeps-installed.txt` 里，回滚 libcamera 也不会动它。不要了就 `apt-get purge gstreamer1.0-pipewire`；删了以后检查项 e 会 SKIP。
- `--rollback` 还没在平板上真跑过。它依赖的 `ver()` 在 10-29 修好之前，会把 hold 着的包当成没装（踩坑九）；修好后 `--status` 已经能正确列出版本和 hold。

## 有意不做的事及原因

- **ipu3、Raspberry Pi 两个 pipeline 不改成停流关节点**：它们从不调 `open()`/`close()`，靠 `setFocusPosition()` 在第一次对焦时打开，之后一直开着（但不再是从 `CameraManager` 启动就开着）。Raspberry Pi 的 IPA 只在第一次 `start` 时发默认镜头位置；如果停流时关了节点，镜头会归零，而 IPA 仍以为它在默认位置。本机两者都用不上。
- **不按自动曝光收敛来推迟第一次扫描**（主 README 前提 3）：0.7.0 的 soft AGC 没有 `AeState` 之类的收敛信号可等。固定延迟多少帧只能拍脑袋定。0004 的「`FocusFoM` 除以平均亮度」已经削弱了曝光变化的影响。先用检查脚本 d 项和作者实拍看锁得对不对，真不对再加。
- **不绕 dw9719 的两个小毛病**：
  - resume 时恢复位置的循环条件是 `pos < val`，所以镜头停在 `val - 16`，差一步。
  - V4L2 核心遇到和当前值相同的控件值不调 `s_ctrl`。
  - 两者叠加的后果：重新出流后，手动模式第一次设回原来那个 `FocusAbsolute` 值时，镜头差 16 码。对焦扫描总会写不同的值，不受影响。要修得改内核（循环条件改成 `pos <= val`，一行），可以等编 y15 时搭车，不值得为它单独编内核。
- **用户态不写归位值**：dw9719 的 runtime suspend 自己会把镜头一步 16 降到 0 再断电。用户态再写 0 是多余的，还会把控件值改成 0。
- **`CameraManager` 启动时还是会短暂打开一次镜头**：`init()` 要打开节点才能验驱动、读控件，所以 `cam -l`、WirePlumber 启动、pipewire 重启时，VCM 会上电约 1 s（autosuspend 延迟）再断。次数很少，躲不开。
- **镜头打开失败不重试**：只记 Warning，帧照出，AF 报 Failed。重试会把出流拖慢，而失败多半是驱动或硬件出了问题，重试也没用。
- **只出 raw 流时没有对焦**：没有 soft ISP 就没有统计。相机应用都要处理过的格式，不为这种情况做什么。
- **不标定 `LIBCAMERA_SIMPLE_AF_RANGE`**：没有模组数据，默认扫驱动给的控件全程（dw9719 是 0–1023）。如果实测发现两端从来锁不到，可以再收窄扫描范围，加快锁焦。
- **`libcamera-dev`、`python3-libcamera` 只在已经装着时才一起换**：`libcamera-dev` 精确依赖同版本的 `libcamera0.7`，装着又不换就会挡住升级；平板上没有东西需要这两个包。
- **不用 `DEB_BUILD_PROFILES`**：原因写在 build 脚本头。`debian/rules` 无条件打开 pycamera、qcam、gstreamer、test，那几个 profile 只去掉 Build-Depends；nocheck profile 还会去掉 lc-compliance 需要的 libgtest-dev。
- **不报上游**（`Forwarded: no`；补丁随本仓库公开，但没有提交给 libcamera）：0005 的思路对上游也成立（任何常驻 `CameraManager` 的进程都会让镜头一直上电）。但向上游提交要作者点头，而且要先在 libcamera 主线上重写（主线的 `CameraLens` 和 simple pipeline 都变了）。
- **只要省电、不要对焦的变体没做**：如果作者不要对焦，只取 0005 里 `camera_lens.{h,cpp}` 的部分，单独打在原版上就够了。原版的 simple pipeline 不碰镜头，`init()` 关掉节点之后就不会再打开。这个变体没有准备、也没验证。
- **不在 Win11 上编译**：本机没有 C++ 工具链，下载要作者同意。第一次编译就在平板上，编译错误出在 build 脚本第 4 步，已装的 libcamera 不受影响。
- **熄屏功耗对比不靠卸补丁来测「之前」**（`lens-power-ab.sh`）：
  - 回滚要重启 pipewire（断声音）、动包；而且装 libcamera 的同一晚内核也从 y14 换成了 y15、VA 驱动也换了，跨开机、跨天比较会把这些差别一起算进去。
  - B 臂复现的是同一个电气状态（节点开着、对焦 0），和 A 在同一次开机里交替测。
- **不测「镜头停在最后对焦位置、线圈带电流」那种状态**：那是只有 0001–0004 没有 0005 时才会出现的（见「根因」）。我们装的带 0005，这种状态不会出现；为了测它让线圈整夜带电流也不值得。
- **测量单元不放进 cx-auto 的 BENCHES**：放进去 cx-auto 会让出，两个旋钮关着，测到的是旋钮全关时的底噪，不是每天熄屏的状态。
- **测量脚本把对焦控件写成 0，并且留在 0**：和上面「用户态不写归位值」不矛盾。那一条说的是 libcamera 里不要多写；这里写 0，是为了让 B 臂和原版一样（原版从不动镜头，控件一直是默认的 0）。10-29 测之前控件停在 618，是对焦测试留下的。控件值本身无所谓：libcamera 每次出流都自己设位置，镜头空闲时断电。
- **不为镜头再测第二夜**（10-29 测完后定的）：
  - 按器件估算，真值约 1–4 mW。这台台架 80 % 功效下最小可检出差约 22 mW。
  - 即使改好台架、每夜约 71 对，和已有 27 对合并，1/2/3 夜的 95 % 半宽也只到 ±8/±6/±5 mW。要以 80 % 把握测出 2 mW 约需 3100 对，合 40 多夜，而且每夜平板整夜不能碰、不能 ssh。
  - 噪声里约 2/3 是窗口之间整机功耗本身的变化，外接功率计也去不掉。真要测准，只能直接测相机那几路电源。
- **不改 `lens-power-ab.sh`**：没有下一次运行的计划，改了没法在真机上验证（「验证过的改动才 commit」）。修法写在「踩坑」十，复用前先改、再试跑。报告脚本能在 Win11 上用当夜数据验证，所以改了。
- **不去核实「A 臂 CCI 引脚倒灌」的假说**（见「验证状态」）：
  - 要看 CCI 当前处在哪个 pinctrl 状态，得读 `/sys/kernel/debug/pinctrl/pinctrl-handles`。那是 pinctrl 核心的软件记账，不是寄存器，但毕竟是 debugfs，和「别读寄存器 debugfs」的规矩挨得近。
  - 这一项最多几 mW，核实了也改变不了结论。要做由作者定。

## 周期性义务（checklist）

hold 让 libcamera 停在我们的版本，Ubuntu 的更新**进不来，也不会报错**，所以要人记着：

- [ ] **每次看系统升级时**：`apt-cache policy libcamera0.7`。
  - Candidate 高于 `0.7.0-1ubuntu2` 时，说明 Ubuntu 出了新版，被 hold 挡住了（`apt-get -s upgrade` 不会升级它）。
  - **安全更新**（Ubuntu 的 USN 里有 libcamera）优先级最高。来不及重编时，宁可 `--rollback` 让 Ubuntu 的版本进来，代价是对焦没了、漏电回来。
- [ ] **有新版时重编**：
  1. 先看上游有没有替我们做掉：libcamera 主线是否已经给 simple pipeline 加了对焦，是否也修了镜头节点常开；iceland-mainline 的补丁有没有更新。
  2. 在平板上 `dpkg-source -x` 新的源码包，把 5 个补丁按顺序重新对上。0002 最容易冲突，因为它碰的是统计结构。**平板上没装 quilt**（build-dep 也不会带上它），build 脚本只靠 `dpkg-source`。两条路选一条：
     - 用 quilt：先 `apt-get install --no-install-recommends quilt`（用完 `apt-get purge quilt`），在解开的源码树里 `export QUILT_PATCHES=debian/patches QUILT_REFRESH_ARGS="-p ab --no-timestamps --no-index"`，然后**一个一个来**：`quilt import <补丁>` 紧接着 `quilt push`，再 import 下一个（一次 import 多个时，每个都插在当前顶端补丁后面，顺序会乱）。push 失败时 `quilt push -f`，照 `.rej` 手工改，再 `quilt refresh`；push 成功但输出里有 fuzz 或 offset 也要 `quilt refresh`，因为 dpkg-source 打补丁是 `-F 0`。refresh 会保留 DEP-3 头。
     - 不用 quilt：在解开的源码树里 `git init -q && git add -A && git commit -qm base`（root 没配 git 身份时给 `git` 加 `-c user.name=y700 -c user.email=y700@localhost`），然后按顺序对每个补丁 `patch -p1 -F 0 --dry-run < 补丁`，能打就去掉 `--dry-run` 打上，再 `git add -A && git commit -qm 000N`；打不上就去掉 `-F 0` 打，照 `.rej` 手工改完再提交。最后每个补丁 = 原补丁 `---` 那一行以上的 DEP-3 头 + `---` + `git diff <上一个提交> <这个提交>`。Win11 上准备这 5 个补丁时就是这么做的。
     - 无论哪条路，最后都要在一份新解开的树上用 `patch -t -F 0 -N -p1` 依次打一遍，全部不报 fuzz 才算数。
  3. 拷回仓库，改 build 脚本的 `UP`/`VER`、三个 sha256，以及 install 脚本的 `VER`。
  4. 按「用法」从第 2 步重来，同时备份新的原版 .deb。
  5. 如果 Ubuntu 的 SONAME 变了（出现 `libcamera0.8` 之类的新包名），整套脚本的包名都要改，旧的 hold 可能还会挡住 pipewire 的升级。
- [ ] **换内核后**：dw9719 驱动的 runtime PM 改了的话（open 不再上电、suspend 不再降位），重跑 `libcamera-af-check.sh --pipewire`。
- [x] **测熄屏功耗时**：顺带记下镜头的 runtime_status 和 l6b。`lens-power-ab.sh` 每个窗口采样前后都记，写在日志里。
- [x] **体检自动查**（10-29 做了：`tools/y700-checklist.py` 的 `check_libcamera`，自测 S30a–m，装上平板实跑报 OK）。作者自用的每日定时任务会跑它（不随附），有 WARN 才通知。原来列的三项都做了，另加了「没 hold」和「apt 列表太旧」两项：
    1. 装的 `libcamera0.7` 版本以 `+y700.N` 结尾，且 `libcamera.so.0.7.*` 里有 `Failed to open the focus lens`（0005 独有的字符串）；
    2. Candidate 比装的版本新时 WARN；
    3. 没有相机在用时 `/sys/bus/i2c/devices/5-000c/power/runtime_status` 应为 `suspended`。「没在用」看的是后摄传感器 `5-0056` 的 runtime_status 不是 active。
  - 所以「每次看系统升级时」那一项现在由体检代劳。但它只看得到 apt 列表里有的东西，平板的 apt 列表不会自己刷新（主 README 体检一节），列表超过 30 天体检会报。
  - 主 README 的两条（对焦、待验证）已经指向本文件。

## 踩坑

1. **0002 不能直接打**：0.7.1 的 soft ISP 统计按工作线程各算一份，0.7.0 是单个 `stats_`。不是上下文的问题，是结构不同，只能手工移植（见文件表）。
2. **dpkg-source 要求 fuzz 0**：
   - 3.0 (quilt) 格式的打补丁选项是 `patch -F 0`。
   - 0004 在 0.7.0 上只能以 fuzz 1 打上，dpkg-source 会直接拒绝。
   - 所以 0001、0003、0004 都在 0.7.0-1ubuntu2 上重新生成了上下文。
3. **0004 自己有个 bug**：
   - `afCurrentFrame_`、`afMoveFrame_` 跨 `start()` 保留，而请求序号每次 `start()` 都从 0 开始。
   - 结果是第二次打开相机后，第一次扫描要等到序号超过上一次留下的值才开始，等的帧数和上一次出流一样多。
   - 0005 在 `resetAutoFocus()` 里把两者清零。
4. **`libcamera0.7` 和 `libcamera-ipa` 必须同一次构建**：
   - IPA 模块用每次构建新生成的私钥签名，公钥编进 `libcamera0.7`。
   - 0002 还改了两者共用的统计结构。
   - install 脚本一次 `dpkg -i` 全装。
5. **`cam` 跑完镜头断电，证明不了 0005**：进程一退出，内核就会关掉它的所有 fd，用原版也一样（检查项 b4）。能证明的是常驻进程：检查项 c2（同一个 `CameraManager` 枚举了后摄但没开流）和 e（pipewire）。
6. **换了 .so，常驻进程还在用旧库**：pipewire、wireplumber 映射的是已删除的旧文件（`--status` 里标 `OLD`），漏电要等它们重启才消失。所以有 `--restart-wireplumber`；不加的话，要等下次登录或重启。
7. **Win11 上的 git 默认改行尾**：准备补丁时，clone 必须用 `core.autocrlf=false`，否则补丁和对比全带 CR。仓库里的文件都是 LF、无 BOM，下发前不要在远端跑 `sed` 去 CR。
8. **iceland 的补丁让没镜头的相机也报 AF 元数据**（10-29 评审发现）：
   - `handleFocusControls()` 开头有 `if (!focusLens_) return;`，但 0003 加、0004 改的 `updateAutoFocus()` 没有。soft ISP 每出一帧，`metadataReady()` 都无条件调它，它再调 `writeFocusMetadata()`。
   - 结果：前摄（gc08a8，定焦）不在控件表里声明 `AfMode`/`AfState`，每个请求的元数据里却带着 `AfMode`、`AfState`、`FocusAbsolute`，应用会以为它能对焦。检查项 c1 判的就是这个。
   - 0005 在 `updateAutoFocus()` 开头补了同样的判断。0001–0004 保持 iceland 原样，不在那里改，这样和原补丁逐行对比时还是「完全相同」。
9. **被 hold 的包，dpkg 状态是 `hold ok installed`，不是 `install ok installed`**（10-29 第一次 `--install` 踩到）：
   - Status 的第一个词是 want 字段，hold 就记在那里。install 脚本的 `ver()` 原来只认 `install ok installed`，其余一律当没装（`none`）。
   - 脚本是先 `apt-mark hold` 再核对版本，于是自己刚 hold 上的包全被判成 none，报 `gstreamer1.0-libcamera is none after dpkg -i` 并 FAILED（`runs/camera/libcamera-af-install-20261029-0149.log`）。
   - 那次 `dpkg -i` 和 hold 其实都做完了，只是停在重启 pipewire 之前：pipewire、wireplumber 还映射着旧库，漏电还在。`install-state.txt` 记的是装之前的原版版本，没被弄乱。
   - 同一个 bug 还会让 `--rollback` 跳过所有 hold 着的包，报「nothing to roll back」后正常退出，等于回滚悄悄什么都没做；`--status` 也会把它们显示成 none。
   - 修法：`ver()` 也认 `hold ok installed`。修好后重跑 `--install --restart-wireplumber`，OK（`…-015022.log`）。重跑会把同一批 .deb 再 `dpkg -i` 一遍，无害。
10. **电量计零读数把一夜的有效对数砍掉了一大半**（10-29 夜，`lens-power-ab.sh`）：
    - 现象：80 个尝试窗口里有 17 个因零读数超过 12 个（SECS/10）被作废，A 11 个、B 6 个，Fisher p=0.28。每次作废后又白等 10 分钟空闲，最后只得到 27 对（预期约 60–70）。
      - 03:16–09:25 共 368 min：有效的对 136 min；空闲等待 167 min；作废的窗口 43 min；随整对一起扔掉的、本来有效的首窗 23 min。
      - 测量期间没有检测到任何输入：16 次作废后的等待都是 602–604 s，是最短可能值。
    - 根因：
      - `window()` 零读数作废时 `return 1`，和「被打断」是同一个返回码。主循环见非 0 就置 `fresh=1`，下一轮 `wait_idle` 从头计 10 分钟。
      - 可零读数检查排在 quiet、状态、对焦、放电检查之后，这些当时都已经过了。
    - 修法（脚本没改，见「有意不做」）：
      - 零读数作废单独返回 4。主循环见 4 不置 fresh，同一个 k 按原顺序立即重测；连续 6 对都这样时，退回等 10 分钟。
      - 每个窗口的逐秒数据都写进 raw，作废的也写，加一列状态。这一夜作废窗口的数据全丢了，选择偏差只能靠假设去估（见「验证状态」）。
      - `ok_state` 加上 l10b；SUMMARY 改用 t 分位。
      - 阈值要不要从 12 放宽到 30，要另议。零读数挨着最低电流那一档，不像随机丢读：63 个合格窗口里，含零读数的窗口剔零均值比不含的低约 19 mW（219.4 对 238.6，se 6.7）。放宽阈值等于把作废带来的选择偏差，换成窗口内的剔零偏差。所以放宽前要先定好零读数口径，并且剔零、按地板计两种结果都报。
      - 按当夜的零读数序列回放（模拟）：只改返回码约 50 对/夜，再放宽阈值约 71 对/夜。零读数是成串出现的，立即重测时实际收益可能更少。
    - 零读数是什么，还没有定论：
      - 几乎都是整块的电量计更新：18 段 5 s、6 段 6 s、5 段 10 s，电量计约 5.2 s 更新一次；另有一段 2 s、一段 3 s，都在窗口第 0 秒。打印出来都是 `-0.0`，也就是 current 读数为 0，或者读 current 失败（powersample 读失败时默认 0）。也不是 1 s 超时：零读数多的窗口样本数不少。
      - 10-18 的几次测量一个零读数都没有。但那是飞行记录器，每 ≥4.5 s 才读一次；powersample 每秒读一次，往电量计跑的次数多 5 倍。
      - 下一版台架可以改成每 5 s 读一次：电量计本来约 5.2 s 才更新，这样不丢信息，也许还能顺带避开零读数。这一点没试过。

## 验证状态（2026-10-28，10-29 按评审修改后重验；10-29 01:4x 平板上跑了基线、编好了包；01:50 装上，验收 PASS）

**10-29 平板上做了的**（内核 y15 `7.3.0-tb323fu-t52-y15`；补丁和三个脚本 scp 过去后两边 sha256 一致）：

- **基线**（原版 0.7.0-1ubuntu2，`runs/camera/libcamera-af-check-baseline-20261029-0143.log`）：和预期一样。
  - FAIL：a（镜头 runtime active，节点被 pipewire、wireplumber 开着，`vreg_l6b_2p8` 开着）、b1 和 b2（没有任何 AF 元数据）、b4（cam 退出 5 s 后还是 active，同样被那两个进程开着）、c2（前摄出流期间后摄镜头 27/27 个采样都是 active）。
  - PASS：b3（出流时 42/42 个采样上电）、c1（前摄 150 帧，没有 AF 元数据）。
  - e SKIP：平板上没有 `gstreamer1.0-pipewire`（见「用法」第 1 步）。
  - 也就是说，漏电在 y15 上照样成立，根因那一节的判断对。
- **编译**（`systemd-run --unit=y700-libcamera-build`，日志 `/root/libcamera-y700/build-20261029-014423.log`）：01:44 开始，01:47 结束，**OK**。
  - 三个下载件的 sha256 都对上；`.dsc` 的 PGP 签名没验（平板上没有 Ubuntu 的 keyring，dpkg-source 只给警告，脚本头写过）。
  - 5 个补丁在 fuzz 0 下全部打上；带补丁的 `camera_lens.cpp`、`pipeline/simple/simple.cpp`、`swstats_cpu.cpp`、`soft_simple.cpp` 编译时没有任何警告。整份日志里的编译器警告只有原版代码的两条（`v4l2_videodevice.cpp` 未用参数、`cam_helper_imx500.cpp` 的 strncpy）；另有十几条 dpkg-shlibdeps 的 `diversions involved`，来自 Ubuntu 自己的 usr-merge 转移（`dpkg-divert --list`），和这次无关。
  - 新 `libcamera.so.0.7` 里找到了 0001 和 0005 各自独有的字符串。
  - 编出 7 个 .deb（加 `-dbgsym` .ddeb），在 `/root/libcamera-y700/`。
  - 为编译新装了 48 个包（`/root/libcamera-y700/builddeps-installed.txt`，卸载方法见「回滚」）。
- **安装**（作者 10-29 选了「现在装」）：01:49 第一次 `--install --restart-wireplumber` 报 FAILED，是脚本自己的 bug（踩坑九）。修好 `ver()` 后 01:50 重跑，OK（`runs/camera/libcamera-af-install-20261029-0149.log`、`…-015022.log`）。
  - 5 个包都是 `0.7.0-1ubuntu2+y700.1`，hold 住了。Ubuntu 原版 .deb 备份在 `/root/libcamera-y700/orig-0.7.0-1ubuntu2/`，装之前的版本记在 `install-state.txt`。
  - pipewire、pipewire-pulse、wireplumber 重启后（pid 53141、53142）映射的都是新库；默认音频输出还是 `effect_input.y700_lenovo`。
  - 为了跑检查项 e，另装了 Ubuntu 官方的 `gstreamer1.0-pipewire` 1.6.2-1ubuntu1.2（见「回滚」）。
- **验收**（`runs/camera/libcamera-af-check-installed-20261029-0150.log`）：**RESULT: PASS**。
  - a：空闲时镜头 1.01 s 内 suspended，没人开着节点，l6b 关了。基线里这三样都是反的，漏电没了。
  - b1：seq 68（第一帧后 2.26 s）锁焦。b2：FocusAbsolute 走了 16 个值，都在 0..1023 内，最后停在 1023。b3：出流时 42/42 个采样上电。b4：cam 退出 1.11 s 后 suspended。
  - c1：前摄 150 帧，没有 AF 元数据。c2：前摄出流期间，后摄镜头 27/27 个采样都是 suspended。
  - e：经 PipeWire 出流时镜头被 pipewire 开着；客户端走后 1.33 s 镜头 suspended，pipewire 还在跑。这正是 0005 要修的场景。
  - d 只是 INFO：锁焦后和扫描时的清晰度之比 1.00，扫描选中的位置是 1023（行程的一端）。平板当时多半平放着，后摄对着桌面或远处，比不出什么，所以前提 3 还得靠作者实拍。
  - 10-29 02:1x 再看 `--status`：镜头 suspended、没人开着，l6b disabled（num_users 0）。
- **还没做**：作者实拍（「用法」第 5 步）。
- **熄屏功耗对比（10-29 夜，已测完，结果在本条末尾）**：作者要求开始熄屏功耗测试。
  - 部署：03:06 把三个文件装上平板，两端 sha256 一致（`lens-power-ab.sh` 0bceee89…、`y700-powersample.py` 2cac6b3e…、`y700-cx-status` 266289d3…）。旧的两份备份为 `/usr/local/libexec/y700-powersample.py.bak-20261029-030611` 和 `/root/y700-cx-status.bak-20261029-030611`。
  - 03:06:18 起跑：`systemd-run --unit y700-lensab --collect /root/lens-power-ab.sh --idle 10 --until 09:30`。启动自检通过（powersample 写得出原始数据行）。状态页显示 `lensab=running` 和日志末尾。当时屏幕 03:00 起熄着，cx-auto 03:00:53 起处于开启状态（aco=Y aso=Y）。
  - 部署前在平板上做过部件冒烟测试（02:51）：
    - 持有节点时镜头 active、l6b enabled；放开后 1.28 s suspended、l6b disabled。
    - `v4l2-ctl -C/-c focus_absolute` 在这个子设备上能用。控件原来是 618，设成了 0。
    - powersample 的原始数据行格式对，不设变量时输出不变。
  - 起跑前独立复核（3 个视角、每条发现再由一个反驳者核对，不连平板）：确认 9 条，驳回 2 条，都在部署前改了。
    - **主要的一条**：每测完一对「A B」，脚本在镜头 1 s autosuspend 结束前就去检查，读到 active，于是白等 10 分钟空闲。一夜的有效对数会少将近一半。修法：每对结束后等镜头真正挂起再往下走。
    - 其余几条：
      - 启动时先空跑一次 powersample，确认写得出原始数据行；
      - B 臂读对焦控件挪到采样之后（原来只有 B 臂在采样开始前一刻跑一次 v4l2-ctl）；
      - 电量计读数恰好为 0 的样本不算进均值（和 `exp-collect.sh`、fr-slice R3 一样），超过 SECS/10 个就作废这个窗口；
      - 偶尔读不到电量时不当成「电量低」而停掉；
      - 每个窗口的最后一次轮询在采样结束后约 1 s 醒来，不再白等最多 10 s；
      - 报告里把单晚结果写成上界。
    - 驳回的一条担心夜里 man-db、apt-daily-upgrade 跑起来造成离群窗口。实际上这两个服务都带 `ConditionACPower=true`，用电池时 systemd 根本不跑。
  - **预期**：按每个窗口约 20–30 mW 的波动，一夜约 60 对，95 % 区间约 ±9 mW。镜头这部分要是只有几 mW，结果会是「最多省了多少」的上界，测不出确切数字。
  - **结果**：
    - 来源：09:24:53 到截止时间自己停。日志和原始数据拷回 `runs/camera/lensab-20261029.txt`、`lensab-20261029-raw.tsv`，两端 sha256 一致；数字用 `lens-power-ab-report.py` 算。
    - 数据量：27 对完整数据（54 个窗口，6440 个 1 Hz 样本）。A（修后）均值 232.7 mW，B（原版状态）228.7 mW。
    - **B−A = −4.0 mW**，95 % t 区间 −19.8..+11.7，bootstrap −18.7..+10.7；中位数 −11.0，B>A 13/27。
    - 各种检验都不显著：配对 t p=0.60，Wilcoxon 精确 p=0.59，符号检验 p=1.00，精确置换 p=0.60。**测不出差别**。负号在噪声里，不能读成「修完反而费电」，也不能读成「没差别」。
  - **结论按上界写**：
    - 原版状态熄屏多耗电的单侧 95 % 置信上界是 **+9.0 mW**，约占熄屏平均功耗 233 mW 的 4 %（双侧区间上端 +11.7）。
    - 差值序列有振荡的自相关（Ljung-Box p≈0.01，事后诊断）。换成 HAC 标准误，上界在 +7.3..+10.9 之间。
    - 零读数三种口径（剔除 / 按地板 117.6 mW / 按 0），B−A 是 −4.0 / −4.8 / −5.7，上界 +9.0 / +8.4 / +8.1。
    - 另一侧：数据也排除不了修复后反而略多耗，单侧下界约 −17 mW。物理上能让 B−A 变负的只有下面那个倒灌假说，最多约 4.6 mW。
  - **最弱的一环是作废规则**：
    - 被作废的 17 个窗口没有逐秒数据（踩坑十），只能按假设补回去重算：
      - 假定它们和保留的窗口一样：结论不变；
      - 按阶跃模型补：上界 +8..+11；
      - 按回归外推补（外推超出了观测范围）：不配对 B−A 从 −3.4 变成 +2..+3，上界约 14–16 mW；
      - 零读数按 0 计：上界可到 +20，但不合物理。
    - 也就是说，作废规则可能把 B−A 往负方向推了 0 到约 7 mW，方向正好会掩盖镜头的耗电。
    - 严谨的说法：上界约 9 mW；作废窗口如果确有选择偏差，约 15 mW。
  - **物理上预期只有 1–4 mW**：
    - B 臂比 A 臂多开的东西：GT9764 在 DAC=0 时的芯片静态电流；两颗 HPM 模式 LDO（l6b、l10b）的地电流；l10b 通电后两个传感器 I/O 域的少量漏电。
    - GT9764 没有公开的电流数据，只能按同类器件估。AW86017P 在 DAC=0 时 IQ 0.20 mA，双向驱动的 BU64297 ICC 1.0 mA。
    - 折到电池端，低/中/高约 +0.4/+1.9/+6.5 mW，约占熄屏功耗的 1 %。这是估算，不是测量。
    - 还有一个**符号相反的假说**（未证实）：A 臂里 l10b 断电，CCI 的 SCL/SDA 可能仍处在 default pinctrl 态，挂着 TLMM 的 2.2 kΩ 上拉（baldur-camera.dtsi）。
      - DT 定义了带下拉的 sleep 态，但 i2c-qcom-cci 似乎不会切过去。驱动源码不在仓库里，没核实。
      - 旁证：0044 说没有强上拉时 CCI 每次传输都超时；0047 说 VCM 要 l10b 通电才能用。
      - 如果倒灌存在，A 臂会多耗 0..约 4.6 mW。两项叠加，净值连符号都定不下来。
  - **台架分辨不了这么小的差**：
    - se 7.7 mW，80 % 功效下最小可检出差约 22 mW。要以 80 % 把握测出 2/5 mW，约需 3100/500 对。
    - 噪声构成：电量计约 5.2 s 才更新一次，每个窗口只有约 22 个独立读数，这种快照抽样只占配对差方差的约 1/3。其余约 2/3 是窗口之间整机功耗本身的变化。
    - 读数是双峰的：38 % 的样本 <200 mW，最低一档是 27 mA≈117.6 mW。B−A 几乎由两个窗口低功耗态占比之差决定（r=−0.90）。
    - 配对几乎没起作用：同一对 A、B 窗口均值的相关只有 +0.13。
    - 区间比预期宽，主要原因是只得到 27 对（踩坑十）；配对差的 sd 39.8，比预期隐含的约 35 只高一点。
  - **其余数据是干净的**：
    - 63 个合格窗口全在预期状态：A 是 suspended、l6b 关、users 0；B 是 active、l6b 开，33 个 B 窗口有 33 个不同的 holder。
    - 没有打断、状态错、没放电的窗口；整夜没检测到触摸、按键、亮屏或后摄出流；cx-auto 一直 armed。
    - 两臂 CPU 忙 0.63/0.64 %，中断 339/344 次每秒；cxsd/aosd 两臂都是 0 %。
    - 顺序效应 −4.7 mW（p=0.55）；14/13 的先后顺序不平衡给均值带来的偏差是 −0.17 mW；未检出漂移。
  - **没解释的描述性现象**（都是事后挑出来的，没做多重比较校正）：
    - 前 5 对全为负：均值 −22.3，其余 22 对 +0.1。但 27 对里某处出现 ≥5 个连续同号的概率约 45 %。
    - 后 14 对的离散度是前 13 对的两倍多。
    - 每个窗口前 20 s，两臂都抬高约 17 mW。多半是采样器启动和 `state()` 扫 `/proc` 落进了第一个电量计块；两臂相同，可以抵消。
    - p2 B 是唯一出现 ADSP 唤醒的窗口；去掉 p2 后 B−A 是 −3.1。
  - **l10b 补核**（09:5x，同一次开机）：台架只核了 l6b，事后另用 regulator sysfs 实看（「根因」末条）。拿着节点时两路都开，放开后两路都关，所以 B 臂复现的确实是原版状态。
  - **适用范围**：
    - 只对这些条件成立：熄屏、y15 内核、cx-auto E3a 开着、两臂都进不了 CX 塌缩和 AOSS 睡眠。
    - 哪天 CX 塌缩做通了，被拉住的两颗 HPM LDO（active-only 投票）要重新评估。
    - 亮屏时的差值没测。原版在亮屏时同样一直开着镜头。
  - **独立复核**（不连平板）：
    - 做法：4 个视角各自从原始数据重算，合成 14 条结论；再由统计、测量、物理与措辞 3 个反驳者逐条核对。
    - 结果：42 次判定里 17 次成立、25 次要求改措辞、0 次驳倒。上面的写法已按核对意见改过，比如上界不写成「最坏」、写出下界一侧、说明噪声主因、给出作废规则的偏差范围。
  - **0005 的意义**：
    - 相对原版，熄屏省电至多约 9 mW（95 %），估计 1–4 mW。
    - 更重要的是，它让对焦补丁 0001–0004 能安全使用。只装 0001–0004 而不带 0005 时，镜头会带着线圈电流停在最后一次对焦的位置，挂一整个会话。
      - 例如 10-29 对焦测试后控件停在 618。按同类器件满量程 100–130 mA 估，线圈约 60–79 mA，电池端约 0.2–0.3 W，和整个熄屏功耗同一量级。这个数没实测。
    - 原版和现在装的版本都不会进入这种状态。


**10-29 评审后改了什么**：

- 0005 补上 `updateAutoFocus()` 的无镜头判断（踩坑八），DEP-3 头写明了这处偏离 iceland。0001–0004 一个字节没变。
- 检查脚本：
  - c、e 也按 `CHECK_SIZE` 出流（c 加 `-s`，e 加 `video/x-raw,width=…,height=…` caps），超时和 b 一样放到 60 s。以前不带尺寸，走的是 pipeline 默认的全尺寸，CPU ISP 慢时会凑不够帧数、被 timeout 杀掉而误判 FAIL。全尺寸实际多少 fps 没测过。
  - c2 的判定窗口改成从前摄**第一帧出现在 cam 输出里的墙钟时刻**加 1.5 s 开始，持有者也在那一刻记。以前从启动 cam 前的时间点固定加 2.5 s，cam 启动慢时，枚举时打开又关上的后摄镜头还在 1 s 的 autosuspend 里，会误判 FAIL。cam 自己打印的时间戳是传感器时间，不能和采样的墙钟比，所以另起一个小循环盯输出文件（cam 每帧一行都会 flush）。
- README 周期性义务里重编的第 2 步：平板上没有 quilt，写了装 quilt 和不用 quilt 两条路。

**已做**（Win11 离线；工作目录在本机临时目录，不进仓库）：

- 补丁能干净打上（10-29 改完 0005 后重跑过）：
  - 基准树是 0.7.0 orig 加上 Ubuntu 的 debian/ 0.7.0-1ubuntu2，并按 `dpkg-source -x` 的做法打好了 Ubuntu 自己的 series。
  - 在这棵树上，用 dpkg-source 的 patch 选项（`-t -F 0 -N -p1 -u -V never -E`）依次打 5 个补丁：全部 clean，无 fuzz、无 offset。打完的树和移植提交逐字节一致。
  - 换成 `git apply --check` 加 `git apply` 依次打，结果相同。
- 检查脚本 c 项（第一帧监视、c1、c2 窗口）用假的 `cam` 和假的 runtime_status 文件离线跑过三种情况：打补丁后且 cam 启动慢（2.2 s）时 c1、c2 都 PASS；原版（镜头一直开到 cam 退出）时 c2 FAIL；前摄带 AF 元数据时 c1 FAIL。用的是 Git Bash 的 gawk，不是平板上的 mawk。
- 和 iceland 原补丁逐行对比：
  - 0001、0003、0004 增删的行完全相同；
  - 0002 的差异只在移植的那几处。
- 三个脚本：
  - `bash -n` 通过。
  - 检查脚本的 `cam` 输出解析器、`window()`，以及 build 脚本生成的 changelog 条目，都用合成数据离线测过。awk 用的是 `gawk --posix`，平板上是 mawk。
  - 检查脚本里嵌的两段 Python 编译通过；pw-dump 节点匹配用合成 JSON 测过。
- 文件全部是 LF、无 BOM。

**没做**：

- ~~**C++ 一行都没编译过**：本机没有工具链。第一次编译就在平板上。~~ 10-29 在平板上编过了，见上。
- ~~平板上什么都没跑过：下载、sha256 校验、`build-dep`、`dpkg-buildpackage`、安装、检查都没跑。~~ 10-29 跑了下载、校验、`build-dep`、`dpkg-buildpackage` 和基线检查，01:50 装上并验收 PASS（见上）。`--rollback` 没跑过。
  - `.dsc` 的 sha256 是从准备补丁用的那份本地副本算出来的；两个 tarball 的值取自 `.dsc`。
- ~~对焦效果、锁焦对不对（前提 3）、PipeWire 下的实际表现，都没测。~~ PipeWire 下镜头按时断电已经测过（e）。锁焦对不对（前提 3）还没测：d 项比不出来，要作者实拍。
- 漏电的证据有两条，功耗差都没测过：
  - 10-16 cx-audit 的 regulator_summary（y10 内核，见「根因」）；
  - 10-28 在 y14 内核上（`7.3.0-tb323fu-t52-y14`）读的 sysfs：`5-000c`（gt9764，dw9719 驱动）整个开机期间 runtime active，约 100,400 s active、0 s suspended，两个传感器都是 suspended；`vreg_l6b_2p8` 开着；镜头子设备被 pipewire 和 wireplumber 打开着。三者的 `autosuspend_delay_ms` 都是 1000。
  - 所以基线那一步 a 项预期 FAIL；检查脚本第一次跑是用同一套判据把这条再确认一遍。
  - 10-29 装上以后，a、c2、e 证明镜头不再一直上电；但省了多少电还是没测。

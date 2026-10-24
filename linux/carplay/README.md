# Y700 无线 CarPlay（进行中，2026-10-17 起）

> 交接文档：写给没有上下文的下一个接手者。状态以本文件的「进度」清单为准。

## 作者的要求与已做的决定

- 目标：iPhone 的**无线 CarPlay，平板装在车上当中控屏**，做成一个点开就能用的 App，不求面面俱到。
- MFi 认证：本仓库**不包含任何 MFi 认证组件或认证材料**。LIVI 需要一颗 MFi 认证协处理器（见「设计」），自己部署要用合法的 MFi 认证硬件（见末尾「认证硬件」）。下文开发记录里的「认证组件」（`/dev/i2c-99`）不随本仓库发布。
- 10-20 起同时支持无线 Android Auto：同一个桌面图标、同一个 LIVI，安卓手机走无线 Android Auto。见进度「无线 Android Auto」。

## 设计

LIVI 原样使用，另需一个 MFi 认证组件（不在本仓库）。10-23 起用 10.0.0，全是官方 AppImage 原件。之前的 9.4.0 有个例外（10-20 至 10-23）：`livi-core` 和 `livi-gst-host` 两个文件是在平板上带上游 Siri 修复自编的（见进度「Siri、地图语音听不到」「换版 LIVI 10.0.0」）。

- **LIVI**（github.com/f-io/LIVI，GPL-3.0-or-later）：现成的 Linux 车机 App，作者写明在 Ubuntu 26.04 上测过。
  - 使用官方 `LIVI-10.0.0-linux-arm64.AppImage`（10-23 起），sha256 `9ddce395…8911`；之前是 `LIVI-9.4.0-linux-arm64.AppImage`，sha256 `38849d50…f4922`。两个都与 GitHub 发布页的 digest 一致。
  - 它包办这些：全屏车机界面（10.0.0 起是 Slint 的 `livi-ui`，9.4.0 是 Electron）；后台程序 `livi-helperd`（Rust，经 sudoers 以 root 运行）；BlueZ 配对和 iAP2；自开 hostapd 热点；GStreamer 硬解；音频、麦克风、Siri。
  - 唯一缺的是 MFi 认证。它只认两种：板上 I²C 芯片（`/dev/i2c-<carPlayMfiI2cBus>`），或刷过机的 LIVI Link 加密狗。
- **MFi 认证组件（不在本仓库）**：LIVI 从 `/dev/i2c-<carPlayMfiI2cBus>` 读认证协处理器（读写方式见 LIVI 的 `native/livi-helperd/crates/iap2-mfi/src/linux.rs`）。这里配的是总线 99（`carPlayMfiI2cBus` 99，`carPlayMfiPowerGpio` -1），启动器起 LIVI 前检查 `/dev/i2c-99` 在不在。LIVI 的 helper 只在启动时打开一次认证设备，那时设备必须已经存在。LIVI 本身一行不改。

## 文件

| 位置 | 是什么 |
|---|---|
| `livi/install-livi.sh` | 代替 LIVI 自带 install.sh 的安装脚本，平板上 root 运行，可重复跑。做了什么、哪些故意不做以及原因，写在脚本头注释里。第 0 步把解出来的目录改成 0755（10.0.0 的 AppImage 里是 0700，见「换版 LIVI 10.0.0」）。**跑之前先把仓库的整个 `livi/` 目录同步到平板**（10-23 发现平板上的副本是旧的）。新建的 LIVI 配置：仪表盘全关（9.4.0 的 dash3/dash4，10.0.0 的 `dashboard`；开着 iPhone 只给 30 帧）；车辆空调关（`carPlayVehicleClimate`，10.0.0）；打开无线 Android Auto；投屏 1600×1000（否则安卓手机的画面糊，10-20），dpi 是 0（10-20 设过 270，10.0.0 下 iPhone 的界面因此大一号，10-23 改回）。已有的配置不改，只在这几项不对时提示。第 6 步还写一条 KWin 规则 `y700-livi-fullscreen`，让 LIVI 的窗口全屏（10.0.0 自己不全屏）；已有就不动。这几项的原因见「换版 LIVI 10.0.0」的踩坑五到八。平板上的副本在 `/root/src-carplay-livi/` |
| `livi/y700-carplay` | `/usr/local/bin/`，桌面图标的入口。启动前：确认 MFi 认证组件在（`/dev/i2c-99`）；拉起 avahi-daemon；设 `LIVI_GST_SINK`，让视频走 GPU 转换（原因见进度第 10 步「黑屏」）；设 `LIVI_GST_PRELOAD`，把下一行的色彩修正库挂进 gst-host（原因见「第四次实测」），再挂上系统的 `libwayland-client.so.0`（10.0.0 自带的 1.23 让 Mesa 的 EGL 加载失败、黑屏，见「换版 LIVI 10.0.0」踩坑四）。起 LIVI 后给刷新率守护写一份 livi-compositor 的播放状态，CarPlay 全屏时面板 60 Hz（见「帧率与刷新率」）。手机画面在来时（iPhone 和安卓手机都算），或者安卓手机的 AA 会话连着时（AA 画面静止时不发帧），用 `kde-inhibit` 挡住 PowerDevil 的闲置变暗和关屏（`keep_awake`，见「开车时自动变暗、息屏」）。iPhone 抢在热点网卡回来之前经蓝牙要 CarPlay、LIVI 因此卡住时，等热点起来后断开那台手机的蓝牙，让 LIVI 重新叫它（`unstick`，10-23，见「换版 LIVI 10.0.0」）。退出后（正常退出或崩溃）：停热点单元；若 NM 的 unmanaged 配置还在，跑 teardown；收掉残留的 root helper；删掉 LIVI 复制到 `/etc` 的 Wi‑Fi 配置副本（见进度第 10 步）；停 avahi。日志在 `~/.cache/y700-carplay/livi.log`（上一次的是 `.log.1`） |
| `livi/y700-gst-colorimetry.c` | `install-livi.sh` 在平板上用 gcc 编成 `/usr/local/lib/y700-carplay/y700-gst-colorimetry.so`（不需要 GStreamer 头文件）。经 `LIVI_GST_PRELOAD` 成为 gst-host 的 LD_PRELOAD，把 iPhone 码流的色彩参数 `1:3:7:1` 报成 `1:3:5:1`，硬解才协商得过。原因、验证见进度第 10 步「第四次实测」 |
| `livi/y700-carplay-boot-guard.service` | `/etc/systemd/system/`，排在 NetworkManager 之前。断电或复位后若留下 `99-livi-ap-unmanaged.conf`，开机时删掉，否则平板开机后没有 Wi‑Fi |
| `livi/y700-carplay-ap-tune` | `/usr/local/sbin/`，root。LIVI 起的 hostapd 进 ENABLED 后：打开 DEBUG 日志；可选改成只用 WPA2‑PSK（默认不改）。原因和验证见进度第 10 步「复测」「第三次实测」 |
| `livi/y700-carplay-ap-tune.service` | `/etc/systemd/system/`，不单独启用。`BindsTo=livi-wifi-ap.service`，开关是 `Y700_AP_SECURITY`（`livi` 默认 / `wpa2`）和 `Y700_AP_DEBUG`（`1`/`0`） |
| `livi/y700-carplay-ap-settle` | `/usr/local/sbin/`，root，热点单元的 `ExecStartPre`。等 wpa_supplicant 真正放开网卡，再重载 ath12k 让固件重新加载（约 2 s），然后才轮到 LIVI 起 hostapd。原因见进度第 10 步「问题一」「问题二」；`Y700_AP_FW_RESET=0` 关掉重载 |
| `livi/y700-carplay-ps-restore` | `/usr/local/sbin/`，root，热点单元的 `ExecStopPost`（10-22）。热点停下后，等 wlp1s0 回到 station（最多 10 s），把 Wi‑Fi 省电打开回来。原因：`livi-helperd --wifi-ap` 起热点时执行 `iw … set power_save off`（日志「stays awake」），teardown 不恢复。cfg80211 把这个设置记在网卡上，之后每次连家里 Wi‑Fi 都沿用；NM 的 `wifi.powersave=3` 也没把它改回来。10-22 用过两次 CarPlay，16:53 起一直是 off，20:00 体检才发现，熄屏多耗约 0.06 W。tb323fu-helperd 的「性能」档（WifiLowLatency）关省电时会把网卡记进 `/etc/tb323fu/helper.toml` 的 `[wifi] power_save_off`，这种情况脚本不动它。**有时限（10-23）**：systemd 给 ExecStopPost 的时限就是单元的 `TimeoutStopSec`，LIVI 的单元是 8 s。10-23 15:01 它被这样杀过一次（热点单元的 journal：`State 'stop-post' timed out. Terminating.`），一句话没留，省电一直关着；网卡当时 1 秒内就回到了 station，卡在哪不知道。现在每次 `iw` 限 2 s（`Y700_PS_IW_S`），等待按截止时间算，整个脚本最多约 19 s，drop-in 把时限放到 40 s；开头先写一行 `power save: start`，每种结局都带用时（`…, 3s`），再卡住时能看出卡在哪。**等不到 station 就交给 NM（10-24）**：10-23 23:49 等满 20 s 放弃了，`iw` 还说 `type AP`；NM 到 23:54 才重新连上 HOME_6G（22:15 HOME_6G、HOME_2.4G 都连失败过，多半是 NM 的自动重连还被挡着），省电一直关到 00:2x 手动打开。等更久没用：车上可能一小时都没有认识的 Wi‑Fi，而停热点的一方（LIVI 退出、启动器收尾）要一直等它。所以脚本一开始先留个标记 `/run/y700-carplay/ps-pending-wlp1s0`（写的是时间；在 /run，重启就没了，那时 ath12k 本来就是省电开着起来的），只等 10 s；省电确定下来（开回来、本来就开着、helperd 占着）才删标记，否则 journal 里写 `deferred to NetworkManager's dispatcher`，由下面的 `90-y700-carplay-ps` 在 NM 下次把 wlp1s0 连上时带 `nm` 参数再跑一遍（只等 5 s）。**有意不做**：每次连上都去开省电。没有标记时钩子什么都不做，省电平时还是 NM 和 helperd 的事，不和 helperd 抢 |
| `livi/90-y700-carplay-ps` | `/etc/NetworkManager/dispatcher.d/`，root 0755（10-24）。NM 的 dispatcher 钩子，ps-restore 的后一半：`up` 事件、而且有那个接口的标记时，跑 `y700-carplay-ps-restore <接口> 5 nm`，否则直接退出。NM 只跑 root 所有、只有 root 能写、可执行的钩子，不合要求就跳过，只在它自己的 journal 里说；所以体检会查这三点和钩子里有没有调 ps-restore。10-24 平板上手动按 NM 的方式调过（真 `iw`）：没标记不动，标记在、省电 on 时 `already on`，先关掉省电再调是 `restored when NetworkManager brought wlp1s0 up`，两次都删了标记 |
| `livi/test-ps-restore.sh` | 不安装。ps-restore 和上面钩子的桩测试（10-24）：假 `iw`、`logger`，标记和 helper.toml 放在临时目录。测 11 项：马上回到 station、本来就开着、helperd 占着、等不到 station（留标记，再看钩子遇到 `down`、仍是热点时的 `up`、回到 station 后的 `up`、再来一次 `up`）、`iw set` 不生效、没标记的 `up`、`iw` 卡死时的总用时。Git Bash 或平板上任何用户都能跑，约 12 s；换成 10-23 的旧脚本跑有 7 项失败 |
| `livi/test-unstick.sh` | 不安装。启动器 `unstick` 的桩测试（10-23）：假 `iw`/`ip`/`bluetoothctl`，一个 `sleep` 充当 LIVI，手写日志，跑 `y700-carplay --unstick <pid> <日志>`。7 种情形（热点晚到、有线、期间已发出 start、手机已断、不知道哪台手机、连续 4 次失败只断 3 次、等热点时 LIVI 退出），约 20 秒，PC 的 Git Bash 或平板上任何用户都能跑，什么都不碰 |
| `livi/test-ap-settle.sh` | 不安装。桩测试（假 modprobe/lsmod/sysfs，PC 的 Git Bash 或平板上任何用户都能跑，什么都不碰）：重载的三种情形——正常、`modprobe -r` 只卸掉 `ath12k_wifi7`（`ath12k` 被占着）、第一次 `modprobe ath12k_wifi7` 失败——最后都必须网卡回来、`ath12k_wifi7` 在。10-19 审计加：旧版在后两种情形下直接退出，平板就没有 `wlp1s0`，要重启才有 Wi‑Fi |
| `livi/livi-wifi-ap-y700.conf` | `/etc/systemd/system/livi-wifi-ap.service.d/y700.conf`，给 LIVI 的热点单元加 `Wants=y700-carplay-ap-tune.service`、`ExecStartPre=y700-carplay-ap-settle` 和 `ExecStopPost=-y700-carplay-ps-restore`（10-22），再把 `TimeoutStopSec` 从 LIVI 的 8 s 放到 40 s（10-23，原因见上面 ps-restore 一行；10-24 起脚本只等 10 s，40 s 没改，宽一点不碍事）。LIVI 只按全文比对重写单元本身，不看 drop-in |
| `aptest/` | 离线排查热点用的测试工具（平板 `/root/`，PC 端两个 `.ps1` 在 Win11 上跑），用法见进度第 10 步「测法」。都是测试专用：一次性 SSID `Y700-T<k>`、测试口令 `/root/aptest2/pw`（和 CarPlay 口令无关，也不贴出），插桩模块只编在源码副本里。`y700-carplay-ap-m1watch` 原本给 tuner 用，验证无效后撤下，只留给 `apjoin.sh WATCH=N`。`apjoin.sh` 的开关写在文件头（`STA=` 指定 STA 间隔连哪个网络，`RELOAD=1/pair/onbad` 重载固件，`NOSTA`、`WATCH`、`SEC`、`SETUP`、`SETTLE`）；`reloadtest.sh` 单独空跑一次重载。分析脚本（平板上对 `/root/aptest2/join-*` 跑）：`spells.py`（每个 STA 间隔前后好坏、连的 BSS、WMI 差异）、`caps.sh`（PEER_ASSOC 的 peer_caps）、`mactrace.py` + `win.sh`（PC MAC 的时间线）、`episodes.py`（当天所有热点按时间排的好坏）、`wmi-seq.py`；`noenc-patch.py` 是关封装卸载的测试补丁（无效）。10-17 23:52 收尾：平板上这批工具、`/root/aptest2/`（含全部 join-* 结果）、插桩模块源码副本 `ath12k-txdbg/`、各次实测收的日志和其余临时脚本，统一挪进 `/root/carplay-tests-20261017/`（root 0700，184 MB，没删）；测试口令文件已删。要重跑 `apjoin.sh`，先在 `/root/aptest2/pw` 放一个新的测试口令（root 0600，8–63 字符），没有它脚本会拒绝运行 |
| `livi/sudo` | `/usr/local/lib/y700-carplay/bin/sudo`，只放进 LIVI 进程的 PATH，转给经典 sudo（`/usr/bin/sudo.ws`）。原因见进度第 8 步。系统默认 sudo（sudo-rs）不改 |
| `livi/dryrun.sh` | 空跑检查，root 在平板上跑。跑的时候把 `wirelessCpEnabled` 和 `wirelessAaEnabled` 都关掉（开着任何一个，LIVI 都会起热点），跑完按原样放回，所以 Wi‑Fi 不会被拿走，可以在 ssh 下跑。升级 LIVI 后重跑一遍。中途被打断的话，记得把这两个开关改回 true（输出里有 `wireless switches before`）。**10.0.0 起它会让 bluetoothd 重启两次**（开关都关时 LIVI 撤掉自己的 drop-in 和 Class，再开时放回去），所有蓝牙设备断两次，所以要先告诉作者，再带 `Y700_BT_RESTART_OK=1` 跑；换版的空跑改用下一行的 `dryrun-wireless.sh` |
| `livi/dryrun-wireless.sh` | 带无线的空跑，不用手机（10-20）。root 在平板上跑，LIVI 不能在跑。它先 `test-guard.sh arm 8`，再用 systemd-run 在后台跑：经启动器无界面起 LIVI 60 s，第 40 s 记下热点、蓝牙（网卡名、Android Auto 的 RFCOMM UUID）、BLE 广播和 AA 的 TCP 5277，退出后 `test-guard.sh restore` 再 `disarm`，然后看残留、热点单元自己的日志（journal）、跑体检。热点会占走 wlp1s0，ssh 断约 2 分钟，回来后看 `/root/livi-dryrun-wireless.txt`。config.json 只读两个无线开关，日志都过口令过滤。升级 LIVI 或改了启动器后重跑 |
| `livi/test-guard.sh` | 实测时的自恢复。root 在平板上跑（`/root/src-carplay-livi/`）：`arm [分钟]` 用 systemd-run 定一个瞬时定时器（单元 `y700-carplay-test-guard`，默认 20 分钟）；`disarm` 取消；`restore` 照 LIVI 自己退出的路子收尾——给 livi-core 发 TERM，`y700-carplay` 随后停热点、teardown、收 helper、停 avahi——然后逐项复查，确认 wlp1s0 回到 NetworkManager 并连上；`state` 只看状态。不重启，不碰 config.json |
| `livi/dev.f-io.livi.desktop` | 应用菜单 `~/.local/share/applications/`（文件名要和 LIVI 窗口的 app_id `dev.f-io.livi` 一致，任务栏图标才对得上），另存一份为桌面图标 `~/Desktop/CarPlay.desktop`（755） |

下载件（LIVI AppImage）不进仓库：`LIVI-10.0.0-linux-arm64.AppImage`（112 MB）、之前的 `LIVI-9.4.0-linux-arm64.AppImage`（222 MB），从 LIVI 的 GitHub 发布页下载。

## 进度

- [x] 调研与核实：现有的开源 CarPlay 接收端实现、LIVI、加密狗路线、Linux 协议栈、法律风险。
  - 结论：LIVI 是现成的 Linux 原生实现。有线不需要 USB gadget；无线需要平板开 5 GHz 热点。mainline ath12k 的 WCN7850 条目声明支持 AP，本机 WCN7860 还没验证。
  - 注意：调研汇总里说「LIVI 的 arm64 AppImage 要自己编」**是错的**，9.4.0 发布页有 arm64 AppImage。
- [x] 下载并校验 LIVI AppImage（10-17）。
- [x] 准备 MFi 认证组件（不在本仓库）。
- [x] 平板上 1–3 步（10-17 16:28–16:35，内核 y12）：`/dev/i2c-0`…`8` 是板上的 I²C，认证组件在总线 99。用 LIVI 自己的 `iap2-mfi` 代码在平板上对 `/dev/i2c-99` 跑 `I2cCoprocessor::open(99, -1)` → `protocol_major` → `read_certificate` → `generate_challenge_response`，全部通过。
- [x] 平板上 4–7 步（10-17 16:36–16:55）：
  4. apt：缺的只有 `hostapd dnsmasq-base avahi-daemon avahi-utils`，连带装了 `libavahi-core7 libdaemon0`，都来自 Ubuntu 官方源。`iw rfkill pulseaudio-utils libspa-0.2-bluetooth` 本来就有。
  5. `iw list`：wlp1s0（ath12k，我们的 y700-1041 构建）支持 AP 模式。regdomain 由固件自管，是 JP：5 GHz 的 36–48 不需要 DFS，52–144 需要 DFS，149 以上禁用。所以热点用 36 信道、80 MHz（36–48 正好是一个 80 MHz 块）。
  6. 装 LIVI：`/opt/livi-9.4.0` 是 AppImage `--appimage-extract` 解出来的，`/opt/livi` 软链指向它。之后跑 `livi/install-livi.sh`。这一步之前读了 LIVI 9.4.0 的源码（`common.sh`、`wifi_ap.rs`、`bluetoothd.rs`、`udev_rule.rs`、`host_setup.rs`、`helper.rs`、`ui.rs`），结论：
     - **触屏**：`livi-touch-filter` 只隐藏「同一个 USB 设备上既有多点触控又有鼠标接口」的那个鼠标接口。Y700 的 NVT 触屏（event3）没有被标成鼠标，所以规则保留，装完复查 event3 也没被忽略。
     - **udev 规则**：精简版保留 `# LIVI-RULE-VERSION=6` 这一行。livi-core 只检查这一行，有就不会覆盖文件。去掉了 Android 厂商那几行，原因是它们会全系统关掉这些品牌手机的 MTP 和自动挂载，联想 17ef 也在其中。这几行只有有线 Android Auto 用得上：无线 AA（10-20 打开）不经过手机的 USB，所以照样不要。Apple 那两行保留（有线 CarPlay 要用）。副作用：iPhone 插到平板上时，不会再被当成相机或媒体设备。
     - **不是从 AppImage 运行时，helper 不会被复制到 `~/.config/LIVI/driver/`**（`resolve_bin` 只在 AppImage 挂载点内才复制），而是直接从 `/opt` 以 root 运行。所以 sudoers 指向 `/opt/livi-9.4.0/resources/driver/livi-helperd`（root 所有，安全）。user 本来就有 `NOPASSWD: ALL`，这条规则不增加任何权限，只是让配置不依赖那条。同样因为不在 AppImage 里，LIVI 的自动更新是关闭的，版本固定在 9.4.0。
     - **livi-core 只在 `~/.config/LIVI/driver/` 下找崩溃后残留的 helper**，在这里永远找不到，所以由 `y700-carplay` 退出时按 `/opt` 的路径收尾。
     - **LIVI 自己的热点只有正常退出时才会停**（`release_for_quit`）。崩溃后热点单元继续跑，`99-livi-ap-unmanaged.conf` 也留着，NM 就拿不回 Wi‑Fi。`y700-carplay` 退出时补做一次；断电、复位的情况由 boot-guard 兜底。
     - **avahi-daemon 按需运行**：helper 用 `avahi-publish-service _airplay._tcp` 和 `avahi-browse -r -k _carplay-ctrl._tcp` 广播 CarPlay，这两个命令需要 daemon 在跑。本机没有别的程序用 avahi，所以开机不启动（daemon.service 和 .socket 都 disable），由 `y700-carplay` 起停。这样平时家里 Wi‑Fi 上没有一个常驻的 mDNS 应答器在制造唤醒，也不影响夜间功耗实验。
     - **UI**：livi-core 先起自己的嵌套合成器 `livi-compositor`（smithay），它在 KWin 里开一个窗口，app_id 是 `dev.f-io.livi`，Electron UI 跑在里面。user 的 `unshare -Ur` 能用，所以 Electron 沙箱正常，不需要 `--no-sandbox`。（这是 9.4.0；10.0.0 起界面是 Slint 的 `livi-ui`，没有 Electron。）
     - 装完核对（16:53）：`visudo -c` 通过；`udevadm verify` 通过；boot-guard 先手放一个假的残留文件再起服务，文件被删掉了；avahi 两个单元都是 disabled/inactive；config.json 字段正确，权限 0600；桌面图标 755。
  7. `~/.config/LIVI/config.json`（install-livi.sh 只在文件不存在时写）：
     - `wirelessCpEnabled` true，`wifiInterface` wlp1s0，`wifiType` 5ghz，`wifiChannel` 36，`wifiChannelWidth` 80。
     - `country` JP，`hand` 1（右舵；按 Serialize_repr，0 是左舵）。
     - `carName` "Y700 CarPlay"，同时用作热点 SSID 和蓝牙名，最多 20 字符。
     - `carPlayMfiI2cBus` 99，`carPlayMfiPowerGpio` -1。
     - `wifiPassword` 是平板上用 `secrets.token_urlsafe(12)` 生成的 16 位随机串，没有显示，也没有记在任何地方。iPhone 通过蓝牙 iAP2 自动拿到，不需要人输入；要看的话 root 读这个文件。
     - `kiosk.main` true（全屏、无标题栏），`mainScreenWidth/Height` 1600×1002（面板的逻辑尺寸），`projectionWidth/Height` 1152×720。这三项是第 9 步加的，原因见那里。投屏 10-20 改成 1600×1000，并加了 `projectionDpi` 270，原因见「无线 Android Auto」。
     - 其余项用 LIVI 默认值。
- [x] 8. 空跑（10-17 16:55 和 16:59，各 60 秒）。做法：临时把 `wirelessCpEnabled` 改成 false；经真正的启动器 `y700-carplay` 起 LIVI，带 `LIVI_NO_UI=1 LIVI_NO_COMPOSITOR=1`（只跑 core 和 helper，熄屏时不起 GPU 合成器）；60 秒后发 TERM，前后对比状态。脚本是 `livi/dryrun.sh`，平板上 `/root/livi-dryrun.sh`。
  - **认证组件被认出来了**：helper 打印 `opening MFi bus=99 gpio=-1` → `MFi addr=0x10`。
  - 收到 TERM 后正常退出，rc=0，没有残留进程（core、helper、avahi 都没有）。热点单元没有起，NM 和 wlp1s0 不受影响，avahi 回到 inactive。
  - **发现并修了一个问题：sudo-rs 吞掉 `-E`。** Ubuntu 26.04 默认的 sudo 是 sudo-rs 0.2.13，第一次空跑日志里出现 `sudo: preserving the entire environment is not supported, '-E' is ignored`。livi-core 用 `sudo -n -E` 起 helper，大部分设置 helper 会自己从 `$SUDO_USER/.config/LIVI/config.json` 读回来，所以 bus=99 照样生效。但 LIVI 自己的 AirPlay 配件身份（`LIVI_CP_PK`/`LIVI_CP_PI`）和运行时才定的 CarPlay 端口（`LIVI_CP_AIRPLAY_PORT`）只能靠环境变量传，于是 helper 报 `LIVI opened no CarPlay port, CarPlay is not announced`。平板上同时装着经典 sudo（`/usr/bin/sudo.ws` 1.9.17，读同一份 `/etc/sudoers`），所以加了 `livi/sudo` 垫片，只放进 LIVI 的 PATH，系统默认 sudo 不动。第二次空跑没有这条警告，出现了 `[cp] published _airplay._tcp port=38533 deviceid=…`，说明 CarPlay 已经在广播。
  - LIVI 第一次启动做的持久改动和预期一致，退出后仍然保留，见「已知副作用」：
    - bluetoothd 的 drop-in `/etc/systemd/system/bluetooth.service.d/livi-no-sap.conf`（`--noplugin=sap,midi`），`main.conf` 里 `Class = 0x200418`，并重启了 bluetoothd。
    - `~/.config/wireplumber/wireplumber.conf.d/99-livi-hfp.conf`，并重启了 WirePlumber。默认输出仍是 `effect_input.y700_lenovo`，sink 一个不少。
    - `/etc/sudoers.d/99-LIVI-gvfs`。
    - LIVI 把 config.json 补全成整份默认值（4.6 KB，0644；所在目录 `~/.config/LIVI` 是 0700，别人读不到）。
  - 第二次启动不再重启 bluetoothd 和 WirePlumber：前后状态逐行相同，gvfs 进程也相同。
  - 体检：前后都是 rc=10，只有同一条既有的音量键 WARN。和基线（`/root/livi-baseline-checklist-20261017.txt`）比，只差飞行记录器日志的大小。
- [x] 9. 亮屏看桌面图标和界面（10-17 17:05–17:13）。趁屏幕熄着、作者没在用时做，做完关屏；每次都把 `wirelessCpEnabled` 临时改成 false，不动 Wi‑Fi。LIVI 是用 `kioclient exec ~/Desktop/CarPlay.desktop` 起的，和点图标走的是同一条路。
  - **桌面图标一开始没出来。** `~/Desktop/CarPlay.desktop` 在，`kioclient ls desktop:/` 也列得出来，但 plasmashell（前一天 19:09 起）一直没收到这个新文件，桌面上就没有它。处理照主 README「桌面图标旋转后乱序」：
    1. 停 plasmashell。
    2. 改 `positions`：
       - 横屏 1600x1002：把 CarPlay 放在 Konsole 后面的 (1,8)。顺手删掉早已不存在的文件的条目，它们还占着 (1,8)–(1,11)。
       - 竖屏 1002x1600：按横屏顺序，从第 1 行第 0 列重排。
    3. 删掉 `changedPositions`。
    4. 再起 plasmashell。

    备份在 `~/.config/plasma-org.kde.plasma.desktop-appletsrc.y700bak-positions-carplay`。截图里 CarPlay 图标（LIVI 的播放三角）在 Konsole 右边。竖屏没转屏验证。以后往桌面放图标后，要截图确认它真的出现了。
  - **界面一开始只占左上角 1280×720。** KWin 把窗口全屏到 1600×1002，但 livi-compositor 只在第一次 configure 时发布一次输出模式，用的是 `mainScreenWidth/Height`（默认 1280×720）。之后尺寸再变，它也不改模式；源码注释说改模式会让 waylandsink 崩溃。所以 Electron 界面一直停在 1280×720。把 `mainScreenWidth/Height` 设成面板的逻辑尺寸 1600×1002 后：
    - 合成器日志是 `new output -> screen 'main' at x=0 (1600x1002)`；
    - 截图里界面铺满整屏，右侧导航栏一直到底。
  - **投屏分辨率**：LIVI 读不到这块面板的尺寸，没有按面板去算，用了默认的 1280×720（16:9）。改成 1152×720（16:10），和 LIVI 自己的 `fit_720p` 对 1280×800 面板算出的结果相同。画面比例要等 iPhone 实测确认。（10-20 又改成 1600×1000：1152×720 下安卓手机只给 720p，画面糊，见「无线 Android Auto」。）
  - **全屏与退出**：全屏用的是 LIVI 自己的 `kiosk.main`，没有标题栏和窗口按钮。退出 CarPlay：设置 → 系统 →「Power Off」。它只退出 LIVI，**不会关平板**。关机要同时有环境变量 `LIVI_KIOSK=1` 和 `/usr/local/lib/livi/livi-power.sh`，这里都没有。
  - HUD（`y700-hud-overlay`）开着时会叠在 CarPlay 左上角。这是 HUD 本身的设计（overlay 层盖住全屏程序），关掉 HUD 就没了。
  - 截图不能当验收（主 README 的教训：在旋转屏上，KWin 截图和真实输出走两条渲染路径）。实际观感以作者看到的为准。
  - 每次退出都干净：没有残留进程，热点单元 inactive，NM 的 conf.d 只剩原来两个文件。
    - 退出时 Electron 会打一行 `FATAL … GPU process isn't usable. Goodbye.`。它出现在 `ui:main disconnected` 之后：合成器先退，Electron 跟着退出。rc=0。
- [ ] 平板，接下来：
  10. 和作者约好后，拿作者的 iPhone 实测。测试期间 Wi‑Fi 变成热点，ssh 会断，所以用 systemd-run 定时自恢复，测前先告诉作者。**不要和夜间实验（`y700-cx-night.timer`，00:30 起）撞上。**
      - 自恢复脚本 `livi/test-guard.sh` 已在平板上验证过（10-17 17:17）：做法是把无线关掉、不起界面，起 LIVI 后 `arm 1`。定时器到点后 2 秒内收干净：livi-core、launcher、helper 和 avahi 都没了；Wi‑Fi 和 Tailscale 全程在线。开着热点时的那条路径（stop 单元、teardown、重连）只能在实测时验证。
      - 步骤：
        1. 告诉作者。
        2. 记下 `test-guard.sh state` 和 `/etc/NetworkManager/system-connections/` 的内容。
        3. `test-guard.sh arm 20`。
        4. 告诉作者「可以点了」，作者再点桌面 CarPlay 图标。**先 arm 再点**：第一次实测时作者先点了，热点一起来 ssh 就断，arm 没能执行。
        5. iPhone：蓝牙里配对「Y700 CarPlay」，弹出「使用 CarPlay」时点同意，Wi‑Fi 会自动连上平板热点。
        6. 测完退出：投屏期间满屏都是 CarPlay，LIVI 自己的设置按钮点不到。先让 iPhone 断开，比如 iPhone 上关 Wi‑Fi，或在 设置 → 通用 → CarPlay 里忘掉这辆车。10 秒后 LIVI 判定会话结束，回到自己的界面，再点 设置 → 系统 →「Power Off」。或者等定时器到点。
        7. ssh 回来后：`disarm`，收 `~/.cache/y700-carplay/livi.log`、`~/.config/LIVI/log/`、`journalctl -u y700-carplay-ap-tune` 和 `/tmp/livi-hostapd.log`（hostapd 的 DEBUG 输出，下次开热点会被清空，要先拷走），全部过滤掉口令行；再看画面比例、触控、声音、Siri、来电。
      - **第一次实测（10-17 17:23–17:51，作者的 iPhone）：配对、认证、热点都通了，但画面全黑。** 定时自恢复没 arm 上（见上面第 4 步）。退出后 17:51:36 平板自己回到 Wi‑Fi，Tailscale 恢复。
        - 能用的部分：
          - 17:24:45 蓝牙连上，紧接着 `bt: MFi auth succeeded`；17:24:58 `auth-setup signed`，即认证组件的签名被 iPhone 接受。
          - iPhone 申报支持 HEVC；之后切到 Wi‑Fi 隧道（`tunnel: MFi auth succeeded`），会话一直保持到 17:50:17（iPhone 10 秒没动静，会话结束），共 25 分钟。
          - 视频流在收（`cp_screen` 有数据）。
          - 热点开在 **5 GHz**：信道 36（5180 MHz），80 MHz，802.11ax，国家码 JP。配置是 `wifiType 5ghz`、`wifiChannel 36`、`wifiChannelWidth 80`。iPhone 从 17:24:56 关联，到 17:50:07 断开，中间一直稳定（`journalctl -u livi-wifi-ap.service`）。
        - **黑屏的根因**（`~/.config/LIVI/log/gst-host.log`）：
          - gst-host 选了硬解 `v4l2h265dec`（高通 iris，`/dev/video0`），管线一开始就 `not-negotiated` 停了。
          - 在 LIVI 自带的 GStreamer 1.28.7 下逐段复现：
            - iris 单独解码 1152×720@60 的 HEVC 和 H.264 测试片都正常。它输出线性 NV12 dmabuf，高度按 736 对齐，每帧 1271808 字节。
            - livi-compositor 声明支持 NV12（线性和高通 UBWC 两种），但真交给它时导入失败。smithay 日志：`eglCreateImageKHR: createImageFromDmaBufs failed`（EGL BAD_ALLOC）。gst 侧报 `can't create linux-dmabuf buffer`，接着 `cannot have a wl_buffer`。
            - 同一个 buffer 交给 KWin（wayland-0）能用。两边用的都是系统 Mesa 26.0.8，LIVI 的 AppImage 不带 Mesa。区别在导入方式：GStreamer 的 `glupload` 自己按平面导入，能成功；合成器把整个 NV12 当成一张 EGLImage 导入，失败。更深一层（Mesa 里是哪一步拒绝的）没往下查。
        - **修法**：LIVI 留了 `LIVI_GST_SINK` 这个口子，用来替换管线最后的 sink 名字。它是直接拼进 `gst_parse_launch` 字符串的（`{name} name=sink sync=false`），所以能塞一整段链。`y700-carplay` 设成 `glupload ! glcolorconvert ! gldownload ! waylandsink`：
          - 硬解照旧；
          - GPU 转成 RGB，下载回内存，再由 waylandsink 走 shm 交给合成器。
        - 各条路的 CPU（10-17 18:00 左右，在 LIVI 合成器里跑；1152×720、8 Mbit/s 带噪声的 HEVC 测试片；按 60 fps 实时送帧 20 秒；gst 进程的 user+sys 时间，单位是一个核）：

          | 路线 | gst 进程 CPU |
          |---|---|
          | 硬解直接交 dmabuf（LIVI 默认） | 不出画面 |
          | 硬解 + GPU 转换 + gldownload（**现用**） | 约 40% |
          | 硬解 + 系统内存 NV12 + `videoconvert` | 约 68% |
          | 软解 `LIVI_GST_SWDEC=1`（avdec_h265 + `videoconvert`） | 约 85% |

          软解比硬解只多十几个点，大头是 `videoconvert` 在 CPU 上转色。
        - 试过但不能用的：让 `gldownload` 直接输出 dmabuf（AB24）给 waylandsink，协商失败。不加约束时，`gldownload` 会先试 dmabuf，失败后自己退回系统内存，所以最后跑的是系统内存那条路。
        - 回退：在环境里设空的 `LIVI_GST_SINK=`，就回到 LIVI 原来的 sink（硬解时又会黑屏）。`LIVI_GST_SWDEC=1` 能强制软解。
        - **有意没做**：没改 LIVI。它的安装包和二进制按原样用，升级时整体替换。`LIVI_GST_SINK` 这条路依赖 9.4.0 拼管线字符串的写法，以后升级 LIVI 要先查 `native/livi-gst-video/rust/codec/src/lib.rs` 的 `sink_chain` 有没有变。
        - 验证情况：新启动器 10-17 18:07 装进 `/usr/local/bin`，`LIVI_GST_SINK` 已出现在 livi-core 和合成器的环境里，gst-host 会继承。**真机画面还没看到，要等作者复测。**
        - **后来查明（10-17 23:40，真机）：这一步必要，但不够。** iPhone 的码流还带着 v4l2 解码器不收的色彩参数，在走到合成器之前就 not-negotiated 了。见下面「第四次实测」。上面用测试片复现出的合成器导入失败是真的，只是真机上它排在后面，所以 GPU 转换这段链继续留着。
      - **`/etc` 里多出的 Wi‑Fi 配置副本（已处理，10-17 18:11）**：LIVI 开热点前会调用 `persist_nm_profiles`，把 `/run/NetworkManager/system-connections/` 里由 netplan 生成的 Wi‑Fi 配置复制到 `/etc/NetworkManager/system-connections/`，理由是「接口离开 NM 后 /run 里的配置会消失」。这台平板上 5 个 Wi‑Fi 配置全是 netplan 生成的，原先 `/etc` 那个目录是空的。
        - 第一次实测后核实到：
          - `/etc` 里多了 5 份副本（17:23，root 0600），和 `/run` 里的原件逐字节相同。
          - `/run` 里的原件整个测试期间都在，LIVI 说的「会消失」在这里不成立。
          - NM（1.54.3）用的全是 `/run` 那份（`nmcli -f NAME,FILENAME connection show`），没有重复 UUID。所以副本平时不起作用。
          - 副本的问题出在以后：在系统设置里删掉某个网络后，netplan 那份没了，`/etc` 的副本会让这个网络又冒出来。另外，口令也多存了一份。
        - **处理**：`y700-carplay` 退出时，删掉那些和 `/run` 原件逐字节相同的 `netplan-*.nmconnection` 副本，然后 `nmcli connection reload`。不相同的不碰，比如作者以后自己放在 `/etc` 的配置。下次开热点 LIVI 还会再复制，退出时再删。
          - 已在平板上验证：起 LIVI（无线关）再退出，日志出现 `removed 5 Wi-Fi profile copies LIVI left in /etc`；`/etc` 那个目录回到空；Wi‑Fi 配置仍全来自 `/run`，连接没断，Tailscale 在线。
          - 断电等原因导致 `y700-carplay` 没走到收尾时，副本会留到下一次 CarPlay 退出。
      - **热点关掉后先连上 HOME_2.4G**：不是问题。17:51:22 热点刚撤，扫描里还没出现 6G，NM 先按优先级连了 HOME_2.4G（优先级 10）。17:51:48，作者原有的 NM dispatcher 脚本 `90-y700-prefer-6g` 看到 HOME_6G 后切了回去（优先级 30），日志 `HOME_6G visible, switching from HOME_2.4G`。
        - 家里的 HOME_5G 设成不自动连接（`autoconnect no`）。作者说这是和家里那台路由器兼容性不好，不是平板的 5 GHz 有问题。CarPlay 热点本来就在 5 GHz 上跑（见上），别因为这个设置去改热点的频段。
      - LIVI 每次启动都会用蓝牙去回连上次配对的 iPhone，无线关掉时也一样（日志 `[cp] reconnect: … page failed`，那时 iPhone 拒绝了）。车上要的就是这个效果；但测试时没必要就别反复起 LIVI，免得去打扰作者的手机。
      - **复测（10-17 18:13–18:18）：还是黑屏，但这次根本没走到视频。** iPhone 没连上热点，CarPlay 会话没建立，gst-host 一次都没起，所以这次和上面的视频修法无关，那条路仍未在真机上验证。
        - 过程（`~/.cache/y700-carplay/livi.log`，hostapd 的输出在 journal 里 `_COMM=hostapd`）：
          - 18:13:55 起 LIVI 用蓝牙回连 iPhone，18:14:02.15 连上；认证 0.1 秒就过了（`bt: MFi auth succeeded`）；18:14:02.75 `bt: CarPlayStartSession sent`。
          - 160 ms 后 iPhone 来连热点：18:14:02.91 `authenticated`，然后 03.10、06.78、10.02 三次 `associated (aid 1)`。没有 `pairwise key handshake completed`，没有 DHCP；18:14:18 `deauthenticated due to local deauth request`。之后 iPhone 只留在蓝牙上，不再试 Wi‑Fi。
          - 第一次实测则是：17:24:56.825 `associated`，38 ms 后 `pairwise key handshake completed (RSN)`，前面**没有** `authenticated` 这一行。
        - 对照 hostapd 2.11 源码（`src/ap/ieee802_11.c`、`wpa_auth.c`、`wpa_auth_glue.c`）读出来的：
          - INFO 级的 `authenticated` 只在开放系统认证（WPA2‑PSK 走的那种）成功时打；SAE 认证不打。所以**第一次 iPhone 走的是 WPA3（SAE），复测时它先做了开放系统认证**。
          - 开放认证后又用 SAE AKM 来关联、但 hostapd 手里没有对应 PMKSA 的，会被拒（`INVALID_PMKID`，只在 DEBUG 里有记录）。iPhone 上次走过 SAE，带着缓存的 PMKSA 来快速重连，像是这么回事；而 hostapd 每次随 LIVI 新起，缓存是空的。之后 iPhone 具体换了哪种方式，INFO 日志看不出来。
          - 如果是口令不对，4 次握手第 2 帧 MIC 校验失败时 hostapd 会打 `AP-STA-POSSIBLE-PSK-MISMATCH`（INFO，进 `/tmp/livi-hostapd.log`），这次没有。也就是 hostapd 根本没收到第 2 帧：要么第 1 帧没到 iPhone，要么 iPhone 没回。
          - 口令和 SSID 两次没变：`install-livi.sh` 只在没有 config.json 时生成口令，两份 config.json（`~/.config/LIVI/`、`~/.local/share/LIVI/`）和 hostapd 配置里的一致，日志里没有 LIVI 回落到默认口令的那行。比对只输出「相同/不同」，不显示值，也不显示长度。
          - 平板这边：本次开机只开过这两次热点（17:23:57、18:13:53），配置相同（5 GHz 36 信道、80 MHz、`wpa_key_mgmt=WPA-PSK SAE`、`ieee80211w=1`、`sae_pwe=2`）。复测期间内核没有任何 ath12k 报错。第一次时有 52 条 `dp_tx: failed to find the peer with peer_id 12`，但那次是好的。
        - **当时的结论**：断在 WPA2/WPA3 过渡模式下 iPhone 的重连。是 iPhone 那边的问题还是平板网卡丢帧，INFO 日志分不出来，所以下次要有 DEBUG 日志。
          - **这个结论后来证明是错的**：真正的原因是平板网卡固件丢帧，WPA2‑only 照样坏。见下面「第三次实测」和「问题二」。下面这段处理保留，只是 WPA2‑only 已不再是默认。
        - **处理（10-17 18:39 装上）**：`y700-carplay-ap-tune`，跟着 LIVI 的热点单元一起起停（drop-in `livi-wifi-ap.service.d/y700.conf` 加 `Wants=`，tuner 自己的单元 `BindsTo=`）。LIVI 每起一个 hostapd，等它进 ENABLED 后做两件事：
          - 改成**只用 WPA2‑PSK**：改法和 LIVI 自己的回退「WPA2 only」（`livi-wifi` 的 `ap_config::weaker`）一样，`wpa_key_mgmt=WPA-PSK`，删掉 `ieee80211w`、`sae_pwe`；然后 `hostapd_cli raw RELOAD_CONFIG` 让 hostapd 重读。无线 CarPlay 车机普遍就是 WPA2‑PSK。
          - 打开 hostapd 的 DEBUG 输出，带时间戳（`log_level DEBUG 1`）。输出写进 LIVI 自己的 `/tmp/livi-hostapd.log`，LIVI 每次开热点会清空这个文件。
          - 顺手把 `/tmp/livi-hostapd.conf` 设成 0600。LIVI 写成 0644，里面有口令。
        - 为什么这么绕：
          - LIVI 选加密方式只看网卡能不能跑 SAE（`security_for`），没有配置项。
          - 它找 hostapd 用的是写死的 `/usr/sbin`、`/sbin`…（`livi-runtime` 的 `sys::tool`），所以没法在 PATH 前面放一个包装脚本。
          - 它只按全文比对重写 `livi-wifi-ap.service` 本身，不看 drop-in。
        - 离线验证（10-17 18:39，只起 `livi-wifi-ap.service`，不起 LIVI，也没有 CarPlay；用 `systemd-run` 定时跑，热点保持 60 秒后由 `test-guard.sh restore` 收回）：
          - 18:39:15.20 hostapd 进入 ENABLED。tuner 15.20 打开 DEBUG，15.26 `RELOAD_CONFIG OK, key_mgmt now 'WPA-PSK'`；`get_config` 是 `wpa=2`、`key_mgmt=WPA-PSK`、CCMP；配置文件 0600。
          - 从外面看：这台 Win11 PC 用 WinRT 的 `WiFiAdapter.ScanAsync` 扫，8 次都是 `Y700 CarPlay` 02:00:00:00:00:10、5180 MHz、`RsnaPsk`/`Ccmp`。扫描不会让 PC 断开自己的 Wi‑Fi。
          - 60 秒里 hostapd 没被重启。停单元后 tuner 跟着停了（inactive），4 秒内连回 HOME_6G，`/etc` 的 5 份副本也删了。
        - **未验证**：
          - iPhone 上次走 SAE 存下了这个网络，这次热点只剩 WPA2，它会不会照常加入。
          - LIVI 中途重启 hostapd（PID 变了）时，tuner 会再改一次。代码里有这一步，但没实际触发过。
        - 回退：`systemctl edit y700-carplay-ap-tune` 设 `Environment=Y700_AP_SECURITY=livi`，就回到 LIVI 自己的选择；`Y700_AP_DEBUG=0` 关掉 DEBUG。要整个不用，删掉 drop-in 再 `systemctl daemon-reload`。（10-17 晚起默认就是 `livi`，要只用 WPA2 改设 `wpa2`。）
        - 读 DEBUG 日志一定要过滤：hostapd 不加 `-K` 时密钥显示成 `[REMOVED]`，但有几行会带口令的长度（`PSK (ASCII passphrase) … len=`）。用 `sed -E 's/((passphrase|password|sae_password|wpa_psk|psk)[^a-z_-]).*/\1 [cut]/I'`，把关键字之后整段切掉。
        - **有意没做**：
          - 没改 LIVI。
          - 没改成只用 WPA3：一来没有证据说明是 WPA2 这条路坏了；二来 iPhone 重连时还是会先拿旧 PMKSA 去试。
          - 没持久化 PMKSA：hostapd 不支持跨进程保存。
          - 没去管 `~/.config/LIVI/config.json`：LIVI 每次启动都会把它重写成 0664，里面有口令，但这台平板只有作者一个用户，先记下。
      - **第三次实测（10-17 18:44–18:47，WPA2‑only 已经装上）：和复测一样，iPhone 连不上热点。**
        - 18:44:34.10 LIVI 起热点，35.08 `AP up`（36 信道、80 MHz、802.11ax）；35.15 tuner 改成 WPA2‑only，`RELOAD_CONFIG OK`。
        - iPhone 在 18:44:42、46、51、55 做了四次「开放认证 → 关联」，每次都没完成握手；18:45:04 被 hostapd 踢掉。之后 iPhone 只留在蓝牙上。
        - DEBUG 日志里每次关联都一样：EAPOL‑Key 第 1 帧（M1）发了一遍又一遍，iPhone 一次第 2 帧（M2）都没回。也就是说，「WPA3 过渡模式下重连出错」这个判断不对，只剩 WPA2 照样坏。
        - wpa_supplicant 对 wlp1s0 的 deinit 在 18:44:34.119，hostapd 34.54 才起，所以这次也不是下面的问题一。
      - **根因是两个互不相关的问题（10-17 19:00–21:50 离线查清，用 PC 代替 iPhone）。**
        - **测法**（工具在 `aptest/`）：
          - **平板端**：`apjoin.sh K HOLD GAP` 连开 K 个一次性测试热点。
            - SSID 是 `Y700-T<k>`；配置取自 LIVI 的 `/tmp/livi-hostapd.conf`，口令换成测试专用的 `/root/aptest2/pw`。
            - 每个热点保持 HOLD 秒；两个热点之间把网卡交回 NetworkManager 连家里 Wi‑Fi，模拟每次打开 CarPlay 时的「STA → AP」切换。`NOSTA=1` 时不交回，只重启 hostapd。`WATCH=N` 时对每个 hostapd 跑 m1watch，被停后 2 s 照 LIVI 的方式重起。
            - 每个热点留下：过滤掉口令行的 hostapd `-dd` 日志、内核日志，以及一行汇总（关联次数、M1/M2 数、握手、DHCP、重起次数）。
            - 测试期间平板离线，所以由 `apjoin-go.sh` 或 `txdbg-go.sh` 经 systemd-run 起，同时定好自恢复定时器。
          - **PC 端（Win11）**：`pcloop.ps1` 逐个连 `Y700-T<k>`，每个交给 `pcjoin2.ps1`。
            - `pcjoin2.ps1` 用 netsh 导入一个临时配置文件，导入后立刻删掉；连上后测 DHCP 和 ping，再回家里的 HOME_6G。
            - `-ConnWait` 秒内没连上、状态又是 disconnected 时，每 4 s 重发一次 connect，模拟手机自己重试。
            - 不用 WinRT 的 `ConnectAsync`：它 0.8 s 就回 NetworkNotAvailable，一帧都不发。
          - **驱动插桩**：
            - `txdbg-patch.py` 只改 ath12k 源码的**副本**，不动内核树。`txdbg-build.sh` 用 clang 18 编出 `y700-1041-txdbg` 模块。
            - `txdbg-run.sh` 测前换上插桩模块，测后换回原装的 `y700-1041`；`txdbg-restore.sh` 同时用作自恢复。
            - 打印的内容：AP 上每个数据帧的 TX 描述符；每个发送完成状态（WBM 原始 8 个字）；固件的 HTT 完成状态；peer、vdev、bank 的建立；全部 WMI 命令和事件（前 48 字节）。装密钥和管理帧只记 ID 和长度，不记内容。
            - `txdbg-sum.sh` 按热点汇总。`wmi-seq.py` 按 wmi.h 里的名字展开 WMI 流，范围从 AP vdev 创建到第一帧 EAPOL。
        - **问题一：wpa_supplicant 退得晚，把刚起的热点关掉（已修）。**
          - LIVI 的 `--wifi-ap-claim` 执行 `nmcli device set wlp1s0 managed no`，命令立刻返回。wpa_supplicant 要再过 100–350 ms，才拆掉 p2p-dev-wlp1s0 并对 wlp1s0 做 nl80211 deinit。
          - deinit 会把接口切回 station 模式。如果它落在 hostapd 的 START_AP 之后，内核随即停掉 AP（`iw event`：「start ap」后约 20 ms 就是「stop ap」）。hostapd 却仍报 ENABLED，外面既看不到热点也连不上。
          - 离线在 2.4 GHz 上试了 4 次，中了 2 次（10-17 19:17）。三次真机实测都没碰上。
          - 修法：`y700-carplay-ap-settle`，作为 `livi-wifi-ap.service` 的 ExecStartPre，排在 LIVI 自己的 claim 之后。
            - 它等到三件事都成立：`/run/wpa_supplicant/` 下这块网卡和 p2p-dev 的控制口都没了；没有 P2P-device；wpa_supplicant 在 D-Bus 上的接口列表里也没有它。然后再等 0.5 s。
            - 最多等 10 s，超时照样放行，不让单元失败。
          - 之后的离线测试里它等了 177–239 ms，热点再没被关过。
        - **问题二：平板连过 6 GHz 家里 Wi‑Fi 后，固件可能把热点的 EAPOL 全部丢掉（修法：开热点前重载 ath12k）。**
          - **现象**：对方关联成功，hostapd 发出 M1，对方不回 M2。hostapd 隔 0.1 s、1 s、1 s 重发，发满 4 次后以握手超时踢掉对方；对方再关联还是这样。
            - 坏状态成段出现：跨 hostapd 重启、跨 2.4 GHz 的 STA 间隔，一坏几分钟（见「规律」）。
            - 离线用 PC 测了 36 个热点，坏了 7 个（约 19%）。20 MHz 一轮 12 个里坏 3 个；80 MHz 两轮 24 个里坏 4 个。
            - iPhone 第二、第三次实测碰上的就是它。
          - **证据（插桩模块）**：
            - 坏热点里每一帧 EAPOL 的 TX 描述符，和好热点逐字段相同：vdev 0；bank 0，配置 00004402；tcl metadata；encap；搜索标志；AST。
            - 但发出后约 56 µs，固件就把帧退回来：HTT WBM 状态 1，意思是「被固件丢弃」，release source 3。状态字里的 peer 字段是 0，也就是固件没找到这个 peer。
            - 好热点约 4 ms 后回状态 0（发送成功），peer 字段是客户端的 peer_id。
            - 驱动这边的 peer 创建、HTT peer map（ast / hw peer id）、vdev 参数，好坏热点都一样。
          - **完整 WMI 记录**：抓了 12 个热点（其中 2 个坏），范围从 STA 拆除、扫描 vdev、AP vdev 创建、VDEV_START、装 GTK，一直到客户端的 PEER_CREATE / ASSOC / INSTALL_KEY 和第一帧 EAPOL。
            - 好坏之间，命令和事件的种类、顺序、载荷（前 48 字节）都没有差别，时序也接近。
            - 结论：**主机这边能看到的东西没有任何区别，问题在固件内部**。这块网卡的固件不开源，没再往下挖。
          - **规律：只有 6 GHz 的 STA 间隔会改变状态**（10-17 晚，`aptest/spells.py`）：
            - 两次 12 热点跑法（join-212700、join-215640）里，逐个 STA 间隔看前后两个热点：好↔坏的翻转**只**出现在 NetworkManager 连 HOME_6G（6 GHz）的间隔里，15 个里翻了 6 个；连 HOME_2.4G 的 7 个间隔一个没翻，状态原样带过去。两个方向都有（好→坏、坏→好），像是每次 6 GHz 连接都让固件里的某样东西重新「掷」一次。
            - 6 GHz 间隔里多出来的 WMI 命令只有 `0x502b`（VDEV_SET_TPC_POWER，6 GHz 才发），2.4 GHz 间隔多出 `0x4003`（PDEV_SET_PARAM）。这只说明哪段是 6 GHz，看不出固件里变了什么。
            - 不经过 NetworkManager、只连续重启 hostapd（`NOSTA=1`，正是 LIVI 重启 hostapd 的方式），11 个热点全好（10-17 21:05–21:24）；WATCH 跑法的坏段里约 40 个 hostapd 一个接一个全坏。两者一起说明：没有 6 GHz STA 间隔，状态就不变，好的一直好，坏的一直坏。
            - 原先「上一个 STA 连的是哪个 BSS 与好坏无关」的结论不矛盾：状态由最近一次 6 GHz 间隔决定，之后的 2.4 GHz 间隔不改它，所以只看「上一个」看不出关系。
          - **排除过的假设**（每条都有离线对照）：
            - HT40 共存扫描建的扫描 vdev：20 MHz 不建这个 vdev，仍然 3/12 坏。
            - 客户端分到的 peer_id、settle 等了多久：都和好坏无关。
            - hostapd 报的 `EAPOL-Key TX status … ack=0`：好热点里也有。
            - WMI 命令和事件的差异：没有，见上。PEER_ASSOC 里的 peer_caps（`aptest/caps.sh`）：0x1431、0x1511 两种在好坏热点里都有。
            - **TX 以太网封装卸载**（实测，10-17 21:56，join-215640）：驱动副本里去掉 `SUPPORTS_TX_ENCAP_OFFLOAD`（`aptest/noenc-patch.py`，叠在 txdbg 上）。EAPOL 确实改走普通硬件路径（没有 TO_FW、没有扩展描述符、没有 HTT 元数据），但完成状态照样来自固件（release source 3），坏热点照样「固件丢弃、peer 0」，12 个坏 4 个。驱动走哪条路无关。所以没有把它做成正式模块（原本打算叫 y700-1049，草稿已删）。
            - STA 模式下固件记住了 PC 的 MAC（`aptest/mactrace.py`）：STA 间隔里主机这边看不到任何提到 PC MAC 的 HTT/WMI 消息，peer map 只有家里的 AP；客户端的 peer_id 照常递增。固件内部的状态排除不了。
            - 更早排除的：上游的 peer_id 0 修复（树里已经有了）；tcl_metadata 的 `|=`；WPA3 / PMKSA；U-APSD；AP 省电；开机后的第一个热点；按 CPU 分的发送环。
          - 内核日志里的 `dp_tx: failed to find the peer with peer_id N` 是另一回事，可以忽略：好热点每个都有一两百条（来自 TQM 完成事件），和握手成败无关。
        - **处理（10-17 晚）：每次开热点前重载 ath12k，让固件重新加载。**
          - 放在 `y700-carplay-ap-settle` 里，等 wpa_supplicant 放手之后：`modprobe -r ath12k_wifi7 ath12k`，再 `modprobe ath12k_wifi7`（走 `/etc/modprobe.d/y700-ath12k.conf` 的规则，装的还是我们的模块），等 wlp1s0 回来，再等 wpa_supplicant 确实没碰它。约 2 s。
          - **离线验证**（`aptest/apjoin.sh` 的 `RELOAD=pair STA=HOME_6G`，10-17 22:25，join9）：热点两两一组，单数那个前面先让 NM 连 HOME_6G（会随机翻转状态），双数那个紧跟其后、不经 STA，只做重载。16 个热点：
            - s1 坏（PC 关联 4 次，M1 20 个，M2 0）。紧接着重载，s2 好：PC 1.5 s 连上，DHCP、ping 都通。
            - s2–s16 共 15 个全好。其中 7 个单数热点前面是 HOME_6G 间隔（另一个间隔 NM 落到了 HOME_2.4G），一个都没变坏；没重载的跑法里 6 GHz 间隔约 40% 会翻转。
            - 重载 3.5–3.8 s，NM 一直是 unmanaged，模块版本仍是 y700-1041，蓝牙不受影响，内核没有 Oops。
          - **用正式脚本验证**（`CLAIM=livi STA=HOME_6G SEC=livi SETUP=livi SETTLE=/usr/local/sbin/y700-carplay-ap-settle`，每个热点前都连 HOME_6G，再照 LIVI 认领网卡、走部署好的 settle，join11 / 平板 `join-230810`）：
            - s1–s7 共 7 个全好：PC 1.5 s 连上，DHCP、ping 都通。settle 里固件重启 1.43–1.68 s，之后 wpa_supplicant 约 10 ms 就放手。
            - s8 坏了，但不是固件状态：**`y700-wifi-watchdog` 在 settle 重载后 1 s 又重载了一次驱动**。那个 STA 间隔里测试脚本切 HOME_6G 时两次断开 NM 自己连上的 HOME_5G，每次断开内核记一行 `failed to flush transmit queue`，3 分钟内 2 行到了看门狗的阈值。两次 `modprobe` 撞在一起，wlp1s0 在 settle 检查之前又消失了，hostapd 没网卡可用；s9、s10 也因为网卡不在而失败。作者叫停，没再跑。
            - 修法：看门狗在 `livi-wifi-ap.service` 处于 active / activating / deactivating 时不动 Wi‑Fi，只在 journal 里说一句（`linux/net/y700-wifi-watchdog`，10-17 已部署；单独跑 case 那段验证过两个分支）。正式 CarPlay 走这个单元，所以覆盖到了；测试脚本模拟的认领不走单元，不受这条保护。
            - 回头看：下午的测试里看门狗也重载过两次（21:24、21:47），等于中途换了新固件，那两段的好/坏统计可能被它带偏。结论靠的是 22:25 的成对跑法，那一段它没有动。
          - **实现要点**：
            - 顺序：LIVI 的 ExecStartPre `--wifi-ap-claim` 已经写好 `99-livi-ap-unmanaged.conf` 并让 NM 放手；接着是 settle（等 wpa_supplicant、重载）；然后 LIVI 的 ExecStart `--wifi-ap` 才做 `iw reg set`、`ip addr add`、link-local、读网卡能力和 MAC、起 dnsmasq/hostapd。所以重载不会丢掉 LIVI 设好的东西。
            - 新网卡出现时 NM 已经读到 LIVI 的 unmanaged 配置（`/etc/NetworkManager/conf.d/99-livi-ap-unmanaged.conf`），不会去碰它，更不会去连家里 Wi‑Fi（否则又是一次 STA 间隔）。重载后网卡 MAC 不变（02:00:00:00:00:10）。
            - **踩过的坑（10-17 22:52，join10 作废）**：第一版 settle 为「没有 LIVI 配置文件」的情况在 `/run/NetworkManager/conf.d/` 放了一份临时 unmanaged 配置。NM 不认那里的这一行：新网卡一出现就被 NM 接管，起了 wpa_supplicant 和 P2P 设备，占掉 vdev 0；0.4 s 后 hostapd 建 AP vdev 失败（`failed to vdev 1 create peer for AP: -22`、`failed to create vdev`），热点根本没起来，6 个热点 PC 都扫不到。现在不放临时配置：重载后一律 `nmcli device set managed no`，再按第 1 部分等 wpa_supplicant 放手、再等 0.5 s。正式环境里 LIVI 的配置在 `/etc`，NM 本来就不碰。测试脚本也改成照 LIVI 原样认领网卡（`apjoin.sh CLAIM=livi`）。
            - LIVI 自己重启 hostapd（坏了、退出了）是在 `--wifi-ap` 进程里循环，不回 ExecStartPre，所以不会重复重载；那时也没有 STA 间隔，状态不会变。
            - 环境变量 `Y700_AP_FW_RESET=0` 可关掉这一步。重载出任何问题都只在 journal 里说一句，不让单元失败。
            - 先例：`linux/net/y700-wifi-watchdog` 在固件发送队列卡死时也是这样重载。
          - **试过、无效、已撤下：重启 hostapd 的看门狗 `y700-carplay-ap-m1watch`**（现在在 `aptest/`）。
            - 做法：跟着 hostapd 的 DEBUG 日志，同一个 station 连续 3 个 M1 都没回音（约 1.1 s），就给 hostapd 发 TERM，LIVI 2 s 内用同一份配置重起。10 分钟内最多 5 次。单测 `aptest/m1watch-unit.sh`（合成日志，5 个场景，只有「连丢 3 次」那个停了进程）。
            - `WATCH=3` 跑法（join-212700）：坏段里它一个接一个停了约 40 个 hostapd，新起的每一个照样丢 EAPOL。换一个 hostapd 出不了这个固件状态，所以撤下。脚本留着只给 `apjoin.sh WATCH=N` 用。
          - **tuner 默认改回 `Y700_AP_SECURITY=livi`**，用 LIVI 原样的 WPA2/WPA3 过渡模式。WPA2‑only 是按错误的判断加的；开关还留着。
        - **有意没做**：
          - 没修固件或驱动：问题在固件内部，主机这边找不到可改的差异（关封装卸载实测无效）。换固件版本风险大，还会影响家里的 Wi‑Fi。
          - 没做「看到 M1 没回音再重载」：要等 iPhone 来连才看得出坏，那时重载会断掉热点、还要和 LIVI 的 hostapd 抢网卡。每次开热点先重载只多约 2 s，而且结果确定。
          - 没禁掉 6 GHz：家里 Wi‑Fi 要用；重载已经把它的影响清掉。
          - 没改成 20 MHz：20 MHz 下坏的比例一样（3/12）。
          - 没用 hostapd 的 `noscan=1`：Ubuntu 的 hostapd 2.11 不认这个配置项（`unknown configuration item 'noscan'`）。
      - **第四次实测（10-17 23:30–23:50，作者的 iPhone；自恢复定时器每次都先 arm 好）：热点修好了，画面从黑到有。**
        - **热点**：23:30 起，晚上一共开了 4 次热点（23:30、23:38、23:42、23:49，后三次是下面的重启），每次 settle 都重载了固件（1.48–1.58 s），iPhone 每次都连上：握手完成、拿到地址、视频流进来。第一次 iPhone 收了 13.5 MB 数据。问题二的修法在真机上成立。
        - CarPlay 期间平板离开家里 Wi‑Fi，经 Tailscale 的 ssh 会断。作者插上 USB 后，改走 USB 网口 `ssh root@192.168.7.2`（PC 端 192.168.7.1），这条线不受影响。后面几次重启都是经 USB 做的。
        - **画面还是黑的，这次的根因是色彩参数**（23:33 收的日志，平板 `/root/carplay-tests-20261017/cp-test-233307/`）：
          - gst-host 选了硬解 `v4l2h265dec`，管线照样 not-negotiated。启动器的 GPU 转换链这次已经在了，说明卡在它前面。
          - 用 `LIVI_GST_SWDEC=1`（软解）重启（23:38）后**作者确认有画面**。再带 `LIVI_GST_DEBUG=h265parse:4` 重启（23:42），解析器日志：`colorimetry has been changed from (NULL) to 1:3:7:1`。iPhone 主屏是 HEVC 1152×720，VUI 写的是全范围、BT.709 矩阵、**sRGB 传输函数**、BT.709 原色。
          - GStreamer 的 v4l2 解码器只收它探测过的色彩参数。sink caps 里的列表是：`bt601, 1:4:16:3, smpte240m, bt709, 1:3:5:1, 2:4:5:2, 2:4:5:3, 1:4:5:3, 1:4:7:1, 2:4:7:1, 2:4:12:8, bt2020, bt2100-pq, 2:0:0:0`。这是 GStreamer 拿一组固定候选去 TRY_FMT 得到的，候选里没有「BT.709 矩阵 + sRGB 传输」，`1:3:7:1` 就不在里面，caps 被拒。内核 iris 驱动本身对 OUTPUT 队列的色彩参数是原样收下的（`iris_vdec.c` 的 try_fmt / s_fmt），不是驱动的事。
          - LIVI 里有同类修正，但只认树莓派 4 的 `1:4:5:1`（`media_player_lib.rs` 的 `BAD_COLORIMETRY`，在解码器 sink 上挂 probe 改写）。
          - 之前离线复现用的测试片不带这组 VUI，所以没碰到。
        - **修法**：`y700-gst-colorimetry.so`，经 LIVI 留的 `LIVI_GST_PRELOAD`（成为 gst-host 的 LD_PRELOAD）挂进去。
          - 它只替换一个函数：`gst_video_colorimetry_to_string`。h264parse / h265parse（`libgstvideoparsersbad.so`）就是用它把 VUI 写成 caps 里的字符串的。矩阵是 BT.709、传输是 sRGB 时，改报 BT.709 传输，结果是 `1:3:5:1`（限定范围时是 `bt709`），解码器收。
          - 画面不受影响：这条管线里没有元素用到传输函数。`glcolorconvert` 转 RGB 只用范围和矩阵，这两项原样保留；`videoconvert` 默认 `gamma-mode=none`。两条曲线本身差得不小（sRGB 编码的中灰 128 按 BT.709 读约为 115），以后若加了会转 gamma 的元素，或让合成器按色彩管理吃 YUV，这个改标签会变成看得见的中间调偏移（审查指出，10-18 改正）。
          - 实现要点：gst-host 本身不链接 libgstvideo，它跟着插件进来，而 GStreamer 用 RTLD_LOCAL 打开插件，`dlsym(RTLD_NEXT)` 不一定看得见它。所以先 `dlopen("libgstvideo-1.0.so.0", RTLD_NOLOAD)` 拿已加载的那份再 `dlsym`，拿不到才退回 RTLD_NEXT。
          - 不需要 GStreamer 头文件：`GstVideoColorimetry` 就是四个枚举，源码里自己声明。平板上没装 gstreamer 的 dev 包，LIVI 自带的是 1.28.7。
        - **离线验证**（23:47，gst-host 的原样环境，LIVI 自带的 gst-launch，`hevc_metadata` 把测试片的 VUI 改成和 iPhone 一样）：不加修正库，not-negotiated，和真机一模一样；加上，解析器报 `1:3:5:1`，iris 硬解 90 帧出 89 帧（管线收尾少一帧），走 GPU 转换到底。
        - **真机验证**（23:49，经 USB 重启 CarPlay，去掉 `LIVI_GST_SWDEC`）：iPhone 自己重连；`gst-host.log` 里是 `decoder=v4l2h265dec (hw)`、`colorimetry … to 1:3:5:1`、`decoded format=DMA_DRM drm=NV12 1152x720`，没有报错，`cp_screen` 不丢帧。gst-host 约 25% 单核（软解时约 85%）。**作者确认硬解画面正常、颜色对**（23:51）。
        - 回退：环境里设 `LIVI_GST_SWDEC=1` 走软解，不需要修正库也不需要 GPU 转换链。设空的 `LIVI_GST_PRELOAD=` 就不挂修正库（硬解又会黑）。
        - **有意没做**：
          - 没改 LIVI，理由同上。升级 LIVI 后要先确认 `LIVI_GST_PRELOAD` 还在、解码器 caps 列表是否已经包含 `1:3:7:1`（包含了就可以不挂）。
          - 没在解码器 sink 上挂 probe 改 caps（LIVI 对树莓派的做法）：要在 gst-host 里找到管线和元素，得拦 `gst_parse_launch` 再自己操作 pad，比换一个字符串函数复杂得多。
          - 没把所有不在列表里的色彩参数都映射：只见过 iPhone 这一种；别的车机流以后碰到再加。
- [x] 测通后：主 README 加条目（「无线 CarPlay」一节和目录表）；体检加了一项（10-17 23:55 装上平板，`tools/y700-checklist.py` 的 `check_carplay`）。
  - 查的内容：认证组件在、能通过探测（CarPlay 在用时跳过）；热点 drop-in 挂着 settle；开机保护已启用；色彩修正库是 ELF、启动器里有 `LIVI_GST_PRELOAD`，CarPlay 在用时还看 gst-host 的 `/proc/<pid>/maps` 里有没有加载它；LIVI 不在跑时，热点单元不该开着，NM 的 unmanaged 配置也不该还在。
  - 另外：基线里记 LIVI 版本，变了报 CHANGED；CarPlay 热点开着时，Wi‑Fi 省电那一项改记 INFO（AP 模式本来就没有省电，第一次实跑时误报过 WARN）。
  - 平板实跑：CarPlay 在用时打出 `OK CarPlay 就绪…（CarPlay 正在用，跳过芯片探测；实测自恢复定时器还挂着…）`。不在用时那条探测分支见下一条。
  - 已知：`tools/y700-checklist-selftest.py` 有 3 个场景失败（S7、S11、S11f）。改之前的版本也是同样 3 个：自测没跟上 10-16/17 加的刷新率守护和音量键检查，和这次无关，留作待办。
- [x] **帧率与刷新率（10-18 00:00–00:25，作者的 iPhone）**。现象：看着只有 30 帧，面板刷新率 120 Hz 没跟着降。
  - **实测**：gst-host.log 每 5 秒一行 `[cp_screen] recv 0x7a000001: in=N …`，N 就是这 5 秒收到的帧数。改之前一直是 150–152，即 **30 帧/秒**，画面静止时也一样。面板一直 120 Hz：刷新率守护 `y700-refresh-auto`（`linux/display/refresh-auto/`）只认会写播放状态文件的播放器（wiliwili、mpv），不认 LIVI。
  - **查 LIVI 源码**（github f-io/LIVI，tag v9.4.0）：LIVI 已经在 /info 里给每块屏报 `maxFPS`，主屏取 `projectionFps`（60），见 `native/livi-helperd/crates/livi-cp/src/info.rs`。在平板的二进制里 grep 不到 `maxFPS`，是因为短字符串被编进了指令立即数，不是没报。真正的原因在 `bin/livi-core/src/carplay.rs` 的 `cluster_displayed`：`dashboards` 里 **dash3、dash4（LIVI 的仪表盘页，源码注释原话是 cluster dashboards）** 只要有一个开着，LIVI 就多报一块 1280×720 的仪表盘屏，iPhone 建两路视频（日志里有 `SETUP screen NATIVE (cluster…)` 和 `(main…)` 两行）。LIVI 的默认配置里这两页是开着的。
  - **修法一：关掉 dash3/dash4**（10-18 00:09，LIVI 不在跑时改的 `~/.config/LIVI/config.json`，只改 `dashboards`，原件备份为同目录 `config.json.bak-20261018-fps`）。00:10 重开后只建了主屏一路。帧数每 5 秒 285–301，即 **57–60 帧/秒**；静止时回落到 30 左右。iPhone 是按画面变化出帧的，这是它的正常行为。代价是 LIVI 里少了两页仪表盘（显示 iPhone 仪表盘画面的那两页），这台平板只当主屏用，用不上。`install-livi.sh` 新建配置时直接写成关；配置已存在时不改，开着的话会打 NOTE。体检里开着就报 WARN。
  - **修法二：刷新率跟随**。启动器起 LIVI 后，等 livi-compositor（LIVI 在 KWin 里的窗口就是它）出现，在 `$XDG_RUNTIME_DIR/y700-video/livi-<pid>` 写一份和 mpv 脚本同格式的播放状态（`playing=1 fullscreen=1 fps=60`）。刷新率守护见到全屏窗口的 pid 对得上，就把面板降到 60 Hz。触摸后 3 秒内回 120，这是守护对所有播放器的规矩。LIVI 退出时 pid 没了，守护自己删文件、回 120。实测：00:04 手写文件，面板 120→60；00:10 起由启动器写，`cur_hz 60`、`video_target 60`。
    - 为什么报 60 不报 30：iPhone 动起来就是 60 帧。画面静止时的 30 帧和面板不同步，30 Hz 下晚到一点的帧会错过刷新，被下一帧顶掉；60 Hz 下每帧显示两次，有余量。
    - **作者确认 60 Hz 下滑动是顺的，保持这样**（10-18，看过 00:10–00:25 那次）。以后若觉得卡，回 120 的办法是：删掉启动器里的 `refresh_follow &` 这一行。
  - **收尾验证**（00:25 自恢复定时器结束 CarPlay 后）：状态文件已被守护删掉，`cur_hz` 回到 120，Wi‑Fi 回到 HOME_6G。随后在平板上把整套 `install-livi.sh` 重跑了一遍（00:26）：启动器和仓库逐字节相同，修正库重编 0644，avahi 停着，体检空闲分支 `OK CarPlay 就绪：…探测通过…`。
  - **顺手发现**：10-17 收拾测试残留时，把原样备份 `livi-preinstall-20261017.tgz` 也挪进了归档目录。安装脚本找不到它，又打了一份 `livi-preinstall-20261018.tgz`，可那时已经是装过 LIVI 之后的状态。00:27 已把原样那份放回 `/root/`；新的那份改名为 `livi-state-after-install-20261018-0026.tgz`，留在 `/root/carplay-tests-20261017/`。
  - **有意没做**：
    - 没改 LIVI，理由同上。若作者以后要仪表盘页，就得在「仪表盘页」和「60 帧」之间选一个。另一条路是请上游让「仪表盘页开着但不向手机报 cluster 屏」可配置，那要发 issue，得作者同意。
    - 每次运行只写一次状态文件：LIVI 自己重启合成器的话，新合成器没有文件，面板留在 120（安全的一边）。不为这个常驻轮询。
    - 没跟踪「CarPlay 画面是否真在放」：LIVI 全屏就当 60 Hz。LIVI 自己的界面多是静止的，内核的空闲刷新本来也会降。
    - LIVI 每次启动都会把 `config.json` 重写成 0664（里面有热点口令），安装脚本设的 0600 留不住。平板只有一个本地用户，没为它包一层 umask。
  - **体检同时按两份审查改了**（10-18）：
    - gst-host 是否挂了色彩修正库，改看 `/proc/<pid>/maps` 里有没有这个 .so。原来看 environ 的子串，启动器 export 的 `LIVI_GST_PRELOAD` 变量本身就会命中，LIVI 升级后口子没了也会报假 OK。
    - LIVI 版本变了的 CHANGED 提示，先列出写死 `/opt/livi-9.4.0` 的几处（install-livi.sh 的 `LIVI=`、启动器和 test-guard.sh 的 `CORE/HELPER`、desktop 文件的 `Icon`）。
    - 认证组件那一项：缺失和出错分开报，单项出错不会让整项变成「检查出错」。
    - pidof 出错不再当成 CarPlay 在用。
    - 热点单元在 activating/deactivating（settle 正在重载 ath12k）时，省电和锁死两项只记 INFO。
    - 自测补了 S13l2（热点正在停）、S13p/p2/p3（仪表盘页开/关、口令不出现在输出里、配置读不了）。S13f 改成「有变量、没加载库」。现在只剩原来那 3 个失败。
- [x] **开车时自动变暗、息屏（10-19 实车发现，10-20 修）**。作者反映：用着 CarPlay 屏幕会自己变暗，然后灭掉。
  - **原因**：车上平板用电池（upower `discharging`）。`~/.config/powerdevilrc` 只给 AC 关了闲置变暗和关屏，电池方案没有 `[Battery][Display]` 段，用的是 Plasma 的默认值：闲置先变暗，5 分钟没碰就关屏。自动亮度守护 `y700-autobright` 的日志里，每次 `screen off` 都正好在上一次触摸后约 5 分钟（日志里举两次，都是触摸后 5 分 01 秒）。锁屏本来就关着（`kscreenlockerrc` `Autolock=false`）。按环境光调亮度的 `y700-autobright` 是另一回事，按设计工作，没动。
  - **修法**：启动器里加了 `keep_awake`。iPhone 的画面在来时，用 `kde-inhibit --power --screenSaver` 挂一个阻止：PowerDevil 不变暗、不关屏、不锁屏、不睡眠。手机走了、画面停了，12 秒后放掉。这样停车后 LIVI 忘了关，屏幕照样会灭，不会耗光电池。
    - 「画面在来」的信号：gst-host 每 5 秒往 `~/.config/LIVI/log/gst-host.log` 写一行 `[cp_screen] recv …`，前提是这 5 秒里收到过帧，画面静止时也有。没帧就不写，见 LIVI 源码 `take_stats`。启动器每 12 秒比一次这个文件和一个时间戳文件（`$XDG_RUNTIME_DIR/y700-carplay-frames`）谁新。
    - 被 `kde-inhibit` 包着跑的是启动器自己的隐藏模式 `y700-carplay --while-frames <LIVI pid> <日志> <时间戳>`。它在 12 秒没新帧或 LIVI 退出时返回，`kde-inhibit` 随之退出，阻止就放了，不用 kill。PowerDevil 的电池小部件里显示的阻止者是 `/usr/local/bin/y700-carplay`。
    - 安卓手机（10-20 补）：AA 只在画面变化时发帧，画面静止时 gst-host.log 能几十秒不更新。所以 TCP 5277 上有一条 established 连接（AA 会话）也算手机在，启动器里是 `aa_session`，用一次 `ss`。原因和实测见「无线 Android Auto」。
    - 开销：只在 LIVI 运行期间存在，每 12 秒一次 `sleep` 和一次 `ss`，别的什么都不唤醒。
  - **踩坑**：PowerDevil 收到阻止后要过约 5 秒才生效。第一次 1.5 秒就去查 `HasInhibition(4)`，以为 `kde-inhibit` 和 `org.freedesktop.ScreenSaver.Inhibit` 都不管用。等 7 秒再查，两条路都是 true；调用方的 D-Bus 连接一断，阻止就自动撤掉。
  - **验证（10-20 01:00–01:19，平板用电池，没开 LIVI，用假帧）**：
    - 函数单测：有帧 → `HasInhibition(4)` true；断帧 → 约 8 秒后放掉；再来帧 → 又挂上；假 LIVI 进程结束 → 放掉、循环退出、时间戳文件删掉、没有残留进程。
    - 实效：用一个临时虚拟键盘按一下没绑定的 F24 当作「有人碰了」，把屏幕点亮、重置 PowerDevil 的闲置计时，然后挂着阻止等 6.5 分钟。27 次采样全是 `dpms=On`，背光一直是 1525，越过了原来 5 分钟灭屏的时间点。（D-Bus 的 `SimulateUserActivity` 点不亮屏幕，所以用了按键。）
    - 对照（紧接着，同一次测试）：撤掉阻止、再按一下 F24，然后不碰。约 3.3 分钟时背光从 1525 降到 458（变暗；15 秒一采样），约 6.2 分钟时 `dpms=Off`。也就是说放掉阻止后，平板照常变暗、关屏。
  - **体检**（`check_carplay`）：启动器里没有 `--while-frames` 或没装 `kde-inhibit` → WARN。CarPlay 在用时还查三件事：时间戳超过 30 秒没更新 → 循环没在跑（多半不是从桌面图标起的 LIVI）；画面在来、阻止已挂上 10 秒以上，PowerDevil 却没有 `HasInhibition(4)` → WARN；手机 40 秒没发画面、阻止还挂着 → WARN（停车后屏幕不会灭）。阻止刚挂上不到 10 秒时不判（PowerDevil 要等约 5 秒）。画面在来、阻止还没接上，只记一条备注（刚连上的头十几秒正常）。安卓手机的 AA 会话连着、画面静止时，和「画面在来」一样判（10-20）。自测 S13q–S13q12。
  - **有意没做**：
    - 没改 PowerDevil 的电池方案。平板平时离车时还是要闲置变暗、关屏省电，只在 CarPlay 有画面时挡。
    - 没写常驻守护（Rust 或 Python）。`kde-inhibit` 是 KDE 自带的，启动器里一个 sh 循环就够了，而且只在 LIVI 运行期间存在。
    - 没按「LIVI 在前台」来挡。LIVI 开着、手机不在，挡了就是白耗电。
- [x] **Siri、地图语音听不到（10-19 实车，10-20 修，实测通过）**。作者反映：CarPlay 里叫 Siri、在 Google 地图里用语音（Gemini）都没反应，像是麦克风没被调用。
  - **原因**：上游已查明并修好，见 f-io/LIVI 的 b82707ad（2026-10-14，「fix(cp): Siri over Wi-Fi reaches the phone again」）。它在 9.4.0（c068c6c2，10-11）之后，还没进发布版。
    - 无线 CarPlay 时，iPhone 从链路本地地址（`fe80::…`，要带 `%网卡` 才有意义）连过来。livi-core 把手机地址交给 gst-host 时用的是 `net::host_of`，把 `%网卡` 丢了。
    - gst-host 的 `uplink.rs` 把地址拼成 `"{phone}:{port}"` 字符串发麦克风，发送结果直接丢掉（`let _ = socket.send_to`）。没有网卡号的 fe80 地址，包出不去或从别的网卡出去，iPhone 收不到声音。
    - 不在车上复现（平板上照原样拼字符串，发到一个 fe80 地址）时 `send_to` 返回成功、不报错，包从哪张网卡出去由路由决定。所以看日志有没有报错判断不了，真凭据只能是实测 Siri。
  - **修法**：上游的修复（保留 `%网卡`，`net::route_of`；gst-host 正经解析地址，发送失败记一次日志）原样挑到 v9.4.0 上，干净应用，3 个文件。
    - 在平板上编 `livi-core` 和 `livi-gst-host`，替换 `/opt/livi-9.4.0/resources/` 里的这两个文件。原件留成 `.orig-9.4.0`，`/root/livi-9.4.0-orig/` 里还有一份。
    - 用的是 LIVI 锁定的工具链 Rust 1.100.0-beta.3。rustup 装在 `/root`，系统 rustc 1.93 不动（y700 自己的守护都用它离线编）。
    - 新文件链接的系统库和原版完全一样，体积差不到 1%（livi-core 19.03→19.11 MB）。补丁自带的两个单测通过。
    - 修好后，gst-host 发不出去时会在 `~/.config/LIVI/log/gst-host.log` 记一行 `[cp_mic:…] cannot send to …`（只记一次）。
    - 整套写成 `livi/build-livi-siri.sh`（补丁 `livi/livi-b82707ad-siri-over-wifi.patch`，GPL-3.0），`--restore` 换回原版。`install-livi.sh` 最后一步发现还是原版时打 NOTE，不自动编（要下载工具链和源码）。10-23 换 10.0.0 后这些都删了（公开仓库里没有）。
  - **踩坑**：LIVI 的 crate 用 `include_str!` 引了 `native/` 外的文件（`src/main/shared/assets/icon-*.b64`、`scripts/livi-link/common/rootfs/etc/hostapd.conf`），只取 `native/` 编不过，稀疏拉取要带上这两个目录。
  - **体检**：两个文件还是 9.4.0 原版（按 sha256，`LIVI_940_STOCK`）→ WARN，提示跑 `build-livi-siri.sh`。自测 S13r–S13r3。10-23 连同自测一起删了，原因见下一条。
  - **上游巡检**（`tools/upstream-check.py`）加了 f-io/LIVI。新加的 `releases` 键让兄弟项目也盯 GitHub 发布，新发布必通知；提交只报修复类和麦克风、热点相关的（`feat(cp)` 几乎天天有，不报）。测试 `sibling-releases`。
  - **周期性义务**（巡检会提醒）：
    - [x] LIVI 出了含 b82707ad 的新版 → 换版（照体检的 CHANGED 提示改写死的 `/opt/livi-9.4.0`）；删掉 `build-livi-siri.sh`、补丁文件、体检里的 `LIVI_940_STOCK` 和 `install-livi.sh` 第 8 步。10-23 换成 10.0.0，原版的 Siri 实测可用（见「换版 LIVI 10.0.0」的 e），这几样都删了。
      - **有意不留检查**：体检不再查 Siri。回 9.4.0 要照「回滚到 9.4.0」主动做，那时 `/opt/livi-9.4.0` 里还是自编的两个文件；LIVI 换了版本，体检的 CHANGED 那一项会报。
      - 平板上编译剩下的东西 10-23 经作者同意删了：`/root/src-livi-9.4.0`（1.3 GB）、`/root/.rustup`（527 MB，那套 beta 工具链）、`/root/.cargo/bin` 和 `env`（rustup 的入口），还有 `/root/.cargo/registry/src`（601 MB，解压出来的源码，cargo 会从压缩包重新解开），根分区 96 → 94 GB。**留着** `/root/.cargo/registry/cache` 和 `index`（约 140 MB）：fcitx5-osk 也用系统 cargo 从 crates.io 编，这份缓存 10-11 就有了。删完核对过：fcitx5-osk 在 aarch64 上的 467 个依赖（normal 加 build，`cargo tree --offline`）压缩包都在缓存里，离线还能编。系统的 `/usr/bin/cargo` 1.93 不受影响。回滚要用的 `/opt/livi-9.4.0` 自编文件、`.orig-9.4.0` 和 `/root/livi-9.4.0-orig/`（20 MB）都留着。
  - **有意没做**：
    - 没用 LD_PRELOAD 垫片给发送补网卡号（写过草稿）。作者选了直接用上游代码：上游的修法连「发送失败不报错」也一起修了，换上新版后这份改动自然消失。
    - 没重编 `livi-helperd` 和 `livi-compositor`，修复不涉及它们，9.4.0 原件不动。
  - **验证**：
    - 实测（10-20 01:36–01:40，iPhone）：Siri 和地图语音都能收到麦克风的声音了。
      - LIVI 日志：两次 `CarPlay Siri active`（01:36:37–51、01:36:59–01:37:11），每次都按 `audioType=speechRecognition` 建了麦克风流。gst-host.log 里没有 `cannot send to`。
      - 平板上 `/root/carplay-tests-20261017/siri-watch.sh` 每 2 秒记一次 UDP 发包增量和 PipeWire 的录音流（不存音频；结果在同目录 `siri-watch.out`）。麦克风开着的 49 次采样，平均每 2 秒发 97 个 IPv6 UDP 包，约 50 包/秒，对得上 20 ms 一包；其余 252 次平均 2.6 个。麦克风开着时，PipeWire 里是 `livi-gst-host` 的「Record Stream」。
      - 测之前单独录过 3 秒平板麦克风，只算音量、不存音频：有底噪和峰值（rms 44、峰值 1098），不是全零，说明硬件这头本来就是好的。
    - 脚本（01:47–01:51，LIVI 不在跑）：
      - `build-livi-siri.sh` 从零跑通：稀疏拉取、核对提交号、打补丁、编译约 1 分钟、两个单测、安装。编出来的两个文件和实测时用的**逐字节相同**（sha256 `f2445c0d…`、`c4133fdf…`），所以装上的就是测过的那份。
      - `--restore` 换回原版，再跑一遍是「already 9.4.0's」。原版状态下重跑，会把原件备份后装上新编的。
      - 故意改坏 gst-host、挪走它的备份后，`--restore` 和安装都拒绝（rc=1），而且 livi-core 没被动过。第一版脚本是逐个文件边查边换的，这种情况下会先把 livi-core 换掉，已改成两个文件都查完再动手。`--restore` 改用 `cp -p`，保留原件的日期。
    - 体检装上平板：两个文件是新编的 → `OK CarPlay 就绪：…保持亮屏、Siri 修复都在`；临时换回原版 → `WARN …还是 9.4.0 原版…`，换回新编的又是 OK。`install-livi.sh` 第 8 步对新编和原版两种文件各试过一次，提示都对。

- [x] **无线 Android Auto（10-20 打开，空跑通过，用安卓手机实测两次）**。要求：同一个桌面图标、同一个 LIVI 同时支持无线 AA。测试用的是一台安卓手机。第一次实测能用但糊；改了投屏分辨率后第二次清晰多了。
  - **做法**：LIVI 9.4.0 本身支持无线 AA，不用 MFi 认证组件，只要打开 config.json 的 `wirelessAaEnabled`（LIVI 默认是关的）。打开后 LIVI 多做三件事（`livi-helperd/src/linux_main.rs`）：
    - 注册 AA 的 RFCOMM profile（UUID `4de17a00-52cb-11e6-bdf4-0800200c9a66`）；
    - 发一个 BLE 广播；
    - 在 TCP 5277 上等手机。

    热点、蓝牙名、热点口令都和 CarPlay 共用。安卓手机这边的流程：蓝牙配对「Y700 CarPlay」，经 RFCOMM 拿到热点信息，连上热点，再连 10.10.0.1:5277。
    - 平板上已经打开（10-20 02:29）。`install-livi.sh` 新建配置时会打开；已有的配置不改，AA 关着时打 NOTE。
    - 帧率：`projectionFps` 是 60（LIVI 的默认值）时，LIVI 向手机要 60 帧，否则要 30（`livi-aa-stack/src/config.rs`）。AA 只在画面变化时发帧，静止时一帧都不发。
    - **分辨率（第一次实测后改）**。LIVI 怎么选档（`livi-aa-stack/src/config.rs` 的 `fitting_tier`）：
      - AA 的档是 800×480、1280×720、1920×1080、2560×1440、3840×2160，从小往大试。每档先按投屏的比例裁出一块区域，这块区域放大到投屏尺寸不超过 1.2 倍（`MAX_TIER_UPSCALE`）就取这一档。手机只给 H.264 时最高到 1080p 档。
      - dpi 用 `projectionDpi`；是 0 就按档插值（720p 180、1080p 200）。
      - 原来的 1152×720 拿到 1280×720 档（裁出 1152×720），到面板上被放大约 2.6 倍（1152 → 窗口的 1600 逻辑像素，KWin 再乘 1.9），看着模糊。
      - 现在投屏是 1600×1000，接近窗口的逻辑尺寸 1600×1002。1280×720 档要放大 1.39 倍，超了，取 1920×1080 档（裁出 1728×1080）。日志是 `display 1600x1000 -> AA tier 1920x1080 @270dpi`。
      - `projectionDpi` 设 270。1080 像素 ÷ 270 dpi 和 720 像素 ÷ 180 dpi 都是 640 dp 高，所以 AA 的按钮和字和原来一样大。设 0 就是 200 dpi（864 dp 高），东西会小四分之一。
        - **10-23 起改回 0**：10.0.0 也用它算 CarPlay 屏幕的物理尺寸，270 让 iPhone 的界面大一号（见「换版 LIVI 10.0.0」踩坑七）。于是 AA 的 1080p 档回到 LIVI 的 200 dpi，按上面的算法东西小四分之一。AA 在 10.0.0 下还没试过（作者说安卓先放着），试的时候看字和按钮的大小。
      - iPhone 也跟着按 1600×1000 出图，作者看过没问题。9.4.0 的 CarPlay 直接用投屏尺寸，不看 `projectionDpi`（10.0.0 起要看，见上）。
      - 只改了 config.json，没改 LIVI。平板上是第二次实测前改的。`install-livi.sh` 新建配置时写这三项；已有的配置这三项不对时打 NOTE。
    - **保持亮屏（第一次实测后改）**。AA 的画面经 core 的 feed socket 送到 gst-host，每 5 秒往 gst-host.log 写一行 `[feed] recv`，和 iPhone 的 `[cp_screen] recv` 一样会更新这个文件。但画面静止时 AA 不发帧：第一次实测最长 27 秒没有一帧，`keep_awake` 12 秒没见新帧就放掉了阻止，空了约 25 秒。
      - 修法：没帧、但 TCP 5277 上有一条 established 连接（AA 会话）也算手机在，启动器里是 `aa_session`（一次 `ss`）。手机走后，LIVI 约 6 秒 ping 超时、断开会话，之后最多再过 12 秒放掉阻止。
      - 平板上用假会话测过：本机连一条 127.0.0.1:5277，帧文件 10 分钟前的。会话 40 秒时关掉，`--while-frames` 在第 48 秒返回；没有会话时第 12 秒返回。第二次实测里阻止一直挂着（见下）。
      - **再更正**：早先一版写过「不改的话 AA 开着照样会变暗」，后来一版读了启动器，把这句当错话删了。实测说明它对了一半：画面在动时挡得住，静止时挡不住。
    - 体检：
      - config.json 读得出来、`wirelessAaEnabled` 却不是 true → WARN（自测 S13p4、S13p5）。读不出来不判（S13p6、S13p3）。
      - 投屏不是 1600×1000、270 dpi → WARN，报出现在的值（S13p7–S13p9；键不在时写「默认」）。10-23 起要的是 1600×1000、dpi 0（键不在也算 0），270 → WARN「大一号」（S13p8、S13p8b）。
      - AA 会话连着、画面静止时，按「手机在」判保持亮屏（S13q11、S13q12）。
      - OK 那行末尾写「无线 Android Auto 开着」。
    - 桌面图标的说明改成「无线 CarPlay 和 Android Auto」，图标名仍是 CarPlay。
  - **空跑（10-20 02:43，`livi/dryrun-wireless.sh`，没有手机）**。第 40 秒时：
    - 蓝牙：网卡名是「Y700 CarPlay」，可发现，BLE 广播 1 个，AA 的 UUID 在；
    - TCP 5277 在听；
    - 热点：`AP up — ssid=Y700 CarPlay ip=10.10.0.1 channel=36 (5180 MHz) width=80MHz 802.11ax`，wlp1s0 是 AP；
    - 日志：`[hfp] HF profile registered`、`[aa] profile registered (RFCOMM ch 8)`、`[aa] BLE advertisement registered`。

    60 秒后 TERM，guard 跑 restore：NM 重新连上家里的 Wi‑Fi，蓝牙名、可发现、广播都回到原样，没有残留进程，体检 OK。
    - HFP 不会出现在网卡的 UUID 列表里，这是正常的。LIVI 的 HF profile 是 `Role=client`（平板主动去连手机），BlueZ 不给 client 角色发布 SDP 记录。凭据是日志里的 `[hfp] HF profile registered`。
  - **踩坑：从 root 经 sudo 起 LIVI，热点起不来**。
    - 现象：第一次空跑（02:36）时热点单元是 active，wlp1s0 却还连着家里的 Wi‑Fi。journal 里 hostapd 在开 `wlan0`（40 MHz），一直报 No such device。
    - 根因：
      - livi-core 每次启动都按模板 `/opt/livi-9.4.0/resources/livi-wifi-ap.service.template` 重写 `/etc/systemd/system/livi-wifi-ap.service`，把用户写进 `Environment=SUDO_USER=`。这个用户取自环境变量 `SUDO_USER`，没有时才取进程自己的用户（`livi-core/src/privileged.rs` 的 `username`）。
      - 空跑脚本是 root 用 `sudo -u user` 起的 LIVI。sudo 会带上 `SUDO_USER=root`，单元就被写成了 root。
      - 热点的 helperd 按这个用户去找 `/root/.config/LIVI/config.json`（`linux_main.rs` 的 `config_path`），找不到，就全用默认值。
    - 修法：两个空跑脚本起 LIVI 时去掉 `SUDO_*` 变量（`sudo -u user env -u SUDO_USER …`）。平板上的单元按模板改回 user，diff 只有这一行。从桌面图标起的 LIVI 没有这个变量，本来就是对的，而且它下次启动时也会把单元改回来。
    - 体检：单元里写的用户不是 user → WARN（S13l3）；没有单元不判（S13l4）。
    - 连带发现：不带无线的 `dryrun.sh` 原来只关 `wirelessCpEnabled`。打开 AA 以后，LIVI 照样会起热点、拿走 Wi‑Fi，在 ssh 下跑就会断。已改成两个开关都关，跑完按原值放回。在平板上用临时文件试了两种情况（两个都开、只开 CarPlay），值和键的顺序都原样回来了。
    - 第一次空跑还在开跑前就卡住了：`btmgmt` 没有终端时不会返回。现在所有查询都加了 `timeout` 和 `</dev/null`。
  - **两次实测怎么记的**：开测前 `test-guard.sh arm`；平板上一个临时脚本（`/root/carplay-tests-20261017/aa-watch.sh`，不进仓库，同 siri-watch.sh）用 systemd-run 在后台跑，LIVI 在时每 2 秒记一行：热点客户端数、5277 上的会话数、蓝牙连着的设备、gst-host 的 CPU、gst-host.log 多久没更新、`HasInhibition(4)`、背光。LIVI 退出后，把 LIVI.log、gst-host.log、启动器日志和热点、蓝牙的 journal 过一遍口令过滤，拷到同目录（root 0700）。
  - **第一次实测（10-20 02:50–02:53，投屏还是 1152×720）**：
    - 配对「Y700 CarPlay」→ 手机自己连上热点 → 出画面，一次成功。
    - 手机选 H.265，`v4l2h265dec (hw)` 硬解，解出 1280×720，没有 not-negotiated。作者只提了糊和帧数，没提颜色，所以色彩修正库没为安卓加映射。
    - 会话 93 秒（02:50:58–02:52:31，最后是手机那头走了、ping 超时），1156 帧，音频包 0 个。5 秒最多 275 帧（55 帧/秒）。
    - gst-host CPU 平均 9%、最高 44%（单核，2 秒一采样）。
    - 问题一：糊，原因和改法见上面「分辨率」。
    - 问题二：画面静止时最长 28 秒没帧，保持亮屏断断续续（会话期间 20 次采样是 false，含刚连上的几秒），原因和改法见上面「保持亮屏」。
    - 帧数看着也不够高。按日志，LIVI 要的是 60，手机动起来能给到 55；静止时不发帧，看着就像掉帧。第二次没再提。
  - **第二次实测（10-20 03:01–03:06，投屏 1600×1000、270 dpi，启动器带 `aa_session`）**，各项都试过，清晰多了：
    - AA：日志是 `AA tier 1920x1080 @270dpi`，H.265 硬解出 1920×1080，不丢帧。滑动时 5 秒最多 260 帧（约 52 帧/秒，分辨率高了，帧率基本没掉）。第一个会话 166 秒、3565 帧、音频包 2375 个。
    - 保持亮屏：会话期间 gst-host.log 最长 29 秒没更新，阻止一直挂着。`HasInhibition(4)` 只在刚连上的 4 秒里是 false（PowerDevil 要约 5 秒才生效），背光一直没动。
    - gst-host CPU：AA 平均 24%、中位 18%、最高 77%；之后 iPhone 那段平均 15%、最高 57%。
    - iPhone：解出 1600×1000，5 秒最多 215 帧。
    - **换手机要等约 40 秒**。03:04:24 安卓手机的蓝牙那头断了（推测是作者在换 iPhone 测）。之后安卓手机又重连了两次，每次 LIVI 都丢掉旧会话（`wireless reconnect … dropping the superseded session`）。第三次卡在 INIT，30 秒后被 LIVI 自己的看门狗收掉（`pre-RUNNING watchdog`）。这期间 LIVI 回连 iPhone 一直报 `br-connection-busy`；看门狗收掉 5 秒后 iPhone 连上（03:05:08）。
    - 日志在平板 `/root/carplay-tests-20261017/aa2-1600x1000/`，第一次的在同级的 `aa-20261020/`。
  - **有意没做**：
    - 有线 AA：`install-livi.sh` 删掉的 Android 厂商 udev 行不加回来，因为它们会全系统关掉这些品牌手机的 MTP 和自动挂载。车上用无线。
    - 没给 AA 改名：蓝牙名和热点名仍是 LIVI 配置里的「Y700 CarPlay」，作者没要求改。
    - 没改 LIVI：全是它自带的功能，只改了配置（一个开关、三个投屏值）。
    - 没要更高的 2560×1440 档。LIVI 的窗口按 1600×1002 出图（`mainScreenWidth/Height`），1080p 档裁出的 1728×1080 已经比它大，再多的像素应该到不了面板（推断，没量过合成器怎么缩放）。手机编码和平板解码的负担还会更大。
    - 没给 AA 和 CarPlay 分开设分辨率：LIVI 两者共用 `projectionWidth/Height`，要分开就得改 LIVI。iPhone 在 1600×1000 下作者看过没问题。
    - 换手机等约 40 秒的事没处理：这是 LIVI 自己的重连和看门狗，车上一般只有一台手机。
    - 国产协议（CarLife+、亿连、ICCOA Carlink）不考虑：车机端都是闭源授权 SDK，没有 Linux 版，LIVI 也不支持。
  - **待验证**：
    - [x] 安卓手机实测：配对 → 自动连热点 → 出画面（10-20 两次，见上）。
    - [x] 安卓手机连着时屏幕不变暗（第二次实测，改了 `aa_session` 之后）。
    - [x] AA 打开后 iPhone 的无线 CarPlay 能连上、出画面（第二次实测，1600×1000）。
    - [x] AA 打开、投屏 1600×1000 以后，iPhone 的 60 帧和 Siri：10-23 在 10.0.0 下测了，滑动时 5 秒 300 帧，Siri 用了三次（见「换版 LIVI 10.0.0」的实测）。
    - [x] AA 的声音：第二次实测有 2375 个音频包，AA 的声音正常（10-20）。
    - [ ] 安卓手机打电话没测（作者说 CarPlay 电话用得极少，同理不急）。
    - [ ] iPhone 的 CarPlay 电话：10-19 实车那次的日志里出现「call Active」时没看到电话音频流，值得查（同样不急）。

- [x] **换版 LIVI 10.0.0（10-23 完成：iPhone 实测通过，修了五处问题，地图语音作者确认没问题；无线 AA 作者说先放着，没测）**。10.0.0（tag `91f7ced80c6a`，10-22 发布）含 Siri 修复 b82707ad，照上面「Siri」一节的周期性义务换版。
  - **下载**：官方 `LIVI-10.0.0-linux-arm64.AppImage`（112 MB，sha256 `9ddce395…8911`，和发布页的 digest 一致），10-23 下载（不进仓库）。为了读源码，还在 PC 的临时目录稀疏拉了一份 v10.0.0（只读，不进仓库）。
  - **10.0.0 里和我们有关的变化**（读源码核对过）：
    - 界面从 Electron 换成 Slint（80f4b1b7）。AppImage 根目录现在是 sh 脚本 `LIVI`（`exec resources/core/livi-core`）、`livi-ui` 和 `livi.png`，`/opt/livi/livi` 没有了。启动器改起 `/opt/livi/LIVI`；脚本 exec 成 livi-core，所以启动器里的 `$pid` 就是 livi-core。窗口的 app_id 仍是 `dev.f-io.livi`；`kiosk.main` 和设置里的 Power Off（只退出 LIVI）照旧。
    - 双向认证 MFi4（66b79fe0）：芯片报协议 3 时，CarPlayStartSession 里声明 `supports_mutual_authentication`；iPhone 带 `X-Apple-AT: 0x20` 来时走新流程。它对芯片只用 `certificate()` 和对 sha256 摘要的 64 字节签名。没在真机上跑过之前不算数，见下面「待验证」。
    - 新增文件形式的 MFi 认证材料（`~/.config/LIVI/mfi/` 目录）。**这次不用**，继续走 I²C 总线 99。没有这个目录时，helper 不会打 `MFi from the imported files` 那行。
    - 不变的：`LIVI_GST_SINK`、`LIVI_GST_PRELOAD`、色彩修正库改的那段解析、config.json 的键、I²C 读写方式、热点（wifi_ap）、sudoers/udev/热点单元的模板、`LIVI_NO_UI`/`LIVI_NO_COMPOSITOR`、gst-host 的日志行和位置。helper 仍然只在 AppImage 挂载点内才复制到 `~/.config/LIVI/driver/`，所以 sudoers 照旧指向 `/opt` 里 root 所有的那份。
  - **改了的写死路径**：`install-livi.sh` 的 `LIVI=`，启动器的 `LIVI`/`CORE`/`HELPER`，`test-guard.sh` 的 `CORE`/`HELPER`，`dryrun-wireless.sh` 的 `CORE`，desktop 文件的 `Icon`（`/opt/livi-10.0.0/livi.png`）。体检的 CHANGED 提示同步列出这几处（加上了 dryrun-wireless.sh）。
  - **踩坑一：AppImage 里的目录是 0700**。FUSE 挂载时归运行的人所有，所以没事；以 root 解出来以后，16 个目录里 15 个是 root 0700，user 进不了 `resources/`，点图标什么都起不来。9.4.0 的 24 个目录都是 0755。`install-livi.sh` 加了第 0 步：把目录统一改成 0755（文件本来就是 0644/0755，没有 setuid）；有任何文件或目录不归 root、或者组和别人可写，就拒绝安装；最后确认 user 能执行 livi-core。
  - **踩坑二：`dryrun.sh` 在 10.0.0 下会让 bluetoothd 重启两次**。10.0.0 的 helper 按两个无线开关调整 bluetoothd（`livi-runtime/src/bluetoothd.rs`）：都关时，撤掉自己的 `--noplugin` drop-in，把车载 Class 从 main.conf 拿掉，重启 bluetoothd；下次开着无线启动时再放回去，再重启一次。所有蓝牙设备会断两次。所以 `dryrun.sh` 现在要带 `Y700_BT_RESTART_OK=1` 才跑（先告诉作者）。换版的空跑改用 `dryrun-wireless.sh`：开关保持开着，平板上的 drop-in 和 Class 和 10.0.0 要的逐字相同，所以不重启（空跑后 bluetoothd 的启动时间仍是 10-22 13:29）；代价是 Wi‑Fi 被拿走约 2 分钟。10.0.0 第一次运行写了 `/var/lib/livi/main-conf-class`（记 LIVI 改之前的 Class；这里是空文件）。
  - **踩坑三：平板上的源码副本是旧的**。`/root/src-carplay-livi/` 里的 ap-settle、ps-restore、热点 drop-in 和 test-ap-settle.sh 都不是仓库版。装着的 `/usr/local/sbin/y700-carplay-ap-settle` 也退回了 10-19 审计之前的版本，多半是 10-20 从这份旧副本跑过 install-livi.sh。这次先把仓库的 `linux/carplay/livi/` 整个传上去、逐个核对 sha256，再装；旧副本留成 `/root/src-carplay-livi.bak-9.4.0`。**以后跑 install-livi.sh 之前，先把整个目录从仓库同步过去。**
  - **平板上的步骤（10-23 00:15–00:20）**：
    1. AppImage 传到 `/root/livi-10.0.0-dl/`，核对 sha256，`--appimage-extract` 解到一个新建的临时目录，chown root 后 mv 成 `/opt/livi-10.0.0`（294 MB）。五个二进制 `ldd` 都不缺库。`/opt/livi-9.4.0`（620 MB，含 Siri 自编的两个文件）留着回滚用。
    2. 仓库目录同步到 `/root/src-carplay-livi/`（见踩坑三）。
    3. 确认 LIVI 不在跑，`ln -sfn livi-10.0.0 /opt/livi`，跑 `install-livi.sh`。结果：改了 15 个目录的权限；sudoers 和原来比只差路径（`visudo -c` 通过，`sudo -l -U user` 列出新路径；原来那份留成 `/root/99-LIVI-helper.9.4.0`）；udev 规则仍是 `LIVI-RULE-VERSION=6`，触屏过滤脚本和 10.0.0 自带的逐字节相同；色彩修正库重编；启动器、ap-settle 和两个 desktop 文件都和仓库逐字节相同。
    4. 体检只多了一条 `CHANGED LIVI livi-9.4.0 -> livi-10.0.0`。
  - **无线空跑（10-23 00:21–00:23，`dryrun-wireless.sh`）**：
    - 认证组件：`opening MFi bus=99 gpio=-1` → `MFi addr=0x10`。
    - 第一次开着无线启动时，livi-core 按自己的 helper 重装了热点那三样：`/usr/local/sbin/livi-helperd` 换成 10.0.0 的，`/etc/sudoers.d/99-LIVI-wifi-ap` 和热点单元按 10.0.0 的模板重写。时间都是 00:21:28，在起热点之前。
    - 热点：ap-settle 重载 ath12k 用了 1.6 s，`AP up — ssid=Y700 CarPlay … channel=36 (5180 MHz) width=80MHz 802.11ax`，wlp1s0 是 AP。
    - 蓝牙：`[hfp] HF profile registered`、`[aa] profile registered (RFCOMM ch 8)`、`[aa] BLE advertisement registered`。网卡名是「Y700 CarPlay」，可发现，广播 1 个，AA 的 UUID 在。TCP 5277 在听。bluetoothd 没有重启。
    - 退出：guard restore 之后没有残留进程，热点单元 inactive，NM 的 unmanaged 配置撤了，Wi‑Fi 回到 HOME_6G，`removed 5 Wi-Fi profile copies`；`ps-restore` 把省电开回 on（`journalctl -t y700-carplay`）。体检 CarPlay 一项 OK。
    - **意外：作者的 iPhone 被叫过来了**。蓝牙这一步的芯片认证过了（`bt: MFi auth succeeded`，这是蓝牙 iAP2 上的认证，不是 MFi4），但 CarPlay 没起来，见下一条。它在蓝牙上挂了 58 秒，LIVI 退出时断开。
  - **发现并修了：iPhone 应答太快时 CarPlay 起不来**（9.4.0 也一样，只是以前没碰上）。
    - 时间线（毫秒，来自启动器日志和 journal）：28.36 helper 的蓝牙就绪 → 29.40 LIVI 呼叫 iPhone（它的重连循环只要热点网卡上有 fe80 就呼叫；这时 wlp1s0 还是连家里 Wi‑Fi 的站点，也有 fe80）→ 29.59 起热点单元 → 30.48 ap-settle 等到 wpa_supplicant 放手，卸载 ath12k，wlp1s0 消失约 1.6 s → 30.51 iPhone 连上 → 30.95 认证通过 → 31.03 iPhone 要 CarPlay，日志 `CarPlayStartSession not sent: no link-local on "wlp1s0"`。
    - 根因（`livi-runtime/src/bringup.rs`）：`wait_for_ap` 本来会等热点最多 30 s，但网卡不存在时直接返回，不等。于是不发 CarPlayStartSession，蓝牙会话却一直挂着。重连循环看到这台手机「连着、有会话」（`link_active`），不会断开重来；它的「connected but no session」只管没有会话的手机。「再发一次 start」（`start_again`）只有有线才有。结果是蓝牙挂着、CarPlay 永远不来，直到手机自己断开蓝牙。9.4.0 的这几段代码一样；以前实测时 iPhone 7 秒后才应答，那时热点早就起来了。
    - 修法：启动器加了 `unstick`。LIVI 运行期间，它用 `tail --pid -F` 读启动器日志（inotify，日志不写就不醒；LIVI 退出它就退出）。见到蓝牙那条 `bt bring-up failed: no link-local on "wlp1s0"`，就等热点真的起来（`iw` 报 AP、有 fe80，最多 30 s），然后 `bluetoothctl disconnect` 那台手机。LIVI 的重连循环几秒内会再呼叫它，这一次热点在，start 就发出去了。以下情况不动：这期间已经发出了 start；手机自己断了蓝牙；没见到是哪台手机；有线 iPhone（失败行里是 USB 网卡名）；这次运行已经断过 3 次。user 可以直接经 BlueZ 断开设备，不用 sudo（平板上试过）。
    - 测试：`livi/test-unstick.sh`，7 种情形，在 PC 的 Git Bash 和平板上（dash、uutils 的 tail）都全过。真机上要等 iPhone 实测时碰上才看得到，日志是 `[y700-carplay] unstick: …`。
    - **有意没做**：没改 ap-settle 的重载，那是热点能用的前提（见第 10 步「问题二」）。没在启动器里提前重载固件：NM 还管着网卡时重载，站点会马上连回去。没改 LIVI。上游可以让 `wait_for_ap` 在网卡暂时不在时也等，但发 issue 要作者同意。
  - **iPhone 实测（10-23 00:43–01:33，五次）**。
    - 怎么记的：每次开测前 `test-guard.sh arm 30`；一个临时脚本（`/root/carplay-tests-20261017/cp10-watch.sh`，不进仓库，同 aa-watch.sh）用 systemd-run 在后台跑，每 2 秒记热点客户端数、5277 会话、蓝牙连着的设备、gst-host 的 CPU、gst-host.log 多久没更新、`HasInhibition(4)`、背光；LIVI 退出后把 LIVI.log、gst-host.log、compositor.log、启动器日志和热点、蓝牙的 journal 过口令过滤，拷到 `/root/carplay-tests-20261017/livi10-20261023{,b,c,d,e}/`（root 0700）。
    - CarPlay 期间 wlp1s0 是热点、Tailscale 断着，进平板走 USB 网络（`root@192.168.7.2`，作者插了线）。前两根线不通，第三根才行。
    - 经过（字母是上面的目录）：

      | 次 | 时间 | 现象 | 原因、改法 |
      |---|---|---|---|
      | a | 00:43–00:55 | 连上了，屏幕全黑 | 踩坑四 |
      | b | 00:56–01:05 | 有画面，但窗口带标题栏、Dock 被切掉；只有 30 帧；界面大一号 | 踩坑五、六（大一号当时没认出来） |
      | c | 01:10–01:15 | 全屏、60 帧；作者说分辨率还是不对、Dock 两头多了空调 | 踩坑七、八 |
      | d | 01:18–01:22 | 改完配置后第一次，没出画面 | 见下面「只碰到一次」 |
      | e | 01:22–01:33 | 全对，作者滑了一阵、用了 Siri | — |

  - **踩坑四：黑屏，10.0.0 自带的 libwayland-client 太旧**。
    - 10.0.0 的 GStreamer 带着自己的 `libwayland-client.so.0`（1.23），经 RUNPATH 先被找到。系统 Mesa 的 `libEGL_mesa` 要 1.24 才有的 `wl_fixes_interface`，加载失败。GL 元件拿不到 EGLDisplay，启动器给的 `glupload ! glcolorconvert ! gldownload ! waylandsink` 一开始就停了。解码其实在跑（`decoder=v4l2h265dec (hw)`，帧也在收），只是画不出来。
    - 修法：启动器的 `LIVI_GST_PRELOAD` 里再加上系统的 `/usr/lib/aarch64-linux-gnu/libwayland-client.so.0`。它先加载，soname 相同，自带的那份就不会再加载。b 之后的启动器日志都是这一行。
    - 体检：启动器里没有 `libwayland-client` → WARN；LIVI 在跑时，gst-host 映射了 `/usr/lib/` 以外的 `libwayland-client` → WARN（S13n3–S13n10）。
  - **踩坑五：窗口不全屏**。
    - 10.0.0 的 livi-core 按 `kiosk.main` 定窗口大小，却不告诉 livi-compositor 要全屏。compositor 只在 `LIVI_KIOSK=1` 或宿主让它全屏时才全屏。所以窗口带着 32 px 的标题栏，高 1034 px，比屏幕的 1002 还高，底下的 Dock 被切掉（b 的日志 `panel 'main': 268x173 mm over 1600x1034 px`）。
    - 修法：KWin 规则 `y700-livi-fullscreen`（`~/.config/kwinrulesrc`：wmclass `dev.f-io.livi`、标题 `LIVI`、强制全屏 `fullscreenrule=2`），`install-livi.sh` 第 6 步写，已有就不动。平板上 01:00 写好，之后是 `268x168 mm over 1600x1002 px`。
    - **有意不用 `LIVI_KIOSK=1`**：那样 livi-core 就当自己是整台机器，设置里的 Power Off / Restart 会关掉、重启平板。现在的 Power Off 只退出 LIVI。
    - 体检：kwinrulesrc 里没有一条列在 `General/rules` 里、wmclass 是 `dev.f-io.livi`、强制全屏的规则 → WARN。
  - **踩坑六：只有 30 帧，9.4.0 的仪表盘槽位被迁成了 10.0.0 的仪表盘**。
    - 9.4.0 的 `dashboards` 有四个槽位，dash1/dash2 的 `main` 本来就是 true（只有 dash3/dash4 会要第二路，10-18 关掉的就是这两个）。10.0.0 第一次启动时把它迁成新的 `dashboard`，结果 `main` 是 true。LIVI 于是向 iPhone 声明一个仪表盘屏，iPhone 编两路码流（`0x7a000001` 主屏、`0x7a000010` 仪表盘），主屏只给 30 帧（a、b 滑动时 5 秒最多 195、169 帧）。
    - 修法：config.json 的 `dashboard` 三项全 false（01:05，LIVI 不在跑时改；改之前的备份是 `config.json.bak-20261023-dash`）。c 起只有一路，e 滑动时 5 秒 300 帧。
    - 体检：`dashboard` 任何一项是 true → WARN「仪表盘开着」；没有 `dashboard` 时照旧看 9.4.0 的 dash3/dash4（S13p10–S13p12）。
  - **踩坑七：界面大一号，`projectionDpi` 在 10.0.0 里也管 CarPlay**。
    - 10.0.0 的 `carplay.rs` 给 iPhone 报屏幕的毫米尺寸时，先用 `projectionDpi` 算（`像素 × 25.4 ÷ dpi`），没有 dpi 才用面板报的尺寸，再没有才按全屏估。270 dpi 算出来是 150×94 mm，iPhone 当成一块小而密的屏，按钮、字、Dock 都大一号。9.4.0 直接用面板的 268×168 mm，270 只给 AA 用（10-20 为 AA 设的）。
    - 修法：`projectionDpi` 设 0（c 和 d 之间，改之前的备份是 `config.json.bak-20261023-dpi`）。CarPlay 回到面板的尺寸，和 9.4.0 一样。代价是 AA 的 1080p 档回到 LIVI 的 200 dpi（d 的日志 `AA tier 1920x1080 @200dpi`），AA 的界面会小四分之一，见「无线 Android Auto」的「分辨率」。AA 在 10.0.0 下还没试。
    - 体检：投屏不是 1600×1000、dpi 0 → WARN；270 时说「大一号」（S13p7–S13p9、S13p8b）。
  - **踩坑八：Dock 两头多了温度调节，时钟没了**。
    - 10.0.0 新加的 `carPlayVehicleClimate`：开着时 LIVI 向 iPhone 声明车上有空调和座椅（`with_climate`）。iPhone 就在 Dock 两头各放一个温度控件，原来的时钟挤没了。平板上 10.0.0 第一次启动写的是 true。配置结构是编译时生成的，源码里找不到它的默认值，所以键不在也按开着算。
    - 修法：config.json 里设 false（和踩坑七一起改）。e 的 Dock 和 9.4.0 一样。
    - 体检：仪表盘是 10.0.0 的格式、`carPlayVehicleClimate` 不是 false → WARN（S13p13–S13p15）。
  - **只碰到一次：改完配置后第一次没出画面（d，01:18）**。iPhone 连上热点、过了认证，建了会话和 iAP 隧道，却没有建主屏的视频流；5 秒后一个事件请求得到 408，再过 5 秒 iPhone 断开（`session #1 ends`）。之后 3 分半，LIVI 的重连循环只在呼叫那台安卓手机（`br-connection-key-missing`，那台要重新配对），iPhone 没再来。01:22 作者手动关掉了 LIVI（日志里先是 compositor 退出），01:22:57 重开就是 e，一切正常。原因不明，没改东西。再碰到时，先看 LIVI.log 里 408 前后。
  - **实测结果**：
    - [x] CarPlay 连上、出画面；五次都是 MFi4 双向认证，`[cp] mfi4 0x5100 -> 0x5201 (SetUp)` 到 `0x51ff -> 0x52ff (Proven)`，然后 `the phone and LIVI proved each other`。还有一行 `no Apple accessory root, the phone's certificate chain goes unchecked`：LIVI 不核对 iPhone 的证书链，这一侧不影响能不能用。
    - [x] gst-host.log 里是 `decoder=v4l2h265dec (hw)`；c 起只有一路 `0x7a000001`，e 滑动时 5 秒 300 帧（60 帧/秒）。
    - [x] Siri：e 里用了三次（`Siri speech active` → `Siri speech done`，麦克风那路是 `audioType=speechRecognition`，Opus），Siri 能用。这就是 9.4.0 要自编 b82707ad 才有的东西，10.0.0 原版就行。
    - [x] 地图语音：没专门测，作者自己用时确认没问题（10-23）。其中一次开着导航（手机一直在写 `routeState`、`rerouteReason`），有 17 段 `audio default`（type 101，导航提示走这路），每段都起停正常，没有音频报错。
    - [ ] 无线 Android Auto：先放着。那台安卓手机要重新配对（`br-connection-key-missing`）；AA 的 dpi 已经变了（踩坑七）。
    - [x] 用完后 Wi‑Fi 省电开回来：01:05、01:15、01:22、01:33 四次和之后作者自己用的几次都是 `power save restored`，只有一次没开回来（脚本被热点单元的 8 s 时限杀了，已修，见文件表的 ps-restore 一行）。23:49 那次也没开回来：等了 20 s 网卡还是热点类型，NM 五分钟后才连上，10-24 改成交给 NM 的 dispatcher（文件表 `90-y700-carplay-ps`）。
    - [x] 界面铺满（踩坑五之后）、触摸（作者一直在点）、保持亮屏（watch 里 `inhibit=true`，背光没动）、退出干净（guard restore 后没有残留进程，体检 CarPlay 一项 OK）。
    - [ ] 桌面图标是不是新的 livi.png：没看。
  - **之后作者又实车用了三次**。最长一次 81 分钟，647 次 `[cp_screen] recv` 都是一路，最多 5 秒 300 帧；Siri 两次。其间作者在 LIVI 的设置里把音量（`huVolume`）调到了 1.0。LIVI 10.0.0 存设置时把 config.json 写成 0664（里面有热点口令），但 `~/.config/LIVI` 是 0700，别人读不到，所以没改。
  - **收尾（10-23，iPhone 实测之后）**：删掉了 `build-livi-siri.sh`、补丁文件、体检的 `LIVI_940_STOCK`（连同自测 S13r–S13r3）和 `install-livi.sh` 第 8 步，平板上的 `/root/src-carplay-livi/` 同步删掉。这是上面「Siri」一节的周期性义务；没等地图语音和 AA，因为删掉的东西只管 9.4.0 的 Siri。
  - **回滚到 9.4.0**（10.0.0 用不了时）：
    1. 退出 LIVI，`ln -sfn livi-9.4.0 /opt/livi`。
    2. 把换版之前那版 `linux/carplay/livi/`（公开仓库里没有）整个传到 `/root/src-carplay-livi/`，跑它的 `install-livi.sh`。sudoers 和启动器会换回 9.4.0 的路径。
    3. `/opt/livi-9.4.0` 里还是带 Siri 修复的自编文件。热点那三样，9.4.0 下次开无线时会自己装回它的那份。bluetoothd 的 drop-in 和 Class 两版一样，不用动。
    4. config.json 要改两处（LIVI 不在跑时改）。10.0.0 第一次启动时把 `dashboards` 迁成 `dashboard` 后删掉了旧键（10-23 核对过），9.4.0 读不到它就按默认打开 dash3/dash4，iPhone 又只给 30 帧。所以要加回 `"dashboards"`，写成换版之前的 `install-livi.sh` 生成的样子：`dash1`…`dash4`，`main` 只有 dash1、dash2 是 true，`dash`、`aux` 全 false，`pos` 1–4。再把 `projectionDpi` 改回 270，AA 的字才和 10-20 一样大。换版之前的体检这两处不对都会报。`dashboard`、`carPlayVehicleClimate` 9.4.0 不读，留着没事。KWin 规则也不用动，9.4.0 的窗口本来就全屏。
- [x] **LIVI 10.0.1：10-24 读了 v10.0.0..v10.0.1 的源码 diff，决定不换**。三处修复都不在我们的用法上：
  - 有线 iPhone 会话起来 8 s 还没开 CarPlay，就复位它的 USB（`livi-cp/src/manager.rs` 的 `STUCK_AFTER`、`livi-helperd/src/wired.rs`）。只管有线，我们只用无线。
  - 会话在、手机还没给主屏视频时，不再切到黑的投屏页，留在 LIVI 自己的界面（`livi-core/src/projection.rs` 的 `video_up`）；投屏页没画面时显示一个图标，不再是「Connect your phone」。上面 d（01:18）那种 iPhone 没建视频流的情况，10.0.1 下看到的会是 LIVI 主页而不是黑屏，但起不来的原因没变。
  - 窗口标题栏的关闭按钮真的退出 LIVI（`livi-compositor/rust/src/input.rs`，原来只关界面那个窗口）。我们靠 KWin 规则全屏，没有标题栏。
  - 其余是 AA 和面板尺寸的日志少打几遍，以及 Arch Linux 的安装脚本（我们不用它的 install.sh）。自带的 libwayland-client 还是 1.23.1，踩坑四的预加载照样要。
  - **反而多一个变量**：10.0.1 把自带的 libva 2.22 挪进 `lib/libva-compat`，只在系统 libva 低于 2.21 或缺 drm/x11 时才放到前面（`livi-core/src/resources.rs`）。平板上系统 libva 是 2.23，drm、x11 都在，所以 gst-host 会改用系统的 libva（`/usr/local` 里还有 radxa 的 libva-v4l2），VA 那条链路变了，硬解要重看。
  - 换版要下 AppImage（10.0.0 是 112 MB，先问作者），还要作者在场用 iPhone 重测。等下一个和无线有关的版本一起换，上游巡检照常盯 f-io/LIVI 的发布。真要换时照上面 10.0.0 的流程走，多看一眼 gst-host.log 的 `decoder=` 还是不是 `v4l2h265dec (hw)`。

## 已知副作用（要告诉作者）

- LIVI 运行时会接管蓝牙：用自己的参数重启 bluetoothd，并把设备类别设成车载。平板连着的其他蓝牙设备会断。它还会从 NetworkManager 手里拿走 Wi‑Fi，所以 CarPlay 期间平板自己上不了 Wi‑Fi。在车上这两点都不影响。
  - 10-20 读 9.4.0 源码补充（没在平板上复测）：只有 drop-in 或 `main.conf` 需要改的时候才重启 bluetoothd（`livi-runtime/src/bluetoothd.rs` 的 `setup()`）。平板上这两处 10-17 已经写好，所以之后再打开 LIVI 不会重启，其他设备也不该再断。
- **第一次打开后留下、退出也不撤的改动**（10-17 空跑实测）：
  - bluetoothd 不加载 SAP（SIM 卡访问）和 MIDI 插件；`main.conf` 的 Class 改成车载音响。
  - WirePlumber 的蓝牙角色只剩 A2DP（`99-livi-hfp.conf`），这样 LIVI 自己的 HFP 才能用。代价是**蓝牙耳机在平板上打电话、开会时没有麦克风**（只剩听）。要恢复，删掉这个文件再 `systemctl --user restart wireplumber`；但下次打开 CarPlay，LIVI 又会写回来。
  - 改之前的原样备份在 `/root/livi-preinstall-20261017.tgz`。
- avahi-daemon 只在 CarPlay 打开期间运行。
- LIVI 起热点时会关掉 wlp1s0 的 Wi‑Fi 省电，停热点时不恢复。10-22 之前每用一次 CarPlay，省电就一直关着，直到重启或 NM 碰巧重设。从 10-22 起由 `y700-carplay-ps-restore` 在停热点后打开回来，见上面的文件表。10-23 15:01 它被热点单元的 8 s 时限杀过一次，那次省电没开回来；之后时限放到了 40 s。23:49 又漏了一次（停热点后网卡迟迟不回 station），10-24 起等不到时留标记，NM 下次连上 Wi‑Fi 时由 dispatcher 钩子开回来。体检：省电 off 且没连 Wi‑Fi、标记还在时只报 INFO（等连上）；连着还是 off 就报 WARN，有标记时会点名钩子。
- 无线 Android Auto 开着（10-20 起）：LIVI 运行期间多一个 BLE 广播，附近的安卓手机能看到它；TCP 5277 监听在 0.0.0.0 上。这时 wlp1s0 是热点，Tailscale 也断着，能连进来的只有知道热点口令的设备，以及 USB 线那头。
- iPhone 用线插到平板上时，不会再被当成相机或媒体设备（LIVI 的 Apple udev 规则，有线 CarPlay 要用）。
- 停车暴晒时仪表台能到 70 °C 以上，平板是被动散热、带锂电池，**停车时把平板拿走**。

## 以后可做：OBD、胎压也走平板蓝牙（10-20 调研，没动手）

作者设想 CarPlay、OBD、胎压监测都走平板的蓝牙。结论：**蓝牙这头能做到**，难点在数据显示在哪。

- **芯片**：蓝牙也在 WCN7850 上（`btmgmt info`：高通，HCI 版本 14，BR/EDR 和 LE 双模，central 和 peripheral 两种角色都支持，16 个广播实例）。平板上已经配对了键盘、手柄、耳机和手机。
- **频段**：CarPlay 热点在 5 GHz（config.json 里 `wifiType` 是 `5ghz`，信道 36，80 MHz），蓝牙在 2.4 GHz。CarPlay 的画面和声音都走 Wi‑Fi，蓝牙只在连上之前用 iAP2 交换热点信息，之后几乎没有流量。
- **LIVI 不独占蓝牙**：用内置网卡时它走 BlueZ（它自带的 `livi-bt-host` 只给 LIVI Link 狗用）。它注册自己的 iAP2/CarPlay profile，把网卡设成可发现、可配对，退出时再改回去。bluetoothd 什么时候重启，见上面「已知副作用」。
  - 坑：**LIVI 运行期间，它是 BlueZ 的默认配对代理，谁来配对都自动同意**（PIN 回 0000，passkey 回 0，见 `livi-runtime/src/bt.rs` 的 `Agent`）。所以 PIN 是 1234 的经典 ELM327，要在 LIVI 没运行时先用 `bluetoothctl` 配好。
- **硬件怎么选**：
  - 胎压：选「手机 App 版」蓝牙胎压，传感器自己广播 BLE。带独立显示屏或接收盒的不行，那种走 315/433 MHz 射频，平板收不到。读 BLE 广播只要被动扫描，不建立连接，也不占连接数。各品牌的广播格式不一样，选开源解码器（比如 Theengs Decoder）已经支持的型号，省得自己逆向。
  - OBD：选正规的 BLE ELM327（比如 Vgate iCar Pro BLE、OBDLink CX），别买几十块的「v2.1」仿品，指令不全，还常掉线。要能停车自动休眠，否则一直插着会耗电瓶。OBD 狗同一时间只能被一台设备连，所以 iPhone 上的 OBD App 不能再去连它。
- **显示**：iPhone 的普通 CarPlay（上游叫 CarPlay Classic）**不显示胎压、转速、水温**，这些苹果只在车厂集成的 CarPlay Ultra 里显示。
  - 上游 LIVI 主线 10-14、10-15 加了遥测推送：`POST http://<host>:4000/telemetry`，内容是 JSON，字段表和每个字段的去向在 `native/livi-helperd/crates/livi-core-proto/src/telemetry.rs`。CarPlay Classic 只用其中的油量、续航、档位、车外温度、昼夜和 GPS 等；胎压只用在 LIVI 自己的仪表盘页和 Android Auto 里。9.4.0 还没有 HTTP 推送。
  - 所以胎压和 OBD 读数得放在 CarPlay 画面外面显示。一种是等 LIVI 发新版，用它的仪表盘页：dash1、dash2 是主屏上的页，不影响 60 帧；拖慢帧数的是 dash3、dash4 两块仪表屏。另一种是自己做一个提醒条，读数异常时弹出来。
- **要做的话**：写一个 Rust 常驻程序，负责 BLE 被动扫描、连 OBD、把数据推给 LIVI 或自己显示。它跟 CarPlay 启动器一起起停，平板不在车上时不跑。

## 认证硬件

- **LIVI Link**：把一个 Carlinkit 加密狗刷成 LIVI 固件。认证芯片、热点和蓝牙都在狗上，LIVI 原生支持。先确认狗的 SoC 是支持的那几种，MIPS X1600 不支持。
- **认证芯片接 USB‑I²C**：经 Apple MFi 计划合法取得的认证协处理器。注意 CH341 单条 I²C 消息最多 26 字节，而 LIVI 一次读完整张证书，所以要换 CP2112 或 MCP2221（主线有驱动）。
- **启动器的可选钩子**：如果你的认证协处理器要一个 systemd 单元才会出现 `/dev/i2c-99`，在桌面会话的环境里设 `Y700_CARPLAY_AUTH_UNIT=<单元名>`（例如写进 `~/.config/environment.d/y700-carplay.conf`，启动器是从桌面图标起的）。启动器见它没在跑，就用 `sudo -n systemctl start <单元名>` 拉起，所以还要给这条命令配一条 sudoers 规则。不设这个变量时，启动器只等 `/dev/i2c-99` 出现（最多 3 秒）。

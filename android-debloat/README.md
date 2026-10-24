# 安卓（ColorOS 17 移植）精简记录

目标：省电、少后台。不要 OPPO 云控、广告、AI、游戏组件和统计上报。**流畅度和省电相关的机制一律保留。**

## 文件

| 文件 | 用途 |
|---|---|
| `batch1.txt` | 第一批禁用清单（包名、类别、理由） |
| `apply.sh` | `./apply.sh batch1.txt <adb序列号>`：先把 `/data/system/users/0/package-restrictions.xml` 备份到 `backup/`，再逐个 `pm disable-user --user 0` |
| `restore.sh` | `./restore.sh batch1.txt <序列号>` 全部恢复，或 `./restore.sh 包名 <序列号>` 恢复单个（用 `su -c pm enable`，两种禁用都能解） |
| `applied.log` | 每次操作的结果（`apply.sh` 生成，不随仓库发布） |
| `sys-packages.txt` / `disabled-before.txt` | 动手前的快照（2026-10-11 23:5x；已装应用列表和进程快照不随仓库发布） |
| `disabled-after-batch1.txt` | 第一批之后的禁用列表 |
| `backup/` | 包状态备份（`apply.sh` 写入；设备数据，不随仓库发布） |
| `ksu-y700-hide/` | KernelSU 模块源码：开机时藏掉禁用后仍被强制拉起的系统应用（清单在 `hide.list`） |
| `ksu-y700-vrr/` | KernelSU 模块：把抖音等应用的 OPPO 私有降频请求翻译成真正的 60 Hz 切换（见"刷新率"一节） |
| `refresh-rate/` | OPPO 按应用刷新率配置的生成/安装脚本与清单（作者最终决定保持全局 165，没有装覆盖配置）。原件备份和生成的覆盖配置是 OPPO 的文件，只留在本地（`.gitignore`），10-19 已从 git 历史里清掉 |
| `launcher/` | 安卓桌面图标整理：直接改启动器数据库的脚本和存法说明（见其 README；数据库备份不随仓库发布） |
| `audio-crash/` | 刷抖音时音频"断一下又恢复"的分析：杜比音效 + OPPO audioserver 的 FMQ 互等死锁，分析与选项（见其 README） |
| `ksu-y700-audio/` | KernelSU 模块：把 audioserver TimeCheck 超时从约 14 s 改为 5+2 s，杜比互等死锁时更快自恢复（作者决定保留杜比） |

## 作者的选择（2026-10-11）

- 保留：负一屏和全局搜索、智能侧边栏、跨设备互联、欢太账号和云服务、搜狗定制输入法。
- 去掉：游戏助手和游戏中心（安卓侧不用于游戏）。
- 自带应用（时钟、笔记、商店、音乐等）没表态，**暂不动**。它们只在打开时运行，平时不耗电。

## 第一批（2026-10-12 00:00，已执行，未重启）

20 个包，类别见 `batch1.txt`：统计和日志上报（statistics.rom、olc、logtrial）、云控（romupdate）、静默更新（sau、sauhelper、upgradeguide）、广告标识（openid）、电信自注册（ctautoregist）、注册和激活上报（regservice、activation）、游戏（games、gamecenter、game.empowerment.folder）、AI（aipaint、aiwriter、aimemory、aiwidgets、aiunit.aon、speechassist 小布）。

- 16 个用 `pm disable-user` 禁用成功。**olc、romupdate、sau、openid 受 ColorOS 保护**，`disable-user` 返回 `new state: default`（没生效），改用 `su -c 'pm disable'` 才成功（状态 `disabled`）。
- `regservice` 的 `dumpsys package` 显示 `enabled=3`（已禁用），但不出现在 `pm list packages -d` 里，属列表显示差异，不是失败。
- 禁用后 system_server、systemui 和桌面正常，crash 缓冲区没有新记录。
- [x] 2026-10-12 00:09 重启验证：约 35 s 开机，systemui、桌面、system_server 正常。crash 缓冲区只有移植包原有的 minidumpreader SIGSEGV 和 init SIGABRT（禁用前就有）。被禁的包都没在运行，**只有 `com.oplus.olc` 例外**：它是 `PERSISTENT` 系统应用（`/system_ext/app/Olc`，uid system），`enabled=2` 也照样在开机时被 ActivityManager 以 `added application` 拉起，`am force-stop` 无效，kill 掉一秒内 `restart`。
- [x] 为此做了 KernelSU 模块 **`ksu-y700-hide/`**（装在 `/data/adb/modules/y700_hide`）：在 post-fs-data 阶段用空 tmpfs 盖住 `hide.list` 里的目录（挂上后再 chcon 成 `system_file`；mount 的 `context=` 参数会被拒），PackageManager 扫不到，应用就消失，也不会被拉起。`last.log` 记录每次开机的结果。00:13 重启验证：`hidden /system_ext/app/Olc`，olc 不再运行，`pm path` 找不到它，系统和杜比 daxService 都正常，日志里没有反复找 olc 的报错。
  - 恢复：删掉 `hide.list` 里对应行或删掉整个模块目录，然后重启。开机卡住时：开机过程中连按几下音量减，进 KernelSU 安全模式（不加载模块，y700_dax 杜比也会暂时失效），再用 adb 删模块。
- 以后每批之后都要重启验证一次，开机卡住只能靠 adb 或 KernelSU 安全模式救（/data 加密，Linux 和 recovery 都改不了包状态）。 要是开机卡住：/data 是加密的，Linux 和 recovery 都改不了包状态，只能靠 adb（`restore.sh`）。所以每批之后都要重启验证一次，别连着做几批再重启。

## 有意保留（别禁）

- `com.oplus.athena`（后台清理和冻结）、`com.oplus.deepthinker`（应用使用预测，供省电调度用）、`com.oplus.cosa`（性能调度）、`com.oplus.battery`、`com.oplus.powermonitor`（耗电异常检测）、`com.oplus.exsystemservice`：都跟省电和流畅度有关。
- `com.oplus.aiunit`：system_server 直接绑定它，禁用可能拖垮系统服务，先留着。
- `com.heytap.mcs`（推送）、`com.heytap.htms`：账号和云服务（含查找设备）依赖它们，作者要留云服务。
- `com.nearme.instant.*`、`com.oppo.instant.local.service`（快应用）：负一屏的卡片可能要用。作者要留负一屏，所以先不动。
- 工程模式类（engineermode 等）：平时不运行，禁了可能影响拨号暗码等调试入口，收益为零。

## 刷新率：屏幕常年钉在 165 Hz（2026-10-12 查明，待修）

**现象**：刷抖音时 SurfaceFlinger 的 activeMode 一直是 165 Hz，抖音通过 OPPO 接口申请 30 Hz（日志 `[OTI-SW] setFrameRate 30`）也不落地。显示管线（`crtc_commit` 50%、composer 20%、SF 22%、`pp_event` 18%）合计吃掉约一个核，是看视频时除抖音外最大的 CPU 消耗。Linux 侧实测 164 vs 60 Hz 差约 1.5 W。

**根因（移植接缝）**：
- OPPO 的刷新率策略（`oplus-services.jar`，`com.android.server.wm.OplusRefreshRatePolicyImpl` 等）在"自动"档把绝大多数应用钉在 165（投票 min=max=165，`setDisplayConfigSpecs rate=165`）。真 OPPO 机器靠 LTPO 面板级自动降频（oplus_display 内核节点、ADFR/OTI-HW）省电，所以框架层不切模式。
- 联想内核没有 `/sys/kernel/oplus_display`（OPPO 的 touch-idle 硬件路径不存在），面板是 LTPS，只能靠 SF 切显示模式；SF 的 idle timer 和内容检测也都关着（`ro.surface_flinger.use_content_detection_for_refresh_rate=false`，无 `set_idle_timer_ms`），而且 OPPO 把范围钉死后 SF 也无从选择。
- 配置文件 `/my_product/etc/refresh_rate_config.xml`（作者改过：文件头提到 TB323FU，version 20260930，末尾加了桌面/SystemUI 钉 165 的两行）。格式 `rateId="a-b-c-d-e"`：5 个数对应设置档位 0 自动 / 1 90 / 2 60 / 3 高(120/144/165) / 4 极致(185)；每个数是 rate id：1=90, 2=60, 3=120, 4=144, 5=72, 6=30, 7=165, 8=185。抖音 `7-2-2-7-7`、B 站 HD `7-1-2-7-7`：自动档都是 165。2157 条里 1868 条是 `7-2-2-7-7`。
- 设置键：`Settings.Secure oplus_customize_screen_refresh_rate`（现为 0=自动）。
- 代码里还引用 `data/system/refresh_rate_config.xml` 和 `/data/system/refresh_rate_config_user_override.xml`（后者现为空 `<map />`），可能可以不动系统分区就覆盖配置——加载顺序待反编译确认。
- 面板 DRM 模式：1904x3040 @120/144/165 为独立 timing，30/60/90 由 HWC 作为 alternativeRefreshRates 提供，全部 group=0（切换无缝）。
- 原文件备份：`refresh-rate/refresh_rate_config.xml.port-orig`、`oplus_vrr_config.json.port-orig`（SHA256SUMS）。**只在本地工作区，不进仓库**（OPPO 的文件；10-19 审计后从全部 git 历史里清掉，连同 `refresh_rate_config.{cap120,noop,video60}.xml` 三份生成结果）。新克隆里没有它们：从平板取原件 `adb pull /my_product/etc/refresh_rate_config.xml refresh_rate_config.xml.port-orig`（`oplus_vrr_config.json` 的位置以平板上 `find /my_product /odm -name oplus_vrr_config.json` 为准），用 `sha256sum -c SHA256SUMS` 对上这里记的版本，再用 `make_config.py` 按清单生成覆盖配置。

**反编译确认的机制**（`oplus-services.jar` classes3.dex，`com.android.server.wm.OplusRefreshRateConfigs$RefreshRateConfigUpdater`、`OplusRefreshRatePolicyImpl`，用 androguard 4.1.4 的 DAD 反编译，反编译脚本未收入仓库）：
- `init()`：读 `data/system/refresh_rate_config.xml` 和 `/my_product/etc/refresh_rate_config.xml`，取根节点 `version`，**/data 那份 ≥ 系统那份就用 /data 的**。`parseContentFromXML` 还要求 version > 已加载版本（开机时为 1），所以每次改配置都要把 version 抬高（用日期即可）。
- 热重载：RUS 广播 `oplus.intent.action.ROM_UPDATE_CONFIG_SUCCESS`（`--esal ROM_UPDATE_CONFIG_LIST sys_refresh_rate_config`）能到达 `RomUpdateObserver`，但它是去 `com.oplus.romupdate.provider.db` 这个 ContentProvider 取内容，而 `com.oplus.romupdate` 已被第一批禁用 → 报 `Failed to find provider info`，**不会重载**。改完配置要重启（约 40 s）。
- 最终模式由 `setDisplayConfigSpecs` 下发，primary/app 两个范围都是 `[rate, rate]`，所以 SurfaceFlinger 的内容检测、idle timer 在这套框架下都无法生效；只能改按应用配置。
- 窗口自带 `preferredRefreshRate/preferredDisplayModeId` 会被尊重（`enableWinOverride` 默认 true，比配置值低就采用），但抖音等用的是 OPPO 私有 OTI 接口直通 SF 扩展（`OPlusSurfaceFlingerController.setTouchIdleAppRequest`），在联想 HWC 上空转。
- `Config` 默认值：`defaultMaxRate=120`（本文件写了 165）、`appSwitchBoostMaxTemp=49`；`defaultRateId` 只在条目 rateId 为 0 时兜底。
- 工具：`refresh-rate/make_config.py`（按清单改 rateId、抬版本、保留 CRLF）、`install.sh`（装到 /data/system，system:system 0660 `system_data_file`）、`uninstall.sh`。清单 `video-60.list`（视频应用自动档→60），`noop.list`（空改动，用来验证机制）。
- 2026-10-12 00:29 先装入空改动版验证机制；00:48 换成 `refresh_rate_config.cap120.xml`（`--auto-cap 3`，全部"自动"档压到 120）；**00:55 作者改主意要保持 165，已用 `uninstall.sh` 删掉**，/data/system 下现在没有覆盖配置，系统用 /my_product 原件。cap120 文件留着备用。

**动态降频：`ksu-y700-vrr/`（KernelSU 模块 `y700_vrr`，2026-10-12 00:48 装入并手动拉起，实测可用）**
- 作者要的效果："视频播放 60 Hz，信息流滑动仍高刷"。按应用配置做不到（一个应用只能钉一个值），但抖音自己会通过 OPPO 私有接口 `OPlusRefreshRateService.setFrameRate(30/60/0, 窗口, 包名, pid)` 报告状态：手指离开约 3 s 且视频在播 → 30；触摸/滑动 → 60；退出 → 0。ColorOS 原本把它交给 SF 扩展做 LTPO 面板级空闲降频，在联想 HWC 上空转。
- 找到的开关：binder 服务 `oplusscreenmode`（`com.oplus.screenmode.IOplusScreenMode`，实现在 `com.android.server.wm.OplusDisplayModeService`），事务 4 = `requestRefreshRate(boolean 开, int 速率id)`，**无权限检查**，投 `PRIORITY_MEMC`(70) 票，压过窗口默认值；`service call oplusscreenmode 4 i32 1 i32 2` 立刻切 60，`i32 0 i32 2` 撤回（实测即时、无闪屏）。事务 25 = `setAppOverrideRefreshRate(包名, 档位, 速率id)`（需要 `oplus.permission.OPLUS_COMPONENT_SAFE`，未试）；26/27 = 读取按应用覆盖（root 可读，返回 Bundle）。
- `vrr-bridge.sh`：`logcat -v brief | grep --line-buffered` 盯三类行：`setFrameRate [ r , win , pkg , pid ]`（1≤r≤30 且 pkg 在 `/data/adb/y700/vrr-apps.txt` 里且 pkg 是前台 → hold；r≥60 或 **r=0（取消）** 且 pkg 是持有者 → release）、`Trigger app switch boost ... u0 <pkg>/`（切到别的应用 → release）、`handleScreenStateChange ... state: 1`（熄屏 → release）。另有看门狗每 3 s 核对前台应用（`dumpsys window` 的 mCurrentFocus），不是持有者就强制 release。持有状态放在 `/data/adb/y700/vrr-held`，主循环和看门狗共用。状态变化写 `/data/adb/y700/vrr-bridge.log`。空闲时 CPU 0%。`vrr-apps.txt` 取自 OPPO 自己的 `oplus_vrr_config.json` `sw_whitelist_3rd`（抖音、抖音极速版、抖音火山、快手、快手极速版、腾讯会议）。
  - 踩坑（00:53）：第一版把 r=0 当成"≤30"，抖音退到后台时发的 0 被当成请求，桌面被压到 60，作者立刻发现。第二版修正。
  - 踩坑：`pkill -f vrr-bridge.sh` 会把自己所在的 adb shell 也杀掉（命令行里含这个字符串），重启守护进程别用它，用 `ps -A -o PID,ARGS | grep "^.*sh /data/adb/modules/y700_vrr"` 找 PID 再 kill。
- `service.sh`：开机 `sys.boot_completed` 后 5 s 以 nohup 拉起。手动重启守护：`su -c "pkill -f vrr-bridge.sh; setsid sh /data/adb/modules/y700_vrr/vrr-bridge.sh >/dev/null 2>&1 </dev/null &"`。
- 实测（00:49:30–00:49:44 和 00:50:22–00:51:33）：抖音报 30 → SF `RefreshRateDirector` 切到 modeId 4（60 Hz），采样连续 50 s 都是 60；作者碰屏幕抖音报 60/90 → 立刻回到配置值（当时 165）。抖音偶尔会报 90，按 ≥60 处理即释放。
- [x] 2026-10-12 01:09 重启验证：开机 ~50 s，`service.sh` 在 KernelSU 3.3（无 metamodule）下正常自动拉起守护进程（log 有 start 行，三个进程在）；y700_hide 照常藏掉 olc；禁用列表保持（24 项，olc 因被藏起不再出现在列表里）；杜比 daxService 在；无新崩溃；桌面布局保持。
- 限制：只对会调 OPPO 接口的应用有效。红果（com.kylin.read）自己用标准窗口属性申请 60，策略直接照办，不需要桥接；B 站 HD 未观察到请求（看视频时按配置档位跑）。`logcat -s` 不认带方括号的标签，所以用 grep。
- 卸载：删 `/data/adb/modules/y700_vrr`、`/data/adb/y700/vrr-*`，重启；配置用 `refresh-rate/uninstall.sh`。

## 其他已知现象

- 移植接缝（待修，影响小）：应用读剪贴板状态时，`OplusCustomizeRestrictionManager.getClipboardStatus` 报空指针，因为 `IOplusCustomizeRestrictionManagerService` 不存在（作者禁用了 `com.oplus.customize.coreapp`）。异常已被兜住，粘贴照常可用。2026-10-12 在 com.kylin.read 的日志里看到。
- 插着电脑 USB 时 `a600000.ssusb` 和 `charge_wakelock` 一直拿着唤醒锁，挡住深度休眠（开机后成功休眠 0 次）。不插线时机身也一直温热，还没做拔线测试。

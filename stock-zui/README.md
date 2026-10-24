# 联想原厂固件（研究用）

> **免责声明**：非官方个人项目，与联想、杜比、OPPO 无关。这里的 KernelSU 模块会改动系统分区的挂载视图，按现状提供、无任何担保，风险自负；厂商的 APK 与配置文件不随仓库发布。
> Unofficial, no warranty: use at your own risk; no vendor files are included.

作者 2026-10-11 授权：从联想官网下载原厂镜像用于研究分析（只读分析，**不刷机**）。

- 官方渠道只有 Lenovo Software Fix（原 Rescue and Smart Assistant / LMSA），没有公开的国行 ZUXOS 直链。
  - 下载页：`https://pcsupport.lenovo.com/<地区>/<语言>/downloads/ds101291`
  - 安装包 `tool/software_fix_v7.6.2.10_setup.exe`（136.66 MB，2026-07-28）
  - SHA256 `5f85da1d2a841f61f495d14aa55bc40e11cf79fbc80a1e553a289b101cc1e973`，与官网一致；Authenticode 有效，签名者 CN=Lenovo。
- 由作者自己完成：UAC 安装、登录联想账号、输入平板 S/N。**只点下载，不要点 Rescue/刷机**，否则会清空平板。
- 研究目的：拿 ZUI 原版的 vendor/system 层，与 ColorOS 移植包里的 vendor 对比，确认音频组件（杜比 spatializer/gamedap、ZUI 音效服务和调音）有没有被删，并找出更多扬声器调音数据。

## 实际来源：本机此前的整盘备份（2026-10-11 20:20）

本机此前已有整盘备份（存在另一台机器上），所以没有安装 Software Fix（安装程序已退出，系统里查不到安装记录；安装包还留在 `tool/`）。备份所在机器通过 ssh 密钥访问。

- `<备份目录>/y700-backup-cn088-20261008-141640Z/automatic-01/lun0/p007_7375706572.img`（文件名是 hex 编码，即 `super`，20 GiB）：**本机在原厂国行 ZUXOS 088 时整盘导出的 super**，和 ColorOS 移植包里的 vendor 是同一个基线。备份里还有 `-cow` 分区：说明导出时有一个 OTA 快照还没合并完，system/product/odm 读出来可能新旧混杂；vendor 没有 cow，内容完整。
- `y700-row104-unverified-20261008-dxl779lx/`：ROW 18.0.12.104 全量 zip，目录里自带 `UNVERIFIED_THIRD_PARTY_MIRROR.txt`，**来自第三方镜像站，不是联想官方的**，这次没用。
- 用 `linux/audio/lpcat.py`（只读，按 LP 元数据拼接 extent 输出到 stdout），经 Windows 中转，用 ssh 管道把 vendor_a / odm_a / system_ext_a / product_a 传到平板的 `/home/stock-cn088/*.img`（ZUI 用的是 ext4，sha256 见 `stock-cn088.sha256`）。只读 loop 挂载对比，分析完已卸载。

### 结论

1. **移植包没删联想 vendor 里任何音频文件。** 原厂 vendor 和 ColorOS vendor 的文件清单逐个比对：ColorOS 一个都没少，只多了 4 个（`init.tb323fu.sched.sh`、`init.tb323fu-{double-tap,tweaks}.rc`、`oplus_avb.pubkey`）；内容有改动的只有相机 provider、build.prop、fstab、SELinux 规则和 `thermal-engine_battery_0.conf`。杜比 DAP、ACDB、`dax-default.xml` 全部和原厂逐字节相同。`libswspatializeraidl.so`、`libswgamedapaidl.so` 在原厂 vendor 里也没有，不是移植时删的。
2. **ZUI 比 ColorOS 多出来的音频组件是 `system_ext/priv-app/daxService`（`com.dolby.daxservice`）**：杜比的控制服务，负责打开 vendor 里的 DAP、加载联想的 `dax-default.xml` 调音、按横竖屏切换调音。ColorOS 移植包里没有它，换成了 OPPO 自己的 `AudioEffectCenter` + `liboplusdolbyeffect_5.0.so`。**推测：ColorOS 下杜比 DAP 可能根本没被正确打开，或者用的不是联想的调音**，这很可能就是 ColorOS 听起来不如 ZUI 的原因。[ ] 回安卓后用 `dumpsys media.audio_flinger` 确认 DAP 是否在运行。
3. daxService 可以搬过去：apk 里没有 sharedUserId（不需要系统签名），是 persistent priv-app，只要 3 个特权权限（INTERACT_ACROSS_USERS、MANAGE_USERS、WRITE_SECURE_SETTINGS），原厂的 `com.dolby.daxservice.xml` 已经把它们列入白名单。可以做一个 KernelSU 模块，systemless 挂载到 `/system_ext/priv-app/daxService` 和 `/system_ext/etc/permissions/`，在 KernelSU 管理器里禁用模块即可回退。这一步**还没做**，需要在安卓下进行，并且要先确认第 2 点。
   - 文件在 `cn088-daxService/`：`daxService.apk` sha256 `65cffffe…50ad`，`com.dolby.daxservice.xml` sha256 `6d04846e…36c9`。联想/杜比的专有文件，**不随仓库发布**，需从自己设备的原厂固件里提取。

## 在 ColorOS 上恢复联想杜比（2026-10-11 22:19 生效，试听确认）

**现场确认（装模块前）**：`pm list packages` 里没有 `com.dolby.daxservice`；`vendor.dolby.dms.service` 在运行；但 `dumpsys media.audio_flinger` 的所有输出线程都是 `0 Effect Chains`，`Total Effects CPU: 0`。也就是说 ColorOS 下杜比 DAP **从来没有被打开过**，扬声器一直在输出未经处理的原始声音。

**做法**：KernelSU 模块 `y700_dax`（本机 `ksu-y700-dax/`，打包为 `ksu-y700-dax.zip`，sha256 `34f495b3…0441`；仓库里只有脚本和自写的 sysconfig，APK 与 privapp 白名单不随仓库发布）：
- `system_ext/priv-app/daxService/daxService.apk`：原厂 CN088 的 daxService，打了一处 3-nop 补丁（见下文），sha256 `7c62ecf8…be4c`。
- `system_ext/etc/permissions/com.dolby.daxservice.xml`：原厂的 privapp 白名单。
- `system_ext/etc/sysconfig/y700-daxservice-hiddenapi.xml`：`hidden-api-whitelisted-app`，允许它调用 `ServiceManager.waitForDeclaredService` 这个隐藏 API 来连接 `vendor.dolby.dms`。
- `post-fs-data.sh`：把文件复制到 tmpfs `/dev/y700_dax`，`chcon system_file` 后，用只读 overlay 叠加到 `/system_ext/{priv-app,etc/permissions,etc/sysconfig}` 上。

**一路踩到的坑**（按顺序）：
1. 先当普通应用 `adb install` 测试（ColorOS 会弹安装确认）。shell 用户启动不了它的服务（受 `com.dolby.permission.DAXSERVICE` 保护）；root 启动时又被后台启动限制拦下，只能先拉起它的 activity，把进程带到前台。
2. 隐藏 API 被拦（`waitForDeclaredService ... api=blocked`）。临时设 `hidden_api_policy=1` 验证后已删除这个设置，正式方案改用 sysconfig 白名单。
3. 连上 DMS HAL 之后，`DAP ... status 0 enabled 1` 能成功创建。**说明联想的 DAP 在 ColorOS 的 AudioFlinger 下是能用的。**
4. 接着 `registerReceiverAsUser(UserHandle.ALL)` 需要 `INTERACT_ACROSS_USERS_FULL`，这是 signature 级权限。ZUI 能拿到，是因为 daxService 用联想 platform key 签名、和 framework 同一把钥匙；ColorOS 的 framework 是 OPPO 签的，系统应用也拿不到。**不能重签名**：联想 vendor 的 `vendor_mac_permissions.xml` 把联想证书映射为 `seinfo=platform`，只有用原签名，进程才会落在 `platform_app` 域，才能访问杜比 HAL。所以采用“保留原签名块、原地改 dex”的办法：system 分区上的 APK，PackageManager 只读取证书，不校验摘要。`dexpatch/dexscan.py` 用来定位；改 dex 并重算 dex 的 SHA-1/adler32 和 zip 里 CRC 的补丁脚本含厂商 dex 的偏移和原始字节，不随公开仓库发布。
   - v1 把 `ALL` 改成 `CURRENT`（field 81→82），结果 Android 16 对 -2 照样要求这项权限，失败。
   - v2（现行）：把 `DaxService.onCreate` 里那条 `invoke-virtual/range registerReceiverAsUser` 换成 3 个 nop。这个接收器只监听 USER_SWITCHED/ADDED/REMOVED、REBOOT、SHUTDOWN 广播，单用户平板用不上。
5. KernelSU 3.3 没有内置的模块挂载（需要 metamodule），`ksud module install` 之后文件不会出现在 `/system_ext`。直接用 `/data/adb/modules/...` 做 overlay 的 lowerdir 时，内核报 `case-insensitive capable filesystem ... not supported`（/data 是 casefold 的 f2fs），所以先复制到 tmpfs。这套挂载先在运行中试挂、核对标签、再卸载，确认无误后才写进开机脚本。

**结果**：daxService 常驻（persistent），音频输出上出现 1 条效果链，里面是 `DAP`（Dolby Laboratories，Registered/Enabled）。杜比会使用 `/vendor/etc/dolby/dax-default.xml` 里联想的扬声器调音。
- 回退：在 KernelSU 管理器里禁用 `Y700 ZUI Dolby (daxService)` 后重启。如果开机异常，开机时按住音量减进入 KernelSU 安全模式。
- `persist.sys.disable_rescue` 这台本来就是 `true`，不是本项目改的。
- 已知但未处理：OPPO 的 `com.oplus.persist.multimedia`（AEC.AudioxService）每 3 秒尝试创建一次 Audiox 音效（`41f6c0f4-5d8f-11ec-bf63-0242ac130002`），因为联想 vendor 里没有这个引擎，每次都失败。与杜比无关，很可能移植包一直如此。**处理结果（22:25，作者同意尝试停掉）**：先 `pm disable com.oplus.audio.effectcenter/.service.AudioxService`，再 kill 常驻进程 `com.oplus.persist.multimedia`，最后 `am stopservice`，服务记录已经消失，但每 30 秒仍有 10 次失败。重试来自同一进程里别处的 `effect thread`，不归这个服务组件管。实测这个线程 60 秒只用了 1 tick（0.01 CPU 秒），整个进程 60 秒 22 tick，**耗电可以忽略**，不值得为它去改 OPPO 音效中心的代码。所以已经 `pm enable` 恢复原状，不做处理。
- 没有杜比的切换界面（ZUI 的快捷开关和设置页属于 ZUI 系统层）。现在固定使用默认配置（Dynamic）。

## 充电上限（2026-10-11 22:15）

作者反映安卓下插电一直停在 79%：原因是 Linux 助手设的 80% 上限（`charge_control_end_threshold=80`）写在电池管理固件里，切到安卓后仍然有效。作者要求安卓和 Linux 都充到 100%。安卓这边已经用 root 写成 100，重启后仍保持。Linux 这边已于 22:36 执行 `tb323fu-ctl charge-limit 100`，`/etc/tb323fu/helper.toml` 里是 `charge_limit = 100`，sysfs 读到的也是 100。另外，当时读到 `usb/online=0`（没检测到充电器），需要确认作者当时是否插着线。

- 充电慢的另一个原因（22:36 在 Linux 下看到）：当时插的是 PC 的 USB 口（`ChargerAdapter: SDP`，输入约 894 mA × 4.8 V ≈ 4.3 W），比整机功耗还低，所以插着电也在掉电。要真正充电得用 PD 充电头。安卓下读到 `usb/online=0` 可能与 SDP 有关，没有深究。

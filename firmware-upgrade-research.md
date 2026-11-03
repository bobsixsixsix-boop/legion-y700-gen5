# 底层升级调研（2026-11-01，只查资料，没下载、没刷机、没碰平板）

作者 11-01：「那你研究一下底层升级呗」。这是对已拍板的「088 底层不升」（README「安卓上层跟进 OPPO 官方更新」）做一次摸底，不是改主意。删安卓 / 换联想原版界面的调研在 [android-remove-zui.md](android-remove-zui.md)，这份接着它往深里查。

术语，第一次出现时解释一下：
- **底层**：平板开机最先跑的那批联想 / 高通固件（xbl、tz、hyp、aop、abl 等），加上和它们配套的驱动。不是安卓界面。
- **9008**：插电脑刷机、救砖的模式。
- **efisp**：放我们破解程序的分区。有了它，开机程序会把自己当成「已解锁」。
- **防降级保险丝**：芯片里一次性烧断的熔丝。烧过以后，旧版固件就再也开不了机。

---

## 第一部分：给你看的

### 1. 一句话结论

理论上也许能只换底层，同时保住 Linux 和 root，但这台机器从来没这样试过。上一次换底层（海外 187），Linux 就起不来了。

我没找到新底层能修好 Linux 现有毛病的证据。风险里有一条（防降级保险丝）一旦踩中，就永远回不去了。

**建议继续用 088。** 想先摸底的话，有几步不碰平板、几乎不用下载的检查可以做，见第 5 节。

### 2. 现在有哪些更新的底层

| 版本 | 哪条线 | 构建日期 | 能不能拿到 | 把握 |
|---|---|---|---|---|
| ZUXOS 2.0.12.088（现在用的） | 国行正式 | 06-10 | 电脑上有一套；联想官方 9008 整包也能下，10.05 GB | 高 |
| 152、199、211、222 | 国行正式，中间几版 | — | 只有增量升级包，查询要用设备序列号 | 中 |
| ZUXOS 2.0.12.236 | 国行正式，最新 | 09-11 | **联想官方 9008 整包**，11.59 GB。联想刷机接口 10-19 起给的就是它 | 高 |
| ZUXOS 2.0.12.255 | 国行 | 09-19 | 拿不到。只在 ColorOS 移植包里见过这个名字 | 中 |
| ZUXOS 2.5（安卓 17）内测 | 国行内测 | — | 升级包地址公开，10.27 GB。论坛说这一版**已经封了这类破解** | 中低 |
| ZUI 18.0.12.187 | 海外 | 09-07 | 增量包，或联想救援工具 | 高（Linux 在它上面卡死过） |

### 3. 升级能得到什么

- **Linux**：没找到能修好现有毛病的证据。
  - Wi‑Fi、显卡、音频用的固件放在 Linux 自己的盘里，换底层也不会变。
  - 5 GHz：同一个底层下安卓是稳的，所以问题大概率在 Linux 驱动，跟底层关系不大。
  - 底层里确实有几块会影响 Linux：
    - 内存布局（187 卡死多半就是它变了）；
    - 充电固件；
    - 电源管理固件。
  - 联想的更新说明里，199→211 写过修「非标充电器充电中断」「部分场景耗电快」，但没说改的是底层固件还是安卓。其余说明全是 AI、游戏、人脸这类安卓功能，没有一条提到 Wi‑Fi、基带或开机固件。
- **安卓**：你用的是 ColorOS 界面，联想的新功能用不上。
  - 安全补丁也不吃亏：ColorOS 的系统补丁（2026-09-01）比 255 的（2026-08-05）还新。
  - 底层驱动的补丁，两边都停在 2025-06-05。

### 4. 风险

| 可能发生什么 | 可能性 | 能撤回吗 |
|---|---|---|
| 新开机程序不认破解：Linux、root、ColorOS 全起不来 | 236：查不到；安卓 17 内测：较高 | 能。用 9008 写回 088 的开机程序和破解。前提是没踩下一条，而且按键能进 9008 |
| 新固件带防降级保险丝：再也回不去 088，硬刷就变砖 | 低到中。088 读出来全是 0，但这个数的含义只有中等把握 | **不能**。刷之前能离线查个大概 |
| Linux 开机卡死，像 187 那次 | 中 | 能，但要整机重刷 088，可能还要修分区表里「A 槽不可启动」的标记 |
| 只换一部分底层，是没人走过的组合，开机早期就卡住 | 中 | 同上 |
| 安卓出毛病，要清安卓数据 | 中 | **清了就回不来**：KernelSU、切 Linux 的脚本和 App 会一起没了 |
| 用了联想官方刷机工具或救援 | 不用就不会 | 不能。整个 Linux 盘会被抹掉 |

### 5. 如果要做，怎么做最稳

每次下载、每次动平板，都先问你。

1. **零风险的准备**（不管升不升都值得做）：
   - 在电脑上存一份现在能开机的 Linux 开机镜像。电脑上只有 10-11 的老版本。
   - 把本机专属分区的备份，另存到本地离线存储（U 盘或 NAS）。里面有 IMEI 和射频校准，不放云盘。
2. **不下载的摸底**：另一台机器上还留着海外 104 / 187 的 31 个固件文件。拷过来，就能比对 187 和 088 的内存布局。这是查清「187 为什么卡死」最便宜的办法。走局域网拷贝，你点头我再做。
3. **小下载（每个包几 MB）**：联想服务器支持只读文件里的一小段。
   - 读几个升级包的目录，能看出每一跳换了哪些分区。
   - 只有开机程序是整块替换的，才能顺带读出新开机程序，查它认不认破解。
   - 另有一个公开的安卓 17 内测版解包站，也许能直接看到它的开机程序。还没打开过。
4. **大下载**：官方 236 整包，11.59 GB。在电脑上离线过五道关：
   - 认不认破解；
   - 保险丝的值是不是全为 0；
   - 内存布局是否一致；
   - 分区表和破解分区是否不受影响；
   - 内核的安装方式是否不变。

   任何一道不过就停。
5. **真要上平板，之前还得做完这些**：
   - 先写一个「只写指定分区」的刷机脚本。现在的脚本只会整机重刷。新脚本照搬现有的拦截，并且先离线测过。
   - 当天重做一次备份：分区表和本机专属分区、Linux 的数据、安卓的数据。
   - 实测一次按键进 9008。
   - 换完先开安卓，确认破解还在，读出新的内存表核对一遍；然后再开 Linux。第一次开 Linux，根分区只读挂载。
6. **回滚**：整机重刷电脑上那套 088（不动 Linux 盘，也不动 B 槽），再从安卓切回 Linux。

### 6. 我的建议

继续用 088，不建议上平板，因为看不到收益。

想摸底的话：
- 第 1 步现在就可以做，零风险；
- 第 2、3 步你点头我就做，都不碰平板。

真要往平板上刷，至少等这些都成立：
- 五道关全过；
- 有一个你具体想要的好处；
- 当天的备份已经另存到离线存储；
- 电脑上有当前的 Linux 开机镜像，也有「只写指定分区」的脚本；
- 按键进 9008 实测成功。

---

## 第二部分：技术附录

路径基准：
- Repo = `C:\Users\me\AI\y700`
- UP = `Repo\linux\tb323fu-linux`，行号按 `origin/main`（da44c84）
- 包 = `Repo\coloros-v17\image\`（ColorOS 17 移植包，就是 10-11 刷进去的那套 088 底层）

置信度写作【高 / 中 / 低】。「推断」单独标出，其余是读文件、读网页、本地解析得到的事实。

### A. 调研怎么做的

- 一个 workflow，共 9 个 agent：
  - 6 个调研员，分头查：本机历史、Linux 侧、版本与获取、破解与防回滚、收益、安卓移植与刷写路径；
  - 1 个汇总；
  - 2 个复核：一个专挑事实错误，一个专挑会弄坏平板的步骤。
- 第一部分和本附录已经按两份复核改过，改了什么见 J 节。
- 联网只做了这些：
  - 读网页；
  - 对联想 CDN 发 HEAD 请求（只取文件头，不下正文）；
  - 查一次联想刷机接口，参数只有 `mtm=CN`，没带任何设备信息。
- 没下载任何固件，没碰平板。
- 本地解析只读了包里的镜像和电脑上的文件。本机专属分区的备份只核对了文件名，没打开。
- 调研时存下的网页和接口返回放在本机临时目录，不进仓库。7z 包的解压密码在 4PDA 1119716 主题首楼公开，这里不转抄。

### B. 版本与获取途径

**官方 9008 整包**
- 联想刷机接口 `POST https://ptstpd.lenovo.com.cn/home/ConfigurationQuery/getPadFlashingMachine`（`mtm=CN`）返回 TB323FU 的记录（id 240001）：
  - `latest_version=TB323_ZUXOS_2.0.12.236`；
  - 下载地址 `zsk-cdn.lenovows.com/知识库/Flash_tool_image/TB323_ZUXOS_2.0.12.236_Tool.7z`；
  - `upd_time` = 2026-10-19；
  - 刷机说明是「关机，按住音量上键，用长边接口连电脑」【高】。
- 所以 `zsk-cdn.lenovows.com` 就是联想官方接口给的地址【高】。`android-remove-zui.md` 里「官方 088 包可能拿不到」「236 只有增量包」两条，11-01 已更正。
- 11-01 两次 HEAD 核对（汇总员、复核员各一次）：

  | 包 | 状态 | 字节 |
  |---|---|---|
  | 236 Tool | 200 | 11,586,561,212 |
  | 088 Tool | 200 | 10,048,999,680 |
  | 255 Tool | 404 | — |

  两个 200 都支持 Range（可以只读一段）。
- 整包历史（第三方索引 lenovows.netlify.app）：2.0.11.092 → …043 → 2.0.12.088 → 2.0.12.236【中】。

**增量包**
- 国行正式链：088 → 152 → 199 → 211 → 222 → 236（4PDA #145613417 的累计更新说明）【中高】。
- 各跳大小（lenovo-ota-tool README:12、25、125）：199→211 是 174.9 MB，211→222 是 147.1 MB，222→236 是 263.4 MB。
- 查询要提供设备序列号；增量包会校验源分区哈希【中】。
- `https://otanew-cdn.lenovo.com/firmware/202691510264732-5014.zip`：276,222,566 B（正好 263.4 MiB），Last-Modified 2026-09-15。「这就是 222→236」是按大小吻合判断的，没找到原文【中】。
- 海外 104→187：`https://ota-cdn.lenovo.com/firmware/2026924202414281-3018.zip`，240,623,525 B，Last-Modified 2026-09-24。4PDA #145424833 说「This build still loads efisp」【中高】。
- 安卓 17 内测：
  - 165 升级包 `https://otanew-cdn.lenovo.com/firmware/202692817247199-9790.zip`，10,270,360,053 B，Last-Modified 2026-09-28。
  - 内测链 199 → 2.5.02.053（8.0 GB）→ … → .198（2.8 GB），要白名单序列号（ota-tool README:102-103、126、218）【中】。
  - 4PDA #145307885（10-02 编辑）说这一版「改了 ABL，去掉了运行 GBL root canoe 的可能，只有把 ABL 降回旧的有漏洞版本才行」【中低，单一论坛来源】。同帖链接了 2.5.02.165 的一份第三方公开解包（tadiphone 解包站）。复核时那个站点打不开，没看到内容。

**255**
- 只出现在包里的 `vbmeta_b`、`vbmeta_system_b`：`ZUXOS_2.0.12.255_260919_PRC`。
- system / product / system_ext 的补丁级别是 2026-08-05，回滚号 1785888000；boot / init_boot / vendor 的补丁级别是 2025-06-05【高，本地解析】。
- 网上没找到它的升级包、整包或帖子【中】。

**海外**
- 最新只找到 187。Software Fix 也只给 187（XDA #90773565、4PDA #145478490）【中】。XDA 只读到第 7 页。
- lolinet 镜像只有 CN 088、ROW 084、ROW 104【中】。

**更新说明**（4PDA #145613417，088→236 累计）
- 绝大多数是系统和应用层：AI、游戏、人脸、续航。
- 199→211 有两条可能沾底层：「修复非标充电器中断充电」「修复部分场景耗电快」。没说改在哪一层。
- 没有一条提到 modem、Wi‑Fi、xbl、tz。187 只写了「修 bug、提升稳定性、修第三方桌面」【中高】。

### C. 开机链与 efisp

- **088（和 076）的 ABL 无条件加载 efisp**【高，调研员实测】：
  - 照 LTBox `efisp_load.rs` 的办法查：0x1078 处 LZMA 解压，取最大的 PE，找 UTF-16 字符串的 ADR/ADRP 引用。
  - `efisp` → `Loading GBL app` → `Starting GBL app` 这条引用链在 0x5854 / 0x5cd0 / 0x6924，附近没有 SecureBoot 判断。
  - 复核员确认了字符串和解压位置，偏移本身没复核。
- **我们的 efisp 自带完整的 LinuxLoader**（包 `efisp.img`）：
  - 内含 "ABL_with_superfastboot" 和 mp260201（076 时期，`coloros16-plan.md:43`）；
  - 有 UTF-16 的 "nulls"，没有 UTF-16 的 "efisp"，也就是把自己再去加载 efisp 的那条路改名堵掉了；
  - 推断【中】：abl 分区里的 ABL 只负责启动它。所以升级时保留 088 的 abl 也许可行，前提是新的 xbl 接受旧 abl，而且 abl 的防降级值是 0。
- 187 仍然加载 efisp：`y700-recovery/notes/upstream-bug-report.md:19`；`HANDOFF-windows.md:12-13`（锁着的开机程序下 KernelSU 能用）【高】。
- 高通 2026-03 初把 GBL 漏洞修复发给了厂商（[Android Authority](https://www.androidauthority.com/qualcomm-gbl-exploit-fix-statement-3649176/)）【高】。
- 兄弟机型已经补上的（mkonic redmagic-wiki、SuperTurtleDev/gbl_root_canoe wiki）【中，复核没核】：
  - 小米 HyperOS 3.0.300+；
  - 红魔 .19 MR2，修复在 abl 和 efisp 里，把旧 abl 和旧 efisp 一起刷回就恢复了。
- 联想 236 / 255 有没有打这个修复：**没查到**。
  - 推断【低到中】：236（260911）和 187（260907）是同一时期的安卓 16 构建，可能也没打；
  - 2.5 内测线据论坛已经打了。
- efisp 失效后的后果，推断【中高】：`vbmeta_a` 是 algo 0、没签名，原厂锁定状态的 ABL 会拒绝它，ColorOS 也起不来。

### D. 防回滚

**AVB 回滚号**（vbmeta 头 112 字节处；以前 `analyze_pkg.py` 读成了 96，11-01 已修）

| 镜像 | rollback_index |
|---|---|
| 076 vbmeta_system | 1772668800（2026-03-05） |
| 104 vbmeta_system（`HANDOFF-windows.md:38`） | 1783209600 |
| 255 vbmeta_system_b（包） | 1785888000 |
| 包里的 `vbmeta_a` / `vbmeta_system_a`（现在跑的） | 0，algo 0，未签名 |
| 236 | 未知 |

- 现在这份 superfastboot efisp 能启动回滚号为 0 的 vbmeta，说明它实际上不拦回滚号，或者存储的门槛本来就低【中】。
- 这不能推广到所有 GBL：
  - LTBox 一系有专门的 `_arb` 绕过版本（`gbl-compare\` 里的 `mn-6.2.192-mod2-row_arb.efi`）；
  - 还有「Rollback Protection Bypass」选项（XDA #90774474）。
  - 换别的 efisp，回滚号可能重新起作用。
- 「锁定、green 状态下跑过签名的 187」（`README.md:120-121`）当时也是在 LTBox 的 GBL 下，所以证明不了存储的回滚号被抬高过。
- 网上的中文刷机教程说：未解锁时降级，会因回滚保护无限重启。本机没试过原厂签名的降级。
- `linux/fastboot-getvar-all.txt` 里没有 `stored_rollback_index`。

**熔丝防回滚（ARB）**
- 包里 088 的 35 个签名镜像，在 hash segment metadata v3.0 +8 处，QTI 和 OEM 的值都是 0。`y700-recovery/loader/prog_firehose_ddr.elf` 的 OEM 值是 1。【读数高 / 字段含义中】偏移是从 v2.0 文档和社区工具推出来的。
- 187→088 刷完能开机，说明 187 没把这些镜像的门槛抬到 0 以上【推断，中】。
- 先例：据报道，一加国行 ColorOS 16.0.3.500/501/503 烧了 ARB 熔丝，降级会永久变砖（Notebookcheck 转述 DroidWin）【中】。
- 104、187、236、255 的 ARB 值：全部未知。
- 推断【低】：会去补 GBL 漏洞的版本，也最可能顺手抬 ARB，这两条风险多半不是独立的。

### E. Linux 侧

- 上游只在海外 104 上验证过（UP `README.md:12-14`、`tools/install/install.sh:371-381`）。
- issue [#9](https://github.com/joonhoekim/tb323fu-linux/issues/9) 仍开着：
  - 10-11 有一条评论，要 187 上安卓的 `/sys/firmware/fdt` 和 `/proc/iomem`，没人给过；
  - 10-28 作者指派给了自己【高】。
- 内存保留区的来源：
  - 补丁 0021 只从开机程序拿 `/memory`，reserved-memory 全部来自 kaanapali.dtsi 加 0054【高】；
  - 088 的 `xbl_config_a.img` 偏移 68492 处有内嵌 FDT，`/soc/memorymap` 列着各个固件保留区【高，实测并复核】；
  - 推断【中】：新底层的保留区要是挪了位置，最可能在这里体现。
- 187 卡死的现象：
  - fbcon 之后 ≤50 ms 挂住，约 1.45 s 停止输出（`y700-recovery/README.md:30-40`）；
  - 7–8 s 后被看门狗复位（`HANDOFF-windows.md:24`）【高】。
- 10-10 失败到 10-11 成功之间，同时变了 6 样东西：底层、地区、开机镜像外壳、槽位和启动 LUN、efisp 的 GBL 变体、vendor_boot / dtbo / vbmeta。
  - Codex 当时不认 187 是根因（`README.md:142`），仓库后来认定是 187（`README.md:173`）。
  - 推断【高】：根因从没被单独隔离出来。187 的设备树、`/memory`、pstore 都没采集过。
- Linux 自己从 `/lib/firmware` 加载 Wi‑Fi、显卡、DSP 固件，哈希来自 104（UP `firmware/README.md:21`、`README.md:3562`）。换底层不会换掉它们【高】。
- 新的 TZ 会不会拒绝旧版 DSP 固件签名（remoteproc 认证失败）：不知道。换完要看 `qcom_q6v5_pas` 的日志。
- **boot_b 和装内核绑在一起**：
  - helper 装每个内核都用 boot_b 当外壳，并核对 `android-boot.sha256`，initramfs 里还用 `-a` 编进了同一个哈希（helper `kernel.rs:775-782`）【高】；
  - 平板上的 boot_b 是包里的 `boot_a.img`（`README.md:174`、`flash_coloros.py:42`）。**千万别拿包里的 `boot_b.img`（255 指纹）去写 boot_b**：哈希会对不上，装不了内核；
  - 包里 `boot_a.img` 和 `boot_b.img` 的 boot hash 描述符一样（摘要 `8edebf602e0779e4…`、39976960 B、回滚号 1749081600），只差指纹属性【高】。
- 「255 和 088 的设备树一样」不成立：
  - 包里的 `vendor_boot_b.img` 指纹是 `qti/canoe/canoe:16/BP2A.250605.015/1779898474116`（2026-05-27）、algo 0、18051072 B；
  - `vbmeta_b` 记录的联想 255 vendor_boot 是 18055168 B；
  - 它和 `vendor_boot_a` 在 4408 个 4K 块里有 4407 块不同；
  - 所以那是另一份 vendor_boot，不是联想 255。255 的设备树仍然未知【高】。

### F. 收益（都没有证据）

| 问题 | 和底层的关系 | 新底层会不会好 |
|---|---|---|
| 5 GHz 断流 | 安卓在同一底层下 5 / 6 GHz 都稳（`README.md:240`）；作者在 ROW104 上 5 GHz 正常、我们在 088 上不行（`README.md:3559`），底层和地区没分开测过 | 大概率不会，问题多半在 ath12k 驱动侧【中】 |
| 充电 / 电量 | SoCCP 由开机程序加载（`README.md:424`），088 的版本串是 `dev_build-00001-dev_build_client-01` | 199→211 修过「非标充电器中断充电」，不知道在哪一层【低】 |
| 簇下电 / 熄屏复位 | ROW104 和 088 表现不同（`README.md:4108`），088 上 E1、E3a 零复位（`README.md:1666`） | 088 已经是好的那一侧【中】 |
| 10-31 21:04 显示寄存器总线错误 | 没有指向底层的证据 | 不知道 |
| 安全补丁 | ColorOS 系统层 2026-09-01（`README.md:604`），255 系统层 2026-08-05；vendor / boot 两边都是 2025-06-05 | 没好处【高】 |

### G. 刷写路径与回滚

**哪条路能走**
- 在线升级走不了：
  - 上层是 ColorOS，没有联想 OTA（`README.md:163`）；
  - 增量包要求源分区是官方原样（ota-tool README:25、222-224），我们的 vbmeta / init_boot / boot 都改过；
  - A/B 升级写的是另一个槽，而我们的 boot_b 另有用途。
- 官方工具和 Software Fix 救援：会清空整机、装最新版（UP `docs/recovery.md:107-109`），还会把 LUN0 分区表恢复成出厂样子，`baldur-root` 会丢【高】。**不用。**
- `prep_pkg.py` + `flash_coloros.py` 是**整机**流程：
  - 重写 6 个 LUN 的主备分区表；
  - 写 20 GiB 的 super 和 A 槽全部分区（含 boot_a）；
  - `ddr` 清零（`prep_pkg.py:9-10`）；
  - 只有 userdata、`_b` 和本机专属分区不写（`prep_pkg.py:11-13、22-25`，`flash_coloros.py:192`）。
- 拿它刷新包，会把 ColorOS 换成 ZUXOS 236、init_boot 换成原厂的（root 没了），boot_b 和 super 也对不上了。**不要拿整机流程刷新包。**
- **现在没有「只写指定分区」的脚本**。唯一的单分区写入是 `linux/restore-coloros-boot.sh`，只写 boot_a。要试只换底层，得先写一个，照搬 `flash_coloros.py` 的拦截：
  - 不写本机专属分区，不写 `_b`；
  - 没有比上次刷写更新的备份就不写（`flash_coloros.py:280-282`）；
  - 写完回读核对。
- 联想发版是整套底层一起换的：104→187 改了 54 个分区，含 `tme_*`、`pdp`、`uefi`、`abl`（`upstream-bug-report.md:19`）。仓库自己的规矩也是遇到混合固件就停（`prep_pkg.py:44-46`）。
  - 要拆开只换一部分，先得把 236 和 088 的整套底层分区、6 个 LUN 的分区表逐项对比；
  - 列出必须同进同退的分区：`*_ac_config`、`tz_qti_config`、`tme_fw/config/seq_patch`、`shrm`、`multiimg*`、`uefisecapp`、`keymaster`、`secretkeeper`，还有 `ddr` 清零；
  - 分区大小或位置有任何变化就停。LUN4 上有 `efisp` 和 `boot_b`。

**回滚到 088 = 整机重刷**
- 顺序：`flash_coloros.py backup` → `flash --pkg v17 --efisp keep --yes` → `verify`。
  - 会写：分区表、super、A 槽全部，boot_a 变回 ColorOS 的开机镜像；
  - 不动：userdata、baldur-root（起点和 GUID 不变）、B 槽。
- 破解用包里的 `coloros-v17\image\efisp.img`，**别用** 10-11 备份里那份。那份是旧的 LTBox 6.2.192-mod2 海外版（`coloros16-plan.md:43`）。
- 回 Linux 有两条路：
  - 靠安卓里的切换脚本，前提是安卓数据还在（`README.md:212`）；
  - 或者把电脑上事先存好的当前 Linux 开机镜像，经 9008 写进 boot_a。这份镜像现在没有，只有 `linux\round1\linux-t47-coloros17-boot.img`（10-11）。
- 开机失败的话，ABL 会把整个 A 槽标成不可启动，写回分区也去不掉这个标记，要用 EDL 重写分区表（UP `docs/recovery.md:75-82`）。电脑上的分区表副本都不是当前的：
  - `flash-logs\20261011-015720-probe\gpt\` 是刷之前读的，当时 A 槽标着 0xf3（`README.md:120`）；
  - `postcheck\lun4.bin` 是 02:07、第一次开机之前的。
- 内核要是在 `/init` 之前就挂住，不算失败的一次尝试，只能靠 EDL 救（UP `docs/notes/kernel-updates-design.md:689-693`）。这就要按键进 9008 好使，而它在现在的开机程序下没实测过。
- 按键进 9008 是芯片 ROM 处理还是 xbl 处理，没查到。在 088 下测通，不代表换了新 xbl 也一定行【低，推断】。

**电脑上已有的回滚材料**（只核对了路径和文件名）
- `coloros-v17\image\`，170 个文件：
  - 全部必需镜像、`super.img`（20 GiB）、`efisp.img`；
  - `flash_lun0..5.xml`、`flash_lun4_keep-efisp.xml`、`patch0..5.xml`、`gpt_main/backup0..5`；
  - `init_boot_a.img` 是 KernelSU 版，和 `patched\init_boot_a-ksu-official.img` 一样。
- `patched\SHA256SUMS`、`y700-recovery\loader\`（firehose，9 个文件）、`edl-win\edl.py`。
- `flash-logs\20261011-015806-backup\backup\`：24 个镜像加 SHA256SUMS。缺口：
  - 是 10-11 刷之前备的；
  - 没有 `abl_b`、`boot_b`（`README.md:4768`）；
  - 里面的 efisp 是旧版；
  - 只能作参考，代替不了当天的新备份。
- **两份清单已经过时，别照它们去「修」**：
  - `image.SHA256SUMS` 和 `patched\SHA256SUMS` 第 2 行对 `init_boot_a.img` 期望的是 `.orig`（6ccea…），现在的文件是 KernelSU 版（ae29…）；
  - `gpt_main0.bin` 是 10-13 04:46 重新生成的（7e0c…），清单（10-11 01:35，8bd2…）和 `.orig` 都对不上；
  - 回滚以 `flash_coloros.py plan` 和 verify 的分区表检查为准。
- 新包要是做 KernelSU 镜像，用新文件名、新清单另存。`patched\init_boot_a-ksu-official.img` 和 `patched\SHA256SUMS` 原样保留，它们是回滚 088 的依据（`flash_coloros.py:140、143-152` 认的是这个固定文件名）。

**B 槽现在是什么**
- B 槽的固件分区多半还是 187 留下的：10-11 那次排除了所有 `_b`，OTA 之后就没人写过。没在平板上核实【推断，中高】。
- A 槽开不起来时，可能会落到这套 187 上。
- boot_b 现在放的是 ColorOS 的开机镜像。

### H. 离线检查清单

**① 不用下载**
1. ~~修 `analyze_pkg.py:51` 的偏移~~：11-01 已修（回滚号 112、flags 120），用包里的 `vbmeta_system_b.img` 读出 1785888000 核对过。
2. 把三样东西写成脚本，先在 088 上跑出基线：
   - ARB 解析（hash segment v7、metadata v3.0 +8）；
   - 照 LTBox `efisp_load` 的 efisp 引用链检查；
   - `xbl_config` 的 memorymap 导出。
3. 三个开机镜像跑 `boot-repack-kernel.py --self-test`。
4. 比对 `gbl-compare\` 里 `_arb` 变体和普通变体差在哪。
5. 在电脑上存一份当前 Linux 开机镜像（要从平板读，零风险，但算动平板，先问）。

**② 局域网拷贝（要作者点头）**
6. 另一台机器上（Codex 当时的工作目录）的海外固件：ROW104 整包 6.4 GB（`HANDOFF-windows.md:38`），另有 31 个 104 / 187 固件文件（`:69`）。查 187 的 ARB、abl，以及 xbl_config / vendor_boot / dtbo 和 088 的差异。这是查清 187 卡死最便宜的办法。
7. 另一台机器上 088 的整机备份（25.2 GiB）：查里面 `-cow` 快照是哪个版本，读原厂签名 vbmeta_system 的回滚号。

**③ 小下载（HTTP Range，每个包几 MB，要作者点头）**
8. 读 222→236、104→187、165 三个升级包的 zip 目录和 payload manifest，看每一跳写了哪些分区、abl 和 xbl_config 动没动。
9. abl 是整块替换（REPLACE）的话，再单独读出那约 1 MB 跑 G1。如果是差分，或者这一跳没改 abl，这一步就回答不了。
10. 试打开 tadiphone 的 2.5.02.165 解包页面，看有没有 abl 和 vbmeta。

**④ 大下载（要作者点头）**
11. 236 Tool 整包（11.59 GB）：跑下面全部闸门。
12. 088 Tool 整包（10.05 GB），可选：当干净参照，校验手上那套 088。

**⑤ 要碰平板（要作者点头）**
13. `fastboot getvar stored_rollback_index:1/2/3`（这台在 fastboot 下只用过 `getvar`）。
14. 只读哈希一遍 B 槽固件。
15. 实测按键进 9008。

**闸门（任一不过就停）**

| 闸门 | 通过条件 |
|---|---|
| G1 | 新 abl 里 efisp 的加载引用链还在，附近没有 SecureBoot 判断 |
| G2 | **每一个**会在平板上跑的新镜像，ARB 都等于 0；有一个大于 0 就停（firehose 的 1 不算参照） |
| G3 | `xbl_config` 的 memorymap、reserved-memory 和 088 一致，或者差异已经补进 DTS |
| G4 | 6 个 LUN 的分区表和 088 一样（大小、位置），efisp 和 boot_b 所在的 LUN4 不用重写 |
| G5 | boot.img 仍是 v4、没有 ramdisk，`--self-test` 通过，boot_b 不动 |

### I. 真上平板时的顺序（只是记下来，没打算做）

1. 当天：
   - `flash_coloros.py probe` + `backup`（只读，存 6 个 LUN 的分区表和本机专属分区，含 abl_b、boot_b）；
   - 备份 Linux 根分区的重要数据：/home、/etc、/root、/usr/local、/var/lib/tb323fu（含 linux-good.img）；
   - 备份安卓数据；
   - 都另存到本地的 U 盘或 NAS，不进云盘（`persist`、`modemst`、`fsg` 里有 IMEI 和射频校准）。
2. 实测按键进 9008。
3. 先把 boot_a 切到 ColorOS，用新写的「只写指定分区」脚本换底层：
   - abl 优先保留 088，只有 G2 证明新 abl 的 ARB 为 0 才考虑换；
   - modem、dsp、bluetooth、super 保持 088 不动。
4. 换完：
   - 先再测一次按键进 9008；
   - 开安卓，确认破解还在；
   - root 读 `/sys/firmware/fdt`、`/proc/iomem`，过 G3。
5. 再开 Linux。第一次用 SD 救援盘，或者根分区只读挂载，别直接读写 baldur-root。保留区要是错了，写盘可能写坏数据，而 y17 开机会跑 `e2fsck -p`。看这几样：
   - dmesg 里的 `builtin FDT: took /memory`；
   - `/proc/iomem` 和 088 对比；
   - `remoteproc` / `qcom_q6v5_pas` 有没有认证错误；
   - 充电。
6. 不过就整机回滚 088（G 节）。

### J. 复核改了什么

| 初稿 | 改成 |
|---|---|
| 「技术上可以只换底层、保留 Linux 和 root」 | 也许可以，但这台从没试过，上次换底层 Linux 就起不来 |
| 「底层里只有充电固件影响 Linux，没有任何说明修过充电」 | 影响 Linux 的还有 xbl_config（内存布局）、tz / hyp、aop / cpucp、soccp；199→211 修过非标充电器中断充电 |
| 「255 的安全补丁和 088 一样」 | boot / vendor 一样（2025-06-05）；系统层 255 是 2026-08-05，ColorOS 已是 2026-09-01 |
| 「走 efisp 不检查 AVB 回滚号【高】」 | 只能说现在这份 efisp 不拦【中】；LTBox 一系有 `_arb` 绕过版本，换 efisp 可能重新起作用 |
| 「2.0.12.152 出处不明」 | 出自 4PDA #145613417：088→152→199→211→222→236 |
| 「读几 MB 就能看出新开机程序认不认破解」 | 只有 abl 是整块替换时才行 |
| 「在线升级写的是 B 槽（ota-tool README:25）」 | 那行说的是源分区校验；更根本的是上层是 ColorOS，没有联想 OTA |
| 「原厂锁定下降级会无限重启」 | 是 HANDOFF:38 转述的教程，本机没试过 |
| 「一加烧熔丝【高】」 | 据报道【中】 |
| 「只用我们自己的 9008 脚本换几块分区」 | 没有这种脚本；现有的是整机重刷，要先另写并照搬拦截 |
| 「把 prep_pkg / flash_coloros 改一改刷新包」 | 不要：会换掉 ColorOS 和 root，和 boot_b 对不上，还会覆盖回滚 088 用的 KernelSU 镜像 |
| 「先换启动链那一组，别的不动」 | 联想是整套一起换的；拆开前要逐项对比整套分区和 6 个 LUN 的分区表 |
| 「另存 10-11 的备份就够」 | 不够：缺 abl_b / boot_b、efisp 是旧版；要当天新备份，加 Linux 数据和安卓数据，只存本地离线存储 |
| 「清安卓数据：能撤回」 | 清了就回不来，连切 Linux 的路一起没了 |
| 「刷回 088 就能撤回」 | 还要：按键能进 9008、当前的分区表副本（A 槽不可启动标记）、用对的 efisp |
| 「换完先开 Linux」 | 先开安卓，读出设备树和内存表过 G3，再开 Linux，根分区只读 |
| 「G2：ARB 为 0 或不高于 088」 | 每一个新镜像都必须等于 0 |
| 「复核哈希」 | 两份清单对 init_boot_a.img、gpt_main0.bin 已过时，不符是预期的 |
| 「boot_a 和 boot_b 一样」 | 指包里的两个文件；平板上的 boot_b 是包里的 boot_a.img，别拿 boot_b.img 去写 |
| 若干行号 | 改正：README 120-121、240、424、1666、4108；HANDOFF:24；UP recovery.md:107-109、123；install.sh:371-381；kernel.rs:775-782；整包历史从 2.0.11.092 起 |

### K. 没核实的

- 236 的补丁级别、回滚号、ARB，以及它的 ABL 认不认 efisp。
- 255 是不是正式发布过。
- 187 卡死的根因：187 的设备树、`/memory`、pstore 都从没采集过。
- 联想会不会烧熔丝。ARB 字段的含义只有中等把握。
- 076 时期的旧 LinuxLoader 能不能和新的 tz / uefi 配合。
- 新底层配 088 vendor，安卓的密钥库、音频、传感器会不会出问题；回到 088 后密钥会不会用不了（RPMB 状态没法用 9008 恢复）。
- 新 TZ 会不会拒绝 Linux 里旧版 DSP 固件的签名。
- 按键进 9008 是 PBL 还是 xbl 处理的。
- LTBox 的 Keep Data 能不能保住我们改过的 LUN0。
- 4PDA 帖子里 236 旁边那个「1943 МБ」是什么。
- 海外有没有比 187 更新的版本。
- 小米、红魔补丁的细节；LTBox 引用链的三个偏移；tadiphone 解包的内容。

### L. 出处

- **仓库**：
  - `README.md`：118-187 的 10-10 / 10-11 段、212、240、424、604、1666、3559-3562、4108、4768 等；
  - `android-remove-zui.md`、`coloros16-plan.md`、`coloros17-analysis.md`；
  - `prep_pkg.py`、`flash_coloros.py`、`analyze_pkg.py`、`linux/restore-coloros-boot.sh`、`linux/fastboot-getvar-all.txt`；
  - `y700-recovery/README.md`、`y700-recovery/HANDOFF-windows.md`、`y700-recovery/notes/upstream-bug-report.md`；
  - `gbl-compare\`；包里的 vbmeta / boot / vendor_boot / xbl_config / efisp / abl。
  - （`linux/fastboot-getvar-all.txt` 和 `y700-recovery/notes/upstream-bug-report.md` 不随公开仓库发布；`gbl-compare\` 也不发布，见 coloros16-plan.md。）
- **上游**（UP，origin/main）：
  - `README.md`、`docs/recovery.md`、`docs/rooting.md`、`docs/notes/kernel-updates-design.md`；
  - `tools/install/install.sh`、`firmware/README.md`、`kernel/patches/0021-…`、`helper/crates/tb323fu-helper-core/src/kernel.rs`；
  - issue [#9](https://github.com/joonhoekim/tb323fu-linux/issues/9)。
- **网上**：
  - 联想刷机接口（`ptstpd.lenovo.com.cn`）；
  - [aweiyry/lenovo-ota-tool](https://github.com/aweiyry/lenovo-ota-tool)，第三方索引 lenovows.netlify.app，lolinet 镜像；
  - 4PDA #145613417、#145307885、#145424833、#145478490；XDA #90773565、#90774474；
  - [Android Authority：高通回应 GBL 漏洞](https://www.androidauthority.com/qualcomm-gbl-exploit-fix-statement-3649176/)；
  - [Notebookcheck：一加熔丝式防回滚](https://www.notebookcheck.net/New-OnePlus-software-updates-add-Samsung-style-ARB-with-permanent-brick-risk.1208015.0.html)；
  - mkonic redmagic-wiki、SuperTurtleDev/gbl_root_canoe wiki、LTBox（miner7222）。

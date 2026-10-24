# 5 GHz：ArmadaOS PR #594 补丁评估（对抗核验后的建议，2026-10-16）

## 结论

- **ArmadaOS 的 1022、1023 不采纳**，它们的前置 1021-timeout 和 1020 也不采纳。这两个补丁在我们的固件上根本不会触发。证据是固件自己上报的能力数据：10-11 调试模块的原始日志里就有，离线找到了，见下文“关键证据”。打进去就是死代码，还要连带 1021-timeout，总共改动 +343/−23 行扫描状态机。
- **1021-freq（single-pdev 频率范围修复）对 5 GHz 丢信标没用。** 国家码为 JP 时，它对下发给固件的信道表没有任何影响。它是一个正确、很小的修复，等下一次本来就要重编内核时顺手进 series 即可。**不为它单独出 y11，也不单独编模块。** y11 这个名字已经被 1044 的 DC ZVA A/B 实验占用，见 `kbuild-y11.sh:2-8`；`Y10-NOTES.md:68` 规定 E2 结果为阳性才做 y11。
- 5 GHz 维持 10-11 作者的决定：当作已知限制，日常用 6 GHz，一切不动。**今天在平板上不需要做任何测试。**

## 关键证据（离线，读的是本机留存的 10-11、10-13 调试记录）

摘录已存到 `5ghz-eval/verifier/evidence-offline.txt`。来源有两份记录：
- 10-11 的记录：2026-10-11T08:50:51Z 的 `/root/wifi-init.log`，用 y700-dbg 模块抓的，`debug_mask=0x62`，固件 `0x200a8555`，和现在用的是同一版（inventory/dmesg:1140）。
- 10-13 的另一份记录。

1. 原始 PHY 能力，来自 `wmi.c:5032`、`wmi.c:5648` 两处的原样打印：
   - `num hw modes 2 preferred_hw_mode 5`
   - `hw_idx 1 hw_mode_id 5 hw_mode_config_type 5 supported_bands 1 phy_id 0 2 GHz [0 - 0] 5 GHz [0 - 0]`
   - `hw_idx 1 hw_mode_id 5 hw_mode_config_type 5 supported_bands 2 phy_id 1 2 GHz [0 - 0] 5 GHz [0 - 0]`
   - `sbs_lower_band_end_freq 0`
2. 加工后的转储，来自 `wmi.c:5515`：`frequency range: DBS(1) mac 1 … 5 GHz [4890 - 7125]`。这里的 4890 和 7125 只是 ath12k 在原始值为 0 时填的默认钳位值（v7.3-rc4 `core.h:543/546`、`wmi.c:5352-5359`），不是固件给的数。
3. JP 下发给固件的信道表（未打补丁的 reg.c）：
   - `WMI no.of chan = 58`
   - `chan[14] = 5180`、`chan[51] = 6295`
   - 58 = 14 个 2.4 GHz + 20 个 5 GHz（36–64、100–144）+ 24 个 6 GHz（1–93）。
4. 5 GHz 关联记录：
   - HOME_5G 在 5180 MHz。
   - OFFICE_AP 在 5200 MHz。
   - **手机热点 PHONE_AP 也在 5200 MHz**：80 MHz HE，y3 上 `beacon loss: 0`。同一次开机里 OFFICE_AP 在 5200 MHz 反复 BEACON-LOSS，reason=4。

## 对两位研究员关键论断的核验

### (a) 1022/1023 的触发条件

条件在叠加后的 `mac.c:5268-5294`：

```c
if (!low[0] || !low[1] || low[0] >= high[0] || low[1] >= high[1] || high[0] == high[1]) return 0;
```

`low[]` 只取 DBS_OR_SBS 模式下带 `WMI_HOST_WLAN_5GHZ_CAP` 的 PHY 的原始 `low_5ghz_freq`。我们这台的数据有两处各自就让条件不成立：
- phy0 的 bands=1，没有 5 GHz 位，被跳过，所以 `low[0]=0`。
- phy1 的原始 `low_5ghz_freq` 本身就是 0，所以 `low[1]=0`。

结果 `split_freq` 恒为 0。1023 的 `split_scan` 也要求 `split_freq` 非 0（叠加后 `mac.c:6020-6025`），所以 1022 和 1023 都是死代码。

1022 在门槛之外唯一的改动，是把扫描超时的 cancel 挪到了 `work_complete`，无害。

各方论断的结果：
- **推翻** A 的“门槛状态未知、置信度低”。
- 10-11 的结论“MAC0 只有 2.4 GHz”是对的。A 怀疑“4890–7125 是钳位值”也是对的，只是这一点不影响结论。
- **推翻** A 和 B 都用过的旁证“dmesg 里没有 `Invalid DBS/SBS mode with only 2.4Ghz`（wmi.c:5551），所以削弱了 MAC0 只有 2.4 GHz”。真正的原因是 `wmi.c:5673-5675` 的条件：`sbs_lower_band_end_freq || low_5ghz_freq || low_2ghz_freq` 三项全是 0，SBS 范围从来没被填过，所以 5551 根本走不到。A 列的三种解释都不是实际情况。
- **推翻** B 的 SBS/ASYNC_SBS 解释。B 自己定的证伪条件是“热点在 5 GHz 下半段就不成立”，而热点在 5200 MHz，就在下半段：
  - 热点在 5200 MHz、80 MHz 下稳定（README:453/659）。
  - OFFICE_AP 同样在 5200 MHz，却会断（README:659）。
  - HOME_5G 限制到 80 MHz 后，中心 5210，和热点在同一个 80 MHz 块里，照样断（README:153）。
  - 按信道把频段分给不同 MAC 的机制，解释不了“同一个频点，有的 AP 好、有的 AP 坏”。
  - 另外，iceland 0067 修的症状是“未关联时扫不到 36–64”（它的提交说明），而我们能扫到 5180/5200 并能关联。

### (b) 原代码下 `ar->freq_range` 的值

在我们这台机器上，原代码这样算：
- 2.4 GHz 段：`cap.band[1]` 实际是 `band[NL80211_BAND_5GHZ]`，`phy_id` 为 1，所以取 `hal_reg_cap[1]`（reg.c:301-311）。
- 5 GHz 段：因为 `supports_6ghz` 为真被跳过（reg.c:313）。
- 6 GHz 段：沿用同一个 `reg_cap`（reg.c:325-330）。
- 三段并成一个连续区间（mac.c:14125-14139）。

实测下发 58 个信道，2.4、5、6 GHz 都在，所以范围约为 2402 到 JP 6 GHz 规则上沿（约 6425）。**A 的结论成立**，而且证据从推断变成了实测。

修复后：
- 2.4 GHz 段改用 `hal_reg_cap[0]`。
- 多出一个 5 GHz 段。
- 并集不变，所以 JP 下零变化。

B 的说法“只在没有 6 GHz 规则的国家码下才有影响”，代码上成立：
- reg.c:718-719 把 `reg_freq_6ghz` 初始化为 INT_MAX/0。没有 6 GHz 规则时 6 GHz 段的 `freq_high=0`，被 mac.c:14128 丢弃，范围只剩 2.4 GHz。
- 5 GHz 信道于是被 reg.c:156-160 和 194-198 从信道表里滤掉。
- 这很可能就是 README:152 里 CN 那次连不上的原因。CN 规则里是否确实没有 6 GHz，没核实。

两处小错：
- A 写的“band[2] 是 6 GHz 那项”不对。`enum nl80211_band` 里 2 是 `NL80211_BAND_60GHZ`，6 GHz 是 3（nl80211.h v7.3-rc4:5970-5976）。这一项在我们机器上不会用到，不影响结论。
- B 写的“覆盖到 7.1 GHz”不准确。JP 下上沿是 6 GHz 规则的上沿，约 6425。

是否已经进上游：
- A 和 B 在 10-16 拉的 ath-next、linux-next 的 reg.c 完全相同（blob 7cf3dbc4），303/313/315 行都是原样，没有合入。
- 我重新拉取时 git.kernel.org 返回了人机验证页，按规定没有绕过，所以没能独立复核。
- ath-current 没有人查过。

### (c) 1023 的机制和我们的症状对不上

即使不考虑门槛，也对不上：
- 1023 只在主机发起 hw_scan 时起作用。`linux/wifi/wifi5g-test.sh` 那次测试脱离了 NM（`managed no`），配置里也没有 bgscan，照样复现。
- 主机扫描造成的离信道和连哪个 AP 无关，可是同一频点上热点好、OFFICE_AP 坏。
- 6 GHz 在同样的扫描环境下正常。
- 链路是彻底死掉（y3 上连 mac80211 自己的探测都失败），不是扫描期间的间歇丢包。

需要注意：“射频大部分时间不在信道上”本身只是推断。10-11 的 HTT 数据是 `rx_suspend_cnt` 18→45→73、`rx_resume` 17→44→73，但没有 6 GHz 或热点的对照组。

### (d) git apply --check（我自己重建的仓，在 `verifier/repo`）

基线的构成：
- v7.3-rc4 的 5 个文件。blob sha 和 GitHub tree API 对过，一致：mac.c 99bf5cf7、core.c 262a2045、core.h a98fc6e0、wmi.c d5160af6、reg.c 89abf2e8。
- 加上 0024、0058、0113。
- 加上 `y700-y9.patch` 的 ath12k 部分。

这样重建出的 ourtree 五个文件和 A 的 blob 完全一致，1041 的 reverse-check 也通过。打补丁的结果（`verifier/apply-check-summary.txt`）和 A 完全一致：

| 打法 | 结果 |
|---|---|
| 1020、1021-timeout、1021-freq 各自单独打 | 成功，只有行偏移 |
| 定稿版 1022 单独打 | 失败：mac.c:5305，**另外 core.h:645 也失败**（A 漏了这一处） |
| 1023 单独打 | 失败 |
| 1020→1021t→1021f→1022→1023 整套 | 成功 |
| 不带 1020 | 成功 |
| 只打 1021t+1022+1023 | 成功 |
| 9cfb97f4 版的 1022 单独打 | 成功 |
| 9cfb97f4 版叠在 1021-timeout 之后 | 失败 |

叠加结果和 A 的 st-main 完全相同（blob 一致）。

两点补充：
- A 说“ArmadaOS 自己的树在 20:18–20:33 之间打不上”，这只是从我们树上的结果外推的，没有在 ArmadaOS 的 7.2.6 树上验证。
- README:404 说的“1023 要手工重定基”，指的是 armadaos-freedom 的 runtime-fixes 版本，和这次的不是同一份文件。

### (e) B 的平板实验安全吗

现在不需要做。既然 1022/1023 已被证明是死代码，这个实验对“采纳哪个补丁”没有任何决定作用。万一作者以后想重开 5 GHz，必须先改下面这些问题。

脚本的问题：
1. `y700-5g-restore.sh:11` 在它自己的 ExecStopPost 里执行阻塞式的 `systemctl stop y700-5g-exp.service`，很可能一直等自己，直到 TimeoutStopSec，restore 中途被杀。要改成 `systemctl --no-block stop`。
2. `y700-5g-exp.sh:27-30` 停掉 y700-kmsg-watch，会把显示看门狗的触发也一起停掉（y700-kmsg-watch:53-54）。更好的办法：先备份 `/run/y700-wifi-watchdog.last`，再写入 `"$(date +%s) ok"`，让 Wi-Fi 看门狗进入 600 s 冷却（y700-wifi-watchdog:14-21）；restore 时先还原这个 stamp。
3. `restore.sh:26` 的兜底是调用看门狗，但看门狗要 3 分钟内至少 2 次 flush 失败才会重载，还受冷却期限制，很可能什么都不做。要补一个无条件的重载：radio off → `modprobe -r ath12k_wifi7 ath12k` → `modprobe ath12k_wifi7` → radio on，再 `nmcli con up HOME_6G`。最后一招是事先说明后重启。
4. `exp.sh:60-80` 任由 wpa_supplicant 循环重连 120 s。10-13 那次整机硬复位，正是发生在这种循环里（README:658）。要改成第一次 `CTRL-EVENT-DISCONNECTED` 或 `api_connection_loss` 出现就 `nmcli con down`。
5. `exp.sh:35-41` 把 PSK 放在命令行参数里。改用下面两条，脚本全程不接触密钥：
   ```
   nmcli connection clone --temporary HOME_5G y700-5g-test
   nmcli connection modify --temporary y700-5g-test 802-11-wireless.bssid … 802-11-wireless.band a
   ```
   然后用 `nmcli -f NAME,FILENAME con show y700-5g-test` 确认它在 `/run` 下，没有写到磁盘。
6. `exp.sh:71` 每秒一次 survey dump。对正在用的信道，ath12k 会发 WMI 并持着 wiphy 锁最多等 3 s（v7.3-rc4 mac.c:13637-13647，调用点在 13694）。在坏掉的状态下，这会干扰 mac80211 自己判断断线的时机。改成每 5 s 一次。
7. 变体 E2（只扫 5 GHz 下半段或上半段）要验证的 SBS 假说已经被热点数据否掉，删掉。
8. A 提的 kprobe + 重载驱动那一步，要的数据已经在 10-11 的日志里，也删掉。

开跑前提：
- 12:30 以后。
- 作者在场，且不在用机。
- `cat /sys/module/qcom_scm/parameters/download_mode` 必须是 `off`（由 y700-dumpmode-off.service:17 设置）。否则一旦硬复位，平板会停在 900E 转储模式耗电（README:895）。

## 平板测试计划（按顺序）

**今天（12:30 后，经作者同意）：只做只读和存档，不碰射频。**

```sh
ls -la /root/wifi-init.log /root/wifi-dbg2* /root/wifi-htt/ 2>/dev/null   # 决定这次结论的原始日志还在不在
cat /sys/module/ath12k/version; iw dev wlp1s0 link | head -3; cat /sys/module/qcom_scm/parameters/download_mode
```

- 预期：版本是 `y700-1041`，连着 HOME_6G，`download_mode` 是 `off`。
- 只要日志文件还在，就 `scp` 回仓库，比如 `linux/wifi/logs-1011/`（是否提交另行决定）。
- 判定：这一步只为存档，不改变任何结论。

**以后某次本来就要编内核时：1021-freq 顺手带上。**

1. 把补丁放进 series，排在 1041 之后，按应用顺序写明，例如 `1046-wifi-ath12k-fix-single-pdev-frequency-ranges.patch`。
2. 在 kbuild 里加断言：

   ```sh
   grep -q "cap.band\[NL80211_BAND_2GHZ\].phy_id" drivers/net/wireless/ath/ath12k/reg.c
   grep -q "single_pdev_only))" drivers/net/wireless/ath/ath12k/reg.c
   ```
3. 照常 `install-local --trial` 安装，然后重启。
4. 验证：
   - `iw reg get` 显示 country JP。
   - HOME_6G 自动连上。
   - `ping -c 300 -i 0.2 192.168.0.1` 零丢包。
   - `nmcli -f SSID,CHAN dev wifi list` 里 2.4、5、6 GHz 的网络都能看到。
5. 判定：和 y10 没有区别就 keep；有区别就是回归，不确认 keep，trial 会在两次启动后自动回到 y10。
6. 不需要做 CN 实验：平板只按 JP 规则用，修了也没收益。

**不要做：**
- 现在单独编带 1022/1023 的模块。
- 把测试模块放进 `/usr/local/lib/modules/y700/<release>/`。按 `linux/wifi/y700-ath12k.conf` 的 install 规则，放进去就会每次开机都加载，直接影响日常 6 GHz。

## 诚实的不确定性

- 固件可能不按自己上报的能力行事。比如它内部有离信道或 SBS 行为，而能力数据里看不出来。
- ath12k 在 `core.c:942-947` 向固件请求 `hw_mode_index 1`（DBS），可固件只列出了模式 0 和 5，而且 ath12k 不处理 SET_HW_MODE 的响应事件。固件把这个 1 当成什么、有没有影响，未知。这只是一条线索，不是证据。
- “射频不在信道上”这个说法缺对照组；HTT 统计里的 `mac_id = 1` 对应哪个物理 MAC，也不确定。
- 热点在 y3 上稳定，OFFICE_AP 在同一次开机里不稳定。但 OFFICE_AP 带宽是 160 MHz 的那条样本来自更早的一次开机（那次开机也处在发送卡死状态）。
- 1021-freq 是否已进 ath-next：用的是两位研究员 10-16 拉的副本，我重拉被人机验证挡住了。ath-current 没人查过。lore 上的讨论原文没看。
- 本机没有 arm64 工具链，补丁只验证了能打上，没有编译验证（1021-freq 只有 3 行）。
- CN 规则里是否确实没有 6 GHz，没核实。
- 平板上 systemd 自己 stop 自己时的行为、`nmcli clone --temporary` 的写法，都没实测。
- 5 GHz 的根因仍然未知。线索依旧指向 AP 一侧的差异：坏的两个 AP 都开 160 MHz BSS，热点是 80 MHz 的 Wi‑Fi 6。最有价值的下一步仍是 README:162 写的：在安卓下抓 qcacld 的 WMI 日志，和 Linux 逐条对照。

## 文件

都在 `5ghz-eval/verifier/` 下：
- `repo/`：tag `ourtree`、`full-series`。
- `apply-check.log`、`apply-check-summary.txt`。
- `evidence-offline.txt`。
- `armada/{main,21316f04,9cfb97f4}/`：从 raw.githubusercontent 取的补丁，main 和 21316f04 逐字相同。
- `dl/`：v7.3-rc4 的 wmi.h、hw.h、dp.h、nl80211.h，以及 GitHub tree 的 JSON。
- `ourtree-plus-armada-main-series.verifier.diff`。

# 下一版内核要带上的东西（排队区，2026-11-05 起）

不值得为它单独编一版、但下一个 yNN 要顺手带上的补丁和配置，先放这里。**起下一个 yNN 时先读本文**：把下面「排队中」每一项并进那一版（补丁拷进它的 `patches/`、在 `series` 末尾加一行、verify 加上本文写的检查），在那一版的 NOTES 里写明收了哪几项，然后把本文对应条目挪到「已收走」。

一个 yNN 对应一个 tree + 一份 config（y14 起的钉子规则）；这里的东西不改当前在跑的 y20，也不单独起号。

## 排队中

### 1059 `arm64: dts: qcom: baldur-stats: hand qcom_stats the AOSS QMP`（11-05，作者「搞」）

- 文件：`1059-arm64-dts-qcom-baldur-stats-hand-qcom_stats-the-AOSS-QMP.patch`。只给 `baldur-stats.dtsi` 的 `sram@c3f0000`（`qcom,rpmh-stats`）节点加一行 `qcom,qmp = <&aoss_qmp>;`。
- 为什么：`qcom_stats` 只有节点带 `qcom,qmp` 时，读 `ddr_stats` 前才会让 AOP 刷新 DDR 统计（`qcom_ddr_stats_show()` 发 `{class: ddr, action: freqsync}`）。SM8450 起不刷就不填时长，所以现在 `ddr_stats` 每一档都是 `Duration (ticks):0`（`linux/power/cx-collapse/cx-audit-2247.txt` 的 ddr_stats 一行）。带上后才看得出熄屏时 DDR 有没有真进低功耗。RESEARCH 问题 13、upstream-check 观察表 `rpmh-stats-qmp` 盯的就是这件事；主线 `sm8750.dtsi`、infiniti 的 `kaanapali.dtsi`、一加 Pad 4 内核（iceland-7.3 `03896b28`）同一节点都带。
- 已核对（11-05，平板 y20 树 `/usr/local/src/linux-t52`，只读）：
  - `kaanapali.dtsi:4808` 有标签 `aoss_qmp: power-management@c300000`。
  - 树里 `baldur-stats.dtsi` 的 blob 是 `26b710af0`，补丁就是在它上面做的；y19 补丁栈里没有别的补丁碰这个文件。
  - `drivers/soc/qcom/qcom_stats.c` 的 probe：没有这个属性时 `qmp_get` 失败会被忽略；有了属性，`-EPROBE_DEFER` 会等，别的错误让整个 probe 失败。
  - y20 配置：`CONFIG_QCOM_AOSS_QMP=y`、`CONFIG_QCOM_STATS=m`，所以只会短暂等一下，不会一直等。
- 风险：
  - `qmp_get` 出别的错，`/sys/kernel/debug/qcom_stats/` 整个没了。会断数据的有：飞行记录器的 `qs=` 字段、`y700-powersample.py`、`cx-exp.sh` / `exp-collect.sh` 的 apss/cxsd/aosd/ddr 计数、`always-on-check.sh`。体检不看 `qs=`（「熄屏省电生效」看的是 `pd=`，「飞行记录器」只看日志在不在更新），所以下面验收第 2、3 条是唯一的防线。
  - 每读一次 `ddr_stats` 发一条 QMP 消息，最多等 1 秒。现在只有 `live-ro3.sh` 这种一次性诊断读它，飞行记录器和 powersample 只读 apss/cxsd/aosd/ddr 和子系统那几个文件，不受影响。
- 上机验收（加进那一版的 `yNN-verify.sh`，前三条不碰 debugfs）：
  1. `/proc/device-tree/soc@0/sram@c3f0000/qcom,qmp` 存在，4 个字节与 `/proc/device-tree/soc@0/power-management@c300000/phandle` `cmp` 相同（y20 上 phandle 是 `0xb3`，换树可能变，比的是两边相同，不写死）。
  2. `/sys/bus/platform/drivers/qcom_stats/c3f0000.sram` 存在（probe 成功）；`journalctl -k -b` 里没有 qcom_stats 的 probe 报错。
  3. 当前飞行记录器日志最新一行的 `qs=` 还是 `apss:<数>/+<数>,cxsd:…,aosd:…,ddr:…` 四段。
  4. **手动、一次**（要读 debugfs，y16 起「新代码不读 debugfs」，所以不写进 verify）：开机几分钟后 `cat /sys/kernel/debug/qcom_stats/ddr_stats` 一次，返回 0，且至少一档 Duration 不是 0。还是全 0 的话，补丁收回，问题 13 记「qmp 也不管用」。这个文件就是飞行记录器一直在读的那个目录里的，不是寄存器文件。
- 可以报上游：`baldur-stats.dtsi` 是主上游 0054 加的文件。要发 issue 或 PR，每次先问作者。

## 已收走

（暂无）

## 有意不做

- 不为这一行单独编 y21：收益只是统计数据（能看清 DDR 睡没睡），不修任何用户看得到的问题；跟下一版一起出，省一次 trial / keep 和重启。
- 不在 verify 里自动读 `ddr_stats`：读它会发 QMP 消息，也违背 y16 起 verify 不读 debugfs 的规矩；只手动读一次。

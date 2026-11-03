# 扬声器 sink 为什么"不挂起"、熄屏时值多少、怎么最小地修（2026-10-16，只读研究，**未装、未上机**）

**范围与方法**：全部离线完成。没有 ssh/ping 平板（12:30 前它在跑无人值守的功耗测量），没有编译、没有安装。读的东西和版本：

- 仓库：`linux/audio/*`、`linux/osk/src/*`、`linux/power/{WAKEUPS,ALWAYS-ON}.md`、`linux/power/cx-collapse/PROTOCOL.md §9`、README 的音频段（200、271–283、744–745、1011–1012 行；行号按 e353793；原稿写的 742–744、1009–1010 对不上现在的 README，README 在并行修改）、`linux/kernel-y8/inventory/packages`（平板装的是 **PipeWire 1.6.2-1ubuntu1.2、WirePlumber 0.5.13-1ubuntu1、alsa-ucm-conf 1.2.15.3-1ubuntu1.7**；没有 `pipewire-jack`）。
- 上游 tb323fu-linux：本地副本 `linux/tb323fu-linux`（0c7c0c4）。与 **helper-v0.4.2** 逐个比了 blob id（GitHub API 取 `git/trees/helper-v0.4.2`）：`userspace/platform` 下所有音频文件、`kernel/out-of-tree/aw882xx/*`、`kernel/dts/baldur-audio.dtsi`、`firmware/audio/*`、补丁 0034/0035/0076 **全部相同**。所以下文行号对 0.4.2 也成立。
- WirePlumber 0.5.13 源码（gitlab.freedesktop.org raw + 本地裸克隆）、PipeWire 1.6.2 源码（同上；`git log` 查了 1.6 分支与 master 的相关提交）、Ubuntu 的 `pipewire_1.6.2-1ubuntu1.2/changelog`、PipeWire issue #5207 / #5392（GitLab API，公开）。
- 内核 v7.3-rc4（raw.githubusercontent.com/torvalds/linux/v7.3-rc4）：`sound/soc/qcom/qdsp6/{q6apm-dai,q6apm,q6apm-lpass-dais,audioreach}.c/.h`、`sound/soc/qcom/sc8280xp.c`、`sound/soc/soc-{pcm,dai}.c`、`drivers/soc/qcom/apr.c`、`drivers/rpmsg/qcom_glink_native.c`。上游 tb323fu 补丁里动音频的只有 0034（sc8280xp MI2S S32_LE）、0035（tx macro）、0037（wcd939x）、0076（q6apm 包源端口），都不碰下文引用的函数。

---

## 0. 一页纸

1. **没有任何配置让扬声器 sink 常开。** `node.pause-on-idle = false` 是 WirePlumber 给**每一个** ALSA 节点的默认值（`monitors/alsa.lua:189-190`），意思是"空闲时别 Pause，等会话管理器来挂起"；挂起由 `node/suspend-node.lua` 在节点变 idle **5 s** 后发一次 `Suspend`。上游平台包、我们的 `linux/audio/*`、WirePlumber 0.5.13 自带的配置里都没有 `session.suspend-timeout-seconds`、`node.always-process`、`node.suspend-on-idle`（§1；PipeWire 上游 1.6.2 的 `pipewire.conf.in`/`pipewire-pulse.conf.in` 审阅时补查过，也没有；Ubuntu 打包后的版本和平板上仓库外的配置没查，§8）。
2. **但 "idle" ≠ 关了。** pause-on-idle=false 的 ALSA sink 在 idle 时 PCM 仍在跑、喂静音：ADSP 里的流图和设备图都在跑，两颗 aw882xx 功放上着电（它们在 prepare 时解除静音、hw_free 时才静音），每 480 帧一条 GPR 写完成消息（≈100 条/s），PipeWire 的 ALSA 定时器 ≈47 次/s。按源码合计 **≈300–400 个唤醒事件/s**（中断、工作项、线程唤醒分开数）；落到 CPU 的 idle 退出上，同一次唤醒里处理的会合并，估计 **≈150–300 次/s**，与整机熄屏基线（300–500 次 idle 退出/s）同量级（§2.3）。在这个平台上 "暂停（snd_pcm_drop）" 只省 CPU 一侧：不再排写缓冲、PipeWire 把节点摘出图，GPR 消息和定时器停了；但 DSP 图不停、MI2S 不停、功放不静音，**只有关闭 PCM（PipeWire 的 suspend）才真正下电**。
3. **现有熄屏数据更像"会挂起"，不像"一直开着"（反推，未经时间线核实）。** 熄屏 30 s 样本里 `apr_rxwq` 17/s × 30 s = 510 条 ≈ 100 条/s 开 5.1 s；pipewire 定时器 7.5/s × 30 = 225 次 ≈ 46.9 次/s 开 4.8 s——**两个独立计数都折合约 5 s**，正好是 WirePlumber 的挂起超时：那 30 s 里链路大概只开了约 5 s 就被关了。熄屏 27 分钟的 4 次 aw882xx 周期按题述每次都有 `shutdown: stream playback`，即后端被关过（DPCM 后端的 shutdown 在前端 close 时调，路由变化时也会调）。亮屏那一次"全部 idle、链接 paused"的快照，可能落在某次活动后的 5 s 窗口里（例如键盘点击流 10 s 闲置计时到期后），也可能是 PipeWire 1.6.2 特有的 `-EBUSY` 拒绝挂起而 WirePlumber 不重试（§3）；随机一次快照恰好落进 5 s 窗口的概率本身不高，所以 H1 只是"与数据不矛盾"，不是定论。注意快照里麦克风/摄像头是 suspended **不能**证明挂起钩子在工作：节点创建时就是 suspended，从没打开过就一直如此。离线分不出，§6.0 的几条只读命令或 §6.1 的记录器定案。
4. **27 分钟 4 次开/关 = 4 次有东西把图跑起来**：一条播放流（提示音：Telegram、KDE 通知、Chrome/Claude 桌面版的网页提示音），或者屏幕键盘在无人触摸时被拉起（它的 show() 会把点击流激活 10 s → 链路开约 15 s）。我们自己的守护/面板/测量脚本都不直接放声音（它们的 `notify-send` 在 Plasma 里带不带提示音没查，§4）。这 27 分钟很可能是 E3a 第二轮、每 2 分钟有一次 ssh 登录的那段（PROTOCOL.md:87），时间戳值得对一下（§4 第 4 条）。平均占空比约 1.5 %，**≈0 W，测不出**。
5. **提案（§5）**：先跑只读的 `y700-audio-watch` 半小时定案；**只有它报 `STUCK`（PCM 开着而 sink idle 超过 10 s）时**才装 WirePlumber 重试钩子（两个新文件，下次开机生效，**不重启 PipeWire/WirePlumber**）。aw882xx 每次开关 ~60 行日志的降级补丁随下次内核构建顺带（纯化妆，不为它单独编内核）。屏幕键盘"点击音关闭时不激活点击流"补丁可选（只在亮屏有用）。
6. **预期收益**：若熄屏时它本来就会挂起（现有数据更像这样），钩子什么也不省；真正剩下的是那几次提示音后的 5 s 尾巴，≈0。若坐实"卡在 idle"，卡住期间省 ≈300–400 个唤醒事件/s（≈150–300 次 idle 退出/s）和推测 0.03–0.15 W（功放静态电流、ADSP、以及丢掉的 apps-pc 驻留；**未测**，§6.4 给了一次就能测出的静音 A/B）。

本目录新文件（全部**未装**）：

| 文件 | 作用 |
|---|---|
| `SUSPEND.md` | 本文 |
| `y700-audio-watch` | 只读诊断：谁打开了扬声器、PCM 开着而 sink idle 的时间（§6.1） |
| `y700-speaker-suspend.lua` | WirePlumber 0.5 钩子：扬声器 sink 在原生超时后 3 s 仍 idle 就再发 Suspend（≤5 次） |
| `y700-speaker-suspend.conf` | 加载上面脚本的 `wireplumber.conf.d` 片段（按绝对路径加载；虚拟组件 wants 它：脚本坏了只告警不拖垮 WirePlumber）；附注释掉的"缩短超时"规则 |
| `aw882xx-quiet-stream-log.DRAFT.patch` | aw882xx 每次开关的 33 条进度日志降为 debug（保留 `start success` 和所有错误） |
| `osk-click-stream-mute.DRAFT.patch` | 屏幕键盘：点击音音量为 0 时不激活点击流（可选） |

---

## 1. 配置审计（问题 a）：谁可能让它 idle 而不挂起

| 层 | 文件（版本） | 与挂起相关的键 | 结论 |
|---|---|---|---|
| 上游 WirePlumber 规则 | `userspace/platform/wireplumber/wireplumber.conf.d/60-tb323fu-speaker-raw.conf:6-16`（=0.4.2） | 只改 `node.description`、`priority.session = 100` | 无 |
| 上游保护链 | `pipewire/pipewire.conf.d/60-tb323fu-speakers.conf:22-87`（=0.4.2） | 回放侧 `node.passive = true`（:79-84），无 suspend/always-process | 被动链接本身不让 sink 跑 |
| 上游 UCM | `alsa/ucm2/Lenovo/TB323FU/HiFi.conf:10-26`、`conf.d/kaanapali/LENOVO-TB323FU.conf:7-12`（=0.4.2） | 只有路由 cset 和 PlaybackPCM/Priority/Channels | 无 |
| 上游混音默认值/功放增益 | `etc/tb323fu/audio.conf`、`libexec/tb323fu-audio-defaults`、`libexec/tb323fu-speaker-gain`、`systemd/{system/tb323fu-audio,user/tb323fu-speaker-gain}.service`、`udev/91-tb323fu-audio.rules`（=0.4.2） | 只写 amixer 控件、默认输出元数据 | 无 |
| 我们的调音链 | 作者自用的 `y700-lenovo-tuning.conf`（未随附，见 [README.md](README.md)） | 回放侧 `node.passive = true`、`dont-reconnect`/`dont-fallback` | 无 |
| 我们的守护 | `y700-speaker-guard`（事件驱动 + 30 s；11-03 换 Rust 后兜底改 10 min） | 只跑 pw-cli/pw-metadata/pactl 查询、`set-sink-volume`、`move-sink-input` | 不建流、不恢复挂起的 sink |
| 屏幕键盘 | `linux/osk/src/sound.cpp:111-139` | 自建 pw_stream，`PW_STREAM_FLAG_INACTIVE` 连接（:133-134），`node.latency = 256/48000`（:119） | 见 §2.5：不活动时不拖住 sink |
| WirePlumber 0.5.13 默认 | `src/scripts/monitors/alsa.lua:189-190` | `node.pause-on-idle = false`（**所有** ALSA 节点） | 这就是快照里那个 False |
| | `src/scripts/node/suspend-node.lua:12-23,38-62` | 关注 `Audio/*`、`Video/*` 的 node-state-changed；进 idle/error 起一个 `session.suspend-timeout-seconds`（缺省 **5**，0=不挂起）的一次性定时器，到时发**一次** `Suspend`，不复查 | 默认会挂起 |
| | `src/config/wireplumber.conf:617-640` | `hooks.node.suspend` 由 `policy.node` 想要（wants） | 默认加载 |
| | `src/config/wireplumber.conf.d/alsa-vm.conf` | 只匹配 `cpu.vm.name`（虚拟机），改 period/headroom | 不适用 |
| PipeWire 1.6.2 | `src/pipewire/impl-node.c:1170-1171` | 核心默认 `pause_on_idle = true`、`suspend_on_idle = false`；ALSA 节点被 WirePlumber 改成 false | — |
| | `src/daemon/pipewire.conf.in`、`pipewire-pulse.conf.in`、`filter-chain.conf.in`（1.6.2 tag；审阅时补查） | 没有 `suspend-timeout`/`pause-on-idle`/`suspend-on-idle`/`always-process` 设置（`pipewire.conf.in:275-288` 只有 Dummy-Driver 的注释提到 always-process）；只有 `minimal.conf.in`（不用）设了 `suspend-on-idle`，`jack.conf.in` 设了 pause-on-idle=false | 上游缺省无；Ubuntu 打包后的 `/usr/share/pipewire/*.conf` 是否被改没看 |
| 文档 | `doc/dox/config/pipewire-props.7.md:384-390` | 空闲节点照常处理、由会话管理器超时后挂起；没有会话管理器时可用 `node.suspend-on-idle` | 设计如此 |
| | 同文件 `:467-469` | 写 `session.suspend-timeout-seconds = 3` | **文档与脚本不一致**：实际运行的 suspend-node.lua 缺省 5 s |

**没查到的地方（只能上机看）**：平板上仓库之外的 `/etc/wireplumber/`、`~/.config/wireplumber/`、`/etc/pipewire/`、`~/.config/pipewire/`，以及 Ubuntu 打包是否往 `/usr/share/wireplumber/wireplumber.conf.d/` 额外放了文件（上游 0.5.13 只带 `alsa-vm.conf`）。§6.0 给了一条 grep。

### 1.1 为什么 ALSA 节点不在空闲时暂停（上游原因）

- PipeWire **d9a63dc69**（Wim Taymans，2021-01-18，"alsa: disable pause-on-idle by default"）：提交说明的意思是 `snd_pcm_drop()` 会产生爆音和咔哒声，不如让 sink 一直吃静音，直到被挂起。随后 **ecd1d3e1d**（2021-02-08）把这个默认挪进配置文件；WirePlumber **73a07d00**（George Kiagiadakis，2021-02-15，"monitor-alsa: sync logic, properties and configuration with media-session"）把 media-session 的这套做法搬了过来，延续到今天的 `alsa.lua:189-190`。
- 所以 pause-on-idle=false 防的是"**短间隔里反复停/开**"的爆音，代价由会话管理器的超时兜住——它从来不是"永远别关"的意思。PipeWire 文档在 `dither.noise` 一项（`pipewire-props.7.md:781-789`）另提了"有的功放静音期间要保活"的做法（加噪声 + 把挂起超时设 0），本项目上游没有用。
- 题目里列的其它可能原因，逐条核过：
  - **功放启动延迟**：上游没有任何文字说扬声器要常开（`docs/hardware-status.md:84` 只写两颗功放每次都能启动；A2DP 那行 :104 说过"流开头第一个音节可能被吃掉"，那是蓝牙）。
  - **保护链需要连续反馈**：不需要。Linux 这边的保护是纯前馈 filter-chain（`60-tb323fu-speakers.conf:11-17`：高通/压缩/RMS 上限/限幅），topology 只有直通路径（README:274），aw882xx 的 monitor 要 per-PID monitor 文件才运转（`aw882xx_monitor.c:469-476`，上游 aw882xx README 说这些文件在 Linux 上不用），没有任何 I/V 回读闭环。RMS 上限的释放时间 1 s（`60-tb323fu-speakers.conf:42-51`），静音 5 s 后它的状态本来就衰减完了，挂起/恢复不损失保护。
  - **"WirePlumber 切配置时 UCM 把 DSP 路由关了、打开报 EINVAL、退到 pro-audio"**（README:745，行号按 e353793 的 README；README 在并行修改，合并时按引文定位）：**节点挂起不会触发它。** PCM 的打开/关闭路径（`spa/plugins/alsa/alsa-pcm.c` 的 `spa_alsa_open/close`）不碰 UCM；UCM 管理器只在节点初始化时为取 `_alibpref` 打开一次（`alsa-pcm.c:37-83,1048`）；UCM 的 Enable/DisableSequence 只在切 profile / 切 port 时跑（`spa/plugins/alsa/acp/acp.c:1615,1832-1842,2266` → `alsa-ucm.c:746,769` 的 `_disdev/_enadev`）。那个坑要 profile off→on，即重启 PipeWire/WirePlumber——这也是下文安装步骤**不重启**它们的原因。

---

## 2. idle 时到底开着什么（问题 b）

### 2.1 PipeWire 1.6.2 一侧

- `idle_node()`：`pause_on_idle` 为 false 直接返回，不发 Pause（`src/pipewire/impl-node.c:299-322`，判断在 :312）；`node_update_state()` 对 IDLE 且非 pause_on_idle 的节点**不从图里摘掉**（:477-482，判断在 :480）。所以 idle 的 ALSA sink 继续当驱动跑周期，spa alsa 照常写（静音）。
- 挂起：`suspend_node()`（:529-585）发 `Suspend` → audioadapter 先把命令转给 ALSA follower（`alsa-pcm-sink.c:334-339` → `spa_alsa_pause()` = `snd_pcm_drop`），再 `configure_format(this, 0, NULL)` 清掉 follower 的格式（`spa/plugins/audioconvert/audioadapter.c:1126-1131`）→ `port_set_format(NULL)` → `spa_alsa_close()`（`alsa-pcm-sink.c:579`）。**到这一步 PCM 才关。**
- 恢复：只在节点 Start 时 audioadapter 才重新协商 follower 格式（`audioadapter.c:1078-1083`）→ `spa_alsa_set_format()` 打开 PCM 并设 hw_params（alsa-lib 设完 hw_params 会自动 prepare）。挂起后 PipeWire 会马上重新准备两端都活动的链接（`context.c:1110-1153`、`impl-link.c:975-995`），但那只在 adapter 的 DSP 端口上协商，**不会**重开 PCM；节点状态也保持 suspended（`context.c:985-993` 的 `ensure_state()` 不会把 SUSPENDED 抬成 IDLE）。所以"挂起后链接仍是 paused"是正常现象。
- 周期大小：q6apm-dai 的回放硬件描述声明 `SNDRV_PCM_INFO_BATCH`（`q6apm-dai.c:110-128`，BATCH 在 :115；:95 是录音那份）→ spa alsa 对 batch 设备取 `min(量子, 1024)/2 = 512` 帧（`alsa-pcm.c:2418-2441`，`DEFAULT_PERIOD 1024` 在 `alsa-pcm.h:41`）→ q6apm-dai 要求周期是 480 帧的整数倍（`q6apm-dai.c:421`）→ 实际 **480 帧 = 10 ms**。PipeWire 的定时器按量子醒：默认 1024 帧 = **46.9 次/s**；屏幕键盘活动时它要 `256/48000`（`sound.cpp:119`），量子降到 256 = 187.5 次/s。

### 2.2 内核 / ADSP 一侧：PCM 各状态下什么在跑（v7.3-rc4）

扬声器链路 = 前端 MultiMedia1（q6apm-dai）→ 后端 PRIMARY_MI2S_RX（q6apm-lpass-dais）+ 两颗 aw882xx（`baldur-audio.dtsi:140-152`）。

| PCM 状态 | 前端（q6apm-dai） | 后端（MI2S 设备图） | 功放 |
|---|---|---|---|
| 关闭 | 无图 | 无图 | 断电 |
| open（startup） | `q6apm_graph_open()`（`q6apm-dai.c:367-453`，GPR 往返） | 只记 `startup`（`q6apm-lpass-dais.c:277-298`） | `aw882xx_startup` 只打日志 + 读校准（`aw882xx.c:273-288`） |
| hw_params + prepare，未 start | **prepare 里就 `q6apm_graph_start()`**（`q6apm-dai.c:288-299`） | 图 open + prepare，**不 start**（:228-275） | prepare 时 ASoC 解除静音（`soc-pcm.c:1082-1085`）→ `aw882xx_mute(0)` 排队启动工作（`aw882xx.c:394-428`）；此时 I²S 没有时钟，PLL 检查失败、重试 5 次（`AW_START_RETRIES`，`aw882xx.h:29`）——这正是 README:200 说的开机/重启 WirePlumber 时那批 `pll&clk check fail` / `start failed, cnt:4`：声卡建立时 ACP 按 UCM 探测 profile，会带 hw_params 打开一次 PCM 再关掉（`spa/plugins/alsa/acp/alsa-ucm.c:2437-2438`，由 `ucm_probe_profile_set()` :2559 调用），从不 trigger start |
| running | 每写入一个周期 DSP 回一条 `DATA_CMD_RSP_WR_SH_MEM_EP_DATA_BUFFER_DONE_V2`（`q6apm.c:582`）→ `snd_pcm_period_elapsed`（`q6apm-dai.c:142-144`）；内核在 `ack` 里按周期写（:314-336） | trigger START 才 `q6apm_graph_start()`（:203-226），DSP 自己出 MI2S 时钟（kaanapali 的机器数据没有 MI2S 时钟开关，`sc8280xp.c:457-462`） | BCLK 来了，PLL/SYSST 过，`start success`，上电工作 |
| drop/stop 后（PCM 仍开） | TRIGGER_STOP **只改状态**，图不停（`q6apm-dai.c:350-355`，注释写着 SoftPause 是 TODO）；但之后没人再写，`ack` 不再排缓冲（:323-333），所以**没有 WRITE_DONE 消息** | 后端 trigger 不处理 STOP（:208-223），图和 I²S 继续 | **不静音**：静音只在 hw_free（`soc-pcm.c:1139-1143`），aw882xx 没设 `mute_unmute_on_trigger`（`aw882xx.c:430-437`） |
| close | 组件 `.close`（`q6apm-dai.c:455-473`，ops 表 :1007）→ 前端图 stop + close | shutdown 里 stop + close（:185-201、:300-306，I²S 的 shutdown 还关 MI2S 时钟 :305） | 先 hw_free：`aw882xx_mute(1)` → `aw882xx_device_stop()`（渐出、软静音、断电）（10-16 下午更正：平板 fade-flag=0、DT 无此键，渐入渐出不生效，见 POPS.md §1.2-1） |

**结论（b 的前半）**：PipeWire 的 "idle" = PCM running 喂静音 → ADSP 流图/设备图、MI2S、两颗功放、每 10 ms 一条 GPR 消息，全在。若改成 "pause"（`snd_pcm_drop`），CPU 一侧的 GPR 消息和 PipeWire 定时器会停（节点被摘出图，`impl-node.c:299-322`），但 DSP 图、MI2S 和功放照旧开着——**只有 close 才全省**。

**LPASS 时钟/五个 macro（ALWAYS-ON §5a）与扬声器 PCM 无关**：ASoC 只对 PCM 所在 rtd 的 component 取 runtime PM 引用（`soc-pcm.c:978`），扬声器链路上的 component 是 q6apm-dai、q6apm-lpass-dais、两颗 aw882xx；lpass macro / soundwire / wcd939x 只在 "WCD Capture" 链路上（`baldur-audio.dtsi:124-136`）。所以 §5a 仍是独立问题（soundwire 主控或 wcd939x 不睡），开着的扬声器不会把它们按住，关掉扬声器也不会让它们睡。

### 2.3 扬声器链路开着一秒的账（源码推出，**非实测**）

| 项 | 次/s | 出处 |
|---|---|---|
| ADSP → APSS 的 GPR 写完成消息 | 100（480 帧周期） | §2.1/2.2 |
| `apr_rxwq`（每条 GPR 包 `queue_work` 一次，积压时合并） | ≤100 | `apr.c:161-187,315-338` |
| `qcom_glink_rx_done_work`（每个收到的 intent 排一次，回 RX_DONE；**所有** ADSP glink 通道都算，包括 pmic_glink） | ≤100 + 其它通道 | `qcom_glink_native.c:554-619` |
| glink/IPCC 中断 | ≈100 | 每条消息一次 |
| PipeWire 主进程 ALSA 定时器（timerfd） | 46.9（键盘活动时 187.5） | §2.1 |
| `y700-lenovo-tuning` 那个独立 pipewire 进程（每个图周期被唤醒一次） | ≈46.9 | 推测，未在 trace 里单独核对 |
| 两颗功放 | 上电空转 | 电流未知（芯片 ID 0x2308 的数据手册没读到） |

合计 **≈300–400 个唤醒事件/s**。这是把中断、工作项、线程唤醒分开数的；CPU 的 idle 退出会合并：IPCC 中断、glink 接收、`schedule_work` 排的 rx_done（系统工作队列，排在本 CPU）通常在同一次唤醒里处理完，`apr_rxwq` 是单线程有序工作队列（`apr.c:620`，`create_singlethread_workqueue` = unbound，可能落到别的 CPU 上再唤醒一次），PipeWire 定时器和调音进程又各是一次。所以落到 `y700-wakeups` 的 idle 退出计数上，估计 **≈150–300 次/s**（审阅时按源码重估，同样未测；§6.4 的 A/B 会直接给出）。功耗推测 0.03–0.15 W（功放静态电流 + ADSP 不能睡 + 唤醒率高到 apps-pc 进不去；三项都没测，范围很宽）。

### 2.4 用这本账反读熄屏 30 s 样本（README:1011-1012，e353793；WAKEUPS.md 本身没有这组数）

- `apr_rxwq` 17/s × 30 s = 510 ≈ **5.1 s** × 100/s；pipewire timerfd 7.5/s × 30 s = 225 ≈ **4.8 s** × 46.9/s；两者之比 2.27，模型（1024/480）是 2.13。两个互不相干的计数都说"开了约 5 s"，正好是 WirePlumber 的挂起超时。
- 所以那个样本里**扬声器挂起大概是正常工作的**：`offmeasure.sh` 熄屏 20 s 后才开始录（README:1011），熄屏前的活动留下的 5 s 尾巴早就过了，更像是录的那 30 s 里有一声短促的声音加 5 s 尾巴（或键盘点击流被拉起，见下）。它不太像"熄屏时音频图一直不挂起"。README:1011-1012 里"疑是调音/保护滤波链按着"的推测应改读为"30 s 里撞上了一个约 5 s 的打开窗口（推断）"（§9 的 README 合并稿里写了这条更正；README/WAKEUPS 本身按约定没动）。
- 这条推断的弱点：两个计数的比值吻合，也可能是巧合（例如某个别的 ADSP 客户端恰好 17 条/s）；样本时间点和当时有没有声音没有记录。§6.1 的记录器能直接给出"PCM 开了几秒、谁开的"。
- 如果它真的一直开着，同样 30 s 应该看到 ≈100/s 的 `apr_rxwq` 和 ≈47/s 的 pipewire 定时器。

### 2.5 屏幕键盘的点击流会不会自己拖住扬声器？——不会

- 流的建立：`Sound::connectStream()`（`sound.cpp:111-139`）用 `PW_STREAM_FLAG_AUTOCONNECT | MAP_BUFFERS | RT_PROCESS | INACTIVE` 连到默认输出（联想调音），所以它一直挂在 `effect_input.y700_lenovo` 上（快照里那条 paused 链接）。
- 激活/去激活：`Sound::setActive()`（`sound.cpp:180-188`）调 `pw_stream_set_active()`；`Osk::click()`（`osk.cpp:264-270`）和 `Osk::show()`（:311-319）激活并重置 10 s 计时器（:134-137），计时到或键盘收起（`hideDone()`，:398-404）就去激活。
- 不活动的流不让任何东西跑：`pw_stream_set_active(false)` → 服务端 `pw_impl_node_set_active(false)`（`stream.c:2428-2442` → `client-node.c:1051-1055`）；图计算跳过不活动节点（`context.c:1110,1128,1149`），链接准备也直接返回（`impl-link.c:983`）。所以这条流只留下一条 paused 链接，**不**让 sink 变 runnable，也不阻止挂起。
- 它的真实影响：每次点击/每次键盘弹出，整条扬声器链路开 **10 s（键盘计时）+ 5 s（WirePlumber 超时）**，期间量子 256 → PipeWire 187.5 次/s。这是亮屏打字时的设计行为；它已经等价于"用完就 cork"。
- 一个小漏洞：点击音音量设为 0 时，`show()`/`click()` 仍然先 `setActive(true)`，`play()` 才因为音量 0 丢掉声音（`sound.cpp:193-197`）——**点击音关掉时每次按键/弹出仍会把扬声器链路开 15 s 放静音**。`osk-click-stream-mute.DRAFT.patch` 补这一处（§5.5）。作者当前的点击音设置未知。
- 没提议缩短 10 s：那会让打字停顿后第一下点击多付一次恢复延迟（§5.2），而它只影响亮屏。

---

## 3. "从不挂起"的几种读法（亮屏快照怎么解释）

按可能性排序：

| # | 假说 | 依据 | 在 `y700-audio-watch` 里的样子 |
|---|---|---|---|
| H1 | 快照落在某次活动后的 5 s idle 窗口里 | 三个 Audio/Sink 一起 idle、链接 paused——与"刚停下、WirePlumber 的三个 5 s 定时器还没到"相符；熄屏数据（§2.4）也更像挂起在工作。但点击流 idle 本身不说明什么（Stream/* 节点 WirePlumber 从不挂起，不活动的流一直是 idle），随机快照落进 5 s 窗口的概率也不高 | pcm `RUNNING -> closed` 总在 sink 进 IDLE 后约 5 s；无 STUCK |
| H2 | PipeWire 1.6.2 拒绝挂起、WirePlumber 不重试 | 1.6.2 的 `suspend_node()` 在任何端口 `busy_count > 0` 时返回 `-EBUSY`（`impl-node.c:540-553`，上游 **bb0efd777**「impl-node: Don't suspend when links are busy」，2025-12-18，进了 1.6.0–1.6.2）；suspend-node.lua 只发一次（:48-62）；上游已在 1.6.3 回退（**1689b441d**，master 上是 6b0248d68，说明里的意思是有挂起中的操作就该取消它们，引 issue #5207）；Ubuntu 1.6.2-1ubuntu1.2 的 changelog 没有回移这次回退。要命中，WirePlumber 的定时器得正好在某条链接协商/分配缓冲的那几毫秒里到点；三个节点同时命中不太可能 | sink 长时间 IDLE 而 pcm RUNNING → `STUCK` |
| H3 | 平板上仓库之外有配置把超时设成 0 | 仓库里没有；离线查不了 | `pw-dump` 能看到 `session.suspend-timeout-seconds = 0`（§6.0） |
| H4 | 有东西每隔 <5 s 把图跑一次 | 要的是一条**非被动**、连到扬声器链（或默认输出）上、每隔不到 5 s 就活动一次的流，例如反复 cork/uncork 的网页音频、反复建流的提示音（一直活动的流会让 sink 一直 RUNNING，快照里就不是 idle 了）。审阅更正两条：(1) JACK 客户端不在此列——Ubuntu 打包虽"Enable pipewire jack emulation"，平板上**没装 `pipewire-jack`**（`inventory/packages` 只有 JACK1 的 `libjack0 0.126`），JACK 程序不会进 PipeWire 图；(2) 没连任何东西、但要驱动的节点（`always-process` 等）在没有别的驱动在跑时挂到优先级最高的 **Dummy-Driver**（`pipewire.conf.in:275-288`，priority.driver 200000；驱动表按优先级降序，`impl-node.c:803-820`，兜底取第一个，`context.c:1488-1516`），不会把 ALSA sink 拉起来；只有 sink 本来就在跑时才会被并进来（`context.c:1540-1553`）。上游 issue **#5392**（2026-07-26 开，未关）报告新版本里"新建视频节点会把整个图唤醒约 1 s"，1.6.2 有没有这个行为未知 | 频繁的 `pcm closed -> RUNNING` / `sink IDLE -> RUNNING`，`playing now:` 列出的流 |

**不是**原因的：`node.pause-on-idle = False`（默认值）、被动链接（`node.passive = true` 只是不让 sink 因它而跑）、点击流的 paused 链接（§2.5）、UCM（§1.1）。

---

## 4. 熄屏 27 分钟 4 次功放开/关（问题 c）

- 一次完整周期（startup → hw_params → mute 0 → start_pa … start success → mute 1 → shutdown，按源码每颗功放上行约 20 行、下行约 10 行）= PipeWire 让 sink **Start**（有一条可运行的跟随者，或改采样率后的 `need_resume`，`context.c:1269-1285,1662-1665`）然后 WirePlumber 5 s 后挂起。几种"探测式打开"不会 trigger start，日志能分出来：ACP 建卡时的 profile 探测（`alsa-ucm.c:2437-2438`，带 hw_params）留下的是 `pll&clk check fail` / `start failed, cnt:0..4`、没有 `start success`；adapter 的 `ParamBegin/ParamEnd`（`alsa-pcm-sink.c:314-322`）只开关 PCM，只有 startup/shutdown 两行。（审阅补）还有第三种：对 sink 节点枚举 `EnumFormat`——adapter 的节点级 EnumFormat 直通 ALSA 端口（`audioadapter.c:253-258` → `alsa-pcm-sink.c:437`），PCM 关着时 `spa_alsa_enum_format()` 会临时 open 再 close（`alsa-pcm.c:2049-2052,2094-2095`），同样只留每颗功放一对 startup/shutdown（外加前端图 open/close 的几次 GPR 往返）。会这样做的有 `pw-dump`（枚举所有可读参数，§6.0 那条命令本身就会触发一次）、`pw-cli enum-params <id> EnumFormat`、WirePlumber 配置节点和建链时查格式（`module-si-audio-adapter.c:160`、`lib/linking-utils.lua:158`）；pipewire-pulse 只在参数的 user 计数变化时重枚举，而 ALSA sink 开关 PCM 时只改 Format 不改 EnumFormat（`alsa-pcm-sink.c:618-626`），所以每次挂起后不会被它再打开一次。**这 4 次周期里有没有 `start success` 我没看到原始日志**——有，就是真的跑起来了（下面的候选）；只有 `start failed`，就是声卡被重建（WirePlumber 重启或设备重枚举），要另查。
- 候选（都要 §6.1 的记录器来分）：
  1. **提示音**：Telegram（不冻结、熄屏照收消息）、KDE 通知（KNotification 经 libcanberra，`libcanberra-pulse` 已装）、Chrome / Claude 桌面版的网页提示音。记录器会打出 `stream new #N: application.name = …`，PCM 开约 5–6 s。
  2. **屏幕键盘在无人触摸时被拉起**：`show()` 不需要点击就激活点击流 10 s。不经点按证据就会 show 的路径有：X11 客户端的焦点 Show（`osk.cpp:300-306`）、门控效果不在（:343-345）、KWin 发起的激活（:349-352）、门控沉默兜底（:362-368）。熄屏时有窗口被激活（例如 XWayland 下的应用弹窗）就可能走到。记录器里没有新流、`playing now:` 是 `y700-osk-clicks`，PCM 开约 15 s。
  3. **H4 那类**：反复开关的非被动流（JACK 客户端不算，见 §3 H4 的更正）。
  4. **（审阅补）时间上的巧合，要对一下**：这 27 分钟很可能就是 E3a 第二轮的 04:10–04:37（PROTOCOL.md §9），当时每 2 分钟有一次 ssh 登录，root 的 systemd 用户管理器起停了 13 次，并为 root 去启动全局启用的 pipewire / wireplumber / filter-chain（PROTOCOL.md:87，"全部 Dependency failed"）。按这句话它们没起来、不会开声卡；但 4 次功放周期的时间戳应该和 `journalctl _COMM=sshd -S "2026-10-16 04:10" -U "2026-10-16 04:38"` 的登录时间对一下（`journalctl -k` 同一区间 `grep -E "aw882xx_(startup|shutdown)"` 给出功放时间戳；日志若已轮转就无从对起），对得上就另查（例如 root 会话里有没有别的单元碰声卡）。
  - 排除：`y700-speaker-guard` 和控制中心只查询/调音量（`backend.cpp:41,313`），不建流；`y700-offmeasure.sh` 只用 `kde-inhibit` 和 `kscreen-doctor`；仓库里没有我们的东西直接放声音（grep 过 pw-play/paplay/canberra/QSoundEffect）。**未排除**：我们的脚本会 `notify-send`（`y700-wifi-watchdog`、`y700-display-watchdog`、`y700-speaker-guard` 的三种提示、`y700-hud-toggle`），Plasma 给这类没有 notifyrc 的通知放不放提示音没核实；它们只在出事时发，27 分钟 4 次的可能性低，`journalctl --user -b | grep -i notify` 或通知历史能看到。
- 代价：4 次 × 约 6 s（提示音）到 15 s（键盘）/ 1620 s ≈ 1.5–3.7 % 占空比 → 平均约 5–15 次唤醒/s、按 §2.3 的推测约 1–6 mW，**低于电池电流读数 ±0.03 W 的噪声，测不出**。值得做的是知道是谁——如果是键盘路径 2，熄屏时不该弹键盘本身就是个 bug。
- 日志：4 × 约 60 行 / 27 分钟 ≈ 0.15 行/s，**不是** PROTOCOL §9 末尾那个"systemd-journal → rsyslogd 7.7/s"的来源。

---

## 5. 提案（问题 d）

### 5.1 先测（零改动）

装 `y700-audio-watch`（只读，§6.1），熄屏跑 30 分钟。它同时回答：开扬声器的是谁（问题 c）、有没有 `STUCK`（H2/H3/H4）。**这一步之前不装任何会改行为的东西。**

### 5.2 若出现 `STUCK`：WirePlumber 重试钩子（最小改动）

- **改什么**：两个新文件（conf 按绝对路径加载脚本，不依赖会话的 `XDG_DATA_DIRS`）。`y700-speaker-suspend.lua` 只看 `alsa_output.platform-sound.HiFi__Speaker__sink`：它进 idle 后等"原生超时 + 3 s"（默认 8 s），若仍是 idle 就再发 `Suspend`，3 s 一次、最多 5 次，然后等它下次运行再说。running / suspended 的节点不碰；`session.suspend-timeout-seconds = 0` 尊重为"故意不挂起"。`y700-speaker-suspend.conf` 用一个虚拟组件 `wants` 这个脚本：脚本缺失或有语法错只在 `journalctl --user -u wireplumber` 里告警，WirePlumber 照常起（直接 `required` 一个坏脚本会让整个 profile 失败 = 没声音）。
- **N 是多少**：不改原生的 5 s；钩子只是保证"5 s 后真的关"（最迟 5 + 3 + 5×3 = 23 s 内给出结论）。H3 的解法是删掉那个 0；H4 的解法是找到那个客户端，钩子帮不上（节点不在 idle）。
- **预期收益**：H1 成立（目前证据更像这样）时 0；H2 坐实时，本该关却开着的那段时间里省 ≈300–400 个唤醒事件/s（≈150–300 次 idle 退出/s）、推测 0.03–0.15 W。
- **首音延迟 / 爆音**：和今天每次 5 s 超时后的行为完全一样，钩子不引入新的开关序列。恢复时的路径：PCM open + 前后端图 open/prepare/start（约 10 次 GPR 同步往返）+ 功放启动（寄存器、等 BCLK 后 PLL/SYSST 检查、渐入），**未测**，估计几十毫秒，静音后第一声提示音/第一下点击的开头可能被吃掉一点（键盘打字中不受影响：点击流 10 s 内保持活动）。爆音风险低：关闭时功放先渐出、静音、断电（hw_free），然后后端 shutdown 才停 I²S（`aw882xx_device.c:795-806,1418-1460`）；开启时功放在 PLL/SYSST 检查通过后才渐入（:1326-1416）。（10-16 下午更正：平板 fade-flag=0、DT 无此键，渐入渐出不生效，见 POPS.md §1.2-1）
- **与 `y700-speaker-guard` / `tb323fu-speaker-gain` 的关系**：没有冲突。挂起不删节点，守护看到的"保护节点在、硬件 sink 在、无旁路流"不变，增益保持 21；`aw_dev_*_volume` 直接写芯片寄存器（`aw882xx.c:757-786` → `aw882xx_device.c:665-680`），渐入回到这个值（:700-723）（10-16 下午更正：平板 fade-flag=0、DT 无此键，渐入渐出不生效，见 POPS.md §1.2-1），所以关开一次后功放仍是 21。挂起/恢复会产生 sink 的 change 事件，守护每次多跑一轮检查（几个 pactl/pw-cli 进程），与今天相同。
- **安装/验证/回滚**：§6.2。**不重启 PipeWire/WirePlumber**，下次开机生效。

### 5.3 可选：缩短扬声器的挂起超时（不推荐作为默认）

`y700-speaker-suspend.conf` 末尾注释掉的 `monitor.alsa.rules` 把扬声器 sink 的 `session.suspend-timeout-seconds` 改成 3。每次声音后少开 2 s；按 4 次/27 分钟算，省 8 s 的打开时间，≈0 W。代价是间隔 3–5 s 的两声（连续的通知、视频暂停再播）要多一次 PCM 重开和功放重启。只有记录器显示熄屏时有大量间隔 >5 s 的短声音时才值得。

### 5.4 aw882xx 日志降级（`aw882xx-quiet-stream-log.DRAFT.patch`）

- 33 条每次开/关都打印的进度消息（`playback enter`、`stream playback requested rate`、`mute state=`、`enter`、各种 `done`、`no cali, needn't init cali re`、`set record spin val done` 等）从 `aw_dev_info` 改为 `aw_dev_dbg`；**保留** `start success`（README:200 用它判断两颗功放都起来了）和所有 `aw_dev_err`（`pll&clk check fail`、`start failed`、`check fail`）；探测期的 info 不动。纯打印级别改动，无寄存器访问、无控制流变化。
- 价值：每声提示音少约 60 行内核日志（干净的 `journalctl -k`、少写盘）；**功耗 ≈0**。所以不为它单独编内核，等下一个内核（y11/y12）构建时顺带。`CONFIG_DYNAMIC_DEBUG=y`（`linux/kernel-y8/config-t49-y9:7822`），需要时运行时打开：`echo 'module snd_soc_aw882xx +p' > /sys/kernel/debug/dynamic_debug/control`。
- 补丁对 helper-v0.4.2 / 0c7c0c4 的四个文件 `git apply --check` 通过（本地试过）；未编译。

### 5.5 可选：屏幕键盘点击音为 0 时不激活点击流（`osk-click-stream-mute.DRAFT.patch`）

`Sound::setActive(true)` 在音量 ≤0 时直接返回（4 行）。音量调回来后的下一次点击照常激活。只影响亮屏且点击音关闭的情形；`git apply --check` 通过，未编译。

### 5.6 有意不做

- **`node.suspend-on-idle = true`**：在 RUNNING→IDLE 的那一刻立即挂起（`impl-node.c:521-526`）= 立刻 `snd_pcm_drop` + 关 PCM，按源码推断会丢掉 ALSA 缓冲里还没放完的那几十毫秒（drop 本身也正是 d9a63dc69 要避免的爆音来源），每两声之间都重开一次；而且走的是同一个 `suspend_node()`，1.6.2 的 `-EBUSY` 照样拒绝。
- **`node.always-process` / `dither.noise` 保活**：方向相反。
- **为了生效去重启 PipeWire/WirePlumber**：会触发 README:745 的 UCM 路由坑；下次开机生效即可（§6.2 写了非重启不可时的完整流程）。
- **让 `y700-speaker-guard` 去挂起 sink**：它是 shell + pactl，每次检查起十来个进程（11-03 换 Rust 后是 3 个，理由不变）；挂起是会话管理器的职责，放在 WirePlumber 里零额外进程。
- **动上游保护链 / 调音链、缩短键盘 10 s 计时**：与熄屏无关，且会改变听感/首击延迟。
- **在平板上做 A/B**：按约定 12:30 前不碰平板；§6.4 写好了步骤。

---

## 6. 部署、验证、回滚（给之后部署的人；以下命令**都没跑过**）

约定：`U="sudo -u user env XDG_RUNTIME_DIR=/run/user/1000"`；文件先 `scp` 到平板 `/root/y700-audio/`。不要在别的功耗测量进行中做这些。

### 6.0 只读核对（几十秒）

```sh
# H3: 仓库之外有没有改挂起的配置（含主配置文件；滤掉注释行）
grep -rnE "suspend-timeout|pause-on-idle|always-process|suspend-on-idle" \
  /etc/wireplumber /etc/pipewire /usr/share/wireplumber /usr/share/pipewire \
  /home/user/.config/wireplumber /home/user/.config/pipewire 2>/dev/null | grep -vE ':[0-9]+:[[:space:]]*#'
#   /usr/share/wireplumber/scripts/monitors/alsa.lua:85,189,190 是 WirePlumber 自己（默认值的来源），jack.conf/minimal.conf 不用
# 扬声器 sink 在 PipeWire 眼里的状态与相关属性
$U pw-dump | python3 -c 'import json,sys
for o in json.load(sys.stdin):
    p=(o.get("info") or {}).get("props") or {}
    if p.get("node.name")=="alsa_output.platform-sound.HiFi__Speaker__sink":
        print(o["info"].get("state"), {k:v for k,v in p.items() if any(s in k for s in ("suspend","pause","always","passive"))})'
# 什么都不放、键盘收起，30 s 内每 5 s 看一次 PCM 和 sink
for i in 1 2 3 4 5 6; do date +%T; head -1 /proc/asound/card0/pcm0p/sub0/status; $U pactl list short sinks | grep HiFi__Speaker; sleep 5; done
```

期望（H1）：`closed` + `SUSPENDED`。注意上面的 `pw-dump` 会枚举扬声器节点的 EnumFormat，PCM 关着时会让它开关一次（内核日志里多一对 aw882xx startup/shutdown，§4），不改节点状态；所以先跑循环、最后再跑 pw-dump，或者对日志时把这一对认出来。若持续 `state: RUNNING` + `IDLE` → H2/H3/H4，继续 6.1。

### 6.1 `y700-audio-watch`（只读，30 分钟，熄屏）

```sh
install -D -m 755 /root/y700-audio/y700-audio-watch /usr/local/libexec/y700-audio-watch
systemd-run --unit y700-audio-watch --collect /bin/sh -c \
  '/usr/local/libexec/y700-audio-watch 1800 > /var/log/y700-audio-watch-$(date +%m%d-%H%M).txt 2>&1'
# 结束后
grep -E "STUCK|stream new|playing now|pcm:" /var/log/y700-audio-watch-*.txt
```

- 每次 `pcm: closed -> RUNNING` 后面的 `playing now:` 就是问题 c 的答案；短促的提示音在 2 s 一次的轮询看到 PCM 打开前可能已经放完，那时 `playing now:` 是空的，答案在它前面那条 `stream new #N: application.name = …`。`STUCK` 出现 = 该装 6.2。内核行是 journalctl 原样的 `… kernel: [Awinic]…`。
- 本机桩测试过逻辑（假 pactl + 假 /proc/asound + 假 journalctl，`Y700_ASOUND` 只为这个测试存在）：新流、sink 状态变化、PCM 开关、STUCK、subscribe 断开重连、journalctl 不可读/起不来都按预期打印。审阅时重跑并修了一处泄漏：原来 journalctl 接在 `sed` 管道里，`$!` 是 sed，脚本退出后 `journalctl -f` 还挂着（桩测试里看到了残留进程），在 systemd-run 外跑（6.2 的验证）会留下一个每条日志都被唤醒的跟随进程；现在 journalctl 直接后台跑、退出时被杀，重跑无残留。root 路径（`sudo -u user`）在 Windows 上测不了；真机的 `pactl` 输出格式、`journalctl --grep`（要 PCRE2）是否可用**未验证**。
- 提前停：`systemctl stop y700-audio-watch`（单元的 cgroup 一起清掉，journalctl / pactl 子进程不会留下）。撤：`rm /usr/local/libexec/y700-audio-watch`（不留服务、不改配置）。

### 6.2 重试钩子（仅当 6.1 出现 STUCK）

```sh
install -D -m 644 /root/y700-audio/y700-speaker-suspend.lua  /usr/local/share/wireplumber/scripts/y700-speaker-suspend.lua
install -D -m 644 /root/y700-audio/y700-speaker-suspend.conf /etc/wireplumber/wireplumber.conf.d/90-y700-speaker-suspend.conf
# 生效 = 下次 WirePlumber 启动。用重启：确认平板没人在用，然后
systemctl reboot
```

**非要不重启整机就生效**（只在什么都没在放的时候）：

```sh
$U systemctl --user restart wireplumber
sleep 12   # 守护在 sink 消失 10 s 后会自己做下面两步；手动做也可以：
$U pw-cli ls Node | grep -q 'HiFi__Speaker__sink' || {
  /usr/libexec/tb323fu/tb323fu-audio-defaults 0
  card=$($U pw-cli ls Device | awk '/^\tid [0-9]+/ {id=$2} /device.name = "alsa_card.platform-sound"/ {print id; exit}' | tr -d ,)
  $U wpctl set-profile "$card" 1
}
$U /usr/libexec/tb323fu/tb323fu-speaker-gain status    # 期望 21/21，默认输出 effect_input.y700_lenovo（默认输出那行要用户身份才查得到）
```

验证：

```sh
$U journalctl --user -u wireplumber -b | grep -i y700          # 应有 "y700-speaker-suspend loaded"；
#   没有而有 "Could not locate script" / "Failed to load" = 脚本没装到绝对路径上或语法错（WirePlumber 照常跑）
# 先开记录器，再放一声 1 s 的声音（sound-theme-freedesktop 已装）
/usr/local/libexec/y700-audio-watch 60 & sleep 2; $U pw-play /usr/share/sounds/freedesktop/stereo/bell.oga; wait
#   期望：pcm closed -> RUNNING，sink RUNNING -> IDLE，约 5 s 后 IDLE -> SUSPENDED、pcm -> closed，无 STUCK
$U journalctl --user -u wireplumber --since -1h | grep "sending Suspend again"
#   正常为空；有行 = 原生那次 Suspend 被拒（H2 坐实），钩子补上了；"still idle after 5" = 重发也不行，查 H4
```

回滚：`rm /usr/local/share/wireplumber/scripts/y700-speaker-suspend.lua /etc/wireplumber/wireplumber.conf.d/90-y700-speaker-suspend.conf`，下次开机生效（或照上面的重启流程）。

### 6.3 aw882xx 日志补丁（下一次内核构建时）

补丁先 scp 到平板 `/root/y8-patches/`（kbuild 脚本放补丁的目录，`kbuild-y11.sh:10-11`；与 6.0–6.2 的 `/root/y700-audio/` 不同）。在构建脚本里编 aw882xx 的三行（`kbuild-y11.sh:124-126`）改为编一份打过补丁的副本（不弄脏 `$UP` 的 git 工作树）：

```sh
AW=/usr/local/src/y700-aw882xx; rm -rf $AW; cp -r $UP/kernel/out-of-tree/aw882xx $AW
patch -d $AW -p4 --dry-run < /root/y8-patches/aw882xx-quiet-stream-log.DRAFT.patch && \
patch -d $AW -p4 < /root/y8-patches/aw882xx-quiet-stream-log.DRAFT.patch
$M M=$AW clean
$M M=$AW CONFIG_SND_SOC_AW882XX=m modules
$M M=$AW CONFIG_SND_SOC_AW882XX=m INSTALL_MOD_PATH=$MODS INSTALL_MOD_STRIP=1 modules_install
```

（`-p4` 去掉 `a/kernel/out-of-tree/aw882xx/`。其余照 `kbuild-y11.sh:123-128` 和它的 vermagic 检查。）验证：新内核里放一声后 `journalctl -k -b | grep -c Awinic` 只多 2 行 `start success`；`pll&clk check fail` 一类错误照旧出现在开机探测里。回滚：`tb323fu-ctl kernel` 的 trial/rollback 机制，或下次构建去掉这一步。

### 6.4 一次就能定"开着值多少 W"的静音 A/B（平板空闲、用电池）

```sh
python3 -c 'import wave; w=wave.open("/tmp/silence90.wav","wb"); w.setnchannels(2); w.setsampwidth(2); w.setframerate(48000); w.writeframes(bytes(4*48000*95)); w.close()'
# A：熄屏 20 s 后 y700-powersample 90 s（什么都不放）
# B：同样熄屏，先 $U pw-play --target effect_input.y700_lenovo /tmp/silence90.wav &，再 powersample 90 s
# ABAB 各两次；B 期间 y700-wakeups 30 应看到 apr_rxwq ≈100/s、pipewire timerfd ≈47/s（验证 §2.3）
```

B−A 就是"扬声器链路开着放静音"的真实代价，§0 第 6 条的 0.03–0.15 W 由它替换。注意 B 里多了 `pw-play` 进程自己每个量子醒一次（≈47 次/s），而"卡在 idle"时没有这个客户端，所以 B−A 会**略高于**卡住的真实代价；`y700-wakeups` 里把 pw-play 那一行减掉再比。silence90.wav 是 95 s，比 90 s 的样本长，样本结束前 WirePlumber 不会挂起。

### 6.5 屏幕键盘补丁（可选）

```sh
# 在平板上 linux/osk 源码副本的上一级（含 linux/ 的目录）；不是 git 仓库就用 patch
cd <含 linux/osk 的源码目录> && patch -p1 --dry-run < osk-click-stream-mute.DRAFT.patch && patch -p1 < osk-click-stream-mute.DRAFT.patch
sh linux/osk/install.sh --no-switch     # 只编译、装文件，然后在 install.sh:49 退出：不重启 fcitx5、不重启键盘
sudo -u user env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \
  /usr/local/bin/y700-osk-ctl restart   # 重启 KWin 的输入法链（launcher → fcitx5 → 键盘），新二进制才生效
ps -o lstart= -p "$(pgrep -x y700-osk)"  # 启动时间应是刚才
```

（审阅更正：原稿说 `--no-switch` 会重启 fcitx5，不对——`install.sh:49` 的 `[ "$SWITCH" = 1 ] || exit 0` 在重启那几行之前就退出了，不手动 restart 的话跑着的还是旧键盘。不用不带参数的 install.sh：它最后的 `y700-osk-ctl on` 会把作者可能关掉的键盘重新打开。）验证：点击音音量设 0，弹出键盘、按几下，`y700-audio-watch 30` 不应出现 `pcm: closed -> RUNNING`；音量设回 5，第一下就有声。回滚：`patch -R -p1 < osk-click-stream-mute.DRAFT.patch`，再跑一次 `install.sh --no-switch` 和 `y700-osk-ctl restart`。

---

## 7. 周期性义务（装了 6.2 之后）

- [ ] PipeWire 升到 ≥1.6.3（Ubuntu SRU 或下个发行版）：`-EBUSY` 检查没了，钩子变成纯保险。升级后跑一次 `y700-audio-watch 600`，看扬声器和两个 filter sink 是否都还能挂起——上游 #5392 报告的"被动 filter/loopback 节点 idle 不挂起、新视频节点唤醒整个图"是更新版本里的回归。
- [ ] WirePlumber 升级：看 `node/suspend-node.lua` 是否加了重试；加了就删本钩子。
- [ ] 装钩子后给 `tools/y700-checklist.py` 加一项：本次开机的 WirePlumber 日志里出现 `still idle after 5 extra Suspend` 就提醒（本轮没改 checklist）。
- [ ] 上游 tb323fu 若新增 WirePlumber/PipeWire 音频配置：重做 §1 的表。

---

## 8. 未验证

- 平板上的任何现场状态：仓库外的 WirePlumber/PipeWire 配置（H3）、扬声器 sink 的实际属性、亮屏快照当时的时序、4 次周期分别是谁（§6.0/6.1 才能回答）。
- H2 是否在这台机器上发生过：只知道 1.6.2 有这条拒绝路径、WirePlumber 不重试；没有任何日志证明它命中过（PipeWire 只在 debug 级别打 `can't suspend … busy`）。
- §2.3 的唤醒账是按源码推的；功耗 0.03–0.15 W 是推测，功放静态电流、ADSP 增量都没有数据（§6.4 能测）。`y700-lenovo-tuning` 进程每周期一次唤醒没在 trace 里单独核对。
- 首音延迟"几十毫秒"没测；功放启动的确切耗时取决于 `aw882xx_dev_reg_update` 是否重写寄存器（换 profile 才重写）和 PLL 锁定时间。
- `y700-speaker-suspend.lua` 没有在任何 WirePlumber 里跑过，本机没有 Lua 解释器，连语法检查都没做；API 用法逐个对照了 0.5.13 的 `suspend-node.lua`、`autoswitch-bluetooth-profile.lua`（`node["state"]`）、`module-lua-scripting/api/api.c`、`module-standard-event-source.c:335-348`（事件键 `event.subject.new-state`）。"wanted 的脚本加载失败只告警"是按 `components_and_profiles.rst:136-151` 的文字理解，未实测。
- 脚本搜索路径：原稿按相对名加载，依赖 WirePlumber 进程的 `XDG_DATA_DIRS` 含 `/usr/local/share`；审阅时改成按绝对路径加载（`module-lua-scripting/module.c:137-139` 对 daemon 也接受绝对路径），这条依赖没了。conf 里 `provides` 改成 `hooks.node.y700-speaker-suspend`，让上游 `wireplumber.components.rules`（`wireplumber.conf:770ff`）像对待自带钩子一样给它排在 `support.standard-event-source` 之前——这两处改动同样**没在 WirePlumber 里跑过**。验证步骤里的 "loaded" 日志行仍是唯一的确认。
- `y700-audio-watch`：只在 Windows 的 Git Bash 里用桩跑过（审阅时重跑并补了 journalctl 不可读 / 起不来两种情形）；真机 `pactl list sink-inputs` 的字段、`journalctl -k --grep` 是否可用、root 下 `sudo -u user` 那条路径都没核对。
- 两个补丁只做了 `git apply --check` / `patch --dry-run`（审阅时对 0c7c0c4 = helper-v0.4.2 的副本重做了 `patch -p4` 和 `patch -p1`，都能打上），都没编译。屏幕键盘补丁的部署步骤审阅时改过（§6.5），改后的步骤也没跑过。
- 行号：PipeWire 的行号按上游 1.6.2 tag；Ubuntu 1.6.2-1ubuntu1.1 的 CVE-2026-14330 补丁改了 `impl-node.c` 等文件里的 alloca 部分，打补丁后的行号会偏，语义（`suspend_node()` 的 `-EBUSY` 检查）不受影响，没逐行核对。README 行号按 e353793（2026-10-16 11:01），README 正被并行修改。
- §2.3 的"≈150–300 次 idle 退出/s"是审阅时按"哪些事件落在同一次唤醒里"重估的，同样是推测。
- Ubuntu 的 wireplumber 包是否带额外的 `wireplumber.conf.d` 片段、Ubuntu 打包后的 `/usr/share/pipewire/pipewire.conf` 是否改过上游缺省：只看了上游 0.5.13 / 1.6.2 的源码树（§6.0 的 grep 已覆盖这些目录）。
- 熄屏 30 s 样本的时间点和当时有没有提示音：README 没记，只能用计数反推（§2.4）。
- 熄屏 27 分钟 4 次功放周期与 E3a 第二轮 ssh 轮询（PROTOCOL.md:87）在时间上是否对得上（§4 第 4 条）：离线没有原始日志，没对。
- 我们的 `notify-send` 提示在 Plasma 里会不会带提示音（§4）：没查。
- lore.kernel.org / patchwork 没看（反爬页）；PipeWire 的提交是在 gitlab 克隆里用 `git log --grep` 找的，可能有措辞不同的相关提交没搜到。

---

## 9. README 合并稿（给手工合并的人；README 本身未改）

**"目录里有什么"表新增行：**

| `linux/audio/SUSPEND.md` | 扬声器 sink 为什么"不挂起"、idle 时开着什么、熄屏代价与修法（只读研究） | 仓库 |
| `linux/audio/y700-audio-watch` | 只读诊断：谁打开了扬声器、PCM 开着而 sink idle 多久（STUCK） | 未装 |
| `linux/audio/y700-speaker-suspend.{lua,conf}` | WirePlumber 钩子：扬声器 sink 原生超时后仍 idle 就再发 Suspend（仅在诊断报 STUCK 时装） | 未装 |
| `linux/audio/aw882xx-quiet-stream-log.DRAFT.patch` | aw882xx 每次开关的进度日志降为 debug（随下次内核构建） | 未打 |
| `linux/audio/osk-click-stream-mute.DRAFT.patch` | 屏幕键盘点击音为 0 时不激活点击流（可选） | 未打 |

**新增一节：**

> ## 扬声器为什么"熄屏不挂起"（2026-10-16，研究，只读，未装、未上机）
>
> 起因：亮屏时 `HiFi__Speaker__sink` 和两条滤波链都是 idle、`node.pause-on-idle=False`；熄屏 30 s 样本里 `apr_rxwq` 17/s、pipewire 定时器 7.5/s；熄屏 27 分钟功放开关 4 次。详见 [SUSPEND.md](SUSPEND.md)。
>
> - **pause-on-idle=False 不是谁故意配的**：WirePlumber 0.5 给所有 ALSA 节点都这么设（防 `snd_pcm_drop` 爆音，PipeWire d9a63dc69），由 `suspend-node.lua` 在 idle 5 s 后挂起。上游平台包（helper-v0.4.2 与本地副本逐文件相同）和我们的配置里都没有改挂起的键。
> - **idle 不等于关**：PCM 照跑静音，ADSP 两张图、MI2S、两颗功放全开，每 10 ms 一条 GPR 消息；这个平台上 pause 只停 CPU 一侧的消息和定时器，不停 DSP 图、不静音功放，只有挂起（关 PCM）才全省。按源码约 300–400 个唤醒事件/s（合并成 idle 退出约 150–300 次/s，推测）。
> - **熄屏时它大概会挂起**（反推）：那个 30 s 样本的两个计数都折合"开了约 5 s"（=挂起超时），不像一直开着。**建议更正 1011–1012 行**（e353793 的行号）："apr 17/s = 熄屏音频图没挂起、疑是滤波链按着"应读作"样本里大概撞上一次约 5 s 的打开窗口"；与 ALWAYS-ON §5a 的 LPASS macro 也无关（macro 不在扬声器链路上）。
> - **4 次开关**的候选是提示音（Telegram/KDE/网页）或屏幕键盘在无人触摸时被拉起（show() 激活点击流 10 s）；这 27 分钟很可能是 E3a 第二轮、每 2 分钟有一次 ssh 登录的那段，时间戳要对一下。平均占空比约 1.5 %，≈0 W。
> - **可能的真问题**：PipeWire 1.6.2 在链接忙时拒绝挂起（bb0efd777，1.6.3 已回退，Ubuntu 没回移），WirePlumber 只发一次 Suspend 不重试 → 可能卡在 idle。没有证据证明发生过。
> - **做法**：先跑 `y700-audio-watch` 半小时；只有报 `STUCK` 才装重试钩子（下次开机生效，**不重启 PipeWire/WirePlumber**，免得踩 745 行的 UCM 路由坑）。aw882xx 日志补丁随下次内核；键盘补丁可选。
> - **有意不做**：`node.suspend-on-idle`（截尾、同样被 -EBUSY 拒）、保活、为生效重启音频栈、让守护去挂起 sink、缩短超时或键盘 10 s 计时（≈0 W，换来更多首音延迟）。
> - **周期性义务**：PipeWire ≥1.6.3 / WirePlumber 升级后各跑一次 `y700-audio-watch 600`；装钩子后 checklist 加"WirePlumber 日志出现 still idle after 5 extra Suspend 就提醒"。

---

## 10. 出处

- WirePlumber 0.5.13：`src/scripts/monitors/alsa.lua:189-190`；`src/scripts/node/suspend-node.lua:12-65`；`src/config/wireplumber.conf:57-80,600-640`；`src/config/wireplumber.conf.d/alsa-vm.conf`；`src/config/wireplumber.conf.d.examples/alsa.conf:89,125-126`；`modules/module-lua-scripting/api/api.c:1156-1240`；`modules/module-standard-event-source.c:335-348`；`lib/wp/base-dirs.c:94-117`；`lib/wp/log.c:211`；`docs/rst/{daemon/locations,daemon/configuration/components_and_profiles,scripting/custom_scripts,scripting/lua_api/lua_log_api}.rst`；提交 73a07d00。
- PipeWire 1.6.2：`src/pipewire/impl-node.c:270-322,451-585,700-718,1170-1171,1280-1282,2740-2860`；`src/pipewire/context.c:985-993,1095-1160,1269-1285,1437-1560,1600-1840`；`src/pipewire/impl-link.c:95-150,400-470,836-905,975-1016,1045-1070`；`src/pipewire/stream.c:2428-2442`；`src/modules/module-client-node/client-node.c:1051-1055`；`spa/plugins/audioconvert/audioadapter.c:1068-1140`；`spa/plugins/alsa/alsa-pcm-sink.c:304-345,566-610`；`spa/plugins/alsa/alsa-pcm.c:37-100,1203-1300,2410-2540`；`spa/plugins/alsa/alsa-pcm.h:41-42`；`spa/plugins/alsa/acp/{acp.c,alsa-ucm.c}`；`doc/dox/config/pipewire-props.7.md:371-390,467-469,781-789`。提交 d9a63dc69、ecd1d3e1d、bb0efd777、1689b441d（1.6.3+）、6b0248d68（master）、9931921c2、b03b57ce9；issue #5207、#5392。Ubuntu `pipewire_1.6.2-1ubuntu1.2/changelog`。
- Linux v7.3-rc4：`sound/soc/qcom/qdsp6/q6apm-dai.c:23-31,91-126,130-150,214-311,314-365,367-470`；`q6apm.c:556-640,740-760,802-830`；`q6apm-lpass-dais.c:185-306,408-440`；`audioreach.h:42,57`；`sound/soc/qcom/sc8280xp.c:247-300,455-462`；`sound/soc/soc-pcm.c:978,1052-1092,1128-1150`；`sound/soc/soc-dai.c:543-575`；`drivers/soc/qcom/apr.c:161-187,315-338,620-625`；`drivers/rpmsg/qcom_glink_native.c:554-619`。
- 上游 tb323fu-linux（0c7c0c4 = helper-v0.4.2 的对应文件）：`userspace/platform/**`（§1 表）、`kernel/dts/baldur-audio.dtsi:21-50,104-152`、`kernel/out-of-tree/aw882xx/{aw882xx.c:265-437,757-786,1005-1035;aw882xx_device.c:575-660,665-723,752-911,925-1062,1120-1160,1218-1460;aw882xx_monitor.c:455-545;aw882xx_spin.c:105-121;aw882xx.h:27-34;README.md}`、`firmware/audio/{LENOVO-TB323FU.m4,README.md}`、`docs/hardware-status.md:84,104,155`。
- 本仓库：`linux/audio/{y700-speaker-guard,y700-wait-card.conf}`（作者自用的 `y700-lenovo-tuning.conf` 未随附，见 [README.md](README.md)）、`linux/osk/src/{sound.cpp,sound.h,osk.cpp}`、`linux/osk/install.sh`、`linux/controlpanel/y700-control-center/src/backend.cpp:41,313`、`tools/y700-offmeasure.sh`、`linux/kernel-y8/{kbuild-y11.sh:21,123-128,config-t49-y9:7822,inventory/packages}`、README 200/271–283/744–745/1011–1012 行（e353793）、`linux/power/{WAKEUPS.md,ALWAYS-ON.md §5a}`、`linux/power/cx-collapse/{PROTOCOL.md :87 与 §9,crash-0341-lastkmsg.log}`、`linux/net/{y700-wifi-watchdog,y700-display-watchdog}`（notify-send）。
- 审阅补读：WirePlumber 0.5.13 `modules/module-lua-scripting/module.c:130-191`、`lib/wp/base-dirs.h:56-76`、`src/config/wireplumber.conf:250-256,612-641,770-800`、`lib/wp/log.c:210-284`；PipeWire 1.6.2 `src/daemon/{pipewire,pipewire-pulse,filter-chain,minimal,jack}.conf.in`（`pipewire.conf.in:275-299` Dummy/Freewheel-Driver）、`src/pipewire/impl-node.c:529-585,700-719,803-820,2786-2860`、`src/pipewire/impl-link.c:75-88,975-995`、`src/pipewire/context.c:1488-1553`、`src/pipewire/resource.{h:128-142,c:221-257}`、`src/modules/module-protocol-native.c:415-432`、`module-protocol-native/protocol-native.c:1331-1346` + `spa/include/spa/utils/hook.h:505-527`（客户端的 `send_command` 返回值被 `spa_hook_list_call` 丢掉，所以 `-EBUSY` 不会作为错误回到 WirePlumber）、`src/modules/module-protocol-pulse/pulse-server.c:4100-4137`（原生流的 Corked = 节点不在 running）；v7.3-rc4 `q6apm-dai.c:110-128,455-473,1006-1014`、`q6apm-lpass-dais.c:300-349,409-429`、`soc-pcm.c:2110-2122,2672-2683,2873-2885`、`drivers/soc/qcom/apr.c:620`；Ubuntu `changelogs.ubuntu.com/…/pipewire_1.6.2-1ubuntu1.2/changelog`（重新取过：无 bb0efd777 的回退；"Enable pipewire jack emulation" 是打包选项，平板没装 `pipewire-jack`）；GitLab API 的 issue #5207、#5392（重新取过，与原稿描述一致）。
- 源码副本在本地临时目录（`src/{wp,pw,k}`、`src/{wp,pw}.git`），不入库。

---

## 11. 独立审阅记录（2026-10-16，离线，同样未上机）

逐条重读了原稿引用的仓库文件和上游源码（WirePlumber 0.5.13、PipeWire 1.6.2 的 tag，v7.3-rc4 的内核文件从 raw.githubusercontent.com 另取了一份、与原稿副本逐字节相同；helper-v0.4.2 的 11 个音频/功放/DT 文件另取、与本地副本相同），重跑了桩测试和两个补丁的 dry-run。主体结论（缺省就会 5 s 挂起、idle = PCM 照跑、只有 close 才让功放和 DSP 图下电、1.6.2 有 `-EBUSY` 拒绝挂起且 WirePlumber 不重试）**成立**。改动：

| 处 | 问题 | 改成 |
|---|---|---|
| `y700-audio-watch` | journalctl 接在 `sed` 管道后台跑，`$!` 是 sed；退出时 `journalctl -f` 留下来（桩测试复现），在 systemd-run 外跑会剩一个每条日志都被唤醒的进程 | journalctl 直接后台跑并检查是否起来；去掉重复的 `kernel:` 前缀；`sudo` 那条路径显式带 `LC_ALL=C`；subscribe 断开的提示一分钟最多一条 |
| `y700-speaker-suspend.conf` | 按相对名找脚本，依赖会话的 `XDG_DATA_DIRS` | 绝对路径；`provides` 改成 `hooks.node.*`，套用上游给钩子的加载顺序规则 |
| §6.5 | `install.sh --no-switch` 在重启 fcitx5 之前就退出，原稿说它会重启 | 加 `y700-osk-ctl restart`；不是 git 仓库时用 `patch -p1` |
| §0/§2.2 | "pause 几乎不省" | pause 省掉 CPU 侧的 GPR 消息和定时器，只是 DSP 图、MI2S、功放不停 |
| §0/§2.3/§5.2/§9 | "300–400 次唤醒/s" 与 idle 退出混用 | 事件 300–400/s，idle 退出估计 150–300/s |
| §0/§2.4/§9 | "现有证据说明会挂起" 说得太满；麦克风 suspended 被当成旁证的余地 | 改为"更像会挂起（反推）"；注明节点创建即 suspended |
| §3 H4 | "Ubuntu 开了 JACK 模拟"；"挂到 ALSA sink 这个兜底驱动" | 平板没装 pipewire-jack；无人在跑时兜底驱动是 Dummy-Driver（priority 200000） |
| §4 | 漏了时间巧合与 notify-send | 补第 4 条候选（E3a 第二轮的 ssh 轮询）和 notify-send 未排除 |
| §6.0/§6.2/§6.3/§6.4 | grep 漏主配置；验证时记录器与 pw-play 同时起、可能错过打开；speaker-gain status 以 root 跑查不到默认输出；补丁目录前后不一；A/B 的 B 含 pw-play 自身唤醒 | 各自补正 |
| §4/§6.0 | 漏了第三种探测式打开：EnumFormat 枚举（含 §6.0 自己的 `pw-dump`）会让关着的 PCM 开关一次 | 补上来源与日志特征；§6.0 提醒 |
| 引用 | README 行号已漂移（743→745、1009–1010→1011–1012）；`q6apm-dai.c:95` 是录音描述；close 那行写成 hw_free；两个补丁头的节号 | 更正 |

审阅时也确认了：`-EBUSY` 不会作为错误回到 WirePlumber（客户端方法的返回值在 `pw_resource_notify` → `spa_hook_list_call` 里被丢掉），所以 H2 在默认日志级别下确实无迹可查，只能靠 `y700-audio-watch` 的 STUCK 或 PipeWire debug 日志；拓扑是 `WR_SH` 写共享内存端点（`firmware/audio/LENOVO-TB323FU.m4:19`），不是 push-pull，每周期一条 WRITE_DONE 的推算成立。

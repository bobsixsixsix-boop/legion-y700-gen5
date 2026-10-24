# linux/audio：扬声器链路、爆音与挂起

TB323FU 内置扬声器在 Linux 一侧的本地补充。上游 tb323fu-linux 提供扬声器保护链（`effect_input.speakers`：高通、压缩、RMS 上限、限幅）和功放增益 helper（`tb323fu-speaker-gain`）。这里的东西都挂在它后面或旁边，不替换它。

研究笔记：

- [POPS.md](POPS.md)：开关音频时的爆音（假设 H1–H5、测试方法、结论）。
- [SUSPEND.md](SUSPEND.md)：扬声器 sink 什么时候真正关闭、它在熄屏时的功耗。

## 链路

```
应用 → effect_input.y700_lenovo（「扬声器（联想调音）」，独立 pipewire 进程，y700-lenovo-tuning.service）
     → effect_input.speakers（上游保护链）
     → alsa_output.platform-sound.HiFi__Speaker__sink（raw，桌面上隐藏）
```

## 未随附：调音配置 `y700-lenovo-tuning.conf`

作者自用的 `/usr/local/share/y700/y700-lenovo-tuning.conf`（以及它用到的 FIR 文件和生成 FIR 的脚本）是从联想原厂固件里的杜比调音参数换算来的，属于由专有文件派生的内容，**不在本仓库里**。下面这些文件都以名为 `effect_input.y700_lenovo` 的 sink 存在为前提：

| 文件 | 没有这个 sink 时 |
|---|---|
| `y700-lenovo-tuning.service` | 起不来（`ExecStart` 指向的配置不存在） |
| `y700-speaker-guard` | 有人选了 raw sink 时，它会把默认输出改到这个不存在的 sink |
| `y700-wait-tuned-sink` 及两个 `*-wait-tuned-sink.conf` drop-in | 每次 Plasma 启动都多等 12 秒才超时 |
| `tools/y700-checklist.py` | 报 `y700-lenovo-tuning.service` 不在运行 |
| `bypass-test.sh`、`eqtest.*`、`pop-test*.sh` | 播放目标不存在；`pop-test-h3.sh` 另外要一份你自己的平滑音量版调音配置放在 `/root/smooth.conf`（作者的那份草稿同样未随附） |

要用这些文件，就自己在那个路径放一个 PipeWire filter-chain 配置，作为独立进程运行，并满足这几个约定：

- 输入侧 `node.name = "effect_input.y700_lenovo"`，`priority.session = 1400`（高于蓝牙 sink 的 1010，WirePlumber 按它挑默认输出；耳机的切换由 `y700-speaker-guard` 负责），`node.virtual = false`（不然 Plasma 的音量小部件不列它，原因见 `61-y700-speaker-raw-virtual.conf` 的注释）；
- 回放侧 `node.name = "effect_output.y700_lenovo"`，`node.passive = true`，`target.object = "effect_input.speakers"`，`node.dont-reconnect = true`，`node.dont-fallback = true`，`stream.dont-remix = true`（必须接在上游保护链前面，不许绕过它）；
- 加载的模块：`libpipewire-module-rt`（`ifexists nofail`）、`-protocol-native`、`-client-node`、`-adapter`、`-filter-chain`。

内容可以只是直通（每个声道一个 builtin `copy` 节点），也可以是你自己的 EQ。下面是一个**没有在真机上验证过**的直通骨架，只用来说明这些约定：

```
context.properties = { log.level = 0 }
context.spa-libs = { audio.convert.* = audioconvert/libspa-audioconvert  support.* = support/libspa-support }
context.modules = [
  { name = libpipewire-module-rt  args = { } flags = [ ifexists nofail ] }
  { name = libpipewire-module-protocol-native }
  { name = libpipewire-module-client-node }
  { name = libpipewire-module-adapter }
  { name = libpipewire-module-filter-chain
    args = {
      node.description = "扬声器（联想调音）"
      media.name       = "扬声器（联想调音）"
      filter.graph = {
        nodes = [
          { type = builtin name = copyL label = copy }
          { type = builtin name = copyR label = copy }
        ]
        inputs  = [ "copyL:In" "copyR:In" ]
        outputs = [ "copyL:Out" "copyR:Out" ]
      }
      audio.channels = 2
      audio.position = [ FL FR ]
      capture.props = {
        node.name        = "effect_input.y700_lenovo"
        media.class      = Audio/Sink
        priority.session = 1400
        node.virtual     = false
      }
      playback.props = {
        node.name           = "effect_output.y700_lenovo"
        node.passive        = true
        target.object       = "effect_input.speakers"
        node.dont-reconnect = true
        node.dont-fallback  = true
        stream.dont-remix   = true
      }
    }
  }
]
```

不想要这一级的话，就别装 `y700-lenovo-tuning.service`、`y700-speaker-guard`、`y700-wait-tuned-sink` 和它的 drop-in，直接用上游的「Speakers」。`y700-speaker-guard` 没有针对这种情况的分支。

## 文件

| 文件 | 作用 | 状态 |
|---|---|---|
| `y700-speaker-guard`、`y700-speaker-guard.service` | 用户服务。确保声音都经过保护链：raw sink 被选成默认输出、有流直接送到 raw sink、保护节点消失时，把功放压回安全衰减；耳机连上时切过去，断开时切回来 | 日常在用 |
| `y700-lenovo-tuning.service` | 用户服务，运行上面那个调音配置 | 日常在用（配置不随附） |
| `61-y700-speaker-raw-virtual.conf` | WirePlumber 规则：把 raw sink 标成虚拟设备，让桌面的音量界面不列它 | 日常在用 |
| `y700-wait-card.conf`、`y700-wait-sound-card` | 自动登录时 PipeWire 比声卡早起来约 5 秒；让增益 helper 等声卡就绪再打开功放 | 日常在用 |
| `y700-wait-tuned-sink`、`y700-kded6-wait-tuned-sink.conf`、`y700-plasmashell-wait-tuned-sink.conf`、`test-wait-tuned-sink.sh` | kded6 和 plasmashell 启动前等调音 sink 成为默认输出（最多 12 秒），免得它们绑到上游「Speakers」上；附一个在 PC 上也能跑的测试 | 日常在用 |
| `y700-speaker-suspend.conf`、`y700-speaker-suspend.lua` | WirePlumber 钩子：sink 超时后仍「idle」（PCM 开着、跑静音）时再发一次 Suspend | **没装，从没运行过**（见 SUSPEND.md） |
| `y700-audio-watch` | 只读记录谁打开了扬声器、sink 是否在 PCM 开着时停在 idle | 诊断工具，没装 |
| `y700-osk-clicks-latency.client.conf.DRAFT`、`osk-click-stream-mute.DRAFT.patch` | 屏幕键盘按键音相关的诊断配置和补丁（POPS.md H2、SUSPEND.md） | DRAFT，没装 |
| `aw882xx-*.DRAFT.patch`、`1050-arm64-dts-qcom-baldur-audio-aw882xx-fade-flag.DRAFT.patch` | 针对功放驱动和设备树的补丁草稿 | DRAFT，没编译或没上机验证，没提交上游 |
| `pop-test*.sh`、`pop-analyze*.py`、`bypass-test.sh`、`eqtest.*` | 爆音录音与分析、保护链旁路测试、EQ 测试 | 测试工具，多数要 root |
| `lpmap.py`、`lpdm.py`、`lpcat.py` | 只读列出 / 映射 / 导出 Android super 分区里的逻辑分区（研究原厂音频配置时用） | 工具 |

安装没有统一脚本，各文件开头的注释写了安装位置。改 WirePlumber 配置后等下次开机生效，别在播放中手动重启 PipeWire / WirePlumber（会让音频 DSP 卡住）。

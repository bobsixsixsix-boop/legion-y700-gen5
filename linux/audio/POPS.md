# 爆音修复计划（对抗性复核后）

2026-10-16，全程离线：没上机、没编译、什么都没装。

作者 13:15 报告三种情况下有爆音：
1. 旋转屏幕；
2. 弹出屏幕键盘；
3. 按住音量键连续调音量。

三份调研（功放 / PipeWire / 键盘+旋转）的结论我逐条回到源码重读过。本文分两部分：先是复核结论（§1），再是修复计划（§2），按风险从小到大排。所有改动都还只是草稿；先跑第 0 步的只读判别，再根据结果挑后面的条件项。

**读的版本**
- PipeWire 1.6.2：`pops/pw-1.6.2`
- WirePlumber 0.5.13：`pops/k/wp-*.lua`
- plasma-pa v6.6.5：`pops/plasma-pa-6.6.5`
- KWin v6.6.6 `src/input.cpp`：`pops/verify/kwin-input-v6.6.6.cpp`
- pulseaudio-qt v1.9.0 和 v1.8.1 的 `src/device_p.h`：`pops/verify/`，两个版本这段相同；平板上实际装的版本没查
- libcanberra 0.30：Debian 0.30-18 源码，`pops/libcanberra/pulse.c`
- 内核 v7.3-rc4：`pops/k/`
- aw882xx：tb323fu-linux `kernel-t47`（0c7c0c4）的 `kernel/out-of-tree/aw882xx`
- y700 仓库：HEAD 3faeef1
- y7 内核开机日志：`linux/kernel-y8/inventory/dmesg`

---

## 1. 复核结论

### 1.1 新发现 H5：音量键和反馈音会被转到 raw 硬件 sink（三份调研都没提到）

**音量键调的是谁。** plasma-pa 6.6.5 的音量键是 kded 模块 `audioshortcutsservice` 里的 QAction。每触发一次，它对 `m_preferredDevice.sink()` 调 `changeVolumePercent`，再调 `playFeedback`；反馈音也放到同一个 sink 的 index 上（`src/kded/audioshortcutsservice.cpp:79-106, 335-345`）。

**PreferredDevice 怎么选**（`src/preferreddevice.cpp:14-54`）：
- 先在 RUNNING 状态里找，再在 IDLE 状态里找，都没有才退回默认 sink；
- 同一状态里，**非虚拟**设备总会入选，虚拟设备只有是默认 sink 时才入选；
- 默认 sink 只有和候选处于同一状态时才能胜出。

**我们的 sink 哪个算虚拟。**
- filter-chain 默认给节点设 `node.virtual = true`（`module-filter-chain.c:1995-1996`）；
- pipewire-pulse 只给非 virtual 节点置 `SINK_HARDWARE`（`pulse-server.c:3774-3776`）；
- pulseaudio-qt 用这个 flag 判断虚拟：`isVirtual = !(flags & 4)`（`device_p.h:145`）。

所以联想调音和 Speakers 这两条 filter sink 都是虚拟的，raw 的 `alsa_output…HiFi__Speaker__sink` 是**唯一的非虚拟 sink**。

**后果。** 只要 raw sink 的状态比联想调音 sink 更"活"（例如 raw 还是 IDLE，联想调音已经 SUSPENDED）：
- 音量键调的是 raw sink，守护随后把它钉回 100 %（`y700-speaker-guard:96-99`），听起来是一次没有斜坡的增益跳变；
- 反馈音直接放进 raw sink，守护把它当成旁路流：先 move，再把功放从 21 硬降到 159（约 −13 dB），下一轮才升回，同时弹出"一个应用的声音绕过了扬声器保护"的通知（`:58-71, :101`）。

**什么时候会出现"raw IDLE、联想调音 SUSPENDED"：**
- (a) PipeWire 1.6.2 以 -EBUSY 拒绝挂起 raw sink，即 SUSPEND.md 里的 STUCK 假设；
- (b) 任何"只延长 raw sink 挂起超时"的改法——**正是功放调研提议的 `91-y700-speaker-keepopen.conf`**；
- (c) 每次挂起时，raw sink 关 PCM 要几十毫秒（hw_free 里两颗功放各约 19 ms），这期间 raw 还是 IDLE，形成一个很短的窗口。

这条只从源码推出，没有上机，要靠时间线核实：按音量键时出现的 `'change' on sink #N`，N 是否是联想调音的 index。

### 1.2 被推翻或修正的结论

1. **SUSPEND.md:165"功放关闭时先渐出、开启时渐入"：推翻。**
   - 两颗功放都打印了 `fade-flag: 0`（y7 dmesg 第 1015-1016、1056-1057 行）；
   - fade_en 为 0 时，`aw_dev_fade_in/out` 一进去就返回（`aw882xx_device.c:706-707, 732-733`）。

2. **H2 的原说法"量子变化导致 ALSA 重配置 / 重开 / xrun"：在 1.6.2 推翻。**
   - 非强制的量子变化只写 `target_duration`，只有 `force_quantum` 才会调 `reconfigure_driver`（`context.c:1762-1795`）；
   - ALSA 驱动这边只在 `check_position_config` 里重算 threshold（`alsa-pcm.c:3133-3163`），不重开 PCM。

3. **"解除静音时的数字台阶就是 H1 爆音"：对正常开流基本推翻。**
   - y7 实测：`playback enter` 在 25.0199 s，两颗功放解除静音在 25.0398/25.0400 s，即开 PCM 后约 20 ms（dmesg 第 1610、1636-1637 行）；
   - 这一刻落在 PipeWire 预先写入的 ≥15 ms 静音里（`alsa-pcm.c:2737-2740`，batch 设备的 headroom 见 `:2109-2120`）。
   - 所以 fade-flag 补丁对 H1 几乎没用。如果 H1 确实会响，只能是 PWDN/AMPPD 的模拟瞬态，离线判断不了。

4. **`91-y700-speaker-keepopen.conf`（只延长 raw sink 的挂起超时）：否决。**
   - 违反熄屏功耗红线：熄屏时每一声之后都多开 60 s；设成 0 则永远开着；
   - 触发 H5：raw IDLE、联想调音 SUSPENDED 时，音量键和反馈音都落到 raw sink。

5. **键盘调研说"冷链路上的第一下点击可能被部分或整个吃掉"：说过头了。**
   - `play()` 把点击请求放进环形队列（`sound.cpp:193-207`），流激活后的第一个 `process()` 才把它混进去（`:220-231`）；
   - 这一帧排在预填的静音之后，而功放在开 PCM 约 20 ms 时就已经解除静音；
   - 所以通常只是推迟，不会丢；只有 PLL 检查重试、解除静音被推迟时才可能被切掉开头。这一点没有实测。

6. **README 3faeef1"plasmashell 的音频小程序把音量键绑到开机时看到的默认 sink"：在 6.6.5 不准确。**
   - 绑定音量键的是 kded 模块；小程序只负责加载它（`src/qml/globalservice.cpp:59-64`）；
   - PreferredDevice 本身会跟着 `defaultSinkChanged` 走（`preferreddevice.cpp:64`）。
   - 因此 `y700-wait-tuned-sink` 推迟 plasmashell 启动，未必是 12:51 那次开机变正确的原因。（10-17 已改到 kded6，见 README 音量键第三次一节）

7. **功放调研的日志判别表需要补两点：**
   - `playback enter` 只说明有人打开了 PCM：pw-dump、pipewire-pulse 刷新格式参数时只做 startup/shutdown，也会打印这一行，但功放不上电。判断 H1 要看 `start success` 和 `device_stop: done`。
   - 量子为 256 时 DSP 可能断供：拓扑是 WR_SH、非 push-pull（`LENOVO-TB323FU.m4:18-24`）；q6apm 只把整周期交给 DSP（`q6apm-dai.c:314-334`）；硬件指针只在 WRITE_DONE 时前进（`:501`）。这种断供不会形成 ALSA XRUN，也就不会留下 `already start`。**所以"功放侧没有任何痕迹"并不能排除 DSP 侧掉音。**

8. **`mute_unmute_on_trigger` 补丁的代价被低估了。**
   - PipeWire 把 stop_threshold 留成默认值（`alsa-pcm.c:2597-2602` 那段是 `#if 0`），所以内核自己检测到的 XRUN 会在 `snd_pcm_period_elapsed` 里触发停止；
   - `snd_pcm_period_elapsed` 跑在 GPR 事件路径上（`q6apm-dai.c:142-143`，即 apr_rxwq 工作队列）；
   - 设了这个标志后，`aw882xx_mute(1)` 会在那里同步执行 `cancel_delayed_work_sync` 和两颗功放的 device_stop（每颗 19–33 ms，`aw882xx.c:404-411`），堵住 DSP 消息处理约 40–66 ms。
   - 静音这条路径不等 GPR 回包，所以不会死锁。

### 1.3 复核后确认的结论

详细出处没有收进本文。要点：

**功放侧**
- 功放在满增益下硬切 HMUTE；
- 开流和关流的顺序都正确；
- xrun 恢复时，功放在满增益、未静音的状态下丢掉时钟；
- 守护会把增益硬降 13 dB 再升回；
- 旋转本身碰不到功放。

**Plasma 侧**
- 按住音量键时每一步都会：截断上一个反馈音、新建一条流、瞬时改一次增益；KWin 会把按键重复事件继续转发给全局快捷键。

**PipeWire 侧**
- 非强制的量子变化不会重配驱动；
- pulse 客户端欠载时整块补静音；
- 运行时可以通过 settings 元数据改 `clock.min-quantum`；
- WirePlumber 按节点读取挂起超时。

**键盘侧**
- 每次 show() 都会激活点击流 10 s，流是 256/48000、RT_PROCESS、同步节点；
- 旋转时键盘只重新排版。

---

## 2. 修复计划（风险从小到大）

### 0. 判别（三个场景都要做，不改任何东西，先做这一步）

- **机制**：区分 H1（PCM 开/关导致功放上下电）、H2（量子切换）、H3（反馈音截断 / 增益台阶）、H4 / xrun / DSP 断供、H5（音量键和反馈音落到 raw sink）。

- **只读采集**，时间戳要对齐：
  - 内核日志：`journalctl -k -f -o short-monotonic | grep -E 'Awinic.*(start success|device_stop: done|already start|mute state|volume_put)'`；
  - `pactl subscribe`，开始前先用 `pactl list short sinks` 记下三个 sink 的 index；
  - 每 0.5 s 读一次 `/proc/asound/card0/pcm0p/sub0/status`；
  - `pw-top -b`，看扬声器驱动的 QUANT 和各节点的 ERR；
  - 也可以直接用仓库里的只读工具 `linux/audio/y700-audio-watch`；
  - **不要跑 pw-dump**：它会让已挂起的 PCM 开关一次。

- **A/B 做法**：
  1. 用 python3 的 wave 模块生成 60 s 静音 wav，然后运行 `pw-play --target effect_input.y700_lenovo --latency 256 silence60.wav`，让链路先以量子 256 跑起来；
  2. 链路跑着的时候，依次弹键盘、旋转、按住音量键；
  3. 停掉静音流，等 PCM 变回 closed，再把三个动作各做一遍；
  4. 旋转那一项另外用 busctl 抓门控日志，看旋转时刻附近有没有 SHOW、KWin-initiated 这类行（可用 `linux/osk/tests/gate-log.sh` 记录）。

- **怎么判读**：
  - 只在 PCM 从 closed 变成 RUNNING、并有 `start success` 时响 → H1；
  - 链路已经跑着、QUANT 没变，仍然响 → H4 / xrun / DSP 断供：看 ERR 有没有加一、有没有 `already start`；
  - 只在有媒体在播、而且 QUANT 在 1024 和 256 之间跳的时候响 → H2；
  - 音量键的 `'change' on sink #` 落在 raw sink 的 index 上，或者 sink-input 建在 raw sink 上 → H5。

- **回滚**：Ctrl-C 停掉静音流即可，不留任何持久改动。
- **功耗**：只在测试的那一分钟里亮屏多开扬声器链路，没有持久成本。
- **风险**：极低。

### 1. 按住音量键：关掉音量反馈音（AudioFeedback=false）

- **机制**：
  - H3a：每次按键重复，plasma-pa 都会 cancel 还在放的上一个反馈音（`volumefeedback.cpp:43-52`）。libcanberra 对它调 `pa_context_kill_sink_input`（`pulse.c:1146-1150`），pipewire-pulse 再 `pw_registry_destroy`（`pulse-server.c:4877-4911`），波形当场断掉。KWin 把按键重复继续交给全局快捷键（`input.cpp:1099-1104 @v6.6.6`），于是每一步都有一次截断，外加一条新流。ocean 主题的这个音长 0.30 s，按键重复默认每秒 25 次。
  - H1：扬声器挂起时，第一下按键只为了放反馈音就把 PCM 打开。
  - H5：处在 H5 状态时，反馈音直接进 raw sink，触发守护降增益。

- **改动**：以桌面用户执行
  ```
  kwriteconfig6 --file plasmaparc --group General --key AudioFeedback --type bool --notify false
  ```
  - 用 root 执行时，前面加 `sudo -u user env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus`。
  - 图形界面等价操作：系统设置 → 声音 → 配置音量控制 → 取消勾选音量反馈。
  - 应该立即生效：kded 的 GlobalConfig 继承 GlobalConfigSkeleton，KConfigWatcher 一收到变更通知就 `load()`（`globalconfigskeleton.h:29-34`、`globalconfig.kcfgc`）；而 `playFeedback` 每次都重新读 `audioFeedback()`（`audioshortcutsservice.cpp:335-338`）。
  - 想保留提示音的备选（没写）：在用户声音主题里覆盖一个 ≤30 ms、尾部渐零的 `audio-volume-change`。这样下一次重复到来时上一声已经放完，不会再被 cancel；但每一步仍会新建一条流。

- **验证**：
  - `kreadconfig6 --file plasmaparc --group General --key AudioFeedback` 输出 false；
  - `sh pwpa/pw-pa-checks.sh hold 10`，期间按住音量键：`sink-input new` 应为 0（改之前约每步 1 个），`'change' on sink #` 只落在联想调音的 index；
  - 什么都不放、PCM 为 closed 时按住音量键：PCM 一直 closed，内核没有新的 `start success`；
  - 耳听。

- **回滚**：同一条命令，把 false 改成 true。
- **功耗**：省电——音量键不再为了反馈音打开扬声器（每次至少 5 s）。
- **风险**：几乎为零。代价是改音量时不再有"嘀"声，OSD 照常显示。`--notify` 没在平板上验证过；如果没生效，注销重新登录即可。

### 2. 弹出键盘 / 旋转时有媒体在播：运行时 min-quantum A/B（条件项）

- **机制**：
  - H2 剩下的两条：
    - 点击流的 `node.latency=256/48000`（`sound.cpp:119`）会在它活跃时把正在运行的图拉到 256（`context.c:1615-1619, 1742-1760`），键盘收起或 10 s 不打字后再拉回去。量子变大的那个周期里，按小量子攒数据的 pulse 客户端（浏览器视频）凑不够 minreq，就会整块补静音（`pulse-server.c:1446-1476`）。
    - 量子 256 时，DSP 前面通常只排着一个周期（拓扑 WR_SH + 只交整周期，见 §1.2 第 7 条），被抢占超过约 5 ms 就断供。这是推导出来的。
  - H4：点击流是同步的 RT_PROCESS 节点（`stream.c:2089-2093`：只有不带 RT_PROCESS 的流才默认 async），量子 256 时每周期的截止时间只有 5.3 ms。

- **改动**：
  1. 先做运行时实验，不持久（以桌面用户）：`pw-metadata -n settings 0 clock.min-quantum 1024`（`settings.c:163-166`）。
  2. 只有 A/B 证明有效才固化，**优先只改键盘**：把 `pops/y700-osk-clicks-latency.client.conf` 装成 `~user/.config/pipewire/client.conf.d/90-y700-osk-clicks-latency.conf`，再 `y700-osk-ctl restart`。它用 stream.rules 给 `y700-osk-clicks` 设 `node.latency=1024/48000`；规则在程序设完属性之后才应用（`stream.c:2132`），所以能覆盖 `sound.cpp` 里的值。
  3. 不推荐全局的 `pwpa/90-y700-min-quantum.conf`。

- **验证**：
  - 放视频时弹出、收起键盘，用 `pw-top -b` 看扬声器驱动的 QUANT：改之前会在视频的量子和 256 之间跳，改之后应保持不变；
  - ERR 不增长；
  - 耳听视频里那一声是否消失；
  - 没有媒体在放时，这一项不应有任何效果（那种情况属于 H1）。

- **回滚**：`pw-metadata -n settings 0 clock.min-quantum 0`；或删掉 client.conf.d 里的文件，再 `y700-osk-ctl restart`。
- **功耗**：不增加。点击流活跃时，图的唤醒从约 188 次/s 降到约 47 次/s，略省；与熄屏无关。
- **风险**：低。代价是按键到出声的延迟变长，估计从约 18 ms 变成约 40 ms（未测）。

### 3. 弹出键盘（只弹出不打字、重新弹出）/ 旋转时重新弹出：`osk-no-wake-on-show.DRAFT.patch`

- **机制**：
  - H1：每次 show() 都会 `setActive(true)` 并启动 10 s 计时（`osk.cpp:318-319, 134-137`）。活跃的流每个周期都输出静音（`sound.cpp:231`），于是整条扬声器链路跑起来：如果扬声器已挂起，就是一次 PCM open/prepare/start 加两颗功放上电，约 15 s 后再下电。视频在播时，这一刻也是把量子拉到 256 的触发点（H2）。
  - 键盘已显示时，KWin 发起的 Show 也会再次调用 show()（`osk.cpp:349-352`）。这是目前唯一已知的、旋转能间接唤醒扬声器的口子。

- **改动**：
  - 删掉 `osk.cpp:318-319` 那两行，改由 `click()`（`:264-270`）在第一下按键时激活点击流；`sound.h` 的注释同步改成新语义。
  - 可以和 `linux/audio/osk-click-stream-mute.DRAFT.patch` 叠加。
  - 部署：在平板源码副本上 `patch -p1`，然后 `sh linux/osk/install.sh --no-switch`，再以 user 身份 `y700-osk-ctl restart`（SUSPEND.md §6.5）。

- **验证**：先什么都不放，静置 20 s 以上，确认 PCM 为 closed。
  1. 点文本框让键盘弹出，不按键：PCM 保持 closed，内核没有新的 `start success`，`pactl list sink-inputs` 里"Y700 屏幕键盘"是 Corked: yes 或干脆不在列表里，听不到爆音；
  2. 按第一下：PCM 变成 RUNNING，出现 `start success`；记录首击相对按键的延迟，听它是否完整；
  3. 停手 10 s 再过约 5 s：PCM 回到 closed；
  4. 键盘隐藏和显示时分别旋转屏幕：PCM 都不动。

- **回滚**：`patch -R -p1`，再跑一次 `install.sh --no-switch` 和 `y700-osk-ctl restart`。
- **功耗**：省电——每次只弹出不打字，扬声器链路少开约 15 s（亮屏时）。
- **风险**：低。扬声器静默 ≥5 s 后的第一下点击会推迟（估计几十 ms，未测），通常不会丢（见 §1.2 第 5 条）。如果 H1 成立，打字会话的第一下按键仍会碰到一次功放上电，那要靠第 7 项。

### 4. 按住音量键时有声音在放：联想调音链里平滑音量

- **机制**：H3b。pipewire-pulse 改音量只发 channelVolumes，不带斜坡。filter sink 把它原样转给 capture 流的 audioconvert，channelmix 矩阵在周期边界瞬间换值（`channelmix-ops.c:780-838`）。Plasma 每步 5 %，按 PA 的立方刻度，例如 20→25 % 是 +5.8 dB；按住时每秒 25 步。

- **改动**：
  - 用 `pwpa/y700-lenovo-tuning.smooth-volume.conf` 替换 `/usr/local/share/y700/y700-lenovo-tuning.conf`（对应的 diff 是 `y700-lenovo-tuning.smooth-volume.DRAFT.patch`）。这份草稿是在作者自用、未随附的调音配置上改的，同样没有随本仓库发布（见 [README.md](README.md)）。
  - 链路：`capture.volumes` → dcL/dcR（builtin sine，Freq 0、Ampl 0，输出就是 Offset，`plugin_builtin.c:1794-1812`）→ bq_lowpass（50 Hz，Q 0.5）→ mult。
  - filter-graph 会把 sink 音量按 `i % n_ports` 写进这两个控制口，同时让流的软件音量回到 1.0（`filter-graph.c:718-738, 800-829`）。
  - 在什么都没放的时候 `systemctl --user restart y700-lenovo-tuning`。

- **验证**：
  - 先离线试启动：把新 conf 拷到 /tmp/t.conf、log.level 改成 2，`systemctl --user stop y700-lenovo-tuning`，前台跑 `pipewire -c /tmp/t.conf` 约 10 s，看有没有 unknown control port 一类的错误；
  - 装正式文件后 `systemctl --user is-active y700-lenovo-tuning`；
  - 放粉噪或音乐，按住音量键，耳听没有 zipper；
  - `pactl get-sink-volume` 报的值与改之前一致；
  - **重启调音之后一定要按一次音量键，确认 `'change' on sink #` 仍是联想调音的 index。**（README 3faeef1 记录的"音量键调错级"回归，就是联想调音 sink 比别人晚出现造成的。）

- **回滚**：拷回 `pwpa/y700-lenovo-tuning.orig.conf`，`systemctl --user restart y700-lenovo-tuning`，再按一次音量键核对 index。
- **功耗**：只在链路运行时，每个采样多 2 次 sinf、2 个 biquad、2 次乘法，可以忽略；不让任何东西常开，熄屏时为 0。
- **风险**：中。
  - 这份配置从来没在 PipeWire 里跑过；调音实例 log.level=0 会吞掉报错，配错了就是进程起不来、没有声音。
  - 音量调到 0 时，softVolumes 会立即置 0（`filter-graph.c:810`）；静音仍然是瞬时的。
  - 链路重新激活时，平滑器从 0 起步，第一下约 3 ms 长的点击会被压低。

### 5. 条件项：H5 坐实时修路由

- **前提**：第 0 步看到以下任一情况：
  - 音量键的 `'change'` 落在 raw sink 上；
  - 新的 sink-input 建在 raw sink 上；
  - 出现"绕过保护"的通知；
  - `volume_put…=159` 和按键同时出现。

- **改动**，按成因选：
  - (a) `y700-audio-watch` 报 STUCK：装 SUSPEND.md §6.2 已经写好的 `y700-speaker-suspend.lua` 和 `.conf` 重试钩子（下次开机生效）。raw sink 真正挂起后，PreferredDevice 就会回落到默认 sink。
  - (b) 根治，不依赖时序：在 `/etc/wireplumber/wireplumber.conf.d/` 加一条 `monitor.alsa.rules`，对 `alsa_output.platform-sound.HiFi__Speaker__sink` 做 `update-props = { node.virtual = true }`。pipewire-pulse 就不再给它 SINK_HARDWARE，PulseAudioQt 把它当虚拟设备，它不是默认 sink 时就永远不会入选（`preferreddevice.cpp:25`）。（已于 10-16 16:2x 作为 `61-y700-speaker-raw-virtual.conf` 装上，10-17 00:5x 验证，见 README 托盘音量一节）

- **验证**：
  - 开机后 `pactl list sinks` 里 raw sink 的 Flags 不再有 HARDWARE；
  - 放一声之后 5–8 s 内按音量键：`'change'` 仍落在联想调音上，没有"绕过保护"通知，也没有 `volume_put…=159`。

- **回滚**：删掉这个 conf，下次开机生效。不要手动重启 WirePlumber（README 记录过：UCM 会掉到 pro-audio）。
- **功耗**：(a) 省电（卡住不关的 PCM 被关掉）；(b) 0。
- **风险**：
  - (a) 低：按 SUSPEND.md 的设计，脚本坏了只是告警，WirePlumber 照常运行。
  - (b) 中：node.virtual 还会影响 pipewire-pulse 给流归属 client_id 的判断（`pulse-server.c:4091, 4175`）；Plasma 小程序也可能把 raw sink 当作虚拟设备隐藏起来（它本来就只用于调试）。这些副作用都没有核实。

### 6. 条件项：守护对一次性旁路先只移流、不降增益

- **前提**：时间线上 `volume_put…=159` 和爆音同时出现。
- **机制**：守护一发现旁路流就 `set_gain off`（21→159，约 −13 dB），下一轮再升回。`volume_put` 是不带斜坡的寄存器写（`aw882xx.c:757-786` → `aw882xx_device.c:665-680`），fade-flag 也管不到这条路径。
- **改动**：只是提案，没写代码。`check()` 里发现旁路时，本轮只 `move-sink-input`、不动增益；只有下一轮仍有旁路（流挪不走），或者保护节点、硬件 sink 确实缺失时，才 `set_gain off`。H5 是最可能产生旁路的路径，先做完第 1、5 项，通常就不需要这一项了。
- **验证**：重做 README:748 的测试（把一路静音流移到 raw）：0.4 s 内被挪回，并且日志里没有 159/21 这一对。
- **回滚**：恢复原脚本。改之前照 `/root/y700-speaker-guard.bak-20261015` 的做法先备份。
- **功耗**：0。
- **风险**：中。旁路流会以 21 档多放约 0.3–2 s，削弱了一层保护，需要作者拍板。

### 7. 条件项：残余的 H1——只在亮屏时让三级 sink 一起不挂起

- **前提**：做完第 1、3 项后，仍在"扬声器静默 ≥5 s 后的第一下点击 / 第一声"时听到爆音，并且第 0 步的 A/B 证实链路跑着时就不响。
- **机制**：PCM 开/关让两颗功放 PWDN/AMPPD 上下电（`aw882xx_device.c:1326-1416` 开、`:1418-1458` 关）。数字台阶在正常开流时不成立，剩下的只可能是模拟瞬态，驱动侧修不了。
- **改动**：只有设计，没写代码。
  - 亮屏时，effect_input.y700_lenovo、effect_input.speakers、raw 三级 sink **一起**不挂起；熄屏后立即照原样挂起。**只改 raw sink 会触发 H5。**
  - 屏幕状态复用 `power/y700-screen-off-freeze` 已有的 2 s DRM dpms 轮询，在亮灭变化时写 `pw-metadata 0 y700.screen on|off`，不新增任何轮询。
  - WirePlumber 侧必须 fail-safe：读不到元数据时一律按原生 5 s；熄屏时主动对仍处于 idle 的三级 sink 发 Suspend，并带上 y700-speaker-suspend 的 -EBUSY 重试。
  - 不能用"禁用原生 suspend-node 钩子、换成自己的脚本"这种写法：脚本一坏就谁都不挂起，熄屏功耗会被吃满。
- **验证**：
  - 装之前先按 SUSPEND.md §6.4 的静音 A/B 实测"亮屏一直开着"到底多少 W，再决定装不装；
  - 装之后：亮屏放一声，60 s 内 PCM 一直 RUNNING，三级 sink 状态一致；音量键的 `'change'` 仍落在联想调音；
  - 熄屏后 5 s 加上重试时间内，PCM 变为 closed；熄屏期间来一声通知，5 s 后照常 closed；
  - 熄屏跑 `y700-audio-watch` 30 分钟，没有 STUCK。
- **回滚**：删掉 WirePlumber 片段和脚本，撤掉写元数据的那几行，下次开机生效。
- **功耗**：亮屏时估计 +0.03–0.15 W（SUSPEND.md §2.3 的推算，未实测），约占 2.6 W 亮屏底线的 1–6 %；熄屏不增加。如果熄屏挂起失败，代价会蔓延到熄屏，所以必须带重试和熄屏核查。
- **风险**：中高。新的 Lua 脚本从没跑过，涉及多个组件；而且只有 H1 被证实时它才有收益。

### 8. 条件项：内核侧，xrun 时的爆音（下次内核构建，y11 起）

- **前提**：爆音时刻的内核日志里有 `mute state=0` 加 `already start`，前面没有新的 `start success` 序列。高负载的旋转或弹键盘时最容易出现。
- **机制**：
  - PipeWire 把 stop_threshold 留成默认值，内核 XRUN 时自己 `snd_pcm_stop`；
  - 随后 `alsa_recover` 依次 drop、prepare、start（`alsa-pcm.c:2782-2860`）；
  - 后端在 prepare 时会停掉已经 start 的图，也就掐掉了 MI2S 时钟（`q6apm-lpass-dais.c:236-239`）；
  - 而 STOP 时 ASoC 只在设了 `mute_unmute_on_trigger` 才静音（`soc-dai.c:819-829`），所以现在功放是在满增益、未静音的状态下丢时钟；
  - 前端图也会被重启（`q6apm-dai.c:241`）。
- **改动**：
  - `pops/aw882xx-mute-on-trigger.DRAFT.patch`：在 `aw882xx_dai_ops` 里加 `.mute_unmute_on_trigger = 1`。DPCM 链路是 nonatomic 的（`qcom common.c:310-315`），所以 `aw882xx_mute()` 可以在 trigger 里睡眠。
  - `pops/1050-…-fade-flag.DRAFT.patch` 可以顺带打上：它只处理"在非零信号上翻转 HMUTE"的边角情况，对 H1 和 xrun 都没用，每次关流多约 28 ms。
  - 两个补丁都只做过 `git apply --check`。
- **验证**：
  - 开机日志 `grep -c 'pll&clk check fail'` 接近 0；
  - 正常放一声，仍然是两行 `start success`；
  - 人为制造一次 xrun（例如 `chrt -f 99` 跑一个 2 s 的忙循环），应看到 `mute state=1 → device_stop: done → mute state=0 → start success`，而不是 `already start`；耳听，咔哒声变成约 20–30 ms 的静默；
  - fade-flag：`journalctl -k | grep 'fade-flag: 1'` 应有两行。
- **回滚**：用 `tb323fu-ctl kernel` 的 trial/rollback 回到 y10。
- **功耗**：0。
- **风险**：中。要重编内核；另外有 §1.2 第 8 条的代价：内核检测到 XRUN 时，`mute(1)` 会在 GPR 的 apr_rxwq 工作队列里阻塞约 40–66 ms。

---

## 3. 交给时间线的问题

1. 每次爆音前后，PCM 是什么状态？从 closed 变 RUNNING，还是一直 RUNNING？
2. 爆音时刻对应的内核行：`start success` / `device_stop: done`（H1）、`already start` 且前面没有新的 start 序列（xrun）、`volume_put…=159`（守护）。只有 `playback enter`、没有 `start success` 的，是格式枚举，不算上电。
3. 按住音量键时，`'change' on sink #` 的 N 是联想调音、`effect_input.speakers` 还是 raw？每一步有没有新的 sink-input？它挂在哪个 Sink 上？有没有"绕过扬声器保护"的通知？
4. 三个场景发生时有没有视频或音乐在放？`pw-top` 的 QUANT 在弹出 / 收起键盘时有没有在 1024↔256 之间跳？ERR 有没有加一？
5. 旋转那一刻有没有任何音频事件：新流、PCM 状态变化、门控日志里的 SHOW 或 KWin-initiated？如果 PCM 全程 closed、也没有任何流事件，那这一声就不是经扬声器 PCM 出来的。
6. 有没有出现过"raw sink IDLE、联想调音 SUSPENDED"（STUCK）？持续多久？
7. 平板上 `plasmaparc` 的 AudioFeedback 实际是什么值？声音主题是什么？按键重复的速率是多少？
8. y700-osk 和 y700-lenovo-tuning 的数据线程拿到 RT 调度没有？（`ps -L -o tid,cls,rtprio,comm`）
9. 链路已经被静音流跑着的时候，弹键盘还响不响？（这是 H1 是否成立的决定性 A/B。）
10. 打了 #3 之后，冷链路上第一下点击的延迟是多少？完整吗？

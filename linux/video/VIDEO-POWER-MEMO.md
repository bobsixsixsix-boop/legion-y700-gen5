<!-- 2026-10-16 一次 AI 辅助调研（4 条调研线 + 独立复核 + 汇总）的汇总稿，原样保存；写于 y12 安装前、门槛 80 落地后。之后的实测以 README "视频播放功耗" 一节为准。 -->

> **过时标记（10-19 加，X28）**：10-18 起：Chrome syncobj 等待加频风暴已证实（README「视频播放功耗」结论 6/7），`y700-no-waitboost.so` 已经 `/etc/ld.so.preload` 全局装上、只对进程名 chrome 生效、不碰 KWin——§0"加频已排除"和 §3 O7"不建议垫片"只对 KWin + wiliwili/mpv 路径成立；2.17 W 是 10-16 y10 门槛 50 的旧基线（tune2：y10 1.87–2.04、y12 1.62–1.66 W，README「视频播放功耗」tune2 条）；本文所有 README.md:行号 按 10-16 版本写，已失效，按节名"视频播放功耗""内核 y12""续航速查"查。

# wiliwili 视频播放功耗决策备忘（2026-10-16 晚）

依据有两部分。一是四条调研线和各自的复核结论（复核驳倒或无法核实的内容已删掉或降级）。二是本仓根目录 `README.md` 里"视频播放功耗"一节的平板实测（README.md:658-713）。实测与调研推断冲突时，以实测为准。

## 0. 先更正任务里的几条前提

- **"GPU 1200 MHz 22 %"作废。** 这个数来自 `trans_stat`，它把 GPU 挂起期间的时间记在挂起前的频点上，所以不可信。同一窗口里 `trans_stat` 记 89 % 在 1200 MHz，而每秒读一次 `cur_freq` 的均值只有 321 MHz（README.md:661；空闲时 msm 只暂存目标频率，见 msm_gpu_devfreq.c:40-44）。以后只用每秒 `cur_freq` 采样。按这个口径，门槛 50 时有 12–20 % 的秒在 1200 MHz（README.md:704）。
- **fence 截止时间加频已被实测排除。** 17:41 跑了 20 s 的 kprobe 跟踪：KWin 设截止时间 1199 次（60/s），msm 截止前 3 ms 的定时器触发 951 次，`msm_devfreq_boost` 被调用 **0** 次。60 次跳到 1200 MHz 全部紧跟调频器采样（README.md:681-691）。源码里这个机制确实存在（msm_fence.c:132-165），只是定时器触发时 KWin 的 fence 都已经完成了。任务里提到的"30 ms PM-QoS 超时"在 6.8–7.3-rc4 和 linux-next 里都不存在；加频的保持时间是 polling_ms，即 50 ms。
- **"DDR 547 MHz 100 %"不能说明带宽低。** 那个 devfreq 只是 CPU memlat 投票的读回（补丁 0126、1042）。GPU 的每个 OPP 由 GMU 直接向 RPMh 投 DDR 峰值带宽：1200 MHz 投 20.8 GB/s，726 MHz 投 8.17 GB/s，282–382 MHz 投 5.29 GB/s（平板 DTS 补丁 0003:64-203 已核对一致）。kaanapali 上 rpmh-stats 没接（README.md:362），所以实际 DDR 频率看不到。
- **门槛已经改了。** upthreshold 18:08 起已落地为 80/10（`linux/power/gpu-dvfs/`，`y700-gpu-dvfs.service`）。真实看 wiliwili 时做了三对 ABAB：2.85 W 降到 2.70 W，每个窗口 KWin 都是 60.0 次/s 合成（README.md:700-708）。所以**下面所有新 A/B 的基线是门槛 80**，不是默认的 50。
- **任务说"正在跑"的 726 MHz 上限 A/B 已经有结果。** 第一轮（17:07–17:16）作废，因为视频开测 18 s 后就暂停了。第二轮是受控的 mpv 测试（门槛 50，背光固定 99，无声）：726 上限省 0.13–0.2 W，8 个窗口 0 掉帧（README.md:662-671）。这是门槛 50 下的数。
- **y12 内核已编好，未安装。** 它是 y10 加上游 A8xx GMU 投票修复 1046–1048（README.md:596-608）。

## 1. 结论

按证据强弱排：
1. **最确定的大头是屏幕本身。** 背光从最低到最高差约 3.4 W（10-14 实测：1 %/10 %/50 %/100 % 分别为 1.13/1.38/2.75/4.50 W，README.md:1068）。按这张表推，背光 ~700 比最低档多约 0.45–0.5 W。静止桌面在最低背光、多数时间 30 Hz 时整机也要约 1.13 W。
2. **其次是播放本身的增量，约 1 W 量级。** 本地片、无声、背光 99 的 mpv 约 2.17 W，比静止桌面多约 1 W。这是跨天、跨配置的粗算，只能看量级。这约 1 W 包括：Iris 解码、mpv 渲染、KWin 每秒 60 次整屏旋转合成、面板从 30 Hz 回到 60 Hz、CPU、DDR。
3. **wiliwili 比 mpv 再多约 0.3 W**（折算到同背光，README.md:673）。其中有扬声器、Wi‑Fi 拉流、界面和弹幕重画，目前拆不开。
4. **播放增量里唯一已拆出并实测的是 GPU 调频策略。** simple_ondemand 门槛 50 让 GPU 在 20 s 里有 60 次从三四百 MHz 直接跳到 1200 MHz，每次还顺带投 20.8 GB/s 的 DDR 票。实测代价 0.13–0.2 W，门槛 80 已收回约 0.15 W。
5. **源码已证实、但电量没测的是"合成次数翻倍"。** 视频只有 30 帧，可 wiliwili 每个 vblank 都整窗重画并提交（borealis application.cpp:168-237）。KWin 实测每秒 60 次整屏合成。横屏下 DPU 平面不支持 90° 旋转，所以不可能直接送屏。这是剩下最大的可动杠杆，但具体能省多少瓦，要等 30 Hz 模式的 A/B。
6. **A840 在每个带宽档都投 ACV 的 DDR 性能模式**（内核缺陷，平板源码 a6xx_gmu.c:1672-1675 已核实，y12 修）。代价未知。
7. **零拷贝路径、解码输出格式、AR30、CPU 都已接近可忽略。** 两个 CPU 簇 95–99 % 时间在最低频，wiliwili 只占 14.8 % 单核。UBWC 解码输出最多省 10–20 mW 量级。

**粗分账（推算，不是测量；门槛 80、背光约 676、正在播放）：**

| 块 | 量级 | 依据 |
|---|---|---|
| 静止桌面底（亮屏、多数 30 Hz、平台） | ≈1.13 W | README.md:1068（10-14） |
| 背光 676 相对最低档 | ≈0.45–0.5 W | 同上，约 0.78 mW/级 |
| 播放增量（mpv 口径，已扣掉门槛 80 收回的约 0.15 W） | ≈0.85 W | 2.17 W − 1.13 W − 门槛收益；跨天粗算 |
| wiliwili 额外（扬声器、Wi‑Fi、UI/弹幕） | ≈0.3 W | README.md:673 |
| 合计 | ≈2.7 W | 对得上实测 2.70 W |

## 2. 改进选项

### 2.0 通用测法（下面每项的"怎么测"默认都按这套）

- **怎么跑：** 在平板上用 `systemd-run` 起脚本，测量窗口内不 ssh（每次登录会起停 root 的 systemd 用户管理器，污染功耗）。可复用的脚本：`linux/video/video-gpu-tune-live.sh`（只切内核参数、作者照常看）、`video-mpv-ab.sh`（受控测试片）、`video-gpu-ab-analyze.sh`（按背光折算）。
- **每秒采：** 电池 `power_now`、背光 `brightness`、GPU `cur_freq`。
- **每窗采：**
  - KWin 合成次数/s：kprobe `p:msmdl msm_fence_set_deadline` 的命中数。这是 KWin 源码里唯一的 SET_DEADLINE 调用点，每次合成调用一次。
  - mpv 掉帧：mpv 日志，或 wiliwili 的 VideoProfile 浮层（decoder/output drops）。全屏下"显示 FPS"看不到。
  - wiliwili CPU、扬声器状态、温控状态（补丁 0108 在 quiet-therm ≥44 °C 时另外限 GPU）。
- **对照：** ABAB 至少 3 对，每窗 90–150 s。受控测试用同一段本地测试片循环；wiliwili 实测时同一个视频从头放，音量和弹幕设置不变。
- **背光：** 受控测试暂停自动亮度，sysfs 固定在 99。作者在看时不碰亮度，只记每秒背光，事后按 0.78 mW/级折算。
- **怎么判读：** 实测时同一条件三个窗口之间能差 0.3 W（2.99 / 2.69 W）。小于 0.1 W 的效果只信受控测试或更多对数。

### 2.1 排序总表

排序规则：先看预期省电，有实测的排在有机制估算的前面，再往后是收益未知的；同档里风险低、工作量小的排前面。

| # | 选项 | 预期省电（量级/依据） | 风险 | 工作量 | 15 min 能 A/B |
|---|---|---|---|---|---|
| 0 | 门槛 80/10（已落地，保留） | 实测 ≈0.15 W | 低；游戏可能停在偏低频 | 已完成 | 已测 |
| D | 诊断包（先做） | 0，用来判断 2/7/8/9 值不值得做 | 无 | 15 min | — |
| 1 | 全屏放 30 fps 视频时 KWin 切 30 Hz 模式 | 未测，预计本表最大：面板刷新、KWin 合成、UI 三样都减半。上界参考：静止画面 120→30 Hz 省 0.5 W | 中：延迟和音画偏移、弹幕 30 帧、30/60 Hz 下完整 modeset 会闪 | 测几分钟；自动化约 1 h | 能 |
| 2 | wiliwili 按视频帧率出图（a "跟随视频帧数" profile；b 限 30 帧） | 未测；GPU 侧估计少约 1/3 像素工作；调研粗估 0.1–0.3 W（低置信）；面板不降频 | a 低–中（触控延迟 ≤1 帧）；b 中（抖动，全局 30 帧） | 零代码 | 能 |
| 3 | y12 内核（A8xx GMU 投票修复） | 未知（低于 826 MHz 不再投 ACV 性能模式，视频几乎全程在这个区间） | 低–中：投票表错会导致 GMU 起不来；trial 启动可回滚 | 已编好；安装加验证约 30 min | 不能（要跨重启） |
| 4 | GPU 上限 726 叠加在门槛 80 上 | 门槛 50 下实测 0.13–0.2 W；叠加 80 后增量预计小，未测 | 视频低；游戏丢峰值性能 | 无 | 能 |
| 5 | 暂停和闲置时降帧（改 JSON） | 只在暂停/闲置时有效；暂停画面比同背光静止桌面高约 0.4–0.7 W（粗算），能收回其中 GPU 和合成那部分 | 低–中：唤醒后首帧丢动画 | 几分钟 | 能 |
| 7 | 按需重画补丁（borealis + wiliwili） | 无弹幕播放时约等于 2a；暂停时接近零帧 | 中 | 0.5–1 天 | 编好后能 |
| 8 | mpv FBO 缩到视频分辨率 | 估 30–100 mW（低置信） | 中（边界情况多） | 30–60 行 | 编好后能 |
| 9 | 预旋转缓冲，实现直接送屏 | 省掉 KWin 每帧的整屏合成；上限可以先测 | 高 | 数天 | 只能测上限 |

### 2.2 逐项说明

**0　门槛 80/10（已落地，保留）**
- 机制：50 ms 窗口忙于 80 % 以上才跳到最高频；70–80 % 之间保持当前频率；低于 70 % 时按目标负载 75 % 选频（governor_simpleondemand.c:56-81）。debugfs 里的值每次采样都实时读取（devfreq.c:835）。
- 收益：实测 2.85 → 2.70 W，GPU 几乎一直在 160 MHz，KWin 每窗 60.0 次/s，没有掉进"错过 vblank、退到 30/s"的陷阱（README.md:700-707）。
- 风险：GPU 吃紧的游戏可能停在偏低频点，这正是上游选 50 的原因（msm_gpu_devfreq.c:149-154）。兜底是切到"性能"档，下限锁在 461 MHz。
- 回滚：当场 `echo 50 > /sys/kernel/debug/dri/1/devfreq/upthreshold`；永久 `systemctl disable y700-gpu-dvfs`。
- 待办：README.md:711 ① 的 50/80/65 交替测试（每窗同时数合成次数和掉帧）；跑一个游戏确认没变卡。

**D　诊断包（全部只读，不放在功耗窗口里跑）**
1. 读现成的 `~/.cache/wiliwili-mpv.log`：
   - grep `Enabling dumb mode`：出现说明 profile=fast 生效，mpv 只走一个 pass。
   - grep `Using EGL dmabuf interop via`：后面是 GL_OES_EGL_image 说明是 GLES 构建，是 GL_EXT_EGL_image_storage 说明是桌面 GL 构建（桌面 GL 每帧建删纹理，但只是 CPU 侧的小开销）。
2. `grep player_low_quality ~/.config/wiliwili/wiliwili_config.json`，没有这个键就是 true。如果是 false，mpv 会用 lanczos + sigmoid + dither 并关掉 dumb mode。这本身就是一个值得 A/B 的项（未测），在设置里打开即可，mpv 会立即重启。
3. 播放 60 s，前后各读一次 wiliwili 和 kwin_wayland 的 `/proc/<pid>/fdinfo/*` 里的 `drm-engine-gpu` 和 `drm-cycles-gpu`（msm_gpu.c:152-157）。这是"KWin 合成占多少 GPU"唯一的直接数据，决定 7 和 9 值不值得做。
4. `grep -n -A1 colorPowerTradeoff ~/.config/kwinoutputconfig.json`：缺省就是 PreferEfficiency，预期没有影子 pass。夜灯开着时用 `modetest -M msm -p` 看 CRTC 的 CTM blob 是否非零。
5. 用 `IRIS_VAAPI_DEBUG=1` 启动 wiliwili（需要作者会话的 WAYLAND_DISPLAY 和 XDG_RUNTIME_DIR），放 60 s：
   - 不应出现 `surface copy selected mode`。拷贝器是懒创建的，这行不出现就说明从没拷贝过。
   - `persistent GEM export` 只应在启动探测时出现几次。
6. 在 `/sys/kernel/debug/dri/1/state` 里看 plane-0 fb 的 `modifier=`：确认 KWin 的 AR30 缓冲是 UBWC（0x0500000000000001）还是线性。只读这一个文件，别碰 dpu/*、dsi* 寄存器转储（见 power/cx-collapse/PROTOCOL.md）。
7. 查 README.md:711 ③：单独测 mpv 时每秒 60 次提交是谁发的，以及当时 wiliwili 是不是在后台开着。wiliwili 只有最小化才停循环（glfw_platform.cpp:203-206）。这决定 2.17 W 这个 mpv 基线干不干净。

**1　KWin 30 Hz 模式（全屏放 30 fps 视频时）**
- 机制：KWin 的渲染循环和帧回调跟着模式刷新率走。wiliwili 的 swap interval 是 1，被帧回调节流，于是每秒提交 30 次，KWin 合成 30 次/s，DPU 扫描和 DSI 刷新都减半。
- 本内核下切换应该不黑屏：60↔30 是只改垂直前沿（VFP）的原地切换（补丁 0065/0066：同像素时钟，vtotal 6800/13600）。0110 记录过有人看 30 Hz 时序没有闪烁。和 idle_refresh 也不冲突（基准 vtotal 变成 13600，min_hz 是 30）。
- 收益依据：静止画面固定 120 Hz 比自动降到 30 Hz 多 0.5 W（背光最大，README.md:1069-1072）。这是"只有面板刷新"的上界，60→30 应该比它小。再加上 KWin 和 UI 每秒少 30 次整屏 pass（调研估算约 1/3 的 GPU 像素工作）。预计百 mW 级，未测。
- 风险：
  - 延迟和音画偏移（推算，未测）：KWin 的安全余量是 vblankTime + 1 ms（drm_commit_thread.cpp:364-371），vblankTime 按 (vtotal−vdisplay)×htotal/clock 算（drm_connector.cpp:72-75）。按 0066 的时序，60 Hz 时约 9.2 ms，30 Hz 时约 25.9 ms，也就是合成要在翻页前约 28 ms 加渲染时间就开始。这大约多出一帧延迟和音画偏移，而 libmpv 拿不到呈现反馈来补偿。
  - 弹幕和触控都变成 30 Hz；60 fps 的片源会丢一半帧。
  - 0065 写明：在 30/60 Hz 下做一次完整 modeset（DPMS 亮屏、开机后第一次 CTM）会让 CSOT 面板闪。所以自动化脚本要在熄屏和锁屏之前切回 120 Hz。
  - README.md:711 写着"切换会黑一下"，和 0065/0066 的说法对不上，要现场看一次。
  - KScreen 会把模式写进 kwinoutputconfig.json，测完必须显式切回。
- 回滚：`kscreen-doctor output.DSI-1.mode.1904x3040@60`，或用原来的模式 id。
- 15 min A/B：能。
  - 先用 `kscreen-doctor -o` 记下 30 Hz 和 60 Hz 的模式 id。
  - 同一视频全屏，60/30 交替，每窗 120 s，做 3 对。
  - 指标：W、合成次数/s（应为 60 和 30）、`/sys/module/msm/parameters/idle_refresh_state`、cur_freq、掉帧，再主观看音画同步。
  - 测完单独在 30 Hz 下做一次熄屏/亮屏，看闪不闪（不计入功耗窗口）。
  - 这会改正在播放的屏幕，只在没人用平板时做。
- 工作量：手动几分钟。做成"wiliwili 全屏播放时切 30 Hz，退出、暂停、熄屏前切回"的自动化约 1 h（控制中心已经在调 kscreen-doctor，Main.qml:273）。

**2　wiliwili 按视频帧率出图（零代码）**
- **2a "跟随视频帧数" profile。** wiki 里有个示例 profile，执行的是 `set video-timing-offset 0.05`（wiki Home.md:256-258）。文件放在 `~/.config/wiliwili/pack.json`（shader_helper.cpp:147），在播放器齿轮菜单里选。用之前先看看示例里除了这条还设了别的什么。
  - 机制：offset 大于 0 时，`mpv_render_context_render` 会阻塞到每一帧的目标时间（render.h:694-696，vo.c:846-850）。于是 UI 循环大约每个视频帧跑一次，vsync 照旧，KWin 合成降到约 30 次/s，面板仍是 60 Hz。顺带还消掉现在"新视频帧要晚一个 UI pass 才上屏"的延迟。运行时 `set` 就会生效（vo.c:228-242）。
  - 这条只是复核从源码推出来的，平板上没验证过。
  - 风险：UI 线程每帧最多阻塞 50 ms，触控延迟最多多一帧；OSD 和弹幕跟着视频帧率走；暂停时回到 60 Hz，不省电。
- **2b 限 30 帧。** 在设置里把帧率限制选 30，立即生效并保存（setting_activity.cpp:351-356）。实现是 swapInterval 设 0 再加 sleep（application.cpp:226-234），和 vblank、mpv 时钟都不同步，会出现一帧保持 1 个或 3 个 vblank 的抖动，而且全局 UI 都变 30 帧。只适合做测量代理，或者 2a 不行时的退路。
- 收益：GPU 侧和第 1 项一样，没有面板那部分。拿第 1 项的结果减第 2 项，大约就是"面板和扫描从 60 降到 30"的价值。
- 回滚：2a 选回默认 profile 或删掉 pack.json；2b 选回"垂直同步"（LIMITED_FPS=0，即时生效）。
- 15 min A/B：能。同一视频、关弹幕，"默认 / 2a"交替，每窗 120 s。指标是合成次数/s（期望约 30）、W、cur_freq、VideoProfile 浮层里的掉帧，再主观看抖动和触控延迟。

**3　y12 内核**
- 机制：
  - 1046（`db6a2e4a7ebd`）只在带宽 ≥ perfmode_bw（10.69 GB/s，对应 826 MHz 及以上）时才投 ACV 性能模式。
  - 1048 改成按 GPU 的 OPP 表重建依赖票，高频档会抬高 MX 票，可能略增功耗；但门槛 80 下 GPU 很少到高档。
  - 1047 在这台机器上实际不改投票（README.md:603 已核）。
- 收益：未知，ACV 和 DDR 功耗没有任何公开数据，只能实测。
- 风险：投票表算错会让 GMU 起不来、没有桌面。README.md:603 已核过 cmd-db 的 MX 档能覆盖所有 GPU 档。
- 回滚：trial 方式启动；出问题用 `tb323fu-ctl kernel rollback` 回 y10。
- 测法：15 分钟内做不完。按 README.md:608 安装后，跑 `y12-verify.sh`，用 vkcube 和 mpv 压一压，看 dmesg 里的 GMU/hfi 报错、"not found in the RPMh list"、fenced write 次数。之后在同一测试片、背光 99、门槛 80 下和 y10 对比：y10 和 y12 各测一遍，再换回去各测一遍，抵消跨重启的噪声。要在作者不用时做；重启会清掉 00:30 的临时夜间定时器。

**4　726 上限叠加门槛 80**
- 机制：sysfs 的 max_freq 是一个 DEV_PM_QOS_MAX 请求，同时压住调频器的"跳到最高"和所有加频（devfreq.c:145-155），GMU 的 DDR 票也就不超过 8.17 GB/s。
- 收益：门槛 50 下实测 0.13–0.2 W。门槛 80 下 GPU 几乎都在 160 MHz，只有约 2 % 的秒到 1200（README.md:697、705），叠加的增量预计小。**不要沿用 0.13–0.2 W 这个数。**
- 风险：视频没问题（0 掉帧）；游戏会丢峰值性能；长测时温控可能介入，要一起记录。
- 回滚：`tb323fu-ctl gpu profile balanced`。
- 15 min：能。受控 mpv 条件、门槛 80，balanced 和 power-saver 做 ABAB×3。如果增量小于窗间噪声，就不做"看视频时自动切省电档"。

**5　暂停和闲置时降帧**
- 机制：在 wiliwili **关着**的时候，往 `wiliwili_config.json` 的 setting 里加 `"deactivated_time": 2000, "deactivated_fps": 1`。fps 必须 ≥1：设 0 会让 glfwWaitEventsTimeout 收到无穷大并拒绝，循环就忙等（window.c:1167-1178）。播放时 wiliwili 自己会关掉降帧（mpv_core.cpp:1347-1353），所以这只影响暂停和闲置页面，也覆盖"wiliwili 开着放在后台"的情况。
- 收益：暂停画面 @626 实测约 2.0–2.3 W（README.md:661，作废那一轮的副产品），同背光的静止桌面推算约 1.6 W。降帧能收回其中的 GPU 和合成部分。但每秒 1–2 次提交时面板最多只能降到 60 Hz（idle_refresh_ms30=2000），要真正到 30 Hz 需要零提交，那是第 7 项的事。
- 风险：上游 #120 里 wiliwili 作者承认过唤醒问题（首帧丢动画、跑马灯卡顿）；闲置时加载的封面最多晚 1 s 出现。
- 回滚：wiliwili 关着时删掉这两个键。它退出时会重写配置，所以不能在运行时改。
- 15 min：能。暂停视频 2 min、首页闲置 2 min，有无这两个键各测一次，记 W、cur_freq、idle_refresh_state、合成次数/s。

**7　按需重画补丁（约 80–120 行，0.5–1 天）**
- 机制：
  - borealis 加 `requestRedraw()`（原子标志加 `glfwPostEmptyEvent` 唤醒）；一轮循环里没有输入、没有重画请求、也没有正在跑的 Animatable 时，跳过 `frame()`。
  - wiliwili 在 mpv 的 on_update 里请求重画；`draw()` 里先渲染待处理的 mpv 帧再贴图；OSD、提示、弹幕可见时每帧都请求重画。
- 收益：无弹幕播放时约等于 2a；暂停时零帧，面板能降到 30 Hz；有弹幕时不省，除非接受弹幕 30 Hz 的台阶。
- 风险（复核补充）：
  - GLFW fork 892256c3 的 `_glfwPostEmptyEventWayland`（wl_window.c:3250-3254）每调用一次就泄漏一个 wl_callback，必须先回移上游的 noopCallbackListener/destroy 修复。
  - `VideoView::draw` 里不只是画图，还有长按状态机、OSD 回调、clearHint 这些逻辑。
  - mpv 事件走 on_wakeup → brls::sync，也要能唤醒循环，否则最多晚 100 ms。
  - 漏一次唤醒，vo_libmpv 的 flip_page 等 200 ms 超时就会丢帧（vo_libmpv.c:504-556）。
  - 又多一个每次升级都要重打的本地补丁。
- 回滚：JSON 开关关掉，或换回旧二进制。
- 前提：第 1、2 项测出合成减半确实值钱，并且 2a 的副作用（触控延迟、暂停不省）不可接受，再做这个。

**8　mpv FBO 缩到视频分辨率**
- 机制：在 setFrameSize（mpv_core.cpp:742-781）里把 FBO 宽度限到视频宽度（1080p 全屏时约 1920x1203，而不是 3040x1904），交给已有的 GL_LINEAR 四边形放大。只在 LOW_QUALITY 开着时这么做。
- 收益：估 30–100 mW，低置信。省电主要来自 GPU 忙的时间变少、跳频变少，而门槛 80 之后这部分已经不多。
- 风险：宽高比覆盖、旋转、镜像、边距、弹幕遮罩对齐；视频分辨率变化时要监听 video-params 重新计算尺寸。
- 测法：编好后能做，主指标是 wiliwili 进程的 drm-cycles。放在第 7 项之后。

**9　预旋转缓冲，实现直接送屏（长期）**
- 机制：客户端渲染竖屏缓冲，并调用 set_buffer_transform 匹配输出变换，这样 offloadTransform 变成 Normal（compositor.cpp:414），KWin 就能把 wiliwili 的缓冲直接放到 plane-0 上，省掉自己的整屏合成。
- 先测上限（15 min 能做）：锁成竖屏放同一个视频，看 `/sys/kernel/debug/dri/1/state` 里 plane-0 fb 的**格式**。AR30 说明是 KWin 在合成；8-bit（AR24/XR24）说明是直接送屏。不要看 "allocated by"，两种情况下那一栏都是 kwin_wayland，因为 ADDFB2 是 KWin 做的（drm_framebuffer.c:886）。再比较 W 和 cur_freq。竖屏下视频区域更小，mpv 的工作量会略有不同。
- 实现风险：
  - GLFW fork 只绑定 wl_compositor v3（wl_init.c:123-127），收不到 v6 才有的 preferred_buffer_transform。
  - KWin 按预乘 alpha 混合（drm_pipeline.cpp:265-266），帧缓冲里 alpha 小于 1 的地方直接送屏后会变暗。
  - 任何 OSD、通知、光标或特效出现都会退回合成。
  - DPU 的 test commit 仍可能拒绝这个缓冲。

### 2.3 建议顺序

1. **有人拔电播放时**：只做使用者察觉不到的事。D 里的只读项可以做（读日志、读 fdinfo）；第 4 项可以用 live 方式只切 max_freq。都用 systemd-run 起，测量期间不 ssh。
2. **可以打断播放时**：做第 1 项（30 Hz）和第 2a 项，同时亲眼验收闪烁、延迟和抖动。
3. **平板空闲时**：y12 trial；第 5 项。
4. **看数据再决定** 7、8、9 要不要做。

## 3. 不建议做

- **msm 截止时间加频开关补丁（O5），以及给 KWin 的 LD_PRELOAD 去 deadline 垫片（O7）。** 实测 0 次加频。O7 还可能静默失效：Debian 打包给 kwin_wayland 加了 CAP_SYS_NICE 文件能力（26.04 没核），ld.so 会忽略带路径的 LD_PRELOAD。另外去掉加频，也就去掉了 KWin 错过提交点时唯一的兜底。（10-18 已被 Chrome 垫片取代，见 README「视频播放功耗」；本条只对 KWin + wiliwili/mpv 路径成立）
- **polling_interval 改成 100 ms。** 没有证据支持。这个值写的是 msm 共享的静态 profile，加频保持时间和空闲加频阈值会跟着一起变（devfreq.c:614-650、:832）。跳频问题门槛 80 已经解决了。
- **idle_clamp=Y。** 上游只给 a618/7c3 开，理由是"power supply issues"（a6xx_gpu.c:2762-2766）。它会让每帧在提交路径上同步多一次 HFI 往返（msm_gpu.c:815-822），而这颗 GMU 已经有 fenced write 延迟。它省电的前提（IFPC 期间 GMU 仍保持带宽票）也没核实。
- **门槛调到 80 以上，或随手改 downdifferential。** up 小于 down、或 up 大于 100 时，调频器每次采样都返回 -EINVAL，频率冻结。门槛越高离"错过 vblank"陷阱越近。80 已有实测，且没有掉进陷阱。
- **设置里的 1/2、1/3、1/4 垂直同步。** Mesa 的 Wayland EGL 把交换间隔上限锁在 1（platform_wayland.c:2334-2342），这几个选项无效，而且会误导人以为省了电。LIMITED_FPS 设 60/90/120 在 60 Hz 下也不省电，90 和 120 画出来的帧 KWin 根本不显示。
- **UBWC/QC08C 解码输出。** 最多省约 100 MB/s 的流量，不到 10–20 mW。freedreno 在 A840 上直接拒绝 R8 加 QCOM_COMPRESSED（has_8bpp_ubwc 没设），而 mpv 把 NV12 拆成 R8/GR88 两个平面导入，所以根本导不进去。还要改 libva-v4l2 和 mpv，工作量是数天。
- **`-DMPV_NO_FB` 构建。** wiliwili CI 只在 PS4 和 PS Vita 上用过。这种模式下 mpv 在 nanovg 的 nvgEndFrame 之前渲染，会盖掉之前排队的 UI；BLOCK_FOR_TARGET_TIME 在 UI 帧里阻塞，可能把 swap 推过 vblank。收益也没证实。
- **换 hwdec=v4l2m2m 或 drm-prime。** 这台机器上非 copy 的 v4l2m2m 缓冲映射不了（kernel-y2/video-accel/configs/mpv.conf:1-3），只能用 -copy，更差。
- **overlay 类路线。** dmabuf-wayland 和 drmprime-overlay 在 libmpv 的 render API 下用不了（render.h:468-470 只有 opengl 和 sw）。`KWIN_USE_OVERLAYS=1` 也没用：全屏项留给主平面，overlay 平面只做直接送屏，同样卡在 90° 旋转。
- **改 KWin 让主平面优先用 8-bit 格式。** AR30 和 AR24 都是 32 bpp，只有 D-6 查出 KWin 缓冲是线性 modifier 时才值得考虑。几个环境变量也不要用：`KWIN_DRM_PREFER_COLOR_DEPTH` 不改帧缓冲格式；`KWIN_DRM_USE_MODIFIERS=0` 会丢掉 UBWC；`KWIN_DRM_FORCE_GL_FINISH_PRESENT` 和 `KWIN_COMPOSE=Q` 只会更慢。
- **用 `idle_refresh policy=1 hz=30` 代替切 KWin 模式。** KWin 会继续按 60 Hz 计时，翻页被门控，排队延迟更大。
- **以下测量方法不要再用：**
  - `trans_stat`；
  - 每 5 ms cat 一次 min_freq 的轮询（每秒几百个进程，扰动 CPU）；
  - 用 debugfs state 里的 "allocated by" 判断是否直接送屏；
  - 用 `drm_vblank_event` 数合成次数（它数的是 vblank 中断，不管有没有提交）；
  - 全屏时看"显示 FPS"（全屏下不显示）；
  - 在测量窗口里 ssh。

## 4. 仍未解决的问题

1. **约 1 W 播放增量怎么拆：** 面板 60→30、KWin 合成、wiliwili UI、mpv、Iris 解码、扬声器、Wi‑Fi 拉流各占多少。第 1、2 项和 D-3 能拆出一部分；扬声器和 Wi‑Fi 拉流**没有任何一条调研线覆盖**。
2. **mpv 基线 2.17 W 干不干净：** 当时每秒 60 次提交是谁发的，wiliwili 是不是在后台开着。
3. **全屏视频时 KWin 实际用的是哪个模式：** 是 60 Hz 模式，还是 120 Hz 模式被内核 idle_refresh 拉到 60（状态行 "live 6800 hz 60"），以及是谁切的。`kscreen-doctor -o` 能回答。
4. **门槛 80 的副作用和后续：** 对游戏有没有影响；65 是不是更好的折中；726 上限叠加在 80 之上还剩多少收益。
5. **DDR 相关：** y12 和 ACV 性能模式的真实收益；GMU 在 IFPC 期间是否保持 DDR/ACV 票；实际的 DDR 聚合频率（rpmh-stats 没接，看不到）。
6. **2a profile 是否真的有效：** 在这套栈上是否真能把提交降到约 30/s 且不抖。目前只有源码推导。
7. **30 Hz 模式的现场表现：** KWin 约 26.9 ms 的余量带来多少实际延迟和音画偏移；切换时黑不黑屏（README.md:711 和 0065/0066 说法矛盾）；30 Hz 下熄屏再亮屏会不会闪。
8. **wiliwili 和 mpv 的实际配置：** player_low_quality 的实际值；dumb mode 是否生效；构建是 GLES 还是桌面 GL。
9. **缓冲细节：** KWin 的 AR30 缓冲和 wiliwili 的缓冲各用什么 modifier；在 1.9 分数缩放下 wiliwili 的缓冲是 1904 行还是 1903 行，不是 1:1 的话 KWin 要重采样。VideoProfile 浮层的 framebuffer 一行能回答。
10. **Kaanapali DPU 硬件能否做内联 90° 旋转：** 上游没暴露这个能力，下游 SDE catalog 没查。
11. **功耗模型的精度：** kaanapali 各 RPMh 档的电压、A840 各频点的功耗都没有公开数据，功耗模型只能做到 2 倍左右的精度。
12. **温控干扰：** 长时间 A/B 里，0108 的温控限频有没有介入。

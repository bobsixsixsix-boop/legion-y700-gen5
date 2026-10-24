# 安卓音频"断一下又恢复"（audioserver 自杀重启）分析

2026-10-12 作者反映：刷抖音时音频会崩一下然后自己恢复。查到今晚两次：00:13:43 和 01:13:10。

## 现场

- `tombstone_23/26`：`/vendor/bin/hw/audiohalservice.qti`（联想 vendor 的高通音频 HAL），signal 35（debuggerd 转储信号）——**不是 HAL 自己崩**，是 audioserver 的 TimeCheck 超时前把它转储了一份。
- `tombstone_24/27`：`/system/bin/audioserver`（OPPO system 的）SIGABRT，Abort message：`TimeCheck timeout for IAudioFlinger::createTrack scheduled 01:12:57`——createTrack 等线程锁等了 14 s。
- 持锁的线程：**`AudioOut_2D`**（播放线程），栈在 `EffectChain::process_l → EffectModule::process → EffectHalAidl::process → waitHalStatusFmq → EventFlag::wait`：等 HAL 里的**音效**处理完返回状态，永远没等到。
- HAL 那边对应的音效线程：`DAPV3`（Dolby Audio Processing）和两个 `Music Volume L[istener]`（Dolby 的音量监听音效），都停在 `EffectImpl::process → EventFlag::waitHelper`——在等数据/命令事件。
- 即：**audioflinger 等 HAL 回状态，HAL 音效线程等 audioflinger 发事件，两边互等**（AIDL 音效 FMQ 事件丢失/状态错位）。同时还有线程在 `createEffect`、`Track::start/pause`（抖音频繁建销音轨和音效），像是并发建销音效时触发的竞争。
- 之后 audioserver 自杀，init 把它和 audiohalservice 一起重启（两者 STIME 相同），声音恢复。

## 相关性

- `/data/tombstones` 里 10-11 01:24 起全部记录：装 `y700_dax`（恢复联想杜比 daxService，10-11 21:33–22:19）**之前没有任何音频崩溃**；之后两次都是。
- 两次都在刷抖音时；不是每次开机都发生（23:07、00:09 两次开机后没出）。
- 音效链里有 Dolby 的 `DAP`（ID 11）和 `Music Volume Listener`（ID 75），都是 daxService 挂上去的。

## 判断与选项

杜比音效（联想 vendor 的 Dolby 实现）+ OPPO 的 audioserver，在抖音高频建销音轨/音效时偶发 FMQ 握手死锁。属移植接缝（OPPO system 配联想 vendor 的音效 HAL），上游两家都不会修。
- 选项 A：禁用 `y700_dax`（`touch /data/adb/modules/y700_dax/disable`，重启）——没有杜比，但彻底消除。可先 A/B 一天确认。
- 选项 B：保留杜比，忍受偶发 15 s 断音自恢复。
- 选项 C（未验证）：只保留 DAP、不挂 Music Volume Listener——需要改 daxService 行为，暂无把握。

## 作者的决定（2026-10-12 01:27）：保留杜比，把恢复时间缩短

- `libmediautils.so` 的 TimeCheck 读系统属性 `audio.timecheck.timeout_duration_ms` / `audio.timecheck.second_chance_duration_ms`（原本都没设，这个 OPPO 构建默认合计约 14 s）。改为 AOSP 默认 5000 + 2000 ms，卡死后约 7 s 自杀重启，再加 1–2 s 重启，断音约 8–9 s。
- 做成 KernelSU 模块 **`ksu-y700-audio/`**（`y700_audio`）：`post-fs-data.sh` 用 `resetprop` 写这两个属性（audioserver 是 class core，`on boot` 才启动，post-fs-data 来得及）。01:28 已装入并当场 `setprop`，下次 audioserver 重启（含下一次卡死）即按新值；重启后由模块写入。
- 不改更短：蓝牙连接、通话模式切换等慢操作可能超过 3–4 s，会被误判成卡死而白白重启音频。vendor 侧 HAL 自己的 `vendor.audio_hal.timecheck_timeoutMS=8000` 不动。
- [ ] 下次再断音时核对：logcat 里 `TimeCheck timeout` 行到 audioserver 重启的间隔应 ≈7 s；用 16 MB 的日志缓冲抓崩溃前的 HAL/Dolby 日志，看能不能找到避免互等的办法（选项 C）。

## 其他

- logd 缓冲原来只有 256 KiB，崩溃进程的日志早被滚掉；已 `setprop persist.logd.size 16M` + `logcat -G 16M`，下次能抓到崩溃前的 HAL 日志。
- audioserver 每秒找 `vendor.oplus.hardware.performance.IPerformance`（联想 vendor 没有），SELinux 拒绝刷屏，无害。
- tombstone 文本（`tombstone_23/26/27.txt`）含厂商构建指纹和内存映射，不随公开仓库发布。

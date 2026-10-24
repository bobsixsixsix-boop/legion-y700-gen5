# Google Play 商店（2026-10-12 装）

- 现象：作者在设置里打开 Google 服务后没有 Play 商店。GMS（`com.google.android.gms` 26.11，apex）和 GSF 都在且启用；`com.android.vending` 只是国行固件的 **25 KB 空壳**（`/product/priv-app/GooglePlayServicesUpdater`，22.7.54，没有任何 Activity），只给 GMS 自更新用。国行 ColorOS 本来就这样，不是移植问题。
- 处理：从 APKMirror 下 `com.android.vending` **53.4.34-29**（通用 APK，Android 10+，nodpi，109,166,946 字节，sha256 见 `SHA256SUMS`），作为空壳的**更新**用 `adb install -r` 装上（装到 /data/app，系统分区不动）。
- 签名核对：空壳 v1 证书 SHA-1 `38918a453d07199354f8b19af05ec6562ced5788`（APKMirror 记作 "3891"），新包 v2/v3 签名块里同一张证书。选只带 "3891" 签名的变体（不带 "bd32" 轮换的），最稳。
- 回滚：`adb shell pm uninstall-system-updates com.android.vending`（回到空壳）。
- 以后 Play 商店会自己更新。空壳原件备份（`stub.apk`）和下载的 APK 不随仓库发布。
- APKMirror 页面直接抓取会 403；用浏览器打开变体页拿到 `download.php?id=…&key=…` 链接后，curl 带 UA 和 Referer 能直接下。

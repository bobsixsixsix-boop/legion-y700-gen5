# 参与

[English](#english)

欢迎提改动。这是个人项目，改动可能很久才有人看，也可能不会被合并；动手做大的改动之前，最好先开 issue 说一下。

## 签名（DCO）

每个提交都要带 `Signed-off-by:` 行，用 `git commit -s` 即可。签名表示你确认 [Developer Certificate of Origin 1.1](https://developercertificate.org/)：这份改动是你有权按本仓库的许可证提交的。签名里的名字和邮箱会公开，可以用 GitHub 提供的 noreply 邮箱。

## 改动的大小与范围

- 一个提交只做一件事，小而专注。不要把格式整理、重命名和功能改动混在一起。
- 改了脚本的行为，就同时更新它开头的注释或所在目录的文档。
- 文档以中文为主，英文同样欢迎。写清楚日期、数据的出处和测量条件；不确定的地方直接写「不确定」。

## 在真机上测试，并写清楚怎么测的

- 改动要在真实设备上测过。请在提交说明或 PR 里写明：设备型号、固件版本、内核 release、执行了哪些命令、看到了什么结果。
- 没法测的部分要明说没测，必要时在文件名或文件开头标 `DRAFT`。
- 会写分区、改启动、动内核参数或可能导致复位的改动，请写清楚出问题时怎么回退。

## 绝不能提交的内容

- 个人数据：真实的 IP、主机名、用户名、家目录路径、Wi‑Fi 名称和密码、位置信息、带个人信息的日志或截图。
- 设备标识：序列号、HWID、IMEI、MAC 与蓝牙地址、解锁数据。
- 专有文件：固件、厂商 APK 与配置文件、ROM 包、EDL loader 镜像、原厂分区镜像，以及从它们中提取或派生的内容。
- 密钥与认证材料：签名密钥、keystore、私钥、token、Apple MFi 认证材料。
- 二进制产物：内核 Image、模块、APK、压缩包等。

需要这类值的地方，请沿用仓库里已有的占位符，例如 `100.64.0.x`、`02:00:00:00:00:xx`、`example-tailnet.ts.net`、`user`。

## 许可证

- 你的贡献按 [REUSE.toml](REUSE.toml) 为对应路径规定的许可证发布；文件自带 SPDX 头的，以文件头为准。概要见 [README.md](README.md) 的「许可证」一节。
- 新文件可以在开头加上 `SPDX-FileCopyrightText` 和 `SPDX-License-Identifier` 两行。
- 引入第三方代码时，写明来源、原作者和原许可证，保留原有的版权与许可声明，并在 [NOTICE.md](NOTICE.md) 里登记。许可证必须和目标文件兼容。

## 内核补丁

- 用 `git format-patch` 的格式，带 `From:`、`Subject:` 和 `Signed-off-by:`。
- 外来的补丁保留原作者的 `From:` 和 `Signed-off-by:`；在本地查不到原作者时，加一行 `Originally from:` 写明出处。
- 在 [PATCHES.md](PATCHES.md) 里登记作者、来源和你做过的改动（例如变基）。
- 对所有使用这台设备的人都有用的修复，最好先报给上游 [tb323fu-linux](https://github.com/joonhoekim/tb323fu-linux)。

## 关于 AI 辅助

可以用 AI 工具写代码或文档，但提交的人要读懂、测过，并对内容负责；DCO 签名同样适用。

## English

Contributions are welcome. This is a personal project, so changes may wait a long time for review or may not be merged; for anything large, please open an issue first.

### Sign-off (DCO)

Every commit needs a `Signed-off-by:` line; use `git commit -s`. By signing off you certify the [Developer Certificate of Origin 1.1](https://developercertificate.org/): you have the right to submit the change under this repository's licenses. The name and email in the sign-off become public; a GitHub noreply address is fine.

### Size and scope

- One commit, one purpose: small and focused. Do not mix reformatting, renames and functional changes.
- If you change what a script does, update the comment at its top or the documentation in its directory in the same change.
- Documentation is mainly in Chinese; English is equally welcome. State dates, data sources and measurement conditions, and say so plainly when you are unsure.

### Test on real hardware and say how

- Test the change on a real device. In the commit message or pull request, state the device model, firmware version, kernel release, the commands you ran and what you observed.
- Say clearly which parts are untested, and mark them `DRAFT` in the file name or at the top of the file where it helps.
- For changes that write partitions, change booting, touch kernel parameters or may cause resets, explain how to roll back.

### Never include

- Personal data: real IP addresses, host names, user names, home directory paths, Wi‑Fi names and passwords, location information, logs or screenshots with personal details.
- Device identifiers: serial numbers, HWIDs, IMEIs, MAC and Bluetooth addresses, unlock data.
- Proprietary files: firmware, vendor APKs and configuration files, ROM packages, EDL loader images, stock partition images, and anything extracted from or derived from them.
- Keys and authentication material: signing keys, keystores, private keys, tokens, Apple MFi authentication material.
- Binaries: kernel Images, modules, APKs, archives and the like.

Where such a value is needed, reuse the placeholders already in the repository, such as `100.64.0.x`, `02:00:00:00:00:xx`, `example-tailnet.ts.net` and `user`.

### Licensing

- Your contribution is licensed under the license that [REUSE.toml](REUSE.toml) assigns to its path; a file's own SPDX header takes precedence. See the licensing section of [README.md](README.md) for an overview.
- New files may start with `SPDX-FileCopyrightText` and `SPDX-License-Identifier` lines.
- When you bring in third-party code, state its source, original authors and original license, keep its copyright and license notices, and add it to [NOTICE.md](NOTICE.md). The license must be compatible with the file it goes into.

### Kernel patches

- Use the `git format-patch` format with `From:`, `Subject:` and `Signed-off-by:`.
- Imported patches keep the original author's `From:` and `Signed-off-by:`; when the original author cannot be found locally, add an `Originally from:` line naming the source.
- Record the author, the source and what you changed (for example a rebase) in [PATCHES.md](PATCHES.md).
- Fixes that help everyone with this device are best reported to upstream [tb323fu-linux](https://github.com/joonhoekim/tb323fu-linux) first.

### AI assistance

You may use AI tools to write code or documentation, but whoever submits the change must understand it, test it and take responsibility for it; the DCO sign-off applies in the same way.

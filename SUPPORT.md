# 支持

[English](#english)

这是作者一个人的业余项目，**没有任何支持承诺**。

- issue 可能很久才有回复，也可能一直没有回复。没有回复不代表问题不存在，也不代表会被修。
- 不提供一对一的刷机、救砖或获取 ROM 的帮助。本仓库不提供也不链接任何 ROM 包、固件或 loader 镜像。
- 这里的东西只在作者自己的一台 TB323FU 上验证过。在别的设备或固件上出现问题，很可能无法复现。
- 内核、helper、安装和启动方面的问题，先看是不是上游 [tb323fu-linux](https://github.com/joonhoekim/tb323fu-linux) 的问题；如果是，请按上游的方式向上游反馈。不要把本仓库的改动引起的问题报到上游去。
- 安全问题不要开公开 issue，请按 [SECURITY.md](SECURITY.md) 私下报告。

## 提 issue 时

请写清楚：

- 设备型号、Android 固件版本、Linux 内核的 release 名（`uname -r`）；
- 用了哪个目录下的哪个脚本或配置，具体做了哪些步骤；
- 期望的结果和实际的结果。

## 贴日志之前先去掉个人数据

日志、截图和命令输出里常常带着能识别你或你的设备的信息。贴出来之前请逐项检查并删掉或替换：

- 设备序列号、HWID、IMEI、解锁数据。EDL / Sahara 日志会打印芯片序列号和 HWID；
- MAC 地址、蓝牙地址、Wi‑Fi 名称和密码；
- IP 地址、主机名、tailnet 名称；
- 用户名、家目录路径、窗口标题、文件名里的个人信息；
- 任何 token、密码、私钥或访问码；
- 位置、时区之类能推断出你所在地的信息。

可以像本仓库一样换成占位符，例如 `100.64.0.x`、`02:00:00:00:00:xx`、`user`。

## English

This is one person's hobby project, and **there is no support promise of any kind**.

- Issues may take a long time to get a reply, or may never get one. Silence does not mean the problem is not real, nor that it will be fixed.
- There is no one-to-one help with flashing, unbricking or finding ROMs. This repository neither provides nor links any ROM package, firmware or loader image.
- Everything here has been tested only on the author's own TB323FU. Problems on other devices or firmware versions may well be impossible to reproduce.
- For kernel, helper, installation and boot problems, first check whether they belong to upstream [tb323fu-linux](https://github.com/joonhoekim/tb323fu-linux); if so, report them there in the way upstream asks. Do not report problems caused by this repository's changes to upstream.
- Do not open public issues for security problems; report them privately as described in [SECURITY.md](SECURITY.md).

### When you open an issue

Please state:

- the device model, the Android firmware version and the Linux kernel release (`uname -r`);
- which script or configuration from which directory you used, and the exact steps;
- what you expected and what happened instead.

### Remove personal data before you post logs

Logs, screenshots and command output often carry information that identifies you or your device. Check them before posting and remove or replace:

- device serial numbers, HWIDs, IMEIs and unlock data (EDL / Sahara logs print the chip serial number and the HWID);
- MAC addresses, Bluetooth addresses, Wi‑Fi names and passwords;
- IP addresses, host names and tailnet names;
- user names, home directory paths, window titles and personal details in file names;
- any token, password, private key or access code;
- locations, time zones and anything else that reveals where you are.

You can use placeholders the way this repository does, for example `100.64.0.x`, `02:00:00:00:00:xx` and `user`.

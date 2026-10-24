# 安全

[English](#english)

## 报告安全问题

请通过 GitHub 的「私密漏洞报告」（private vulnerability reporting）私下报告：在本仓库页面打开 **Security** 标签页，点 **Report a vulnerability**。**不要开公开 issue。**

- 这是个人项目，没有响应时限的承诺，会尽力处理。
- 报告时请写清楚涉及的文件、触发条件和影响，并去掉个人数据（见 [SUPPORT.md](SUPPORT.md)）。
- 范围只限本仓库里的脚本、配置和补丁。上游 [tb323fu-linux](https://github.com/joonhoekim/tb323fu-linux)（内核、helper、平台文件）的问题请报给上游；LIVI 等第三方项目的问题请报给对应的项目。

## 已知问题与设计取舍

下面这些是已知的、有意保留或尚未处理的安全相关行为。作者的使用场景是一台只有自己用的平板，桌面用户本来就能免密码使用 sudo；在别的环境里，它们的影响可能更大。部署之前请逐条判断。

### 屏幕键盘（`linux/osk/`）

- **语音输入会上传麦克风音频。** 影响：开启语音输入后，录下的音频会发到 `Y700_OSK_ASR_URL` 指定的服务；访问码从 `~/.config/y700-osk/asr.code`（可用 `Y700_OSK_ASR_CODE_FILE` 改路径）读取，并放在请求头里。如果地址是 http，访问码以明文传输。缓解：只指向你自己控制的服务，并使用 https。仓库不附带公共网关，默认地址是一个解析不到的占位符，不配置就不会上传。
- **fcitx5 插件在会话总线上提供输入接口。** 影响：`org.fcitx.Fcitx5` 上的 `/y700osk`（接口 `fyi.y700.OskCommit1`）提供 `CommitString`、`ForwardKey`、`SelectCandidateCommit`，同一用户的任何进程都能借此往当前焦点应用里输入文字和按键。缓解：这和会话总线本身的信任边界相同；不要在会运行不可信进程的账户里使用。
- **KWin 效果 `y700_oskgate` 会在会话总线上广播触摸与文本输入状态的信号**，同一用户的进程可以监听。缓解：同上。
- **键盘面板会显示 Klipper 的剪贴板历史。** 影响：复制过的密码等内容会出现在键盘面板里。缓解：在 Klipper 里关闭或定期清空历史，或者不要通过剪贴板传递密码。
- **apt 钩子以 root 重新构建 KWin 效果。** 影响：`/etc/apt/apt.conf.d/99y700-oskgate` 在每次 dpkg 运行后以 root 从 `/usr/local/src/y700-osk` 重新构建效果；如果普通用户能写这个目录，就能借 apt 提权。缓解：保持该目录及其内容归 root 所有、其他用户不可写。

### CarPlay / Android Auto（`linux/carplay/livi/`）

- **sudoers 的 SETENV 让 root helper 接受任意环境变量。** 影响：`install-livi.sh` 按 LIVI 的模板安装的 `/etc/sudoers.d/99-LIVI-helper` 带 SETENV；仓库里的 `sudo` 垫片又把调用转给会保留 `-E` 的经典 sudo（sudo.ws）。结果是以桌面用户身份运行的任何进程，都能用自己选定的环境变量启动这个 root helper，这是一条借环境变量注入拿到 root 的路径。在作者的环境里桌面用户本来就有 `NOPASSWD: ALL`，所以没有额外影响；在没有这条规则的系统上就是提权。缓解：去掉 SETENV，改用 `Defaults!<helper 路径> env_keep += "LIVI_CP_PK LIVI_CP_PI LIVI_CP_AIRPLAY_PORT"`，只放行这三个变量；同时让 `sudo` 垫片在转交前去掉 `-E`，否则没有 SETENV 时 sudo 会拒绝执行。
- **LIVI 运行期间蓝牙可被发现，并自动接受配对。** 影响：附近的设备在这段时间里可以配对。缓解：只在需要时打开 LIVI，用完就退出。
- **`config.json` 以 0664 权限重写，里面有热点的 WPA 密码。** 影响：只有所在目录的 0700 权限在保护它。缓解：保持目录为 0700；需要时把文件改成 0600。
- **无线 Android Auto 的 TCP 5277 监听在 0.0.0.0 上。** 影响：LIVI 运行期间，能连上热点的设备（以及 USB 网络那一端）都能连到这个端口。缓解：用防火墙把它限制在热点接口上，或在不用时关掉无线 Android Auto。

### 远程访问（`linux/usbstick/`、`linux/devaccess/`）

- **U 盘脚本会在所有地址上开放 root 的 ssh 登录。** 影响：`y700-fix.sh` / `y700-fix-stdin.sh` 让 sshd 监听 `0.0.0.0` 和 `::`，设 `PermitRootLogin prohibit-password`，注释掉其他限制，在 ufw / nft / iptables 里放行 tcp/22，并把 nft 规则持久化。这样平板在所连的每个网络上都暴露 root 的 ssh（只接受密钥）。缓解：脚本在 `PCKEY` 换成你自己的公钥之前拒绝运行；只在可信网络上使用，用完恢复 sshd 配置和防火墙规则。
- **USB gadget 网络允许以密钥登录 root。** 影响：`10-y700-usb.conf` 允许从 `192.168.7.1` 经 USB 线以密钥登录 root。缓解：保管好对应的私钥；不需要时删掉这份配置。

### 内核（`linux/kernel-y8/` 到 `linux/kernel-y14/`）

- **开机后约 3 分钟内，崩溃会把内存导出到 USB。** 影响：内建的内核命令行保留了 `qcom_scm.download_mode=full`，这段时间里如果崩溃，内存内容可以经 USB 读出。之后由用户态的 `y700-dumpmode-off.timer` 关掉。缓解：确认这个定时器已启用；不需要崩溃转储时，从命令行去掉这个参数。
- **USB gadget 串口可以给出 root shell。** 影响：USB gadget（NCM + ACM）和 `U_SERIAL_CONSOLE` 是内建的；命令行带 `tb323fu.usbshell=1` 时，initramfs 会在 `ttyGS0` 上提供不需要认证的 root shell，有物理接触就能用。缓解：日常使用时不要设置这个参数。
- **y8 起的内核去掉了 SELinux、AppArmor 和审计（AUDIT）。** 影响：依赖 AppArmor 的发行版默认防护不再生效。缓解：需要这些机制时，在内核配置里重新打开。

### 电源与测量（`linux/power/`）

- **`y700-cx-status` 是无认证的只读 HTTP 页面。** 影响：`y700-cx-status.socket` 在 tailnet 地址（占位符 `100.64.0.10`）的 8766 端口提供状态页，以 DynamicUser 运行，没有任何控制功能，但能看到设备的电源状态。缓解：只绑定到私有网络地址，不要绑定到公网或 `0.0.0.0`。
- **实验脚本以 root 写 debugfs 和模块参数，并且就是为了诱发复位而设计的。** 影响：`cx-exp`、`cx-when-idle`、`cx-ladder` 写 `qcom_aoss` 的 debugfs 和模块参数，E1–E5 各步可能让 SoC 复位、丢失未保存的数据。`dczva-stress` 可能挂死设备或触发固件复位，并写 `/dev/pmsg0`。缓解：先读 `cx-collapse/PROTOCOL.md`，只在能接受复位的时候运行。
- **读取寄存器类 debugfs 曾让总线挂死。** 影响：读 pcie、`qcom_aoss`、regmap、`clk_summary` 这类 debugfs 可能让设备卡死。脚本都绕开了它们。缓解：不要手动去读。
- **`soccp-chg-ulog.py` 会占用一个 glink 通道**，重启之前无法再次打开。
- **`y700-screen-off-freeze` 在熄屏 60 秒后冻结按名字匹配的应用 cgroup。** 影响：被冻结的应用在熄屏期间不会处理网络和消息。缓解：按需要调整匹配列表（默认值见脚本开头）。
- **ICE 运行时电源管理的草稿补丁可能卡住根文件系统的 I/O。** 它没有编译过，也没有上机验证过，不要用于日常。
- **安装 tailscaled 的 drop-in 会重启 tailscaled**，经 Tailscale 的远程连接会断开。
- **keyhold 的本地覆盖替换了紧急切回 Android 的组合键程序。** 影响：如果替换后的程序有问题，紧急组合键可能失效。缓解：安装后在设备就在手边时测试一次。
- 下载模式在开机后的前约 3 分钟保持 `full`，见上面「内核」一节。

### 其他

- **切换回 Android 的 sudoers 规则。** `switcher/linux/y700-switch.sudoers` 允许桌面用户免密码以 root 运行 `/usr/sbin/back-to-android`（任意参数）。这个命令会改写启动分区并重启。规则只放行这一个命令。
- **Tailscale 的 operator。** `linux/net/install-tailscale.sh` 把桌面用户设为 tailscale 的 operator，该用户不用 root 就能修改 Tailscale 的设置。
- **安装脚本以 root 运行，并且不检查机型。** 它们假定桌面用户是 `user`（uid 1000），并写入 `/etc`、`/usr/local` 等系统目录。运行之前请先读脚本。

## English

### Reporting a vulnerability

Please report privately through GitHub's private vulnerability reporting: open the **Security** tab of this repository and choose **Report a vulnerability**. **Do not open a public issue.**

- This is a personal project with no promised response time; reports are handled on a best-effort basis.
- Name the files involved, the conditions that trigger the problem and its impact, and remove personal data first (see [SUPPORT.md](SUPPORT.md)).
- The scope is the scripts, configuration and patches in this repository. Report problems in upstream [tb323fu-linux](https://github.com/joonhoekim/tb323fu-linux) (kernel, helper, platform files) to upstream, and problems in third-party projects such as LIVI to those projects.

### Known issues and design trade-offs

The items below are known security-relevant behaviours that are kept on purpose or not yet addressed. The author's setup is a single-user tablet whose desktop user can already use sudo without a password; elsewhere the impact may be larger. Judge each item before you deploy.

#### On-screen keyboard (`linux/osk/`)

- **Voice input uploads microphone audio.** Impact: with voice input on, recorded audio goes to the service named by `Y700_OSK_ASR_URL`; an access code read from `~/.config/y700-osk/asr.code` (path configurable with `Y700_OSK_ASR_CODE_FILE`) is sent in a request header, in clear text if the URL is http. Mitigation: point it only at a service you control, over https. No public gateway is bundled; the default address is a placeholder that never resolves, so nothing is uploaded until you configure it.
- **The fcitx5 add-on exposes input methods on the session bus.** Impact: `/y700osk` on `org.fcitx.Fcitx5` (interface `fyi.y700.OskCommit1`) offers `CommitString`, `ForwardKey` and `SelectCandidateCommit`, so any process of the same user can type text and keys into the focused application. Mitigation: this is the session bus's own trust boundary; do not use it in an account that runs untrusted processes.
- **The KWin effect `y700_oskgate` emits touch and text-input state signals on the session bus**, which processes of the same user can listen to. Mitigation: as above.
- **The keyboard panel shows Klipper's clipboard history.** Impact: copied secrets such as passwords appear in the panel. Mitigation: disable or regularly clear the history in Klipper, or avoid moving passwords through the clipboard.
- **An apt hook rebuilds the KWin effect as root.** Impact: `/etc/apt/apt.conf.d/99y700-oskgate` rebuilds the effect as root from `/usr/local/src/y700-osk` after every dpkg run; if an unprivileged user can write that directory, apt becomes a path to root. Mitigation: keep the directory and its contents owned by root and not writable by others.

#### CarPlay / Android Auto (`linux/carplay/livi/`)

- **SETENV in the sudoers rule lets the root helper accept any environment.** Impact: `/etc/sudoers.d/99-LIVI-helper`, installed by `install-livi.sh` from LIVI's template, carries SETENV, and the repository's `sudo` shim hands the call to classic sudo (sudo.ws), which honours `-E`. Any process running as the desktop user can therefore start the root helper with an environment of its choosing, an environment-injection path to root. On the author's setup this adds nothing, because the desktop user already has `NOPASSWD: ALL`; on a system without that rule it is a privilege escalation. Mitigation: drop SETENV and use `Defaults!<helper path> env_keep += "LIVI_CP_PK LIVI_CP_PI LIVI_CP_AIRPLAY_PORT"` so that only these three variables pass, and have the `sudo` shim drop `-E` before handing the call on, because without SETENV sudo refuses `-E`.
- **While LIVI runs, Bluetooth is discoverable and pairing is accepted automatically.** Impact: nearby devices can pair during that time. Mitigation: run LIVI only when needed and quit it afterwards.
- **`config.json` is rewritten with mode 0664 and contains the hotspot's WPA passphrase.** Impact: only the directory's 0700 mode protects it. Mitigation: keep the directory at 0700; set the file to 0600 if needed.
- **The wireless Android Auto TCP listener on port 5277 binds 0.0.0.0.** Impact: while LIVI runs, any device that can join the hotspot (and the far end of the USB network) can reach it. Mitigation: restrict it to the hotspot interface with a firewall, or turn wireless Android Auto off when not in use.

#### Remote access (`linux/usbstick/`, `linux/devaccess/`)

- **The USB-stick scripts open root ssh login on all addresses.** Impact: `y700-fix.sh` / `y700-fix-stdin.sh` make sshd listen on `0.0.0.0` and `::` with `PermitRootLogin prohibit-password`, comment out other restrictions, accept tcp/22 in ufw / nft / iptables and persist the nft ruleset, so the tablet offers key-only root ssh on every network it joins. Mitigation: the scripts refuse to run until `PCKEY` holds your own public key; use them only on trusted networks and restore the sshd configuration and firewall rules afterwards.
- **The USB gadget network allows key-based root login.** Impact: `10-y700-usb.conf` allows key-only root ssh from `192.168.7.1` over the USB cable. Mitigation: keep the matching private key safe; remove the file when you do not need it.

#### Kernel (`linux/kernel-y8/` to `linux/kernel-y14/`)

- **For about three minutes after boot, a crash dumps memory over USB.** Impact: the built-in kernel command line keeps `qcom_scm.download_mode=full`, so memory contents can be read over USB after a crash in that window; the userspace `y700-dumpmode-off.timer` turns it off afterwards. Mitigation: make sure the timer is enabled; remove the parameter if you do not need crash dumps.
- **The USB gadget serial port can give a root shell.** Impact: the USB gadget (NCM + ACM) and `U_SERIAL_CONSOLE` are built in; with `tb323fu.usbshell=1` on the command line, the initramfs offers an unauthenticated root shell on `ttyGS0` to anyone with physical access. Mitigation: do not set that parameter in daily use.
- **Kernels from y8 on drop SELinux, AppArmor and AUDIT.** Impact: distribution defaults that rely on AppArmor no longer apply. Mitigation: re-enable them in the kernel configuration if you need them.

#### Power and measurement (`linux/power/`)

- **`y700-cx-status` is an unauthenticated read-only HTTP page.** Impact: `y700-cx-status.socket` serves a status page on port 8766 of the tailnet address (placeholder `100.64.0.10`). It runs as a DynamicUser and has no control functions, but it shows the device's power state. Mitigation: bind it only to a private network address, never to a public address or `0.0.0.0`.
- **The experiment scripts write debugfs and module parameters as root, and are designed to provoke resets.** Impact: `cx-exp`, `cx-when-idle` and `cx-ladder` write `qcom_aoss` debugfs entries and module parameters; steps E1–E5 can reset the SoC and lose unsaved data. `dczva-stress` can hang the device or trigger a firmware reset, and writes `/dev/pmsg0`. Mitigation: read `cx-collapse/PROTOCOL.md` first and run them only when a reset is acceptable.
- **Reading register-class debugfs has hung the bus.** Impact: reading debugfs entries such as pcie, `qcom_aoss`, regmap or `clk_summary` can freeze the device. The scripts avoid them. Mitigation: do not read them by hand.
- **`soccp-chg-ulog.py` binds a glink channel** that cannot be reopened until reboot.
- **`y700-screen-off-freeze` freezes app cgroups matched by name 60 seconds after the screen goes off.** Impact: frozen applications do not handle network traffic or messages while the screen is off. Mitigation: adjust the match list (the default is at the top of the script).
- **The draft ICE runtime power-management patch can hang root file system I/O.** It has not been compiled or tested on the device; do not use it day to day.
- **Installing the tailscaled drop-in restarts tailscaled**, which drops remote connections made over Tailscale.
- **The local keyhold override replaces the emergency back-to-Android key-chord program.** Impact: if the replacement misbehaves, the emergency chord may not work. Mitigation: test it once after installing, with the device at hand.
- Download mode stays `full` for about the first three minutes after boot; see the kernel section above.

#### Other

- **The sudoers rule for switching back to Android.** `switcher/linux/y700-switch.sudoers` lets the desktop user run `/usr/sbin/back-to-android` (with any arguments) as root without a password. That command rewrites the boot partition and reboots. The rule allows only this one command.
- **Tailscale operator.** `linux/net/install-tailscale.sh` makes the desktop user the tailscale operator, so that user can change Tailscale settings without root.
- **Install scripts run as root and do not check the device model.** They assume the desktop user `user` (uid 1000) and write to system directories such as `/etc` and `/usr/local`. Read a script before you run it.

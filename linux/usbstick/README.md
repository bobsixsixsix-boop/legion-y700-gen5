# linux/usbstick：用 U 盘一次性开启 ssh

平板上的 Ubuntu 还连不上 ssh 时，用 U 盘把下面这个脚本带过去，在平板本机的终端里运行一次。

| 文件 | 用法 |
|---|---|
| `y700-fix.sh` | `sudo bash /media/$USER/<U 盘>/y700-fix.sh` |
| `y700-fix-stdin.sh` | 内容相同，只是包了一层函数、标准输入接 `/dev/null`，适合用 `bash < 脚本` 这类读标准输入的方式运行（防止脚本里的命令把剩下的脚本当输入吃掉） |

## 用之前必须改

脚本里的 `PCKEY='REPLACE_WITH_YOUR_SSH_PUBLIC_KEY'` 要换成**你自己的** ssh 公钥（`~/.ssh/id_ed25519.pub` 的那一行）。没换的话脚本直接退出，什么都不改。

## 它会改什么

这是一个「先让 ssh 通起来」的脚本，改动范围比较大，运行前请读一遍：

- 取消 ssh 相关单元的 mask，删掉阻止 sshd 运行的标记文件；
- 注释掉其他 sshd 配置里的 `Port`、`ListenAddress`、`AllowUsers` / `DenyUsers` 等，写入 `/etc/ssh/sshd_config.d/00-y700.conf`：22 端口、**所有网络接口**、只允许密钥登录、root 只能用密钥登录；
- 把 `PCKEY` 追加到 **root** 的 `authorized_keys`；
- 在 ufw、nftables、iptables 里放行 22 端口（nftables 开机启用时还会把当前规则集写回 `/etc/nftables.conf`）；
- 停用 `ssh.socket`，启用并重启 `ssh.service`。

改动过的文件都备份为 `*.y700bak`；日志写在脚本旁边的 `y700-fix-<时间>.log`。

如果只想在 USB 网络上开 ssh，见 `linux/devaccess/` 里的配置。上面这个脚本会删掉 `10-y700-usb.conf`，改成监听所有网络。

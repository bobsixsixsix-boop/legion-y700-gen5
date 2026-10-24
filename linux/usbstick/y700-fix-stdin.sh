#!/bin/bash
y700_main() {
# y700-fix.sh -- make SSH work on the tablet's Ubuntu. Run once from the USB stick:
#     sudo bash /media/$USER/*/y700-fix.sh
# sshd on port 22, all addresses, key login only (no passwords). Firewalls that
# block 22 are opened. Every changed file is backed up as *.y700bak.
# A log is written next to this script: y700-fix-<time>.log
# Before use: put YOUR OWN SSH public key into PCKEY below (one line of ~/.ssh/id_ed25519.pub); it is appended to
# root's authorized_keys. The script refuses to run while PCKEY still holds the placeholder.
set -u
[ "$(id -u)" = 0 ] || { echo "run with sudo:  sudo bash $0"; exit 1; }
DIR=$(cd "$(dirname "$0")" && pwd)
LOG=$DIR/y700-fix-$(date +%Y%m%d-%H%M%S).log
: > "$LOG" 2>/dev/null || LOG=/root/y700-fix.log
run() { echo "\$ $*" >> "$LOG"; "$@" >> "$LOG" 2>&1; echo "[exit $?]" >> "$LOG"; }
backup() { [ -e "$1" ] && [ ! -e "$1.y700bak" ] && cp -a "$1" "$1.y700bak"; }
PCKEY='REPLACE_WITH_YOUR_SSH_PUBLIC_KEY'
[ "$PCKEY" != REPLACE_WITH_YOUR_SSH_PUBLIC_KEY ] || { echo "edit this script first: set PCKEY to your own SSH public key (one line of ~/.ssh/id_ed25519.pub)"; exit 1; }

echo "== before" >> "$LOG"
run ss -tlnp
run grep -rniE '^[[:space:]]*(port|listenaddress|allowusers|denyusers|addressfamily)' /etc/ssh/sshd_config /etc/ssh/sshd_config.d

# 1. units: unmask everything ssh-related
for u in ssh.service ssh.socket sshd.service; do
	[ "$(readlink -f /etc/systemd/system/$u 2>/dev/null)" = /dev/null ] && run systemctl unmask "$u"
done

# 1b. "do not run" markers and any other ConditionPathExists=! the units check
for m in /etc/ssh/sshd_not_to_be_run $(systemctl cat ssh.service ssh.socket 2>/dev/null | sed -n 's/^ConditionPathExists=!//p'); do
	[ -e "$m" ] && { backup "$m"; rm -f "$m"; echo "removed $m" >> "$LOG"; }
done

# 2. config: drop any Port/ListenAddress/Allow*/Deny* set elsewhere, then our own file
[ -s /etc/ssh/sshd_config ] || printf 'Include /etc/ssh/sshd_config.d/*.conf\nUsePAM yes\nSubsystem sftp /usr/lib/openssh/sftp-server\n' > /etc/ssh/sshd_config
grep -q '^Include /etc/ssh/sshd_config.d/\*\.conf' /etc/ssh/sshd_config || { backup /etc/ssh/sshd_config; sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config; }
for f in /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf; do
	[ -f "$f" ] || continue
	case "$f" in */00-y700.conf) continue;; esac
	if grep -qiE '^[[:space:]]*(port|listenaddress|addressfamily|allowusers|denyusers|allowgroups|denygroups)[[:space:]]' "$f"; then
		backup "$f"
		sed -i -E 's/^([[:space:]]*)((port|listenaddress|addressfamily|allowusers|denyusers|allowgroups|denygroups)[[:space:]].*)$/\1# y700-fix: \2/I' "$f"
	fi
done
rm -f /etc/ssh/sshd_config.d/10-y700-usb.conf
install -d -m 755 /etc/ssh/sshd_config.d
printf '# y700: every network, key login only\nPort 22\nListenAddress 0.0.0.0\nListenAddress ::\nPermitRootLogin prohibit-password\nPubkeyAuthentication yes\nPasswordAuthentication no\nKbdInteractiveAuthentication no\nPermitEmptyPasswords no\n' > /etc/ssh/sshd_config.d/00-y700.conf

# 3. keys
ls /etc/ssh/ssh_host_*_key >/dev/null 2>&1 || run ssh-keygen -A
chown root:root /etc/ssh/ssh_host_*_key; chmod 600 /etc/ssh/ssh_host_*_key
install -d -m 700 /root/.ssh; touch /root/.ssh/authorized_keys; chmod 600 /root/.ssh/authorized_keys
grep -qF "$PCKEY" /root/.ssh/authorized_keys || echo "$PCKEY" >> /root/.ssh/authorized_keys
mkdir -p /run/sshd

# 4. firewalls
if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q 'Status: active'; then run ufw allow 22/tcp; fi
if command -v nft >/dev/null; then
	run nft list ruleset
	nft list ruleset 2>/dev/null | awk '/^table /{f=$2;t=$3} /^\tchain /{c=$2} /type filter hook input/{print f,t,c}' | sort -u |
	while read -r f t c; do nft list chain "$f" "$t" "$c" | grep -q 'tcp dport 22 accept' || run nft insert rule "$f" "$t" "$c" tcp dport 22 accept; done
	if systemctl is-enabled nftables.service >/dev/null 2>&1 && [ -f /etc/nftables.conf ]; then backup /etc/nftables.conf; nft list ruleset > /etc/nftables.conf; fi
fi
if command -v iptables >/dev/null; then
	iptables -C INPUT -p tcp --dport 22 -j ACCEPT 2>/dev/null || run iptables -I INPUT -p tcp --dport 22 -j ACCEPT
fi

# 5. start
run sshd -t; T=$?
run systemctl daemon-reload
run systemctl disable --now ssh.socket
run systemctl enable ssh.service
run systemctl restart ssh.service
sleep 2
echo "== after" >> "$LOG"
run systemctl status ssh.service --no-pager -l
run journalctl -u ssh -b --no-pager -n 30
run ss -tlnp
sync

echo
if ss -tln | grep -qE '[:.]22[[:space:]]'; then
	echo "SSH OK: listening on port 22, key login only. USB address $(ip -4 -br addr show usb0 2>/dev/null | awk '{print $3}')"
else
	echo "SSH NOT listening. Log: $LOG"
	journalctl -u ssh -b --no-pager -n 8
fi
}
y700_main </dev/null

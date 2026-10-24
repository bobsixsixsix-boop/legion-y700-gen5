#!/bin/sh
# Tailscale on the Y700 (Ubuntu 26.04, arm64): official apt repository, tailscaled enabled, the desktop
# user made the "operator" so the control centre tile can run `tailscale up/down` without root.
# Run as root. Logging in (tailscale up / login) is the owner's job: it opens a browser login.
set -eu
U=user
if ! command -v tailscale >/dev/null; then
	code=$(. /etc/os-release && echo "${VERSION_CODENAME:-}")
	# the official install script knows the supported codenames; a brand-new Ubuntu may not be
	# in it yet, then the previous LTS repository (noble) is what Tailscale themselves suggest
	if ! curl -fsSL https://tailscale.com/install.sh | sh; then
		echo "install.sh refused codename '$code', using the noble repository" >&2
		curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/noble.noarmor.gpg | tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
		curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/noble.tailscale-keyring.list | tee /etc/apt/sources.list.d/tailscale.list >/dev/null
		apt-get update && apt-get install -y tailscale
	fi
fi
systemctl enable --now tailscaled
# the tile runs as the desktop user: operator rights (no sudo for up/down/status)
tailscale set --operator=$U
echo "tailscale $(tailscale version | head -1) installed; state: $(tailscale status --json 2>/dev/null | python3 -c 'import sys,json; print(json.load(sys.stdin).get("BackendState"))' 2>/dev/null || echo unknown)"
echo "next: as $U run 'tailscale up' (prints a login URL) or tap the tile in the control centre"

# SPDX-FileCopyrightText: 2026 Jens Koehler <kwin-effect-upscale@koehler-speyer.de>
# SPDX-License-Identifier: GPL-2.0-or-later
# /etc/xdg/plasma-workspace/env/kwin-upscale-x11.sh (as installed by kwin-effect-upscale with prefix /usr).
# Plasma sources this before starting KWin and publishing the launch environment.
# Freeze routing for this login: changing it cannot migrate existing X11 sockets.
if [ "${XDG_SESSION_TYPE:-}" = wayland ]; then
    if "/usr/lib/aarch64-linux-gnu/libexec/kwin-upscale-x11/Xwayland" --upscale-enabled; then
        UPSCALE_X11_SESSION_ROUTED=1
    else
        UPSCALE_X11_SESSION_ROUTED=0
    fi
    export UPSCALE_X11_SESSION_ROUTED
    PATH="/usr/lib/aarch64-linux-gnu/libexec/kwin-upscale-x11:$PATH"
    export PATH
fi

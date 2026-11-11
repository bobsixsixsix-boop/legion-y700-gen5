#!/usr/bin/env python3
"""y700-checklist: the tablet's "things to remember", checked instead of remembered (2026-10-15).
Installed on the tablet as /usr/local/bin/y700-checklist; run as root.
Read-only except its own baseline (/var/lib/y700/checklist-state.json, written with --save: a .tmp renamed over it).

Two kinds of checks:
  CHANGED  a watched package/component changed since the baseline -> the follow-up it needs
           (the periodic obligations scattered through y700/README.md, in one place);
  WARN     the current state is wrong (not our kernel, keyboard gate missing, /etc/drirc's zink list not the repo's,
           GPU hangs since the last --save, a watchdog not running...). OK lines say what was verified.
Exit code: 10 if anything is CHANGED or WARN (worth telling the owner), 0 otherwise, 1 on error.
A daily job on another machine can run it over ssh with --save and report the lines.

Crash forensics (2026-10-16, for the cx-collapse experiments; PROTOCOL.md section 2, RESEARCH.md 2.6):
  - an unclean previous boot is classified from the pstore console tail (console-ramoops), the pstore panic
    records (dmesg-ramoops) and the flight recorder's archive of the previous boot's pmsg ring / UFS log;
    "the previous boot's" = archived by systemd-pstore THIS boot (its ExecMainStartTimestamp vs the files' ctime;
    when systemctl cannot say: the last --save, or without one this boot's start less 10 min),
    because /var/lib/systemd/pstore is flat and keeps old records, and the recorder re-copies all of it every boot;
  - a NEW dump in the rawdump partition (XBL wrote it in download mode) is reported with the lastkmsg tail
    and the raw RST_STAT / PMIC_PON bytes (hash of header + lastkmsg kept in the baseline);
  - experiment hygiene: allow_cluster_off / allow_system_off left on without a y700-cx-exp unit running.
Battery page (2026-10-30, linux/power/battery/DESIGN.md section 7; silent where it is not installed): y700-batteryd
running with no automatic restart since the last --save (its NRestarts and boot kept in the baseline), its ledger
written within 40 min and at most 20 MiB with the foreground logs (the 16 MiB cap plus a day's growth before the next
prune), flightrec's energy line at most 60 s old by CLOCK_MONOTONIC while flightrec runs, and the report's diag block
(coefficients to recalibrate: INFO while they are still the uncalibrated priors, WARN once calibrated; a report that
times out is INFO, one that exits with no output is WARN).
Every one of these runs under guard(): a broken check prints one WARN line instead of killing the run.
"""
import glob, hashlib, json, os, re, struct, subprocess, sys, time

STATE = "/var/lib/y700/checklist-state.json"
FLIGHTREC = "/var/log/y700-flightrec"                       # y700-flightrec (Rust): flightrec-<boot8>.log, pstore/<boot8>/
FLIGHTREC_UNIT = "/etc/systemd/system/y700-flightrec.service"
# the battery page (linux/power/battery, DESIGN.md section 7, 2026-10-30): its recorder is a systemd user unit of user that
# linux/power/battery/install.sh installs (its presence is what turns these checks on), its ledger lives in user's
# ~/.local/state, its energy counters in the flight recorder's tmpfs dir, and its report is a read-only CLI
BATTERYD_UNIT = "/home/user/.config/systemd/user/y700-batteryd.service"
BATTERY_LEDGER = "/home/user/.local/state/y700-battery"   # b-<boot8>[.<n>].jsonl, fg-<boot8>[.<n>].log, boots.txt
FLIGHTREC_ENERGY = "/run/y700-flightrec/energy"               # flightrec's acc.rs: one fixed-width line, pwrite in place
BATTERY_REPORT = "/usr/local/bin/y700-battery-report"
BATTERY_LEDGER_STALE_S = 2400     # batteryd snapshots every 300 s with the screen on, checkpoints every 1800 s with it off
BATTERY_LEDGER_MAX = (16 + 4) << 20   # ledger.rs KEEP_BYTES (16 MiB) + one 4 MiB part: the prune runs about once a day
#   (at start and the first screen-on snapshot a day after the last one), so the total may pass 16 MiB by up to a day's
#   growth in between, always less than one part. At the estimated 130-300 KB/day the 40-day rule keeps it at 5-12 MiB
BATTERY_ENERGY_STALE_S = 60       # flightrec rewrites the line after every data line: every 10 s, every 1 s in experiments
BATTERY_UNEXPLAINED_MAX = 0.20    # the report's diag thresholds (DESIGN.md 6b.a "diag" quotes them from section 7)
BATTERY_FLOOR_DRIFT_MAX = 0.25
BATTERY_COEFF_MAX_DAYS = 90
BATTERY_REPORT_TIMEOUT_S = 30     # the report aims at < 1.5 s; its busctl / journalctl calls time out at 5 s each
PSTORE_DIRS = ("/var/lib/systemd/pstore", "/sys/fs/pstore")  # systemd-pstore's archive (flat: every ramoops record at the top level,
#   console/pmsg overwritten each boot, dmesg-ramoops-N never deleted - cx-audit-2247.txt, PROTOCOL.md 1.4), then the raw fs
RAWDUMP = "/dev/disk/by-partlabel/rawdump"
CX_PARAMS = "/sys/module/cpuidle_psci_domain/parameters"     # allow_cluster_off (patch 0118, bool -> Y/N), allow_system_off (y10)
# signatures in the last lines of a kernel console -> what the end of that boot looked like
CRASH_SIGNS = (
    (r"Kernel panic", "内核 panic"),
    # qcom_wdt barks 1 s before it bites (pretimeout 1); no pretimeout governor, so the bark only prints this. bootstatus
    # does not tell a bite on this SoC (0 after the 2026-11-01 01:27 bite test), this line in the console tail does
    (r"watchdog\d+: pretimeout event", "硬件看门狗到点：系统卡了 30 秒没人喂狗，1 秒后被看门狗复位（y16 起直接重启，11-01 咬测试）"),
    # 2026-10-31 21:04: die() printed this, CPU0 stopped mid-register-dump, panic() never ran; the firmware reset into dump mode
    (r"synchronous external abort", "同步外部中止（SEA）：读硬件寄存器时总线报错，CPU 当场停住，panic 和 10 秒重启都没跑到"),
    (r"pc : msm_mdss_irq", "出错点在显示模块的中断处理（读 MDSS 中断状态寄存器，10-31 21:04 同款）"),
    (r"Internal error: Oops|Unable to handle kernel", "内核 Oops（oops=panic，所以也会 panic）"),
    (r"SError Interrupt", "SError（总线/固件异常）"),
    (r"Unhandled fault", "未处理的异常"),
    (r"soft lockup|hard LOCKUP|rcu_[a-z]+ (self-)?detected|rcu: INFO", "lockup / RCU stall"),
    (r"blocked for more than|hung_task", "hung task"),
    (r"timed out in resp|TCS Busy|rpmh[^\n]*(timeout|fail)", "固件通道超时（SCMI/RPMh）＝总线挂死那一类（03:41 同款）"),
    # 2026-11-02 15:15 (boot 447a621b): the only sign in the console, about 2 s before a silent reset; in no boot's journal
    # otherwise (checked 11-03). A plain sysfs read that times out does not print it, only the uevent after a change does
    (r"qcom-battmgr-bat: driver failed to report", "电池固件（ADSP，经 pmic_glink）超时不回话（11-02 15:15 只有这一样，约 2 秒后整机复位；03:41 总线挂死时也有）"),
    (r"failed to flush transmit queue|ath12k[^\n]*(crash|firmware)", "Wi‑Fi 固件出事"),
    (r"vblank timeout|wait for commit done", "显示管线超时（DPU；平时也零星有，单独出现不算死因）"),
    (r"hangcheck recover", "GPU 卡死"),
    (r"Out of memory|oom-kill", "OOM"),
)
# programs /etc/drirc (y700/linux/gpu/drirc) sends to zink instead of freedreno GL, which hangs the Adreno 840 under
# them (Chrome 10-14; ChatGPT's and steamwebhelper's GPU processes 10-19), with the day each was added there: a GPU hang
# of one of them from before its own day is "from before zink". The name is what Mesa matches: the basename of argv[0].
# Must name exactly the programs linux/gpu/drirc zinks (the selftest compares them); to roll one back, take it out of
# both and install both (README『Chrome 让 GPU 卡死』), or the drirc line WARNs every day.
DRIRC_ZINK = {"chrome": "2026-10-14", "ChatGPT": "2026-10-23", "steamwebhelper": "2026-10-23"}
# GPU hangs in the kernel log: msm's recover_worker prints "hangcheck recover!" and then "offending task: <comm> (<cmdline>)"
# (or "offending task: unknown"); "hangcheck detected gpu lockup" is the older hangcheck timer's line
GPU_HANG_GREP = "hangcheck (recover|detected gpu lockup)|offending task:"
GPU_HANG_CAP = 400                                  # newest matching kernel lines read (2 per hang): bounds a hang storm
DESKTOP_PROGS = ("kwin_wayland", "Xwayland", "plasmashell")   # the desktop itself: not something to move to zink one by one
USER_ENV = ["sudo", "-u", "user", "env", "XDG_RUNTIME_DIR=/run/user/1000",
            "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus"]
GOOD_KERNEL_TAG = re.compile(r"-tb323fu-t\d+-y\d+$")    # our builds: ...-tb323fu-t49-y7
# the initramfs's e2fsck of the roots (kernel y17, linux/kernel-y17/NOTES.md, 2026-11-01): y17's init says on kmsg
# "baldur:  fsck NAME (DEV): exit N (WHAT), T s" after each run (journalctl strips "baldur:", the syslog identifier, so
# the message reads " fsck ..."), or "... no e2fsck in this image, not checked". One journalctl -g per boot reads those,
# the kernel's ext4 complaints that matter (in order with them) and the boot's "Linux version" line
FSCK_GREP = (r"^Linux version \S+|fsck \S+ \(/dev/\S+\): (exit |no e2fsck)|EXT4-fs (error \(device \S+\)|\(\S+\): "
             r"(warning: mounting fs with errors|Couldn't remount RDWR|Errors on filesystem, clearing orphan list))")
# hci_qca's lines for each setup of the Bluetooth chip (check_bt_firmware); uppercase in it = journalctl -g matches case
# sensitively
BT_GREP = r"hci[0-9]+: (setting up |QCA (Failed to|FW build version: |setup on UART is completed))"
FSCK_RESULT = re.compile(r"fsck (\S+) \((/dev/\S+)\): exit (\d+) \(([^)]*)\), (\d+) s$")
FSCK_FIRST_Y = 17                                     # the first kernel whose initramfs runs it
PANEL_MM_FIRST_Y = 18                                 # the first kernel reporting the panel's real 118 x 190 mm (upstream 0144)

# package -> what to do when it changes
PACKAGES = {
    "kwin-wayland": "KWin 升级：键盘门卫特效由 apt 钩子自动重编（journalctl -t y700-oskgate 看结果，下次登录生效）；"
                    "台前调度的圆角特效同样由 apt 钩子自动重编（journalctl -t y700-stagecorners）；"
                    "控制中心用的 registerTouchScreenEdge / LayerShellQt 接口看一眼；SGSR 特效（已停用）要用时需重编；"
                    "底边上滑手势跑一次 linux/gesture/tests/taskswitcher-test.sh（装了多任务卡片时；否则 home-test.sh；会动屏幕，先确认没人在用）",
    "plasma-mobile": "Plasma Mobile 升级（多任务卡片的上游）：重跑 linux/gesture/taskswitcher/install.sh（补丁对不上会停下，"
                     "旧版留着），重新登录后跑 linux/gesture/tests/taskswitcher-test.sh（会动屏幕，先确认没人在用）",
    "plasma-workspace": "Plasma 升级：控制中心、键盘（LayerShellQt 层壳）、桌面图标位置看一眼",
    "libkf6screen8": "libkscreen 升级：y700-autorotate 要用新版本的头文件重编（README『控制中心』）",
    "libqt6core6t64": "Qt 升级：y700-osk、控制中心、自动旋转可能要重编（看它们能否启动）",
    "fcitx5": "fcitx5 升级：重跑 linux/osk/install.sh 重编 y700osk 插件（上屏/候选靠它）",
    "google-chrome-stable": "Chrome 升级：zink 由 /etc/drirc 保证不用管；大版本时确认视频硬解还在（linux/gpu/cdp_media.py），"
                            "并跑一次硬解自测 systemd-run --unit=y700-vp9chrome --collect bash /root/chrome-vp9-check.sh"
                            "（约 4 min，测量期间别跑，要 0 failed；README『（周期性）Chrome 硬解自测』）；"
                            "看 WaylandExternalBeginFrameSource 是否已默认开启或改名（README『Chromium 新帧源开关』）",
    "claude-desktop": "Claude 桌面版升级：Electron 大版本变了就熄屏复测合成线程（linux/power/cx-collapse/runs/day-20261018/bfsclaude.sh），"
                      "并确认还是从 /usr/lib/claude-desktop/claude-desktop 启动（/usr/local/bin/claude-desktop 包装指着它）",
    "chatgpt": "ChatGPT 桌面版升级：点一下它的输入框看屏幕键盘还弹不弹（Electron 大版本变了尤其要看）；"
               "体检报「和 deb 的桌面项对不上」就重跑 /root/daily/chatgpt-wayland-ime.sh（README『屏幕键盘 y700-osk』10-22）",
    "libgl1-mesa-dri": "Ubuntu Mesa GL 升级：/etc/drirc 让 Chrome、ChatGPT、Steam 界面（steamwebhelper）走 zink 绕开它；"
                       "可以考虑撤掉，三个要一起复测（撤哪个就从 freedreno GL 上开它、看 journalctl -k 有没有 hangcheck，"
                       "Chrome 打开一个重页面来回滑）；撤掉要同时改 linux/gpu/drirc 和体检的 DRIRC_ZINK（README『Chrome 让 GPU 卡死』）。"
                       "Steam 界面 10-30 起走 GPU、关掉 zink 的渲染通道跟踪（ZINK_DEBUG=norp，开着时商店评测花屏）："
                       "以 Y700_STEAM_UI=gpu-rp 开一次 Steam，看商店评测区还花不花，不花了就可以撤掉启动器里的 "
                       "ZINK_DEBUG=norp（README『Steam 界面花屏』）",
    "libva2": "libva 升级：大版本时重编 radxa libva-v4l2（/usr/local），否则 Chrome/mpv 的 VA-API 硬解会掉",
    "tb323fu-helper": "helper 包升级：若装了熄屏慢轮询补丁（/etc/systemd/system/tb323fu-helperd.service.d/y700-local.conf），"
                      "要在新源码上重打 linux/power/helperd-slow-poll.patch 重编到 /usr/local/libexec（README『熄屏唤醒治理』）",
}


def pid_env(name):
    """(pid, environ bytes) of the first process called `name`, or (None, b'')."""
    pid = run(["pidof", name]).split()
    if not pid:
        return None, b""
    try:
        with open(f"/proc/{pid[0]}/environ", "rb") as f:
            return pid[0], f.read()
    except OSError:
        return pid[0], b""


def run(cmd, user=False, timeout=20):
    try:
        r = subprocess.run((USER_ENV + cmd) if user else cmd, capture_output=True, text=True, timeout=timeout)
        return r.stdout.strip()
    except Exception as e:
        return f"ERROR {e}"


def run_rc(cmd, user=False, timeout=20):
    """run() keeping the exit status: (rc, stdout, stderr), both stripped. rc None: still running at `timeout` (killed);
    rc 127 with the reason as stderr: it could not be started. sudo and env pass the command's own status through"""
    try:
        r = subprocess.run((USER_ENV + cmd) if user else cmd, capture_output=True, text=True, timeout=timeout)
        return r.returncode, r.stdout.strip(), r.stderr.strip()
    except subprocess.TimeoutExpired:
        return None, "", ""
    except Exception as e:
        return 127, "", f"ERROR {e}"


def dpkg_version(pkg):
    return run(["dpkg-query", "-W", "-f", "${Version}", pkg]) or None


def slurp(path, default=None):
    """A small text file's content, or `default` when it is missing or unreadable. For the reads main() makes outside
    guard(): an exists() check does not cover the file vanishing before open() (the ath12k version while CarPlay's
    settle reloads the module), a permission or a decode error - any of which used to end the whole run in one
    "ERROR" line, exit 1, nothing saved (10-19 audit)."""
    try:
        with open(path) as f:
            return f.read()
    except (OSError, ValueError):
        return default


def file_hash(path):
    try:
        return hashlib.sha256(open(path, "rb").read()).hexdigest()[:16]
    except OSError:
        return None


def read(path, default=None):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return default


def kwin_js(code):
    """Run a KWin script in the owner's session; the lines it out()s, or None if KWin would not load it
    (linux/osk/tests/kwin-eval.sh's trick: print() goes to KWin's journal, found again by a unique tag)."""
    tag = f"y700chk{os.getpid()}"
    path = f"/tmp/{tag}.js"
    with open(path, "w") as f:
        f.write(f"function out(s) {{ print('{tag} ' + s); }}\n{code}\n")
    os.chmod(path, 0o644)
    since = time.strftime("%Y-%m-%d %H:%M:%S")
    scripting = ["busctl", "--user", "call", "org.kde.KWin", "/Scripting", "org.kde.kwin.Scripting"]
    try:
        sid = run(scripting + ["loadScript", "ss", path, tag], user=True).split()
        if len(sid) != 2 or sid[0] != "i" or sid[1] == "-1":
            return None
        run(["busctl", "--user", "call", "org.kde.KWin", f"/Scripting/Script{sid[1]}", "org.kde.kwin.Script", "run"], user=True)
        time.sleep(0.4)
        run(scripting + ["unloadScript", "s", tag], user=True)
        lines = run(["journalctl", "--user", "--since", since, "--no-pager", "-o", "cat"], user=True).splitlines()
        return [l.split(tag + " ", 1)[1] for l in lines if tag + " " in l]
    finally:
        os.unlink(path)


def session_kwin():
    """pid of the owner's session kwin_wayland, or None. Not simply the first pid pidof prints: that is the newest,
    and the headless test KWins (`kwin_wayland --virtual`, started as user by linux/video/chrome-vp9-check.sh,
    wiliwili-wayland-disconnect-test.sh and the task-switcher test bed) have the same comm and uid. During a test
    "KWin 旧库" read the test KWin's maps and "上次登录残留" took its start for this login's, every app the owner
    had open reported as left over (10-23). The rule is y700-kwin-uclamp's (src/main.rs is_virtual): uid 1000,
    no "--virtual" among its arguments. Negative on purpose: with no KWin found both checks print nothing, so a
    positive test (parent kwin_wayland_wrapper, cgroup plasma-kwin_wayland.service) would silently switch them off
    if Plasma ever started KWin another way. Of several (a re-login's old one still exiting) the one started last."""
    best = None
    for pid in run(["pidof", "kwin_wayland"]).split():
        if not pid.isdigit():
            continue
        try:
            uid = re.search(r"^Uid:\s+(\d+)", read(f"/proc/{pid}/status") or "", re.M)
            with open(f"/proc/{pid}/cmdline", "rb") as f:
                args = f.read().split(b"\0")
            start = int((read(f"/proc/{pid}/stat") or "").rsplit(")", 1)[1].split()[19])
        except (OSError, IndexError, ValueError):
            continue                        # gone meanwhile
        if uid and uid.group(1) == "1000" and b"--virtual" not in args and (best is None or start > best[1]):
            best = (pid, start)
    return best[0] if best else None


def current():
    cur = {"pkgs": {p: dpkg_version(p) for p in PACKAGES}}
    cur["kernel"] = os.uname().release
    cur["checked_at"] = time.time()                 # pstore records with a ctime after this are "new" next time
    cur["boot8"] = (read("/proc/sys/kernel/random/boot_id", "") or "").replace("-", "")[:8] or None
    mesa = os.path.realpath("/var/lib/tb323fu/mesa/current") if os.path.exists("/var/lib/tb323fu/mesa/current") else None
    cur["tb323fu_mesa"] = os.path.basename(mesa) if mesa else None
    cur["fex"] = file_hash("/home/user/.local/share/Steam/steamapps/common/FEX-Emu/VERSIONS.txt")
    cur["livi"] = os.path.basename(os.path.realpath("/opt/livi")) if os.path.exists("/opt/livi") else None   # -> livi-10.3.0
    boots = list_boots()
    ended = [b for b in boots if b["boot_id"][:8] != cur["boot8"]] if cur["boot8"] else boots[:-1]
    cur["prev_boot"] = ended[-1]["boot_id"] if ended else None
    return cur, ended


def list_boots():
    """The boots journald keeps, oldest first, as `journalctl --list-boots -o json` gives them: [{"index" (0 = this
    boot), "boot_id" (32 hex), "first_entry", "last_entry"}]; [] when journalctl cannot say."""
    try:
        boots = json.loads(run(["journalctl", "--list-boots", "-o", "json", "--no-pager", "-q"]) or "[]")
        return sorted([b for b in boots if isinstance(b.get("boot_id"), str)], key=lambda b: b["index"])
    except (ValueError, KeyError, TypeError, AttributeError):
        return []


def prev_boot_ending(boot):
    """How a boot that is over ended (`boot`: its id): (clean?, time of its last journal line). A crash or SoC reset leaves
    no shutdown lines; a reset the firmware does (watchdog bite, fatal bus error) then sits in the crash-dump screen and
    drains the battery until someone holds the power key (2026-10-15 03:41: 73 % -> 37 % overnight; 2026-10-31 21:04:
    2 h 9 min although download_mode was off: SDI stays armed until kernel y16, README「10-31 21:04 死机」).
    tb323fu-ctl's LastBootClean did not notice that one, so look at the journal itself."""
    tail = run(["journalctl", "-b", boot, "-n", "300", "--no-pager", "-o", "cat"])
    clean = any(s in tail for s in ("systemd-shutdown", "Reached target reboot.target", "Reached target poweroff.target",
                                     "Reached target System Reboot", "Reached target System Power Off", "Journal stopped"))
    last = run(["journalctl", "-b", boot, "-n", "1", "--no-pager", "-o", "short-iso"]).split(" ", 1)[0]
    return clean, last


# ---- crash forensics helpers ---------------------------------------------------------------------------

def tail_text(path, max_bytes=512 * 1024):
    """The last max_bytes of a possibly garbled log as text (ramoops bit flips -> U+FFFD, never an exception)."""
    with open(path, "rb") as f:
        f.seek(0, os.SEEK_END)
        f.seek(max(0, f.tell() - max_bytes))
        return f.read().decode("utf-8", "replace")


def head_text(path, max_bytes=4096):
    """The first max_bytes of a file as text (pstore dmesg records start with "Panic#1 Part1", the flight
    recorder's log with its HEADER line - the tail would show neither once the file outgrows the window)."""
    with open(path, "rb") as f:
        return f.read(max_bytes).decode("utf-8", "replace")


def first_line(path, max_bytes=4096):
    return (head_text(path, max_bytes).splitlines() or ["?"])[0]


def console_lines(text):
    """Kernel console text -> [(display line, repeat count)]: printk time prefix stripped, blank and
    ECC-garbled lines dropped, consecutive lines equal up to numbers collapsed (03:41 was 163 identical
    SCMI timeouts in a row - three of those would say nothing)."""
    out = []
    for raw in text.splitlines():
        ln = re.sub(r"^\s*\[\s*\d+\.\d+\]\s*", "", raw).strip()
        if len(ln) < 4 or sum(1 for c in ln if c == "�" or ord(c) < 32) * 10 > len(ln):
            continue
        norm = re.sub(r"0x[0-9a-fA-F]+|\d+", "#", ln)
        if out and out[-1][2] == norm:
            out[-1][1] += 1
        else:
            out.append([ln, 1, norm])
    return [(ln, n) for ln, n, _ in out]


def console_tail(text, n=3, width=110):
    return [ln[:width] + (f" ×{c}" if c > 1 else "") for ln, c in console_lines(text)[-n:]] or ["（空）"]


def classify_console(text):
    """Crash signatures found in the last 300 console lines, in CRASH_SIGNS order."""
    tail = "\n".join(text.splitlines()[-300:])
    return [label for pat, label in CRASH_SIGNS if re.search(pat, tail)]


def last_line(path):
    try:
        lines = [l for l in tail_text(path, 8192).splitlines() if l.strip()]
        return lines[-1] if lines else None
    except OSError:
        return None


def brief_flightrec(line, keys=("at", "up", "bat", "dpms", "aco", "aso", "dl", "pd", "qs", "irq")):
    """A flight-recorder line (PROTOCOL.md section 2 field list) cut down to the fields that date and explain it."""
    if not line:
        return "（无）"
    if line.startswith(("MARK", "HEADER", "STOP", "MODE")):
        return line[:120]
    f = dict(kv.split("=", 1) for kv in line.split() if "=" in kv)
    return " ".join(f"{k}={f[k]}" for k in keys if k in f) or line[:120]


def pstore_records(boot8):
    """{kind: path} for the pstore records on disk; kind = console | pmsg | dmesg:<name>.
    Looked for in the flight recorder's archive for THIS boot first (y700-flightrec copies every top-level file of
    systemd-pstore's archive there at start, because systemd-pstore overwrites same-named files next boot; files it
    took from /sys/fs/pstore get a sysfs- prefix), then systemd-pstore's archive, then /sys/fs/pstore itself (only
    populated when systemd-pstore did not run). First hit per kind wins. Whether a record is NEW is is_fresh()'s job:
    the directories hold old records too (systemd-pstore never deletes dmesg-ramoops-N, and the recorder re-copies
    them every boot)."""
    dirs = ([f"{FLIGHTREC}/pstore/{boot8}"] if boot8 else []) + list(PSTORE_DIRS)
    found = {}
    for d in dirs:
        for p in sorted(glob.glob(d + "/*") + glob.glob(d + "/*/*")):     # ramoops records are flat; */* only for an EFI-style layout
            if not os.path.isfile(p):
                continue
            name = os.path.basename(p)
            name = name[6:] if name.startswith("sysfs-") else name
            kind = name.split("-")[0]
            if kind in ("console", "pmsg"):
                found.setdefault(kind, p)
            elif kind == "dmesg":
                found.setdefault(f"dmesg:{name}", p)
    return found


def pstore_archived_at():
    """When systemd-pstore ran THIS boot (unix s) - it archives whatever /sys/fs/pstore held at boot, so only records
    with a ctime after that are the previous boot's. None = it did not run (ConditionDirectoryNotEmpty failed: nothing
    survived the reset, e.g. a cold cut); "?" = systemctl could not say. The unit is Type=oneshot RemainAfterExit=yes,
    so the timestamp stays for the whole boot. Both it and the files' ctime were stamped by the same early-boot wall
    clock (this tablet's RTC reads 1970 at boot - inventory dmesg "setting system clock to 1970-01-06"; PID 1 then
    restores the clock from timesyncd's clock file), so comparing them survives the later NTP step."""
    out = run(["systemctl", "show", "-a", "--timestamp=unix", "-p", "LoadState", "-p", "ConditionResult",
               "-p", "ExecMainStartTimestamp", "systemd-pstore.service"])         # -a: empty properties are printed too
    props = dict(l.split("=", 1) for l in out.splitlines() if "=" in l)
    m = re.match(r"@(\d+)", props.get("ExecMainStartTimestamp", ""))
    if m:
        return int(m.group(1))
    if props.get("ConditionResult") == "no" or (props.get("LoadState") == "loaded" and not props.get("ExecMainStartTimestamp")):
        return None                                  # loaded but never ran this boot: ConditionDirectoryNotEmpty failed
    return "?"


def uptime_s():
    return float((read("/proc/uptime", "0 0") or "0 0").split()[0])


def mono_s():
    """CLOCK_MONOTONIC in seconds, the clock flightrec's energy line counts its t= in (ms). A function of its own so
    the selftest, which runs on Windows (no clock_gettime there), can replace it. /proc/uptime is not used: it is
    CLOCK_BOOTTIME, which only equals CLOCK_MONOTONIC while the tablet never suspends."""
    return time.clock_gettime(time.CLOCK_MONOTONIC)


def read_agreed(path, tries=4):
    """A file another process rewrites in place (flightrec's energy line: pwrite at offset 0, never a rename), taken
    only when two reads in a row return the same bytes - the reader rule acc.rs and DESIGN.md section 2 give, since a
    read that overlaps the pwrite can return half the old line and half the new. None: the file is missing; False: no
    two of `tries` reads agreed."""
    prev = None
    for _ in range(tries):
        try:
            with open(path, "rb") as f:
                data = f.read(4096)
        except FileNotFoundError:
            return None
        if data == prev:
            return data
        prev = data
    return False


def is_fresh(path, since, boot8):
    """Did this record arrive after `since` (unix s; None = nothing arrived this boot)? This boot's by construction:
    files in /sys/fs/pstore and the recorder's sysfs-* copies of them. Everything else is judged by the ctime of the
    systemd-pstore ORIGINAL (/var/lib/systemd/pstore/<name>) - the archive write; the record's own mtime is preserved
    and reads 1970 for ramoops console/pmsg, the panic time for dmesg records (cx-audit-2247.txt), so it dates nothing
    reliably. The recorder's copies must not be judged on their own: it re-copies
    the whole flat systemd directory every boot, the stale dmesg-ramoops-N from 10-11/10-13 included, and after a cold
    cut the stale console-ramoops-0 / pmsg-ramoops-0 too."""
    name = os.path.basename(path)
    mine = bool(boot8) and path.startswith(f"{FLIGHTREC}/pstore/{boot8}/")
    if path.startswith(PSTORE_DIRS[1] + "/") or (mine and name.startswith("sysfs-")):
        return True
    if since is None:
        return False
    orig = f"{PSTORE_DIRS[0]}/{name}" if path.startswith(f"{FLIGHTREC}/pstore/") else path
    try:
        return os.stat(orig if os.path.exists(orig) else path).st_ctime > since
    except OSError:
        return False


def record_head(path):
    """First line of a pstore dmesg record ("Panic#1 Part1" / "Oops#1 Part1"); .enc.z = the kernel could not
    decompress it (ramoops bit flips), still a panic record but no readable text."""
    return "压缩记录未解（.enc.z）" if path.endswith(".enc.z") else first_line(path)[:40]


def unclean_details(old, cur):
    """Why the previous boot ended: {'verdict': str, 'lines': [(kind, text)]} from the pstore console tail, the
    pstore panic records and the flight recorder's copies (pmsg ring archived? UFS log's last line?)."""
    boot8 = cur.get("boot8")
    prev8 = (cur.get("prev_boot") or "")[:8] or None
    at = pstore_archived_at()
    if isinstance(at, int):
        since = at - 5                               # archived this boot = the previous boot's records
    elif at is None:
        since = None
    else:                                            # systemctl could not say: the last --save; without one, this boot's start (true
        since = old.get("checked_at") or (time.time() - uptime_s() - 600)           # clock) less 10 min. Not max() of the two: the
        # early clock the archive's ctime was stamped with lags the true clock by the whole downtime (a dump-mode sit = hours), so a
        # floor at "boot - 10 min" would hide exactly the records such a sit leaves behind (2026-10-16 review)
    recs = pstore_records(boot8)
    fresh = {k: p for k, p in recs.items() if is_fresh(p, since, boot8)}
    lines, verdict = [], "死机或 SoC 复位"
    con = fresh.get("console")
    if con:
        text = tail_text(con)
        why = classify_console(text)
        verdict = "；".join(why) if why else "控制台末尾没有 panic/oops 文本——静默复位（固件/看门狗）或日志在复位前就断了"
        lines.append(("INFO", f"上一次开机的控制台尾部（{os.path.basename(con)}，{os.path.getsize(con)} B）：" + " ｜ ".join(console_tail(text))))
    elif at is None:
        verdict += "；开机时 /sys/fs/pstore 是空的（systemd-pstore 没跑）：冷切断/长按，或 ramoops 没挺过这次复位（PROTOCOL.md §8 问题 1）"
    else:
        verdict += "；pstore 里没有它的控制台（console-ramoops）：systemd-pstore 没搬到它，或归档被清过"
    dm = [p for k, p in sorted(fresh.items()) if k.startswith("dmesg:")]
    if dm:
        heads = [record_head(p) for p in dm[:2]]
        verdict += f"；pstore 有 {len(dm)} 份内核 dmesg 转储（{'、'.join(heads)}）＝内核自己 panic 过"
    # the flight recorder: did the previous boot's pmsg ring survive, and what was the last UFS line
    ufs = f"{FLIGHTREC}/flightrec-{prev8}.log" if prev8 else None
    ufs_last = last_line(ufs) if ufs and os.path.exists(ufs) else None
    pm = fresh.get("pmsg")
    installed = os.path.exists(FLIGHTREC_UNIT)
    if pm:
        lines.append(("INFO", f"飞行记录器：上一次的 pmsg 环挺过了复位并已归档（{os.path.basename(pm)} {os.path.getsize(pm)} B，"
                              f"尾行 {brief_flightrec(last_line(pm))}）"))
    elif installed and at is None:
        lines.append(("WARN", "上一次的 pmsg 环没有挺过这次复位（开机时 pstore 为空）：PROTOCOL.md §8 问题 1 的答案是「这类复位丢 DDR」，"
                              "以后只能靠记录器的 UFS 份和 rawdump"))
    elif installed:
        if run(["systemctl", "is-active", "y700-flightrec"]) != "active":
            lines.append(("WARN", "飞行记录器本次开机没在跑，没人把上一次的 pstore 记录拷到按 boot-id 的目录（systemctl status y700-flightrec）"))
        lines.append(("WARN", f"pstore 挺过了复位（systemd-pstore 本次开机搬了记录）但里面没有新的 pmsg-ramoops：复位前记录器没在写 pmsg"
                              "（没在跑，或 /dev/pmsg0 打不开；journalctl -b -1 -u y700-flightrec）"))
    else:
        lines.append(("INFO", "飞行记录器未安装，没有 pmsg 份可核对（linux/power/cx-collapse/y700-flightrec.service）"))
    if ufs_last:
        lines.append(("INFO", f"记录器 UFS 份 {os.path.basename(ufs)} 最后一行（复位前：实验时 ≤1 s、平时 ≤10 s，再加落盘延迟）：{brief_flightrec(ufs_last)}"))
    elif installed and prev8:
        lines.append(("INFO", f"记录器没有上一次开机的 UFS 份（{ufs}）：复位前它没在跑"))
    return {"verdict": verdict, "lines": lines}


def new_panic_records(old, cur):
    """(kind, text) for pstore dmesg-ramoops records written since the last --save, wherever they are - catches a panic
    followed by a clean reboot before the daily run (the previous-boot check would then say OK). Judged by the ctime of
    the systemd-pstore original (is_fresh), so the stale records the recorder re-copies every boot do not count.
    No checked_at in the baseline (first run of this version): INFO listing what is already there, not WARN."""
    boot8, since = cur.get("boot8"), old.get("checked_at")
    dm = sorted(p for k, p in pstore_records(boot8).items() if k.startswith("dmesg:") and is_fresh(p, since or 0, boot8))
    if not dm:
        return None
    head = record_head(dm[-1])
    if since is None:
        return ("INFO", f"pstore 里已有 {len(dm)} 份历史内核 panic/oops 转储（最新 {dm[-1]}，头行「{head}」）：记入基线时间，以后只报新的")
    return ("WARN", f"pstore 里有 {len(dm)} 份新的内核 panic/oops 转储（最新 {dm[-1]}，头行「{head}」）：journalctl -b -1 -k | tail；cat {dm[-1]} | tail -40")


def zink_programs(drirc):
    """Executable names an /etc/drirc text sends to zink: <application executable="..."> blocks with dri_driver zink."""
    names = []
    for blk in drirc.split("<application")[1:]:
        blk = blk.split("</application>")[0]
        m = re.search(r'executable="([^"]+)"', blk)
        if m and 'value="zink"' in blk:
            names.append(m.group(1))
    return names


def gpu_hangs(since, boot8):
    """GPU hangs in the kernel journal since `since` (epoch s), or in this boot when `since` is None. `journalctl -k`
    means -b (this boot) even with --since, so the kernel's lines are matched by _TRANSPORT=kernel, across every boot
    journald still has. Returns {"error": text} when the journal cannot be read, else {"n": hangs, "progs": {program:
    [count, first, last, [boot labels]]}, "flatpak": set, "procexe": set, "nocmd": set, "capped": bool, "boots": boots
    in the window, "oldest": the oldest boot journald kept, {"index", "start" (None when not a real time), "end"}, or
    None}. The kernel (msm recover_worker) prints "offending task: <comm> (<cmdline, NULs as spaces>)" or "offending
    task: unknown". A program is the basename of argv[0], the first field after "(" (what Mesa matches driconf's
    executable= against: the GPU thread's comm reads "steamweb:gdrv0"). The comm is up to 15 bytes and may hold spaces
    (Firefox's "Isolated Web Co"), so it is matched lazily up to " ("; without a "(" (a cut line) the whole rest is the
    comm, in "nocmd". argv[0] /proc/self/exe (zypak / flatpak Electron) would read "exe", the name Mesa sees too: such
    a program goes by its comm, in "procexe". A hang without an offending-task line counts as 未知.
    Capped with tail, not -n: systemd 259 prints nothing for --since together with -n and -g (10-23, on the tablet).
    The first lines of a boot carry the early clock (07-28, see below) and fall before any --since: a GPU hang needs the
    desktop up, long after timesyncd has set the clock."""
    where = f"--since @{int(since)}" if since else "-b 0"
    out = run(["sh", "-c", f"{{ journalctl --no-pager -q _TRANSPORT=kernel {where} -g '{GPU_HANG_GREP}' -o json "
                           f"--output-fields=MESSAGE,_BOOT_ID 2>&1; echo rc=$?; }} | tail -n {GPU_HANG_CAP + 1}"], timeout=60)
    lines = out.splitlines()
    rc = lines.pop()[3:] if lines and lines[-1].startswith("rc=") else None
    entries, other = [], []
    for l in lines:
        if l.startswith("{"):
            try:
                entries.append(json.loads(l))
                continue
            except ValueError:
                pass
        if l.strip():
            other.append(l.strip())
    # journalctl -g exits 1 both for "nothing matched" (silent with -q) and for a real failure (said on stderr)
    if rc not in ("0", "1") or (rc == "1" and not entries and other):
        return {"error": (other or [out or "没有输出"])[0][:100]}
    boots, oldest = {}, None
    try:
        listed = json.loads(run(["journalctl", "--list-boots", "-o", "json", "--no-pager", "-q"]) or "[]")
        boots = {b["boot_id"]: b for b in listed}
        if listed:
            o = min(listed, key=lambda b: b["index"])
            start, end = o["first_entry"] / 1e6, o["last_entry"] / 1e6
            # since 10-16 every boot's first entry reads 07-28 05:44 (the early clock before timesyncd's, RTC at 1970):
            # a "boot" longer than 30 days is that, not a start time
            oldest = {"index": o["index"], "start": start if end - start < 30 * 86400 else None, "end": end}
    except (ValueError, KeyError, TypeError):
        pass

    def label(bid):
        if boot8 and bid[:8] == boot8:
            return "本次开机"
        return f"开机 {boots[bid]['index']}" if bid in boots else f"开机 {bid[:8]}"
    recovers = lockups = 0
    progs, flatpak, procexe, nocmd = {}, set(), set(), set()
    for e in entries:
        msg = e.get("MESSAGE", "")
        if isinstance(msg, list):                   # journald's JSON gives a field that is not UTF-8 as a byte array
            msg = bytes(msg).decode("utf-8", "replace")
        if "hangcheck recover" in msg:
            recovers += 1
        elif "detected gpu lockup" in msg:
            lockups += 1
        m = re.search(r"offending task: (.+?) \((\S*)", msg) or re.search(r"offending task: (.+)$", msg)
        if not m:
            continue
        comm = m.group(1).strip()
        argv0 = (m.group(2) if m.re.groups > 1 else "").rstrip(")")
        prog = comm
        if re.fullmatch(r"/proc/(self|\d+)/exe", argv0):
            procexe.add(comm)
        elif argv0:
            prog = argv0.rsplit("/", 1)[-1] or comm
            if argv0.startswith("/app/"):            # a flatpak: it sees its runtime's /etc, not the host's drirc
                flatpak.add(prog)
        elif comm not in ("unknown", ""):
            nocmd.add(comm)
        prog = "未知" if prog in ("unknown", "") else prog
        t = int(e.get("__REALTIME_TIMESTAMP") or 0) / 1e6
        p = progs.setdefault(prog, [0, t, t, []])
        p[0], p[1], p[2] = p[0] + 1, min(p[1], t), max(p[2], t)
        b = label(e.get("_BOOT_ID", ""))
        if b not in p[3]:
            p[3].append(b)
    named = sum(p[0] for p in progs.values())
    n = max(recovers, lockups, named)                # the hangcheck timer path prints both lines for one hang
    if n > named:
        progs.setdefault("未知", [0, None, None, []])[0] += n - named
    window = sum(1 for b in boots.values() if b.get("last_entry", 0) / 1e6 >= since) if since else 1
    return {"n": n, "progs": progs, "flatpak": flatpak, "procexe": procexe, "nocmd": nocmd,
            "capped": len(entries) >= GPU_HANG_CAP, "boots": window, "oldest": oldest}


def rawdump_summary():
    """The Qualcomm "Raw_Dmp!" dump in the rawdump partition (XBL writes it in download mode, README 2026-10-15
    22:50). Returns None (no dump), "unreadable" (no partition / not root) or {hash, sections, kmsg_bytes, tail,
    regs}. hash = sha256 of the first 4 KiB of the header + the lastkmsg.log section, so a rewritten dump is
    seen even when its size is the same. Record walk as in tools/rawdump-ls.py (that file runs on import, so
    reimplemented): 64-byte records from 0x38: u32 flags, ver, type; u64 offset, size, base, reserved; name[20].
    Reads only the header, lastkmsg.log (<= 2 MiB) and 32 bytes of RST_STAT.BIN / PMIC_PON.BIN."""
    try:
        f = open(RAWDUMP, "rb")
    except OSError:
        return "unreadable"
    with f:
        hdr = f.read(0x10000)
        if hdr[:8] != b"Raw_Dmp!":
            return None
        secs, off = {}, 0x38
        while off + 0x40 <= len(hdr):
            _flags, _ver, _typ, soff, size, _base, _rsvd = struct.unpack_from("<IIIQQQQ", hdr, off)
            name = hdr[off + 0x2c:off + 0x40].split(b"\0")[0]
            if not name or not all(32 <= c < 127 for c in name):
                break
            secs[name.decode()] = (soff, size)
            off += 0x40

        def section(name, cap):
            if name not in secs:
                return b""
            soff, size = secs[name]
            f.seek(soff)
            return f.read(min(size, cap))

        kmsg = section("lastkmsg.log", 2 << 20)
        return {"hash": hashlib.sha256(hdr[:4096] + kmsg).hexdigest()[:16], "sections": len(secs), "kmsg_bytes": len(kmsg),
                "tail": console_tail(kmsg.decode("utf-8", "replace")),
                "regs": {n: (section(n, 32).hex() or ("空段" if n in secs else "无此段")) for n in ("RST_STAT.BIN", "PMIC_PON.BIN")}}


def main():
    save = "--save" in sys.argv
    old, bad = {}, None
    if os.path.exists(STATE):
        try:
            with open(STATE) as f:
                old = json.load(f)
            if not isinstance(old, dict):
                raise ValueError(f"不是 JSON 对象而是 {type(old).__name__}")
        except Exception as e:
            old, bad = {}, e                          # said below as a WARN, not passed off as a first run (10-31 audit C6)
    cur, ended = current()
    out, attention = [], False

    def say(kind, text):
        nonlocal attention
        out.append(f"{kind:8} {text}")
        if kind in ("CHANGED", "WARN"):
            attention = True

    def guard(name, fn):
        """A check that raises must not kill the run (main()'s try would exit 1 and hide every other line)."""
        try:
            fn()
        except Exception as e:
            say("WARN", f"检查「{name}」出错：{e!r}（体检脚本自己的问题，不是平板的）")

    # ---- what changed since the baseline, and what it needs
    if old:
        for p, v in cur["pkgs"].items():
            ov = old.get("pkgs", {}).get(p)
            if ov is None and p not in old.get("pkgs", {}):
                say("INFO", f"开始监视 {p} {v}")       # a package added to PACKAGES after the baseline
            elif ov != v:
                say("CHANGED", f"{p} {ov} -> {v}: {PACKAGES[p]}")
        if old.get("kernel") != cur["kernel"]:
            say("CHANGED", f"内核 {old.get('kernel')} -> {cur['kernel']}：确认是我们编的（官方内核会丢掉全部 y 修复）；"
                           "外部模块（ath12k、aw882xx）的 vermagic 要对得上；看门狗 grep 的报错字符串、kscreen-doctor 模式名看一眼")
        if old.get("tb323fu_mesa") != cur["tb323fu_mesa"]:
            say("CHANGED", f"上游 Mesa（Vulkan/Turnip）{old.get('tb323fu_mesa')} -> {cur['tb323fu_mesa']}：游戏和 /etc/drirc 走 zink 的"
                           "Chrome、ChatGPT、Steam 界面（steamwebhelper）都用它。游戏玩一会儿；三个程序各开一下用一会儿，"
                           "看它们 GPU 进程的 maps 里有 /var/lib/tb323fu/mesa 的 libvulkan_freedreno（zink 用的 Turnip），"
                           "journalctl -k 没有 hangcheck；没了的话 zink 会退回 Ubuntu 自带的 Turnip，三个都要复测")
        if old.get("fex") != cur["fex"]:
            say("CHANGED", "Steam 的 FEX 更新了：跑一次 fex-guest-test.sh 和 slr-chain-test.sh（README『Steam x86 Linux 原生游戏』）")
        if "livi" not in old:
            if cur["livi"]:
                say("INFO", f"开始监视 LIVI 版本 {cur['livi']}")
        elif old["livi"] != cur["livi"]:
            say("CHANGED", f"LIVI {old['livi']} -> {cur['livi']}：先把写死的 /opt/livi-<版本> 改成新目录（install-livi.sh 的 LIVI=、"
                           "y700-carplay、test-guard.sh 的 CORE/HELPER、dryrun-wireless.sh 的 CORE、dev.f-io.livi.desktop 的 Icon），"
                           "把仓库的 linux/carplay/livi/ 整个同步到平板，再重跑 install-livi.sh（会重写 sudoers）和 "
                           "dryrun-wireless.sh（dryrun.sh 自 10.0.0 起会让 bluetoothd 重启两次）；"
                           "确认 LIVI_GST_SINK、LIVI_GST_PRELOAD 两个口子还在（gst-host 的管线字符串和 LD_PRELOAD），"
                           "v4l2 解码器是否已经收 1:3:7:1（收了就不用色彩修正库）；热点单元的 drop-in 还挂得上（linux/carplay/README.md）")
    elif bad:
        say("WARN", f"基线 {STATE} 坏了（{bad}），这次只能当第一次运行，--save 时重建：和上次比的 CHANGED 都没了，"
                    "上次体检以来升过什么看 /var/log/apt/history.log")
    else:
        say("INFO", "第一次运行：建立基线（下次起报告变化）")

    # ---- how the boots since the last --save ended (each reported once). Not only the previous one (10-31 audit C2): the
    # check runs once a day, so a reset in boot X, a clean reboot in boot Y and the check in boot Z left X's reset unseen
    # (a silent reset with cx-auto off leaves neither a pstore panic record nor a rawdump). From the boot the last --save
    # ran in (its boot8 in the baseline: it ended since) to the previous one; when that boot is not in journald's list
    # (no baseline, journald rotated it away) the previous boot, once, as before. pstore holds only the last reset's
    # console, so an earlier boot gets no attribution beyond its flight recorder's last UFS line
    pos = next((i for i, b in enumerate(ended) if old.get("boot8") and b["boot_id"][:8] == old["boot8"]), None)
    todo = ended[pos:] if pos is not None else ended[-1:] if cur["prev_boot"] != old.get("prev_boot") else []
    clean_earlier = 0
    for b in todo[:-1]:
        clean, last = prev_boot_ending(b["boot_id"])
        if clean:
            clean_earlier += 1
            continue
        ufs_last = last_line(f"{FLIGHTREC}/flightrec-{b['boot_id'][:8]}.log")
        say("WARN", f"开机 {b['index']}（{b['boot_id'][:8]}，上次体检以来、上一次之前的）没有正常结束，日志停在 {last}：死机或 SoC 复位。"
                    "pstore 只留最近一次复位的控制台，它没有归因" + (f"；记录器 UFS 份最后一行 {brief_flightrec(ufs_last)}" if ufs_last else "")
                    + f"（journalctl -b {b['boot_id']} | tail）")
    if clean_earlier:
        say("OK", f"上次体检以来、上一次之前的 {clean_earlier} 次开机都是正常关机/重启的")
    if todo:
        clean, last = prev_boot_ending(todo[-1]["boot_id"])
        if clean:
            say("OK", f"上一次开机是正常关机/重启的（{last}）")
        else:
            det = {}
            guard("上次开机归因", lambda: det.update(unclean_details(old, cur)))
            say("WARN", f"上一次开机没有正常结束，日志停在 {last}：{det.get('verdict', '死机或 SoC 复位')}。"
                        "固件接手的复位会卡在转储界面耗电（y16 前关了 download_mode 也一样）；看 /var/lib/systemd/pstore、journalctl -b -1 | tail")
            for kind, text in det.get("lines", []):
                say(kind, text)

    # ---- current state
    k = cur["kernel"]
    if GOOD_KERNEL_TAG.search(k):
        say("OK", f"内核是我们编的 {k}")
    else:
        say("WARN", f"内核 {k} 不是我们编的 y 版本：官方内核会丢掉电池/Wi-Fi/视频/SSBS 等全部修复（tb323fu-ctl kernel rollback）")

    stamp = (slurp("/usr/local/share/y700-osk/oskgate.kwin-version") or "").strip() or None
    kv = cur["pkgs"]["kwin-wayland"]
    loaded = "true" in run(["busctl", "--user", "call", "org.kde.KWin", "/Effects", "org.kde.kwin.Effects", "isEffectLoaded", "s", "y700_oskgate"], user=True)
    if stamp != kv:
        say("WARN", f"键盘门卫特效是为 KWin {stamp} 编的，现在是 {kv}：自动重编没成功（journalctl -t y700-oskgate；手动 linux/osk/install.sh）")
    elif not loaded:
        say("WARN", "键盘门卫特效没加载（KWin 升级后要重新登录一次；否则键盘退回“获得焦点就弹”）")
    else:
        say("OK", "键盘门卫特效已加载，版本对得上")

    # Reinstalling a KWin plugin (install.sh, y700-oskgate-rebuild after a KWin upgrade, a hand `install`) unlinks
    # the file KWin has mapped: KWin keeps running the old code until the next login, and the fix just installed
    # silently does nothing (2026-10-21: the gate fix for the task-switcher cards). A library a package upgrade
    # replaced under KWin (Qt, Mesa) means the same: KWin needs a re-login to use the new one.
    def check_kwin_stale_libs():
        pid = session_kwin()
        if not pid:
            return
        gone = set()
        for line in (read(f"/proc/{pid}/maps", "") or "").splitlines():
            f = line.split(None, 5)
            if len(f) == 6 and f[5].endswith(" (deleted)") and f[5].startswith("/usr/") and ".so" in f[5]:
                gone.add(f[5][:-len(" (deleted)")])
        gate = {p for p in gone if p.endswith("/y700_oskgate.so")}
        if gate:
            say("WARN", "键盘门卫特效换了新版，KWin 还在跑换掉之前的那份：重新登录（或重启）之后新版才生效")
        if gone - gate:
            names = sorted(p.rsplit("/", 1)[-1] for p in gone - gate)
            say("WARN", f"KWin 还映射着 {len(names)} 个被升级替换掉的库（{'、'.join(names[:4])}{' 等' if len(names) > 4 else ''}）："
                        "重新登录一次才用上新版")
        if not gone:
            say("OK", "KWin 用的都是当前装着的库和插件")
    guard("KWin 旧库", check_kwin_stale_libs)

    # 10-22: a run-once self-check unit (/root/y700-glass-post.*) deleted its own unit file and ran daemon-reload while
    # it was still starting; systemd lost track of it, killed it at the default 90 s start timeout and kept it "failed",
    # so `systemctl is-system-running` said degraded for the rest of the boot and no check noticed. Any failed system or
    # user unit is worth a line now.
    # 11-03: KDE runs every app launch as a transient user unit app-<desktop id>@<32 hex>.service, and one that exits
    # non-zero stays "failed" until reboot. That is the app's business, not a broken service: bluedevil-wizard exits 1
    # after a successful pairing (QDialog::Accepted), the owner's battery-notify shortcut pressed fast hits Plasma's
    # flood limit. Those get one INFO line per app; anything else still WARNs.
    def check_failed_units():
        found, apps, unknown = [], {}, False
        for scope, cmd, user in (("系统", ["systemctl", "--failed", "--no-legend", "--plain", "--no-pager"], False),
                                 ("用户", ["systemctl", "--user", "--failed", "--no-legend", "--plain", "--no-pager"], True)):
            txt = run(cmd, user=user)
            if txt.startswith("ERROR"):
                say("INFO", f"查不了{scope}的失败服务（{txt[:80]}）")
                unknown = True
                continue
            for name in [l.split()[0] for l in txt.splitlines() if l.strip()]:
                m = user and re.fullmatch(r"app-(.+)@[0-9a-f]{32}\.service", name)
                if m:
                    app = m[1].replace("\\x2d", "-")
                    apps[app] = apps.get(app, 0) + 1
                else:
                    found.append(f"{scope} {name}")
        if apps:
            say("INFO", "应用启动后退出码非 0（KDE 每开一次应用就起一个临时单元，不算服务坏了）："
                        + "、".join(f"{a} ×{n}" for a, n in sorted(apps.items()))
                        + "（systemctl --user status 'app-…' 看原因；systemctl --user reset-failed 清掉）")
        if found:
            say("WARN", f"有失败的服务：{'、'.join(found[:8])}{' 等' if len(found) > 8 else ''}"
                        "（systemctl [--user] status <名字> 看原因；处理完 systemctl [--user] reset-failed <名字>）")
        elif not unknown:
            say("OK", "没有失败的系统或用户服务")
    guard("失败的服务", check_failed_units)

    # the bottom-edge home gesture (linux/gesture, 2026-10-17): KWin's own touch edge, armed by our script.
    # The owner's symptom "swiping up from the bottom does nothing" = the script is not loaded, the fullscreen
    # switch is off, or the script left the edge off with neither the keyboard nor the control centre up.
    # Since 2026-10-21 the edge can belong to the y700-taskswitcher effect instead (Plasma Mobile's task
    # switcher, linux/gesture/taskswitcher): kwinrc [Script-y700-home] BottomEdge=false, and the same
    # logged-state-vs-blockers check runs on the effect's "y700-taskswitcher: bottom edge" lines.
    def edge_matches_blockers(tag):
        """(on, blocker, last line) once the two reads agree in time, or None if KWin won't run the probe"""
        for attempt in (1, 2):              # the owner may open or close the keyboard between the two reads
            edge = run(["sh", "-c", f"journalctl --user -b --no-pager -o cat | grep -F '{tag}: bottom edge' | tail -1"], user=True)
            up = kwin_js("out(workspace.windowList().some(function (w) { return w.inputMethod || "
                         "['y700-osk', 'y700-control-center'].indexOf(w.resourceClass) >= 0; }))")
            if up is None or not up:
                return None
            on, blocker = edge.endswith(" on"), up[0] == "true"
            if on != blocker:
                break
            time.sleep(1.5)
        return on, blocker, edge

    def check_home_gesture():
        if not os.path.exists("/home/user/.local/share/kwin/scripts/y700-home"):
            return
        if "true" not in run(["busctl", "--user", "call", "org.kde.KWin", "/Scripting", "org.kde.kwin.Scripting",
                              "isScriptLoaded", "s", "y700-home"], user=True):
            say("WARN", "底边上滑手势的 KWin 脚本 y700-home 没加载（sh linux/gesture/install.sh；journalctl --user -b | grep y700-home）")
            return
        remain = run(["kreadconfig6", "--file", "kwinrc", "--group", "ScreenEdges", "--key", "RemainActiveOnFullscreen"], user=True)
        if remain != "true":
            say("WARN", f"kwinrc [ScreenEdges] RemainActiveOnFullscreen 是「{remain}」：全屏窗口上底边手势和左右边缘返回键都不灵（linux/gesture/install.sh）")
            return
        if run(["kreadconfig6", "--file", "kwinrc", "--group", "Script-y700-home", "--key", "BottomEdge"], user=True) == "false":
            check_taskswitcher()
            return
        st = edge_matches_blockers("y700-home")
        if st is None:
            say("WARN", "底边上滑手势：KWin 不肯跑检查脚本，没法确认手势状态")
            return
        on, blocker, edge = st
        if on and not blocker:
            say("OK", "底边上滑手势就绪（y700-home 已加载、全屏下也生效）")
        elif blocker and not on:
            say("OK", "底边上滑手势已加载，现在屏幕键盘或控制中心开着，手势按设计暂停")
        else:
            say("WARN", f"底边上滑手势状态不对：脚本最后记的是「{edge or '没有记录'}」，键盘/控制中心{'开着' if blocker else '都没开'}"
                        "（重装 linux/gesture/install.sh 会重载脚本）")

    # the task switcher cards (2026-10-21). Besides loaded / edge state: KWin keeps the QML it compiled
    # first, so after a reinstall or a plasma-mobile upgrade the running build (logged at load) can differ
    # from the installed one until the next login - on 10-21 that hid a "close all" that closed games.
    def check_taskswitcher():
        fxdir = "/home/user/.local/share/kwin/effects/y700-taskswitcher"
        if "true" not in run(["busctl", "--user", "call", "org.kde.KWin", "/Effects", "org.kde.kwin.Effects",
                              "isEffectLoaded", "s", "y700-taskswitcher"], user=True):
            say("WARN", "多任务卡片特效 y700-taskswitcher 没加载，底边上滑没反应（sh linux/gesture/taskswitcher/install.sh；"
                        "journalctl --user -b | grep -iE 'taskswitcher|qml'）")
            return
        m = re.search(r'y700Build: "([^"]*)"', slurp(fxdir + "/contents/ui/main.qml", ""))
        want = m.group(1) if m else ""
        got = run(["sh", "-c", "journalctl --user -b --no-pager -o cat | grep -F 'y700-taskswitcher: loaded' | tail -1"], user=True)
        got = got.rsplit(" ", 1)[-1] if got else ""
        if not want or got != want:
            say("WARN", f"多任务卡片：KWin 里跑的是「{got or '没有记录'}」，装着的是「{want or '读不到'}」——"
                        "KWin 只认第一次加载的 QML，新版要重新登录（或重启）才生效")
            return
        if run(["kreadconfig6", "--file", "plasmamobilerc", "--group", "General", "--key", "navigationPanelEnabled"], user=True) != "false":
            say("WARN", "plasmamobilerc [General] navigationPanelEnabled 不是 false：多任务卡片的底边手势被上游关掉了（重跑 taskswitcher/install.sh）")
            return
        st = edge_matches_blockers("y700-taskswitcher")
        if st is None:
            say("WARN", "多任务卡片：KWin 不肯跑检查脚本，没法确认手势状态")
            return
        on, blocker, edge = st
        if on and not blocker:
            say("OK", f"多任务卡片就绪（{want}，全屏下也生效）")
        elif blocker and not on:
            say("OK", "多任务卡片已加载，现在屏幕键盘或控制中心开着，底边手势按设计暂停")
        else:
            say("WARN", f"多任务卡片手势状态不对：特效最后记的是「{edge or '没有记录'}」，键盘/控制中心{'开着' if blocker else '都没开'}"
                        "（重新登录会重载特效）")
    guard("底边上滑手势", check_home_gesture)

    # a swiped-away card quits its app (2026-10-31, linux/gesture/taskswitcher/appquit.py): the effect starts
    # y700-appquit@PID_....service over D-Bus and the unit is collected as soon as it ends, so a missing piece or a
    # failed quit only shows in the journal. Silent when all is well (a quit that had nothing to do is no failure).
    def check_appquit():
        if not os.path.exists("/home/user/.local/share/kwin/effects/y700-taskswitcher/contents/ui/AppQuit.qml"):
            return
        missing = [p for p in ("/usr/local/libexec/y700-appquit", "/home/user/.config/systemd/user/y700-appquit@.service")
                   if not os.path.exists(p)]
        if missing:
            say("WARN", f"划走卡片只关窗口、不退程序：{'、'.join(missing)} 不在（重跑 linux/gesture/taskswitcher/install.sh）")
            return
        bad = run(["sh", "-c", "journalctl --user -b --no-pager -o cat | grep -cE "
                   "'y700-taskswitcher: app quit: StartUnit failed|y700-appquit@[0-9_]+[.]service: Failed with result'"], user=True)
        if bad.isdigit() and int(bad) > 0:
            say("WARN", f"划走卡片退出程序这次开机失败了 {bad} 次（journalctl --user -b | grep -E 'app quit|y700-appquit'）")
    guard("划走退出程序", check_appquit)

    # y700-gamepad-screen (linux/gamepad/screen, 11-01): until then it fought y700-padkeys for the G9's joystick node every
    # 5 s while the screen was dark, a traceback each time (17k journal lines a boot) and no wake from the pad's buttons.
    # Now one line per distinct error, so many lines mean something loops again. Counted since the service last started
    # (its invocation id), so a restart onto a fixed build clears it. Silent when all is well.
    # 11-03 it became Rust: the binary must be an ELF (a script there is the Python version back, i.e. a rollback), and
    # a panic shows as automatic restarts (Restart=on-failure; NRestarts starts from 0 at a manual restart and a boot).
    def check_gamepad_screen():
        b = "/usr/local/libexec/y700-gamepad-screen"
        try:
            elf = open(b, "rb").read(4) == b"\x7fELF"
        except OSError:
            return
        if not elf:
            say("WARN", f"G9 息屏服务 {b} 不是编译好的 Rust 程序（11-03 起是 Rust；回滚到 Python 版才会这样；"
                        "在平板上重跑 y700/linux/gamepad/screen/install.sh）")
            return
        n = run(["sh", "-c", "journalctl -b -u y700-gamepad-screen "
                 "_SYSTEMD_INVOCATION_ID=$(systemctl show -p InvocationID --value y700-gamepad-screen) "
                 "--no-pager -o cat | grep -c 'G9 lighting/wake handling failed'"])
        r = run(["systemctl", "show", "-p", "NRestarts", "--value", "y700-gamepad-screen"])
        if n.isdigit() and int(n) > 20:
            say("WARN", f"G9 息屏服务这次启动以来报错 {n} 次，手柄按键可能亮不了屏、日志在刷（journalctl -b -u y700-gamepad-screen；"
                        "README『G9 息屏关灯与按键亮屏』）")
        elif r.isdigit() and int(r) > 5:
            say("WARN", f"G9 息屏服务自动重启了 {r} 次（本次开机或上次手动重启以来），Rust 版崩了才会这样"
                        "（journalctl -b -u y700-gamepad-screen | grep panicked）")
    guard("G9 息屏服务", check_gamepad_screen)

    # the installed /etc/drirc against the repo's list (DRIRC_ZINK = linux/gpu/drirc, the selftest holds them equal): a
    # program rolled back on the tablet only, or added there only, is said every day until the repo says the same
    zinked = zink_programs(slurp("/etc/drirc", "") or "")
    missing = [p for p in DRIRC_ZINK if p not in zinked]
    extra = [p for p in zinked if p not in DRIRC_ZINK]
    if missing:
        say("WARN", f"/etc/drirc 里没有 {'、'.join(missing)}→zink：会回到会卡死 GPU 的 freedreno GL。不是有意的就装回 y700/linux/gpu/drirc；"
                    "有意撤掉的话，仓库 linux/gpu/drirc 和体检的 DRIRC_ZINK 都删掉它，两边都重装（README『Chrome 让 GPU 卡死』）")
    if extra:
        say("WARN", f"/etc/drirc 比仓库多了 {'、'.join(extra)}→zink：把它连同加入日期写进 y700/linux/gpu/drirc 和体检的 DRIRC_ZINK，"
                    "两边都重装（README『Chrome 让 GPU 卡死』）")
    if not missing and not extra:
        say("OK", f"{'、'.join(DRIRC_ZINK)} 走 zink（/etc/drirc，和仓库的名单一致）")

    # Chromium's frame-callback-driven begin-frame source (2026-10-18, linux/power/chromium-bfs.py): without it Chrome /
    # Claude keep their GPU-process compositor ticking at refresh rate while KWin has the window suspended (screen off),
    # which keeps the system domain from powering down (README "Chromium 新帧源开关")
    def check_bfs():
        feat = "WaylandExternalBeginFrameSource"
        wrapper = read("/usr/local/bin/claude-desktop")
        launchers = {f: read(f"/home/user/{f}") or "" for f in (
            ".local/share/applications/google-chrome.desktop", ".local/share/applications/com.google.Chrome.desktop",
            "Desktop/google-chrome.desktop")}
        if wrapper is None and not any(feat in t for t in launchers.values()):
            return                      # never installed, or taken out with chromium-bfs.py --undo: nothing to say
        bad = []
        if feat not in (wrapper or ""):
            bad.append("/usr/local/bin/claude-desktop 没了或不带开关")
        for f, text in launchers.items():
            if any(feat not in ln for ln in text.splitlines()
                   if re.match(r"Exec=(env \S+ )*(/usr/bin/google-chrome|/opt/google/chrome/)", ln)):
                bad.append(f"~/{f} 有启动行不带开关")
        # a running one without it: started from another launcher, or the app overwrote the switch. Chrome: look at the
        # browser process (no --type=), not the GPU process - Google runs a Finch study on this feature, and with the
        # owner's seed a command-line-forced feature reaches the children as field-trial state (ForcedOn_ group), so it
        # is missing from the GPU process's --enable-features although it works (10-18 13:14, bfsprop2.sh: 0.0 vs 60.1
        # wakeups/s). Claude (Electron, no Finch): the GPU process, which shows the app really passed it on.
        for exe, name, ptype in (("/opt/google/chrome/chrome", "Chrome", None),
                                 ("/usr/lib/claude-desktop/claude-desktop", "Claude", "gpu-process")):
            for p in glob.glob("/proc/[0-9]*"):
                try:
                    if os.readlink(p + "/exe") != exe:
                        continue
                    cmd = open(p + "/cmdline", "rb").read().replace(b"\0", b" ").decode(errors="replace")
                except OSError:
                    continue
                t = re.search(r"--type=([a-z-]+)", cmd)
                if (t.group(1) if t else None) == ptype and feat not in cmd:
                    bad.append(f"正在跑的 {name} 没带开关（从别的入口开的？完全退出后从菜单重开）")
                    break
        if bad:
            say("WARN", "Chromium 新帧源开关：" + "；".join(bad) + "（重跑 linux/power/chromium-bfs.py）")
        else:
            say("OK", "Chrome / Claude 带 WaylandExternalBeginFrameSource 启动（熄屏时合成线程不空转）")
    guard("Chromium 新帧源开关", check_bfs)

    # ChatGPT (OpenAI's Electron app, 2026-10-22, linux/daily/chatgpt-wayland-ime.sh): the deb's launcher runs it on
    # XWayland with GTK3 and no IM module, so the screen keyboard never pops in its chat box. The user-level override
    # (same id) and the desktop icon start it as a Wayland client with Chromium's IME switches; both are the deb's
    # entry with the Exec line changed, so a deb upgrade that rewrites the entry shows up here as a mismatch.
    def check_chatgpt_ime():
        sys_entry = read("/usr/share/applications/chatgpt.desktop")
        if sys_entry is None:
            return                      # not installed
        flags = "--ozone-platform=wayland --enable-wayland-ime --wayland-text-input-version=3"
        expect = re.sub(r"^(Exec=[^ ]*chatgpt)( .*)?$", lambda m: m.group(1) + " " + flags + (m.group(2) or ""),
                        sys_entry, flags=re.M)
        bad = []
        for f in (".local/share/applications/chatgpt.desktop", "Desktop/chatgpt.desktop"):
            text = read(f"/home/user/{f}")
            if text is None:
                bad.append(f"~/{f} 没了")
            elif "--enable-wayland-ime" not in text:
                bad.append(f"~/{f} 的启动行不带 IME 参数")
            elif text != expect:
                bad.append(f"~/{f} 和 deb 的桌面项对不上（ChatGPT 升级改了桌面项？）")
        if bad:
            say("WARN", "ChatGPT 启动项：" + "；".join(bad) + "（屏幕键盘在它的输入框不弹；重跑 /root/daily/chatgpt-wayland-ime.sh）")
            return
        running = None                  # the browser process (no --type=), if one is up
        for p in glob.glob("/proc/[0-9]*"):
            try:
                if os.readlink(p + "/exe") != "/usr/lib/chatgpt/ChatGPT":
                    continue
                cmd = open(p + "/cmdline", "rb").read().replace(b"\0", b" ").decode(errors="replace")
            except OSError:
                continue
            if "--type=" in cmd:
                continue
            running = cmd
            break
        if running is not None and "--enable-wayland-ime" not in running:
            say("WARN", "正在跑的 ChatGPT 没带 IME 参数（从别处启动的，或改启动项前就开着）：退出它再从图标开一次，键盘才会在输入框弹")
        else:
            say("OK", "ChatGPT 启动项带 Wayland IME 参数" + ("，正在跑的也带" if running else ""))
    guard("ChatGPT 屏幕键盘", check_chatgpt_ime)

    # X11 apps' scale (2026-10-29, README "Steam 字太小"): kwinrc [Xwayland] Scale means "X11 apps scale themselves", and
    # Steam (the only X11 client here) takes its scale from Xft.dpi in the Xwayland resource database. KWin writes it at
    # every Xwayland start (kcminit -> xrdb -merge, int(Scale x 96) = 182 at 1.9) while Ubuntu's Xwayland-session.d/00-xrdb
    # merges /etc/X11/Xresources and ~/.Xresources at the same moment; on 10-29 the database held only 00-xrdb's line and
    # Steam drew at 1x. ~/.Xresources carries the value too, so whichever writer lands last has it. The live database is
    # read only while Xwayland runs (KWin starts it on demand: our xrdb must not be what starts it).
    def check_xft_dpi():
        scale = run(["kreadconfig6", "--file", "kwinrc", "--group", "Xwayland", "--key", "Scale"], user=True)
        try:
            want = int(float(scale) * 96)
        except ValueError:
            return                      # KWin scales Xwayland itself (or no session): no X11 app reads Xft.dpi for it
        if want <= 96:
            return                      # 1x: an X11 app without Xft.dpi draws at the right size anyway
        bad, notes, steam, where = [], [], None, "~/.Xresources 的 Xft.dpi 是"
        m = re.search(r"^Xft\.dpi:\s*(\S+)", read("/home/user/.Xresources") or "", re.M)
        if not m:
            bad.append("~/.Xresources 里没有 Xft.dpi（Xwayland 启动时它被挤掉就没有兜底）")
        elif m.group(1) != str(want):
            bad.append(f"~/.Xresources 写的 Xft.dpi 是 {m.group(1)}，显示缩放 {scale} 要 {want}（改了显示缩放要一起改）")
        if not run(["pidof", "Xwayland"]):
            notes.append("Xwayland 没在跑，实时库没查")
        else:
            env = dict(ln.split("=", 1) for ln in run(["systemctl", "--user", "show-environment"], user=True).splitlines()
                       if "=" in ln)
            q = ""
            if env.get("DISPLAY"):
                xenv = [f"DISPLAY={env['DISPLAY']}"] + ([f"XAUTHORITY={env['XAUTHORITY']}"] if env.get("XAUTHORITY") else [])
                q = run(["env"] + xenv + ["sh", "-c", "xrdb -query; echo xrdb-rc=$?"], user=True)
            if "xrdb-rc=0" not in q:
                say("INFO", "X11 程序缩放：读不到 Xwayland 的资源库（会话环境里没有 DISPLAY，或 xrdb 连不上），实时的 Xft.dpi 没查")
            else:
                got = re.search(r"^Xft\.dpi:\s*(\S+)", q, re.M)
                where = "实时库和 ~/.Xresources 的 Xft.dpi 都是"
                if not got or got.group(1) != str(want):
                    bad.append(("实时库里没有 Xft.dpi" if not got else f"实时库里 Xft.dpi 是 {got.group(1)}") + f"（要 {want}），"
                               "之后打开的 Steam 会画小：以 user 在会话环境里跑 "
                               "QT_QPA_PLATFORM=wayland kcminit kcm_fonts_init kcm_style_init，再完全退出 Steam 重开")
        if run(["pidof", "steam"]):     # the scale Steam's browser picked at its start: its GPU log's display line
            try:
                found = re.findall(r"Display\[\d+\] bounds=[^\n]*?scale=([\d.]+)",
                                   tail_text("/home/user/.local/share/Steam/logs/webhelper_gpu.txt", 4 << 20))
            except OSError:
                found = []
            if found:
                steam = float(found[-1])
                if steam < want / 96 - 0.05:
                    bad.append(f"正在跑的 Steam 按 {steam:g} 倍画（它启动时库里还没有 Xft.dpi）：Steam 菜单里退出 Steam 再开")
        if bad:
            say("WARN", "X11 程序缩放（Steam 字小）：" + "；".join(bad) + "（README『Steam 字太小』）")
        else:
            say("OK", f"X11 程序缩放：{where} {want}（= Xwayland 缩放 {scale} × 96）"
                + "".join(f"，{n}" for n in notes) + ("" if steam is None else f"，Steam 按 {steam:g} 倍画"))
    guard("X11 程序缩放", check_xft_dpi)

    # the panel's physical size as the kernel reports it (kernel y18, upstream 0144, linux/kernel-y18/NOTES.md): 118 x 190 mm
    # since y18, a 12.4" panel's 168 x 268 before. KWin keeps its saved output config (scale 1.9) either way - the size only
    # feeds the default scale of an output without one and the tablet/touch-to-output mapping - so the scale is printed,
    # not judged: a scale that moved with a kernel change is what to look at (README「Steam 字太小」, check_xft_dpi above)
    def check_panel_size():
        ky = re.search(r"-y(\d+)$", cur["kernel"])
        try:
            # a Qt GUI app: without WAYLAND_DISPLAY it tries xcb and exits (11-04 on the tablet); KWin's socket is wayland-0
            j = run(["env", "WAYLAND_DISPLAY=wayland-0", "kscreen-doctor", "-j"], user=True)
            outs = [o for o in json.loads(j)["outputs"] if o.get("connected") and "DSI" in o.get("name", "")]
        except (ValueError, KeyError, TypeError):
            say("INFO", "面板尺寸：kscreen-doctor -j 读不到输出列表（桌面会话没起来？），这项没查")
            return
        if len(outs) != 1:
            say("INFO", f"面板尺寸：kscreen-doctor 里连着的 DSI 输出有 {len(outs)} 个，这项没查")
            return
        mm = outs[0].get("sizeMM") or {}
        size, sc = f"{mm.get('width')} × {mm.get('height')} mm", outs[0].get("scale")
        if not ky or int(ky.group(1)) < PANEL_MM_FIRST_Y:
            say("INFO", f"面板尺寸：内核报 {size}（y{PANEL_MM_FIRST_Y} 前的内核报的是 12.4 寸屏的 168 × 268；"
                        f"y{PANEL_MM_FIRST_Y} 起 118 × 190），显示缩放 {sc}")
        elif (mm.get("width"), mm.get("height")) == (118, 190):
            say("OK", f"面板尺寸：内核报 {size}（y{PANEL_MM_FIRST_Y} 起的真实尺寸），显示缩放 {sc}")
        else:
            say("WARN", f"面板尺寸：{cur['kernel']} 该报 118 × 190 mm，KWin 看到的是 {size}（上游 0144 没在这个内核里？"
                        f"linux/kernel-y18/NOTES.md），显示缩放 {sc}")
    guard("面板尺寸", check_panel_size)

    # zram B (2026-11-04, the owner's choice over installing tb323fu-platform 0.4.6; README「内核 y19」): /dev/zram0 is the
    # only swap and as big as RAM (zram-generator.conf zram-size = ram), zstd; vm.swappiness 100 and vm.page-cluster 0 come
    # from /etc/sysctl.d/90-y700-zram.conf. Each line below names the file to look at; no swap at all is its own WARN (a
    # broken zram-generator.conf leaves the tablet without swap, silently)
    def check_zram():
        swaps = [l.split() for l in (read("/proc/swaps") or "").splitlines()[1:] if l.strip()]
        if not swaps:
            say("WARN", "zram：/proc/swaps 里没有任何 swap——systemd-zram-setup@zram0 没起来（systemctl status 它；"
                        "/etc/systemd/zram-generator.conf 写坏了也是这样，README「内核 y19」zram 一段）")
            return
        bad, z = [], [s for s in swaps if s[0] == "/dev/zram0"]
        if len(swaps) != 1 or not z:
            bad.append("swap 不是只有 zram0：" + "、".join(s[0] for s in swaps))
        try:
            mt = int(re.search(r"^MemTotal:\s+(\d+)", read("/proc/meminfo") or "", re.M).group(1)) * 1024
            ds = int(read("/sys/block/zram0/disksize") or 0)
        except (AttributeError, ValueError):
            mt, ds = 0, 0
            bad.append("读不到 /proc/meminfo 的 MemTotal 或 /sys/block/zram0/disksize")
        if abs(ds - mt) >= 2 << 20:       # zram-generator: ram = MemTotal in MiB, so disksize = MemTotal up to a page
            bad.append(f"zram0 {ds / 2**30:.1f} GiB，内存 {mt / 2**30:.1f} GiB：/etc/systemd/zram-generator.conf 的 zram-size 不是 ram"
                       "（改回半内存了？改完要 daemon-reload + restart systemd-zram-setup@zram0）")
        if "[zstd]" not in (read("/sys/block/zram0/comp_algorithm") or ""):
            bad.append("zram0 的压缩算法不是 zstd（/etc/systemd/zram-generator.conf 的 compression-algorithm）")
        sw, pc = read("/proc/sys/vm/swappiness"), read("/proc/sys/vm/page-cluster")
        if (sw, pc) != ("100", "0"):
            bad.append(f"vm.swappiness {sw}、vm.page-cluster {pc}（要 100、0）：/etc/sysctl.d/90-y700-zram.conf 没了或没生效（sysctl --system）")
        if bad:
            say("WARN", "zram：" + "；".join(bad) + "（README「内核 y19」zram 一段）")
        else:
            say("OK", f"zram：zram0 {ds / 2**30:.1f} GiB = 整个内存，zstd，优先级 {z[0][4]}；swappiness 100、page-cluster 0")
    guard("zram", check_zram)

    # Magic Mouse 2 (2026-11-04, README「Magic 键鼠」): the driver hid-magicmouse is the kernel's own module from y20 on
    # (CONFIG_HID_MAGICMOUSE=m); on y19 it is the out-of-tree build /usr/local/lib/y700-extra-modules/<release>/
    # hid-magicmouse.ko that 90-y700-magicmouse.rules loads through /usr/local/sbin/y700-extra-modules. Without either the
    # mouse binds to hid-generic and has no scrolling. Files only: the hid devices' uevent (HID_ID, DRIVER), the module
    # files, the module parameters. A tablet without the two transition files never had the mouse set up: no item.
    def check_magicmouse():
        rule = read("/etc/udev/rules.d/90-y700-magicmouse.rules") is not None
        loader = read("/usr/local/sbin/y700-extra-modules") is not None
        if not rule and not loader:
            return
        rel = cur["kernel"]
        intree = os.path.exists(f"/lib/modules/{rel}/kernel/drivers/hid/hid-magicmouse.ko")
        extra = os.path.exists(f"/usr/local/lib/y700-extra-modules/{rel}/hid-magicmouse.ko")
        src = "内核自带" if intree else ("树外 /usr/local/lib/y700-extra-modules/" if extra else "")
        bad = []
        if not (rule and loader):
            bad.append("90-y700-magicmouse.rules 和 /usr/local/sbin/y700-extra-modules 少了一个（sh linux/owner-devices/install.sh）")
        if not src:
            bad.append(f"内核 {rel} 没带 hid-magicmouse，/usr/local/lib/y700-extra-modules/{rel}/ 也没有——换内核忘了带（y20 起内核自带）")
        mice = []
        for ue in glob.glob("/sys/bus/hid/devices/*/uevent"):
            u = read(ue) or ""
            if re.search(r"^HID_ID=000[35]:0000(004C|05AC):00000269$", u, re.M):
                drv = re.search(r"^DRIVER=(.*)$", u, re.M)
                mice.append(drv.group(1) if drv else "（没绑驱动）")
        for drv in mice:
            if drv != "magicmouse":
                bad.append(f"鼠标接着，驱动却是 {drv}（没滚轮）：hid-magicmouse 没装上去（手跑 /usr/local/sbin/y700-extra-modules hid-magicmouse 看报错）")
        acc = read("/sys/module/hid_magicmouse/parameters/scroll_acceleration")
        if acc is not None and acc.strip() != "Y":
            bad.append(f"hid_magicmouse scroll_acceleration={acc.strip()}（要 Y）：/etc/modprobe.d/hid_magicmouse.conf 没了或没生效")
        fn = read("/sys/module/hid_apple/parameters/fnmode")
        if fn is not None and fn.strip() != "2":
            bad.append(f"hid_apple fnmode={fn.strip()}（要 2，F 键是 F 键）：/etc/modprobe.d/hid_apple.conf 没了或没生效")
        if bad:
            say("WARN", "Magic 鼠标驱动：" + "；".join(bad) + "（README「Magic 键鼠」）")
        else:
            say("OK", "Magic 鼠标驱动：" + (f"接着 {len(mice)} 个，驱动 magicmouse" if mice else "没接") + f"；hid-magicmouse {src}，规则和加载脚本在")
    guard("Magic 鼠标驱动", check_magicmouse)

    # Bluetooth firmware (11-05, README「每日体检」): hci_qca loads qca/brhbtfw20.mbn + brhbtnv20.bin into the chip; when
    # that fails (file missing: ArmadaOS shipped without them, armadaos-freedom fefd745b) qca_setup carries on with the
    # chip's ROM firmware ("run with original fw/config") and Bluetooth still pairs, so only the kernel log tells.
    # Every setup of this boot counts (the tablet sets the chip up twice per boot, both complete when all is well).
    def check_bt_firmware():
        # -q like the other journalctl -g calls: the default output prints "-- No entries --" on no match (-o cat does
        # not, tablet 11-05). -g exits 1 both for "nothing matched" and for a real failure (said on stderr): with run()
        # a failure read as "no Bluetooth this boot" and the item silently vanished (11-05 review)
        rc, out, err = run_rc(["journalctl", "-k", "-b", "--no-pager", "-q", "-o", "cat", "-g", BT_GREP])
        if rc not in (0, 1) or (rc == 1 and err):
            say("INFO", f"蓝牙固件：查不了，journalctl 没答上来（{err or out or ('超时' if rc is None else rc)}）")
            return
        # One "setting up" per setup. An error other than -ENOENT / -EAGAIN retries inside the same setup (no new
        # "setting up"), so a "QCA Failed to" line followed by a completion is a hiccup, not the ROM fallback. The chip
        # runs what the LAST setup ended with: a completion = the downloaded firmware; a (-2) / (-11) failure = ROM
        # firmware (hci_qca sets QCA_ROM_FW and carries on); any other failure last = that setup gave up
        segs = []
        for l in out.splitlines():
            if "setting up" in l or not segs:
                segs.append([])
            segs[-1].append(l)
        if not segs:
            return                      # no Bluetooth chip set up this boot: nothing to judge
        ends = [next((l.split(": ", 1)[-1] for l in reversed(s) if "QCA Failed to" in l or "setup on UART is completed" in l), "")
                for s in segs]
        done = sum("setup on UART is completed" in e for e in ends)
        ver = [l.split("QCA FW build version: ", 1)[1].split()[0] for l in segs[-1] if "QCA FW build version: " in l]
        errs = [l.split(": ", 1)[-1] for l in out.splitlines() if "QCA Failed to" in l]
        last = ends[-1]
        if "QCA Failed to" in last and ("(-2)" in last or "(-11)" in last):
            say("WARN", f"蓝牙固件没加载上，芯片在用自带的旧固件跑：{last}（ls /lib/firmware/qca/brhbt*；linux-firmware 包；"
                        "journalctl -k -b | grep hci0）")
        elif "QCA Failed to" in last:
            say("WARN", f"蓝牙芯片最后一次初始化失败：{last}（journalctl -k -b | grep hci0）")
        elif not last or not ver:
            say("WARN", f"蓝牙芯片最后一次初始化没走完：这次开机初始化 {len(segs)} 次，完成 {done} 次、"
                        f"固件版本 {ver[-1] if ver else '没报'}（journalctl -k -b | grep hci0）")
        else:
            clean = done == len(segs) and not errs
            say("OK", f"蓝牙固件 {ver[-1]}，这次开机初始化 {len(segs)} 次" + ("都加载上了" if clean else "，最后一次加载上了"))
            if not clean:
                say("INFO", "蓝牙：这次开机的初始化出过岔子、后来好了："
                            + (errs[-1] if errs else f"{len(segs) - done} 次没走完") + "（journalctl -k -b | grep hci0）")
    guard("蓝牙固件", check_bt_firmware)

    # The bottom USB-C port with a DisplayPort monitor (2026-11-04, README「USB-C 外接屏」): while the tablet sinks power
    # from the monitor the PD firmware and the monitor re-attach every 5-10 s, so 71-y700-dp-source.rules makes the tablet
    # the source once DP-1 is connected; and y700-usb-port's delayed "device" write after a partner remove must not land
    # after a re-attach (the controller then sits in device mode with a UFP partner: the monitor's hub is gone).
    def check_usbc_port():
        if read("/usr/local/libexec/y700-usb-port") is None:
            return                      # usbport not installed our way
        if read("/usr/local/libexec/y700-dp-source") is None:
            say("WARN", "USB-C 底部口：/usr/local/libexec/y700-dp-source 没装——接外接屏会反复断开"
                        "（bash linux/usbport/install.sh；README「USB-C 外接屏」）")
            return
        rule = read("/etc/udev/rules.d/71-y700-dp-source.rules") is not None
        if not rule:                    # removed on purpose to charge through a DP dock (README「USB-C 外接屏」有意不做)
            say("INFO", "USB-C 底部口：外接屏供电规则 71-y700-dp-source.rules 被拿掉了（经扩展坞充电？恢复：bash linux/usbport/install.sh）")
        partner = os.path.exists("/sys/class/typec/port0-partner")
        dr, pr = read("/sys/class/typec/port0/data_role") or "", read("/sys/class/typec/port0/power_role") or ""
        role = read("/sys/class/usb_role/a600000.usb-role-switch/role") or "?"
        side = (read("/run/y700-usb-port.state") or "").startswith("side")   # controller given to the side port's gamepad
        dp = [p for p in glob.glob("/sys/class/drm/card*-DP-1/status") if read(p) == "connected"]
        if not partner:
            say("OK", "USB-C 底部口：没接东西" + ("；外接屏供电规则在" if rule else ""))
            return
        bad = []
        if "[host]" in dr and role != "host":
            bad.append(f"伙伴是 UFP（data_role {dr}）而控制器 role 是 {role}：y700-usb-port 把拔掉后的 device 写在了重连之后？"
                       "（echo host > /sys/class/usb_role/a600000.usb-role-switch/role 立即恢复）")
        if "[device]" in dr and role != "device" and not side:
            bad.append(f"伙伴是 DFP（data_role {dr}）而控制器 role 是 {role}：电脑看不到平板的 gadget，y700-usb-port 把侧边口的 host "
                       "写在了重连之后？（echo device > /sys/class/usb_role/a600000.usb-role-switch/role 立即恢复）")
        if dp and "[sink]" in pr and rule:
            bad.append(f"接着外接屏却在从它取电（power_role {pr}）：y700-dp-source 没跑或固件没换（journalctl -t y700-dp-source）")
        if bad:
            say("WARN", "USB-C 底部口：" + "；".join(bad) + "（README「USB-C 外接屏」）")
        else:
            say("OK", f"USB-C 底部口：有伙伴，data_role {dr}、power_role {pr}、控制器 {role}" + ("，外接屏在" if dp else ""))
    guard("USB-C 底部口", check_usbc_port)

    # Steam's UI on the GPU with zink's render-pass tracking off (2026-10-30, README "Steam 界面花屏"): with it on (ANGLE
    # GL -> zink -> Turnip) store pages show noise blocks where faded/masked layers are. Our launcher exports
    # ZINK_DEBUG=norp, which the steamwebhelper browser process (no --type=) then carries in its environment;
    # Y700_STEAM_UI=cpu (the 10-29 -cef-disable-gpu) is clean too and gives --disable-gpu.
    def check_steam_ui():
        launcher = read("/home/user/.local/bin/steam-arm64")
        if launcher is None:
            return                      # Steam not installed our way
        if not any(re.search(r"\bZINK_DEBUG=norp\b", ln) for ln in launcher.splitlines() if not ln.lstrip().startswith("#")):
            say("WARN", "Steam 启动器 ~/.local/bin/steam-arm64 不带 ZINK_DEBUG=norp：GPU 绘制的商店评测会花屏"
                        "（换回仓库的 linux/games/steam-arm64；README『Steam 界面花屏』）")
            return
        running = env = None
        for p in glob.glob("/proc/[0-9]*"):
            try:
                if not os.readlink(p + "/exe").endswith("/steamrtarm64/steamwebhelper"):
                    continue
                cmd = open(p + "/cmdline", "rb").read().replace(b"\0", b" ").decode(errors="replace")
            except OSError:
                continue
            if "--type=" not in cmd:
                running = cmd
                try:
                    env = open(p + "/environ", "rb").read().decode(errors="replace").split("\0")
                except OSError:
                    pass
                break
        if running is not None and re.search(r"--disable-gpu( |$)", running):
            say("OK", "Steam 界面由 CPU 绘制（Y700_STEAM_UI=cpu 开的；不花屏，滚动时比 GPU 绘制多用约 0.3 核）")
        elif env is not None and not any(v.startswith("ZINK_DEBUG=") and "norp" in v[11:].split(",") for v in env):
            say("WARN", "正在跑的 Steam 界面走 GPU 但没关 zink 的渲染通道跟踪（Y700_STEAM_UI=gpu-rp 试验后没换回，"
                        "或从别的入口开的）：商店评测会花屏，Steam 菜单里退出 Steam 再从图标开")
        else:
            say("OK", "Steam 界面走 GPU、关了 zink 的渲染通道跟踪（启动器带 ZINK_DEBUG=norp"
                + ("，正在跑的也是）" if env is not None else "）"))
    guard("Steam 界面绘制", check_steam_ui)

    # GPU hangs since the last --save (2026-10-23; until then: this boot only). The daily run that saves the baseline was
    # stuck from 10-20, and the 10-19 hangs (3 x ChatGPT's GPU process, 1 x steamwebhelper, kernel y12) left with their
    # boot before any run looked. Now a hang is a WARN in every run until a --save has reported it. Without a checked_at
    # in the baseline: this boot, as before. journald keeps only some boots (24 on 10-23): a window older than that is said.
    # The window starts at gpu_since when the baseline has one: the start of a window a run could not read the journal for,
    # kept (10-31 audit C4). checked_at moves on with every --save, so a failed read used to lose that window's hangs for
    # good. checked_at itself is not held back: the pstore checks date "new" records by it and would report them again
    def check_gpu_hangs():
        since = old.get("gpu_since") or old.get("checked_at")

        def when(t):
            return time.strftime("%m-%d %H:%M", time.localtime(t))
        scope = f"上次体检（{when(since)}）以来" if since else "本次开机"
        if since:
            cur["gpu_since"] = since                  # until the journal has been read: the next run looks from here again
        h = gpu_hangs(since, cur.get("boot8"))
        if "error" in h:
            say("INFO", f"查不了{scope}的 GPU 卡死：journalctl 没答上来（{h['error']}）")
            return
        cur.pop("gpu_since", None)
        o = h["oldest"]
        if since and o and (o["start"] if o["start"] is not None else o["end"]) > since:   # no real start: conservative
            say("INFO", f"内核日志最早只留到开机 {o['index']}（{when(o['start']) + ' 起' if o['start'] is not None else when(o['end']) + ' 结束'}），"
                        f"更早的开机已被 journald 轮转掉：{scope}在那之前的 GPU 卡死查不到了")
        if not h["n"]:
            say("OK", f"{scope} GPU 没有卡死" + (f"（查了 {h['boots']} 次开机的内核日志）" if since and h["boots"] else ""))
            return
        who = []
        for prog, (k, t0, t1, bl) in sorted(h["progs"].items(), key=lambda kv: -kv[1][0])[:5]:
            span = "" if t0 is None else when(t0) + ("" if when(t1) == when(t0) else
                                                     "–" + (when(t1)[6:] if when(t1)[:5] == when(t0)[:5] else when(t1)))
            where = "，".join(x for x in (span, "、".join(bl)) if x)
            who.append(f"{prog} {k} 次" + (f"（{where}）" if where else ""))
        progs = [p for p in h["progs"] if p != "未知"]
        hints = []
        px = [p for p in progs if p in h["procexe"]]
        if px:
            hints.append(f"{'、'.join(px)} 的命令行 argv[0] 是 /proc/self/exe（zypak / flatpak 的 Electron 常这样），这里按线程名记；"
                         "drirc 按 argv[0] 的文件名匹配，Mesa 看到的只是「exe」，配不上它：要在它的启动项里设 "
                         "MESA_LOADER_DRIVER_OVERRIDE=zink（先验证）")
        nc = [p for p in progs if p in h["nocmd"] and p not in px]
        if nc:
            hints.append(f"{'、'.join(nc)} 只记了线程名、没有命令行（日志行被截断），不一定是 drirc 的 executable= 要写的名字"
                         "（那是 argv[0] 的文件名）：它再开着时用 ps -eo comm,args 对一下")
        plain = [p for p in progs if p not in zinked and p not in DESKTOP_PROGS and p not in h["flatpak"] and p not in px
                 and p not in nc]
        if plain:
            hints.append(f"{'、'.join(plain)} 还走 freedreno GL：照 ChatGPT 的做法在 /etc/drirc 加一段 executable=\"{plain[0]}\" 的 "
                         f"dri_driver=zink（源文件 y700/linux/gpu/drirc，体检的 DRIRC_ZINK 也加上；先用 exec -a /x/{plain[0]} eglinfo -B "
                         "验证，README『Chrome 让 GPU 卡死』）")
        fp = [p for p in progs if p in h["flatpak"] and p not in zinked]
        if fp:
            hints.append(f"{'、'.join(fp)} 是 flatpak 程序，看不到宿主的 /etc/drirc：要在它自己的运行时里切 zink"
                         "（flatpak override --env=MESA_LOADER_DRIVER_OVERRIDE=zink <应用 id>，先验证）")
        zk = [p for p in progs if p in zinked and p not in px and p not in nc]

        def added(p):
            """Local midnight of the day p went into /etc/drirc (DRIRC_ZINK), None without a date. Each program by its own
            day, not by the file's mtime: adding ChatGPT on 10-23 did not make Chrome's 10-19 hangs pre-zink. A hang on
            the day itself counts as after it (the hint that asks to look)."""
            try:
                return time.mktime(time.strptime(DRIRC_ZINK[p], "%Y-%m-%d"))
            except (KeyError, ValueError):
                return None
        early = [p for p in zk if added(p) is not None and h["progs"][p][2] is not None and h["progs"][p][2] < added(p)]
        if early:                       # 10-23: the 10-19 ChatGPT / steamwebhelper hangs, from before they were added
            hints.append(f"{'、'.join(f'{p}（{DRIRC_ZINK[p][5:]} 加入）' for p in early)} 的卡死都在加进 /etc/drirc 那天之前，"
                         "那时还没走 zink：此后不再卡就不用管")
        late = [p for p in zk if p not in early]
        if late:
            hints.append(f"{'、'.join(p + ('（' + DRIRC_ZINK[p][5:] + ' 起）' if added(p) is not None else '（仓库没记加入日期）') for p in late)}"
                         " 已在 /etc/drirc 走 zink：卡死时它若是加入之前开的、一直没重开，重开即可；"
                         "否则不是 freedreno GL 的老问题，journalctl -k 看那几次前后")
        dk = [p for p in progs if p in DESKTOP_PROGS]
        if dk:
            hints.append(f"{'、'.join(dk)} 是桌面本身，不单独切 zink（README『Chrome 让 GPU 卡死』有意不做），journalctl -k 看那几次前后")
        say("WARN", f"{scope} GPU 卡死{' 至少' if h['capped'] else ''} {h['n']} 次：{'；'.join(who)}" + ("。" + "；".join(hints) if hints else ""))
    guard("GPU 卡死", check_gpu_hangs)

    # the Wi-Fi / display watchdogs: started by y700-kmsg-watch when the kernel logs their error line
    # (linux/net/KMSG-WATCH.md, 2026-10-16); until that is installed, by their once-a-minute timers
    watchdog_timers = ("y700-wifi-watchdog.timer", "y700-display-watchdog.timer")
    if os.path.exists("/etc/systemd/system/y700-kmsg-watch.service"):
        def check_kmsg_watch():
            state = run(["systemctl", "is-active", "y700-kmsg-watch.service"])
            if state != "active":
                say("WARN", f"y700-kmsg-watch.service 是 {state}：Wi‑Fi / 显示看门狗没人触发了（journalctl -u y700-kmsg-watch）")
                return
            # a ping through /dev/kmsg: proves the read loop is alive and that it can start both watchdogs
            ans = run(["/usr/local/libexec/y700-kmsg-watch", "--selftest"])
            if ans.split()[2:3] == ["ok"]:
                say("OK", "y700-kmsg-watch 读得到内核日志、能启动两个看门狗（" + ans.split("; ", 1)[-1] + "）")
            else:
                say("WARN", f"y700-kmsg-watch 自检没通过：{ans or '没有输出'}（systemctl restart y700-kmsg-watch；linux/net/KMSG-WATCH.md）")
            # Rust since 11-03 (linux/net/kmsg-watch); a script at the same path is the Python one back (a rollback)
            try:
                elf = open("/usr/local/libexec/y700-kmsg-watch", "rb").read(4) == b"\x7fELF"
            except OSError:
                elf = True
            if not elf:
                say("WARN", "y700-kmsg-watch 跑的是 Python 版（11-03 起是 Rust；回滚了才会这样；"
                            "在平板上重跑 y700/linux/net/kmsg-watch/install.sh）")
            for t in watchdog_timers:
                if run(["systemctl", "is-enabled", t]) != "enabled":
                    continue
                if os.path.exists(f"/etc/systemd/system/{t}.d/y700-safety.conf"):
                    say("OK", f"{t} 作为 15 分钟的安全网开着（y700-safety.conf）")
                else:
                    say("WARN", f"{t} 又启用了：和 y700-kmsg-watch 重复，每分钟白跑一次（systemctl disable --now {t}）")
        guard("kmsg 触发器", check_kmsg_watch)
        watchdog_timers = ()
    for unit in watchdog_timers + ("y700-guestos.service",):
        state = run(["systemctl", "is-active", unit])
        (say("OK", f"{unit} {state}") if state == "active" else say("WARN", f"{unit} 是 {state}"))
    for unit in ("y700-speaker-guard.service", "y700-lenovo-tuning.service", "y700-control-center.service"):
        state = run(["systemctl", "--user", "is-active", unit], user=True)
        (say("OK", f"{unit} {state}") if state == "active" else say("WARN", f"用户服务 {unit} 是 {state}"))

    # the control centre's gestures (10-21): the pull-down strip y700-cc-pull is its own unit (top edge; left half
    # = notifications, right half = controls since 10-22), the side edges are the back key through the KWin
    # script y700-edge, and KWin only hands the panel org_kde_kwin_fake_input (to send that key) when its desktop
    # file names the interface. And KWin's blur effect: the curtain is a frosted sheet over the whole screen; on
    # 10-22 the effect turned out not loaded at all in the session (the curtain was a thin tint over sharp icons)
    def check_control_center_gestures():
        if not os.path.exists("/home/user/.config/systemd/user/y700-cc-pull.service"):
            return
        bad = []
        state = run(["systemctl", "--user", "is-active", "y700-cc-pull.service"], user=True)
        # the strip is y700-shellbar's once that runs (its status bar takes the pull; install.sh disables y700-cc-pull,
        # and check_shellbar warns when both are up): no complaint about the old unit then
        shellbar = run(["systemctl", "--user", "is-active", "y700-shellbar.service"], user=True) == "active"
        if state != "active" and not shellbar:
            bad.append(f"下拉条 y700-cc-pull.service 是 {state}（右上往下拉不出面板）")
        if "true" not in run(["busctl", "--user", "call", "org.kde.KWin", "/Scripting", "org.kde.kwin.Scripting",
                              "isScriptLoaded", "s", "y700-edge"], user=True):
            bad.append("KWin 脚本 y700-edge 没加载（左右边缘返回键、控制中心「显示桌面」都没了）")
        if "org_kde_kwin_fake_input" not in (read("/usr/local/share/applications/y700-control-center.desktop") or ""):
            bad.append("/usr/local/share/applications/y700-control-center.desktop 缺 fake_input 授权（返回键发不出去）")
        if "true" not in run(["busctl", "--user", "call", "org.kde.KWin", "/Effects", "org.kde.kwin.Effects",
                              "isEffectLoaded", "s", "blur"], user=True):
            bad.append("KWin 模糊特效 blur 没加载（下拉帘子背后没有毛玻璃）")
        if bad:
            say("WARN", "控制中心手势：" + "；".join(bad) + "——sh linux/controlpanel/y700-control-center/install.sh")
        else:
            say("OK", "控制中心手势就绪（顶边下拉、左右边缘返回、模糊特效）")
    guard("控制中心手势", check_control_center_gestures)

    # Stage Manager (linux/stage, 11-08): the KWin script y700-stage, off until the control centre's 「台前调度」 tile,
    # which writes kwinrc [Script-y700-stage] Active and then calls the shortcut y700-stage-on / -off. KWin keeps the
    # QML it compiled per URL, so install.sh puts each build in contents/build-<BuildId>/ (a BuildId with no folder = a
    # script that loads nothing). Active and the script's last word must agree (a shortcut that did not land, a reload
    # that failed); a QML error at run time is a bug (11-08 in ts-bed: calls into an unloaded instance's dead root)
    def check_stage():
        sdir = "/home/user/.local/share/kwin/scripts/y700-stage"
        if not os.path.exists(sdir):
            return
        if "true" not in run(["busctl", "--user", "call", "org.kde.KWin", "/Scripting", "org.kde.kwin.Scripting",
                              "isScriptLoaded", "s", "y700-stage"], user=True):
            say("WARN", "台前调度：KWin 脚本 y700-stage 没加载（sh linux/stage/install.sh；journalctl --user -b | grep y700-stage）")
            return
        bid = run(["kreadconfig6", "--file", "kwinrc", "--group", "Script-y700-stage", "--key", "BuildId"], user=True)
        if not re.fullmatch(r"[0-9]+", bid) or not os.path.exists(f"{sdir}/contents/build-{bid}/ui/Stage.qml"):
            say("WARN", f"台前调度：kwinrc 的 BuildId「{bid}」对不上装着的构建目录，脚本什么都没加载（重跑 sh linux/stage/install.sh）")
            return
        errs = run(["sh", "-c", "journalctl --user -b --no-pager -o cat | grep -cE "
                                "'kwin/scripts/y700-stage/contents/[^ ]*[.]qml:[0-9]+'"], user=True)
        if errs not in ("", "0"):
            say("WARN", f"台前调度：这次开机 y700-stage 报了 {errs} 条 QML 错误"
                        "（journalctl --user -b | grep 'y700-stage/contents' 看是哪一行）")
            return
        for attempt in (1, 2):              # a tap on the tile between the two reads: Active is written first
            want = run(["kreadconfig6", "--file", "kwinrc", "--group", "Script-y700-stage", "--key", "Active"], user=True) == "true"
            last = run(["sh", "-c", "journalctl --user -b --no-pager -o cat | grep -E "
                                    "'y700-stage: (loaded, (on|off)$|on, |off, )' | tail -1"], user=True)
            got = None if not last else bool(re.search(r"y700-stage: (loaded, on$|on, )", last))
            if got == want:
                break
            time.sleep(1.5)
        if got is None:
            say("WARN", "台前调度：这次开机的日志里没有 y700-stage 的加载记录（journalctl --user -b | grep y700-stage）")
        elif got != want:
            say("WARN", f"台前调度：kwinrc 记的是「{'开' if want else '关'}」，脚本最后一句是「{last.split('y700-stage: ', 1)[-1]}」"
                        "（控制中心的「台前调度」点两下对齐；还不对看 journalctl --user -b | grep y700-stage）")
        else:
            say("OK", f"台前调度就绪（y700-stage 已加载，{'开着' if want else '关着'}，和控制中心的开关一致）")
        # the round corners (kwin-corners/, 11-09): a KWin upgrade makes the old plugin unloadable and the apt hook
        # rebuilds it; a rebuild that failed leaves the stage square-cornered without a word. Loaded only once the
        # stage has been on (the script asks for it), so "not loaded" counts only while it is on. No stamp = never
        # built here (no kwin-dev at install): no line
        stamp = (slurp("/usr/local/share/y700-stage/stagecorners.kwin-version") or "").strip() or None
        kv = cur["pkgs"]["kwin-wayland"]
        if stamp and stamp != kv:
            say("WARN", f"台前调度的圆角特效是为 KWin {stamp} 编的，现在是 {kv}：自动重编没成功，舞台窗口是方角"
                        "（journalctl -t y700-stagecorners；手动 sh /usr/local/src/y700-stage/install.sh，下次登录生效）")
        elif stamp and want and got and "true" not in run(["busctl", "--user", "call", "org.kde.KWin", "/Effects",
                                                           "org.kde.kwin.Effects", "isEffectLoaded", "s", "y700_stagecorners"], user=True):
            say("WARN", "台前调度开着，圆角特效却没加载，舞台窗口是方角（journalctl --user -b | grep -i stagecorners）")
    guard("台前调度", check_stage)

    # split screen (linux/split, 11-10): the KWin script y700-split, its BuildId's folder (as the stage's), no QML error
    # this boot; kwinrc [Windows] ElectricBorderTiling / ElectricBorderMaximize false (install.sh: else KWin's own quick
    # tiling takes the same title bar drag to an edge); the corner effect, once loaded, must have its split part
    # (setSplitWindows: an effect built before 27d19a8 has none: square halves, no gap colour, the card follows the
    # cursor, until linux/stage/install.sh has rebuilt it and a login has loaded the new one)
    def check_split():
        sdir = "/home/user/.local/share/kwin/scripts/y700-split"
        if not os.path.exists(sdir):
            return
        if "true" not in run(["busctl", "--user", "call", "org.kde.KWin", "/Scripting", "org.kde.kwin.Scripting",
                              "isScriptLoaded", "s", "y700-split"], user=True):
            say("WARN", "分屏：KWin 脚本 y700-split 没加载（sh /usr/local/src/y700-split/install.sh；journalctl --user -b | grep y700-split）")
            return
        bid = run(["kreadconfig6", "--file", "kwinrc", "--group", "Script-y700-split", "--key", "BuildId"], user=True)
        if not re.fullmatch(r"[0-9]+", bid) or not os.path.exists(f"{sdir}/contents/build-{bid}/ui/Split.qml"):
            say("WARN", f"分屏：kwinrc 的 BuildId「{bid}」对不上装着的构建目录，脚本什么都没加载（重跑 sh /usr/local/src/y700-split/install.sh）")
            return
        errs = run(["sh", "-c", "journalctl --user -b --no-pager -o cat | grep -cE "
                                "'kwin/scripts/y700-split/contents/[^ ]*[.]qml:[0-9]+'"], user=True)
        if errs not in ("", "0"):
            say("WARN", f"分屏：这次开机 y700-split 报了 {errs} 条 QML 错误"
                        "（journalctl --user -b | grep 'y700-split/contents' 看是哪一行）")
            return
        edges = [k for k in ("ElectricBorderTiling", "ElectricBorderMaximize")
                 if run(["kreadconfig6", "--file", "kwinrc", "--group", "Windows", "--key", k], user=True) != "false"]
        if edges:
            say("WARN", "分屏：kwinrc [Windows] " + "、".join(edges) + " 不是 false，拖标题栏到边时 KWin 自己的贴边会抢"
                        "（重跑 sh /usr/local/src/y700-split/install.sh）")
            return
        fx = run(["busctl", "--user", "introspect", "org.kde.KWin", "/org/y700/StageCorners"], user=True)
        if fx and "setSplitWindows" not in fx:
            # the library on disk already has it (moc keeps the method names): built and installed, the session is older
            try:
                built = b"setSplitWindows" in open("/usr/lib/aarch64-linux-gnu/qt6/plugins/kwin/effects/plugins/"
                                                   "y700_stagecorners.so", "rb").read()
            except OSError:
                built = False
            say("WARN", "分屏：KWin 里跑的圆角特效是旧的，没有分屏那部分（两半方角、缝里不上色、拖标题栏时卡片跟鼠标不跟手指）："
                        + ("新的已经装好，重新登录一次" if built else "sh /usr/local/src/y700-stage/install.sh 重编后重新登录一次"))
            return
        say("OK", "分屏就绪（y700-split 已加载，KWin 自带的贴边已关）")
    guard("分屏", check_split)

    # the curtain's blur on the live screen (linux/controlpanel/y700-control-center/tests/blur-flicker.sh, 10-22): a fake
    # finger pulls the curtain while every frame KWin renders is kept; a frame tinted but sharp is the flicker that was
    # fixed that day (README「下拉模糊闪烁」). The test takes the screen for 4 s, so this does not run it: it checks the
    # tools it needs (KWin grants ScreenShot2 and fake_input per executable, hence the copies with their desktop
    # files) and the one-line result the last run wrote
    def check_control_center_blur():
        if not os.path.exists("/usr/local/share/y700-control-center/tests/blur-flicker.sh"):
            return
        bad = []
        if not os.path.exists("/usr/local/bin/y700-capseq") or "ScreenShot2" not in (read("/usr/local/share/applications/y700-capseq.desktop") or ""):
            bad.append("y700-capseq 或它 desktop 文件里的 ScreenShot2 授权不在（抓不了帧）")
        if not os.path.exists("/usr/local/bin/y700-ftouch") or "org_kde_kwin_fake_input" not in (read("/usr/local/share/applications/y700-ftouch.desktop") or ""):
            bad.append("y700-ftouch 或它 desktop 文件里的 fake_input 授权不在（假手指按不下去）")
        last = read("/var/lib/y700/cc-blur-last.txt") or ""
        if bad:
            say("WARN", "控制中心模糊自检工具：" + "；".join(bad) + "——sh linux/controlpanel/y700-control-center/install.sh")
        elif not last:
            say("INFO", "控制中心模糊自检还没跑过：改过帘子、模糊或窗口相关代码后，没人用平板时跑 "
                        "sh /usr/local/share/y700-control-center/tests/blur-flicker.sh")
        elif " OK " not in last:
            say("WARN", "控制中心模糊自检上次没过：" + last[:160] + "——看 /home/user/cc-blur/sheet.png，修好再跑 blur-flicker.sh")
        else:
            say("OK", "控制中心帘子模糊：上次自检 " + " ".join(last.split(" ")[:2]) + " 通过，工具齐全")
    guard("控制中心模糊自检", check_control_center_blur)

    # the dock's glass inside the task switcher (linux/dock/tests/dock-glass-run.sh, 10-22): while its cards are up the
    # effect paints the dock itself, and without PanelGlass (taskswitcher/ui/TaskSwitcher.qml) that copy had no blur:
    # see-through until the effect ended. The runner plays the leave in the headless bed against the INSTALLED
    # build and records the verdict with that build; the installed build is in main.qml, so a verdict for another
    # build means the installed one was never tested: rerun (nothing touches the screen), whatever that verdict said
    # (the install checklist's red run is against the OLD build: after the install its FAIL is stale, not a failure)
    def check_dock_glass():
        fxdir = "/home/user/.local/share/kwin/effects/y700-taskswitcher"
        qml = slurp(fxdir + "/contents/ui/main.qml", "")
        if not qml:
            return
        m = re.search(r'y700Build: "([^"]*)"', qml)
        want = m.group(1) if m else ""
        last = (read("/var/lib/y700/dock-glass-last.txt") or "").strip()
        parts = last.split()
        tested = last.rsplit(" build ", 1)[1] if " build " in last else ""
        if not last:
            say("INFO", "Dock 玻璃自检还没跑过：改过多任务卡片或 Dock 后跑 sh /usr/local/src/y700-dock/tests/dock-glass-run.sh"
                        "（无头测试台，不动屏幕）")
        elif not want or tested != want:
            say("INFO", f"Dock 玻璃自检上次测的不是现在装的多任务卡片（装着 {want or '读不到'}，测过 {tested or '不明'}）："
                        "重跑 sh /usr/local/src/y700-dock/tests/dock-glass-run.sh")
        elif len(parts) < 3 or parts[2] != "OK":
            say("WARN", "Dock 玻璃自检上次没过：" + last[:180] + "——看 /home/user/dock-glass/strip.png，修好再跑 dock-glass-run.sh")
        else:
            say("OK", "Dock 玻璃（多任务卡片里）：上次自检 " + " ".join(parts[:2]) + " 通过")
    guard("Dock 玻璃自检", check_dock_glass)

    # the control centre's brightness / volume pills under a finger (linux/dock/tests/pill-drag-run.sh, 10-22): since
    # the thumb-first layout put them under the right thumb's resting spot, a press must not jump the value (relative
    # drag, qml/Pill.qml); the runner plays six gestures in the headless bed and stamps the verdict with the sha256 (12)
    # of the Pill.qml it tested. The installed one is read at runtime from /usr/local/share, so a verdict for another
    # Pill.qml means the installed one was never tested: rerun (nothing touches the screen), whatever it said
    def check_pill_drag():
        qml = "/usr/local/share/y700-control-center/qml/Pill.qml"
        if not os.path.exists(qml):
            return
        want = (file_hash(qml) or "")[:12]
        last = (read("/var/lib/y700/pill-drag-last.txt") or "").strip()
        parts = last.split()
        tested = last.rsplit(" pill ", 1)[1] if " pill " in last else ""
        if not last:
            say("INFO", "控制中心胶囊滑杆自检还没跑过：改过 Pill.qml 或测试台后跑 sh /usr/local/src/y700-dock/tests/pill-drag-run.sh"
                        "（无头测试台，不动屏幕）")
        elif not want or tested != want:
            say("INFO", f"控制中心胶囊滑杆自检上次测的不是现在装的 Pill.qml（装着 {want or '读不到'}，测过 {tested or '不明'}）："
                        "重跑 sh /usr/local/src/y700-dock/tests/pill-drag-run.sh")
        elif len(parts) < 3 or parts[2] != "OK":
            say("WARN", "控制中心胶囊滑杆自检上次没过：" + last[:200] + "——看 /home/user/pill-drag/p*.png，修好再跑 pill-drag-run.sh")
        else:
            say("OK", "控制中心胶囊滑杆（按下不跳、相对拖动）：上次自检 " + " ".join(parts[:2]) + " 通过")
    guard("控制中心胶囊滑杆自检", check_pill_drag)

    # the volume pill's level when the curtain opens (10-22, linux/dock/tests/vol-open-run.sh, README「控制中心」
    # 第十三轮): show() reads the volume with one wpctl ahead of the 0.35 s status pipeline and follows the volume keys
    # with pactl subscribe while open. That is compiled into the binary, so the verdict is stamped with the sha256 (12)
    # of the binary it tested; a verdict for another build (not run since a reinstall) asks for a rerun, not a WARN
    def check_vol_open():
        cc = "/usr/local/bin/y700-control-center"
        if not os.path.exists(cc):
            return
        want = (file_hash(cc) or "")[:12]
        last = (read("/var/lib/y700/vol-open-last.txt") or "").strip()
        parts = last.split()
        tested = last.rsplit(" cc ", 1)[1] if " cc " in last else ""
        if not last:
            say("INFO", "控制中心开帘音量自检还没跑过：改过控制中心的音量代码或测试台后跑 sh /usr/local/src/y700-dock/tests/vol-open-run.sh"
                        "（无头测试台，不动屏幕、不出声）")
        elif not want or tested != want:
            say("INFO", f"控制中心开帘音量自检上次测的不是现在装的控制中心（装着 {want or '读不到'}，测过 {tested or '不明'}）："
                        "重跑 sh /usr/local/src/y700-dock/tests/vol-open-run.sh")
        elif len(parts) < 3 or parts[2] != "OK":
            say("WARN", "控制中心开帘音量自检上次没过：" + last[:200] + "——看 /home/user/vol-open/v*.png，修好再跑 vol-open-run.sh")
        else:
            say("OK", "控制中心开帘就是当前音量、开着跟音量键：上次自检 " + " ".join(parts[:2]) + " 通过")
    guard("控制中心开帘音量自检", check_vol_open)

    # the vivo-style status bar + dock (linux/dock/y700-shellbar, 10-22): its service, the window-management grant in
    # its desktop file (without it the task model is empty and the dock thinks it is always on the desktop), only one
    # pull strip (it took over y700-cc-pull's job), the B+ hook in the installed task switcher QML, and (once it is
    # enabled) a control centre new enough for the curtain: the strip's left half opens the notification centre
    # (pullBeginSide, NotesPane.qml); an old one has no such method and the left half's pull does nothing
    def check_shellbar():
        if not os.path.exists("/usr/local/bin/y700-shellbar"):
            return
        bad = []
        enabled = run(["systemctl", "--user", "is-enabled", "y700-shellbar.service"], user=True)
        state = run(["systemctl", "--user", "is-active", "y700-shellbar.service"], user=True)
        if enabled == "enabled" and state != "active":
            bad.append(f"y700-shellbar.service 是 {state}（没有状态栏和 dock）")
        if "org_kde_plasma_window_management" not in (read("/usr/local/share/applications/y700-shellbar.desktop") or ""):
            bad.append("/usr/local/share/applications/y700-shellbar.desktop 缺窗口管理授权（dock 看不到窗口）")
        if enabled == "enabled" and not os.path.exists("/usr/local/share/y700-control-center/qml/NotesPane.qml"):
            bad.append("装着的控制中心是旧版、没有通知中心（左半下拉没反应；装 linux/controlpanel/y700-control-center）")
        if state == "active" and run(["systemctl", "--user", "is-active", "y700-cc-pull.service"], user=True) == "active":
            bad.append("y700-cc-pull 和 shellbar 的下拉条同时开着（systemctl --user disable --now y700-cc-pull）")
        # since phase 2 (10-22) the shellbar is the session's notification server: libnotificationmanager registers
        # org.freedesktop.Notifications from its Banners.qml model and takes the name over for good. Anyone else
        # holding it while the service runs (a plasmashell restarted with its panel still there, a shellbar that came
        # up before the bus settled) means no banners, and a notification centre watching a server the apps do not talk to
        if state == "active":
            owner = ""   # busctl list: NAME PID PROCESS USER CONNECTION ...; the activatable entry is a second line, all "-"
            for line in run(["busctl", "--user", "--no-pager", "--no-legend", "list"], user=True).splitlines():
                cols = line.split()
                if cols[:1] == ["org.freedesktop.Notifications"] and len(cols) > 2 and cols[2] != "-":
                    owner = cols[2]
            if owner != "y700-shellbar":
                bad.append("通知服务 org.freedesktop.Notifications 在 " + (owner or "没人")
                           + " 手里，不在 y700-shellbar（没有横幅；systemctl --user restart y700-shellbar 抢回来）")
        ts = read("/home/user/.local/share/kwin/effects/y700-taskswitcher/contents/ui/TaskSwitcher.qml")
        if ts is not None and "fyi.y700.Shellbar" not in ts:
            bad.append("装着的多任务卡片 QML 里没有 B+ 钩子（应用里轻扫底边不出 dock）")
        if bad:
            say("WARN", "状态栏与 dock：" + "；".join(bad) + "——sh linux/dock/y700-shellbar/install.sh")
        else:
            say("OK", f"状态栏与 dock 就绪（服务 {enabled}/{state}）")
    guard("状态栏与 dock", check_shellbar)

    # the control centre's tray (the dock's stage 4, 10-23: linux/controlpanel/y700-control-center/src/tray.cpp): the
    # curtain's 「后台应用」 row lists the StatusNotifierItems kded6's watcher knows, and the watcher hands them only to a
    # host that owns org.kde.StatusNotifierHost-<pid> and registered it. Without one the row stays empty (a control
    # centre that could not take the name, or kded6 without its statusnotifierwatcher module)
    def check_tray_host():
        if not os.path.exists("/usr/local/share/y700-control-center/qml/TrayTile.qml"):
            return
        if run(["systemctl", "--user", "is-active", "y700-control-center.service"], user=True) != "active":
            return                                  # the unit's own line above already says so
        hosts, watcher = [], ""
        for line in run(["busctl", "--user", "--no-pager", "--no-legend", "list"], user=True).splitlines():
            cols = line.split()                     # NAME PID PROCESS ...; activatable entries have "-" there
            if len(cols) < 3 or cols[2] == "-":
                continue
            if cols[0].startswith("org.kde.StatusNotifierHost-"):
                hosts.append(cols[2])
            elif cols[0] == "org.kde.StatusNotifierWatcher":
                watcher = cols[2]
        bad = []
        if not watcher:
            bad.append("kded6 的 StatusNotifierWatcher 不在总线上（没有托盘项可列；systemctl --user restart plasma-kded6）")
        # busctl prints the process name the kernel keeps: 15 characters
        if not any(h.startswith("y700-control-ce") for h in hosts):
            bad.append("控制中心没占 org.kde.StatusNotifierHost-<pid>（总线上的宿主："
                       + ("、".join(hosts) or "没有") + "；systemctl --user restart y700-control-center）")
        if bad:
            say("WARN", "控制中心托盘（帘子「后台应用」是空的）：" + "；".join(bad))
        else:
            say("OK", f"控制中心是托盘宿主（watcher 在 {watcher} 手里）")
    guard("控制中心托盘", check_tray_host)

    # a package upgrade whose postinst does not restart its daemons leaves them running the old, deleted binary
    # (2026-10-16: tb323fu-platform 0.4.1 -> 0.4.2 left keyhold under tb323fu-emergency-key.service on the old file,
    # and tb323fu-helperd kept answering "0.4.1" until restarted)
    def check_stale_binaries():
        stale = set()
        for exe in glob.glob("/proc/[0-9]*/exe"):
            try:
                target = os.readlink(exe)
            except OSError:
                continue
            if target.endswith(" (deleted)") and target.startswith("/usr/"):
                pid = exe.split("/")[2]
                cg = (read(f"/proc/{pid}/cgroup") or "").strip().rsplit("/", 1)[-1]
                stale.add(f"{target[:-len(' (deleted)')]}（{cg or 'pid ' + pid}）")
        if stale:
            hint = "包的 postinst 没重启它们，systemctl restart 对应单元（helper/platform 升级后见过）"
            # the keyboard is no unit of ours but part of KWin's input-method chain (2026-10-21: reinstalled
            # for the gate fix, the old one ran until the next login)
            if any(s.startswith("/usr/local/bin/y700-osk（") for s in stale):
                hint += "；y700-osk 在会话里跑：以 user 身份 y700-osk-ctl restart，或者重新登录"
            # the shellbar is a user unit; its install.sh --no-start leaves a fresh build unstarted on purpose (the
            # live one keeps running until the owner agrees to the blink), so this is the reminder that it is pending
            if any(s.startswith("/usr/local/bin/y700-shellbar（") for s in stale):
                hint += "；y700-shellbar 是用户单元：以 user 身份 systemctl --user restart y700-shellbar（dock 和状态栏闪一下，先确认没人在用）"
            # logind is never restarted by its postinst on purpose (Debian #919509: the graphical session goes with it)
            # and a lone wireplumber/pipewire restart drops the speakers to pro-audio (README「flatpak 更新」): both
            # wait for the next reboot (11-01, systemd 259.9 / wireplumber 0.5.13-1ubuntu1.1)
            wait = sorted({s.split("（")[0].rsplit("/", 1)[-1] for s in stale} & {"systemd-logind", "wireplumber", "pipewire"})
            if wait:
                hint += f"；{'、'.join(wait)} 别单独重启（logind 一重启图形会话就没了，音频服务单独重启会掉到 pro-audio），等下次整机重启"
            say("WARN", f"{len(stale)} 个进程还在跑升级前被替换掉的旧二进制：{'；'.join(sorted(stale)[:6])}——{hint}")
        else:
            say("OK", "没有进程在跑被升级替换掉的旧二进制")
    guard("旧二进制", check_stale_binaries)

    # an app from an earlier login that outlived it (2026-10-21: after a re-login by `systemctl restart sddm` the
    # next autologin comes before the user manager's stop delay runs out, so systemd --user stays up and the apps
    # Plasma started as app-*.service / app-*.scope units in its app.slice are never stopped; their Wayland socket
    # died with the old KWin and wiliwili's GLFW loop spun one core at 100 % on it for an hour, windowless; that spin
    # is fixed since 10-21 17:20 by linux/video/wiliwili-glfw-wayland-disconnect.patch, the check stays for the rest)
    def check_orphan_apps():
        kw = session_kwin()
        if not kw:
            return
        def stat(pid):      # (comm, cpu ticks, start ticks since boot): fields 14+15 and 22 of /proc/<pid>/stat
            st = read(f"/proc/{pid}/stat") or ""
            f = st.rsplit(")", 1)[1].split()
            return st[st.find("(") + 1:st.rfind(")")], int(f[11]) + int(f[12]), int(f[19])
        since = stat(kw)[2]
        units = {}
        for cgf in glob.glob("/proc/[0-9]*/cgroup"):
            pid = cgf.split("/")[2]
            m = re.search(r"/user@1000\.service/app\.slice/(app-[^/\s]+)", read(cgf) or "")
            if not m:
                continue
            try:
                comm, cpu, start = stat(pid)
            except (IndexError, ValueError):
                continue                    # gone meanwhile
            if start < since:
                u = units.setdefault(m.group(1), [comm, 0])
                u[1] += cpu
        if units:
            # ticks are USER_HZ, 100 on arm64 Linux
            what = "；".join(f"{c}（{u}，累计 CPU {t // 6000} 分钟）" for u, (c, t) in sorted(units.items(), key=lambda x: -x[1][1])[:4])
            say("WARN", f"{len(units)} 个程序是上一次登录留下的，窗口已经随旧 KWin 没了，有的会空转占满一核：{what}"
                        "——以 user 身份 systemctl --user stop 对应单元")
        else:
            say("OK", "没有上一次登录留下的程序")
    guard("上次登录残留", check_orphan_apps)

    # our patches are compiled into the self-built wiliwili (2026-10-21): a rebuild after a wiliwili upgrade must
    # re-apply every one by hand, and a missed one fails silently (back to vaapi-copy, the refresh rate no longer
    # follows the video, a spinning core after a re-login...). Each adds a string only it puts into the binary.
    WILIWILI_PATCHES = (("wiliwili-prefer-mainland-mirrors.patch", b"Video mirror order: {}"),
                        ("wiliwili-vaapi-zero-copy.patch", b"WILIWILI_DRM_RENDER_NODE"),
                        ("wiliwili-video-state.patch", b"/y700-video"),
                        ("wiliwili-glfw-wayland-disconnect.patch", b"Wayland: Lost the connection to the compositor"))
    def check_wiliwili_patches():
        try:
            with open("/usr/local/bin/wiliwili", "rb") as f:
                blob = f.read()
        except OSError:
            return                          # not built on this machine
        missing = [p for p, mark in WILIWILI_PATCHES if mark not in blob]
        if missing:
            say("WARN", f"装着的 wiliwili 缺 {len(missing)} 个我们的补丁：{'、'.join(missing)}——重编时漏打了，"
                        "补丁在仓库 linux/video/，在 /usr/local/src/wiliwili 上 patch -p1 再 ninja && ninja install"
                        "（README「wiliwili 断线退出」）")
        else:
            say("OK", f"wiliwili 带着我们的 {len(WILIWILI_PATCHES)} 个补丁")
    guard("wiliwili 补丁", check_wiliwili_patches)

    # libcamera with our rear autofocus + lens power patches (linux/camera/, 2026-10-29), held at 0.7.0-1ubuntu2+y700.N.
    # The hold stops Ubuntu's libcamera updates, security ones too, without a word; Ubuntu's build coming back (an
    # unhold, an upgrade) means no focus and the lens leak again: the VCM and vreg_l6b_2p8 powered for as long as
    # pipewire runs. linux/camera/README.md「周期性义务」. Only where libcamera-af-install.sh --install ever ran.
    LIBCAMERA_STATE = "/root/libcamera-y700/install-state.txt"
    LIBCAMERA_MARK = b"Failed to open the focus lens"               # only patch 0005 puts this into libcamera.so
    LENS_RT = "/sys/bus/i2c/devices/5-000c/power/runtime_status"   # gt9764 VCM, dw9719 driver
    REAR_RT = "/sys/bus/i2c/devices/5-0056/power/runtime_status"   # s5kjns: runtime active only while it streams
    def check_libcamera():
        if not os.path.exists(LIBCAMERA_STATE):
            return                          # never installed here
        inst = dpkg_version("libcamera0.7")
        if not inst or "+y700." not in inst:
            say("WARN", f"libcamera：libcamera0.7 是 {inst or '没装'}，不是我们编的 +y700 版，后摄对焦没了、镜头漏电回来了——"
                        "按 linux/camera/README.md「用法」重装（作者定了不要时，删掉体检的 check_libcamera）")
            return
        try:
            with open("/usr/lib/aarch64-linux-gnu/libcamera.so.0.7", "rb") as f:
                marked = LIBCAMERA_MARK in f.read()
        except OSError:
            marked = False
        bad = []
        if not marked:
            bad.append("libcamera.so.0.7 里没有补丁 0005 的字符串，装着的库不是我们编的那份")
        if "libcamera0.7" not in run(["apt-mark", "showhold"]).split():
            bad.append("libcamera0.7 没 hold，Ubuntu 一出新版 apt upgrade 就会换掉它（五个包都要 apt-mark hold）")
        m = re.search(r"^\s*Candidate:\s*(\S+)", run(["env", "LC_ALL=C", "apt-cache", "policy", "libcamera0.7"]), re.M)
        cand = m.group(1) if m else None
        if cand and cand not in ("(none)", inst) and \
                run(["sh", "-c", 'dpkg --compare-versions "$1" gt "$2" && echo newer', "sh", cand, inst]) == "newer":
            bad.append(f"Ubuntu 出了 {cand}，被 hold 挡住了：先看是不是安全更新（USN），再按「周期性义务」在新版上重编；"
                       "来不及就 libcamera-af-install.sh --rollback（对焦没了、漏电回来）")
        # the candidate is only as new as the apt lists: this tablet has no APT::Periodic, so apt-daily refreshes
        # nothing (10-29); they move when someone runs apt update (or Discover does)
        lists = [os.path.getmtime(p) for p in glob.glob("/var/lib/apt/lists/*_Packages*")]
        age = (time.time() - max(lists)) / 86400 if lists else None
        if age is None or age > 30:
            bad.append(f"apt 列表{'不在' if age is None else f' {age:.0f} 天没刷新'}，看不到 Ubuntu 有没有出新的 libcamera："
                       "apt-get update（平板没配 APT::Periodic，apt-daily 什么都不刷新）")
        lens = read(LENS_RT)
        if lens == "active" and read(REAR_RT) != "active":
            time.sleep(2)                   # a CameraManager starting (cam -l, a pipewire restart) holds the lens ~1 s
            lens = read(LENS_RT)
        rear = read(REAR_RT)
        if lens is None:
            bad.append(f"读不到 {LENS_RT}（镜头的 I2C 地址变了？），漏电查不了")
        elif lens == "active" and rear != "active":
            bad.append("后摄没在出流，镜头却上着电：0005 修的漏电回来了（bash /root/libcamera-af-install.sh --status 看谁开着镜头节点）")
        for b in bad:
            say("WARN", f"libcamera：{b}（linux/camera/README.md）")
        if not bad:
            say("OK", f"libcamera {inst} 带着对焦和镜头补丁、hold 着，Ubuntu 没有更新的版本（apt 列表 {age:.0f} 天前刷新）；镜头 {lens}"
                      + ("（后摄正在出流）" if rear == "active" else ""))
    guard("libcamera 补丁", check_libcamera)

    # automatic brightness (README "自动亮度"; Rust since 11-03, linux/display/autobright): a unit that runs python3 is
    # the old version back (a rollback), a panic shows as automatic restarts, and when its last word on KWin's screen
    # events is "no KWin screen events ..." it reads /sys/class/drm every second again (the Python version's cost)
    def check_autobright():
        if run(["systemctl", "--user", "is-enabled", "y700-autobright.service"], user=True) != "enabled":
            return
        state = run(["systemctl", "--user", "is-active", "y700-autobright.service"], user=True)
        if state != "active":
            say("WARN", f"自动亮度开着但服务是 {state}（journalctl --user -u y700-autobright）")
            return
        try:
            unit = open("/home/user/.config/systemd/user/y700-autobright.service").read()
        except OSError:
            unit = ""
        r = run(["systemctl", "--user", "show", "-p", "NRestarts", "--value", "y700-autobright.service"], user=True)
        last = run(["sh", "-c", "journalctl --user -b -u y700-autobright --no-pager -o cat | grep 'KWin screen events' | tail -1"], user=True)
        if "python3" in unit:
            say("WARN", "自动亮度跑的是 Python 版（11-03 起是 Rust；回滚了才会这样；在平板上重跑 y700/linux/display/autobright/install.sh）")
        elif r.isdigit() and int(r) > 5:
            say("WARN", f"自动亮度自动重启了 {r} 次（本次开机或上次手动重启以来），Rust 版崩了才会这样"
                        "（journalctl --user -b -u y700-autobright | grep panicked）")
        elif last.startswith("no KWin screen events"):
            say("WARN", f"自动亮度收不到 KWin 的熄屏事件（{last}），正每秒读一次 sysfs：功能照常，但熄屏时也每秒醒一次"
                        "（README『自动亮度』）")
        else:
            say("OK", "自动亮度在跑")
    guard("自动亮度", check_autobright)

    # refresh rate follows the video + GPU thresholds (README "刷新率跟随视频" / "视频播放功耗", 2026-10-16). Rust since
    # 11-03 (linux/display/refresh-auto/daemon), checked as check_autobright: python3 in the unit is a rollback, a panic
    # shows as restarts, and "no KWin screen events" as its last word means the screen-off guard is on the 1 s sysfs tick
    def check_refresh_auto():
        if run(["systemctl", "--user", "is-enabled", "y700-refresh-auto.service"], user=True) != "enabled":
            return
        state = run(["systemctl", "--user", "is-active", "y700-refresh-auto.service"], user=True)
        if state != "active":
            say("WARN", f"刷新率跟随视频的守护是 {state}（journalctl --user -u y700-refresh-auto）")
            return
        try:
            unit = open("/home/user/.config/systemd/user/y700-refresh-auto.service").read()
        except OSError:
            unit = ""
        r = run(["systemctl", "--user", "show", "-p", "NRestarts", "--value", "y700-refresh-auto.service"], user=True)
        last = run(["sh", "-c", "journalctl --user -b -u y700-refresh-auto --no-pager -o cat | grep 'KWin screen events' | tail -1"], user=True)
        if "python3" in unit:
            say("WARN", "刷新率守护跑的是 Python 版（11-03 起是 Rust；回滚了才会这样；"
                        "在平板上重跑 y700/linux/display/refresh-auto/daemon/install.sh）")
        elif r.isdigit() and int(r) > 5:
            say("WARN", f"刷新率守护自动重启了 {r} 次（本次开机或上次手动重启以来），Rust 版崩了才会这样"
                        "（journalctl --user -b -u y700-refresh-auto | grep panicked）")
        elif last.startswith("no KWin screen events"):
            say("WARN", f"刷新率守护收不到 KWin 的熄屏事件（{last}）：降档时改回每秒读 sysfs，防闪烁照常，但放视频时每秒醒一次"
                        "（README『刷新率跟随视频』）")
        st = run(["gdbus", "call", "--session", "-d", "fyi.y700.RefreshAuto", "-o", "/RefreshAuto", "-m",
                  "fyi.y700.RefreshAuto.status"], user=True) or ""
        try:
            j = json.loads(st[st.index("{"):st.rindex("}") + 1].replace("\\'", "'"))
        except ValueError:
            say("WARN", f"刷新率守护在跑但 D-Bus 状态读不出来：{st[:80]!r}")
            return
        if j.get("cur_hz") != j.get("base_hz") and j.get("video_target") is None:
            say("WARN", f"面板停在 {j.get('cur_hz')} Hz，没有视频在要求降档（基准 {j.get('base_hz')} Hz）——"
                        "守护的切换没回去？看 journalctl --user -u y700-refresh-auto")
        else:
            say("OK", f"刷新率守护在跑：基准 {j.get('base_hz')} Hz，现在 {j.get('cur_hz')} Hz"
                      + (f"（视频要 {j['video_target']} Hz）" if j.get("video_target") else ""))
    guard("刷新率跟随视频", check_refresh_auto)
    def check_gpu_dvfs():
        d = next(iter(glob.glob("/sys/kernel/debug/dri/*/devfreq/upthreshold")), None)
        if run(["systemctl", "is-enabled", "y700-gpu-dvfs.service"]) != "enabled" or not d:
            return
        up = (read(d) or "").strip()
        (say("OK", f"GPU 调频门槛 {up}（y700-gpu-dvfs）") if up == "80" else
         say("WARN", f"GPU 调频门槛是 {up}，不是 y700-gpu-dvfs 设的 80（systemctl status y700-gpu-dvfs）"))
    guard("GPU 调频门槛", check_gpu_dvfs)
    # 120 fps streaming (2026-10-20, linux/streaming): KWin keeps uclamp.min 512 (root service, the owner chose a
    # permanent floor) and Moonlight's menu entry / desktop icon start it through the uclamp launcher
    def check_stream_floor():
        if run(["systemctl", "is-enabled", "y700-kwin-uclamp.service"]) != "enabled":
            return
        st = run(["/usr/local/sbin/y700-kwin-uclamp", "--status"]) or ""
        m = re.search(r"(\d+) threads, (\d+) below (\d+)", st)
        if m and m.group(2) != "0":
            # a thread KWin made in the last few seconds waits for the daemon's next rescan (RESCAN_SEC, 5 s)
            time.sleep(6)
            st = run(["/usr/local/sbin/y700-kwin-uclamp", "--status"]) or ""
            m = re.search(r"(\d+) threads, (\d+) below (\d+)", st)
        if run(["systemctl", "is-active", "y700-kwin-uclamp.service"]) != "active":
            say("WARN", "y700-kwin-uclamp 没在跑：KWin 没有抬频地板，120 fps 串流会多掉帧（systemctl status y700-kwin-uclamp）")
        elif not m or m.group(2) != "0":
            say("WARN", f"KWin 有线程不在地板上（隔 6 s 复查仍在）：{st[:90] or '查不到'}（journalctl -u y700-kwin-uclamp；守护要每 RESCAN_SEC 秒补扫新线程）")
        else:
            say("OK", f"KWin {m.group(1)} 个线程 uclamp.min {m.group(3)}（y700-kwin-uclamp）")
        home = "/home/user"
        bad = [p for p in (f"{home}/.local/share/applications/com.moonlight_stream.Moonlight.desktop",
                           f"{home}/Desktop/com.moonlight_stream.Moonlight.desktop")
               if os.path.exists(p) and f"Exec={home}/.local/bin/y700-moonlight" not in (read(p) or "")]
        if bad:
            say("WARN", f"Moonlight 启动项没走抬频启动器：{', '.join(bad)}（/root/streaming/install-moonlight-launcher.sh）")
    guard("串流抬频", check_stream_floor)
    # touch boost (2026-10-21, y700-kwin-uclamp's second thread): GPU min_freq goes up on an edge touch and back at
    # most BOOST_MAX_MS (10 s) later. Still up after that = stuck (the daemon killed mid-boost and ExecStopPost not
    # run, or another tool wrote min_freq): the GPU would idle at the boost clock
    def check_touch_boost():
        if run(["systemctl", "is-enabled", "y700-kwin-uclamp.service"]) != "enabled":
            return
        conf = read("/etc/default/y700-kwin-uclamp") or ""
        m = re.search(r"^\s*BOOST_GPU_MHZ\s*=\s*\"?(\d+)", conf, re.M)
        mhz = int(m.group(1)) if m else 600
        f = "/sys/class/devfreq/3d00000.gpu/min_freq"
        cur = (read(f) or "").strip()
        if not mhz or not cur.isdigit():
            return
        if int(cur) >= mhz * 1_000_000:
            time.sleep(11)          # maybe a gesture right now: a boost lasts at most BOOST_MAX_MS
            cur = (read(f) or "").strip()
        if cur.isdigit() and int(cur) >= mhz * 1_000_000:
            say("WARN", f"GPU 最低频卡在 {int(cur) // 1_000_000} MHz（触摸 boost 没放回去？journalctl -u y700-kwin-uclamp；"
                        f"systemctl restart y700-kwin-uclamp 会复位）")
        else:
            say("OK", f"触摸 boost 待命：GPU 最低 {int(cur) // 1_000_000} MHz，边缘手势时 {mhz} MHz")
    guard("触摸 boost", check_touch_boost)
    # the volume keys live in kded6 and bind to the default sink it sees at start (2026-10-17, the third time they
    # moved the fixed "Speakers" stage instead of the Lenovo tuning sink): its start must have waited for the tuned
    # sink, and the guard's self-heal (restart kded6 when a fixed stage is moved) should not have been needed
    def check_volume_keys():
        if not os.path.exists("/etc/systemd/user/plasma-kded6.service.d/y700-wait-tuned-sink.conf"):
            say("WARN", "kded6 没有“等联想调音”的开机等待：音量键可能绑到固定 100 % 的 Speakers 上（linux/audio/y700-kded6-wait-tuned-sink.conf）")
            return
        waited = run(["sh", "-c", "journalctl --user -b -u plasma-kded6 --no-pager -o cat | grep -E 'tuned sink|default .* kept' | tail -1"], user=True)
        heals = run(["sh", "-c", "journalctl --user -b -u y700-speaker-guard --no-pager -o cat | grep -c 'restarting plasma-kded6'"], user=True) or "0"
        if not waited or "not the default" in waited:
            say("WARN", f"本次开机 kded6 没等到联想调音（{waited or '没有等待记录'}）：按一次音量键看调的是不是“扬声器（联想调音）”")
        elif heals.isdigit() and int(heals) > 0:
            say("WARN", f"音量键本次开机绑错过 {heals} 次（守护已重启 kded6 自愈）：journalctl --user -u y700-speaker-guard | grep kded6，查是什么又改了默认输出")
        else:
            say("OK", f"音量键对准联想调音（kded6 开机时：{waited}）")
    guard("音量键", check_volume_keys)
    # y700-speaker-guard is Rust since 11-03 (linux/audio/speaker-guard): a script there is the bash version back (a
    # rollback), a panic shows as automatic restarts (Restart=on-failure; NRestarts starts from 0 at a manual restart
    # and a boot), and it waits on pipewire-pulse events: when its last word about them is "lost" or "no ..." (not
    # "back", nor a later start), it is checking every 2 s - protection as before, but the bash version's cost and more
    def check_speaker_guard():
        b = "/usr/local/libexec/y700-speaker-guard"
        try:
            elf = open(b, "rb").read(4) == b"\x7fELF"
        except OSError:
            return
        if not elf:
            say("WARN", f"扬声器守护 {b} 不是编译好的 Rust 程序（11-03 起是 Rust；回滚到 bash 版才会这样；"
                        "在平板上重跑 y700/linux/audio/speaker-guard/install.sh）")
            return
        r = run(["systemctl", "--user", "show", "-p", "NRestarts", "--value", "y700-speaker-guard.service"], user=True)
        last = run(["sh", "-c", "journalctl --user -b -u y700-speaker-guard --no-pager -o cat "
                    "| grep -E 'watching the default output|pulse event connection' | tail -1"], user=True)
        if r.isdigit() and int(r) > 5:
            say("WARN", f"扬声器守护自动重启了 {r} 次（本次开机或上次手动重启以来），Rust 版崩了才会这样"
                        "（journalctl --user -b -u y700-speaker-guard | grep panicked）")
        elif last.startswith(("pulse event connection lost", "no pulse event connection")):
            say("WARN", f"扬声器守护收不到 pipewire-pulse 的事件（{last}），正每 2 秒查一次：保护照常，但费电"
                        "（systemctl --user status pipewire-pulse；README『扬声器守护』）")
    guard("扬声器守护", check_speaker_guard)
    # the game overlay is a Rust binary since 2026-10-17 (linux/games/hud/install.sh); the unit runs it directly, so
    # a Python script or a missing file there means a half-done install (Restart=on-failure, no start limit: it
    # would restart every 3 s); a sampling panic is logged, not fatal. Since 10-22 the unit runs `--sampler` and the
    # status bar shows the numbers (linux/dock/y700-shellbar: HudLine.qml in an app, HudWidget.qml on the desktop):
    # the old unit (the GTK bar) beside a status bar that shows them is every number twice; the new unit with a
    # status bar that does not is numbers nobody sees
    def check_hud():
        b = "/home/user/.local/bin/y700-hud-overlay"
        unit = slurp("/home/user/.config/systemd/user/y700-hud-overlay.service")
        if unit is None:
            return
        try:
            elf = open(b, "rb").read(4) == b"\x7fELF"
        except OSError:
            elf = None
        if not elf:
            say("WARN", f"性能浮层 {b} {'不见了' if elf is None else '不是编译好的 Rust 程序'}：浮层一打开就会反复崩溃重启"
                        "（在平板上重跑 y700/linux/games/hud/install.sh）")
            return
        sampler = "--sampler" in unit
        bar = os.path.exists("/usr/local/share/y700-shellbar/qml/HudLine.qml")
        if bar and not sampler:
            say("WARN", "性能浮层的服务还是旧的 GTK 横条（单元里没有 --sampler），状态栏也显示同一组数字，打开就是两份"
                        "（在平板上重跑 y700/linux/games/hud/install.sh）")
            return
        if sampler and not bar:
            say("WARN", "性能浮层只采样不显示：装着的状态栏没有 HudLine.qml，打开浮层什么也看不到"
                        "（重装状态栏 y700/linux/dock/y700-shellbar/install.sh）")
            return
        n = run(["sh", "-c", "journalctl --user -b -u y700-hud-overlay --no-pager | grep -c 'sample failed'"], user=True) or "0"
        r = run(["systemctl", "--user", "show", "-p", "NRestarts", "--value", "y700-hud-overlay.service"], user=True) or "0"
        if n.isdigit() and int(n) > 0:
            say("WARN", f"性能浮层本次开机采样出错 {n} 次（journalctl --user -u y700-hud-overlay | grep 'sample failed'）")
        elif r.isdigit() and int(r) > 5:
            why = "采样器不碰 GPU，重启就是崩了" if sampler else "GPU 卡死自愈每次一回"
            say("WARN", f"性能浮层本次开机重启了 {r} 次（{why}；看 journalctl --user -u y700-hud-overlay）")
        elif sampler:
            say("OK", "性能浮层是 Rust 采样器，数字在状态栏和桌面小组件里；本次开机没有采样出错")
        else:
            say("OK", "性能浮层是 Rust 版，本次开机没有采样出错")
    guard("性能浮层", check_hud)

    # power tweaks (linux/power/install.sh, 2026-10-15)
    polls = {d: (slurp(f"/sys/class/devfreq/{d}/polling_interval") or "").strip() or None for d in ("ddr", "llcc", "ddr-qos")}
    if all(v == "1000" for v in polls.values()):
        say("OK", "内存调频统计每秒轮询一次（udev 规则在生效）")
    else:
        say("WARN", f"内存调频统计轮询不是 1000 ms：{polls}（每 2 ms 一次会多出约 950 次/秒中断；linux/power/install.sh）")
    # crash-dump mode is left 3 min after boot (y700-dumpmode-off.timer): only a kernel panic then reboots after 10 s
    # instead of sitting in XBL dump mode at ~1.6 W (2026-10-15 03:41, 7 h, 73 % -> 37 %). "off" clears the TCSR
    # dload bits only: SDI stays armed, so a firmware reset still dumps and waits (2026-10-31 21:04, 2 h 9 min) until y16
    # (patch 1058: switching off also disables SDI and logs the SCM call's result once, linux/kernel-y16/NOTES.md)
    dm = run(["cat", "/sys/module/qcom_scm/parameters/download_mode"])
    up = float(open("/proc/uptime").read().split()[0])
    ky = re.search(r"-y(\d+)$", cur["kernel"])
    sdi = [l for l in run(["journalctl", "-k", "-b", "--no-pager", "-o", "cat", "-g", "SDI disable: "]).splitlines()
           if "download mode off, SDI disable: " in l] if dm == "off" else []
    if sdi and all(l.endswith("SDI disable: 0") for l in sdi):
        say("OK", "转储模式已退出，SDI 也关了（y16 的 1058）：内核 panic 10 秒后重启，看门狗复位也直接重启（11-01 咬测试）；"
                  "固件当场判致命的复位、整机卡死时的咬还没验证过（README「内核 y16」）")
    elif sdi:
        say("WARN", f"转储模式退出了，但 SDI 没关掉（{sdi[-1]}）：看门狗复位仍会卡在转储界面耗电（linux/kernel-y16/NOTES.md 风险 1）")
    elif dm == "off" and ky and int(ky.group(1)) >= 16:
        say("WARN", "y16 起关转储模式时内核会关 SDI 并打一行「download mode off, SDI disable: 0」，这次开机没有：1058 没生效？"
                    "（journalctl -k -b -g 'SDI disable'）")
    elif dm == "off":
        say("OK", "转储模式已退出（内核 panic 会 10 秒后重启；固件接手的复位在 y16 前仍会进转储模式，见 README「10-31 21:04 死机」）")
    elif up < 300:
        say("INFO", f"开机 {up:.0f} s，转储模式还没到关闭时间（3 min）")
    else:
        say("WARN", f"download_mode 是 {dm}：死机会卡在转储模式耗电（systemctl status y700-dumpmode-off.timer；linux/power/install.sh --dumpmode-off）")
    # printk time prefix (linux/power/y700-printk-time.conf, 2026-11-01): the upstream initramfs switches it off
    if read("/sys/module/printk/parameters/time") == "Y":
        say("OK", "内核日志带时间戳（死机时控制台尾部能和飞行记录器对时间）")
    else:
        say("WARN", "内核日志没有时间戳：/etc/tmpfiles.d/y700-printk-time.conf 没生效（linux/power/install.sh；"
                    "echo Y > /sys/module/printk/parameters/time）")

    # ---- the boot-time e2fsck of the roots (kernel y17, 2026-11-01; FSCK_GREP above): every boot since the last --save
    # (not the one it ran in: that run read it) and this one, unless the last --save ran in this one (11-01 review: a
    # repair at this boot came back every day until a reboot; a mark it left still shows in tune2fs below). It never
    # stops a boot, so only this says what it did:
    # exit 0 clean; 1-3 repaired = the disk was damaged since the last check (a crash, a hard reset) - WARN, except on
    # the first checked boot after unchecked ones (the old mark from before y17: expected, INFO); 4-7 errors left and
    # 8+ / stopped / the 600 s limit - WARN; a y17+ boot with no result line - WARN. The kernel's ext4 complaints count
    # only after the boot's last check (before it they are what the check is about: the first y17 boot's remount,rw
    # of the still-marked root says "mounting fs with errors" once). Then the root's state now (tune2fs -l)
    def check_bootfsck():
        boots = list_boots()
        ids = [b["boot_id"] for b in boots]
        scope = ended[pos + 1:] if pos is not None else todo
        scope = [(b["boot_id"], f"开机 {b['index']}（{b['boot_id'][:8]}）") for b in scope]
        if not cur["boot8"] or old.get("boot8") != cur["boot8"]:
            scope.append(("0", "本次开机"))
        seen = {}

        def events(bid):
            if bid not in seen:
                lines = run(["journalctl", "-k", "-b", bid, "--no-pager", "-o", "cat", "-g", FSCK_GREP]).splitlines()
                rel = next((l.split()[2] for l in lines if l.startswith("Linux version ") and len(l.split()) > 2), None)
                seen[bid] = (rel, [l.strip() for l in lines if not l.startswith("Linux version ")])
            return seen[bid]

        def checked(bid):
            return any(FSCK_RESULT.search(l) for l in events(bid)[1])

        clean = 0
        for bid, label in scope:
            rel, ev = events(bid)
            rel = cur["kernel"] if bid == "0" else rel
            ky = re.search(r"-y(\d+)$", rel or "")
            res = [(i, FSCK_RESULT.search(l)) for i, l in enumerate(ev) if FSCK_RESULT.search(l)]
            if not res:
                nof = next((l for l in ev if "no e2fsck in this image" in l), None)
                if nof:
                    say("WARN", f"{label}的 initramfs 里没有 e2fsck（{nof[:90]}）：根分区没查")
                elif ky and int(ky.group(1)) >= FSCK_FIRST_Y:
                    say("WARN", f"{label}跑的是 {rel}（y{FSCK_FIRST_Y} 起开机要查根分区），却没有磁盘检查的结果行：initramfs 里的 "
                                f"init 不对？（journalctl -k -b {bid} -t baldur | grep fsck）")
                continue
            # the boot before this one in journald's list ran no check: its repair is the old mark's (first y17 boot)
            me = boots[-1]["boot_id"] if bid == "0" and boots else bid      # list_boots: oldest first, this boot last
            i = ids.index(me) if me in ids else 0
            first = i > 0 and not checked(ids[i - 1])
            bad = False
            for _, m in res:
                name, dev, rc, what, secs = m.group(1), m.group(2), int(m.group(3)), m.group(4), m.group(5)
                where = f"{name} {dev}：exit {rc}（{what}），{secs} s"
                if rc == 0 and "limit" not in what:
                    continue
                bad = True
                if 1 <= rc <= 3 and "limit" not in what and first:
                    say("INFO", f"{label}是头一次带开机磁盘检查，修掉了 y{FSCK_FIRST_Y} 之前留下的错误（{where}），这是预期的；"
                                "详细输出在 /var/log/baldur-fsck.log")
                elif 1 <= rc <= 3 and "limit" not in what:
                    say("WARN", f"{label}的磁盘检查修了根分区（{where}）：上次检查以来磁盘被弄坏过，多半是死机或硬复位，已经修好；"
                                "详细输出在 /var/log/baldur-fsck.log")
                elif 4 <= rc <= 7:
                    say("WARN", f"{label}的磁盘检查有修不了的错误（{where}）：要在根分区卸下时手动跑 e2fsck -f"
                                "（从别的系统里，README「内核 y17」）；开机照常，但错误还在")
                else:
                    say("WARN", f"{label}的磁盘检查没做完（{where}）：这次开机没查完；看 /var/log/baldur-fsck.log，"
                                "下次开机会再查")
            devs = {m.group(2)[len("/dev/"):] for _, m in res}
            after = [l for l in ev[res[-1][0] + 1:] if any(f"({d})" in l or f"(device {d})" in l for d in devs)]
            if after:
                bad = True
                say("WARN", f"{label}检查完以后内核又报了根分区的 ext4 问题 {len(after)} 次（{after[0][:100]}）："
                            f"下次开机 e2fsck -p 会再查（journalctl -k -b {bid} -g EXT4-fs）")
            clean += not bad
        if clean:
            say("OK", f"开机磁盘检查：{clean} 次开机（上次体检以来，含本次）根分区都查过、干净")
        dev = run(["findmnt", "-no", "SOURCE", "/"])
        st = run(["tune2fs", "-l", dev]) if dev.startswith("/dev/") else ""
        state = re.search(r"^Filesystem state:\s*(.+?)\s*$", st, re.M)
        errs = re.search(r"^FS Error count:\s*(\d+)", st, re.M)
        ky = re.search(r"-y(\d+)$", cur["kernel"])
        if not state:
            say("INFO", f"读不到根分区（{dev or '?'}）的 ext4 状态（tune2fs -l）")
        elif state.group(1) == "clean" and not errs:
            say("OK", f"根分区 {dev} 的 ext4 状态 clean，没有记着错误")
        else:
            fix = ("下次开机 initramfs 的 e2fsck -p 会修" if ky and int(ky.group(1)) >= FSCK_FIRST_Y
                   else f"这个内核开机不查（y{FSCK_FIRST_Y} 起才查，README「内核 y17」）")
            say("WARN", f"根分区 {dev} 的 ext4 状态是「{state.group(1)}」" + (f"，记着 {errs.group(1)} 次错误" if errs else "")
                        + f"：{fix}；带着错误标记时死机后的孤儿文件不回收、trial 漏记（README「10-31 21:04 死机」）")
    guard("开机磁盘检查", check_bootfsck)

    # ---- crash forensics (cx-collapse experiments, 2026-10-16): new pstore panic records, a new rawdump
    def check_panic_records():
        found = new_panic_records(old, cur)
        if found:
            say(*found)
    guard("pstore 新转储", check_panic_records)

    def check_rawdump():
        rd = rawdump_summary()
        if rd == "unreadable":                      # no such partition / not root: keep the baseline as it was
            if "rawdump" in old:
                cur["rawdump"] = old["rawdump"]
            return
        if rd is None:
            cur["rawdump"] = None
            if old.get("rawdump"):
                say("INFO", "rawdump 分区里的转储没了（被清空或重写成空）")
            return
        cur["rawdump"] = rd["hash"]
        where = f"{rd['sections']} 段，lastkmsg {rd['kmsg_bytes']} B"
        if "rawdump" not in old:
            say("INFO", f"rawdump 分区里有一份崩溃转储（{where}；尾行 {rd['tail'][-1]}）：记入基线，以后只报新的")
        elif old["rawdump"] != rd["hash"]:
            say("WARN", f"新的崩溃转储：XBL 重写了 rawdump 分区（{where}），说明机器进过转储模式、在那里等过人"
                        "（download_mode 还是 full，或复位是固件接手的——y16 前关了 download_mode 也会这样，10-31 21:04 同款）。"
                        f"lastkmsg 尾部：" + " ｜ ".join(rd["tail"]) +
                        f"；RST_STAT={rd['regs']['RST_STAT.BIN']} PMIC_PON={rd['regs']['PMIC_PON.BIN']}"
                        "（原始字节，解码见 cx-collapse/RESEARCH.md §2.6；导出：rawdump-ls /dev/disk/by-partlabel/rawdump lastkmsg.log RST_STAT.BIN PMIC_PON.BIN）")
        else:
            say("OK", "rawdump 分区没有新的崩溃转储")
    guard("rawdump", check_rawdump)

    # ---- CX experiment hygiene: a knob left on after cx-exp.sh (its EXIT trap restores; a killed trap does not)
    def check_cx_knobs():
        aco, aso = read(f"{CX_PARAMS}/allow_cluster_off"), read(f"{CX_PARAMS}/allow_system_off")
        units = [l.split()[0] for l in run(["systemctl", "list-units", "--plain", "--no-legend", "--type=service", "--state=active,activating",
                                            "y700-cx-exp*", "y700-cx-ladder*", "y700-cx-idle*", "y700-cx-night*", "y700-offmeasure*"]).splitlines()
                 if l.strip() and not l.startswith("ERROR")]
        knobs = f"allow_cluster_off={aco} allow_system_off={aso if aso is not None else '无（不是 y10）'}"
        if aco is None:
            say("INFO", f"没有 {CX_PARAMS}/allow_cluster_off（内核没带 0118？）")
        elif units:
            say("INFO", f"CX 实验 {', '.join(units)} 正在跑（{knobs}）：实验期间别碰平板")
        elif (aco in ("Y", "1") or aso in ("Y", "1")) and os.path.exists("/run/y700-cx-auto.armed")                 and run(["systemctl", "is-active", "y700-cx-auto.service"]) == "active":
            say("OK", f"旋钮由 y700-cx-auto 打开着（熄屏、用电池时的 E3a 日常省电；{knobs}）")
        elif aco in ("Y", "1") or aso in ("Y", "1"):
            say("WARN", f"实验旋钮没复原：{knobs}，而没有 y700-cx-exp 在跑（cx-exp.sh 的 EXIT trap 没执行到？）。"
                        f"echo 0 > {CX_PARAMS}/allow_cluster_off（allow_system_off 同理）——上游 0118 记录的复位就是开着它时发生的")
        else:
            say("OK", f"CX 实验旋钮都在默认值（{knobs}）")
    guard("CX 实验旋钮", check_cx_knobs)

    # y700-cx-auto (2026-10-17): E3a while the screen is off on battery; disables itself after a boot that ended armed
    def check_cx_auto():
        if not os.path.exists("/etc/systemd/system/y700-cx-auto.service"):
            return
        dis = read("/var/lib/y700/cx-auto.disabled")
        state = run(["systemctl", "is-active", "y700-cx-auto.service"])
        if dis and "the owner: y700-cx-auto --disable" in dis:
            say("INFO", f"CX 自动省电已被手动停用：{dis}（要恢复：y700-cx-auto --enable）")
        elif dis:
            say("WARN", f"CX 自动省电已停用：{dis}——如果是一次复位，看上一次开机的飞行记录器尾巴；确认没事后 y700-cx-auto --enable")
        elif state != "active":
            say("WARN", f"y700-cx-auto 是 {state}（journalctl -u y700-cx-auto）：熄屏不再自动省电")
        else:
            arms = run(["sh", "-c", "journalctl -b -u y700-cx-auto --no-pager -o cat | grep -c '^armed'"]) or "0"
            say("OK", f"CX 自动省电在跑（本次开机熄屏时打开过 {arms} 次）")
    guard("CX 自动省电", check_cx_auto)

    # 2026-10-18: armed is not effective. From 10-17 18:24 to the 10-18 05:50 reboot E3a was armed every time the screen
    # went off, yet the system domain (apps-pc) was entered 0 times: plasmashell's network applet kept a BusyIndicator
    # animation running with its popup hidden and the screen off, Qt drove it with a ~130 Hz timer on cpu1, and the
    # cluster governor vetoed cluster0 (so the system domain) every time. Healthy armed screen-off is ~20 entries/s.
    # Same symptom after the reboot: Claude desktop's GPU-process VizCompositorThread ticking at 120 Hz with idle renderers
    # (the panel went off with a frame still unpresented); a 10 s screen-on/off cycle stopped it and the system domain
    # went 0 -> 30/s. Judged from the flight recorder's pd= increments over the most recent 30 armed screen-off minutes of this boot.
    # 10-22: those 30 minutes are armed rows, not wall-clock, and may span several screen-offs: an 87-minute stuck stretch
    # (18:13-19:40, right after CarPlay closed) kept the verdict at WARN after the owner had woken the screen once and the
    # next screen-off was healthy again (27/s). So the stretches are told apart: when the 30 minutes look stuck but the
    # latest screen-off (>= 2 rows) does enter the system domain, that is OK, and this boot's stuck stretches are an INFO.
    def check_cx_effect():
        cur = os.path.realpath(f"{FLIGHTREC}/current.log")
        if not os.path.exists(cur):
            return
        eps, ep, prev_t = [], None, None    # stretches of consecutive armed screen-off rows: (seconds, at, cl0, cl1, sys use)
        for line in tail_text(cur, 4 * 1024 * 1024).splitlines():
            if not line.startswith("t="):
                if line.startswith(("HEADER", "STOP")):
                    prev_t, ep = None, None
                continue
            f = dict(kv.split("=", 1) for kv in line.split() if "=" in kv)
            try:
                t = float(f["t"])
            except (KeyError, ValueError):
                continue
            dt, prev_t = (t - prev_t if prev_t is not None else 0), t
            m = re.search(r"pd=cl0:(\d+)/\d+,cl1:(\d+)/\d+,sys:(\d+)/", line)
            if f.get("dpms") == "Off" and f.get("aco") == "Y" and f.get("aso") == "Y" and m and 0 < dt <= 30:
                if ep is None:
                    ep = []
                    eps.append(ep)
                ep.append((dt, f.get("at", "?"), *map(int, m.groups())))
            else:
                ep = None
        rows = [r for e in eps for r in e]
        secs_of = lambda rs: sum(r[0] for r in rs)
        sys_rate = lambda rs: sum(r[4] for r in rs) / secs_of(rs)
        span = lambda rs: f"{rs[0][1]}–{rs[-1][1]}"
        stuck = [e for e in eps if secs_of(e) >= 600 and sys_rate(e) < 1]
        def stuck_info():
            if stuck:
                say("INFO", "本次开机熄屏省电卡住过：" + "、".join(f"{span(e)}（{secs_of(e) / 60:.0f} 分钟，系统域 {sys_rate(e):.1f} 次/秒）"
                                                       for e in stuck[-5:])
                            + "，之后已恢复。卡住时亮屏几秒再熄屏就好；想抓是谁，卡住时熄屏跑 y700-whoawake 20（README『熄屏省电开着却没生效』）")
        win, secs = [], 0.0
        for r in reversed(rows):
            if secs >= 1800:
                break
            win.append(r)
            secs += r[0]
        if secs < 600:
            say("INFO", f"熄屏省电效果还看不出来：本次开机飞行记录器里熄屏且旋钮打开的时间只有 {int(secs // 60)} 分钟（要 ≥10 分钟才判断）")
            return
        win.reverse()
        c0, c1, sy = (sum(r[i] for r in win) / secs for i in (2, 3, 4))
        rates = f"系统域 {sy:.1f} 次/秒，cluster0 {c0:.1f}，cluster1 {c1:.1f}"
        if sy >= 1:
            say("OK", f"熄屏省电生效：最近 {secs / 60:.0f} 分钟熄屏省电期间（{span(win)}）{rates}（正常约 20 次/秒）")
            stuck_info()
            return
        latest = eps[-1]
        if len(latest) >= 2 and sys_rate(latest) >= 1:
            say("OK", f"熄屏省电生效：最近一次熄屏 {span(latest)} 系统域 {sys_rate(latest):.1f} 次/秒"
                      f"（之前累计 {secs / 60:.0f} 分钟的熄屏里系统域只有 {sy:.1f} 次/秒，见下一行）")
            stuck_info()
            return
        last = next((r[1] for r in reversed(rows) if r[4] > 0), None)
        say("WARN", f"熄屏省电开着但没生效：最近 {secs / 60:.0f} 分钟熄屏、旋钮打开（{span(win)}），{rates}（正常约 20 次/秒；"
                    f"{'本次开机最后一次进系统域是 ' + last if last else '本次开机熄屏时一次都没进过系统域'}）——有东西每秒把 CPU 叫醒上百次，"
                    "熄屏时跑 y700-whoawake 20，按线程的唤醒排第一的通常就是。见过的：plasmashell 网络小程序 Wi‑Fi 开关的忙碌动画"
                    "在弹窗收起、熄屏后还在跑（10-17 18:24 起；systemctl --user -M user@ restart plasma-plasmashell 或重启平板）；"
                    "Claude 桌面版 / Chrome 的 GPU 进程里 VizCompositorTh 按刷新率空转（10-18 起它们带 WaylandExternalBeginFrameSource "
                    "启动就不该再空转，看上面「Chromium 新帧源开关」那项；没带开关时亮屏几秒再熄屏就停）；"
                    "10-22 两次都是关掉 CarPlay 后几秒内熄屏卡住的，亮屏一下再熄屏就恢复（谁在画没坐实）。"
                    "细节：README『熄屏省电开着却没生效』『Chromium 新帧源开关』")
    guard("熄屏省电生效", check_cx_effect)

    def check_flightrec():
        unit_file = os.path.exists(FLIGHTREC_UNIT)
        enabled, active = run(["systemctl", "is-enabled", "y700-flightrec"]), run(["systemctl", "is-active", "y700-flightrec"])
        if not unit_file and enabled in ("", "not-found") and active != "active":
            say("INFO", "飞行记录器未安装（CX 实验前装：linux/power/cx-collapse/y700-flightrec.service）")
            return
        logs = glob.glob(f"{FLIGHTREC}/flightrec-*.log")
        archives = glob.glob(f"{FLIGHTREC}/pstore/*/")
        cur_log = os.path.realpath(f"{FLIGHTREC}/current.log")
        size = os.path.getsize(cur_log) if os.path.exists(cur_log) else 0
        age = time.time() - os.path.getmtime(cur_log) if os.path.exists(cur_log) else None
        state = f"本次开机日志 {size / 1024:.0f} KiB，历史 {len(logs)} 份，pstore 归档 {len(archives)} 次开机"
        if active == "active":
            if age is None or age > 120:
                say("WARN", f"飞行记录器 active 但 {os.path.basename(cur_log)} {'不存在' if age is None else f'{age:.0f} s 没更新'}（实验时每秒一行，平时每 10 秒；journalctl -u y700-flightrec）")
            else:
                say("INFO", f"飞行记录器在跑（{state}；{age:.0f} s 前更新）")
        elif enabled == "enabled":
            say("WARN", f"飞行记录器 enabled 但是 {active}（Restart=always 都没拉起来：journalctl -u y700-flightrec）；{state}")
        else:
            say("INFO", f"飞行记录器 {active}（{enabled or '未启用'}）；{state}")
    guard("飞行记录器", check_flightrec)

    # ---- the battery page (linux/power/battery, DESIGN.md section 7, 2026-10-30). Every one of these is silent where
    # it is not installed (no y700-batteryd user unit). The recorder is a systemd user unit of user, asked over
    # that user's bus like the HUD; the ledger and the energy line are judged here directly, the report only for its model (its
    # diag also carries ledger_bytes / ledger_newest_age_s / energy_age_s, which repeat the direct checks and are not
    # used: the report may not be installed yet, and a broken report must not hide a dead recorder)
    batt = {}                                         # check_batteryd's verdict, for check_battery_ledger

    def check_batteryd():
        if not os.path.exists(BATTERYD_UNIT):
            return
        if "batteryd" in old:
            cur["batteryd"] = old["batteryd"]         # kept as it was when NRestarts cannot be read below
        unit = "y700-batteryd.service"
        state = run(["systemctl", "--user", "is-active", unit], user=True)
        batt["active"] = state == "active"
        if not batt["active"]:
            en = run(["systemctl", "--user", "is-enabled", unit], user=True)
            say("WARN", f"电池页的记账服务 y700-batteryd 是 {state or '查不到（user 的用户总线不通？）'}（{en or '?'}）："
                        "从这时起电量曲线和谁用了电都不再记录（journalctl --user -u y700-batteryd 看原因；"
                        "systemctl --user -M user@ restart y700-batteryd，起不来就重跑 linux/power/battery/install.sh）")
        n = run(["systemctl", "--user", "show", "-p", "NRestarts", "--value", unit], user=True)
        if not n.isdigit():
            if batt["active"]:
                say("INFO", f"y700-batteryd 在跑，但读不到它的重启次数（{n[:80] or '空'}），基线照旧")
            return
        n = int(n)
        cur["batteryd"] = {"boot8": cur["boot8"], "nrestarts": n}
        base = old.get("batteryd")
        if not isinstance(base, dict):
            if n:
                say("INFO", f"y700-batteryd 本次开机已自动重启 {n} 次：记入基线，以后只报新的（journalctl --user -u y700-batteryd）")
            elif batt["active"]:
                say("OK", "y700-batteryd 在跑，本次开机没有自动重启过")
            return
        # NRestarts counts the automatic restarts (Restart=on-failure) and starts again from 0 on a new boot, a restart
        # of user's user manager and a manual start / restart: another boot's baseline, or a count below the
        # baseline, means every restart counted now came after the last --save
        b = base.get("nrestarts")
        since = b if base.get("boot8") == cur["boot8"] and isinstance(b, int) and b <= n else 0
        if n > since:
            say("WARN", f"y700-batteryd 自上次体检以来自动重启了 {n - since} 次（本次开机共 {n} 次）：Restart=on-failure 的"
                        "每次重启都是它崩了或被杀了（比如超了单元的 MemoryMax），看 journalctl --user -u y700-batteryd")
        elif batt["active"]:
            say("OK", f"y700-batteryd 在跑，自上次体检以来没有自动重启（本次开机共 {n} 次）")
    guard("电池页记账服务", check_batteryd)

    def check_battery_ledger():
        if not os.path.exists(BATTERYD_UNIT):
            return
        parts = set(glob.glob(f"{BATTERY_LEDGER}/b-*.jsonl"))
        total, newest, early = 0, None, False
        for p in sorted(parts) + glob.glob(f"{BATTERY_LEDGER}/fg-*.log"):   # what ledger.rs prunes, as diag.ledger_bytes
            try:
                st = os.stat(p)
            except OSError:
                continue                              # pruned between the glob and the stat
            total += st.st_size
            if p in parts:
                newest = st.st_mtime if newest is None else max(newest, st.st_mtime)
                early = early or st.st_mtime < 1e9
        mib = total / (1 << 20)
        fresh = None
        if batt.get("active", True):                  # a dead batteryd was WARNed above: its stale ledger is the same news
            age = time.time() - newest if newest is not None else None
            if age is None:
                say("WARN", f"y700-batteryd 在跑，但 {BATTERY_LEDGER} 里一份账本（b-*.jsonl）都没有：它写不了盘？"
                            "journalctl --user -u y700-batteryd")
            elif age <= BATTERY_LEDGER_STALE_S:
                fresh = age
            elif early and uptime_s() < BATTERY_LEDGER_STALE_S + 1800:
                # the RTC starts at 1970 here (ledger.rs): this boot's part, written before chrony set the clock, carries
                # a 1970 mtime (and the newest real mtime is the previous boot's) until the next snapshot / checkpoint,
                # at most 30 min after the clock is right
                say("INFO", "电池页账本上次写入时时钟还没对上（mtime 在 1970 年），过了下一个检查点（≤30 分钟）再看")
            else:
                ago = (f"{age / 60:.0f} 分钟" if age < 7200 else f"{age / 3600:.0f} 小时" if age < 2 * 86400
                       else f"{age / 86400:.0f} 天")
                say("WARN", f"电池页账本已 {ago}没写入（应 ≤40 分钟：亮屏每 5 分钟、熄屏每 30 分钟一次）："
                            "y700-batteryd 卡住了？journalctl --user -u y700-batteryd")
        if total > BATTERY_LEDGER_MAX:
            say("WARN", f"电池页账本加前台日志共 {mib:.1f} MiB，超过 20 MiB（16 MiB 上限加一天的余量）：batteryd 的修剪没起作用"
                        f"（开机和每天第一次亮屏时修剪；按 40 天保留平时只有 5–12 MiB）。ls -la {BATTERY_LEDGER}；"
                        "journalctl --user -u y700-batteryd | grep prune")
        elif fresh is not None:
            say("OK", f"电池页账本 {fresh:.0f} s 前写过，账本加前台日志共 {mib:.1f} MiB（≤20 MiB）")
        elif total:
            say("OK", f"电池页账本加前台日志共 {mib:.1f} MiB（≤20 MiB）")
    guard("电池页账本", check_battery_ledger)

    def check_battery_energy():
        if not os.path.exists(BATTERYD_UNIT) or run(["systemctl", "is-active", "y700-flightrec"]) != "active":
            return                                    # a recorder that is not running is the flight recorder line's news
        line = read_agreed(FLIGHTREC_ENERGY)
        if line is None:
            say("WARN", f"飞行记录器在跑，但没有 {FLIGHTREC_ENERGY}：装的 y700-flightrec 不带电池页的电量累计（acc.rs），"
                        "batteryd 只能降级记账、分不出应用（重装飞行记录器：linux/power/flightrec/deploy.sh）")
            return
        if line is False:
            say("INFO", f"{FLIGHTREC_ENERGY} 连读 4 次都不一样（正好在改写？），这次不判断")
            return
        m = re.match(r"v1 boot=(\w+) t=(\d+) ", line.decode("ascii", "replace"))
        if not m:
            say("WARN", f"{FLIGHTREC_ENERGY} 认不出：{line[:60]!r}（飞行记录器和电池页的版本对不上？）")
            return
        age = mono_s() - int(m.group(2)) / 1000      # t= is CLOCK_MONOTONIC ms
        if cur["boot8"] and m.group(1) != cur["boot8"]:
            say("WARN", f"{FLIGHTREC_ENERGY} 是另一次开机的（boot={m.group(1)}，本次 {cur['boot8']}）：飞行记录器没在更新它"
                        "（journalctl -u y700-flightrec）")
        elif age > BATTERY_ENERGY_STALE_S:
            say("WARN", f"飞行记录器在跑，但电量累计 {FLIGHTREC_ENERGY} 已 {age:.0f} s 没更新（应 ≤60 s，平时每 10 s 一次）："
                        "电池页从这时起只能按电量粗算（journalctl -u y700-flightrec）")
        else:
            say("OK", f"飞行记录器的电量累计 {max(age, 0):.0f} s 前更新过（≤60 s）")
    guard("电池页电量累计", check_battery_energy)

    def check_battery_diag():
        if not os.path.exists(BATTERYD_UNIT) or not os.path.exists(BATTERY_REPORT):
            return
        # as user: its ledger, its user journal, its ~/.config coefficients. The report is read-only (DESIGN.md
        # 6b.b). coreutils timeout stops the report itself; run_rc()'s timeout is only the backstop, since killing sudo
        # with SIGKILL would leave the python behind it running
        rc, raw, err = run_rc(["timeout", str(BATTERY_REPORT_TIMEOUT_S), BATTERY_REPORT, "--json"], user=True,
                              timeout=BATTERY_REPORT_TIMEOUT_S + 10)
        try:
            doc = json.loads(raw) if raw else None
        except ValueError:
            doc = None
        hint = f"sudo -u user {BATTERY_REPORT} --json 看 stderr 里的细节"
        if not isinstance(doc, dict):
            if rc is None or rc == 124:                # timed out (it prints only at the end): timeout's 124, or the backstop
                how = "timeout 到点停了它" if rc == 124 else f"{BATTERY_REPORT_TIMEOUT_S + 10} s 的后备超时到了"
                say("INFO", f"电池页报表 {BATTERY_REPORT_TIMEOUT_S} s 内没出结果（{how}），这次不看系数")
            elif not raw:
                # the report always writes a document, its error document too (exit 0 / 2, DESIGN.md 6b.b): an empty
                # stdout is python dying before cli.main (1: an import error after an upgrade or a partial install) or
                # env / timeout not starting it (126 / 127). That repeats every run, and the page is broken with it
                last = (err.splitlines() or [""])[-1][:160]
                say("WARN", f"电池页报表没输出就退出了（退出码 {rc}：{last or 'stderr 也是空的'}）：打开电池页也会出错（{hint}）")
            else:
                say("WARN", f"电池页报表的输出不是 JSON：{raw[:80]!r}（打开电池页也会出错；{hint}）")
            return
        if "error" in doc:
            say("WARN", f"电池页报表出错：{str(doc['error'])[:160]}（打开电池页也会看到这个错；{hint}）")
            return
        dg = doc.get("diag")
        if not isinstance(dg, dict):
            say("WARN", "电池页报表的 JSON 里没有 diag 块（报表和体检的版本对不上？）")
            return
        num = lambda x: isinstance(x, (int, float)) and not isinstance(x, bool)
        med, learned, model = dg.get("unexplained_median_7d"), dg.get("floor_off_learned_mw"), dg.get("floor_off_model_mw")
        days, flagged = dg.get("coeff_age_days"), dg.get("segments_flagged_7d")
        # like with like (DESIGN.md 6b.a): the learned figure is the P25 of the measured power of the >= 20 min screen-off
        # segments, the model's is its own prediction for those same segments (F_off + wakeups + CPU / GPU / Wi-Fi), so
        # "differs by > 25 %" is read relative to the model's: the learned one is the measurement
        drift = abs(learned - model) / model if num(learned) and num(model) and model > 0 else None
        why = []
        if num(med) and med > BATTERY_UNEXPLAINED_MAX:
            why.append(f"7 天里各放电段「没算清」的中位数 {med * 100:.0f} %（>20 %）")
        if drift is not None and drift > BATTERY_FLOOR_DRIFT_MAX:
            why.append(f"账本里学到的熄屏功率 {learned:.0f} mW，模型对同样这些段算出 {model:.0f} mW（差 {drift * 100:.0f} %，>25 %）")
        if num(days) and days > BATTERY_COEFF_MAX_DAYS:
            why.append(f"系数是 {days:.0f} 天前定的（>90 天）")
        co = doc.get("coeffs") if isinstance(doc.get("coeffs"), dict) else {}
        which = f"系数 v{co.get('version', '?')}{'，还是没标定的先验值' if co.get('calibrated') is False else ''}"
        if why:
            # the shipped priors (coeffs-v1, calibrated false) are not expected to fit the ledger: until the calibration
            # night they are only shown (INFO), or this would notify every day with nothing to do but agree to that night
            cal = co.get("calibrated") is True
            say("WARN" if cal else "INFO", "电池页系数要重标：" + "；".join(why) + f"（{which}"
                + ("" if cal else "：标定前只提示、不报警") + "。标定在作者同意的夜里跑，DESIGN.md 第 9 节第 8 步；"
                "y700-battery-report --fit 只出建议值，人工确认后放 ~/.config/y700-battery/coeffs-v<N>.json）")
            return
        seen = []
        if num(med):
            seen.append(f"7 天里没算清的中位数 {med * 100:.0f} %")
        if drift is not None:
            seen.append(f"熄屏功率学到 {learned:.0f} mW、模型算 {model:.0f} mW")
        if num(days):
            seen.append(f"系数 {days:.0f} 天")
        if num(flagged) and flagged:                  # recorded only (DESIGN.md 6b.a): no threshold
            seen.append(f"7 天里 {flagged} 段标了「模型偏高」")
        say("OK", f"电池页系数不用重标（{'，'.join(seen) or '数据还不够判断'}；{which}）")
    guard("电池页报表", check_battery_diag)

    # never suspend (owner, 2026-10-15 night): PowerDevil idle action "nothing" on battery, sleep.target masked
    pdrc = "/home/user/.config/powerdevilrc"
    pd = slurp(pdrc, "")
    bat_ok = re.search(r"\[Battery\]\[SuspendAndShutdown\][^\[]*AutoSuspendAction=0", pd) is not None
    masked = run(["systemctl", "is-enabled", "sleep.target"]) == "masked"
    if bat_ok and masked:
        say("OK", "不会自动休眠（PowerDevil 电池闲置=无动作，sleep.target 已 mask）")
    else:
        say("WARN", f"休眠保护变了：PowerDevil 电池闲置动作{'正常' if bat_ok else '不是「无动作」'}，sleep.target {'已 mask' if masked else '没 mask'}"
                    "（linux/power/y700-no-suspend.sh）")

    # screen off = really off, waking goes straight to the desktop (owner, 2026-10-24: a password on the on-screen
    # keyboard is too much). PowerDevil 6.6 takes the default of "lock before turning the display off" and of the
    # battery dim / off timeouts from KWin's tablet mode (powerdevilsettingsdefaults.cpp: lock = isMobile; battery
    # 1 / 2 min instead of 2 / 5), KWin enters tablet mode on touch, and PowerDevil rereads the profile on every AC
    # change: with the keys unset, the 10-24 08:59 unplug made every power-key press lock. So the keys are written out
    # in all three profiles. System Settings' power page deletes a key it saves with a value equal to the default of
    # the moment (KConfigSkeleton), which is how they could vanish again. kscreenlocker's idle / resume locks default
    # to on. Read the way KConfig reads: a bool is false for false / no / off / 0 in any case, and an immutable
    # marker [$i] on a key or a group header does not change its name.
    # Battery / low battery dim or screen-off set to "never" is a WARN too (11-01): KDE's power page wrote that into all
    # three profiles the moment it opened (10-30 20:12, [AC] said never without times; linux/power/battery/
    # kcm-never-test.sh), and the screen then stayed on all night unless switched off by hand
    def check_no_lock():
        klrc = "/home/user/.config/kscreenlockerrc"
        pd, kl = (slurp(p, "" if not os.path.exists(p) else None) for p in (pdrc, klrc))   # no file = all defaults
        if pd is None or kl is None:
            say("INFO", f"熄屏不锁屏查不了：{'powerdevilrc' if pd is None else 'kscreenlockerrc'} 读不出来")
            return

        def group(text, header):
            keys, cur = {}, None
            for line in text.lstrip("﻿").splitlines():
                s = line.strip()
                if s.startswith("["):
                    cur = re.sub(r"\[\$i\]$", "", s)
                elif cur == header and "=" in s and not s.startswith("#"):
                    k, v = s.split("=", 1)
                    keys[re.sub(r"\[\$i\]$", "", k.strip())] = v.strip()
            return keys

        def off(v):
            return v is not None and v.lower() in ("false", "no", "off", "0")
        bad = []
        for prof in ("AC", "Battery", "LowBattery"):
            d = group(pd, f"[{prof}][Display]")
            if not off(d.get("LockBeforeTurnOffDisplay")):
                bad.append(f"{prof} 熄屏前锁屏没关")
            if prof != "AC":
                idle = (("变暗", "DimDisplayWhenIdle", "DimDisplayIdleTimeoutSec"),
                        ("熄屏", "TurnOffDisplayWhenIdle", "TurnOffDisplayIdleTimeoutSec"))
                never = [w for w, on, _ in idle if off(d.get(on))]
                loose = [w for w, on, sec in idle if not off(d.get(on)) and sec not in d]
                if never:
                    bad.append(f"{prof} 闲置不{'、不'.join(never)}（「从不」：KDE 电量页打开时会这样写）")
                if loose:
                    bad.append(f"{prof} 闲置{'、'.join(loose)}时间没写死（平板模式下会缩短）")
        dm = group(kl, "[Daemon]")
        if not off(dm.get("Autolock")):
            bad.append("kscreenlocker 闲置自动锁屏没关")
        if not off(dm.get("LockOnResume")):
            bad.append("kscreenlocker 唤醒后锁屏没关")
        if bad:
            say("WARN", "熄屏会锁屏，或闲置变暗 / 熄屏不对：" + "；".join(bad) + "（README「熄屏不锁屏」：kwriteconfig6 写回，"
                        "再 busctl --user call org.kde.Solid.PowerManagement /org/kde/Solid/PowerManagement "
                        "org.kde.Solid.PowerManagement refreshStatus）")
        else:
            say("OK", "熄屏不锁屏：PowerDevil 三档都关了熄屏前锁屏，电池档闲置变暗 / 熄屏开着且时间写死，kscreenlocker 不自动锁")
    guard("熄屏不锁屏", check_no_lock)
    usbc = run(["cat", "/sys/bus/platform/devices/a600000.usb/power/control"])
    if usbc == "auto":
        say("OK", f"USB 控制器允许运行时挂起（现在 {run(['cat', '/sys/bus/platform/devices/a600000.usb/power/runtime_status'])}）")
    else:
        say("WARN", f"USB 控制器 power/control 是 {usbc}，应为 auto（90-y700-usb-rpm.rules；若 OTG 设备识别不了，echo on 回去并记一笔）")
    gov = run(["cat", "/sys/devices/system/cpu/cpuidle/current_governor"])
    avail = run(["cat", "/sys/devices/system/cpu/cpuidle/available_governors"])
    if "teo" in avail and gov != "teo":
        say("WARN", f"cpuidle 调度器是 {gov}，应为 teo（/etc/tmpfiles.d/y700-cpuidle.conf；linux/power/install.sh）")
    elif "teo" in avail:
        say("OK", "cpuidle 调度器 teo")
    ms60 = run(["cat", "/sys/module/msm/parameters/idle_refresh_ms60"])
    if ms60 == "500":
        say("OK", "面板空闲降频 0.5 s/2 s（power-saver 预设）")
    else:
        say("WARN", f"面板空闲降频阈值变成了 {ms60} ms（应为 500；tb323fu-ctl refresh preset power-saver）")

    # our own ath12k build (linux/wifi/y700-ath12k.conf; 1041 station power save) tags itself with
    # MODULE_VERSION "y700-1041" -> /sys/module/ath12k/version when loaded (ath12k has no srcversion)
    ours = f"/usr/local/lib/modules/y700/{k}/ath12k.ko"
    if os.path.exists(ours) or os.path.exists("/sys/module/ath12k/version"):
        want = run(["modinfo", "-F", "version", ours]) if os.path.exists(ours) else "y700-1041"
        have = (slurp("/sys/module/ath12k/version") or "").strip() or None
        if have and have == want:
            say("OK", f"Wi-Fi 跑的是我们编的 ath12k {have}（固件省电生效）")
        else:
            say("WARN", f"加载的 ath12k 版本是 {have}，应为 {want}：固件省电没生效，熄屏多耗约 0.06 W；"
                        "看 /etc/modprobe.d/y700-ath12k.conf 的 install 规则")
    ps = run(["iw", "dev", "wlp1s0", "get", "power_save"])
    lap = run(["systemctl", "is-active", "livi-wifi-ap.service"])
    if lap == "active":
        say("INFO", f"CarPlay 的热点占着 Wi‑Fi（AP 模式没有省电，{ps}）")
    elif lap in ("activating", "deactivating", "reloading"):   # settle reloads ath12k meanwhile: no wlp1s0 for seconds
        say("INFO", f"CarPlay 的热点正在起/停（{lap}），这次不看 Wi‑Fi 省电")
    elif ps.strip().endswith(": on"):   # not `"on" in ps`: run()'s "ERROR ... timed out after 20 seconds" has one
        say("OK", "Wi-Fi 省电模式开着")
    else:
        # y700-carplay-ps-restore's mark (10-24): the hotspot stopped before wlp1s0 was a station again, and its
        # NetworkManager dispatcher hook turns power save on when wlp1s0 next comes up; not connected, that is still due
        pend = "/run/y700-carplay/ps-pending-wlp1s0"
        link = run(["iw", "dev", "wlp1s0", "link"]) if os.path.exists(pend) else ""
        if link.startswith("Not connected"):
            say("INFO", f"Wi-Fi 省电模式是「{ps}」，Wi‑Fi 没连着：CarPlay 停热点时接口还没回到 station，"
                        f"等 NetworkManager 下次连上时由 dispatcher 钩子 90-y700-carplay-ps 开回来（标记 {pend}）")
        else:
            say("WARN", f"Wi-Fi 省电模式是「{ps}」（熄屏多耗约 0.06 W；nmcli 的 wifi.powersave 或性能档开关；"
                        "用过 CarPlay 也会这样：LIVI 起热点时关省电，10-22 起停热点后由 y700-carplay-ps-restore 开回来，"
                        + (f"这次它留了待办 {pend}，连上 Wi‑Fi 时本该由 dispatcher 钩子 90-y700-carplay-ps 开回来，"
                           if os.path.exists(pend) else "")
                        + "看 journalctl -t y700-carplay。立即恢复：iw dev wlp1s0 set power_save on）")

    # wireless CarPlay (linux/carplay, 2026-10-17): LIVI unmodified + an MFi authentication coprocessor on /dev/i2c-99
    # (not part of this repo) + the launcher's fixes; checked once the launcher is installed.
    def check_carplay():
        if not os.path.exists("/usr/local/bin/y700-carplay"):
            return
        bad, notes = [], []
        core = run(["pidof", "livi-core"])
        busy = bool(core) and not core.startswith("ERROR")
        if core.startswith("ERROR"):
            bad.append(f"判断不了 LIVI 是否在跑（pidof：{core[:80]}）")
        ap = run(["systemctl", "is-active", "livi-wifi-ap.service"])
        if not os.path.exists("/dev/i2c-99"):
            bad.append("没有 /dev/i2c-99（MFi 认证协处理器，不在本仓库），iPhone 认证会失败（linux/carplay/README.md「认证硬件」）")
        dropin = read("/etc/systemd/system/livi-wifi-ap.service.d/y700.conf", "")
        if "y700-carplay-ap-settle" not in dropin:
            bad.append("热点单元的 drop-in 没挂 y700-carplay-ap-settle：手机可能连不上热点（install-livi.sh）")
        # LIVI's unit stops in TimeoutStopSec=8, which systemd also gives ExecStopPost: ps-restore was killed there
        # on 10-23 15:01 and power save stayed off. The drop-in gives 40 s (ps-restore ends within ~29 s)
        tos = re.findall(r"^TimeoutStopSec=(\d+)s?\s*$", dropin or "", re.M)
        if (not re.search(r"^ExecStopPost=-?\S*/y700-carplay-ps-restore\b", dropin or "", re.M)   # not its comments
                or not tos or int(tos[-1]) < 30):
            bad.append("热点单元的 drop-in 没挂 y700-carplay-ps-restore 或没把 TimeoutStopSec 放到 ≥30 s："
                       "停 CarPlay 后 Wi‑Fi 省电可能开不回来（LIVI 的单元只给 8 s，重跑 install-livi.sh）")
        # ps-restore's second half (10-24): NetworkManager runs a dispatcher script only when root owns it, nobody
        # else may write it and it is executable; otherwise it skips it, and says so only in its own journal
        hook = "/etc/NetworkManager/dispatcher.d/90-y700-carplay-ps"
        try:
            hst = os.stat(hook)
        except OSError:
            hst = None
        if (hst is None or hst.st_uid != 0 or hst.st_mode & 0o022 or not hst.st_mode & 0o100
                or "y700-carplay-ps-restore" not in (read(hook, "") or "")):
            bad.append(f"NetworkManager 的 dispatcher 钩子 {hook} "
                       + ("不在" if hst is None else "不是 root 所有、只有 root 能写的可执行文件，或没调 y700-carplay-ps-restore")
                       + "：停 CarPlay 时接口没及时回到 station 的话，Wi‑Fi 省电要等手动开（重跑 install-livi.sh）")
        if run(["systemctl", "is-enabled", "y700-carplay-boot-guard.service"]) != "enabled":
            bad.append("y700-carplay-boot-guard 没启用：LIVI 崩溃后断电，开机会没有 Wi‑Fi")
        so = "/usr/local/lib/y700-carplay/y700-gst-colorimetry.so"
        try:
            elf = open(so, "rb").read(4) == b"\x7fELF"
        except OSError:
            elf = False
        launcher = read("/usr/local/bin/y700-carplay", "") or ""
        if not elf or "LIVI_GST_PRELOAD" not in launcher:
            bad.append("色彩修正库或启动器里的 LIVI_GST_PRELOAD 不在：iPhone 画面会黑（install-livi.sh）")
        elif "libwayland-client" not in launcher:
            bad.append("启动器的 LIVI_GST_PRELOAD 没带系统的 libwayland-client：LIVI 10 自带的 1.23 版先被找到，"
                       "Mesa 的 EGL 加载失败，iPhone 画面会黑（install-livi.sh）")
        if busy:
            # the libraries mapped, not the variable: gst-host inherits LIVI_GST_PRELOAD from the launcher either way.
            # 10.0.0's bundle has its own libwayland-client (1.23, through its RUNPATH): mapped instead of the system's,
            # Mesa's libEGL_mesa does not load (wl_fixes_interface is 1.24's) and the GL chain stops, black (10-23)
            gst = run(["pidof", "livi-gst-host"]).split()
            maps = (read(f"/proc/{gst[0]}/maps", "") or "") if gst and gst[0].isdigit() else ""
            wl = {l.split()[-1] for l in maps.splitlines() if "/libwayland-client.so" in l}
            if maps and "y700-gst-colorimetry.so" not in maps:
                bad.append(f"CarPlay 的视频进程 {gst[0]} 没加载色彩修正库：iPhone 画面会黑"
                           "（不是从桌面图标 y700-carplay 起的？LIVI 的 LIVI_GST_PRELOAD 口子还在吗？）")
            elif maps and any(not p.startswith("/usr/lib/") for p in wl):
                bad.append(f"CarPlay 的视频进程 {gst[0]} 加载的是 LIVI 自带的 libwayland-client"
                           f"（{'、'.join(sorted(p for p in wl if not p.startswith('/usr/lib/')))}）：Mesa 的 EGL 起不来，"
                           "iPhone 画面会黑（启动器的 LIVI_GST_PRELOAD 要带 /usr/lib/aarch64-linux-gnu/libwayland-client.so.0）")
        # Siri over Wi-Fi: 9.4.0's own livi-core and gst-host sent the microphone nowhere (10-19); upstream's fix
        # (b82707ad) is in 10.0.0, checked with the iPhone on 10-23. Nothing is checked for it any more: going back to
        # 9.4.0 is a deliberate step (linux/carplay/README.md, its /opt/livi-9.4.0 still has the rebuilt pair), and a
        # LIVI that changes is the "LIVI changed" item's business.
        # the launcher's keep_awake: while the phone's frames come in, kde-inhibit keeps PowerDevil from dimming and
        # blanking the panel (10-19: on battery it went off 5 min after the last touch, mid-session). Its loop touches a
        # stamp every 12 s while LIVI runs; the holder ("y700-carplay --while-frames") lives while frames come.
        if "--while-frames" not in launcher or not os.path.exists("/usr/bin/kde-inhibit"):
            bad.append("启动器没有保持亮屏（keep_awake）或没装 kde-inhibit：开车时屏幕会变暗、5 分钟没碰就息屏（install-livi.sh）")
        elif busy:
            def age(p):
                try:
                    return time.time() - os.path.getmtime(p)
                except OSError:
                    return None
            stamp, fage = age("/run/user/1000/y700-carplay-frames"), age("/home/user/.config/LIVI/log/gst-host.log")
            holder = run(["pgrep", "-f", "y700-carplay --while-frames"]).split()
            held = run(["ps", "-o", "etimes=", "-p", holder[0]]).strip() if holder and holder[0].isdigit() else ""
            # an Android phone sends no frame while its picture is still; its session on 5277 holds the panel too
            aa_on = bool(run(["ss", "-Htn", "state", "established", "( sport = :5277 )"]).strip())
            frames_on = fage is not None and fage <= 15
            what = "手机画面在来" if frames_on else "安卓手机的 Android Auto 连着"
            if stamp is None or stamp > 30:
                bad.append("保持亮屏的循环没在跑：开车时屏幕会变暗、息屏（LIVI 不是从桌面图标 y700-carplay 起的？）")
            elif frames_on or aa_on:
                if not holder:
                    notes.append(f"{what}，保持亮屏还没接上（刚连上的十几秒内正常）")
                elif held.isdigit() and int(held) >= 10:     # PowerDevil applies an inhibition ~5 s after it is asked
                    has = run(["gdbus", "call", "--session", "-d", "org.kde.Solid.PowerManagement", "-o",
                               "/org/kde/Solid/PowerManagement/PolicyAgent", "-m",
                               "org.kde.Solid.PowerManagement.PolicyAgent.HasInhibition", "4"], user=True)
                    if "true" in has:
                        notes.append(f"{what}，屏幕保持亮着")
                    else:
                        bad.append(f"保持亮屏在跑，PowerDevil 却没认（HasInhibition：{has[:60] or '没有输出'}）：开车时屏幕会变暗、息屏")
            elif holder and fage is not None and fage > 40:   # the holder ends 12-24 s after the last frame
                bad.append(f"手机已经 {int(fage)} 秒没发画面，保持亮屏却还没放：停车后屏幕不会灭"
                           "（pkill -f 'y700-carplay --while-frames'）")
        if ap in ("activating", "deactivating", "reloading"):
            notes.append(f"热点单元正在起/停（{ap}），没看 Wi‑Fi 是否被锁")
        elif os.path.exists("/etc/NetworkManager/conf.d/99-livi-ap-unmanaged.conf") and ap != "active" and not busy:
            bad.append("LIVI 不在跑，但 99-livi-ap-unmanaged.conf 还在：Wi‑Fi 被锁在 NetworkManager 外面"
                       "（bash /root/src-carplay-livi/test-guard.sh restore）")
        elif ap == "active" and not busy:
            bad.append("LIVI 不在跑，热点单元却开着：平板上不了网（bash /root/src-carplay-livi/test-guard.sh restore）")
        # livi-core writes its user into the hotspot unit (SUDO_USER when set, else itself) and the hotspot's helperd
        # reads that user's config.json. Started as root through plain sudo (an old dry run, 10-20) it writes root:
        # no config there, so the hotspot goes for wlan0 and never comes up. The next start from the icon rewrites it.
        m = re.search(r"^Environment=SUDO_USER=(\S*)", read("/etc/systemd/system/livi-wifi-ap.service", ""), re.M)
        if m and m.group(1) != "user":
            bad.append(f"热点单元里写的用户是 {m.group(1) or '空'}，不是 user：热点读不到 LIVI 的配置，起不来"
                       "（多半是以 root 经 sudo 起过 LIVI；从桌面图标打开一次 LIVI 就会改回来）")
        # 10.0.0 opens windowed unless KWin makes it full screen (32 px title bar, the dock cut off, 10-23): a rule
        # in kwinrulesrc forcing it for app_id dev.f-io.livi (install-livi.sh step 6; not LIVI_KIOSK=1, with which
        # LIVI's Power Off shuts down the tablet). Any rule listed in General/rules counts, whatever its group's name.
        groups, cur_g = {}, None
        for line in (read("/home/user/.config/kwinrulesrc", "") or "").splitlines():
            line = line.strip()
            if line.startswith("[") and line.endswith("]"):
                cur_g = groups.setdefault(line[1:-1], {})
            elif cur_g is not None and "=" in line:
                k, v = line.split("=", 1)
                cur_g[k.strip()] = v.strip()
        listed = (groups.get("General") or {}).get("rules", "").split(",")
        if not any((groups.get(n) or {}).get("wmclass") == "dev.f-io.livi" and groups[n].get("fullscreen") == "true"
                   and groups[n].get("fullscreenrule") == "2" for n in listed):
            bad.append("KWin 没有强制 LIVI 全屏的规则（kwinrulesrc 的 y700-livi-fullscreen）：LIVI 10 会开成窗口，"
                       "顶上一条 32 px 标题栏、底下 dock 被切掉（重跑 install-livi.sh）")
        # The phone's cluster screen: with it on LIVI advertises a second display and the iPhone, encoding two, gives
        # the main one 30 fps instead of 60 (10-18). 10.0.0 keeps it in "dashboard" (main/cluster/aux, booleans),
        # migrated from 9.4.0's "dashboards" (dash1-4) with any slot that had the screen on: 9.4.0's "main" slots
        # became main = true there, and the phone still sets up a cluster stream (0x7a000010, 10-23). So every screen
        # is off; a file still in 9.4.0's form is judged on dash3/dash4 as before. Wireless Android Auto is on since
        # 10-20 (the owner's ask; LIVI's default is off). The size asked of the phones is 1600x1000 since 10-20: at
        # LIVI's own 1152x720 Android Auto takes its 720p tier, stretched ~2.6x onto the panel (blurred, the first
        # Android test). The dpi is LIVI's own (0) since 10-23: 10.0.0 sizes the iPhone's screen from it, and at the
        # 270 of 10-20 (then read by Android Auto only) the iPhone drew everything a size larger; with 0 it gets the
        # panel's 268x168 mm as under 9.4.0. 10.0.0's vehicle climate (on in its file) puts a temperature control at
        # each end of the iPhone's dock and the clock goes: off. Only "dashboard(s)", "wirelessAaEnabled",
        # "carPlayVehicleClimate" and the projection keys are read (the file has the Wi-Fi passphrase); an unreadable
        # file is not judged.
        try:
            lcfg = json.load(open("/home/user/.config/LIVI/config.json"))
            dash, old, aa = lcfg.get("dashboard"), lcfg.get("dashboards") or {}, lcfg.get("wirelessAaEnabled")
            clim = lcfg.get("carPlayVehicleClimate")
            proj = tuple(lcfg.get(k) for k in ("projectionWidth", "projectionHeight", "projectionDpi"))
        except (OSError, ValueError, AttributeError):
            lcfg, dash, old, aa, clim, proj = None, None, {}, None, None, None
        if isinstance(dash, dict):
            on = [s for s in ("main", "cluster", "aux") if dash.get(s) is True]
        else:
            on = [k for k in ("dash3", "dash4") if isinstance(old.get(k), dict) and any(old[k].get(s) for s in ("main", "dash", "aux"))]
        if on:
            bad.append(f"LIVI 的仪表盘开着（{'、'.join(on)}）：LIVI 会多报一块仪表盘屏，iPhone 两路一起编，主屏只给 30 帧"
                       "（退出 LIVI 后把 config.json 的 dashboard 三项都改成 false，见 linux/carplay/README.md「帧率」）")
        if lcfg is not None and aa is not True:
            bad.append("LIVI 的无线 Android Auto 关着：安卓手机连不上（LIVI 设置里打开，或退出 LIVI 后把 config.json 的"
                       " wirelessAaEnabled 改成 true）")
        if lcfg is not None and isinstance(dash, dict) and clim is not False:
            bad.append("LIVI 的车辆空调开着：iPhone 的 Dock 两头各多一个空调温度，时钟没地方放"
                       "（退出 LIVI 后把 config.json 的 carPlayVehicleClimate 改成 false）")
        if lcfg is not None and (proj[0], proj[1], proj[2] or 0) != (1600, 1000, 0):
            w, h, dpi = ("默认" if v is None else v for v in proj)
            bad.append(f"LIVI 的投屏是 {w}x{h}、{dpi} dpi，不是试好的 1600x1000、dpi 0：写了 dpi，iPhone 会当成小而密的屏，"
                       "界面整体大一号；尺寸不对，安卓手机的画面会退回 720p 发糊（退出 LIVI 后改 config.json 的 "
                       "projectionWidth/Height/Dpi，见 linux/carplay/README.md「换 LIVI 10.0.0」）")
        if run(["systemctl", "is-active", "y700-carplay-test-guard.timer"]) == "active":
            notes.append("实测自恢复定时器还挂着，到点会结束 CarPlay")
        if bad:
            say("WARN", "CarPlay：" + "；".join(bad))
        else:
            say("OK", "CarPlay 就绪：/dev/i2c-99 在"
                      + "，热点 settle 与停热点后的省电恢复、开机保护、色彩修正库与系统 libwayland、保持亮屏、全屏规则都在"
                      + ("，无线 Android Auto 开着" if aa is True else "") + (f"（{'；'.join(notes)}）" if notes else ""))
        if bad and notes:
            say("INFO", "CarPlay：" + "；".join(notes))
    guard("CarPlay", check_carplay)

    # screen-off wakeup reductions (linux/power/WAKEUPS.md): each checked only once its file is installed
    if os.path.exists("/home/user/.config/systemd/user/plasma-powerdevil.service.d/y700-no-ddcutil.conf"):
        pid, env = pid_env("org_kde_powerdevil")
        if pid and b"POWERDEVIL_NO_DDCUTIL=1" in env:
            say("OK", "PowerDevil 不用 ddcutil（display_recheck 10 Hz 线程已除）")
        else:
            say("WARN", f"PowerDevil 的 POWERDEVIL_NO_DDCUTIL 没生效（进程 {pid}；systemctl --user daemon-reload && "
                        "systemctl --user restart plasma-powerdevil.service）")
    if os.path.exists("/etc/systemd/system/tailscaled.service.d/y700-wakeups.conf"):
        pid, env = pid_env("tailscaled")
        if pid and b"TS_PORTLIST=false" in env:
            say("OK", "tailscaled 不扫端口（TS_PORTLIST=false）")
        else:
            say("WARN", f"tailscaled 的 TS_PORTLIST=false 没生效（进程 {pid}；systemctl daemon-reload && systemctl restart tailscaled，从局域网地址做）")
    if os.path.exists("/etc/systemd/system/tb323fu-helperd.service.d/y700-local.conf"):
        pid, _ = pid_env("tb323fu-helperd")
        exe = os.path.realpath(f"/proc/{pid}/exe") if pid else ""
        if exe.startswith("/usr/local/libexec/"):
            say("OK", f"tb323fu-helperd 跑的是自编的熄屏慢轮询版（{exe}）")
        else:
            say("WARN", f"tb323fu-helperd 跑的是 {exe or '没在跑'}，不是 /usr/local/libexec 的自编版（helperd-slow-poll.patch 重编后 systemctl restart）")
    if os.path.exists("/etc/systemd/user/y700-screen-off-freeze.service"):
        en = run(["systemctl", "--user", "is-enabled", "y700-screen-off-freeze.service"], user=True)
        if en == "enabled":
            state = run(["systemctl", "--user", "is-active", "y700-screen-off-freeze.service"], user=True)
            (say("OK", "熄屏冻结服务在跑（Claude/Chrome 熄屏 60 s 后冻结）") if state == "active"
             else say("WARN", f"熄屏冻结服务是 {state}（journalctl --user -u y700-screen-off-freeze；停了会自动解冻）"))

    layout = run(["gsettings", "get", "org.gnome.desktop.wm.preferences", "button-layout"], user=True)
    if "minimize" in layout:
        say("OK", "Chrome/Claude/Telegram 标题栏按钮布局正常")
    else:
        say("WARN", f"窗口按钮布局变回了 {layout}：右上角会只剩 X（gsettings set ... 'icon:minimize,maximize,close'）")

    print("\n".join(out))
    if save:
        # a new file renamed over the old one: truncating STATE and writing into it left an empty or half file after a
        # reset or a full disk mid-write, read next time as a first run - a day's CHANGED lost, unnoticed (10-31 audit C6)
        os.makedirs(os.path.dirname(STATE), exist_ok=True)
        with open(STATE + ".tmp", "w") as f:
            json.dump(cur, f, ensure_ascii=False, indent=1)
            f.flush()
            os.fsync(f.fileno())
        os.replace(STATE + ".tmp", STATE)
    return 10 if attention else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:
        print(f"ERROR {e!r}")
        sys.exit(1)

"""Split the y700 base diff (y700-y5.patch minus 0540/0620-0622) into named patches for the y14 series.
Inputs are the archived cumulative diffs in linux/kernel-y1..y5; outputs go to <scratch>/in/.
"""
import os
import re
import sys

ROOT = "C:/Users/me/AI/y700/linux"
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "in")
os.makedirs(OUT, exist_ok=True)


def read(p):
    with open(p, encoding="utf-8", newline="") as f:
        return f.read()


def sections(text):
    """file path -> list of lines of that 'diff --git' section (incl. header)"""
    out = {}
    cur = None
    for line in text.splitlines(keepends=True):
        m = re.match(r"diff --git a/(\S+) b/", line)
        if m:
            cur = m.group(1)
            out[cur] = []
        if cur:
            out[cur].append(line)
    return out


def hunks(sec):
    head, hs = [], []
    for line in sec:
        if line.startswith("@@"):
            hs.append([line])
        elif hs:
            hs[-1].append(line)
        else:
            head.append(line)
    return head, hs


def header(subject, body, author="bobsixsixsix-boop <304558835+bobsixsixsix-boop@users.noreply.github.com>", date="Mon, 12 Oct 2026 15:00:00 +0000"):
    return (f"From 0000000000000000000000000000000000000000 Mon Sep 17 00:00:00 2001\n"
            f"From: {author}\nDate: {date}\nSubject: [PATCH] {subject}\n\n{body.strip()}\n---\n\n")


y5 = sections(read(f"{ROOT}/kernel-y5/y700-y5.patch"))
y2 = sections(read(f"{ROOT}/kernel-y2/y700-y2.patch"))
y3 = sections(read(f"{ROOT}/kernel-y3/y700-y3.patch"))
va = read(f"{ROOT}/kernel-y2/upstream-patches/iris-decode-order-deblock-t47.patch")

# sanity: the iris part of y5 is exactly va-iris (index lines aside)
iris_y5 = "".join(l for k, v in y5.items() if "/iris/" in k for l in v if not l.startswith("index "))
iris_va = "".join(l for l in va.splitlines(keepends=True) if not l.startswith("index "))
if iris_y5 != iris_va:
    sys.exit("y5 iris part != va-iris.patch")

files = {}
files["00y1-media-iris-decode-order-display-delay-and-deblock-controls.patch"] = header(
    "media: iris: decoder display delay (decode order) and deblocking controls",
    """Expose V4L2_CID_MPEG_VIDEO_DEC_DISPLAY_DELAY[_ENABLE] (decode-order
output, what the libva-v4l2 VA-API backend needs) and the H.264/HEVC
loop filter controls on the gen2 HFI decoder, and size the capture pool
for it. Origin: code002-2/sm8750-video-accel 0001-decode-order-deblock
(identical to the three radxa libva-v4l2 kernel patches), rebased by the
y700 workspace onto the tb323fu t47 iris (two contexts, plus the missing
iris_set_deblock_gen2 declaration). Was /root/va-iris.patch =
linux/kernel-y2/upstream-patches/iris-decode-order-deblock-t47.patch.""",
    author="y700 workspace (from code002-2/sm8750-video-accel) <304558835+bobsixsixsix-boop@users.noreply.github.com>",
    date="Mon, 12 Oct 2026 16:02:00 +0000") + va

files["00y2-power-supply-qcom_battmgr-status-power_now-and-charge-units-on-kaanapali.patch"] = header(
    "power: supply: qcom_battmgr: y700 status, power_now from I*V, mAh unit on SM8350/SM8550",
    """Three fixes for the TB323FU (kaanapali, SM8550-style battmgr firmware):
- STATUS: the firmware says "Charging" while external power is in but the
  battery is held (limit/bypass) or drained; derive Discharging /
  Not charging from the sign of current_now (y1);
- POWER_NOW: BATT_POWER_NOW is unusable (0, or a bogus constant after a
  full-battery boot); always compute current_now * voltage_now (y1; y3
  made it unconditional);
- unit: the SM8350/SM8550 firmware answers BATT_CHG_FULL[_DESIGN] in uAh,
  set QCOM_BATTMGR_UNIT_mAh so charge_full[_design] stop reading ENODATA
  (UPower showed 0 Wh) (y1).
y14: rebased onto upstream 0132 (charge current limit), which is now in
the base series (in y10..y13 0132 was rebased onto this patch instead).""",
    date="Sun, 11 Oct 2026 06:37:00 +0000") + "".join(y5["drivers/power/supply/qcom_battmgr.c"])

files["00y3-wifi-ath12k-wcn7860-no-mlo-unless-asked.patch"] = header(
    "wifi: ath12k: don't advertise MLO on WCN7860 unless wcn7860_mlo=1",
    """With the Android GNG firmware the WCN7860 completes the ML association
with an MLO AP but EAPOL 2/4 over the MLO link is never acked
(4WAY_HANDSHAKE_TIMEOUT), so 5/6 GHz MLO SSIDs never connect. Without
MLO the station associates single-link and the handshake goes through.
Knob: ath12k.wcn7860_mlo (0444, default off). (y1)""",
    date="Sun, 11 Oct 2026 06:37:00 +0000") + "".join(y5["drivers/net/wireless/ath/ath12k/core.c"])

files["00y4-wifi-ath12k-wcn7860-5g-160-knob.patch"] = header(
    "wifi: ath12k: wcn7860_5g_160 knob to limit 5 GHz to 80 MHz",
    """WCN7860 with the Android GNG firmware lost beacons and stopped
transmitting some seconds after joining a 5 GHz BSS at 160 MHz.
ath12k.wcn7860_5g_160=0 drops the 160 MHz capability on 5 GHz only (VHT
and HE); default on (unchanged behaviour). (y2)""",
    date="Mon, 12 Oct 2026 16:05:00 +0000") + "".join(y2["drivers/net/wireless/ath/ath12k/mac.c"])

head, hs = hunks(y3["drivers/net/wireless/ath/ath12k/mac.c"])
bm = [h for h in hs if h[0].startswith("@@ -1982,")]
assert len(bm) == 1
files["00y5-wifi-ath12k-no-backup-beacon-miss-timer-for-stations.patch"] = header(
    "wifi: ath12k: don't arm the backup connection-loss timer on beacon miss",
    """On 5 GHz the WCN7860 firmware stops forwarding beacons over WMI a few
seconds after association, so the backup connection_loss_work (which only
a WMI beacon cancels) tore the link down (reason 4) every ~20 s while
data still flowed. mac80211 already probes the AP after
ieee80211_beacon_loss() and disconnects on a real loss. (y3)""",
    date="Tue, 13 Oct 2026 05:52:00 +0000") + "".join(head) + "".join(bm[0])

for name, text in files.items():
    with open(os.path.join(OUT, name), "w", encoding="utf-8", newline="\n") as f:
        f.write(text)
    print(name, len(text))

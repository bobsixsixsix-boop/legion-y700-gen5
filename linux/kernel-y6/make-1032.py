#!/usr/bin/env python3
# Write y700 patch 1032 into the y6 tree (/usr/local/src/linux-t47) and save it as a git-format patch.
import pathlib, subprocess, sys
T = pathlib.Path("/usr/local/src/linux-t47")
D = "drivers/media/platform/qcom/iris/"
files = [D + "iris_hfi_gen2.h", D + "iris_hfi_gen2_response.c", D + "iris_hfi_gen2_command.c"]
orig = {f: (T / f).read_text() for f in files}
new = dict(orig)

h = new[files[0]]
old = " * @dst_subcr_params: subscription params to fw on output port\n */"
assert h.count(old) == 1, "header doc"
h = h.replace(old, " * @dst_subcr_params: subscription params to fw on output port\n"
                   " * @fw_color_info: colour info the firmware last reported for the bitstream\n"
                   " * @fw_color_info_valid: @fw_color_info holds a firmware report\n */")
old = "\tstruct hfi_subscription_params\tdst_subcr_params;\n};"
assert h.count(old) == 1, "header struct"
h = h.replace(old, "\tstruct hfi_subscription_params\tdst_subcr_params;\n\tu32\t\t\t\tfw_color_info;\n"
                   "\tbool\t\t\t\tfw_color_info_valid;\n};")
new[files[0]] = h

r = new[files[1]]
old = "\tsubsc_params = inst_hfi_gen2->src_subcr_params;\n\twidth = "
assert r.count(old) == 1, "response"
r = r.replace(old, "\tsubsc_params = inst_hfi_gen2->src_subcr_params;\n"
                   "\tinst_hfi_gen2->fw_color_info = subsc_params.color_info;\n"
                   "\tinst_hfi_gen2->fw_color_info_valid = true;\n\twidth = ")
new[files[1]] = r

c = new[files[2]]
old = ("\t\t\t\t\t\t  video_format, video_signal_type_present_flag);\n\n"
       "\tinst_hfi_gen2->src_subcr_params.color_info = color_info;\n")
assert c.count(old) == 1, "command"
c = c.replace(old, ("\t\t\t\t\t\t  video_format, video_signal_type_present_flag);\n"
                    "\t/*\n"
                    "\t * Once the firmware has reported the stream's colour info, a decoder sends that\n"
                    "\t * value back unchanged. Rebuilding it from the V4L2 colorimetry does not round-trip\n"
                    "\t * (an \"unspecified\" primaries/transfer becomes reserved, video_format is lost), and\n"
                    "\t * any difference raises the same source change again every time the bitstream\n"
                    "\t * port is restarted.\n"
                    "\t */\n"
                    "\tif (inst->domain == DECODER && inst_hfi_gen2->fw_color_info_valid)\n"
                    "\t\tcolor_info = inst_hfi_gen2->fw_color_info;\n\n"
                    "\tinst_hfi_gen2->src_subcr_params.color_info = color_info;\n"))
new[files[2]] = c

hdr = """From 0000000000000000000000000000000000000000 Mon Sep 17 00:00:00 2001
From: bobsixsixsix-boop <304558835+bobsixsixsix-boop@users.noreply.github.com>
Date: Wed, 14 Oct 2026 04:30:00 +0000
Subject: [PATCH] media: iris: send the decoder the colour info the firmware reported

The firmware raises a source change when a bitstream property differs from what
the driver set. HFI_PROP_SIGNAL_COLOR_INFO is rebuilt from the V4L2 colorimetry on
every bitstream port start, which does not round-trip: a stream without a colour
description reports 0x00021202 and gets 0x14000003 back, a BT.709 stream whose
primaries/transfer are "unspecified" reports 0x35020201 and gets 0x35000001.
So restarting the bitstream port after the first source change raised it again
for every stream, with or without ArmadaOS 1030/1031 (kprobe on
iris_hfi_gen2_packet_session_property vs iris_hfi_gen2_handle_session_property,
SM8850). Keep the value the firmware reported and send it back unchanged.
---
"""
out = []
for f in files:
    a = pathlib.Path("/tmp/1032-a"); b = pathlib.Path("/tmp/1032-b")
    for base, txt in ((a, orig[f]), (b, new[f])):
        p = base / f; p.parent.mkdir(parents=True, exist_ok=True); p.write_text(txt)
    d = subprocess.run(["diff", "-u", "--label", "a/" + f, "--label", "b/" + f, str(a / f), str(b / f)],
                       capture_output=True, text=True).stdout
    out.append("diff --git a/%s b/%s\n%s" % (f, f, d))
patch = hdr + "".join(out) + "-- \n2.43.0\n"
pathlib.Path(sys.argv[1]).write_text(patch)
for f in files:
    (T / f).write_text(new[f])
print("written", sys.argv[1])

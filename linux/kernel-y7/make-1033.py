#!/usr/bin/env python3
# Write y700 patch 1033 into the tree (/usr/local/src/linux-t47, y6 state) and save it as a patch.
import pathlib, subprocess, sys
T = pathlib.Path("/usr/local/src/linux-t47")
D = "drivers/media/platform/qcom/iris/"
files = [D + "iris_hfi_gen2.h", D + "iris_hfi_gen2_response.c", D + "iris_hfi_gen2_command.c"]
orig = {f: (T / f).read_text() for f in files}
new = dict(orig)

def sub(f, old, rep):
    assert new[f].count(old) == 1, (f, old[:50])
    new[f] = new[f].replace(old, rep)

sub(files[0], " * @fw_color_info_valid: @fw_color_info holds a firmware report\n */",
    " * @fw_color_info_valid: @fw_color_info holds a firmware report\n"
    " * @fw_bitstream_resolution: bitstream resolution the firmware last reported\n"
    " * @fw_bitstream_resolution_valid: @fw_bitstream_resolution holds a firmware report\n */")
sub(files[0], "\tbool\t\t\t\tfw_color_info_valid;\n};",
    "\tbool\t\t\t\tfw_color_info_valid;\n\tu32\t\t\t\tfw_bitstream_resolution;\n"
    "\tbool\t\t\t\tfw_bitstream_resolution_valid;\n};")
sub(files[1], "\tinst_hfi_gen2->fw_color_info_valid = true;\n",
    "\tinst_hfi_gen2->fw_color_info_valid = true;\n"
    "\tinst_hfi_gen2->fw_bitstream_resolution = subsc_params.bitstream_resolution;\n"
    "\tinst_hfi_gen2->fw_bitstream_resolution_valid = true;\n")
sub(files[2], "\t\tresolution = iris_hfi_get_aligned_resolution(inst, width, height);\n"
              "\t\tinst_hfi_gen2->src_subcr_params.bitstream_resolution = resolution;\n",
    "\t\tresolution = iris_hfi_get_aligned_resolution(inst, width, height);\n"
    "\t\t/*\n"
    "\t\t * As with the colour info: once the firmware has reported the stream's\n"
    "\t\t * resolution, send that back. HEVC aligns to 32 here (1280x720 goes out as\n"
    "\t\t * 1280x736, 1920x1080 as 1920x1088), which differs from what the firmware\n"
    "\t\t * parsed and raises the source change again on every bitstream port restart.\n"
    "\t\t */\n"
    "\t\tif (inst_hfi_gen2->fw_bitstream_resolution_valid)\n"
    "\t\t\tresolution = inst_hfi_gen2->fw_bitstream_resolution;\n"
    "\t\tinst_hfi_gen2->src_subcr_params.bitstream_resolution = resolution;\n")

hdr = """From 0000000000000000000000000000000000000000 Mon Sep 17 00:00:00 2001
From: bobsixsixsix-boop <304558835+bobsixsixsix-boop@users.noreply.github.com>
Date: Wed, 14 Oct 2026 04:45:00 +0000
Subject: [PATCH] media: iris: send the decoder the bitstream resolution the firmware reported

Same failure as the colour info (1032), for HEVC: the bitstream resolution is
rebuilt from the OUTPUT format and aligned to 32, so a 1280x720 stream goes out
as 1280x736 (0x050002e0) while the firmware reported 0x050002d0, and 1080p as
1088. Restarting the bitstream port after the first source change then raised
it again for every HEVC stream (kprobes on y6, SM8850; H.264 aligns to 16 and
was not affected). Keep the value the firmware reported and send it back.
---
"""
out = []
for f in files:
    a = pathlib.Path("/tmp/1033-a"); b = pathlib.Path("/tmp/1033-b")
    for base, txt in ((a, orig[f]), (b, new[f])):
        p = base / f; p.parent.mkdir(parents=True, exist_ok=True); p.write_text(txt)
    d = subprocess.run(["diff", "-u", "--label", "a/" + f, "--label", "b/" + f, str(a / f), str(b / f)],
                       capture_output=True, text=True).stdout
    out.append("diff --git a/%s b/%s\n%s" % (f, f, d))
pathlib.Path(sys.argv[1]).write_text(hdr + "".join(out) + "-- \n2.43.0\n")
for f in files:
    (T / f).write_text(new[f])
print("written", sys.argv[1])

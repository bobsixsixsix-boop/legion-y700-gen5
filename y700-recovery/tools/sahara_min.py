#!/usr/bin/env python3
"""Minimal, fully traced Sahara v3 multi-image loader uploader (pyusb).

Serves the device's READ_DATA requests from qsahara_device_programmer.xml with
exact lengths, answers HELLO with HELLO_RESP (image transfer pending), answers
END_IMAGE_TX success with DONE, and stops when the Firehose programmer starts
talking XML.  Every packet is logged.  No Firehose command is sent here.
"""
import os, struct, sys, time
import xml.etree.ElementTree as ET
import usb.core, usb.util

XML = sys.argv[1]
LOG = sys.argv[2] if len(sys.argv) > 2 else None
logf = open(LOG, "a") if LOG else None

def log(*a):
    s = time.strftime("%H:%M:%S ") + " ".join(str(x) for x in a)
    print(s, flush=True)
    if logf:
        logf.write(s + "\n"); logf.flush()

base = os.path.dirname(os.path.abspath(XML))
images = {}
for im in ET.parse(XML).getroot().iter("image"):
    p = os.path.join(base, im.get("image_path"))
    images[int(im.get("image_id"))] = (p, open(p, "rb").read())
log("images:", {k: (os.path.basename(v[0]), len(v[1])) for k, v in images.items()})

dev = usb.core.find(idVendor=0x05C6, idProduct=0x9008)
if dev is None:
    log("no 9008 device"); sys.exit(2)
cfg = dev.get_active_configuration()
intf = cfg[(0, 0)]
if dev.is_kernel_driver_active(intf.bInterfaceNumber):
    dev.detach_kernel_driver(intf.bInterfaceNumber)
usb.util.claim_interface(dev, intf.bInterfaceNumber)
ep_in = usb.util.find_descriptor(intf, custom_match=lambda e: usb.util.endpoint_direction(e.bEndpointAddress) == usb.util.ENDPOINT_IN)
ep_out = usb.util.find_descriptor(intf, custom_match=lambda e: usb.util.endpoint_direction(e.bEndpointAddress) == usb.util.ENDPOINT_OUT)
log("ep_in 0x%02x mps %d, ep_out 0x%02x mps %d" % (ep_in.bEndpointAddress, ep_in.wMaxPacketSize, ep_out.bEndpointAddress, ep_out.wMaxPacketSize))

def rd(timeout_ms=3000, n=4096):
    try:
        d = bytes(ep_in.read(n, timeout_ms))
        log("RX", len(d), d[:64].hex())
        return d
    except usb.core.USBTimeoutError:
        log("RX timeout")
        return b""

PIECE = int(os.environ.get("PIECE", "2048"))
SLEEP = float(os.environ.get("SLEEP", "0"))
def wr(d, what):
    total = 0
    for i in range(0, len(d), PIECE):
        part = d[i:i + PIECE]
        n = ep_out.write(part, 10000)
        if SLEEP: time.sleep(SLEEP)
        total += n
        if n != len(part):
            log("TX", what, "len", len(d), "sent", total, "SHORT WRITE"); sys.exit(3)
    log("TX", what, "len", len(d), "sent", total)

def hello_resp(version):
    # cmd 2, len 0x30, version, version_supported, status, mode(0 = image tx pending), reserved[6]
    wr(struct.pack("<12I", 2, 0x30, version, 1, 0, 0, 0, 0, 0, 0, 0, 0), "HELLO_RESP")

cur_img = None
idle = 0
if os.environ.get('RESUME'):
    img, off, length = (int(x) for x in os.environ['RESUME'].split(','))
    chunk = images[img][1][off:off+length]
    log('RESUME: sending pending chunk unsolicited')
    wr(chunk, 'DATA(resume) img=%d off=%d len=%d' % (img, off, length))
while True:
    d = rd()
    if not d:
        idle += 1
        if idle >= 4:
            log("device silent for 12 s; giving up (state left as is)"); sys.exit(4)
        continue
    idle = 0
    if d.startswith(b"<?xml"):
        log("FIREHOSE XML seen:", d[:200]); break
    cmd, ln = struct.unpack_from("<II", d, 0)
    if cmd == 1:
        ver, vmin, maxlen, mode = struct.unpack_from("<IIII", d, 8)
        log("HELLO ver", ver, "min", vmin, "maxlen", maxlen, "mode", mode)
        hello_resp(ver)
    elif cmd in (3, 0x12):
        if cmd == 3:
            img, off, length = struct.unpack_from("<III", d, 8)
        else:
            img, off, length = struct.unpack_from("<QQQ", d, 8)
        name, data = images[img] if img in images else (None, None)
        if data is None:
            log("UNKNOWN image id", img); sys.exit(5)
        chunk = data[off:off + length]
        if len(chunk) < length:
            chunk += b"\xff" * (length - len(chunk))
        if cur_img != img:
            log("== image", img, os.path.basename(name), "bytes", len(data)); cur_img = img
        wr(chunk, "DATA img=%d off=%d len=%d" % (img, off, length))
    elif cmd == 4:
        img, status = struct.unpack_from("<II", d, 8)
        log("END_IMAGE_TX img", img, "status", status)
        if status != 0:
            log("device rejected image; stopping"); sys.exit(6)
        wr(struct.pack("<II", 5, 8), "DONE")
    elif cmd == 6:
        status, = struct.unpack_from("<I", d, 8)
        log("DONE_RESP status", status, "(0 = more images pending, 1 = complete)")
    elif cmd == 0xB:
        log("CMD_READY (command mode) - unexpected here"); break
    else:
        log("unhandled cmd", hex(cmd))
log("sahara phase finished")

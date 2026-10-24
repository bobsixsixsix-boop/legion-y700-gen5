import usb.core, usb.util, sys
dev=usb.core.find(idVendor=0x18d1, idProduct=0xd00d)
if dev is None: print("no fastboot device"); sys.exit(1)
cfg=dev.get_active_configuration(); intf=cfg[(0,0)]
if dev.is_kernel_driver_active(intf.bInterfaceNumber): dev.detach_kernel_driver(intf.bInterfaceNumber)
usb.util.claim_interface(dev, intf.bInterfaceNumber)
ei=usb.util.find_descriptor(intf, custom_match=lambda e: usb.util.endpoint_direction(e.bEndpointAddress)==usb.util.ENDPOINT_IN)
eo=usb.util.find_descriptor(intf, custom_match=lambda e: usb.util.endpoint_direction(e.bEndpointAddress)==usb.util.ENDPOINT_OUT)
def cmd(c):
    eo.write(c.encode(), 3000); out=[]
    while True:
        try: r=bytes(ei.read(max(ei.wMaxPacketSize,512), 5000)).decode(errors="replace")
        except usb.core.USBTimeoutError: out.append("<timeout>"); break
        out.append(r)
        if r.startswith(("OKAY","FAIL")): break
    return out
for v in sys.argv[1:]:
    print("==",v)
    for l in cmd("getvar:"+v): print("  ",l.strip())

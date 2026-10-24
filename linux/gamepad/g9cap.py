#!/usr/bin/python3
# passive capture of the G9's evdev keys and raw HID reports (no grab)
import os, sys, struct, select, time, glob

dur = float(sys.argv[1]) if len(sys.argv) > 1 else 180
devs = {}
for d in glob.glob('/sys/class/input/event*'):
    name = open(d + '/device/name').read().strip()
    if 'GameSir' in name:
        devs[os.open('/dev/input/' + os.path.basename(d), os.O_RDONLY | os.O_NONBLOCK)] = ('ev', name)
for h in glob.glob('/sys/class/hidraw/hidraw*'):
    if '3537:1136' in os.path.realpath(h):
        devs[os.open('/dev/' + os.path.basename(h), os.O_RDONLY | os.O_NONBLOCK)] = ('raw', os.path.basename(h))
for fd, v in devs.items():
    print('open', v, flush=True)
last = {}
end = time.time() + dur
t0 = time.time()
while time.time() < end:
    r, _, _ = select.select(list(devs), [], [], 1)
    for fd in r:
        kind, name = devs[fd]
        try:
            data = os.read(fd, 4096)
        except BlockingIOError:
            continue
        ts = '%7.2f' % (time.time() - t0)
        if kind == 'ev':
            for i in range(0, len(data), 24):
                sec, usec, typ, code, val = struct.unpack('qqHHi', data[i:i + 24])
                if typ == 1:
                    print(ts, name[-16:], 'KEY 0x%x %d' % (code, val), flush=True)
                elif typ == 3 and abs(val) > 0 and code in (2, 5, 16, 17):
                    pass  # triggers/hat: too chatty, raw shows them
        else:
            prev = last.get(fd)
            if data != prev:
                # print only bytes that changed, to spot buttons
                if prev and len(prev) == len(data):
                    diff = ' '.join('%d:%02x>%02x' % (i, prev[i], data[i]) for i in range(len(data)) if prev[i] != data[i])
                else:
                    diff = data.hex()
                print(ts, name, 'RAW', diff, flush=True)
                last[fd] = data

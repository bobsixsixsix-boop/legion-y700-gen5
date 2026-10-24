#!/usr/bin/env python3
"""Create a uinput keyboard with letters/digits/backspace for N seconds (no key events sent). Test only."""
import fcntl, os, struct, sys, time
UI_SET_EVBIT, UI_SET_KEYBIT = 0x40045564, 0x40045565
UI_DEV_SETUP, UI_DEV_CREATE, UI_DEV_DESTROY = 0x405c5503, 0x5501, 0x5502
EV_KEY = 1
fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
fcntl.ioctl(fd, UI_SET_EVBIT, EV_KEY)
for k in list(range(1, 59)):          # KEY_ESC..KEY_CAPSLOCK: digits, letters, backspace, enter, space
    fcntl.ioctl(fd, UI_SET_KEYBIT, k)
setup = struct.pack("HHHH80sI", 0x06, 0x1234, 0x5678, 1, b"y700-test-kbd", 0)
fcntl.ioctl(fd, UI_DEV_SETUP, setup)
fcntl.ioctl(fd, UI_DEV_CREATE)
time.sleep(float(sys.argv[1]) if len(sys.argv) > 1 else 8)
fcntl.ioctl(fd, UI_DEV_DESTROY)

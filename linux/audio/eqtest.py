#!/usr/bin/env python3
# play test tones into the y700 Lenovo sink, record the protected sink's monitor (input of the protection chain)
import math, os, struct, subprocess, time, wave
FS = 48000
def tone(f, amp, sec, path):
    n = int(FS * sec)
    with wave.open(path, "wb") as w:
        w.setnchannels(2); w.setsampwidth(2); w.setframerate(FS)
        w.writeframes(b"".join(struct.pack("<hh", v, v) for v in
                      (int(32767 * amp * math.sin(2 * math.pi * f * i / FS)) for i in range(n))))
def goertzel(x, f):
    k = 2 * math.cos(2 * math.pi * f / FS); s1 = s2 = 0.0
    for v in x:
        s1, s2 = v + k * s1 - s2, s1
    p = s1 * s1 + s2 * s2 - k * s1 * s2
    return 20 * math.log10(max(math.sqrt(max(p, 0)) * 2 / len(x), 1e-9))
def run(sink, f, amp=0.1):
    tone(f, amp, 2.0, "/tmp/t.wav")
    rec = subprocess.Popen(["pw-record", "--target", "effect_input.speakers", "-P", "stream.capture.sink=true",
                            "--rate", "48000", "--channels", "2", "--format", "s16", "/tmp/r.wav"])
    time.sleep(0.5)
    subprocess.run(["pw-play", "--target", sink, "/tmp/t.wav"])
    time.sleep(0.3); rec.terminate(); rec.wait()
    with wave.open("/tmp/r.wav") as w:
        raw = w.readframes(w.getnframes())
    xs = [struct.unpack_from("<h", raw, i)[0] / 32768 for i in range(0, len(raw), 4)]
    xs = xs[int(1.0 * FS):int(1.0 * FS) + 24000]
    ref = 20 * math.log10(amp)
    return ref, goertzel(xs, f), goertzel(xs, 2 * f), goertzel(xs, 3 * f)
for f in (60, 100, 470, 1313, 1688, 4688, 10000):
    r0, a0, _, _ = run("effect_input.speakers", f)
    r1, a1, h2, h3 = run("effect_input.y700_lenovo", f)
    print(f"{f:6d} Hz  direct {a0 - r0:+6.1f} dB   lenovo {a1 - r0:+6.1f} dB  (2f {h2 - r0:+6.1f}, 3f {h3 - r0:+6.1f})")

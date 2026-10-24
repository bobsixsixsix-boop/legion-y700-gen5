#!/usr/bin/env python3
"""Minimal dex scanner: list sget-object UserHandle.<X> sites and the call that follows them."""
import struct, sys, zipfile

def uleb(b, o):
    r = s = 0
    while True:
        x = b[o]; o += 1; r |= (x & 0x7f) << s; s += 7
        if x < 0x80: return r, o

class Dex:
    def __init__(self, b):
        self.b = b
        h = struct.unpack_from("<8sI20sIIIIIIIIIIIIIIIIIIII", b, 0)
        (self.str_n, self.str_off, self.type_n, self.type_off, self.proto_n, self.proto_off,
         self.field_n, self.field_off, self.meth_n, self.meth_off, self.cls_n, self.cls_off) = h[9:21]
    def s(self, i):
        o = struct.unpack_from("<I", self.b, self.str_off + 4 * i)[0]
        n, o = uleb(self.b, o)
        e = self.b.index(b"\0", o)
        return self.b[o:e].decode("utf-8", "replace")
    def t(self, i):
        return self.s(struct.unpack_from("<I", self.b, self.type_off + 4 * i)[0])
    def field(self, i):
        c, ty, nm = struct.unpack_from("<HHI", self.b, self.field_off + 8 * i)
        return self.t(c), self.s(nm), self.t(ty)
    def meth(self, i):
        c, p, nm = struct.unpack_from("<HHI", self.b, self.meth_off + 8 * i)
        return self.t(c), self.s(nm)
    def classes(self):
        for i in range(self.cls_n):
            ci, af, sc, iface, src, ann, cdata, sv = struct.unpack_from("<8I", self.b, self.cls_off + 32 * i)
            yield self.t(ci), cdata
    def methods(self, cdata):
        if not cdata: return
        o = cdata
        sf, o = uleb(self.b, o); inf, o = uleb(self.b, o); dm, o = uleb(self.b, o); vm, o = uleb(self.b, o)
        for _ in range(sf + inf):
            _, o = uleb(self.b, o); _, o = uleb(self.b, o)
        for n in (dm, vm):
            idx = 0
            for _ in range(n):
                d, o = uleb(self.b, o); idx += d
                _, o = uleb(self.b, o); code, o = uleb(self.b, o)
                yield idx, code

# instruction sizes (code units) per opcode, enough for a linear sweep
FMT = {}
def sz(op):
    if op in (0x00,): return 1
    t = {1:1,2:2,3:3,4:1,5:2,6:3,7:1,8:2,9:3,0xa:1,0xb:1,0xc:1,0xd:1,0xe:1,0xf:1,0x10:1,0x11:1,0x12:1,0x13:2,0x14:3,0x15:2,0x16:2,0x17:3,0x18:5,0x19:2,
         0x1a:2,0x1b:3,0x1c:2,0x1d:1,0x1e:1,0x1f:2,0x20:2,0x21:1,0x22:2,0x23:2,0x24:3,0x25:3,0x26:3,0x27:1,0x28:1,0x29:2,0x2a:3,0x2b:3,0x2c:3}
    if op in t: return t[op]
    if 0x2d <= op <= 0x31: return 2
    if 0x32 <= op <= 0x37: return 2
    if 0x38 <= op <= 0x3d: return 2
    if 0x3e <= op <= 0x43: return 1
    if 0x44 <= op <= 0x6d: return 2
    if 0x6e <= op <= 0x72: return 3
    if op == 0x73: return 1
    if 0x74 <= op <= 0x78: return 3
    if 0x79 <= op <= 0x7a: return 1
    if 0x7b <= op <= 0x8f: return 1
    if 0x90 <= op <= 0xaf: return 2
    if 0xb0 <= op <= 0xcf: return 1
    if 0xd0 <= op <= 0xe2: return 2
    if 0xe3 <= op <= 0xf9: return 1
    if op in (0xfa, 0xfb): return 4
    if op in (0xfc, 0xfd): return 3
    if op in (0xfe, 0xff): return 2
    return 1

def sweep(d, code):
    regs, ins, outs, tries, dbg, n = struct.unpack_from("<HHHHII", d.b, code)
    base = code + 16; pc = 0
    while pc < n:
        u = struct.unpack_from("<H", d.b, base + 2 * pc)[0]; op = u & 0xff
        if op == 0 and u in (0x100, 0x200, 0x300):  # payloads
            if u == 0x100: size = struct.unpack_from("<H", d.b, base + 2 * pc + 2)[0]; pc += size * 2 + 4
            elif u == 0x200: size = struct.unpack_from("<H", d.b, base + 2 * pc + 2)[0]; pc += size * 4 + 2
            else:
                w, size = struct.unpack_from("<HI", d.b, base + 2 * pc + 2); pc += (size * w + 1) // 2 + 4
            continue
        yield pc, base + 2 * pc, op
        pc += sz(op)

if __name__ == "__main__":
    b = zipfile.ZipFile(sys.argv[1]).read("classes.dex")
    d = Dex(b)
    uh = {i: d.field(i) for i in range(d.field_n) if d.field(i)[0] == "Landroid/os/UserHandle;"}
    print("UserHandle fields in dex:", {i: f[1] for i, f in uh.items()})
    for cname, cdata in d.classes():
        if not cname.startswith("Lcom/dolby/"): continue
        for mi, code in d.methods(cdata):
            if not code: continue
            seq = list(sweep(d, code))
            for k, (pc, off, op) in enumerate(seq):
                if op == 0x62:
                    fi = struct.unpack_from("<H", b, off + 2)[0]
                    if fi in uh:
                        nxt = ""
                        for pc2, off2, op2 in seq[k + 1:k + 12]:
                            if 0x6e <= op2 <= 0x72 or 0x74 <= op2 <= 0x78:
                                nxt = "%s.%s" % d.meth(struct.unpack_from("<H", b, off2 + 2)[0]); break
                        print(f"{cname}->{d.meth(mi)[1]} pc={pc} dexoff=0x{off:x} UserHandle.{uh[fi][1]} -> {nxt}")

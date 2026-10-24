import gdb
# 2026-10-18: find the QObjects referenced by the running QQuickAnimatorProxyJob and its QQuickOpacityAnimatorJob and
# print their class-name parent chains. Only calls metaObject() where vtable[0] is a symbol "...::metaObject() const"
# (calling vtable[0] of a non-QObject would run e.g. its destructor)
inf = gdb.selected_inferior()
def rd(a):
    try:
        return int.from_bytes(inf.read_memory(a, 8).tobytes(), 'little')
    except Exception:
        return None
def sym(a):
    try:
        s = gdb.execute("info symbol 0x%x" % a, to_string=True).strip()
    except Exception:
        return ""
    return "" if s.startswith("No symbol") else s
def is_qobject(o):
    vt = rd(o)
    if not vt:
        return False
    f0 = rd(vt)
    return bool(f0) and "metaObject() const" in sym(f0)
def cname(o):
    try:
        return gdb.parse_and_eval("(char *)((const char *(*)(void *)) 'QMetaObject::className() const')(((void *(*)(void *)) (**(void ***)0x%x))((void *)0x%x))" % (o, o)).string()
    except Exception as e:
        return "?(%s)" % str(e)[:50]
def chain(o, n=22):
    out = []
    for i in range(n):
        if not o or not is_qobject(o):
            if o:
                out.append("(non-QObject %x)" % o)
            break
        out.append(cname(o))
        d = rd(o + 8)
        o = rd(d + 16) if d else None
    return " <- ".join(out)
def scan(base, label, size=320):
    print("== %s 0x%x %s" % (label, base, sym(rd(base) or 0).split(" in section")[0]))
    seen = set()
    for off in range(8, size, 8):
        p = rd(base + off)
        if not p or p in seen or p < 0x10000:
            continue
        seen.add(p)
        if is_qobject(p):
            print("  +%d QObject 0x%x: %s" % (off, p, chain(p)))
        else:
            # QPointer<T> = {ExternalRefCountData *d; T *value}: value right after d
            pass
proxy = int(gdb.parse_and_eval("$x0"))
scan(proxy, "proxy job")
op = rd(proxy + 136)
if op:
    scan(op, "animator job")

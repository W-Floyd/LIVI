#!/usr/bin/env python3 -I
"""Stock ramdisk.gz -> ramdisk.emu.gz: root console, ro.secure=0, init.emu.rc imported.
Kia-derived output stays next to the input.
usage: build-ramdisk.py ramdisk.gz ramdisk.emu.gz overlay/init.emu.rc [qfb.ko]"""
import gzip, re, sys

def parse(d):
    o, ents = 0, []
    while True:
        h = d[o:o + 110]
        assert h[:6] == b"070701"
        f = [int(h[6 + 8 * i:14 + 8 * i], 16) for i in range(13)]
        ino, mode, uid, gid, nl, mt, size, _, _, rmaj, rmin, nsz, _ = f
        name = d[o + 110:o + 110 + nsz - 1].decode()
        o = (o + 110 + nsz + 3) & ~3
        data = d[o:o + size]
        o = (o + size + 3) & ~3
        if name == "TRAILER!!!":
            return ents
        ents.append(dict(ino=ino, mode=mode, uid=uid, gid=gid, nl=nl, mt=mt, rmaj=rmaj, rmin=rmin, name=name, data=data))

def emit(ents):
    out = bytearray()
    def one(e):
        nm = e["name"].encode() + b"\0"
        out.extend(b"070701" + b"".join(b"%08x" % v for v in (
            e["ino"], e["mode"], e["uid"], e["gid"], e["nl"], e["mt"], len(e["data"]), 0, 0, e["rmaj"], e["rmin"], len(nm), 0)))
        out.extend(nm); out.extend(b"\0" * (-len(out) % 4))
        out.extend(e["data"]); out.extend(b"\0" * (-len(out) % 4))
    for e in ents: one(e)
    one(dict(ino=0, mode=0, uid=0, gid=0, nl=1, mt=0, rmaj=0, rmin=0, name="TRAILER!!!", data=b""))
    return bytes(out)

src, dst, rc = sys.argv[1:4]
ko = sys.argv[4] if len(sys.argv) > 4 else None
ents = parse(gzip.open(src).read())
by = {e["name"]: e for e in ents}
t = by["init.rc"]["data"].decode()
t = t.replace("import /init.environ.rc", "import /init.environ.rc\nimport /init.emu.rc", 1)
t = re.sub(r"(service console /system/bin/sh\n(?:    .*\n)*?)    user shell\n    group log\n", r"\1    user root\n    group root\n", t, count=1)
by["init.rc"]["data"] = t.encode()
p = by["default.prop"]
p["data"] = p["data"].replace(b"ro.secure=1", b"ro.secure=0")
nxt = max(e["ino"] for e in ents) + 1
ents.append(dict(ino=nxt, mode=0o100644, uid=0, gid=0, nl=1, mt=0, rmaj=0, rmin=0, name="init.emu.rc", data=open(rc, "rb").read()))
if ko:
    ents.append(dict(ino=nxt + 1, mode=0o100644, uid=0, gid=0, nl=1, mt=0, rmaj=0, rmin=0, name="qfb.ko", data=open(ko, "rb").read()))
p["data"] += b"ro.kernel.qemu=1\nro.kernel.qemu.gles=0\n"
open(dst, "wb").write(gzip.compress(emit(ents), 6))

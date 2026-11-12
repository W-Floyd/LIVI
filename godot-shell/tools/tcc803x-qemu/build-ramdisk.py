#!/usr/bin/env python3 -I
"""Stock ramdisk.gz -> ramdisk.emu.gz: root console, ro.secure=0, init.emu.rc imported, fstab without discard.
Kia-derived output stays next to the input.
usage: build-ramdisk.py [--egl DIR] ramdisk.gz ramdisk.emu.gz overlay/init.emu.rc [qfb.ko]
--egl: DIR's files (gles/build.sh's out/egl) go to /emu-egl and init.emu-egl.rc (next to init.emu.rc) is imported:
the GLES 2 driver for the processes in debug.emu.gles2 (default the navigation), see README "OpenGL ES 2"."""
import gzip, os, re, sys

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

args = sys.argv[1:]
egl = None
if args[:1] == ["--egl"]:
    egl, args = args[1], args[2:]
src, dst, rc = args[:3]
ko = args[3] if len(args) > 3 else None
ents = parse(gzip.open(src).read())
by = {e["name"]: e for e in ents}
t = by["init.rc"]["data"].decode()
t = t.replace("import /init.environ.rc", "import /init.environ.rc\nimport /init.emu.rc", 1)
t = re.sub(r"(service console /system/bin/sh\n(?:    .*\n)*?)    user shell\n    group log\n", r"\1    user root\n    group root\n", t, count=1)
by["init.rc"]["data"] = t.encode()
p = by["default.prop"]
p["data"] = p["data"].replace(b"ro.secure=1", b"ro.secure=0")
nxt = max(e["ino"] for e in ents) + 1
rcdata = open(rc, "rb").read()
if egl:
    rcdata += b"\nimport /init.emu-egl.rc\n"
ents.append(dict(ino=nxt, mode=0o100644, uid=0, gid=0, nl=1, mt=0, rmaj=0, rmin=0, name="init.emu.rc", data=rcdata))
if ko:
    ents.append(dict(ino=nxt + 1, mode=0o100644, uid=0, gid=0, nl=1, mt=0, rmaj=0, rmin=0, name="qfb.ko", data=open(ko, "rb").read()))
if egl:
    add = [("init.emu-egl.rc", 0o100644, open(os.path.join(os.path.dirname(rc), "init.emu-egl.rc"), "rb").read()),
           ("emu-egl", 0o40755, b"")]
    for f in sorted(os.listdir(egl)):
        x = os.access(os.path.join(egl, f), os.X_OK)
        add.append(("emu-egl/" + f, 0o100755 if x else 0o100644, open(os.path.join(egl, f), "rb").read()))
    for i, (name, mode, data) in enumerate(add):
        ents.append(dict(ino=nxt + 2 + i, mode=mode, uid=0, gid=0, nl=2 if mode & 0o40000 else 1, mt=0, rmaj=0, rmin=0,
                         name=name, data=data))
# The model's eMMC has no erase group size: ext4 `discard` makes mmc_erase divide by zero ("Division by
# zero in kernel") and stalls everything on the filesystem.
for e in ents:
    if e["name"].startswith("fstab."):
        e["data"] = e["data"].replace(b",discard", b"")
p["data"] += b"ro.kernel.qemu=1\nro.kernel.qemu.gles=0\n"
if egl:
    # zygote must not load EGL before it knows which app it forks: libGLES_emu chooses by process name.
    p["data"] += b"ro.zygote.disable_gl_preload=1\ndebug.emu.gles2=com.mnsoft.navi\n"
open(dst, "wb").write(gzip.compress(emit(ents), 6))

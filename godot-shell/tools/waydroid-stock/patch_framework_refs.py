#!/usr/bin/env python3
"""Vendor framework resources the firmware's framework-res.apk adds (android:drawable/co_bg, 0x01080110) have other
meanings in Android 13 (a progress drawable, a glow...), so every binary XML that references one draws the wrong
image. Rewrite each such reference to a color literal.
usage: patch_framework_refs.py <apk dir> <ARGB hex, e.g. ff0e1212> [id=0x01080110 ...]"""
import glob, os, struct, sys
root, color = sys.argv[1], int(sys.argv[2], 16)
ids = [int(x, 16) for x in sys.argv[3:]] or [0x01080110]
n = 0
for path in glob.glob(os.path.join(root, 'res', '**', '*.xml'), recursive=True):
    b = bytearray(open(path, 'rb').read())
    if b[:2] != b'\x03\x00':
        continue
    hit = 0
    for rid in ids:
        pat = struct.pack('<HBBI', 8, 0, 0x01, rid)
        i = b.find(pat)
        while i >= 0:
            b[i + 3] = 0x1c  # TYPE_INT_COLOR_ARGB8
            struct.pack_into('<I', b, i + 4, color)
            hit += 1
            i = b.find(pat, i + 8)
    if hit:
        open(path, 'wb').write(b)
        n += hit
print('%d framework references rewritten to color %08x' % (n, color))

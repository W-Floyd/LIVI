#!/usr/bin/env python3
"""Raise targetSdkVersion to 23 (below that Android 13 forces a permission-review screen) and turn <uses-library> elements of a binary AndroidManifest.xml into elements the parser skips (libs are bundled as stub classes).
usage: patch_manifest.py in.xml out.xml"""
import struct, sys
b = bytearray(open(sys.argv[1], 'rb').read())

def strings(b):
    off = 8
    t, hs, sz, n, ns, flags, sstart, _ = struct.unpack_from('<HHIIIIII', b, off)
    assert t == 1
    utf8 = flags & 0x100
    idx = struct.unpack_from('<%dI' % n, b, off + hs)
    out = []
    for o in idx:
        p = off + sstart + o
        if utf8:
            l = b[p]; p += 1 if l < 0x80 else 2
            l = b[p]; p += 1 if l < 0x80 else 2
            out.append(bytes(b[p:p + (l if False else b.index(0, p) - p)]).decode('utf8', 'replace'))
        else:
            l = struct.unpack_from('<H', b, p)[0]; p += 2
            out.append(bytes(b[p:p + 2 * l]).decode('utf-16le'))
    return out, sz

S, pool_sz = strings(b)
src = S.index('uses-library')
dst = S.index('meta-data') if 'meta-data' in S else S.index('uses-permission')  # PackageParser skips either under <application>
off = 8 + pool_sz
n = 0
while off < len(b):
    t, hs, sz = struct.unpack_from('<HHI', b, off)
    if t in (0x102, 0x103):
        nm = struct.unpack_from('<I', b, off + 20)[0]
        if nm == src:
            struct.pack_into('<I', b, off + 20, dst); n += 1
        if t == 0x102 and S[nm] == 'uses-sdk':
            ac = struct.unpack_from('<H', b, off + 28)[0]
            for i in range(ac):
                a = off + 36 + 20 * i
                if S[struct.unpack_from('<I', b, a + 4)[0]] == 'targetSdkVersion':
                    struct.pack_into('<I', b, a + 16, 23)
    off += sz
open(sys.argv[2], 'wb').write(b)
print('uses-library -> skipped element: %d elements' % (n // 2))

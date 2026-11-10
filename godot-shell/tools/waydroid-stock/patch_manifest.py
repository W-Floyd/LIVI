#!/usr/bin/env python3
"""Raise targetSdkVersion to 23, or $TARGET_SDK (below 23 Android 13 forces a permission-review screen, below 26 it letterboxes to 1.86:1; Android 13 forces a permission-review screen) and turn <uses-library> elements of a binary AndroidManifest.xml into elements the parser skips (libs are bundled as stub classes).
usage: patch_manifest.py in.xml out.xml"""
import os, struct, sys
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

def rename_attr(b, S, old, new, res_id):
    """Rename attribute `old` to `new` (resource id `res_id`) by rewriting its string and its resource-map entry: the
    string pool is rebuilt, every reference is an index and stays valid. UTF-16 pools only."""
    i = S.index(old)
    S = list(S); S[i] = new
    off = 8
    t, hs, sz, n, ns, flags, sstart, _ = struct.unpack_from('<HHIIIIII', b, off)
    assert t == 1 and ns == 0 and not flags & 0x100
    data = bytearray(); offs = []
    for x in S:
        offs.append(len(data))
        e = x.encode('utf-16le')
        data += struct.pack('<H', len(x)) + e + b'\0\0'
    while len(data) % 4:
        data.append(0)
    sstart = hs + 4 * n
    pool = struct.pack('<HHIIIIII', 1, hs, sstart + len(data), n, 0, flags, sstart, 0) + struct.pack('<%dI' % n, *offs) + data
    rest = bytearray(b[off + sz:])
    assert struct.unpack_from('<H', rest, 0)[0] == 0x180
    struct.pack_into('<I', rest, 8 + 4 * i, res_id)
    return bytearray(b[:8]) + pool + rest, S

if os.environ.get('RESIZEABLE', '1') == '1' and 'supportsRtl' in S:
    # android:resizeableActivity on <application>: without it Android 13 letterboxes an old app to 1.86:1
    b, S = rename_attr(b, S, 'supportsRtl', 'resizeableActivity', 0x010103f9)
    struct.pack_into('<I', b, 4, len(b))
    S, pool_sz = strings(b)
    # and android:maxAspectRatio=3.0 on <application>, in place of android:persistent (a car's own process flag)
    b, S = rename_attr(b, S, 'persistent', 'maxAspectRatio', 0x0101055a)
    S, pool_sz = strings(b)
    o = 8 + pool_sz
    o += struct.unpack_from('<I', b, o + 4)[0]
    while o < len(b):
        t, h, z = struct.unpack_from('<HHI', b, o)
        if t == 0x102 and S[struct.unpack_from('<I', b, o + 20)[0]] == 'application':
            for i in range(struct.unpack_from('<H', b, o + 28)[0]):
                a = o + 36 + 20 * i
                if S[struct.unpack_from('<I', b, a + 4)[0]] == 'maxAspectRatio':
                    struct.pack_into('<HBBf', b, a + 12, 8, 0, 0x04, 3.0)
        o += z
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
                    struct.pack_into('<I', b, a + 16, int(os.environ.get('TARGET_SDK', '23')))
    off += sz
open(sys.argv[2], 'wb').write(b)
print('uses-library -> skipped element: %d elements; resizeableActivity set' % (n // 2))

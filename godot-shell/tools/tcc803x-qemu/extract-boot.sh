#!/bin/sh
# Split the stock Android boot.img into $OUT/kernel (zImage) and $OUT/ramdisk.gz.
# usage: extract-boot.sh /path/to/boot.img /path/to/outdir   (outputs are Kia firmware: keep out of the repo)
set -eu
python3 -I - "$1" "$2" <<'PY'
import struct, sys, os
img, out = sys.argv[1:3]
d = open(img, 'rb').read()
(magic, ks, ka, rs, ra, ss, sa, ta, ps) = struct.unpack('<8s8I', d[:40])
assert magic == b'ANDROID!', magic
os.makedirs(out, exist_ok=True)
rup = lambda n: (n + ps - 1) // ps * ps
o = ps
open(os.path.join(out, 'kernel'), 'wb').write(d[o:o + ks]); o += rup(ks)
open(os.path.join(out, 'ramdisk.gz'), 'wb').write(d[o:o + rs])
print('kernel %d bytes, ramdisk %d bytes' % (ks, rs))
PY

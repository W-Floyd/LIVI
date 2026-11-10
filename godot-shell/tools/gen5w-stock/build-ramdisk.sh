#!/usr/bin/env bash
# Build ramdisk.cpio.gz from the stock boot.img ramdisk: virtio-blk fstab,
# busybox for emuctl, init_wrap.sh as rdinit, a root console service.
# Kia-derived content stays under $WORK.
# usage: WORK=... BOOT_IMG=.../boot.img ./build-ramdisk.sh
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=${WORK:?}; BOOT_IMG=${BOOT_IMG:?stock boot.img}
mkdir -p "$WORK/bootimg"
python3 -I - "$BOOT_IMG" "$WORK/bootimg" <<'PY'
import struct, sys
d = open(sys.argv[1], "rb").read()
_, ks, _, rs, _, _, _, _, ps = struct.unpack("<8s8I", d[:40])
o = ps
o += (ks + ps - 1) // ps * ps
open(sys.argv[2] + "/ramdisk.gz", "wb").write(d[o:o + rs])
PY
docker image inspect gen5w-build >/dev/null 2>&1 || docker build --platform linux/arm64 -t gen5w-build "$HERE"
docker run --rm --platform linux/arm64 -v "$WORK/bootimg:/in:ro" -v "$HERE/ramdisk-overlay:/ov:ro" -v "$WORK:/out" \
  gen5w-build bash -euo pipefail -c '
rm -rf /rd && mkdir /rd && cd /rd
gzip -dc /in/ramdisk.gz | cpio -id --no-absolute-filenames 2>/dev/null
# busybox (static armhf) for emuctl: /sbin/busybox printf etc.
mkdir /deb && cd /deb && dpkg --add-architecture armhf
sed -i "s#^deb #deb [arch=arm64,armhf] #" /etc/apt/sources.list
apt-get update -qq >/dev/null && apt-get download busybox-static:armhf >/dev/null
dpkg -x busybox-static*.deb /deb/x && cd /rd
install -m 0755 /deb/x/bin/busybox sbin/busybox
install -m 0755 /ov/init_wrap.sh init_wrap.sh
install -m 0644 /ov/init.emu.rc init.emu.rc
sed -i "s#^import /init.environ.rc#&\nimport /init.emu.rc#" init.rc
# the stock console service (started by ro.debuggable=1) runs as shell; emuctl needs root
sed -i "/^service console /,/^$/{s/user shell/user root/;s/group log/group root/}" init.rc
# by-name partition -> virtio-blk partition number (GPT order of build-emmc.sh)
n=0; for p in boot recovery misc kpanic log system cache data securedata navi navi2 upgrade vr1 vr2 oem_data; do
  n=$((n+1)); sed -i "s#/dev/block/platform/bdm/by-name/$p\b#/dev/block/vda$n#g" fstab.tcc803x init.*.rc
done
# no e2fsck/discard/encryption in the emulator
sed -i -E "s/,?discard//; s/wait,check,encryptable=[^ ]*/wait/; s/wait,check/wait/" fstab.tcc803x
sed -i "s#^ro.debuggable=.*#ro.debuggable=1#; s#^ro.secure=.*#ro.secure=0#" default.prop
# libEGL only falls back to the software libGLES_android when it thinks it is the emulator
printf "ro.kernel.qemu=1\nro.kernel.qemu.gles=0\n" >> default.prop
find . | cpio -o -H newc -R 0:0 2>/dev/null | gzip -9 > /out/ramdisk.cpio.gz
ls -la /out/ramdisk.cpio.gz; grep -n vda fstab.tcc803x | head -20
'

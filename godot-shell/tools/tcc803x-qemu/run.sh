#!/bin/sh
# Boot the stock Gen5W kernel on the tcc803x QEMU machine; serial console on stdout.
# Env: BOOT_DIR  dir with the extracted stock `kernel` (zImage) and `ramdisk.gz` (see README)
#      EMMC      optional raw eMMC image (GPT, by-name partitions), attached read-only (snapshot)
#      TIMEOUT   seconds (default 60)     APPEND  kernel command line override
#      EXTRA     extra qemu args
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
: "${BOOT_DIR:?set BOOT_DIR}"
TIMEOUT=${TIMEOUT:-60}
APPEND=${APPEND:-"earlycon=pl011,mmio32,0x16600000 console=ttyTCC0,115200n8 earlyprintk ignore_loglevel androidboot.hardware=tcc803x androidboot.mode=emmc androidboot.selinux=disabled maxcpus=1 vmalloc=400M"}
set -- -v tcc803x-qemu-build:/work:ro -v "$HERE":/h:ro -v "$BOOT_DIR":/boot:ro -v tcc803x-qemu-run:/run/q
DRIVE=
if [ -n "${EMMC:-}" ]; then
  set -- "$@" -v "$EMMC":/emmc.img:ro
  DRIVE="-drive if=sd,index=0,format=raw,snapshot=on,file=/emmc.img"
fi
docker run --rm ${DOCKER_FLAGS:-} "$@" -e RAMDISK="${RAMDISK:-ramdisk.gz}" -e DRIVE="$DRIVE" -e APPEND="$APPEND" -e EXTRA="${EXTRA:-}" -e DEBUG="${DEBUG:-guest_errors,unimp}" tcc803x-qemu-dev sh -ec '
  cpp -P -x assembler-with-cpp /h/tcc803x-qemu.dts | dtc -q -I dts -O dtb -o /run/q/tcc803x.dtb -
  timeout '"$TIMEOUT"' /work/qemu/build/qemu-system-arm -M tcc803x -m 1024 \
    -kernel /boot/kernel -dtb /run/q/tcc803x.dtb -initrd /boot/$RAMDISK -append "$APPEND" \
    $DRIVE -display none -serial mon:stdio -d "$DEBUG" -D /run/q/qemu.log $EXTRA || true
  echo "--- qemu.log (unimp/guest_errors, most frequent first)"
  sed -e "s/offset 0x[0-9a-f]*//" /run/q/qemu.log | sort | uniq -c | sort -rn | head -20'

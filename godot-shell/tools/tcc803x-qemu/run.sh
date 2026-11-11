#!/bin/sh
# Boot the stock Gen5W kernel on the tcc803x QEMU machine; serial console on stdout.
# Env: BOOT_DIR  dir with the extracted stock `kernel` (zImage) and `ramdisk.gz` (see README)
#      EMMC      optional raw eMMC image (GPT, by-name partitions), attached read-only (snapshot)
#      TIMEOUT   seconds (default 60)     APPEND  kernel command line override
#      SMP       vCPUs (default 4; 1 is much slower and stalls, see README "Performance")
#      QEMU      path to a native qemu-system-arm (build-native.sh): run without docker (about as fast or faster)
#      LOADVM    with QEMU and a qcow2 EMMC: resume the savevm snapshot of that name (README "Snapshot")
#      MON       with QEMU: unix socket path for the HMP monitor (drive.py screendumps)
#      DEBUG     qemu -d flags (default none; `guest_errors,unimp` logs to qemu.log, harmless but noisy)
#      EXTRA     extra qemu args
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
: "${BOOT_DIR:?set BOOT_DIR}"
TIMEOUT=${TIMEOUT:-60}
SMP=${SMP:-4}
RAMDISK=${RAMDISK:-ramdisk.gz}
APPEND=${APPEND:-"earlycon=pl011,mmio32,0x16600000 console=ttyTCC0,115200n8 earlyprintk ignore_loglevel androidboot.hardware=tcc803x androidboot.mode=emmc androidboot.selinux=disabled vmalloc=400M"}
[ "$SMP" -gt 1 ] || APPEND="$APPEND maxcpus=1"
DEBUG=${DEBUG:-}
if [ -n "${QEMU:-}" ]; then
  W=${TMPDIR:-/tmp}/tcc803x-run.$$; mkdir -p "$W"; trap 'rm -rf "$W"' EXIT
  clang -E -P -x assembler-with-cpp "$HERE/tcc803x-qemu.dts" | dtc -q -I dts -O dtb -o "$W/t.dtb" -
  set -- -M tcc803x -m 1024 -smp "$SMP" -kernel "$BOOT_DIR/kernel" -dtb "$W/t.dtb" -initrd "$BOOT_DIR/$RAMDISK" \
    -append "$APPEND" -display none -serial mon:stdio
  case "${EMMC:-}" in
    "") ;;
    *.qcow2) set -- "$@" -drive "if=sd,index=0,format=qcow2,file=$EMMC" ;;
    *) set -- "$@" -drive "if=sd,index=0,format=raw,snapshot=on,file=$EMMC" ;;
  esac
  [ -z "${LOADVM:-}" ] || set -- "$@" -loadvm "$LOADVM"
  [ -z "$DEBUG" ] || set -- "$@" -d "$DEBUG" -D "$W/qemu.log"
  [ -z "${MON:-}" ] || set -- "$@" -monitor "unix:$MON,server,nowait"
  # shellcheck disable=SC2086
  exec perl -e 'alarm shift; exec @ARGV' "$TIMEOUT" "$QEMU" "$@" ${EXTRA:-}
fi
set -- -v tcc803x-qemu-build:/work:ro -v "$HERE":/h:ro -v "$BOOT_DIR":/boot:ro -v tcc803x-qemu-run:/run/q
DRIVE=
if [ -n "${EMMC:-}" ]; then
  set -- "$@" -v "$EMMC":/emmc.img:ro
  DRIVE="-drive if=sd,index=0,format=raw,snapshot=on,file=/emmc.img"
fi
DBG=
[ -z "$DEBUG" ] || DBG="-d $DEBUG -D /run/q/qemu.log"
docker run --rm ${DOCKER_FLAGS:-} "$@" -e RAMDISK="$RAMDISK" -e DRIVE="$DRIVE" -e APPEND="$APPEND" -e EXTRA="${EXTRA:-}" -e DBG="$DBG" -e SMP="$SMP" tcc803x-qemu-dev sh -ec '
  rm -f /run/q/qemu.log
  cpp -P -x assembler-with-cpp /h/tcc803x-qemu.dts | dtc -q -I dts -O dtb -o /run/q/tcc803x.dtb -
  timeout '"$TIMEOUT"' /work/qemu/build/qemu-system-arm -M tcc803x -m 1024 -smp $SMP \
    -kernel /boot/kernel -dtb /run/q/tcc803x.dtb -initrd /boot/$RAMDISK -append "$APPEND" \
    $DRIVE -display none -serial mon:stdio $DBG $EXTRA || true
  [ ! -f /run/q/qemu.log ] || { echo "--- qemu.log (unimp/guest_errors, most frequent first)"
  sed -e "s/offset 0x[0-9a-f]*//" /run/q/qemu.log | sort | uniq -c | sort -rn | head -20; }'

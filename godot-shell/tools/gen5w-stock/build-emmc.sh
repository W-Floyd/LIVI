#!/usr/bin/env bash
# Build emmc.img (GPT, full by-name layout) around the decrypted V015 system.ext4
# using the emulator's own tools/build-full-emmc.sh, inside Docker.
# usage: WORK=... EMU=path/to/gen5w-emulator SYSTEM_EXT4=.../system.ext4 [DATA_MIB=n] [CACHE_MIB=n] ./build-emmc.sh
# DATA_MIB/CACHE_MIB override the emulator tool's partition sizes (520/278 MiB).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/../../scripts/dotenv.sh"
WORK=${WORK:?}; EMU=${EMU:?}; SYSTEM_EXT4=${SYSTEM_EXT4:?}
mkdir -p "$WORK/image"
docker image inspect gen5w-build >/dev/null 2>&1 || docker build --platform linux/arm64 -t gen5w-build "$HERE"
docker run --rm --platform linux/arm64 -e DATA_MIB="${DATA_MIB:-}" -e CACHE_MIB="${CACHE_MIB:-}" \
  -v "$EMU/tools/build-full-emmc.sh:/build-full-emmc.sh:ro" \
  -v "$SYSTEM_EXT4:/system.ext4:ro" -v "$WORK/image:/out" \
  gen5w-build bash -c 'sed -e "s/\[cache\]=[0-9]*/[cache]=${CACHE_MIB:-278}/" -e "s/\[data\]=[0-9]*/[data]=${DATA_MIB:-520}/" /build-full-emmc.sh > /tmp/b.sh
yes | bash /tmp/b.sh --system /system.ext4 --out /out/emmc.img --force
# kpanic/log are left blank by the emulator tool; the stock fstab mounts log
# (mount_all stops at the first failure and /data is never mounted), so give it ext4.
mkfs_part() {
  n=$1; start=$(sgdisk -i "$n" /out/emmc.img | sed -n "s/^First sector: \([0-9]*\).*/\1/p")
  size=$(sgdisk -i "$n" /out/emmc.img | sed -n "s/^Partition size: \([0-9]*\) sectors.*/\1/p")
  mke2fs -F -q -t ext4 -b 1024 -m 0 -O ^64bit,^metadata_csum -E offset=$((start*512)) /out/emmc.img $((size/2))
}
mkfs_part 5'

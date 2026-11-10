#!/usr/bin/env bash
# Build a Linux 4.4 LTS zImage for the gen5w emulator (QEMU virt, Cortex-A7)
# that can run the stock Android 4.4 userland. Everything is downloaded from
# kernel.org and built in Docker; the output is $WORK/zImage.
# usage: WORK=/path/to/work ./build-kernel.sh
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=${WORK:?set WORK to the (gitignored) work dir}
KVER=${KVER:-4.4.302}
mkdir -p "$WORK/dl"
docker image inspect gen5w-build >/dev/null 2>&1 || docker build --platform linux/arm64 -t gen5w-build "$HERE"
[ -f "$WORK/dl/linux-$KVER.tar.xz" ] ||
  curl -fsSL -o "$WORK/dl/linux-$KVER.tar.xz" "https://cdn.kernel.org/pub/linux/kernel/v4.x/linux-$KVER.tar.xz"
[ -f "$WORK/dl/linux-3.18.140.tar.xz" ] ||
  curl -fsSL -o "$WORK/dl/linux-3.18.140.tar.xz" "https://cdn.kernel.org/pub/linux/kernel/v3.x/linux-3.18.140.tar.xz"

# A named volume keeps the object files between runs (bind mounts are slow).
docker run --rm --platform linux/arm64 \
  -v gen5w-kbuild:/k \
  -v "$WORK/dl:/dl:ro" -v "$HERE:/cfg:ro" -v "$WORK:/out" \
  -e KVER="$KVER" gen5w-build bash -euo pipefail -c '
cd /k
if [ ! -d linux-$KVER ]; then
  tar -xf /dl/linux-$KVER.tar.xz
  tar -xf /dl/linux-3.18.140.tar.xz linux-3.18.140/drivers/staging/android
  cd linux-$KVER
  bash /cfg/kernel-backports.sh /k/linux-3.18.140 /k/linux-$KVER
else cd linux-$KVER; fi
export ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf-
[ -f .config ] || { make multi_v7_defconfig; scripts/kconfig/merge_config.sh -m .config /cfg/gen5w.config; make olddefconfig; }
make -j$(nproc) zImage > /out/kbuild-full.log 2>&1 || { grep -E -B3 -A3 "error|\*\*\*" /out/kbuild-full.log | head -60; exit 1; }
tail -3 /out/kbuild-full.log
cp arch/arm/boot/zImage /out/zImage
cp .config /out/kernel.config
ls -la /out/zImage
'

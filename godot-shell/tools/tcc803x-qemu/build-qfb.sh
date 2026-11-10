#!/usr/bin/env bash
# Build qfb.ko against vanilla linux-3.18.x configured like the stock kernel, with the
# version forced to 3.18.24 so the vermagic matches (no MODVERSIONS in the stock config).
# usage: build-qfb.sh <stock kernel config> <linux-3.18.x.tar.xz> <out dir>
# needs the gen5w-build image (docker build -t gen5w-build ../gen5w-stock)
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
CFG=$(cd "$(dirname "$1")" && pwd)/$(basename "$1"); TAR=$(cd "$(dirname "$2")" && pwd)/$(basename "$2")
mkdir -p "$3"; OUT=$(cd "$3" && pwd)
docker run --rm --platform linux/arm64 -v "$CFG":/config:ro -v "$TAR":/linux.tar.xz:ro -v "$HERE/qfb":/qfb:ro -v "$OUT":/out gen5w-build bash -euo pipefail -c '
mkdir /k && tar -C /k --strip-components=1 -xJf /linux.tar.xz && cd /k
sed -i "s/^SUBLEVEL = .*/SUBLEVEL = 24/" Makefile
cp /config .config
export ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf-
sed -i "/^CONFIG_CC_STACKPROTECTOR/d; /^# CONFIG_CC_STACKPROTECTOR/d" .config
make olddefconfig >/dev/null
make -j"$(nproc)" modules_prepare >/dev/null 2>&1
mkdir /m && cp /qfb/qfb.c /m/ && echo "obj-m := qfb.o" > /m/Makefile
make -C /k M=/m modules 2>&1 | tail -5
cp /m/qfb.ko /out/ && grep -a -o "vermagic=[ -~]*" /m/qfb.ko'

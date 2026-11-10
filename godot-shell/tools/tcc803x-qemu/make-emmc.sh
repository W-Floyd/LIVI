#!/bin/sh
# Make an 8 GiB eMMC image for the machine from an existing GPT by-name image (QEMU eMMC sizes must be
# powers of two). usage: make-emmc.sh in.img out.img   (e.g. the image from tools/gen5w-stock/build-emmc.sh)
set -eu
cp "$1" "$2"
truncate -s 8G "$2"
docker run --rm -v "$(cd "$(dirname "$2")" && pwd)":/i tcc803x-qemu-dev sgdisk -e "/i/$(basename "$2")"

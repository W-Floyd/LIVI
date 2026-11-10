#!/bin/sh
# Builds qemu-system-arm with the tcc803x machine into the docker volume tcc803x-qemu-build.
# Usage: build.sh   (re-run after editing qemu-tcc803x.patch)
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
TAG=${QEMU_TAG:-v10.0.3}
docker build -q -t tcc803x-qemu-dev "$HERE" >/dev/null
docker run --rm -v tcc803x-qemu-build:/work -v "$HERE":/patch:ro tcc803x-qemu-dev sh -ec '
  [ -d qemu ] || git clone --depth 1 --branch '"$TAG"' https://gitlab.com/qemu-project/qemu.git
  cd qemu
  git reset -q --hard && git clean -fdq
  [ ! -s /patch/qemu-tcc803x.patch ] || git apply /patch/qemu-tcc803x.patch
  mkdir -p build && cd build
  [ -f build.ninja ] || ../configure --target-list=arm-softmmu --disable-docs --disable-werror --disable-tools --disable-guest-agent
  ninja qemu-system-arm
  ls -l qemu-system-arm
'

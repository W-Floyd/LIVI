#!/bin/sh
# Build the patched qemu-system-arm natively (macOS or Linux), no docker. Prints the binary path;
# use it as QEMU=... for run.sh / drive.py / bench.py.
# Needs: ninja pkg-config glib pixman python3 (brew install ninja pkg-config glib pixman).
# usage: build-native.sh [build dir]   (default ~/.cache/tcc803x-qemu)
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
TAG=${QEMU_VERSION:-10.0.3}
D=${1:-$HOME/.cache/tcc803x-qemu}
mkdir -p "$D" && cd "$D"
[ -d "qemu-$TAG" ] || {
  curl -fsSL -o q.tar.xz "https://download.qemu.org/qemu-$TAG.tar.xz"
  tar xf q.tar.xz && rm q.tar.xz
  patch -d "qemu-$TAG" -p1 -s < "$HERE/qemu-tcc803x.patch"
}
# configure's mkvenv wants meson + pycotap and would pip-install them (hangs offline).
[ -x v/bin/python ] || { python3 -m venv v && v/bin/pip -q install meson distlib tomli pycotap; }
# configure also probes `docker` (tests/docker/docker.py) and hangs for minutes when Docker Desktop is wedged.
mkdir -p stub && printf '#!/bin/sh\nexit 1\n' > stub/docker && cp stub/docker stub/podman && chmod +x stub/*
export PATH="$D/stub:$D/v/bin:$PATH"
mkdir -p "qemu-$TAG/build" && cd "qemu-$TAG/build"
[ -f build.ninja ] || ../configure --target-list=arm-softmmu --disable-docs --disable-werror --disable-tools \
  --disable-guest-agent --python="$D/v/bin/python"
ninja qemu-system-arm >&2
echo "$PWD/qemu-system-arm"

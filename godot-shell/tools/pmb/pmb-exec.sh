#!/bin/sh
# Run a command in the pmbootstrap container, as pmos in /home/pmos, stdin and stdout passed
# through (binary-safe without a terminal). The image is built on first use and whenever the
# Dockerfile or entrypoint changes; pmbootstrap's work dir and caches are in the volume.
#   tools/pmb/pmb-exec.sh pmbootstrap --version
#   PMB_VOLUME (livi-pmb), PMB_IMAGE (livi-pmb)
set -eu
d=$(cd "$(dirname "$0")" && pwd)
vol=${PMB_VOLUME:-livi-pmb}
img=${PMB_IMAGE:-livi-pmb}:$(cat "$d/Dockerfile" "$d/entrypoint.sh" | cksum | cut -d' ' -f1)
# stdout may be the payload, so build output goes to stderr.
docker image inspect "$img" >/dev/null 2>&1 || docker build -t "$img" "$d" >&2
t=
if [ -t 0 ] && [ -t 1 ]; then t=-t; fi
# --privileged: loop devices, chroot mounts, binfmt_misc.
exec docker run --rm -i $t --privileged -v "$vol:/home/pmos" "$img" "$@"

#!/bin/sh
# As root, then the command as pmos. Needs --privileged.
# Docker's /dev is a tmpfs, where the /dev/loopNpM nodes of `losetup -P` never appear; a devtmpfs
# shows them, and hides Docker's pts and shm, so those come back.
if mount -t devtmpfs devtmpfs /dev 2>/dev/null; then
    mkdir -p /dev/pts /dev/shm
    mount -t devpts -o gid=5,mode=620,ptmxmode=666 devpts /dev/pts
    [ -e /dev/ptmx ] || ln -sf /dev/pts/ptmx /dev/ptmx
    mount -t tmpfs -o mode=1777,nosuid,nodev tmpfs /dev/shm
else
    echo "warning: no devtmpfs on /dev (not --privileged?); pmbootstrap install will fail" >&2
fi
# Foreign-arch chroots: pmbootstrap registers its qemu-user handlers here. Registrations are the
# Docker kernel's, shared with every container.
[ -e /proc/sys/fs/binfmt_misc/status ] ||
    mount -t binfmt_misc none /proc/sys/fs/binfmt_misc 2>/dev/null ||
    echo "warning: no binfmt_misc; foreign-arch chroots will fail" >&2
# The volume starts root-owned and empty. A work dir without a version file is refused, and
# `pmbootstrap init` is interactive.
work=/home/pmos/.local/var/pmbootstrap
chown pmos:pmos /home/pmos
[ -e "$work/version" ] || su-exec pmos sh -c 'mkdir -p "$1" && cd /opt/pmbootstrap &&
    python3 -c "import pmb.config; print(pmb.config.work_version)" > "$1/version"' sh "$work"
exec su-exec pmos "$@"

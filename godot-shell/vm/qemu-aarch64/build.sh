#!/bin/sh
# Build the postmarketOS qemu-aarch64 GNOME image with pmbootstrap (tools/pmb) and turn it
# into ./pmos.qcow2 (grown to $SIZE; the initramfs grows the root partition to fill it on
# first boot). Needs Docker and qemu-img.
#
# Uses its own pmbootstrap config (./pmbootstrap.cfg) and rootfs, so another device's in the
# same work dir are untouched.
set -eu
cd "$(dirname "$0")"
gs=$(cd ../.. && pwd)
. "$gs/scripts/dotenv.sh"
. "$gs/tools/pmb/env.sh"
SIZE=${SIZE:-20G}
SSH_PUBKEY=${SSH_PUBKEY:-$HOME/.ssh/id_ed25519.pub}
CFG=/home/pmos/.config/pmbootstrap-qemu-aarch64.cfg
WORK=/home/pmos/.local/var/pmbootstrap
IMG=$WORK/chroot_native/home/pmos/rootfs/qemu-aarch64.img
ROOTFS=$WORK/chroot_rootfs_qemu-aarch64
MIN_FREE_GB=15

# Assumes Docker's disk is on the file system of this folder.
free_gb() { df -Pk . | awk 'NR==2 {print int($4 / 1048576)}'; }
check_space() {
    f=$(free_gb)
    [ "$f" -ge $MIN_FREE_GB ] || { echo "only ${f} GB free, stopping ($1)" >&2; exit 1; }
}

[ ! -e pmos.qcow2 ] || { echo "pmos.qcow2 exists; move it away first" >&2; exit 1; }
check_space start

# The container cannot see this folder, so the config goes in over stdin; a
# copy, too, because pmbootstrap may rewrite its config.
pmb_config "$CFG" < pmbootstrap.cfg
pmb_aports

# (--no-local-pkgs is refused while the work dir has other local packages.)
pmb() { pmb_exec pmbootstrap --config "$CFG" -y "$@"; }

# Rootfs first, then ./overlay (autologin, no idle/lock/suspend) on top, then
# the image: a second install reuses the rootfs, overlay included.
# shutdown: a previous image install leaves chroot_native/dev/installp* nodes
# that point at stale loop partitions, and mkfs then fails.
pmb shutdown
pmb install --password nura --no-image
COPYFILE_DISABLE=1 tar -C overlay -cf - . |
    pmb_exec sudo tar -xof - -C "$ROOTFS"
# This machine's key, so ssh needs no password. Read here, not kept in overlay/.
if [ -f "$SSH_PUBKEY" ]; then
    pmb_exec sudo sh -c 'd=$1/home/user/.ssh &&
        install -d -m 700 -o 10000 -g 10000 "$d" &&
        cat > "$d/authorized_keys" && chown 10000:10000 "$d/authorized_keys" &&
        chmod 600 "$d/authorized_keys"' sh "$ROOTFS" < "$SSH_PUBKEY"
else
    echo "no $SSH_PUBKEY: ssh takes the password only" >&2
fi
pmb chroot -r -- glib-compile-schemas /usr/share/glib-2.0/schemas
pmb install --password nura --no-split
pmb shutdown
check_space "after install"

pmb_exec sudo cat "$IMG" > pmos.img
check_space "after export"
qemu-img convert -p -f raw -O qcow2 pmos.img pmos.qcow2
rm pmos.img
qemu-img resize pmos.qcow2 "$SIZE"
qemu-img info pmos.qcow2

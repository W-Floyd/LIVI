#!/bin/sh
# Build the postmarketOS qemu-aarch64 GNOME image in the nura builder container
# and turn it into ./pmos.qcow2 (grown to $SIZE; the initramfs grows the root
# partition to fill it on first boot).
#
# Uses its own pmbootstrap config (./pmbootstrap.cfg) so the mobis-g5w config
# and rootfs are untouched; the work dir and package caches are shared.
set -eu
cd "$(dirname "$0")"
NURA_DIR=${NURA_DIR:-/Users/william/Documents/Personal/git/nura-G5W-Android}
NURA=$NURA_DIR/nura
SIZE=${SIZE:-20G}
CFG=/home/pmos/.config/pmbootstrap-qemu-aarch64.cfg
WORK=/home/pmos/.local/var/pmbootstrap
IMG=$WORK/chroot_native/home/pmos/rootfs/qemu-aarch64.img
ROOTFS=$WORK/chroot_rootfs_qemu-aarch64
MIN_FREE_GB=15

free_gb() { df -g /System/Volumes/Data | awk 'NR==2 {print $4}'; }
check_space() {
    f=$(free_gb)
    [ "$f" -ge $MIN_FREE_GB ] || { echo "only ${f} GB free on the Mac, stopping ($1)" >&2; exit 1; }
}

[ ! -e pmos.qcow2 ] || { echo "pmos.qcow2 exists; move it away first" >&2; exit 1; }
check_space start

# The container cannot see this folder, so the config goes in over stdin; a
# copy, too, because pmbootstrap may rewrite its config.
"$NURA" exec sh -c 'cat > "$1"' sh "$CFG" < pmbootstrap.cfg

# exec, not `./nura pmb`: that would first sync the pmaports worktree.
# (--no-local-pkgs is refused while the head unit's armv7 packages exist.)
pmb() { "$NURA" exec pmbootstrap --config "$CFG" -y "$@"; }

# Rootfs first, then ./overlay (autologin, no idle/lock/suspend) on top, then
# the image: a second install reuses the rootfs, overlay included.
# shutdown: a previous image install leaves chroot_native/dev/installp* nodes
# that point at stale loop partitions, and mkfs then fails.
pmb shutdown
pmb install --password nura --no-image
COPYFILE_DISABLE=1 tar -C overlay -cf - . |
    "$NURA" exec sudo tar -xof - -C "$ROOTFS"
pmb chroot -r -- glib-compile-schemas /usr/share/glib-2.0/schemas
pmb install --password nura --no-split
pmb shutdown
check_space "after install"

"$NURA" exec sudo cat "$IMG" > pmos.img
check_space "after export"
qemu-img convert -p -f raw -O qcow2 pmos.img pmos.qcow2
rm pmos.img
qemu-img resize pmos.qcow2 "$SIZE"
qemu-img info pmos.qcow2

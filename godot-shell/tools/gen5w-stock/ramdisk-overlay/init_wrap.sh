#!/sbin/busybox sh
# rdinit for QEMU virt: nothing the stock init needs is missing from the
# kernel, so hand over to it.
/sbin/busybox mkdir -p /proc /sys /dev
exec /init

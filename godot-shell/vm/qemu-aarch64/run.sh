#!/bin/sh
# Start the postmarketOS VM: UEFI (edk2) -> systemd-boot on the image's boot
# partition. ssh -p 2222 user@localhost (password nura).
#
#   ./run.sh                      cocoa window, in the foreground
#   ./run.sh --headless           no window, daemonized (or HEADLESS=1)
#   ./run.sh --headless --vnc 1   ...plus VNC on 127.0.0.1:5901 (or VNC=1)
#   ./run.sh --stop               guest-agent shutdown, then ACPI, then `quit`
#
# Arguments after the options go to qemu.
set -eu
cd "$(dirname "$0")"

QMP=$PWD/qmp.sock
MON=$PWD/monitor.sock
QGA=$PWD/qga.sock
PID=$PWD/qemu.pid
CPUS=${CPUS:-6}
MEM=${MEM:-8G}
HEADLESS=${HEADLESS:-0}
VNC=${VNC:-}

qmp() {
    printf '{"execute":"qmp_capabilities"}\n{"execute":"%s"}\n' "$1" |
        nc -U -w 1 "$QMP" >/dev/null 2>&1 || true
}
# qemu removes the pidfile as it exits.
alive() { p=$(cat "$PID" 2>/dev/null) && kill -0 "$p" 2>/dev/null; }

wait_exit() {
    i=0
    while alive && [ $i -lt "$1" ]; do sleep 1; i=$((i + 1)); done
    ! alive
}

# The guest agent first: GNOME holds logind's power-key inhibitor, so ACPI
# powerdown alone is ignored while the session is up.
stop() {
    alive || { echo "not running"; rm -f "$PID"; return; }
    # Held open: qemu-ga drops a command whose connection closes at once.
    { echo '{"execute":"guest-shutdown"}'; sleep 2; } | nc -U "$QGA" >/dev/null 2>&1 || true
    wait_exit 30 || { qmp system_powerdown; wait_exit 15; } ||
        { echo "no clean shutdown, quitting"; qmp quit; wait_exit 3; } ||
        kill "$(cat "$PID")"
    rm -f "$PID"
}

while [ $# -gt 0 ]; do
    case $1 in
    --stop) stop; exit ;;
    --headless) HEADLESS=1 ;;
    --vnc) VNC=$2; shift ;;
    --) shift; break ;;
    *) break ;;
    esac
    shift
done

alive && { echo "already running (pid $(cat "$PID"))" >&2; exit 1; }

FW=/opt/homebrew/share/qemu/edk2-aarch64-code.fd
# systemd-boot writes EFI variables; give the firmware its own writable store.
# bootindex on the disk: the store's boot entries name PCI slots, which move
# when devices are added, and edk2 then falls to its shell.
[ -e efi-vars.fd ] || cp /opt/homebrew/share/qemu/edk2-arm-vars.fd efi-vars.fd

set -- \
    -M virt,highmem=on -accel hvf -cpu host \
    -smp "$CPUS" -m "$MEM" \
    -drive if=pflash,format=raw,readonly=on,file="$FW" \
    -drive if=pflash,format=raw,file=efi-vars.fd \
    -drive if=none,id=hd,format=qcow2,file=pmos.qcow2,discard=unmap \
    -device virtio-blk-pci,drive=hd,bootindex=0 \
    -netdev user,id=net,hostfwd=tcp:127.0.0.1:2222-:22 \
    -device virtio-net-pci,netdev=net \
    -device virtio-gpu-pci \
    -device virtio-keyboard-pci \
    -device virtio-tablet-pci \
    -device virtio-serial-pci \
    -chardev socket,id=qga,path="$QGA",server=on,wait=off \
    -device virtserialport,chardev=qga,name=org.qemu.guest_agent.0 \
    -serial file:serial.log \
    -qmp unix:"$QMP",server,nowait \
    -monitor unix:"$MON",server,nowait \
    -pidfile "$PID" \
    "$@"
[ -z "$VNC" ] || set -- "$@" -vnc 127.0.0.1:"$VNC"

if [ "$HEADLESS" = 1 ]; then
    # The virtio GPU stays, so GNOME still has an output (and screendump works).
    qemu-system-aarch64 "$@" -display none -daemonize -D qemu.log
    echo "started, pid $(cat "$PID")"
else
    exec qemu-system-aarch64 "$@" -display cocoa
fi

#!/bin/sh
# The shell in a real window of the VM's desktop, for use through the QEMU window (start the VM
# with vm/qemu-aarch64/run.sh, no --headless). Still serves the tuning page on :8765.
#   scripts/live-window.sh              (same SHELL_PACK / SHELL_CAR / LIVE_THEME as live.sh)
set -eu
exec "$(dirname "$0")/vm.sh" "LIVE_THEME=${LIVE_THEME:-instrument} LIVI_SHELL_NO_DMABUF=${LIVI_SHELL_NO_DMABUF:-} scripts/live-window-run.sh"

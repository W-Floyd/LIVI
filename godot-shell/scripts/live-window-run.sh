#!/bin/sh
# In the VM: the shell in a window of the logged-in desktop. From the host: scripts/live-window.sh.
set -eu
cd "$(dirname "$0")/.."
scripts/build-ext.sh --release
godot --headless --path project --import >/dev/null 2>&1 || true
scripts/check-gd.sh
export XDG_RUNTIME_DIR=/run/user/$(id -u)
display=$(cd "$XDG_RUNTIME_DIR" && ls -d wayland-[0-9]* 2>/dev/null | grep -v lock | head -1)
[ -n "$display" ] || { echo "no desktop session: is the VM running with a window?" >&2; exit 1; }
WAYLAND_DISPLAY=$display exec godot --path project --display-driver wayland --rendering-driver opengl3 \
    --audio-driver Dummy --disable-vsync -- --live --window

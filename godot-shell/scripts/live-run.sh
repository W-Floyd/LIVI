#!/bin/sh
# In the VM: the shell under a headless weston, serving a browser page on :8765 for tuning.
# From the host: scripts/live.sh.
set -eu
cd "$(dirname "$0")/.."
scripts/build-ext.sh --release
godot --headless --path project --import >/dev/null 2>&1 || true
scripts/check-gd.sh
runtime=$(mktemp -d)
trap 'kill $weston 2>/dev/null; rm -rf "$runtime"' EXIT INT TERM
XDG_RUNTIME_DIR=$runtime weston --backend=headless --renderer=gl --socket=wayland-live \
    --width=1920 --height=720 >"$runtime/weston.log" 2>&1 &
weston=$!
i=0
until [ -S "$runtime/wayland-live" ]; do
    i=$((i + 1))
    [ $i -lt 50 ] || { cat "$runtime/weston.log" >&2; exit 1; }
    sleep 0.1
done
XDG_RUNTIME_DIR=$runtime WAYLAND_DISPLAY=wayland-live \
    godot --path project --display-driver wayland --rendering-driver opengl3 \
    --audio-driver Dummy -- --live

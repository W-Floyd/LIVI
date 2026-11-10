#!/bin/sh
# Tune the shell from a browser: runs it live in the VM, whose port 8765 the VM's run.sh forwards
# to http://localhost:8765/ (on a VM started before that: echo "hostfwd_add tcp:127.0.0.1:8765-:8765"
# | nc -U vm/qemu-aarch64/monitor.sock). Sliders for the camera, the road, the data and the look; drag the
# picture to move the car, shift-drag to turn the camera; overlay a stock screenshot.
#   scripts/live.sh                       # built-in themes
#   SHELL_PACK=godot-shell/ref/kia/ev6/2024/pack SHELL_CAR=godot-shell/ref/models/car.mesh LIVE_THEME=kia-ev6 scripts/live.sh
# Ctrl-C stops it.
set -eu
echo "http://localhost:8765/ (once it says 'live:')" >&2
exec "$(dirname "$0")/vm.sh" "LIVE_THEME=${LIVE_THEME:-instrument} scripts/live-run.sh"

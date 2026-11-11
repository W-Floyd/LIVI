#!/bin/sh
# A screenshot of the head unit's panel, as the shell shows it (grim through cage's screencopy).
#   scripts/unit-shot.sh [out.png] [host]     default: unit-shots/<time>.png under $TMPDIR
# Needs grim on the unit (Alpine's armv7 apk, installed by hand: the unit has no network).
set -eu
host="${2:-${LIVI_UNIT:-user@mobis-g5w.local}}"
out="${1:-${TMPDIR:-/tmp}/unit-shots/$(date +%Y%m%d-%H%M%S).png}"
mkdir -p "$(dirname "$out")"
ssh "$host" 'XDG_RUNTIME_DIR=/run/livi-shell WAYLAND_DISPLAY=wayland-0 grim - ' > "$out"
echo "$out"

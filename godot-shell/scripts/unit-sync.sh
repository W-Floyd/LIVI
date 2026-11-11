#!/bin/sh
# Copies the shell project (and the armv7 extension, if built) to the head unit's working copy,
# so a change is on the panel after a restart of the shell. Nothing is installed: the unit runs
# the project from ~/shellproj with the packaged godot.
#
#   scripts/unit-sync.sh [-n] [host]        -n: show what would change
#
# Host defaults to $LIVI_UNIT or user@mobis-g5w.local. The extension comes from
# packaging/out/armv7/ (packaging/scripts/build-armv7.sh) and is copied only when it is newer.
set -eu
cd "$(dirname "$0")/.."

dry=
[ "${1:-}" != -n ] || { dry=-n; shift; }
host="${1:-${LIVI_UNIT:-user@mobis-g5w.local}}"
dest=shellproj

# No --delete: the unit copy holds the import (.godot, *.import) the packaged build made, and a
# headless import on the unit segfaults. test/ and live/ are for the VM.
rsync -rtv $dry --exclude .godot --exclude test --exclude live --exclude '*.uid' \
    --exclude 'bin/linux-arm32/*.so' project/ "$host:$dest/"

so=packaging/out/armv7/liblivi_godot_shell.so
if [ -f "$so" ]; then
    rsync -tv $dry --update "$so" "$host:$dest/bin/linux-arm32/liblivi_godot_shell.so"
else
    echo "no $so: extension not copied (packaging/scripts/build-armv7.sh)"
fi

cat <<EOF

On the unit, restart the shell (the seat must be free first):
  sudo pkill -x cage; sleep 2
  sudo -u user env XDG_RUNTIME_DIR=/run/livi-shell LIBSEAT_BACKEND=seatd LIVI_SHELL_SOCKET=livi-shell LIVI_SHELL_NAV=1 LIVI_SHELL_TIMING=1 \\
    cage -s -- /usr/bin/godot --path /home/user/$dest --display-driver wayland --rendering-method gl_compatibility \\
    --rendering-driver opengl3 --fullscreen --resolution 1920x720 --audio-driver PulseAudio 2>&1 | tee /tmp/shell.log
EOF

#!/bin/sh
# Copies the shell project (and the armv7 extension, if built) to the head unit's working copy,
# so a change is on the panel after a restart of the shell. Nothing is installed: the unit runs
# the project from ~/shellproj with the packaged godot.
#
#   scripts/unit-sync.sh [-n | -r] [host]   -n: show what would change
#                                           -r: then check it loads, and restart the GUI if it does
#
# Host defaults to $LIVI_UNIT or user@mobis-g5w.local. The extension comes from
# packaging/out/armv7/ (packaging/scripts/build-armv7.sh) and is copied only when it is newer.
set -eu
cd "$(dirname "$0")/.."

dry=
restart=
case "${1:-}" in -n) dry=-n; shift ;; -r) restart=1; shift ;; esac
host="${1:-${LIVI_UNIT:-user@mobis-g5w.local}}"
live=shellproj
# Synced and load-checked in a staging copy first, so a tree that doesn't parse never reaches
# the copy the shell starts from (a restart, by anyone, would leave the panel grey).
dest=shellproj-next
[ -n "$dry" ] || ssh "$host" "rsync -a --delete ~/$live/ ~/$dest/"

# No --delete: the unit copy holds the import (.godot, *.import) the packaged build made, and a
# headless import on the unit segfaults. test/ and live/ are for the VM.
rsync -rtv $dry --exclude .godot --exclude test --exclude live --exclude '*.uid' \
    --exclude 'bin/linux-arm32/*.so' project/ "$host:$dest/"

# New class_names need the class registry an import makes; generated here from the scripts.
cache=$(mktemp)
python3 scripts/class-cache.py project > "$cache"
rsync -tv $dry --checksum "$cache" "$host:$dest/.godot/global_script_class_cache.cfg"
rm -f "$cache"

so=packaging/out/armv7/liblivi_godot_shell.so
if [ -f "$so" ]; then
    rsync -tv $dry --update "$so" "$host:$dest/bin/linux-arm32/liblivi_godot_shell.so"
else
    echo "no $so: extension not copied (packaging/scripts/build-armv7.sh)"
fi

[ -z "$dry" ] || exit 0
# A headless load first: a script that doesn't parse leaves the panel grey.
# Its own config dir: the running shell's look would be rewritten as this copy resolves it.
errors=$(ssh "$host" "mkdir -p /tmp/livi-check && chmod 700 /tmp/livi-check && cd /tmp && XDG_RUNTIME_DIR=/tmp/livi-check XDG_CONFIG_HOME=/tmp/livi-check timeout 60 /usr/bin/godot --headless --path ~/$dest --quit-after 60 2>&1 | grep -A1 -E 'SCRIPT ERROR|Parse Error|Failed to load'" || true)
if [ -n "$errors" ]; then
    echo "not installed, the project does not load (the unit's ~/$live is unchanged):"; echo "$errors"; exit 1
fi
ssh "$host" "rsync -a --delete ~/$dest/ ~/$live/"
[ -n "$restart" ] || { echo "restart: scripts/unit-sync.sh -r (or sudo systemctl restart livi-shell on the unit)"; exit 0; }
# sudo on the unit asks for the password: LIVI_UNIT_SUDO_PASS feeds it, else ssh -t prompts.
if [ -n "${LIVI_UNIT_SUDO_PASS:-}" ]; then
    printf '%s\n' "$LIVI_UNIT_SUDO_PASS" | ssh "$host" "sudo -S -p '' systemctl restart livi-shell"
else
    ssh -t "$host" "sudo systemctl restart livi-shell"
fi
echo "restarted livi-shell"

#!/bin/sh
# Copies a release build (scripts/export-release.sh's directory: the template as livi-shell, its
# pack, the extension, the fonts) to the head unit's ~/shellrel, through a staging copy that has
# to load first. /etc/livi-shell.conf's LIVI_SHELL_GODOT points the launcher at it
# (scripts/unit-deploy.sh release sets it).
#
#   scripts/unit-release.sh [-n] <dir> [host]     -n: show what would change
#
# Host defaults to $LIVI_UNIT or user@mobis-g5w.local.
set -eu
dry=
[ "${1:-}" != -n ] || { dry=-n; shift; }
[ $# -ge 1 ] || { sed -n 7p "$0" >&2; exit 2; }
src=$1
host="${2:-${LIVI_UNIT:-user@mobis-g5w.local}}"
[ -f "$src/livi-shell" ] && [ -f "$src/livi-shell.pck" ] && [ -f "$src/liblivi_godot_shell.so" ] ||
    { echo "$src: no livi-shell, livi-shell.pck or liblivi_godot_shell.so" >&2; exit 1; }
live=shellrel
dest=shellrel-next
[ -n "$dry" ] || ssh "$host" "mkdir -p ~/$live && rsync -a --delete ~/$live/ ~/$dest/"
rsync -rtv $dry --delete --checksum "$src/" "$host:$dest/"
[ -z "$dry" ] || exit 0
# A headless start first: a pack that does not load leaves the panel grey.
# Its own config dir: the running shell's look would be rewritten as this copy resolves it.
errors=$(ssh "$host" "mkdir -p /tmp/livi-check && chmod 700 /tmp/livi-check && cd /tmp && XDG_RUNTIME_DIR=/tmp/livi-check XDG_CONFIG_HOME=/tmp/livi-check timeout 60 ~/$dest/livi-shell --headless --quit-after 60 2>&1 | grep -A1 -E 'SCRIPT ERROR|Parse Error|Failed to load|Can.t open|Couldn.t load'" || true)
if [ -n "$errors" ]; then
    echo "not installed, the pack does not load (the unit's ~/$live is unchanged):"; echo "$errors"; exit 1
fi
ssh "$host" "rsync -a --delete ~/$dest/ ~/$live/"

#!/bin/sh
# Reclaim what LIVI builds leave behind; all of it is rebuilt on demand.
#   scripts/clean.sh
#
# - The VM, when it answers: vm.sh's pruning, with the shared target's debug/ whatever its size
#   and the copies' own ext/target from before it was shared.
# - Here, unless cargo is running: every worktree's native/ and ext/ debug/ targets (cargo test and
#   check's; release and armv7 stay), and unit-deploy's own targets from before it shared these.
# - Extension builds (~/.cache/livi-ext) unused for 3 days.
# - Docker's build cache older than 72 h. Never images or volumes (livi-pmb holds pmbootstrap's
#   work dir).
set -eu
cd "$(dirname "$0")/../.."
gone() { # paths...: removed, each with its size
    for p in "$@"; do
        [ -e "$p" ] || [ -L "$p" ] || continue
        echo "$(du -sh "$p" 2>/dev/null | cut -f1)	$p"
        rm -rf "$p"
    done
}

if ssh -p 2222 -o BatchMode=yes -o ConnectTimeout=3 user@localhost true 2>/dev/null; then
    echo "VM:"
    ssh -p 2222 -o BatchMode=yes user@localhost sh -s '""' "${VM_PRUNE_DAYS:-3}" 0 old \
        <godot-shell/scripts/vm-prune.sh
fi

if pgrep -x cargo >/dev/null; then
    echo "cargo is running: cargo targets left alone"
else
    git worktree list --porcelain | sed -n 's/^worktree //p' | while read -r w; do
        gone "$w/native/target/debug" "$w/godot-shell/ext/target/debug"
    done
    d=${LIVI_DEPLOY_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/livi-unit-deploy}/src
    for t in "$d/native/target" "$d/godot-shell/ext/target"; do
        [ -L "$t" ] || gone "$t"
    done
fi
find "${XDG_CACHE_HOME:-$HOME/.cache}/livi-ext" -mindepth 1 -maxdepth 1 -mtime +2 2>/dev/null |
    while read -r p; do gone "$p"; done

if docker info >/dev/null 2>&1; then
    docker builder prune -f --filter until=72h
fi

#!/bin/sh
# Runs in the VM, fed by vm.sh and clean.sh over ssh: sh -s DEST DAYS MAX_GB [old] < vm-prune.sh
# Stamps DEST (a copy in the home dir, "" for none) as used, then removes: copies unused for DAYS
# (never livi, DEST or one running), extension builds unused for DAYS, and, while no cargo runs,
# the shared target's debug/ (cargo test's; the scenarios run release) once the target passes
# MAX_GB, and with "old" the copies' own ext/target (an older vm.sh's, which may still build there).
set -eu
cd
[ -z "$1" ] || { mkdir -p "$1" && touch "$1/.vm-used"; }
min=$(($2 * 1440))
for s in */godot-shell/scripts/vm.sh; do
    d=${s%%/*}
    [ -e "$s" ] && [ "$d" != livi ] && [ "$d" != "$1" ] || continue
    # Copies from before the stamp: their last run's out/.
    ref=$d/.vm-used; [ -e "$ref" ] || ref=$d/godot-shell/out; [ -e "$ref" ] || ref=$d
    [ -n "$(find "$ref" -maxdepth 0 -mmin +$min)" ] || continue
    ! pgrep -f "cd $d/godot-shell " >/dev/null || continue
    echo "vm: removing ~/$d ($(du -sh "$d" | cut -f1)), unused for $2 days" >&2
    rm -rf "$d"
done
find .cache/livi-ext -mindepth 1 -maxdepth 1 -mmin +$min -exec rm -rf {} + 2>/dev/null || :
! pgrep -x cargo >/dev/null || exit 0
for t in */godot-shell/ext/target; do
    [ "${4:-}" = old ] && [ -d "$t" ] || continue
    echo "vm: removing ~/$t ($(du -sh "$t" | cut -f1)), now ~/.cache/livi-target" >&2
    rm -rf "$t"
done
t=.cache/livi-target
if [ -d $t/debug ] && [ "$(du -sk $t | cut -f1)" -gt $(($3 * 1048576)) ]; then
    echo "vm: removing ~/$t/debug ($(du -sh $t/debug | cut -f1)), the target over $3 GB" >&2
    rm -rf $t/debug
fi

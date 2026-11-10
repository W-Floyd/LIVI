#!/bin/sh
# Sync this tree into the VM and run a command there, from godot-shell/.
#   scripts/vm.sh scripts/test.sh [args]
# Results come back to ./out.
#   SHELL_PACK=godot-shell/ref/kia/ev6/2024/pack scripts/vm.sh scripts/test.sh kia-ev6
# also copies a local vendor pack (never in git) into the VM's packs directory, as
# SHELL_PACK_NAME (default kia-ev6), for the scenarios that need it. Relative to here or the repo root.
set -eu
pack=
if [ -n "${SHELL_PACK:-}" ]; then
    pack=$(cd "$SHELL_PACK" 2>/dev/null && pwd || (cd "$(dirname "$0")/../.." && cd "$SHELL_PACK" && pwd))
fi
cd "$(dirname "$0")/../.."
DEST=${VM_DEST:-livi}
ssh_cmd="ssh -p 2222 -o BatchMode=yes"
rsync -a --delete -e "$ssh_cmd" \
    --exclude target/ --exclude .godot/ --exclude 'project/bin/' --exclude out/ --exclude vm/ --exclude ref/ \
    godot-shell native user@localhost:"$DEST"/ >/dev/null
if [ -n "$pack" ]; then
    packs=.local/share/livi-shell/themes/${SHELL_PACK_NAME:-kia-ev6}
    $ssh_cmd user@localhost "mkdir -p $packs"
    rsync -a --delete -e "$ssh_cmd" "$pack"/ user@localhost:"$packs"/ >/dev/null
fi
if [ -n "${SHELL_CAR:-}" ]; then
    $ssh_cmd user@localhost "mkdir -p .local/share/livi-shell"
    rsync -a -e "$ssh_cmd" "$SHELL_CAR" user@localhost:.local/share/livi-shell/car.mesh >/dev/null
fi
rc=0
$ssh_cmd user@localhost "cd $DEST/godot-shell && $*" || rc=$?
# --delete: the VM's copies started as ours, so anything missing there was removed on purpose.
rsync -a --delete -e "$ssh_cmd" user@localhost:"$DEST"/godot-shell/out/ godot-shell/out/ 2>/dev/null || true
rsync -a --delete -e "$ssh_cmd" user@localhost:"$DEST"/godot-shell/tests/goldens/ godot-shell/tests/goldens/
exit $rc

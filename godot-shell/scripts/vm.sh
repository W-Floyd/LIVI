#!/bin/sh
# Sync this tree into the VM and run a command there, from godot-shell/.
#   scripts/vm.sh scripts/test.sh [args]
# Results come back to ./out.
set -eu
cd "$(dirname "$0")/../.."
DEST=${VM_DEST:-livi}
ssh_cmd="ssh -p 2222 -o BatchMode=yes"
rsync -a --delete -e "$ssh_cmd" \
    --exclude target/ --exclude .godot/ --exclude 'project/bin/' --exclude out/ --exclude vm/ \
    godot-shell native user@localhost:"$DEST"/ >/dev/null
rc=0
$ssh_cmd user@localhost "cd $DEST/godot-shell && $*" || rc=$?
# --delete: the VM's copies started as ours, so anything missing there was removed on purpose.
rsync -a --delete -e "$ssh_cmd" user@localhost:"$DEST"/godot-shell/out/ godot-shell/out/ 2>/dev/null || true
rsync -a --delete -e "$ssh_cmd" user@localhost:"$DEST"/godot-shell/tests/goldens/ godot-shell/tests/goldens/
exit $rc

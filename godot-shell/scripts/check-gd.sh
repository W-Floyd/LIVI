#!/bin/sh
# Compiles every GDScript in the project and prints each error as `res://file:line: message`.
# Exits 1 if there are any. Faster and clearer than a run: a script that fails to load in a run
# reports only that it could not be loaded.
#
# --check-only does not load autoloads, so errors naming them, and the knock-on errors in
# scripts that load a broken one, are dropped.
set -eu
cd "$(dirname "$0")/../project"
autoloads=$(sed -n '/^\[autoload\]/,/^\[/s/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' project.godot |
    paste -sd'|' -)
errors=$(find . -name '*.gd' -not -path './.godot/*' | sed 's|^\./||' | sort | while read -r f; do
    godot --headless --check-only --script "res://$f" 2>&1 || true
done | awk -v auto="^Identifier not found: (${autoloads:-^$})$" '
    /SCRIPT ERROR: / { sub(/.*SCRIPT ERROR: (Parse|Compile) Error: /, ""); msg = $0; next }
    msg != "" && /at: / {
        if (msg !~ auto && msg !~ /^(Could not preload|Could not resolve|Cannot infer|Failed to compile depended)/) {
            at = $0; sub(/.*\(/, "", at); sub(/\)$/, "", at); print at ": " msg
        }
        msg = ""
    }' | sort -u)
[ -z "$errors" ] && exit 0
echo "$errors" >&2
exit 1

#!/bin/sh
# Import the Godot project (its .godot/ cache: imported resources, the extension list) with
# Alpine's aarch64 editor in a container, which runs at native speed on Apple silicon; the
# armv7 template that runs it on the unit has no editor, so the unit's project ships imported.
# The cache is architecture-independent.
#   packaging/scripts/import-project.sh   -> packaging/out/project/ (project + .godot/)
# Needs docker. Where there is a Linux host with Godot 4.7, `godot --headless --path project
# --import` does the same.
set -eu
gs=$(cd "$(dirname "$0")/../.." && pwd)
out=$gs/packaging/out/project
rm -rf "$out" && mkdir -p "$out"
docker run --rm --platform linux/arm64 -v "$gs/project:/src:ro" -v "$out:/out" alpine:edge sh -euc '
    apk add -q --no-cache -X https://dl-cdn.alpinelinux.org/alpine/edge/testing godot
    # no bin/: the extension is the unit'"'"'s, and a missing one only warns here
    tar -C /src --exclude=./bin --exclude=./.godot -cf - . | tar -C /out -xf -
    godot --headless --path /out --import 2>&1 | tail -20 || true
    test -d /out/.godot/imported
    rm -rf /out/.godot/shader_cache /out/.godot/editor
'
du -sh "$out" "$out/.godot"

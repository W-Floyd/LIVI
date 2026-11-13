#!/bin/sh
# Exports the project as a pack for a release export template, with the extension beside it.
#   scripts/export-release.sh [--arch arm64|arm32] [--scripts text|tokens|compressed] <dir>
# -> <dir>/livi-shell.pck, <dir>/fonts/ and, when built, <dir>/liblivi_godot_shell.so; with
# TEMPLATE (e.g. Alpine godot-templates' /usr/bin/godot-template-release, of the same arch) also
# <dir>/livi-shell, a copy of it. Alpine's templates take no --main-pack: they load <exe>.pck from
# beside the executable, as resolved through symlinks, so the template is copied, not linked. The
# extension is found beside the executable too (the pack keeps res://bin/... paths that miss).
# The pack is the same for either arch. Needs the godot editor of the template's version on PATH.
# docs/startup.md has the numbers; scripts/unit-deploy.sh release ships it to the unit.
set -eu
cd "$(dirname "$0")/.."
arch=arm64
scripts=compressed
while [ $# -gt 1 ]; do
    case $1 in
    --arch) arch=$2; shift 2 ;;
    --scripts) scripts=$2; shift 2 ;;
    *) break ;;
    esac
done
[ $# -eq 1 ] || { sed -n 2,3p "$0" >&2; exit 2; }
case $scripts in text) mode=0 ;; tokens) mode=1 ;; compressed) mode=2 ;; *) exit 2 ;; esac
case $arch in
arm64) so=project/bin/linux-arm64/liblivi_godot_shell.so ;;
arm32) so=packaging/out/armv7/liblivi_godot_shell.so ;;
*) exit 2 ;;
esac
[ -f "$so" ] || echo "no $so (scripts/build-ext.sh, packaging/scripts/build-armv7.sh): pack only" >&2
mkdir -p "$1"
out=$(cd "$1" && pwd)

# Generated per run (gitignored). Non-resource files the shell reads with FileAccess are
# included by the filter; test/ and live/ stay in, though they read ../tests, which is not packed.
cat >project/export_presets.cfg <<EOF
[preset.0]

name="linux"
platform="Linux"
runnable=true
dedicated_server=false
custom_features=""
export_filter="all_resources"
include_filter="*.yaml, *.html, *.txt"
exclude_filter=""
export_path=""
script_export_mode=$mode

[preset.0.options]

binary_format/embed_pck=false
binary_format/architecture="$arch"
EOF
godot --headless --path project --import >/dev/null 2>&1 || true
log=$(mktemp)
godot --headless --path project --export-pack linux "$out/livi-shell.pck" >"$log" 2>&1 ||
    { tail -20 "$log" >&2; rm -f "$log"; exit 1; }
rm -f "$log"
[ ! -f "$so" ] || cp "$so" "$out/"
# Hosted apps get the shell's fonts by path (theme_manager.gd write_tokens): res:// is this
# directory in a template.
mkdir -p "$out/fonts"
cp project/fonts/*.ttf "$out/fonts/"
[ -z "${TEMPLATE:-}" ] || cp "$TEMPLATE" "$out/livi-shell"
ls -l "$out"

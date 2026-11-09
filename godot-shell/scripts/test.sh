#!/bin/sh
# Every test: cargo's, then the scenarios, rendered under a headless weston so no display is
# needed. Arguments go to the runner: a scenario name or path, --update-goldens, --shots-only.
set -eu
cd "$(dirname "$0")/.."
(cd ext && cargo test --quiet)
# Release: the measure steps time the extension, and a debug build's numbers mean little.
scripts/build-ext.sh --release
# Godot imports the project once, so the extension and resources are registered.
[ -d project/.godot ] || godot --headless --path project --import >/dev/null 2>&1 || true
scripts/check-gd.sh
rm -rf out

runtime=$(mktemp -d)
trap 'kill $weston 2>/dev/null; rm -rf "$runtime"' EXIT
XDG_RUNTIME_DIR=$runtime weston --backend=headless --renderer=gl --socket=wayland-test \
    --width=1920 --height=720 >"$runtime/weston.log" 2>&1 &
weston=$!
i=0
until [ -S "$runtime/wayland-test" ]; do
    i=$((i + 1))
    [ $i -lt 50 ] || { cat "$runtime/weston.log" >&2; exit 1; }
    sleep 0.1
done
# A script file that fails to load leaves Godot idling instead of exiting, so the first such
# error kills it; the timeout is for hangs. Only files: a scenario's gdscript step that does not
# compile fails that scenario instead.
status=$runtime/status
{
    XDG_RUNTIME_DIR=$runtime WAYLAND_DISPLAY=wayland-test timeout "${TEST_TIMEOUT:-60}" \
        sh -c 'echo $$ >"$1"; shift; exec "$@"' sh "$runtime/pid" \
        godot --path project --display-driver wayland --rendering-driver opengl3 \
        --audio-driver Dummy --fixed-fps 60 --disable-vsync -- --test "$@" &&
        echo 0 >"$status" || echo $? >"$status"
} 2>&1 | awk -v pidf="$runtime/pid" '{ print; fflush() }
    /Failed to load script/ && !k {
        getline p < pidf; system("kill " p); k = 1 }'
exit "$(cat "$status")"

#!/bin/sh
# Every test: cargo's, then the scenarios, rendered under a headless weston so no display is
# needed. Arguments go to the runner: a scenario name or path (which also skips cargo test),
# --update-goldens, --shots-only, --record.
set -eu
cd "$(dirname "$0")/.."
# Naming a scenario is iterating on it: skip cargo's tests (a full run keeps them).
named=
for a in "$@"; do case $a in --*) ;; *) named=1 ;; esac; done
[ -n "$named" ] || (cd ext && cargo test --quiet)
# Release: the measure steps time the extension, and a debug build's numbers mean little.
scripts/build-ext.sh --release
# Every run: the import registers the extension, resources and global class names (a new
# class_name is unknown until then), and is quick when nothing changed.
godot --headless --path project --import >/dev/null 2>&1 || true
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
    XDG_RUNTIME_DIR=$runtime WAYLAND_DISPLAY=wayland-test timeout "${TEST_TIMEOUT:-240}" \
        sh -c 'echo $$ >"$1"; shift; exec "$@"' sh "$runtime/pid" \
        godot --path project --display-driver wayland --rendering-driver opengl3 \
        --audio-driver Dummy --fixed-fps 60 --disable-vsync -- --test "$@" &&
        echo 0 >"$status" || echo $? >"$status"
} 2>&1 | awk -v pidf="$runtime/pid" '{ print; fflush() }
    /Failed to load script/ && !k {
        getline p < pidf; system("kill " p); k = 1 }'

# --record leaves JPEG frames per recording; they become one MP4 each, at the run's 60 fps.
for frames in out/*/*.frames; do
    [ -d "$frames" ] || continue
    if command -v ffmpeg >/dev/null; then
        ffmpeg -loglevel error -y -framerate 60 -i "$frames/%05d.jpg" -c:v libx264 -preset veryfast \
            -crf 23 -pix_fmt yuv420p -movflags +faststart "${frames%.frames}.mp4" && rm -rf "$frames"
    else
        echo "no ffmpeg: $frames left as JPEG frames" >&2
    fi
done
exit "$(cat "$status")"

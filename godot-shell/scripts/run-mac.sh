#!/bin/sh
# macOS: the shell in a window on this host, on a real livi-core, with phone projection drawn by
# the stub compositor's native video view (ext/src/wayland_stub.rs). Hosted apps never show.
# Needs GStreamer.framework (runtime and devel) in /Library/Frameworks.
#   scripts/run-mac.sh            (a core already running is used as it is)
set -eu
cd "$(dirname "$0")/.."
root=$(cd .. && pwd)
[ "$(uname -s)" = Darwin ] || { echo "macOS only; elsewhere see live-window.sh" >&2; exit 1; }

# livi-core finds livi-output and livi-helperd in out/bin, and GStreamer in assets/, as a repo
# checkout's xtask build-native leaves them.
sh "$root/scripts/assets.sh" fetch gstreamer macos-arm64
(cd "$root/native" && cargo build --release -p livi-core -p livi-output -p livi-helperd)
target=$(cd "$root/native" && cargo metadata --format-version 1 --no-deps | sed 's/.*"target_directory":"\([^"]*\)".*/\1/')
mkdir -p "$root/out/bin"
for b in livi-core livi-output livi-helperd; do cp "$target/release/$b" "$root/out/bin/"; done

scripts/build-ext.sh --release
godot --headless --path project --import >/dev/null 2>&1 || true
scripts/check-gd.sh

# livi-core-client's runtime dir, where the shell serves the planes (std::env::temp_dir()).
tmp=${TMPDIR:-/tmp}
runtime=${tmp%/}/livi-$(id -u)
core=
if ! nc -zU "$runtime/core.sock" 2>/dev/null; then
    mkdir -p "$runtime/log"
    LIVI_NO_UI=1 LIVI_UI_PLANES=$runtime/ui-planes.sock "$root/out/bin/livi-core" >"$runtime/log/core-shell.log" 2>&1 &
    core=$!
    echo "core: started ($runtime/log/core-shell.log)"
fi
trap '[ -z "$core" ] || kill $core 2>/dev/null' EXIT INT TERM
godot --path project --rendering-driver opengl3

#!/bin/sh
# Build the extension for this machine and put it where the project loads it from.
#   scripts/build-ext.sh [--release]
set -eu
cd "$(dirname "$0")/../ext"
profile=debug
[ "${1:-}" != --release ] || profile=release
cargo build ${1:+"$1"}
case $(uname -s)-$(uname -m) in
Linux-aarch64) dir=linux-arm64 lib=liblivi_godot_shell.so ;;
Linux-armv7l) dir=linux-arm32 lib=liblivi_godot_shell.so ;;
Linux-x86_64) dir=linux-x86_64 lib=liblivi_godot_shell.so ;;
Darwin-*) dir=macos lib=liblivi_godot_shell.dylib ;;
*) echo "unsupported host" >&2; exit 1 ;;
esac
mkdir -p "../project/bin/$dir"
cp "target/$profile/$lib" "../project/bin/$dir/"

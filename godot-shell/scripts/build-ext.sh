#!/bin/sh
# Build the extension for this machine and put it where the project loads it from.
#   scripts/build-ext.sh [--release]
#
# A build is kept per source hash (~/.cache/livi-ext): a copy of the tree at another path with the
# same sources takes it instead of building again (cargo rebuilds a path crate per checkout path).
set -eu
cd "$(dirname "$0")/../ext"
profile=debug
[ "${1:-}" != --release ] || profile=release
case $(uname -s)-$(uname -m) in
Linux-aarch64) dir=linux-arm64 lib=liblivi_godot_shell.so ;;
Linux-armv7l) dir=linux-arm32 lib=liblivi_godot_shell.so ;;
Linux-x86_64) dir=linux-x86_64 lib=liblivi_godot_shell.so ;;
Darwin-*) dir=macos lib=liblivi_godot_shell.dylib ;;
*) echo "unsupported host" >&2; exit 1 ;;
esac
client=livi-shell-test-client

# The path dependencies live in ../../native; all of its crates count, being cheap to hash.
hash=$(find Cargo.toml Cargo.lock build.rs src ../../native/Cargo.lock ../../native/crates \
    -type f \( -name '*.rs' -o -name 'Cargo.*' -o -name '*.proto' -o -name '*.toml' \) 2>/dev/null |
    LC_ALL=C sort | xargs cat | { sha256sum 2>/dev/null || shasum -a 256; } | cut -c1-16)
cache=${XDG_CACHE_HOME:-$HOME/.cache}/livi-ext/$profile-$hash
if [ -f "$cache/$lib" ] && [ -f "$cache/$client" ]; then
    echo "extension: built from these sources before ($cache)"
else
    cargo build ${1:+"$1"}
    mkdir -p "$cache.tmp.$$"
    cp "target/$profile/$lib" "target/$profile/$client" "$cache.tmp.$$/"
    rm -rf "$cache" && mv "$cache.tmp.$$" "$cache"
fi
mkdir -p "../project/bin/$dir"
# The test client beside it: target/ may be shared between copies, each building its own.
cp "$cache/$lib" "$cache/$client" "../project/bin/$dir/"

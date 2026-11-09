#!/bin/sh
# Cross-build the extension for the unit (armv7, Alpine's musl) on macOS or Linux, with no
# pmbootstrap: the extension has no C dependencies, so the sysroot is just musl and libgcc
# from Alpine edge, linked with clang and lld.
#   scripts/build-armv7.sh [--release]   -> project/bin/linux-arm32/
set -eu
cd "$(dirname "$0")/../ext"
T=armv7-unknown-linux-musleabihf
X=armv7-alpine-linux-musleabihf
MIRROR=${ALPINE_MIRROR:-https://dl-cdn.alpinelinux.org/alpine/edge/main/armv7}
SYS=$PWD/target/sysroot-armv7

if [ ! -e "$SYS/.done" ]; then
    rm -rf "$SYS" && mkdir -p "$SYS"
    curl -fsSL "$MIRROR/APKINDEX.tar.gz" | tar -xzOf - APKINDEX > "$SYS/APKINDEX"
    for p in musl musl-dev libgcc; do
        v=$(awk -v p="$p" '$0 == "P:" p { f = 1 } f && /^V:/ { print substr($0, 3); exit }' "$SYS/APKINDEX")
        curl -fsSL "$MIRROR/$p-$v.apk" | tar -xzf - -C "$SYS" 2>/dev/null
    done
    # libgcc ships only the soname; the link-time name comes with gcc, which is not needed.
    ln -sf libgcc_s.so.1 "$SYS/usr/lib/libgcc_s.so"
    rm -f "$SYS"/.PKGINFO "$SYS"/.SIGN.* "$SYS/APKINDEX"
    touch "$SYS/.done"
fi

LLD=$(command -v ld.lld) || { echo "needs ld.lld (brew install lld, apk add lld)" >&2; exit 1; }
# A wrapper, as cargo takes the linker as one program. -nostartfiles: a shared object needs
# none of crt1/crti, and gcc's crtbeginS is not in the sysroot. -z defs: anything unresolved
# fails here, not when the unit loads it.
cat > target/armv7-cc <<EOS
#!/bin/sh
exec clang --target=$X --sysroot=$SYS -fuse-ld=$LLD -nostartfiles -Wl,-z,defs "\$@"
EOS
chmod +x target/armv7-cc

profile=debug
[ "${1:-}" != --release ] || profile=release
# rustup's cargo: a distro's (Alpine's) has no std for other targets.
PATH=$HOME/.cargo/bin:$PATH
command -v rustup >/dev/null || command -v rustup-init >/dev/null ||
    { echo "needs rustup" >&2; exit 1; }
command -v rustup >/dev/null ||
    rustup-init -y -q --no-modify-path --profile minimal --default-toolchain stable
rustup target add $T >/dev/null
CARGO_TARGET_ARMV7_UNKNOWN_LINUX_MUSLEABIHF_LINKER=$PWD/target/armv7-cc \
    RUSTFLAGS="-C target-feature=-crt-static" \
    cargo build --target $T ${1:+"$1"}
mkdir -p ../project/bin/linux-arm32
cp "target/$T/$profile/liblivi_godot_shell.so" ../project/bin/linux-arm32/

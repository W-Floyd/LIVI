#!/bin/sh
# Cross-build everything the shell runs on the unit, for armv7 musl hard-float (Alpine's armv7),
# on macOS or Linux, with no Docker and no pmbootstrap:
#   packaging/scripts/build-armv7.sh [--debug] [ext] [core]    -> packaging/out/armv7/
#
#   ext   liblivi_godot_shell.so (the GDExtension) and livi-shell-test-client
#   core  livi-core, livi-gst-host, livi-helperd (native/, the backend and what it spawns)
#
# The sysroot is Alpine edge's armv7 packages, unpacked (alpine-sysroot.py); the linker is
# clang + lld. Needs rustup, clang, ld.lld, pkg-config, cmake and perl (brew install lld
# llvm cmake pkgconf). The native workspace pins a beta toolchain (rust-toolchain.toml);
# rustup fetches it.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
gs=$(cd "$here/../.." && pwd)
out=$gs/packaging/out/armv7
work=${ARMV7_WORK:-$gs/packaging/out/work}
T=armv7-unknown-linux-musleabihf
X=armv7-alpine-linux-musleabihf
SYS=$work/sysroot

profile=release flag=--release
[ "${1:-}" != --debug ] || { profile=debug flag=; shift; }
what=${*:-ext core}

PATH=$HOME/.cargo/bin:/opt/homebrew/opt/llvm/bin:/usr/local/opt/llvm/bin:$PATH
command -v rustup >/dev/null || { echo "needs rustup" >&2; exit 1; }
LLD=$(command -v ld.lld) || { echo "needs ld.lld (brew install lld, apk add lld)" >&2; exit 1; }

# What native/ links: livi-core and its children (musl, libgcc, libstdc++ for the C++
# build scripts' output, GStreamer, udev, seat, drm, xkbcommon, openssl).
if [ ! -e "$SYS/.done" ]; then
    "$here/alpine-sysroot.py" "$SYS" musl-dev libgcc libstdc++ eudev-dev gstreamer-dev \
        gst-plugins-base-dev libxkbcommon-dev openssl-dev wayland-dev libdrm-dev \
        libinput-dev libseat-dev mesa-dev fontconfig-dev xz-dev linux-headers
    ln -sf libgcc_s.so.1 "$SYS/usr/lib/libgcc_s.so"
    touch "$SYS/.done"
fi

# -nostartfiles: gcc's crtbeginS is not in the sysroot; executables get musl's crt1/crti/crtn by
# hand, shared objects none. -z defs: an unresolved symbol fails here, not when the unit loads it.
mkdir -p "$work"
cat > "$work/armv7-cc" <<EOS
#!/bin/sh
case " \$* " in
*" -shared "*) pre= post= ;;
*) pre="$SYS/usr/lib/crt1.o $SYS/usr/lib/crti.o" post=$SYS/usr/lib/crtn.o ;;
esac
exec clang --target=$X --sysroot=$SYS -fuse-ld=$LLD -nostartfiles -Wl,-z,defs -Wl,-rpath-link,$SYS/usr/lib \
    -Wl,-rpath-link,$SYS/lib \$pre "\$@" \$post
EOS
chmod +x "$work/armv7-cc"
mkdir -p "$out"

for w in $what; do
    case $w in
    ext)
        "$gs/scripts/build-armv7.sh" ${flag:+"$flag"}
        for f in liblivi_godot_shell.so livi-shell-test-client; do
            cp "$gs/ext/target/$T/$profile/$f" "$out/"
        done
        ;;
    core)
        t=armv7_unknown_linux_musleabihf
        export CC_$t="clang --target=$X --sysroot=$SYS" AR_$t=llvm-ar
        export CFLAGS_$t="--sysroot=$SYS" BINDGEN_EXTRA_CLANG_ARGS_$t="--sysroot=$SYS --target=$X"
        export PKG_CONFIG_ALLOW_CROSS=1 PKG_CONFIG_SYSROOT_DIR_$t=$SYS
        export PKG_CONFIG_LIBDIR_$t=$SYS/usr/lib/pkgconfig:$SYS/usr/share/pkgconfig
        export CARGO_TARGET_ARMV7_UNKNOWN_LINUX_MUSLEABIHF_LINKER=$work/armv7-cc
        # The channel comes from rust-toolchain.toml; musl has no libdl, so crates that ask for it
        # get an empty one.
        (cd "$gs/../native" && rustup show active-toolchain >/dev/null 2>&1 || rustup toolchain install --profile minimal
         rustup target add $T
         sc=$(rustc --print sysroot)/lib/rustlib/$T/lib/self-contained
         [ ! -d "$sc" ] || [ -f "$sc/libdl.a" ] || llvm-ar rc "$sc/libdl.a"
         RUSTFLAGS="-C target-feature=-crt-static" LIVI_BUILD=g5w LIVI_BUILD_RUN=0 \
             LIVI_BUILD_DATE=$(date -u +%F) LIVI_BUILD_SHA=$(git rev-parse HEAD) LIVI_VERSION=$(sed -n 's/^version = "\(.*\)"/\1/p' Cargo.toml | head -1) \
             cargo build $flag --locked --target $T -p livi-core -p livi-gst-host -p livi-helperd)
        for f in livi-core livi-gst-host livi-helperd; do
            cp "$gs/../native/target/$T/$profile/$f" "$out/"
        done
        ;;
    *) echo "unknown: $w" >&2; exit 1 ;;
    esac
done
(cd "$out" && shasum -a256 * && ls -l)

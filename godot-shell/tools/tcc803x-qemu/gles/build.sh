#!/bin/sh
# Build a GLES 2/3 driver for the stock Android 4.4 (armv7) userland: SwiftShader's legacy OpenGL ES
# (Subzero JIT) at a pinned commit, patched for API 19 (swiftshader-android44.patch), plus libGLES_emu.so,
# which picks it per process (gles_emu.c), and gles2-test. Everything is fetched from upstream, pinned.
# Output: $OUT/egl/ for build-ramdisk.py --egl: libGLES_emu.so, lib{EGL,GLESv2}_swiftshader.so, gles2-test.
# Env: OUT   output dir (default ./out)
#      WORK  downloads and build tree, ~0.5 GB plus the NDK dmg (1.3 GB) (default $TMPDIR/tcc803x-gles)
#      NDK   an Android NDK r25c root to use instead of fetching the macOS one
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=$(mkdir -p "${OUT:-out}" && cd "${OUT:-out}" && pwd)
WORK=${WORK:-${TMPDIR:-/tmp}/tcc803x-gles}
mkdir -p "$WORK"
SS_COMMIT=606261c75c2a686ee5a9331e2141d3ed946986f4   # last commit with the GLES CMake targets (2021-12)
AOSP_TAG=android-4.4.2_r1
NDK_DMG_URL=https://dl.google.com/android/repository/android-ndk-r25c-darwin.dmg
NDK_DMG_SHA256=1856108efde22d502399216c65e2a0f7823bdfac1df69fe6a1f3b71ff7be6ced

if [ -z "${NDK:-}" ]; then
	[ "$(uname)" = Darwin ] || { echo "set NDK to an Android NDK r25c (only the macOS one is fetched)" >&2; exit 1; }
	dmg=$WORK/android-ndk-r25c-darwin.dmg
	if ! echo "$NDK_DMG_SHA256  $dmg" | shasum -a 256 -c - >/dev/null 2>&1; then
		curl -fL -o "$dmg" "$NDK_DMG_URL"
		echo "$NDK_DMG_SHA256  $dmg" | shasum -a 256 -c -
	fi
	mnt=$WORK/ndk
	[ -d "$mnt/AndroidNDK9519653.app" ] || hdiutil attach -readonly -nobrowse -mountpoint "$mnt" "$dmg" >/dev/null
	trap 'hdiutil detach -quiet "$mnt" || true' EXIT
	NDK=$mnt/AndroidNDK9519653.app/Contents/NDK
fi
BIN=$(echo "$NDK"/toolchains/llvm/prebuilt/*/bin)

# SwiftShader: one commit, blobs only for the paths built (not LLVM, SPIR-V, tests).
ss=$WORK/swiftshader
if [ "$(git -C "$ss" rev-parse HEAD 2>/dev/null)" != $SS_COMMIT ]; then
	rm -rf "$ss"
	git init -q "$ss"
	git -C "$ss" remote add origin https://github.com/google/swiftshader.git
	git -C "$ss" sparse-checkout set --no-cone '/*' '!/third_party/llvm-10.0/' '!/third_party/llvm-project/' \
		'!/third_party/SPIRV-Tools/' '!/third_party/SPIRV-Headers/' '!/third_party/googletest/' '!/third_party/benchmark/' \
		'!/third_party/PowerVR_Examples/' '!/tests/'
	git -C "$ss" fetch -q --depth 1 --filter=blob:none origin $SS_COMMIT
	git -C "$ss" checkout -q FETCH_HEAD
fi
git -C "$ss" checkout -q -- . && git -C "$ss" apply "$HERE/swiftshader-android44.patch"

# AOSP 4.4 headers for the native window and gralloc 0.x (not in the NDK).
inc=$WORK/aosp-include
if [ ! -f "$inc/.done" ]; then
	mkdir -p "$inc/system" "$inc/cutils" "$inc/hardware" "$inc/sync"
	for f in system/core:include/system/window.h system/core:include/system/graphics.h \
		system/core:include/cutils/native_handle.h hardware/libhardware:include/hardware/gralloc.h \
		hardware/libhardware:include/hardware/hardware.h hardware/libhardware:include/hardware/fb.h; do
		curl -fsS "https://android.googlesource.com/platform/${f%%:*}/+/refs/tags/$AOSP_TAG/${f#*:}?format=TEXT" |
			base64 -d >"$inc/${f#*:include/}"
	done
	echo '/* window.h includes it; nothing from libsync is used */' >"$inc/sync/sync.h"
	touch "$inc/.done"
fi

b=$WORK/build
cmake -S "$ss" -B "$b" -G Ninja -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
	-DANDROID_ABI=armeabi-v7a -DANDROID_PLATFORM=android-19 -DANDROID_STL=c++_static -DCMAKE_BUILD_TYPE=Release \
	-DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DREACTOR_BACKEND=Subzero -DSWIFTSHADER_BUILD_VULKAN=OFF \
	-DSWIFTSHADER_BUILD_TESTS=OFF -DSWIFTSHADER_BUILD_PVR=OFF -DSWIFTSHADER_WARNINGS_AS_ERRORS=OFF \
	-DSWIFTSHADER_LESS_DEBUG_INFO=ON -DCMAKE_C_FLAGS="-I$inc" -DCMAKE_CXX_FLAGS="-I$inc" \
	-DCMAKE_SHARED_LINKER_FLAGS="-landroid -llog" >/dev/null
ninja -C "$b" libEGL_deprecated libGLESv2_deprecated

mkdir -p "$OUT/egl"
for l in EGL GLESv2; do "$BIN/llvm-strip" -o "$OUT/egl/lib${l}_swiftshader.so" "$b/lib${l}_swiftshader.so"; done
cc="$BIN/clang --target=armv7a-linux-androideabi19 -O2 -Wall"
$cc -shared -fPIC -fvisibility=hidden -o "$OUT/egl/libGLES_emu.so" "$HERE/gles_emu.c" -llog
$cc -fPIE -pie -o "$OUT/egl/gles2-test" "$HERE/gles2-test.c" -lEGL -lGLESv2
"$BIN/llvm-strip" "$OUT/egl/libGLES_emu.so" "$OUT/egl/gles2-test"
ls -l "$OUT/egl"

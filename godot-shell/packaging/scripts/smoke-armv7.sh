#!/bin/sh
# Smoke test of the armv7 build under qemu-user, in an aarch64 Alpine container (Docker on Apple
# silicon cannot exec AArch32, so the container is arm64 and `qemu-arm` runs the armv7 ELFs).
#   packaging/scripts/smoke-armv7.sh      (after build-armv7.sh and import-project.sh)
# Installs Alpine's armv7 godot and the libraries the build links into a throwaway armv7 root,
# then checks: every NEEDED library resolves (musl `ld --list`); the test client starts;
# livi-core opens its socket; Godot's armv7 binary loads the armv7 extension and runs the shell
# headless (--path of the imported project) against that core, which sees "godot-shell connected";
# the test client connects to the shell's own Wayland socket and stays up. Emulated, so it shows loading and
# wiring, not speed or GL.
set -eu
gs=$(cd "$(dirname "$0")/../.." && pwd)
out=$gs/packaging/out
[ -f "$out/armv7/livi-core" ] && [ -d "$out/project/.godot" ] || { echo "run build-armv7.sh and import-project.sh first" >&2; exit 1; }
docker run --rm --platform linux/arm64 -v "$out/armv7:/bin-armv7:ro" -v "$out/project:/project-src:ro" \
    alpine:edge sh -euc '
M=https://dl-cdn.alpinelinux.org/alpine/edge
# qemu-user redirects only the loader (-L): data files are opened in this root, hence the native copy
apk add -q --no-cache qemu-arm xkeyboard-config
mkdir -p /a/etc/apk && echo armv7 > /a/etc/apk/arch
apk --root /a --arch armv7 --initdb --no-scripts --no-cache --allow-untrusted -q \
    -X $M/main -X $M/community -X $M/testing \
    add musl libgcc libstdc++ libxkbcommon libssl3 libcrypto3 glib gstreamer gst-plugins-base \
        eudev-libs mesa-gles mesa-egl xkeyboard-config godot
mkdir -p /a/opt/livi /a/run/r /a/tmp
cp /bin-armv7/* /a/opt/livi/
cp -r /project-src /a/opt/project
mkdir -p /a/opt/project/bin/linux-arm32 && cp /bin-armv7/liblivi_godot_shell.so /a/opt/project/bin/linux-arm32/
Q="qemu-arm -L /a"
LD="$Q /a/lib/ld-musl-armhf.so.1"
echo "== NEEDED resolution"
for f in livi-core livi-output livi-helperd livi-shell-test-client liblivi_godot_shell.so; do
    echo "$f: $($LD --list /a/opt/livi/$f 2>&1 | grep -c "not found" || true) unresolved"
done
echo "godot: $($LD --list /a/usr/bin/godot 2>&1 | grep -c "not found" || true) unresolved"
echo "== livi-core"
R=/a/opt/livi/resources; mkdir -p $R/core $R/output $R/driver
mv /a/opt/livi/livi-core $R/core/; mv /a/opt/livi/livi-output $R/output/; mv /a/opt/livi/livi-helperd $R/driver/
export XDG_RUNTIME_DIR=/a/run/r HOME=/a/tmp/home
mkdir -p $HOME
(LIVI_RESOURCES=$R LIVI_NO_UI=1 WAYLAND_DISPLAY=livi-shell $Q $R/core/livi-core > /a/tmp/core.log 2>&1 &)
i=0; until [ -S $XDG_RUNTIME_DIR/livi/core.sock ] || [ $i -gt 120 ]; do i=$((i+1)); sleep 0.5; done
ls $XDG_RUNTIME_DIR/livi
echo "== godot shell (headless, armv7 godot, arm32 extension)"
(LIVI_SHELL_SOCKET=livi-shell $Q /a/usr/bin/godot --headless --path /a/opt/project --quit-after 3000 > /a/tmp/godot.log 2>&1 &)
i=0; until [ -S $XDG_RUNTIME_DIR/livi-shell ] || [ $i -gt 120 ]; do i=$((i+1)); sleep 0.5; done
ls $XDG_RUNTIME_DIR
[ -S $XDG_RUNTIME_DIR/livi-shell ] || { echo "no shell socket; godot log:"; grep -v Fontconfig /a/tmp/godot.log | tail -20; echo "SMOKE FAILED"; exit 1; }
echo "== test client against the shell socket (a client that stays up 10 s is connected)"
rc=0; WAYLAND_DISPLAY=livi-shell timeout 10 $Q /a/opt/livi/livi-shell-test-client --size 640x360 >/a/tmp/client.log 2>&1 || rc=$?
case $rc in 124|143) echo "client stayed connected for 10 s" ;; *) echo "client exited rc $rc"; cat /a/tmp/client.log; echo "SMOKE FAILED"; exit 1 ;; esac
sleep 15
echo "== godot log"; grep -vE "^Fontconfig|^$" /a/tmp/godot.log | grep -E "godot-rust|ERROR|WARNING" | grep -v U_FILE_ACCESS_ERROR | head
echo "== core log"; tail -6 /a/tmp/core.log
grep -q "godot-shell connected" /a/tmp/core.log && echo "SMOKE OK" || { echo "SMOKE FAILED: the shell never connected to the core"; exit 1; }
'

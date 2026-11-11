#!/bin/sh
# Run the APKBUILDs' package(), subpackages and metadata through abuild in an Alpine container,
# on the binaries build-armv7.sh cross-built, and list what the armv7 apks hold. A packaging
# check, not the release build: build() is replaced by "use the prebuilt binaries" and
# dependencies are not resolved (abuild -d); the from-source build is pmbootstrap's
# (make-source.sh, README). Needs docker; the container is arm64 (abuild only packs, so the
# apks are labelled armv7 with CARCH).
#   packaging/scripts/apk-armv7.sh [pkg...]   -> packaging/out/apk/armv7/
set -eu
gs=$(cd "$(dirname "$0")/../.." && pwd)
out=$gs/packaging/out
[ -f "$out/armv7/livi-core" ] && [ -d "$out/project/.godot" ] || { echo "run build-armv7.sh and import-project.sh first" >&2; exit 1; }
"$gs/packaging/scripts/make-source.sh" ${*:-livi-core livi-shell} >/dev/null
mkdir -p "$out/apk"
docker run --rm --platform linux/arm64 -e PKGS="${*:-livi-core livi-shell}" \
    -v "$gs/..:/repo:ro" -v "$out:/out" alpine:edge sh -euc '
apk add -q --no-cache alpine-sdk
adduser -D -G abuild b && echo "b ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers
su -l b -c "abuild-keygen -a -n" >/dev/null 2>&1; cp /home/b/.config/abuild/*.pub /etc/apk/keys/
for p in $PKGS; do
    w=/home/b/$p; mkdir -p $w
    for f in /out/aports/$p/*; do case $f in *.tar.gz) ;; *) cp $f $w/ ;; esac; done
    chown -R b $w
    cat >> $w/APKBUILD <<EOT

# packaging check only: no tarball, prebuilt binaries
source="\$(echo "\$source" | grep -v tar.gz || true)"
builddir=/repo/\$( [ $p = livi-core ] && echo native || echo godot-shell )
options="!check !strip !tracedeps !archcheck"
build() {
	export CARGO_TARGET_DIR=/home/b/target
	mkdir -p \$CARGO_TARGET_DIR/\$_target/release
	cp /out/armv7/* \$CARGO_TARGET_DIR/\$_target/release/
	[ $p = livi-core ] || cp -r /out/project \$srcdir/project
}
EOT
    su -l b -c "cd $w && CARCH=armv7 abuild checksum >/dev/null 2>&1; CARCH=armv7 abuild -d -F -P /home/b/pkgs" 2>&1 | tail -15
done
mkdir -p /out/apk/armv7
find /home/b/pkgs -name "*.apk" -exec cp {} /out/apk/armv7/ \;
cd /out/apk/armv7
for f in *.apk; do echo "== $f"; tar -xzf $f -O .PKGINFO 2>/dev/null | grep -E "^(pkgname|pkgver|arch|size|depend|install_if) " ; tar -tzf $f 2>/dev/null | grep -v "^\." | head -30; done
'
ls -l "$out/apk/armv7"

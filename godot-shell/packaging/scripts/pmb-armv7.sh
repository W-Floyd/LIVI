#!/bin/sh
# The from-source armv7 build of the APKBUILDs with pmbootstrap (tools/pmb): make-source.sh
# stages them, they go into the container's pmaports (device/testing/), and the apks come out.
#   packaging/scripts/pmb-armv7.sh [pkg...]   -> packaging/out/pmb/armv7/   (default: both)
# Needs Docker. PMAPORTS_URL/PMAPORTS_REF pick the pmaports tree (tools/pmb/env.sh); OUT replaces
# packaging/out. FAST=1, for iterating: --lax (the buildroots are kept, not reinstalled) and the
# APKBUILDs' _livi_fast (cargo's target dir and the source tree kept in the cache mount).
set -eu
gs=$(cd "$(dirname "$0")/../.." && pwd)
. "$gs/scripts/dotenv.sh"
. "$gs/tools/pmb/env.sh"
pkgs=${*:-livi-core livi-shell}
out=${OUT:-$gs/packaging/out}
export OUT="$out"
lax= fast=
[ -z "${FAST:-}" ] || lax=--lax fast=1
CFG=/home/pmos/.config/pmbootstrap-livi-armv7.cfg

"$gs/packaging/scripts/make-source.sh" $pkgs
printf '[pmbootstrap]\nservice_manager = systemd\n' | pmb_config "$CFG"
pmb_aports
(cd "$out/aports" && COPYFILE_DISABLE=1 tar -cf - $pkgs) |
    pmb_exec sh -euc 'cd "$1/device/testing"; f=$2; shift 2; rm -rf "$@"; tar -xf -
        for p; do sed -i "s/^_livi_fast=.*/_livi_fast=$f/" "$p/APKBUILD"; done' \
        sh "$PMB_APORTS" "$fast" $pkgs
# --force: the version is always 0-r0.
pmb_exec pmbootstrap --config "$CFG" -y build $lax --force --arch armv7 $pkgs
rm -rf "$out/pmb/armv7" && mkdir -p "$out/pmb/armv7"
pmb_exec sh -euc 't=$(mktemp -d); for p; do
        find .local/var/pmbootstrap/packages -path "*/armv7/$p-*.apk" -exec cp {} "$t" \;
    done; tar -C "$t" -cf - .; rm -rf "$t"' sh $pkgs | tar -xf - -C "$out/pmb/armv7"
ls -l "$out/pmb/armv7"

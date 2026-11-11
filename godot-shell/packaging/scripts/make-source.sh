#!/bin/sh
# Stage the APKBUILDs for pmbootstrap: the source is a
# `git archive` of this repository's HEAD (so unpushed commits build), pinned in the APKBUILD,
# with its checksums. The repository's APKBUILDs stay unpinned; the staged copies are for the
# build only.
#   packaging/scripts/make-source.sh [pkg...]   -> packaging/out/aports/<pkg>/   (default: both)
# OUT replaces packaging/out.
# Then copy packaging/out/aports/* to the pmaports tree's device/testing/ and
# `pmbootstrap checksum`/`build --arch armv7 livi-core livi-shell`.
set -eu
gs=$(cd "$(dirname "$0")/../.." && pwd)
repo=$(git -C "$gs" rev-parse --show-toplevel)
c=$(git -C "$gs" rev-parse HEAD)
[ -z "$(git -C "$repo" status --porcelain --untracked-files=no)" ] ||
    echo "warning: uncommitted changes are not in the archive" >&2
for p in ${*:-livi-core livi-shell}; do
    d=${OUT:-$gs/packaging/out}/aports/$p
    rm -rf "$d" && mkdir -p "$d"
    cp "$gs/packaging/alpine/$p"/* "$d"/
    git -C "$repo" archive --prefix="livi-$c/" HEAD | gzip -n > "$d/livi-$c.tar.gz"
    sed -i.bak "s/^_livi_commit=.*/_livi_commit=$c/" "$d/APKBUILD" && rm "$d/APKBUILD.bak"
    sed -i.bak '/^sha512sums=/,$d' "$d/APKBUILD" && rm "$d/APKBUILD.bak"
    {
        echo 'sha512sums="'
        # in source= order: abuild checks them by position
        srcs=$(awk '/^source="/ { f = 1 } f { print } f && /"$/ && !/^source="$/ { exit }' "$d/APKBUILD" |
            sed -e 's/^source=//' -e 's/"//g' -e "s/\$_livi_commit/$c/g")
        (cd "$d" && for f in $srcs; do shasum -a 512 "$f"; done)
        echo '"'
    } >> "$d/APKBUILD"
    echo "$d ($c)"
done

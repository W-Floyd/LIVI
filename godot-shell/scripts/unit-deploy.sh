#!/bin/sh
# Builds what the head unit runs from HEAD and installs what differs, with one sudo prompt.
#
#   scripts/unit-deploy.sh [-n | -b] [shell|release|core|micomd|all] [host]     (default: all)
#
#   -n  what would change, read-only: the unit's hashes and versions against HEAD, nothing built
#   -b  build and compare, install nothing
#
#   shell   the project and the extension (scripts/unit-sync.sh), then restart livi-shell
#   release the shell as a release template and pack instead (scripts/export-release.sh, exported
#           in the VM; scripts/unit-release.sh), /etc/livi-shell.conf's LIVI_SHELL_GODOT set to it
#           (shell clears it again); shell and release also install the launcher and its unit
#   core    livi-core, livi-output, livi-helperd (packaging/scripts/build-armv7.sh), the ones
#           whose sha256 differs from the unit's
#   micomd  micomd + micom-livi when the unit's micomd is not the APKBUILD's go-micomd version,
#           device-mobis-g5w(-systemd) when a file of it differs from the unit's; built with
#           tools/pmb from PMAPORTS_DIR's HEAD
#   all     micomd, core, shell
#
# shell and core build from a clean worktree of this checkout's HEAD (LIVI_DEPLOY_CACHE, default
# ~/.cache/livi-unit-deploy), so uncommitted changes never ship; its cargo targets are this
# checkout's, so it holds no second build. micomd: PMAPORTS_DIR is a pmaports checkout holding
# device/testing/{micomd,device-mobis-g5w}; when the go-micomd commit the APKBUILD names is on no
# remote branch of GO_MICOMD_DIR, the build takes it from there.
# Host defaults to $LIVI_UNIT or user@mobis-g5w.local; sudo reads LIVI_UNIT_SUDO_PASS, else asks.
set -eu
gs=$(cd "$(dirname "$0")/.." && pwd)
repo=$(cd "$gs/.." && pwd)
. "$gs/scripts/dotenv.sh"

usage() { sed -n '3,11p' "$0" >&2; exit 2; }
mode=
while getopts nb o; do
    case $o in n) mode=dry ;; b) mode=build ;; *) usage ;; esac
done
shift $((OPTIND - 1))
what=all
case ${1:-} in shell | release | core | micomd | all) what=$1; shift ;; -*) usage ;; esac
host="${1:-${LIVI_UNIT:-user@mobis-g5w.local}}"
[ "$what" != all ] || what="micomd core shell"

cache=${LIVI_DEPLOY_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/livi-unit-deploy}
stage=$(mktemp -d "${TMPDIR:-/tmp}/livi-deploy.XXXXXX")
trap 'rm -rf "$stage"' EXIT INT TERM
mkdir -p "$cache" "$stage/apk" "$stage/core"
R=/usr/lib/livi-core/resources
head=$(git -C "$repo" rev-parse HEAD)
unit() { ssh "$host" "$@"; }
has() { case " $what " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
logrun() { # name cmd...: output to the cache's log, its tail on failure
    l=$cache/$1.log; shift
    "$@" >"$l" 2>&1 || { tail -n 30 "$l" >&2; echo "failed, log: $l" >&2; exit 1; }
}

# --- micomd ------------------------------------------------------------------------------------
apks='' micomd_pkgs=''
if has micomd; then
    P=${PMAPORTS_DIR:?PMAPORTS_DIR: the pmaports checkout to build micomd from (.env)}
    md=$(git -C "$P" ls-files -- '*/micomd/APKBUILD') md=${md%/APKBUILD}
    dd=$(git -C "$P" ls-files -- '*/device-mobis-g5w/APKBUILD') dd=${dd%/APKBUILD}
    [ -n "$md" ] && [ -n "$dd" ] || { echo "no micomd or device-mobis-g5w in $P" >&2; exit 1; }
    echo "micomd: pmaports $(git -C "$P" log -1 --format='%h %s' | cut -c1-70)"
    [ -z "$(git -C "$P" status --porcelain -- "$md" "$dd")" ] ||
        echo "  uncommitted changes in $md or $dd are not deployed"
    ver=$(git -C "$P" show "HEAD:$md/APKBUILD" | sed -n 's/^_ver=//p')
    # Every file the device package ships verbatim: one whose hash no installed file has changed.
    git -C "$P" ls-tree --name-only HEAD "$dd/" | grep -vE '/APKBUILD$|\.initd$' |
        while read -r f; do printf '%s %s\n' "$(git -C "$P" show "HEAD:$f" | shasum -a 256 | cut -d' ' -f1)" "${f##*/}"; done \
        >"$stage/device.sums"
    unit "printf '%s\\n' \"\$(grep -ao 'v0\\.0\\.0-[0-9]\\{14\\}-[0-9a-f]\\{12\\}' /usr/bin/micomd | head -1)\"
        grep -c -F '$ver' /usr/bin/micomd
        apk info -v 2>/dev/null | grep -E '^(micomd|micom-livi|device-mobis-g5w(-systemd)?)-[0-9]' | tr '\n' ' '; echo
        apk info -L device-mobis-g5w device-mobis-g5w-systemd 2>/dev/null | grep -v -e '^\$' -e 'contains:\$' |
            sed 's|^|/|' | xargs sha256sum 2>/dev/null | cut -d' ' -f1" >"$stage/unit.micomd" || true
    echo "  unit: $(sed -n 3p "$stage/unit.micomd")"
    if [ "$(sed -n 2p "$stage/unit.micomd")" = 0 ]; then
        echo "  micomd: $(sed -n 1p "$stage/unit.micomd") -> $ver"
        micomd_pkgs=micomd
    else
        echo "  micomd: $ver, same"
    fi
    changed=$(sed -n '4,$p' "$stage/unit.micomd" | awk 'NR == FNR { h[$1] = 1; next } !($1 in h) { print $2 }' - "$stage/device.sums" | tr '\n' ' ')
    if [ -n "$changed" ]; then
        echo "  device-mobis-g5w: differs: $changed"
        micomd_pkgs="$micomd_pkgs device-mobis-g5w"
    else
        echo "  device-mobis-g5w: same"
    fi

    # An unpushed go-micomd commit: the module proxy has no such version.
    sha=${ver##*-} mirror=
    if [ -n "$micomd_pkgs" ] && [ -n "${GO_MICOMD_DIR:-}" ] &&
        git -C "$GO_MICOMD_DIR" rev-parse -q --verify "$sha^{commit}" >/dev/null &&
        [ -z "$(git -C "$GO_MICOMD_DIR" branch -r --contains "$sha")" ]; then
        mirror=1
        echo "  go-micomd $sha is not pushed: built from $GO_MICOMD_DIR"
    fi

    if [ -n "$micomd_pkgs" ] && [ "$mode" != dry ]; then
        . "$gs/tools/pmb/env.sh"
        CFG=/home/pmos/.config/pmbootstrap-livi-unit.cfg
        printf '[pmbootstrap]\nservice_manager = systemd\n' | pmb_config "$CFG"
        logrun pmaports pmb_aports
        src=$stage/src && mkdir -p "$src/aports"
        strip=$(printf '%s' "${md%/*}/" | tr -cd / | wc -c | tr -d ' ')
        git -C "$P" archive HEAD "$md" "$dd" | tar -xf - -C "$src/aports" --strip-components "$strip"
        if [ -n "$mirror" ]; then
            git clone -q --bare --no-local "$GO_MICOMD_DIR" "$src/go-micomd.git"
            git -C "$src/go-micomd.git" cat-file -e "$sha^{commit}"
        fi
        rel=$(date +%s)
        echo "  building $micomd_pkgs (pkgrel $rel), log: $cache/micomd-build.log"
        # pmbootstrap 3.12's build -i never reaches its context; without it the device package
        # wants the kernel and the rest of its depends built first.
        (cd "$src" && COPYFILE_DISABLE=1 tar -cf - .) | pmb_exec sh -euc '
            a=$1 cfg=$2 rel=$3; shift 3
            t=$(mktemp -d) g=
            trap "rm -rf \"\$t\"; [ -z \"\$g\" ] || sudo rm -rf \"\$g\"" EXIT
            tar -C "$t" -xf -
            cd "$a/device/testing"
            for p in "$t"/aports/*; do
                rm -rf "${p##*/}" && cp -R "$p" . && sed -i "s/^pkgrel=.*/pkgrel=$rel/" "${p##*/}/APKBUILD"
            done
            if [ -d "$t/go-micomd.git" ]; then
                g=$HOME/.local/var/pmbootstrap/cache_git/go-micomd-livi-unit.git
                sudo rm -rf "$g" && sudo mv "$t/go-micomd.git" "$g" && sudo chmod -R a+rX "$g"
                u=$(sed -n "s/^url=\"\\(.*\\)\"/\\1/p" micomd/APKBUILD)
                e="	export GOPROXY=direct GOSUMDB=off GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=url./mnt/pmbootstrap/git/${g##*/}.insteadOf GIT_CONFIG_VALUE_0=$u"
                awk -v e="$e" "/^makedepends=/ { sub(/\"\$/, \" git\\\"\") } { print } /^build\\(\\) \\{/ { print e }" \
                    micomd/APKBUILD >micomd/APKBUILD.new && mv micomd/APKBUILD.new micomd/APKBUILD
            fi
            pmb() { python3 -c "import sys; sys.path.insert(0, \"/opt/pmbootstrap\")
import pmb, pmb.core.context
pmb.core.context.Context.ignore_depends = True
sys.argv[0] = \"pmbootstrap\"
sys.exit(pmb.main())" --config "$cfg" "$@"; }
            { pmb checksum "$@" && pmb -y build --force --arch armv7 "$@"; } >&2
            cd ~/.local/var/pmbootstrap/packages
            find . -path "*/armv7/*-r$rel.apk" ! -name "*-openrc-*" | tar -cf - -T -' \
            sh "$PMB_APORTS" "$CFG" "$rel" $micomd_pkgs 2>"$cache/micomd-build.log" | tar -xf - -C "$stage/apk" ||
            { tail -n 30 "$cache/micomd-build.log" >&2; exit 1; }
        find "$stage/apk" -mindepth 2 -name '*.apk' -exec mv {} "$stage/apk/" \;
        apks=$(cd "$stage/apk" && for f in *.apk; do if [ -e "$f" ]; then printf '%s ' "$f"; fi; done)
        [ -n "$apks" ] || { echo "no apks built, log: $cache/micomd-build.log" >&2; exit 1; }
        echo "  built: $apks"
    fi
fi

# --- shell and core: from a clean worktree of HEAD ---------------------------------------------
wt=$cache/src
if has core || has shell || has release; then
    echo "LIVI: $(git -C "$repo" log -1 --format='%h %s' | cut -c1-70), from $wt"
    dirty=$(git -C "$repo" status --porcelain -- native godot-shell/ext godot-shell/project | wc -l | tr -d ' ')
    [ "$dirty" = 0 ] || echo "  $dirty uncommitted change(s) under native/ and godot-shell/ are not deployed"
    if [ -e "$wt/.git" ]; then
        git -C "$wt" checkout -q --detach -f "$head" && git -C "$wt" clean -fdq
    else
        git -C "$repo" worktree prune
        git -C "$repo" worktree add -q --detach "$wt" "$head"
    fi
    for d in godot-shell/ext native; do
        mkdir -p "$repo/$d/target"
        [ -L "$wt/$d/target" ] || rm -rf "$wt/$d/target"
        ln -sfn "$repo/$d/target" "$wt/$d/target"
    done
    out=$wt/godot-shell/packaging/out/armv7
    # A build is current while nothing it reads changed since the commit it was made at.
    built=$(cat "$out/.built" 2>/dev/null || :)
    current=
    [ -z "$built" ] || ! git -C "$repo" diff --quiet "$built" "$head" -- native godot-shell/ext \
        godot-shell/packaging/scripts rust-toolchain.toml 2>/dev/null || current=1
    # ext and core both: cargo rebuilds only what changed, and one stamp covers both.
    if [ -z "$current" ] && [ "$mode" != dry ]; then
        echo "  building ext core, log: $cache/build-armv7.log"
        PATH=/opt/homebrew/bin:/usr/local/bin:$PATH ARMV7_WORK=${ARMV7_WORK:-$cache/work} \
            logrun build-armv7 "$wt/godot-shell/packaging/scripts/build-armv7.sh" ext core
        echo "$head" >"$out/.built"
        current=1
    fi
fi

core=
if has core; then
    if [ -z "$current" ]; then
        echo "  core: no build of HEAD yet (-b builds one): unit's hashes:"
        unit "cd $R && sha256sum core/livi-core output/livi-output driver/livi-helperd" | sed 's/^/    /'
    else
        sums=$(unit "cd $R && sha256sum core/livi-core output/livi-output driver/livi-helperd 2>/dev/null" || :)
        for b in core/livi-core output/livi-output driver/livi-helperd; do
            l=$(shasum -a 256 "$out/${b#*/}" | cut -d' ' -f1)
            r=$(printf '%s\n' "$sums" | awk -v f="$b" '$2 == f { print $1 }')
            if [ "$l" = "$r" ]; then
                echo "  $b: same"
            else
                echo "  $b: ${r:-missing} -> $l"
                mkdir -p "$stage/core/${b%/*}" && cp "$out/${b#*/}" "$stage/core/$b"
                core="$core $b"
            fi
        done
    fi
fi

shell=
if has shell; then
    n=; [ -z "$mode" ] || n=-n
    # Synced and load-checked; the restart is the root step's.
    "$wt/godot-shell/scripts/unit-sync.sh" $n "$host" >"$cache/unit-sync.log" 2>&1 ||
        { sed 's/^/    /' "$cache/unit-sync.log"; exit 1; }
    f=$(grep -vE '^(sending|sent|total|building|Transfer starting|restart:|$)|/$' "$cache/unit-sync.log" || :)
    echo "  shell: $(printf '%s' "$f" | grep -c .) file(s) ${n:+would be }synced (log: $cache/unit-sync.log)"
    printf '%s\n' "$f" | head -n 15 | sed 's/^/    /'
    [ -n "$mode" ] || shell=1
fi

release=
if has release; then
    # The template is Alpine's (armv7), of the version of the VM's godot, which exports the pack.
    tv=${GODOT_TEMPLATES:-4.7.2-r0}
    tpl=$cache/godot-templates-$tv/usr/bin/godot-template-release
    if [ "$mode" = dry ]; then
        echo "  release: the unit runs $(unit "grep '^LIVI_SHELL_GODOT=' /etc/livi-shell.conf" || echo 'the editor build')"
    elif [ -z "$current" ]; then
        echo "  release: no armv7 extension of HEAD" >&2; exit 1
    else
        if [ ! -f "$tpl" ]; then
            echo "  fetching godot-templates $tv (armv7, ~54 MB)"
            mkdir -p "${tpl%/usr/*}"
            curl -sfL "https://dl-cdn.alpinelinux.org/alpine/edge/testing/armv7/godot-templates-$tv.apk" |
                tar -xzf - -C "${tpl%/usr/*}" usr/bin/godot-template-release
        fi
        echo "  exporting the pack in the VM, log: $cache/export.log"
        VM_DEST=${VM_DEST:-deploy} logrun export "$wt/godot-shell/scripts/vm.sh" \
            "v=\$(godot --version | cut -d. -f1-3); [ \"\$v\" = ${tv%-r*} ] || { echo \"VM godot \$v, template $tv\"; exit 1; }
            scripts/build-ext.sh --release && scripts/export-release.sh out/release"
        r=$wt/godot-shell/out/release
        cp "$tpl" "$r/livi-shell"
        cp "$out/liblivi_godot_shell.so" "$r/"
        n=; [ -z "$mode" ] || n=-n
        "$wt/godot-shell/scripts/unit-release.sh" $n "$r" "$host" >"$cache/unit-release.log" 2>&1 ||
            { sed 's/^/    /' "$cache/unit-release.log"; exit 1; }
        echo "  release: $(grep -cE '^(livi-shell|liblivi|fonts/)' "$cache/unit-release.log") file(s) ${n:+would be }synced (log: $cache/unit-release.log)"
        [ -n "$mode" ] || release=$(unit 'echo $HOME')/shellrel/livi-shell
    fi
fi
# The launcher and its unit, from HEAD: the shell's start depends on both.
if has shell || has release; then
    mkdir -p "$stage/pkg"
    cp "$wt/godot-shell/packaging/alpine/livi-shell/livi-shell.sh" "$wt/godot-shell/packaging/alpine/livi-shell/livi-shell.service" "$stage/pkg/"
fi

[ -z "$mode" ] || exit 0
[ -n "$apks$core$shell$release" ] || { echo "nothing to install"; exit 0; }

# --- the root step: one sudo -------------------------------------------------------------------
{
    printf 'apks=%s\ncore=%s\nshell=%s\nrelease=%s\nR=%s\n' "'$apks'" "'$core'" "'$shell'" "'$release'" "$R"
    cat <<'EOS'
set -u
d=$(cd "$(dirname "$0")" && pwd)
trap 'cd /; rm -rf "$d"' EXIT
since=$(date '+%F %T')
bad=0
j() { journalctl -b --no-pager -o cat --since "$since" "$@"; }
no() { echo "FAIL: $*"; bad=$((bad + 1)); }

if [ -n "$apks" ]; then
    echo "== micomd: apk add $apks"
    (cd "$d/apk" && apk add --allow-untrusted $apks) >"$d/apk.log" 2>&1 || { cat "$d/apk.log"; exit 1; }
    grep -v '^WARNING: fetching' "$d/apk.log" | tail -n 5
    # A drop-in that only sets ExecStart to flags the packaged unit now has is obsolete.
    for u in mobis-g5w-micomd mobis-g5w-micom-livi; do
        pk=$(sed -n 's/^ExecStart=//p' "/usr/lib/systemd/system/$u.service" | tr ' ' '\n')
        for f in /etc/systemd/system/$u.service.d/*.conf; do
            [ -e "$f" ] || continue
            other=$(grep -vE '^(#.*|\[Service\]|ExecStart=.*)?$' "$f")
            flags=$(sed -n 's/^ExecStart=//p' "$f" | tr ' ' '\n' | grep -v '^$')
            if [ -z "$other" ] && [ -n "$flags" ] && [ -z "$(printf '%s\n' "$flags" | grep -vxF "$pk")" ]; then
                rm "$f" && echo "removed $f: its flags are packaged"
            else
                echo "kept $f: sets more than the packaged unit"
            fi
        done
        rmdir "/etc/systemd/system/$u.service.d" 2>/dev/null || :
    done
    # micomd is in the initramfs.
    mkinitfs >"$d/mkinitfs.log" 2>&1 || { cat "$d/mkinitfs.log"; exit 1; }
    systemctl daemon-reload
    systemctl restart mobis-g5w-micomd.service
    sleep 3
    systemctl restart mobis-g5w-micom-livi.service
fi

if [ -d "$d/pkg" ]; then
    cmp -s "$d/pkg/livi-shell.sh" /usr/bin/livi-shell ||
        { install -m755 "$d/pkg/livi-shell.sh" /usr/bin/livi-shell && echo "installed /usr/bin/livi-shell"; }
    u=/usr/lib/systemd/system/livi-shell.service
    cmp -s "$d/pkg/livi-shell.service" $u ||
        { install -m644 "$d/pkg/livi-shell.service" $u && systemctl daemon-reload && echo "installed $u"; }
    c=/etc/livi-shell.conf
    if [ -n "$release" ]; then
        grep -qxF "LIVI_SHELL_GODOT=$release" $c ||
            { sed -i '/^LIVI_SHELL_GODOT=/d' $c && echo "LIVI_SHELL_GODOT=$release" >>$c && echo "$c: LIVI_SHELL_GODOT=$release"; }
    elif grep -q '^LIVI_SHELL_GODOT=.*/shellrel/' $c; then
        sed -i '/^LIVI_SHELL_GODOT=.*\/shellrel\//d' $c && echo "$c: LIVI_SHELL_GODOT dropped: the project again"
    fi
fi

if [ -n "$core" ]; then
    echo "== core:$core"
    systemctl stop livi-shell.service livi-shell-core.service
    for b in $core; do install -Dm755 "$d/core/$b" "$R/$b"; done
    systemctl start livi-shell-core.service livi-shell.service
elif [ -n "$shell$release" ]; then
    echo "== restart livi-shell"
    systemctl restart livi-shell.service
fi
if [ -n "$core$shell$release" ]; then
    i=0
    until j -u livi-shell | grep -q 'first_frame' || [ $i -ge 60 ]; do sleep 1; i=$((i + 1)); done
fi
if [ -n "$core" ]; then
    # A new livi-helperd makes livi-core reinstall the AP's unit and leave the AP down (TODO.md).
    sleep 5
    if systemctl is-enabled --quiet livi-wifi-ap.service && ! systemctl is-active --quiet livi-wifi-ap.service; then
        echo "livi-wifi-ap down: starting it"
        systemctl start livi-wifi-ap.service
    fi
fi
[ -z "$apks" ] || sleep 5

echo "== check"
if [ -n "$apks" ]; then
    apk info -v 2>/dev/null | grep -E '^(micomd|micom-livi|device-mobis-g5w(-systemd)?)-[0-9]' | tr '\n' ' '; echo
    m=$(j -u mobis-g5w-micomd)
    v=$(printf '%s\n' "$m" | grep 'switching to it' | tail -n 1)
    [ -n "$v" ] && echo "$v" || no "micomd: no variant switch"
    asked=$(printf '%s\n' "$m" | grep -c 'asked the micom for')
    unans=$(printf '%s\n' "$m" | grep -E ': no .* after [0-9]+ requests')
    echo "micomd: $asked start-up request(s) sent"
    [ -z "$unans" ] || no "micomd: unanswered: $unans"
    for s in /run/micomd.sock /run/micomd.ctl; do
        [ "$(stat -c %G "$s" 2>/dev/null)" = wheel ] || no "$s not group wheel"
    done
    rep=$(j -u mobis-g5w-micom-livi | grep -iE 'error|fail|refused' | grep -v 'connection refused' |
        sed -E 's/[0-9]+/N/g' | sort | uniq -c | awk '$1 > 1' | sort -rn | head -n 5)
    [ -z "$rep" ] || no "micom-livi repeats:
$rep"
fi
if [ -n "$core$shell$release" ]; then
    s=$(j -u livi-shell)
    ff=$(printf '%s\n' "$s" | grep -E '\[startup\] first_frame' | tail -n 1)
    [ -n "$ff" ] && echo "$ff" || no "livi-shell: no first_frame in 60 s"
    n=$(printf '%s\n' "$s" | grep -c 'SCRIPT ERROR')
    echo "SCRIPT ERROR: $n"
    [ "$n" = 0 ] || no "$n SCRIPT ERROR(s)"
    pgrep livi-output >/dev/null || no "livi-output not running"
fi
for u in mobis-g5w-micomd mobis-g5w-micom-livi livi-shell-core livi-shell livi-wifi-ap mobis-g5w-amp; do
    a=$(systemctl is-active "$u.service")
    echo "$u: $a"
    [ "$a" = active ] || no "$u $a"
done
[ "$bad" = 0 ] && echo "deploy: ok" || { echo "deploy: $bad problem(s)"; exit 1; }
EOS
} >"$stage/root.sh"
rm -f "$stage"/*.sums "$stage"/unit.* && rm -rf "$stage/src"

rdir=$(unit 'mktemp -d /tmp/livi-deploy.XXXXXX')
rsync -a "$stage/" "$host:$rdir/"
rc=0
if [ -n "${LIVI_UNIT_SUDO_PASS:-}" ]; then
    printf '%s\n' "$LIVI_UNIT_SUDO_PASS" | unit "sudo -S -p '' sh $rdir/root.sh" || rc=$?
else
    ssh -t "$host" "sudo sh $rdir/root.sh" || rc=$?
fi
unit "rm -rf $rdir" 2>/dev/null || :
exit $rc

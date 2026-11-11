# Sourced, after dotenv.sh, with gs set to the godot-shell directory. pmb_exec runs its
# arguments where pmbootstrap is: the command in PMB_EXEC (split on spaces) if set, else this
# directory's container (pmb-exec.sh).
# pmb_aports checks out PMAPORTS_URL at PMAPORTS_REF (a commit or branch) at $PMB_APORTS there;
# the default is upstream pmaports at a commit known to work.
PMAPORTS_UPSTREAM=https://gitlab.postmarketos.org/postmarketOS/pmaports.git
PMAPORTS_URL=${PMAPORTS_URL:-$PMAPORTS_UPSTREAM}
PMAPORTS_REF=${PMAPORTS_REF:-50ec4c2e571f001800725b688568c3b950de00a1}
# Named pmaports (pmbootstrap finds its upstream remote by the directory's name), away from
# pmbootstrap's default checkout, which an existing PMB_EXEC container may use for other work.
PMB_APORTS=/home/pmos/livi/pmaports

# Says so, since the work dir and its log (pmbootstrap log) are then that command's.
[ -z "${PMB_EXEC:-}" ] || echo "pmbootstrap through PMB_EXEC: $PMB_EXEC" >&2

pmb_exec() {
    if [ -n "${PMB_EXEC:-}" ]; then $PMB_EXEC "$@"; else "$gs/tools/pmb/pmb-exec.sh" "$@"; fi
}

# origin stays upstream: pmbootstrap reads channels.cfg from its main branch.
pmb_aports() {
    pmb_exec sh -euc 'url=$1 ref=$2 up=$3 d=$4
        [ -d "$d/.git" ] || { mkdir -p "$d" && git -C "$d" init -q && git -C "$d" remote add origin "$up"; }
        git -C "$d" rev-parse -q --verify origin/main >/dev/null || git -C "$d" fetch -q --depth 1 origin main
        [ "$(git -C "$d" rev-parse -q --verify HEAD || :)" = "$ref" ] || {
            git -C "$d" fetch -q --depth 1 "$url" "$ref"
            git -C "$d" checkout -q -f -B main FETCH_HEAD
        }
        echo "pmaports: $url $(git -C "$d" rev-parse HEAD)" >&2' \
        sh "$PMAPORTS_URL" "$PMAPORTS_REF" "$PMAPORTS_UPSTREAM" "$PMB_APORTS"
}

# Writes the pmbootstrap config read from stdin to $1 in the container, pointed at $PMB_APORTS.
pmb_config() {
    awk -v a="aports = $PMB_APORTS" '{ print } /^\[pmbootstrap\]$/ { print a }' |
        pmb_exec sh -c 'mkdir -p "${1%/*}" && cat > "$1"' sh "$1"
}

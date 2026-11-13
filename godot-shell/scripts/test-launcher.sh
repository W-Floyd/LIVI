#!/bin/sh
# The launcher's session bus (packaging/alpine/livi-shell/livi-shell.sh), each case a row: the
# kiosk never takes a bus from its environment, a user's login bus included, unless asked to.
#   scripts/test-launcher.sh
set -eu
cd "$(dirname "$0")/.."
launcher=$PWD/packaging/alpine/livi-shell/livi-shell.sh
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
# Stand-ins that print what each was run with; godot reports the bus it would see.
mkdir "$t/bin"
for c in cage dbus-run-session; do
    printf '#!/bin/sh\necho %s >>"$OUT"\n[ "$1" != -- ] || shift\n[ "$1" != -d ] || shift\n[ "$1" != -s ] || shift\n[ "$1" != -- ] || shift\nexec "$@"\n' "$c" >"$t/bin/$c"
done
printf '#!/bin/sh\necho "godot bus=${DBUS_SESSION_BUS_ADDRESS:-none}" >>"$OUT"\n' >"$t/bin/godot"
chmod +x "$t/bin/"*
login="unix:path=/run/user/$(id -u)/bus"
fail=0
# env (space-separated assignments) | what ran, in order
while IFS='|' read -r env want; do
    : >"$t/out"
    env -i PATH="$t/bin:/usr/bin:/bin" HOME="$t" OUT="$t/out" LIVI_SHELL_CONF=/nonexistent \
        LIVI_SHELL_GODOT="$t/bin/godot" XDG_RUNTIME_DIR="$t" $env sh "$launcher"
    got=$(tr '\n' ' ' <"$t/out" | sed 's/ $//')
    if [ "$got" = "$want" ]; then echo "ok: $env"; else echo "FAIL: $env: ran '$got', want '$want'"; fail=1; fi
done <<ROWS
|dbus-run-session cage godot bus=none
DBUS_SESSION_BUS_ADDRESS=$login|dbus-run-session cage godot bus=none
DBUS_SESSION_BUS_ADDRESS=$login LIVI_SHELL_DBUS=session|cage godot bus=$login
WAYLAND_DISPLAY=wayland-0 DBUS_SESSION_BUS_ADDRESS=$login|godot bus=$login
ROWS
exit $fail

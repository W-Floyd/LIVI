#!/bin/sh
# Starts the Godot shell fullscreen. Under a Wayland session (WAYLAND_DISPLAY set) it is a
# window of that compositor; with none it runs inside cage, a kiosk compositor, on the DRM
# device. The shell opens its own Wayland socket ($LIVI_SHELL_SOCKET) for livi-core's
# livi-output, which livi-core.service points at it.
set -eu
conf=${LIVI_SHELL_CONF:-/etc/livi-shell.conf}
[ ! -f "$conf" ] || . "$conf"
: "${LIVI_SHELL_SOCKET:=livi-shell}"
export LIVI_SHELL_SOCKET
godot="${LIVI_SHELL_GODOT:-/usr/bin/godot}"
# Apps started from the shell need a session bus. The kiosk's is its own, for its life: a user's
# (/run/user/<uid>/bus) lasts only while someone is logged in, libdbus exits the shell when it
# goes, and what it activates (portals, AT-SPI) is a desktop's. LIVI_SHELL_DBUS=session keeps the
# environment's.
dbus=
if [ -z "${WAYLAND_DISPLAY:-}" ] && [ "${LIVI_SHELL_DBUS:-}" != session ]; then
    unset DBUS_SESSION_BUS_ADDRESS
    ! command -v dbus-run-session >/dev/null || dbus=dbus-run-session
fi
# Unset, Godot probes each DRM device for a discrete GPU in forked children before its window
# (~150 ms in the VM); the unit has one GPU, so 0, the default device, is what it would find.
export DRI_PRIME="${DRI_PRIME:-0}"
# The compatibility renderer on GLES3 through Wayland's EGL; no Vulkan (Mali-G51 has no
# usable driver); the arm32 feature tag selects the `unit` quality profile. opengl3_es: with
# opengl3 Godot first tries a desktop GL context, which panfrost refuses (on the unit 1.2 s
# went to that and the GPU probe).
set -- --display-driver wayland \
    --rendering-method gl_compatibility --rendering-driver opengl3_es --fullscreen \
    --resolution "${LIVI_SHELL_RESOLUTION:-1920x720}" --audio-driver "${LIVI_SHELL_AUDIO:-PulseAudio}" \
    ${LIVI_SHELL_GODOT_ARGS:-}
# A release template runs the pack named after it (scripts/export-release.sh) and takes no --path.
if [ -f "$godot.pck" ]; then
    set -- "$godot" "$@"
else
    set -- "$godot" --path "${LIVI_SHELL_PROJECT:-/usr/lib/livi-shell/project}" "$@"
fi
if [ -n "${WAYLAND_DISPLAY:-}" ]; then
    exec "$@"
fi
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/livi-shell}"
exec ${dbus:+$dbus --} cage -d -s -- "$@"

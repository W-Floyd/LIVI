#!/bin/sh
# Manage Waydroid and the stock EV app in the VM, from the host.
#   scripts/waydroid.sh start        # container + session (idempotent), on the live shell's compositor if it runs
#   scripts/waydroid.sh into-shell   # restart both so Android's window goes to the shell (scripts/live-window.sh must be running)
#   scripts/waydroid.sh launch [pkg] # start, then open the app (default: the stock EV app)
#   scripts/waydroid.sh ui           # the whole Android UI
#   scripts/waydroid.sh size [WxH [dpi]]   # the display size and density (default 1920x720 240: the panel, at 1.5x so the layouts' 1280x480 dp fill it), then relaunch
#   scripts/waydroid.sh shot [file]  # the QEMU display as a PNG (default out/waydroid.png)
#   scripts/waydroid.sh logs [N]     # the last N logcat lines (default 80), crashes first
#   scripts/waydroid.sh sh [cmd...]  # a shell, or one command, inside Android as root
#   scripts/waydroid.sh stop         # session and container: frees the VM's CPU
#   scripts/waydroid.sh status
#   scripts/waydroid.sh build        # rebuild and reinstall the patched app (tools/waydroid-stock, needs ref/)
set -eu
cd "$(dirname "$0")/.."
PKG=${PKG:-com.hkmc.daudio.app.ev3}
SSH="ssh -p 2222 -o BatchMode=yes user@localhost"
# The shell's own compositor when the live shell runs (project/live), else the desktop's.
ENVS='export XDG_RUNTIME_DIR=/run/user/10000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/10000/bus; if [ -s /tmp/livi-shell-wayland ] && pgrep -f -- "--live" >/dev/null; then export WAYLAND_DISPLAY=$(cat /tmp/livi-shell-wayland); else export WAYLAND_DISPLAY=wayland-0; fi'
as_user() { $SSH "$ENVS; $*"; }
as_root() { $SSH "echo nura | sudo -S -p '' $*" 2>&1; }
android() { as_root waydroid shell -- "$@"; }

start() {
    as_root systemctl start waydroid-container >/dev/null
    as_user 'systemctl --user is-active waydroid-session >/dev/null 2>&1 || systemd-run --user --unit=waydroid-session -E WAYLAND_DISPLAY -E XDG_RUNTIME_DIR waydroid session start >/dev/null 2>&1'
    i=0
    until [ "$(android getprop sys.boot_completed | tr -d '\r')" = 1 ]; do
        i=$((i + 1))
        [ $i -lt 40 ] || { echo "android did not boot in 4 minutes" >&2; exit 1; }
        sleep 6
    done
}

cmd=${1:-status}
[ $# -eq 0 ] || shift
case $cmd in
    status) as_user 'echo "wayland: $WAYLAND_DISPLAY"; waydroid status' ;;
    into-shell)
        as_user 'systemctl --user stop waydroid-session' || true
        as_root systemctl restart waydroid-container >/dev/null
        start; as_user 'echo "wayland: $WAYLAND_DISPLAY"; waydroid status' ;;
    start) start; as_user waydroid status ;;
    launch)
        start
        as_user "waydroid app launch ${1:-$PKG}"
        echo "launched ${1:-$PKG}; the first frame takes about a minute under QEMU (scripts/waydroid.sh shot)" ;;
    ui) start; as_user 'waydroid show-full-ui' ;;
    size)
        start
        # Stopped first: the app dies if Android relaunches it on the size change (its onDestroy unregisters a
        # receiver it never registered).
        android am force-stop "$PKG"
        android wm size "${1:-1920x720}"
        android wm density "${2:-240}"
        as_user "waydroid app launch $PKG" ;;
    shot)
        out=${1:-out/waydroid.png}
        mkdir -p "$(dirname "$out")"
        tmp=$(mktemp).ppm
        echo "screendump $tmp" | nc -U -w 2 vm/qemu-aarch64/monitor.sock >/dev/null
        sleep 1
        magick "$tmp" "$out"; rm -f "$tmp"
        echo "$out" ;;
    logs)
        n=${1:-80}
        android logcat -d | grep -E "FATAL EXCEPTION|AndroidRuntime" -A12 | tail -"$n"
        echo "--- $PKG"
        android logcat -d | grep -i "$PKG" | tail -"$n" ;;
    sh) [ "${1:-}" != -- ] || shift; if [ $# -gt 0 ]; then android "$@"; else $SSH -t "echo nura | sudo -S waydroid shell"; fi ;;
    stop)
        as_user 'systemctl --user stop waydroid-session' || true
        as_root systemctl stop waydroid-container
        echo stopped ;;
    build)
        for s in 01-fetch 03-target 02-deodex 04-build 05-install; do tools/waydroid-stock/$s.sh; done ;;
    *) sed -n '2,13p' "$0"; exit 2 ;;
esac

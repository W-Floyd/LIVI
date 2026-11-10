#!/usr/bin/env bash
# Copy the patched apk into the VM's Waydroid, install, launch, dump logcat. Usage: 05-install.sh [launch-activity]
set -euo pipefail; . "$(dirname "$0")/env.sh"
PKG="${PKG:-com.hkmc.daudio.app.ev3}"; ACT="${1:-$PKG/.MainActivity}"
scp -q -P 2222 -o BatchMode=yes "$OUT/$APP-patched.apk" user@localhost:/tmp/$APP.apk
"${SSH[@]}" "echo nura | sudo -S sh -c 'cp /tmp/$APP.apk /home/user/.local/share/waydroid/data/local/tmp/$APP.apk && chmod 644 /home/user/.local/share/waydroid/data/local/tmp/$APP.apk && waydroid shell -- pm uninstall $PKG >/dev/null 2>&1; waydroid shell -- pm install -g /data/local/tmp/$APP.apk && waydroid shell -- logcat -c && waydroid shell -- am force-stop com.android.permissioncontroller; waydroid shell -- am start -n $ACT'" 2>&1 | grep -v '^\[sudo\]\|^Password'
sleep "${WAIT:-25}"
"${SSH[@]}" "echo nura | sudo -S waydroid shell -- logcat -d" 2>&1 | grep -E "FATAL EXCEPTION|AndroidRuntime" | grep -v "^\[sudo" | cut -c1-260 | grep -A14 "FATAL EXCEPTION" | tail -${LINES_OUT:-40}
"${SSH[@]}" "echo nura | sudo -S waydroid shell -- dumpsys activity activities" 2>&1 | grep -E "topResumedActivity"

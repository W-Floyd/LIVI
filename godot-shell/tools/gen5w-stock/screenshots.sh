#!/usr/bin/env bash
# Boot the imported template, click through consent/first-run, and capture the
# stock UI at 1920x720. Needs `emuctl` (patched with emulator-macos.patch on macOS)
# and EMUCTL_STATE/EMUCTL_IMAGES set. usage: ./screenshots.sh TEMPLATE OUTDIR
set -euo pipefail
T=${1:?template name, e.g. ev6-V015}; OUT=${2:?output dir}
mkdir -p "$OUT"
id=$(emuctl start "$T" --name "shots-$$")
trap 'emuctl stop "$id" >/dev/null || true' EXIT
emuctl wait "$id" --timeout 600
sleep 10
# com.mobis.welcome draws a black full-screen overlay waiting on the micom; dismiss it.
emuctl exec "$id" 'am force-stop com.mobis.welcome' >/dev/null
sleep 6
emuctl screenshot "$id" "$OUT/01-consent.png"
emuctl tap "$id" 825 660; sleep 5     # Confirm
emuctl tap "$id" 480 665; sleep 4     # First Run Setup: Skip
emuctl tap "$id" 720 558; sleep 6     # Skip? Yes
emuctl screenshot "$id" "$OUT/02-home.png"
for p in com.hkmc.av.app.radiona com.hkmc.system.app.homesetting com.daudio.app.voicememo com.hkmc.system.app.userprofile; do
  emuctl exec "$id" "monkey -p $p -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1" >/dev/null
  sleep 7
  emuctl screenshot "$id" "$OUT/app-$p.png"
done

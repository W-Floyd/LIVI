#!/usr/bin/env bash
# Deodex $APP against the firmware framework -> $OUT/smali/$APP; deodex the framework odex that define com.hkmc.* -> $OUT/fwsmali.
set -euo pipefail; . "$(dirname "$0")/env.sh"
FW="$OUT/fw/framework"
odex="$(find "$OUT/odex" -name "$APP.odex" | head -1)"
rm -rf "$OUT/smali/$APP"
BAKSMALI deodex -a "$API" -d "$FW" -o "$OUT/smali/$APP" "$odex"
for f in framework automotive automotive-service com.hkmc.ext.hcan com.infobank com.logfilter framework2; do
  rm -rf "$OUT/fwsmali/$f"; BAKSMALI deodex -a "$API" -d "$FW" -o "$OUT/fwsmali/$f" "$FW/$f.odex"
done
rm -rf "$OUT/fwsmali/bcm"; BAKSMALI disassemble -a "$API" -o "$OUT/fwsmali/bcm" "$FW/com.broadcom.bt.jar"
SMALI assemble -a "$API" "$OUT/smali/$APP" -o /dev/null && echo "deodexed $APP reassembles"

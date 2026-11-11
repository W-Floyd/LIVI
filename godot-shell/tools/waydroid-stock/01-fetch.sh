#!/usr/bin/env bash
# Download baksmali/smali 2.5.2 and deps (Maven Central), extract framework + app odex from the firmware.
set -euo pipefail; . "$(dirname "$0")/env.sh"
mkdir -p "$JARS" "$OUT/fw" "$OUT/odex"
M=https://repo1.maven.org/maven2
for p in org/smali/baksmali/2.5.2/baksmali-2.5.2 org/smali/dexlib2/2.5.2/dexlib2-2.5.2 org/smali/util/2.5.2/util-2.5.2 \
  org/smali/smali/2.5.2/smali-2.5.2 com/google/guava/guava/31.1-jre/guava-31.1-jre com/google/guava/failureaccess/1.0.1/failureaccess-1.0.1 \
  com/beust/jcommander/1.64/jcommander-1.64 com/google/code/findbugs/jsr305/3.0.2/jsr305-3.0.2 \
  org/antlr/antlr-runtime/3.5.2/antlr-runtime-3.5.2 org/antlr/antlr/3.5.2/antlr-3.5.2 org/antlr/ST4/4.0.8/ST4-4.0.8 \
  org/antlr/stringtemplate/3.2.1/stringtemplate-3.2.1 antlr/antlr/2.7.7/antlr-2.7.7; do
  f="$JARS/$(basename "$p").jar"; [ -s "$f" ] || curl -sfL -o "$f" "$M/$p.jar"
done
: "${SYSTEM_EXT4:?set SYSTEM_EXT4 to the decrypted firmware's system.ext4}"
cd "$(dirname "$SYSTEM_EXT4")"
"$UNBRICK" extract -r -f "$SYSTEM_EXT4" -m '^framework/[^/]+\.(odex|jar)$' -o "$OUT/fw"
"$UNBRICK" extract -r -f "$SYSTEM_EXT4" -m "^(app|priv-app)/[^/]+\.odex$" -o "$OUT/odex"

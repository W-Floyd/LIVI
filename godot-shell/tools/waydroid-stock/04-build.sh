#!/usr/bin/env bash
# stubs + patched smali -> classes.dex/classes2.dex, merged into the stock apk, debug-signed -> $OUT/$APP-patched.apk
set -euo pipefail; . "$(dirname "$0")/env.sh"
SM="$OUT/smali/$APP"; ST="$OUT/stubs"; B="$OUT/build"
rm -rf "$ST" "$B"; mkdir -p "$B/apk"
python3 -I "$HERE/gen_stubs.py" "$SM" "$OUT/fwsmali" "$ST" "$OUT/a13/classes.txt" "$REF/decoded/$APP" "$OUT/a13/api.tsv" "$OUT/stub-values.txt"
rm -rf "$OUT/smali-patched"; cp -R "$SM" "$OUT/smali-patched"
python3 -I "$HERE/patch_smali.py" "$OUT/smali-patched" "$ST" "$OUT/a13/api.tsv"
SMALI assemble -a "$API" "$ST" -o "$B/classes2.dex"
# runtime helpers (Java) -> classes3.dex
AJ="${ANDROID_JAR:-$(ls /opt/homebrew/share/android-commandlinetools/platforms/android-*/android.jar | sort -V | tail -1)}"
mkdir -p "$B/java" "$B/d8"; javac --release 8 -cp "$AJ" -d "$B/java" "$HERE/HkmcStubs.java" 2>&1 | grep -v '^warning\|^Note' || true
"$BT/d8" --min-api 21 --lib "$AJ" --output "$B/d8" "$B"/java/com/livi/waydroid/*.class 2>&1 | grep -v '^WARNING' || true
mv "$B/d8/classes.dex" "$B/classes3.dex"
SMALI assemble -a "$API" "$OUT/smali-patched" -o "$B/classes.dex"
cp "$REF/apks/app/$APP.apk" "$B/in.apk"
cd "$B/apk" && unzip -q ../in.apk && rm -rf META-INF && python3 -I "$HERE/patch_framework_refs.py" . "$(magick "$REF/decoded/framework-res/res/drawable-night-hdpi-v8/co_bg.png" -resize 1x1 -format 'ff%[hex:u.p{0,0}]' info:)" && cp ../classes.dex ../classes2.dex ../classes3.dex . && python3 -I "$HERE/patch_manifest.py" AndroidManifest.xml AndroidManifest.xml.new && mv AndroidManifest.xml.new AndroidManifest.xml && zip -q -r -X ../unsigned.apk AndroidManifest.xml classes.dex classes2.dex classes3.dex . -x '.*'
cd "$B"
KS="$OUT/debug.keystore"
[ -f "$KS" ] || keytool -genkeypair -keystore "$KS" -storepass android -keypass android -alias debug -keyalg RSA -keysize 2048 -validity 10000 -dname "CN=debug" >/dev/null 2>&1
"$BT/zipalign" -f -p 4 unsigned.apk aligned.apk
"$BT/apksigner" sign --ks "$KS" --ks-pass pass:android --key-pass pass:android --v1-signing-enabled true --v2-signing-enabled true --out "$OUT/$APP-patched.apk" aligned.apk
echo "built $OUT/$APP-patched.apk"

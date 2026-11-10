#!/usr/bin/env bash
# Pull the Waydroid framework + apex jars from the VM and list the classes they define ($OUT/a13/classes.txt).
set -euo pipefail; . "$(dirname "$0")/env.sh"
mkdir -p "$OUT/a13"; cd "$OUT/a13"; rm -rf dex jars; mkdir jars
"${SSH[@]}" 'cd /var/lib/waydroid/rootfs/system && tar cf - framework/*.jar apex/*/javalib/*.jar' | tar xf - -C jars
for j in jars/framework/*.jar jars/apex/*/javalib/*.jar; do
  d="dex/$(echo "${j#jars/}" | tr / _)"; mkdir -p "$d"; unzip -q -o -d "$d" "$j" 'classes*.dex' 2>/dev/null || true
done
for d in dex/*/classes*.dex; do BAKSMALI list classes "$d"; done | sed 's/^L//; s/;$//' | sort -u > classes.txt
wc -l classes.txt
# member inventory (class/super/interfaces/methods/fields) used by find_missing.py
mkdir -p "$OUT/build-java"; javac -cp "$CP" -d "$OUT/build-java" "$HERE/DumpApi.java"
java -cp "$OUT/build-java:$CP" DumpApi api.tsv dex/*/classes*.dex 2> >(grep -v '^WARNING' >&2)

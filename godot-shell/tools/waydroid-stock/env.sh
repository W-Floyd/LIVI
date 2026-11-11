# Sourced by the other scripts. Paths are overridable from the environment.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
. "$REPO/scripts/dotenv.sh"
REF="${REF:-$REPO/ref/kia/ev6/2024}"
OUT="${OUT:-$REF/waydroid}"            # everything derived from Kia assets lives here (gitignored)
APP="${APP:-HKMC_TAppEV3}"
API="${API:-16}"                        # firmware is Android 4.2-era Dalvik; api 19+ mis-decodes the odex
UNBRICK="${UNBRICK:-unbrick}"                # go-unbrick binary
SYSTEM_EXT4="${SYSTEM_EXT4:-}"                # decrypted V015 system.ext4; 01-fetch.sh needs it
JARS="$OUT/tools"
CP="$(ls "$JARS"/*.jar 2>/dev/null | tr "\n" ":" || true)"
BAKSMALI() { java -cp "$CP" org.jf.baksmali.Main "$@" 2> >(grep -v '^WARNING' >&2); }
SMALI()    { java -cp "$CP" org.jf.smali.Main "$@" 2> >(grep -v '^WARNING' >&2); }
BT="${BT:-$(ls -d /opt/homebrew/share/android-commandlinetools/build-tools/* 2>/dev/null | sort -V | tail -1)}"
SSH=(ssh -p 2222 -o BatchMode=yes user@localhost)

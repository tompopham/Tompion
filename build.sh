#!/bin/sh
# Builds Tompion.app, a one-binary app bundle, into <output-dir>/Tompion.app
# (default: build/ beside this script).
#
#   TOMPION_BUNDLE_ID=com.yourname.tompion sh build.sh             builds build/Tompion.app
#   TOMPION_BUNDLE_ID=com.yourname.tompion sh build.sh /some/dir   builds /some/dir/Tompion.app
#
# TOMPION_BUNDLE_ID sets the built app's bundle identifier; the Info.plist here
# keeps the com.example.tompion placeholder. Use one of your own and keep it the
# same from build to build: macOS ties the calendar permission to the app's
# identity. Without it the app gets the placeholder, with a warning.
#
# It runs as its own app, through `open` (see README.md), so macOS asks once for
# calendar access for it, instead of refusing silently on behalf of whatever
# started it. It is compiled for macOS 14 or later, whatever this Mac runs, and
# built in a temporary folder first, so a failed build leaves any existing app
# as it was.
#
# Build outside iCloud Drive (so not in a synced Desktop or Documents folder):
# iCloud's file attributes break code signing. If your checkout is in one, pass
# an output directory elsewhere.
set -e
if [ "$#" -gt 1 ]; then echo "usage: sh build.sh [output-dir]" >&2; exit 1; fi

SRC="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
DEST="${1:-$SRC/build}"
OUT="$DEST/Tompion.app"
ID="${TOMPION_BUNDLE_ID:-com.example.tompion}"
case "$ID" in
	*[!A-Za-z0-9.-]*) echo "TOMPION_BUNDLE_ID may hold only letters, digits, hyphens and full stops" >&2; exit 1 ;;
esac
if [ -z "$TOMPION_BUNDLE_ID" ]; then
	echo "warning: TOMPION_BUNDLE_ID is not set, so the app gets the placeholder $ID" >&2
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/tompion-build.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
APP="$TMP/Tompion.app"
mkdir -p "$APP/Contents/MacOS"
cp "$SRC/Info.plist" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $ID" "$APP/Contents/Info.plist"
swiftc -O -target "$(uname -m)-apple-macos14.0" "$SRC/tompion.swift" -o "$APP/Contents/MacOS/tompion"
xattr -cr "$APP"
codesign --force --sign - "$APP"

# Only now replace the old app.
mkdir -p "$DEST"
rm -rf "$OUT"
mv "$APP" "$OUT"
echo "built $OUT ($ID)"

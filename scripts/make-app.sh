#!/bin/bash
# Builds a release Notch.app (no Dock icon). Ad-hoc signed by default.
# Optional: SIGN_ID="Developer ID Application: …" signs with hardened runtime, and
# NOTARY_PROFILE=<notarytool keychain profile> also notarises and staples.
set -euo pipefail
cd "$(dirname "$0")/.."
# Edition: store (limited customisation) by default. Master (everything) with MASTER=1,
# or automatically on a Mac that has ~/.notch/master. EDITION=store forces the store build.
FLAGS=()
if [ "${EDITION:-}" != "store" ] && { [ "${MASTER:-}" = 1 ] || [ -f "$HOME/.notch/master" ]; }; then
  FLAGS=(-Xswiftc -DMASTER); echo "Edition: master"
else
  echo "Edition: store"
fi
swift build -c release ${FLAGS[@]+"${FLAGS[@]}"}
APP=build/Notch.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Notch "$APP/Contents/MacOS/Notch"
cp .build/release/libNotchMediaRemote.dylib "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# App icon
ICONSET=$(mktemp -d)/AppIcon.iconset
swift scripts/make-icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# Stable local identity (scripts/make-signing-cert.sh) keeps macOS permissions across rebuilds.
if [ -z "${SIGN_ID:-}" ] && security find-identity -p codesigning 2>/dev/null | grep -q "Notch Local Signing"; then
  SIGN_ID="Notch Local Signing"
fi
SIGN_ID=${SIGN_ID:--}
if [ "$SIGN_ID" = "-" ] || [ "$SIGN_ID" = "Notch Local Signing" ]; then
  [ "$SIGN_ID" = "-" ] && echo "Note: ad-hoc signing; macOS forgets permissions on every rebuild. Run scripts/make-signing-cert.sh once to fix."
  codesign --force --sign "$SIGN_ID" "$APP/Contents/MacOS/libNotchMediaRemote.dylib"
  codesign --force --sign "$SIGN_ID" "$APP"
else
  codesign --force --timestamp --options runtime --sign "$SIGN_ID" "$APP/Contents/MacOS/libNotchMediaRemote.dylib"
  codesign --force --timestamp --options runtime --entitlements Resources/Notch.entitlements --sign "$SIGN_ID" "$APP"
  if [ -n "${NOTARY_PROFILE:-}" ]; then
    ditto -c -k --keepParent "$APP" build/Notch.zip
    xcrun notarytool submit build/Notch.zip --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
  fi
fi
echo "Built $APP  ->  open $APP"

#!/usr/bin/env bash
# Packages a Developer ID signed build/Mountagent Desk.app into a notarized, stapled DMG.
#
# One-time setup:
#   xcrun notarytool store-credentials mountagent-notary --apple-id you@example.com --team-id TEAMID
#
# Then:
#   DEVELOPER_ID="Developer ID Application: Name (TEAMID)" TEAM_ID=TEAMID scripts/build-app.sh
#   NOTARY_PROFILE=mountagent-notary scripts/release.sh
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Release.noindex/Mountagent Desk.app"
PROFILE="${NOTARY_PROFILE:?Set NOTARY_PROFILE to a notarytool keychain profile}"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG="build/MountagentDesk-$VERSION.dmg"

codesign --verify --deep --strict "$APP"
if codesign -dv "$APP" 2>&1 | grep -q "Signature=adhoc"; then
  echo "$APP is ad-hoc signed; rebuild with DEVELOPER_ID set." >&2
  exit 1
fi

STAGING=$(mktemp -d)
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
rm -f "$DMG"
hdiutil create -volname "Mountagent Desk" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGING"
codesign --sign "$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=\(Developer ID Application.*\)/\1/p' | head -1)" --timestamp "$DMG"

xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature -v "$DMG"
echo "Notarized $DMG"

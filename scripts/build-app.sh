#!/usr/bin/env bash
# Builds Mountagent Desk and, for Release, installs it as /Applications/Mountagent Desk.app: the one
# copy Launchpad and Spotlight show. Everything else lives in *.noindex folders, which
# Spotlight skips, so test builds never appear as extra apps.
#
#   scripts/build-app.sh                 # Release → build/Release.noindex, installed to /Applications
#   INSTALL=0 scripts/build-app.sh       # Release without installing
#   CONFIGURATION=Debug scripts/build-app.sh   # → build/Debug.noindex/Mountagent Desk.app
#   DEVELOPER_ID="Developer ID Application: Name (TEAMID)" TEAM_ID=TEAMID scripts/build-app.sh
#                                        # signed for distribution; then run scripts/release.sh
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIGURATION="${CONFIGURATION:-Release}"
DERIVED="build/DerivedData.noindex"
INSTALL_DIR="${INSTALL_DIR:-/Applications}"

command -v xcodegen >/dev/null || { echo "xcodegen is required: brew install xcodegen" >&2; exit 1; }

if [[ ! -f App/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json ]]; then
  swift scripts/make-icon.swift
fi
if [[ ! -f App/Resources/Assets.xcassets/Contents.json ]]; then
  echo '{"info":{"author":"xcode","version":1}}' > App/Resources/Assets.xcassets/Contents.json
fi

xcodegen generate --quiet

SIGNING=()
if [[ -n "${DEVELOPER_ID:-}" ]]; then
  SIGNING=(
    CODE_SIGN_STYLE=Manual
    "CODE_SIGN_IDENTITY=${DEVELOPER_ID}"
    "DEVELOPMENT_TEAM=${TEAM_ID:?TEAM_ID is required with DEVELOPER_ID}"
    "OTHER_CODE_SIGN_FLAGS=--timestamp"
  )
fi

xcodebuild \
  -project MountagentDesk.xcodeproj \
  -scheme MountagentDesk \
  -configuration "$CONFIGURATION" \
  -destination "platform=macOS" \
  -derivedDataPath "$DERIVED" \
  -skipPackagePluginValidation \
  ${SIGNING[@]+"${SIGNING[@]}"} \
  build | { command -v xcbeautify >/dev/null && xcbeautify --quiet || grep -E "error:|warning:|BUILD (SUCCEEDED|FAILED)"; }

# Release goes to build/Mountagent Desk.app (the copy you run); other configurations get their
# own folder so a test build never replaces it.
OUT="build/$CONFIGURATION.noindex"
APP="$OUT/Mountagent Desk.app"
mkdir -p "$OUT"
rm -rf "$APP"
cp -R "$DERIVED/Build/Products/$CONFIGURATION/Mountagent Desk.app" "$APP"

# Without a Developer ID, re-sign with the local certificate (scripts/make-signing-cert.sh)
# when it exists: a stable signature keeps macOS's "Always Allow" answers across builds.
LOCAL_IDENTITY="Mountagent Desk Local Signing"
if [[ -z "${DEVELOPER_ID:-}" ]] && security find-certificate -c "$LOCAL_IDENTITY" >/dev/null 2>&1; then
  ENTITLEMENTS=$(mktemp)
  codesign -d --entitlements :- "$APP" > "$ENTITLEMENTS" 2>/dev/null || true
  [[ -s "$ENTITLEMENTS" ]] || printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict/></plist>\n' > "$ENTITLEMENTS"
  # Inner code first (--deep skips loose dylibs next to the executable): every image the
  # process loads must carry the same signer, or library validation refuses it.
  find "$APP/Contents" -type f \( -name "*.dylib" -o -perm -u+x \) ! -path "*/Contents/MacOS/Mountagent Desk" -print0 2>/dev/null |
    while IFS= read -r -d '' file; do
      if file "$file" | grep -q "Mach-O"; then
        codesign --force --options runtime --timestamp=none --sign "$LOCAL_IDENTITY" "$file"
      fi
    done
  codesign --force --options runtime --timestamp=none \
    --entitlements "$ENTITLEMENTS" --sign "$LOCAL_IDENTITY" "$APP"
  rm -f "$ENTITLEMENTS"
fi
codesign --verify --deep --strict "$APP"
echo "Built $(pwd)/$APP"

if [[ "$CONFIGURATION" == "Release" && "${INSTALL:-1}" == "1" ]]; then
  # Quit a running copy first so the new one replaces it cleanly.
  if pgrep -f "/Mountagent Desk.app/Contents/MacOS/Mountagent Desk" >/dev/null; then
    osascript -e 'tell application id "dev.mountagent.MountagentDesk" to quit' >/dev/null 2>&1 || true
    sleep 2
  fi
  rm -rf "$INSTALL_DIR/Mountagent Desk.app"
  ditto "$APP" "$INSTALL_DIR/Mountagent Desk.app"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$INSTALL_DIR/Mountagent Desk.app" >/dev/null 2>&1 || true
  echo "Installed $INSTALL_DIR/Mountagent Desk.app"
fi

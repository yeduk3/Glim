#!/bin/bash
# Build a Developer ID-signed, Apple-notarized, stapled, Universal qmd.app and zip it.
#
# Prerequisites (one-time):
#   - A "Developer ID Application" certificate in your keychain
#     (Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application)
#   - A notarytool keychain profile:
#       xcrun notarytool store-credentials qmd-notary \
#         --apple-id you@example.com --team-id XXXXXXXXXX --password <app-specific-password>
#
# Usage:
#   QMD_TEAM_ID=XXXXXXXXXX ./release.sh [version]
set -e
cd "$(dirname "$0")"

VERSION="${1:-1.0.0}"
TEAM_ID="${QMD_TEAM_ID:?set QMD_TEAM_ID to your 10-char Apple Developer Team ID}"
SIGN_ID="${QMD_SIGN_ID:-Developer ID Application}"
NOTARY_PROFILE="${QMD_NOTARY_PROFILE:-qmd-notary}"
DD="$HOME/Library/Developer/Xcode/DerivedData/qmd-build"
APP="$DD/Build/Products/Release/qmd.app"
ZIP="/tmp/qmd-v$VERSION-macos.zip"

command -v xcodegen >/dev/null && xcodegen generate

echo "==> Building Universal Release, signed with Developer ID + hardened runtime"
rm -rf "$DD/Build/Products/Release"
xcodebuild -project qmd.xcodeproj -scheme qmd -configuration Release -derivedDataPath "$DD" \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$SIGN_ID" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  ENABLE_HARDENED_RUNTIME=YES \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  OTHER_CODE_SIGN_FLAGS="--timestamp" \
  build

echo "==> Notarizing (waits for Apple)"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> Stapling + repackaging"
xcrun stapler staple "$APP"
rm -f "$ZIP"; ditto -c -k --keepParent "$APP" "$ZIP"

spctl -a -vvv -t exec "$APP" || true
echo "==> Done: $ZIP"
echo "    Publish: gh release upload v$VERSION \"$ZIP\" --clobber"

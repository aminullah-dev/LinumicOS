#!/bin/zsh
# Builds a Developer ID–signed, notarised release of Linumic OS for macOS.
#
#   tools/release/build-release.sh
#
# Notarisation needs a stored notarytool profile named "LinumicOS". Create it once
# (your Apple ID and an app-specific password from appleid.apple.com; they're stored in your Keychain, not here):
#
#   xcrun notarytool store-credentials LinumicOS --apple-id <your Apple ID> --team-id 27RXPRW77S
#
# Without the profile the script still produces a signed zip and says it isn't notarised.
set -euo pipefail
cd "$(dirname "$0")/../.."

PROFILE=LinumicOS
OUT=build/Release
VERSION=$(grep -m1 'MARKETING_VERSION' project.yml | sed -E 's/.*"([^"]+)".*/\1/')
# Remove only this script's own outputs. A copy of the app you've unzipped here (and may be running) is left alone.
mkdir -p "$OUT" && rm -rf "$OUT/LinumicOS.xcarchive" "$OUT/export" "$OUT"/LinumicOS-*.zip

xcodegen generate >/dev/null
swift test --package-path Packages/LinumicCore >/dev/null
xcodebuild -project LinumicOS.xcodeproj -scheme LinumicOS -configuration Release -destination 'generic/platform=macOS' \
  -archivePath "$OUT/LinumicOS.xcarchive" -allowProvisioningUpdates archive | tail -1
xcodebuild -exportArchive -archivePath "$OUT/LinumicOS.xcarchive" -exportPath "$OUT/export" \
  -exportOptionsPlist tools/release/ExportOptions.plist -allowProvisioningUpdates | tail -1

APP="$OUT/export/LinumicOS.app"
ZIP="$OUT/LinumicOS-$VERSION.zip"
codesign --verify --deep --strict "$APP"
ditto -c -k --keepParent "$APP" "$ZIP"

if xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$APP"
  rm "$ZIP" && ditto -c -k --keepParent "$APP" "$ZIP"
  spctl --assess --type execute --verbose "$APP"
  echo "Notarised: $ZIP"
else
  echo "Signed with Developer ID but NOT notarised (no \"$PROFILE\" notarytool profile). See the top of this script."
  echo "Output: $ZIP"
fi

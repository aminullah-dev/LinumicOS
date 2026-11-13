#!/bin/zsh
# Pictures of the Mac app's pages, taken by the app itself, in a build that cannot reach the owner's data.
#
#   tools/design/mac-preview.sh build
#   tools/design/mac-preview.sh shot <out.png> <WxH> <light|dark> <en|fa-AF> [more launch arguments…]
#
# The build is a Debug build under the bundle identifier com.linumic.commandcenter.preview, ad-hoc signed, with an App
# Sandbox that allows nothing but its own container and this checkout's build/shots folder: no network, no folder of
# the owner's, no Keychain item of the real app (KeychainSecretStore gives a preview build items of its own). So its
# files, settings and keys are its own (~/Library/Containers/com.linumic.commandcenter.preview), never those of the
# installed app (com.linumic.commandcenter). `shot` checks the bundle identifier and the entitlements before it runs
# anything, runs the app with sample data and `-LCCSnapshot` (App/Support/DebugSnapshot.swift: the app draws its own
# window and quits, so no Screen Recording permission is asked), and waits for it to end.
set -euo pipefail
cd "$(dirname "$0")/../.."
root=$PWD
derived="$root/build/DerivedData-preview"
shots="$root/build/shots"
app="$derived/Build/Products/Debug/LinumicOS.app"
preview_id=com.linumic.commandcenter.preview

case "${1:-}" in
build)
  mkdir -p "$shots"
  entitlements="$root/build/preview.entitlements"
  cat > "$entitlements" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.app-sandbox</key>
	<true/>
	<key>com.apple.security.temporary-exception.files.absolute-path.read-write</key>
	<array>
		<string>$shots/</string>
	</array>
</dict>
</plist>
EOF
  xcodegen generate >/dev/null
  xcodebuild -project LinumicOS.xcodeproj -scheme LinumicOS -configuration Debug -destination 'platform=macOS' \
    -derivedDataPath "$derived" \
    PRODUCT_BUNDLE_IDENTIFIER=$preview_id CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
    CODE_SIGN_ENTITLEMENTS="$entitlements" ENABLE_HARDENED_RUNTIME=NO build | tail -1
  ;;
shot)
  out=$2 size=$3 look=$4 lang=$5
  shift 5
  id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")
  [[ "$id" == "$preview_id" ]] || { echo "Refused: the build's bundle identifier is $id, not $preview_id" >&2; exit 1; }
  ents=$(codesign -d --entitlements - --xml "$app" 2>/dev/null)
  [[ "$ents" == *"com.apple.security.app-sandbox"* ]] || { echo "Refused: the build is not sandboxed" >&2; exit 1; }
  [[ "$ents" != *"network.client"* && "$ents" != *"home-relative-path"* ]] || { echo "Refused: the build may reach the network or the owner's folders" >&2; exit 1; }
  mkdir -p "$shots"
  rtl=()
  [[ "$lang" == fa* ]] && rtl=(-AppleTextDirection YES -NSForceRightToLeftWritingDirection YES)
  # A new name for each picture, so an older one is never taken for it.
  fresh="$shots/shot-$$-$RANDOM.png"
  "$app/Contents/MacOS/LinumicOS" -AppleLanguages "($lang)" "${rtl[@]}" -LCCAppearance "$look" -LCCWindowSize "$size" \
    -LCCShowMenuBar NO -LCCProductsSample 1 -LCCSnapshot "$fresh" "$@" >"$shots/last.log" 2>&1 &
  pid=$!
  # The app quits itself after its picture; it is stopped if it has not after 40 seconds.
  for _ in {1..40}; do kill -0 $pid 2>/dev/null || break; sleep 1; done
  kill $pid 2>/dev/null || true
  wait $pid 2>/dev/null || true
  [[ -f "$fresh" ]] || { echo "No picture was written for $out" >&2; exit 1; }
  mv "$fresh" "$out"
  ;;
*)
  sed -n 2,4p "$0" >&2
  exit 2
  ;;
esac

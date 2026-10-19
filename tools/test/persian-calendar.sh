#!/bin/zsh
# LinumicCore's tests with the Persian (Solar Hijri) calendar as the device's own calendar, as on the owner's Mac, which
# runs the app with fa_AF. On a Gregorian test host a day built with `Calendar.current` looks the same as a Gregorian
# one, so a `KeyDay`, a Desk or a Keys check that slipped back to the device's calendar still passes `swift test`
# there. This runs the same suite with `-AppleLocale en_US@calendar=persian` in the test process's own argument domain:
# the Persian calendar, with English text and Latin digits (the tests compare English strings). No preference on this
# Mac is read or changed.
#
#   tools/test/persian-calendar.sh                    # the whole suite
#   tools/test/persian-calendar.sh --filter KeyDay    # some of it
set -euo pipefail
cd "$(dirname "$0")/../../Packages/LinumicCore"
swift build --build-tests >/dev/null
bin=$(swift build --show-bin-path)
binary=$(print -l "$bin"/*.xctest/Contents/MacOS/*(N.x) | head -1)
[[ -n "$binary" ]] || { echo "No test bundle under $bin" >&2; exit 1; }
helper="$(dirname "$(xcrun --find swift)")/../libexec/swift/pm/swiftpm-testing-helper"
[[ -x "$helper" ]] || { echo "No swiftpm-testing-helper at $helper" >&2; exit 1; }
developer="$(xcode-select -p)/Platforms/MacOSX.platform/Developer"
DYLD_FRAMEWORK_PATH="$developer/Library/Frameworks" DYLD_LIBRARY_PATH="$developer/usr/lib" \
  "$helper" --test-bundle-path "$binary" --testing-library swift-testing "$binary" "$@" -AppleLocale "en_US@calendar=persian"

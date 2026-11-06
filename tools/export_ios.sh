#!/usr/bin/env bash
# Exports the iOS Xcode project from Linux (Godot "export project only").
# The Linux VPS cannot compile, sign or upload an iOS app: open the result on
# a Mac with Xcode (see docs/IOS_BUILD.md).
#
#   IOS_TEAM_ID=ABCDE12345 tools/export_ios.sh
#
# Output: build/ios/CitySwing.xcodeproj + sources, zipped to build/CitySwing-ios-xcode.zip
set -euo pipefail
cd "$(dirname "$0")/.."
team="${IOS_TEAM_ID:-}"
if [[ -z "$team" ]]; then
  team="PLACEHOLDR"
  echo "WARNING: IOS_TEAM_ID not set – using placeholder team '$team'."
  echo "         Set your team in Xcode > Signing & Capabilities before archiving."
fi
cp export_presets.cfg build/.export_presets.bak
trap 'cp build/.export_presets.bak export_presets.cfg' EXIT
sed -i "s/^application\/app_store_team_id=.*/application\/app_store_team_id=\"$team\"/" export_presets.cfg
rm -rf build/ios && mkdir -p build/ios
godot --headless --export-release "iOS" build/ios/CitySwing.ipa 2>&1 | grep -vE "^\s*$|reimport|\[ *[0-9]+% \]" || true
test -d build/ios/CitySwing.xcodeproj || { echo "iOS export FAILED: no Xcode project produced"; exit 1; }
(cd build && rm -f CitySwing-ios-xcode.zip && zip -qr CitySwing-ios-xcode.zip ios)
echo "iOS Xcode project: build/ios/CitySwing.xcodeproj  (zip: build/CitySwing-ios-xcode.zip)"

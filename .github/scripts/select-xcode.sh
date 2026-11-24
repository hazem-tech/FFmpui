#!/usr/bin/env bash
#
# select-xcode.sh — picks the newest Xcode on the runner.
#
# shrk supports only the latest macOS and iOS, and the project is saved by
# the latest Xcode (its LastUpgradeCheck: 2700 → Xcode 27). If the runner
# has no Xcode that new yet (GitHub adds new Xcodes months after release),
# the project in this CI checkout only is converted to what the runner's
# Xcode can read: an older project format and deployment targets lowered
# to the runner's SDKs. Nothing is committed; the step turns itself off as
# soon as the runner has the right Xcode.

set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
project="$root/shrk.xcodeproj/project.pbxproj"

xcode=$(find /Applications -maxdepth 1 -name 'Xcode*.app' | sort -V | tail -n1)
[ -n "$xcode" ] || { echo "::error::No Xcode on this runner"; exit 1; }
sudo xcode-select -s "$xcode"
xcodebuild -version

check=$(sed -n 's/.*LastUpgradeCheck = \([0-9]*\);.*/\1/p' "$project" | head -n1)
needed=$((10#${check:-0} / 100))
have=$(xcodebuild -version | sed -n 's/^Xcode \([0-9]*\).*/\1/p')
[ "$have" -lt "$needed" ] || exit 0

macos_sdk=$(xcrun --sdk macosx --show-sdk-version)
ios_sdk=$(xcrun --sdk iphoneos --show-sdk-version)
echo "::warning::This runner's newest Xcode is $have; the project needs Xcode $needed. Building with Xcode $have: project format and deployment targets lowered to macOS $macos_sdk / iOS $ios_sdk in this checkout only."
sed -i '' \
  -e 's/objectVersion = [0-9]*;/objectVersion = 77;/' \
  -e '/validationLevel = /d' \
  -e "s/MACOSX_DEPLOYMENT_TARGET = [0-9.]*;/MACOSX_DEPLOYMENT_TARGET = ${macos_sdk%%.*}.0;/" \
  -e "s/IPHONEOS_DEPLOYMENT_TARGET = [0-9.]*;/IPHONEOS_DEPLOYMENT_TARGET = ${ios_sdk%%.*}.0;/" \
  "$project"

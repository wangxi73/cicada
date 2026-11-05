#!/usr/bin/env bash
set -e
cd "$(dirname "$0")"
DEVICE_UDID="00008150-000E7DCA3400061C"
xcodebuild -project CicadaiOS.xcodeproj \
  -scheme CicadaiOS \
  -destination "generic/platform=iOS" \
  -configuration Debug \
  -derivedDataPath ./build \
  -allowProvisioningUpdates \
  build
xcrun devicectl device install app --device "${DEVICE_UDID}" "./build/Build/Products/Debug-iphoneos/CicadaiOS.app"

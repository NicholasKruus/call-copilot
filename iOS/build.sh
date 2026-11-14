#!/bin/zsh
# Builds the iPhone app. Needs Xcode 26 or later (with its iOS platform installed).
#
#   iOS/build.sh sim     build for the Simulator, install it on a booted (or the first available) iPhone simulator, open it
#   iOS/build.sh phone   build for your iPhone (connected by cable or on the same Wi-Fi) and install it
#
# For a phone, first put your team and a bundle ID prefix in iOS/Config/Signing.local.xcconfig (see Signing.xcconfig),
# sign in to Xcode with your Apple account (Xcode → Settings → Accounts), and turn on Developer Mode on the iPhone.
set -euo pipefail
cd "${0:A:h}/.."
if [[ -z "${DEVELOPER_DIR:-}" && "$(xcode-select -p)" == *CommandLineTools* ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
OUT=build.noindex/ios
target=${1:-sim}
prefix=$(xcodebuild -project CallCopilot.xcodeproj -target CallCopilot -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ PRODUCT_BUNDLE_IDENTIFIER =/ {print $2; exit}')

case $target in
  sim)
    xcodebuild -project CallCopilot.xcodeproj -scheme CallCopilot -configuration Debug \
      -destination 'generic/platform=iOS Simulator' -derivedDataPath $OUT -quiet build
    app=$OUT/Build/Products/Debug-iphonesimulator/CallCopilot.app
    udid=$(xcrun simctl list devices booted | awk -F'[()]' '/iPhone/ {print $2; exit}')
    if [[ -z $udid ]]; then
      udid=$(xcrun simctl list devices available | awk -F'[()]' '/iPhone/ {print $2; exit}')
      xcrun simctl boot $udid
    fi
    open -a Simulator
    xcrun simctl install $udid $app
    xcrun simctl launch $udid $prefix
    echo "installed on simulator $udid"
    ;;
  phone)
    xcodebuild -project CallCopilot.xcodeproj -scheme CallCopilot -configuration Debug \
      -destination 'generic/platform=iOS' -derivedDataPath $OUT -allowProvisioningUpdates -quiet build
    app=$OUT/Build/Products/Debug-iphoneos/CallCopilot.app
    json=$(mktemp)
    xcrun devicectl list devices --json-output $json >/dev/null 2>&1 || true
    device=$(/usr/bin/python3 -c 'import json,sys
d = json.load(open(sys.argv[1])).get("result", {}).get("devices", [])
print(next((x["identifier"] for x in d if x.get("hardwareProperties", {}).get("deviceType") == "iPhone"), ""))' $json)
    rm -f $json
    [[ -n $device ]] || { echo "No iPhone found. Connect it, unlock it and tap Trust."; exit 1; }
    xcrun devicectl device install app --device $device $app
    echo "installed on $device; open Call Copilot on the iPhone"
    ;;
  *) echo "usage: iOS/build.sh sim|phone"; exit 2 ;;
esac

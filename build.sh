#!/bin/zsh
# Builds "Call Copilot.app" into build.noindex/ (the suffix keeps Spotlight from offering a second copy). With --install, also replaces ~/Applications/Call Copilot.app and opens it.
# Ad-hoc signed: macOS asks for mic and system-audio permission again after each new build is installed.
set -euo pipefail
cd "${0:A:h}"
APP="build.noindex/Call Copilot.app"
[[ -e build.noindex ]] && /usr/bin/trash build.noindex
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 -target arm64-apple-macos26.0 Sources/*.swift Shared/*.swift -o "$APP/Contents/MacOS/CallCopilot"
cp Resources/Info.plist "$APP/Contents/"
cp Shared/prompt.txt Shared/default-settings.json "$APP/Contents/Resources/"
# Hardened runtime: blocks injected libraries and debugger attachment, so other code can't borrow the app's
# microphone and system-audio permissions from inside it.
codesign --force --options runtime --entitlements Resources/entitlements.plist --sign - "$APP"
echo "built $APP"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x CallCopilot 2>/dev/null && sleep 1 || true
  mkdir -p ~/Applications
  [[ -e ~/Applications/"Call Copilot.app" ]] && /usr/bin/trash ~/Applications/"Call Copilot.app"
  ditto "$APP" ~/Applications/"Call Copilot.app"
  open ~/Applications/"Call Copilot.app"
  echo "installed and opened ~/Applications/Call Copilot.app"
fi

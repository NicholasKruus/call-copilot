#!/bin/zsh
# Builds and runs the Mac harness for the iPhone app's Claude side. See main.swift for the modes.
set -euo pipefail
cd "${0:A:h}/../.."
mkdir -p build.noindex
swiftc -swift-version 5 -target arm64-apple-macos26.0 Shared/*.swift iOS/Engine/*.swift iOS/Harness/main.swift \
  -o build.noindex/engine-harness 2>&1 | grep -E "error|warning: unre" || true
exec build.noindex/engine-harness "$@"

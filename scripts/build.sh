#!/bin/bash
# Builds Also.app into ./build, for Apple Silicon Macs.
# Needs Apple's Command Line Tools (xcode-select --install) or Xcode.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-1.0}"
APP="build/Also.app"

# If xcode-select points at a removed Xcode, fall back to the Command Line Tools
if ! xcrun --find swiftc >/dev/null 2>&1 && [ -d /Library/Developer/CommandLineTools ]; then
  export DEVELOPER_DIR=/Library/Developer/CommandLineTools
fi
if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "Swift compiler not found. Install Apple's Command Line Tools with: xcode-select --install" >&2
  exit 1
fi

echo "Building Also ${VERSION}..."
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

xcrun swiftc -O -target arm64-apple-macos12.0 Sources/main.swift -o "$APP/Contents/MacOS/Also"

sed "s/__VERSION__/$VERSION/g" Resources/Info.plist > "$APP/Contents/Info.plist"
cp Resources/Also.icns "$APP/Contents/Resources/Also.icns"

codesign --force --sign - "$APP"
echo "Built $APP"

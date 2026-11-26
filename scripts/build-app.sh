#!/bin/sh
# Builds build/DictationMac.app for the host architecture with an ad-hoc signature.
set -eu
cd "$(dirname "$0")/.."

config=${CONFIGURATION:-release}
app=build/DictationMac.app

swift build -c "$config" --product DictationMac
bin=$(swift build -c "$config" --show-bin-path)

rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$bin/DictationMac" "$app/Contents/MacOS/DictationMac"
cp Bundle/Info.plist "$app/Contents/Info.plist"

plutil -lint "$app/Contents/Info.plist"
for key in CFBundleIdentifier LSUIElement NSMicrophoneUsageDescription; do
  plutil -extract "$key" raw "$app/Contents/Info.plist" >/dev/null
done
codesign --force --sign - "$app"
codesign --verify --strict "$app"
lipo -archs "$app/Contents/MacOS/DictationMac"
echo "$app"

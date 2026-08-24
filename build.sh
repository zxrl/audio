#!/bin/zsh
set -euo pipefail

SOURCE_DIR="${0:A:h}"
BUILD_DIR="$SOURCE_DIR/.build"
APP="$SOURCE_DIR/dist/audio.app"
MACOS_VERSION="${MACOS_DEPLOYMENT_TARGET:-13.0}"

rm -rf "$BUILD_DIR" "$APP"
mkdir -p "$BUILD_DIR" "$APP/Contents/MacOS" "$APP/Contents/Resources/bin"

frameworks=(
  -framework AppKit
  -framework AVFoundation
  -framework CoreAudio
  -framework MediaPlayer
  -framework ServiceManagement
)
sources=(
  "$SOURCE_DIR/ShuffleBag.swift"
  "$SOURCE_DIR/audio.swift"
)

for architecture in arm64 x86_64; do
  xcrun swiftc \
    -target "$architecture-apple-macosx$MACOS_VERSION" \
    -warnings-as-errors \
    -O \
    "${frameworks[@]}" \
    -o "$BUILD_DIR/audio-$architecture" \
    "${sources[@]}"
done

lipo -create \
  "$BUILD_DIR/audio-arm64" \
  "$BUILD_DIR/audio-x86_64" \
  -output "$APP/Contents/MacOS/audio"
install -m 644 "$SOURCE_DIR/Info.plist" "$APP/Contents/Info.plist"
install -m 755 "$SOURCE_DIR/bin/audio" "$APP/Contents/Resources/bin/audio"

identity="${CODE_SIGN_IDENTITY:--}"
if [[ "${DISTRIBUTION:-0}" == "1" ]]; then
  codesign \
    --force \
    --deep \
    --options runtime \
    --timestamp \
    --sign "$identity" \
    "$APP"
else
  codesign --force --deep --timestamp=none --sign "$identity" "$APP"
fi

codesign --verify --deep --strict --verbose=2 "$APP"
print -- "$APP"

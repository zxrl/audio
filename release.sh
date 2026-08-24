#!/bin/zsh
set -euo pipefail

SOURCE_DIR="${0:A:h}"
: "${DEVELOPER_ID_APPLICATION:?set DEVELOPER_ID_APPLICATION to a Developer ID Application identity}"
: "${NOTARY_PROFILE:?set NOTARY_PROFILE to a notarytool keychain profile}"

DISTRIBUTION=1 \
CODE_SIGN_IDENTITY="$DEVELOPER_ID_APPLICATION" \
  "$SOURCE_DIR/build.sh"

version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SOURCE_DIR/Info.plist")
app="$SOURCE_DIR/dist/audio.app"
archive="$SOURCE_DIR/dist/audio-$version-macos.zip"

rm -f "$archive"
ditto -c -k --keepParent "$app" "$archive"
xcrun notarytool submit "$archive" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$app"
xcrun stapler validate "$app"

rm -f "$archive"
ditto -c -k --keepParent "$app" "$archive"
spctl --assess --type execute --verbose=2 "$app"
print -- "$archive"

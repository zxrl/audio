#!/bin/zsh
set -euo pipefail

SOURCE_DIR="${0:A:h}"
APPLICATIONS_DIR="$HOME/Applications"
BIN_DIR="$HOME/.local/bin"
APP="$APPLICATIONS_DIR/audio.app"
STAGED_APP="$APPLICATIONS_DIR/.audio.app.installing"
CLI="$BIN_DIR/audio"

[[ ! -e "$APP" ]] || {
  print -u2 -- "audio is already installed: $APP"
  exit 1
}
[[ ! -e "$STAGED_APP" ]] || {
  print -u2 -- "remove the incomplete install first: $STAGED_APP"
  exit 1
}
[[ ! -e "$CLI" ]] || {
  print -u2 -- "audio cli already exists: $CLI"
  exit 1
}

"$SOURCE_DIR/build.sh"
mkdir -p "$APPLICATIONS_DIR" "$BIN_DIR"
ditto "$SOURCE_DIR/dist/audio.app" "$STAGED_APP"
xattr -cr "$STAGED_APP"
codesign --force --deep --timestamp=none --sign - "$STAGED_APP"
codesign --verify --deep --strict --verbose=2 "$STAGED_APP"
mv "$STAGED_APP" "$APP"
ln -s "$APP/Contents/Resources/bin/audio" "$CLI"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "$APP"
open -g -a "$APP"

print -- "$APP"

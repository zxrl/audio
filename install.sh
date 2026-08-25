#!/bin/zsh
set -euo pipefail

SOURCE_DIR="${0:A:h}"
APPLICATIONS_DIR="$HOME/Applications"
BIN_DIR="$HOME/.local/bin"
APP="$APPLICATIONS_DIR/audio.app"
STAGED_APP="$APPLICATIONS_DIR/.audio.app.installing"
REPLACED_APP="$APPLICATIONS_DIR/.audio.app.replaced"
CLI="$BIN_DIR/audio"
APP_EXECUTABLE="$APP/Contents/MacOS/audio"
CLI_TARGET="$APP/Contents/Resources/bin/audio"

[[ ! -e "$STAGED_APP" ]] || {
  print -u2 -- "remove the incomplete install first: $STAGED_APP"
  exit 1
}
[[ ! -e "$REPLACED_APP" ]] || {
  print -u2 -- "remove the incomplete replacement first: $REPLACED_APP"
  exit 1
}
if [[ -e "$CLI" || -L "$CLI" ]]; then
  [[ -L "$CLI" && "$(readlink "$CLI")" == "$CLI_TARGET" ]] || {
    print -u2 -- "audio cli path is already in use: $CLI"
    exit 1
  }
fi

stop_installed_app() {
  local pids
  pids="$(pgrep -f -x "$APP_EXECUTABLE" || true)"
  for pid in ${(f)pids}; do
    kill "$pid"
  done

  for attempt in {1..30}; do
    pgrep -f -x "$APP_EXECUTABLE" >/dev/null || return 0
    sleep 0.1
  done

  print -u2 -- "audio did not stop: $APP_EXECUTABLE"
  return 1
}

wait_for_installed_app() {
  for attempt in {1..30}; do
    pgrep -f -x "$APP_EXECUTABLE" >/dev/null && return 0
    sleep 0.1
  done

  print -u2 -- "audio did not launch: $APP_EXECUTABLE"
  return 1
}

"$SOURCE_DIR/build.sh"
mkdir -p "$APPLICATIONS_DIR" "$BIN_DIR"
ditto "$SOURCE_DIR/dist/audio.app" "$STAGED_APP"
xattr -cr "$STAGED_APP"
codesign --force --deep --timestamp=none --sign - "$STAGED_APP"
codesign --verify --deep --strict --verbose=2 "$STAGED_APP"

if [[ -e "$APP" ]]; then
  stop_installed_app
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -u "$APP"
  mv "$APP" "$REPLACED_APP"
fi

mv "$STAGED_APP" "$APP"
[[ ! -L "$CLI" ]] || unlink "$CLI"
ln -s "$CLI_TARGET" "$CLI"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "$APP"
open -g -a "$APP"
wait_for_installed_app

[[ ! -e "$REPLACED_APP" ]] || rm -rf "$REPLACED_APP"

print -- "$APP"

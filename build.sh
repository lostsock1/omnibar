#!/bin/sh
# Build OmniBar.app with swiftc (no Xcode project) and run it from /Applications.
#   ./build.sh            build, install, start now and at every login (LaunchAgent)
#   ./build.sh build      only build build/OmniBar.app
#   ./build.sh uninstall  stop it, remove the app and the LaunchAgent
# APPS_DIR=~/Applications ./build.sh installs somewhere else (e.g. without admin rights).
set -eu
cd "$(dirname "$0")"

LABEL=local.omnibar
DEST="${APPS_DIR:-/Applications}/OmniBar.app"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"

stop() {
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  i=0
  while launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
}

if [ "${1:-}" = uninstall ]; then
  stop
  rm -f "$AGENT"
  rm -rf "$DEST"
  echo "OmniBar removed. The token stays in the keychain: security delete-generic-password -s omniroute-bar"
  exit 0
fi

APP=build/OmniBar.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
swiftc -O -swift-version 5 -target arm64-apple-macos14.0 main.swift -o "$APP/Contents/MacOS/OmniBar"
codesign --force --sign - "$APP"
echo "built $APP"
[ "${1:-}" = build ] && exit 0

mkdir -p "$(dirname "$DEST")" "$HOME/Library/LaunchAgents"
[ -w "$(dirname "$DEST")" ] || { echo "can't write to $(dirname "$DEST"); try APPS_DIR=\$HOME/Applications" >&2; exit 1; }
stop
rm -rf "$DEST"
cp -R "$APP" "$DEST"
cat > "$AGENT" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>$LABEL</string>
	<key>ProgramArguments</key><array><string>$DEST/Contents/MacOS/OmniBar</string></array>
	<key>RunAtLoad</key><true/>
	<key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
	<key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
EOF
launchctl bootstrap "$DOMAIN" "$AGENT"
echo "OmniBar running from $DEST (starts at login; Quit in its menu stops it until next login)"

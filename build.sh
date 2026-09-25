#!/bin/zsh
# Build "oMLX Widget.app" — no Xcode required, just Command Line Tools.
#
#   ./build.sh                     -> builds to ~/AI/apps/oMLX Widget.app
#   OMLX_WIDGET_APP=/path/X.app ./build.sh
set -euo pipefail
cd "$(dirname "$0")"

APP="${OMLX_WIDGET_APP:-$HOME/AI/apps/oMLX Widget.app}"
VERSION="1.1"
# Stamped into the bundle so the in-app updater knows what it is running.
COMMIT="$(git rev-parse HEAD 2>/dev/null || echo unknown)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>            <string>oMLX Widget</string>
  <key>CFBundleDisplayName</key>     <string>oMLX Widget</string>
  <key>CFBundleIdentifier</key>      <string>ai.omlx.widget</string>
  <key>CFBundleExecutable</key>      <string>OMLXWidget</string>
  <key>CFBundlePackageType</key>     <string>APPL</string>
  <key>CFBundleShortVersionString</key> <string>${VERSION}</string>
  <key>CFBundleVersion</key>         <string>${VERSION}</string>
  <key>OMLXWidgetCommit</key>        <string>${COMMIT}</string>
  <key>CFBundleIconFile</key>        <string>AppIcon</string>
  <key>CFBundleIconName</key>        <string>AppIcon</string>
  <key>LSMinimumSystemVersion</key>  <string>14.0</string>
  <key>NSHighResolutionCapable</key> <true/>
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsLocalNetworking</key> <true/>
  </dict>
</dict>
</plist>
PLIST

echo "compiling…"
swiftc -O \
  -framework AppKit -framework WebKit \
  -o "$APP/Contents/MacOS/OMLXWidget" \
  Sources/main.swift 2>&1 | grep -v "^$" || true

if [[ ! -x "$APP/Contents/MacOS/OMLXWidget" ]]; then
  echo "BUILD FAILED" >&2; exit 1
fi

cp Resources/index.html "$APP/Contents/Resources/index.html"
cp Resources/hermes.py  "$APP/Contents/Resources/hermes.py"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --deep -s - "$APP" 2>/dev/null || echo "(ad-hoc signing skipped)"
echo "built: $APP  (commit ${COMMIT:0:7})"

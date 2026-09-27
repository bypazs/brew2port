#!/bin/bash
# Builds PortCat.app from source. Needs Xcode or the Command Line Tools.
#
#   ./build-app.sh             build for this Mac
#   ./build-app.sh --install   build and copy to /Applications
#   ./build-app.sh --universal build for Intel + Apple Silicon (needs full Xcode)
set -euo pipefail
cd "$(dirname "$0")"

VERSION="0.3.0"
BUNDLE_ID="io.github.brew2port.portcat"
INSTALL=0
ARCH_ARGS=()
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    --universal) ARCH_ARGS=(--arch arm64 --arch x86_64) ;;
    *) echo "Unknown option: $arg"; exit 1 ;;
  esac
done

echo "==> Building PortCat (release)…"
swift build -c release ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"}
BIN="$(swift build -c release ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"} --show-bin-path)/PortCat"

APP="build/PortCat.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/PortCat"

# Bundle brew2port.sh so the app's "Move my Homebrew packages…" button works.
if [ -f ../brew2port.sh ]; then
  cp ../brew2port.sh "$APP/Contents/Resources/brew2port.sh"
  chmod +x "$APP/Contents/Resources/brew2port.sh"
else
  echo "! ../brew2port.sh not found; the Homebrew migration button will be disabled"
fi

cat >"$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>PortCat</string>
  <key>CFBundleDisplayName</key><string>PortCat</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleExecutable</key><string>PortCat</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict>
</plist>
EOF

# Ad-hoc signature so macOS runs it locally (not notarized).
codesign --force --deep --sign - "$APP" >/dev/null
echo "✔ Built $APP"

if [ "$INSTALL" -eq 1 ]; then
  pkill -x PortCat 2>/dev/null || true
  rm -rf "/Applications/PortCat.app"
  cp -R "$APP" /Applications/
  echo "✔ Installed to /Applications/PortCat.app"
  open /Applications/PortCat.app
else
  echo "Run it with:  open $APP"
fi

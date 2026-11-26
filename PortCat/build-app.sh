#!/bin/bash
# Builds PortCat.app from source. Needs Xcode or the Command Line Tools.
#
#   ./build-app.sh             build for this Mac
#   ./build-app.sh --install   build and copy to /Applications
#   ./build-app.sh --universal build for Intel + Apple Silicon (needs full Xcode)
#
# If SwiftPM is broken on your Mac, the script falls back to compiling with swiftc.
# Force that with:  PORTCAT_USE_SWIFTC=1 ./build-app.sh
set -euo pipefail
cd "$(dirname "$0")"

VERSION="0.4.1"
BUNDLE_ID="io.github.brew2port.portcat"
INSTALL=0
UNIVERSAL=0
ARCH_ARGS=()
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    --universal) UNIVERSAL=1; ARCH_ARGS=(--arch arm64 --arch x86_64) ;;
    *) echo "Unknown option: $arg"; exit 1 ;;
  esac
done

# Plain swiftc build, used when SwiftPM itself is broken (for example a damaged
# Command Line Tools install that fails with "Invalid manifest ... PackageDescription").
# The app has no dependencies, so compiling the sources directly works the same.
build_with_swiftc() {
  case "$(uname -m)" in
    arm64) target="arm64-apple-macos13.0" ;;
    *)     target="x86_64-apple-macos13.0" ;;
  esac
  mkdir -p build
  # `|| return 1`: set -e is off inside a function called from `if`, so check by hand.
  swiftc -O -parse-as-library -target "$target" Sources/PortCat/*.swift -o build/PortCat-swiftc || return 1
  BIN="build/PortCat-swiftc"
}

echo "==> Building PortCat (release)…"
if [ "${PORTCAT_USE_SWIFTC:-0}" = "1" ]; then
  if [ "$UNIVERSAL" = 1 ]; then
    echo "✘ --universal can't be combined with PORTCAT_USE_SWIFTC=1 (it needs SwiftPM)."
    exit 1
  fi
  echo "    (PORTCAT_USE_SWIFTC=1, compiling with swiftc directly)"
  build_with_swiftc || exit 1
elif swift build -c release ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"}; then
  BIN="$(swift build -c release ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"} --show-bin-path)/PortCat"
else
  echo ""
  echo "! swift build failed. If the error above mentions \"Invalid manifest\" or"
  echo "  \"PackageDescription\", your Command Line Tools install is probably damaged."
  echo "  Trying a direct swiftc build instead…"
  if [ "$UNIVERSAL" = 1 ]; then
    echo "✘ --universal needs a working SwiftPM. Reinstall the Command Line Tools:"
    echo "    sudo rm -rf /Library/Developer/CommandLineTools && xcode-select --install"
    exit 1
  fi
  if ! build_with_swiftc; then
    echo "✘ The direct build failed too. Reinstall the Command Line Tools, then run this again:"
    echo "    sudo rm -rf /Library/Developer/CommandLineTools && xcode-select --install"
    exit 1
  fi
  echo "✔ Built with swiftc (SwiftPM was not usable on this Mac)"
fi

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

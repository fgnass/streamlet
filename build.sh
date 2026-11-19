#!/bin/zsh
# Builds Streamlet.app into ./build
#   ./build.sh           build for this Mac
#   ./build.sh install   also copy it to ~/Applications
#   ./build.sh release   also write build/Streamlet.zip (Apple silicon) for a GitHub release
set -euo pipefail
cd "${0:A:h}"
MODE="${1:-}"

# The release is for Apple silicon only. Other builds are for the Mac they are built on,
# so the app also runs on an Intel Mac when it is built there. STREAMLET_ARCH overrides both.
if [[ "$MODE" == release ]]; then
  ARCH="${STREAMLET_ARCH:-arm64}"
else
  ARCH="${STREAMLET_ARCH:-$(uname -m)}"
fi
swift build -c release --arch "$ARCH"
BIN="$(swift build -c release --arch "$ARCH" --show-bin-path)/Streamlet"

APP=build/Streamlet.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Streamlet"
cp Streamlet/Info.plist "$APP/Contents/"
cp Streamlet/Assets/AppIcon.icns "$APP/Contents/Resources/"
cp Streamlet/Assets/ChooserIcon.png Streamlet/Assets/DockTile.png "$APP/Contents/Resources/"
cp -R Streamlet/Assets/IconAnimation "$APP/Contents/Resources/"
# Licenses of the third-party packages that are linked into the app
mkdir -p "$APP/Contents/Resources/ThirdPartyLicenses"
cp THIRD_PARTY_LICENSES.md "$APP/Contents/Resources/ThirdPartyLicenses/"

# Signing: STREAMLET_SIGN_IDENTITY (for example a Developer ID), otherwise the local
# "Streamlet Local Signing" certificate if it exists, otherwise ad hoc.
IDENTITY="${STREAMLET_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  if security find-identity -p codesigning 2>/dev/null | grep -q "Streamlet Local Signing"; then
    IDENTITY="Streamlet Local Signing"
  else
    IDENTITY="-"
  fi
fi
codesign --force --sign "$IDENTITY" --identifier com.fgnass.streamlet "$APP"
echo "Built $APP (signed: $IDENTITY)"

if [[ "$MODE" == install ]]; then
  DEST="$HOME/Applications/Streamlet.app"
  osascript -e 'tell application id "com.fgnass.streamlet" to quit' 2>/dev/null || true
  mkdir -p "$HOME/Applications"
  rm -rf "$DEST"
  cp -R "$APP" "$DEST"
  echo "Installed to $DEST"
fi

if [[ "$MODE" == release ]]; then
  [[ "$(lipo -archs "$APP/Contents/MacOS/Streamlet")" == arm64 ]] || { echo "The release must be arm64" >&2; exit 1; }
  [[ "$IDENTITY" == "-" ]] && echo "Note: ad hoc signature. The app is not notarized; install it with install.sh (curl sets no quarantine flag)."
  rm -f build/Streamlet.zip
  ditto -c -k --keepParent "$APP" build/Streamlet.zip
  echo "Wrote build/Streamlet.zip"
fi

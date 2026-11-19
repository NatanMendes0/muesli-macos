#!/bin/bash
# Builds Muesli.app.
#
# Prefers SwiftPM (`swift build`). If SwiftPM is broken — some Command Line
# Tools installs ship a mismatched llbuild/SDK — falls back to invoking swiftc
# directly, which works because Muesli has zero package dependencies.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
BIN=""

pick_sdk() {
  # Newest SDK the compiler actually understands; xcrun sometimes points at a
  # newer SDK than the installed compiler (mismatched CLT halves).
  local sdkdir="/Library/Developer/CommandLineTools/SDKs"
  for candidate in "$sdkdir/MacOSX.sdk" "$sdkdir"/MacOSX15*.sdk "$sdkdir"/MacOSX14*.sdk; do
    if [ -d "$candidate" ]; then
      echo "$candidate"
      return
    fi
  done
  xcrun --sdk macosx --show-sdk-path
}

if swift build -c "$CONFIG" 2>/dev/null; then
  BIN=".build/$CONFIG/Muesli"
else
  echo "SwiftPM unavailable — compiling with swiftc directly"
  SDK="$(pick_sdk)"
  echo "Using SDK: $SDK"
  mkdir -p build
  OPT="-O"
  [ "$CONFIG" = "debug" ] && OPT="-Onone"
  # shellcheck disable=SC2046
  SDKROOT="$SDK" swiftc \
    -parse-as-library \
    "$OPT" \
    -target arm64-apple-macosx14.0 \
    -o build/Muesli-bin \
    $(find Sources/Muesli -name '*.swift' | sort)
  BIN="build/Muesli-bin"
fi

APP="build/Muesli.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Muesli"
cp Support/Info.plist "$APP/Contents/Info.plist"
if [ -f Support/AppIcon.icns ]; then
  cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

# Prefer a real local signing identity so Keychain ACLs and TCC permissions
# (Microphone, Screen & System Audio) survive across rebuilds/updates instead
# of breaking on every new ad-hoc CDHash. Falls back to ad-hoc in CI.
SIGN_IDENTITY="${MUESLI_SIGN_IDENTITY:-}"
if [ -z "$SIGN_IDENTITY" ]; then
  IDENTITIES="$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null || true)"
  SIGN_IDENTITY="$(printf '%s\n' "$IDENTITIES" | /usr/bin/sed -nE 's/.*"(Developer ID Application:[^"]+)".*/\1/p' | /usr/bin/head -n 1 || true)"
  if [ -z "$SIGN_IDENTITY" ]; then
    SIGN_IDENTITY="$(printf '%s\n' "$IDENTITIES" | /usr/bin/sed -nE 's/.*"(Apple Development:[^"]+)".*/\1/p' | /usr/bin/head -n 1 || true)"
  fi
fi

if [ -n "$SIGN_IDENTITY" ]; then
  echo "Signing with: $SIGN_IDENTITY"
  /usr/bin/codesign --force --sign "$SIGN_IDENTITY" --identifier app.muesli.Muesli "$APP"
else
  /usr/bin/codesign --force --sign - --identifier app.muesli.Muesli "$APP" >/dev/null 2>&1
fi

echo "Built $APP"

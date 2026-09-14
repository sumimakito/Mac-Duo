#!/usr/bin/env bash
#
# Builds Mac Duo.app from the SwiftPM package.
#
#   ./build.sh            build and sign
#   ./build.sh --run      build, sign, and relaunch the app
#   ./build.sh --universal  build for Apple Silicon and Intel
#   ./build.sh --dmg        package build/Mac-Duo.dmg
#
# Uses ad-hoc signing by default. macOS may require Screen Recording permission
# again after rebuilding. Set SIGN_IDENTITY to use your own signing identity.

set -euo pipefail
cd "$(dirname "$0")"

SIGN_IDENTITY="${SIGN_IDENTITY:--}"
APP_NAME="Mac Duo"
BUNDLE="build/${APP_NAME}.app"
DMG_PATH="build/Mac-Duo.dmg"

BUILD_ARGS=(-c release)
RUN_APP=false
CREATE_DMG=false
for argument in "$@"; do
  case "$argument" in
    --universal) BUILD_ARGS+=(--arch arm64 --arch x86_64) ;;
    --dmg) CREATE_DMG=true ;;
    --run) RUN_APP=true ;;
    *) echo "Unknown argument: $argument" >&2; exit 1 ;;
  esac
done

swift build "${BUILD_ARGS[@]}" --product MacDuo
swift build "${BUILD_ARGS[@]}" --product lidprobe

BIN_PATH="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"
BINARY="$BIN_PATH/MacDuo"
PROBE="$BIN_PATH/lidprobe"

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BINARY" "$BUNDLE/Contents/MacOS/MacDuo"
# SwiftPM resolves Bundle.module relative to the application bundle.
cp -R "$BIN_PATH/MacDuo_MacDuo.bundle" "$BUNDLE/Contents/Resources/"
cp Resources/Info.plist "$BUNDLE/Contents/Info.plist"
cp LICENSE NOTICE "$BUNDLE/Contents/Resources/"
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$BUNDLE/Contents/Resources/AppIcon.icns"
fi
cp "$PROBE" build/lidprobe

TIMESTAMP=--timestamp
if [[ "$SIGN_IDENTITY" == - ]]; then
  TIMESTAMP=--timestamp=none
fi
codesign --force --options runtime "$TIMESTAMP" \
  --sign "$SIGN_IDENTITY" "$BUNDLE"
codesign --verify --strict --verbose=1 "$BUNDLE"

echo "built ${BUNDLE}"
codesign -dv "$BUNDLE" 2>&1 | grep -E "Identifier|TeamIdentifier|Signature" || true

if "$CREATE_DMG"; then
  echo "Packaging DMG: ${DMG_PATH}..."
  rm -f "$DMG_PATH"
  STAGING="$(mktemp -d "${TMPDIR:-/tmp}/dmg-staging.XXXXXX")"
  ditto "$BUNDLE" "$STAGING/${APP_NAME}.app"
  ln -s /Applications "$STAGING/Applications"
  hdiutil create -volname "${APP_NAME}" -srcfolder "$STAGING" \
    -fs HFS+ -format UDZO "$DMG_PATH" >/dev/null
  rm -rf "$STAGING"
  if [[ "$SIGN_IDENTITY" != - ]]; then
    codesign --force --sign "$SIGN_IDENTITY" "$DMG_PATH" 2>/dev/null || true
  fi
  echo "Created ${DMG_PATH}"
fi

if "$RUN_APP"; then
  pkill -x MacDuo 2>/dev/null || true
  sleep 0.5
  open "$BUNDLE"
  echo "launched"
fi

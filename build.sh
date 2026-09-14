#!/usr/bin/env bash
#
# Builds Mac Duo.app from the SwiftPM package.
#
#   ./build.sh            build and sign
#   ./build.sh --run      build, sign, and relaunch the app
#   ./build.sh --universal  build for Apple Silicon and Intel
#
# Uses ad-hoc signing by default. macOS may require Screen Recording permission
# again after rebuilding. Set SIGN_IDENTITY to use your own signing identity.

set -euo pipefail
cd "$(dirname "$0")"

if [ -z "${SDKROOT:-}" ]; then
  if [ -d "/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk" ]; then
    export SDKROOT="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
  fi
fi

SIGN_IDENTITY="${SIGN_IDENTITY:--}"
APP_NAME="Mac Duo"
BUNDLE="build/${APP_NAME}.app"

BUILD_ARGS=(-c release)
RUN_APP=false
for argument in "$@"; do
  case "$argument" in
    --universal) BUILD_ARGS+=(--arch arm64 --arch x86_64) ;;
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

if "$RUN_APP"; then
  BUNDLE_REALPATH="$(cd "$BUNDLE" 2>/dev/null && pwd -P || echo "$PWD/$BUNDLE")"
  TARGET_BIN="$BUNDLE_REALPATH/Contents/MacOS/MacDuo"

  # Terminate only processes executing from the local workspace build bundle
  for pid in $(pgrep -x MacDuo 2>/dev/null || true); do
    proc_cmd="$(ps -p "$pid" -o command= 2>/dev/null || true)"
    if [[ "$proc_cmd" == *"$TARGET_BIN"* ]] || [[ "$proc_cmd" == *"$BUNDLE_REALPATH"* ]] || [[ "$proc_cmd" == *"$PWD/build/"* ]] || [[ "$proc_cmd" == *"$PWD/.build/"* ]]; then
      echo "Stopping previous development instance (PID $pid)..."
      kill -TERM "$pid" 2>/dev/null || true
      for _ in {1..10}; do
        if ! kill -0 "$pid" 2>/dev/null; then break; fi
        sleep 0.1
      done
      kill -KILL "$pid" 2>/dev/null || true
    fi
  done

  sleep 0.2
  open "$BUNDLE"
  echo "launched"
fi

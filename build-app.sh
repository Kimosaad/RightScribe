#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h}"
OUTPUT_DIR="$PROJECT_DIR/outputs"
APP_DIR="$OUTPUT_DIR/RightScribe.app"
BUILD_DIR="$PROJECT_DIR/work/release-build"
ICON_SOURCE="$PROJECT_DIR/Resources/AppIcon.png"
ICONSET_DIR="$PROJECT_DIR/work/RightScribe.iconset"
MODULE_CACHE="$PROJECT_DIR/work/swift-cache"
SWIFTPM_CACHE="$PROJECT_DIR/work/swiftpm-cache"
SIGNING_IDENTITY="${RIGHTSCRIBE_SIGNING_IDENTITY:-Apple Development: Karim Saad (8TR97M3XW8)}"

cd "$PROJECT_DIR"
mkdir -p "$MODULE_CACHE" "$SWIFTPM_CACHE"
CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" \
SWIFTPM_MODULECACHE_OVERRIDE="$SWIFTPM_CACHE" \
swift build -c release --arch arm64 --scratch-path "$BUILD_DIR"

if ! security find-identity -v -p codesigning | grep -Fq "\"$SIGNING_IDENTITY\""; then
  echo "A stable signing identity is required: $SIGNING_IDENTITY" >&2
  echo "Set RIGHTSCRIBE_SIGNING_IDENTITY to another installed Apple Development identity." >&2
  exit 1
fi

# A running process keeps the previous executable in memory after a rebuild.
# Stop only the copy launched from this bundle before replacing it.
RUNNING_PIDS=("${(@f)$(pgrep -f "^$APP_DIR/Contents/MacOS/RightScribe$" || true)}")
for app_pid in "${RUNNING_PIDS[@]}"; do
  if [[ -n "$app_pid" ]]; then
    kill "$app_pid"
  fi
done

mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BUILD_DIR/arm64-apple-macosx/release/RightScribe" "$APP_DIR/Contents/MacOS/RightScribe"
cp "AppBundle/Info.plist" "$APP_DIR/Contents/Info.plist"

mkdir -p "$ICONSET_DIR"
sips -z 16 16 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_16x16.png" >/dev/null
sips -z 32 32 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_32x32.png" >/dev/null
sips -z 64 64 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_128x128.png" >/dev/null
sips -z 256 256 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_256x256.png" >/dev/null
sips -z 512 512 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_512x512.png" >/dev/null
cp "$ICON_SOURCE" "$ICONSET_DIR/icon_512x512@2x.png"
iconutil -c icns "$ICONSET_DIR" -o "$APP_DIR/Contents/Resources/AppIcon.icns"

codesign --force --deep --sign "$SIGNING_IDENTITY" --timestamp=none "$APP_DIR"

echo "$APP_DIR"

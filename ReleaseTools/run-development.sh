#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(/usr/bin/jq -er '.version' "$ROOT/Sources/LumaWall/Resources/ReleaseNotes.json")"
BUILD="$(/usr/bin/jq -er '.build' "$ROOT/Sources/LumaWall/Resources/ReleaseNotes.json")"
cd "$ROOT"

swift build -c debug
BIN_DIR="$(swift build -c debug --show-bin-path)"
EXECUTABLE="$BIN_DIR/Aster"
APP="$ROOT/.build/development/Aster.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
FRAMEWORKS="$CONTENTS/Frameworks"
RESOURCES="$CONTENTS/Resources"
INFO="$CONTENTS/Info.plist"
IDENTITY="${ASTER_DEVELOPMENT_IDENTITY:-$(
    /usr/bin/security find-identity -v -p codesigning \
        | /usr/bin/sed -n 's/.*"\(Apple Development:[^"]*\)"/\1/p' \
        | /usr/bin/head -1
)}"

rm -rf "$CONTENTS"
mkdir -p "$MACOS" "$FRAMEWORKS" "$RESOURCES"
cp "$EXECUTABLE" "$MACOS/Aster"
cp "$BIN_DIR/libAsterScreenSaver.dylib" "$FRAMEWORKS/libAsterScreenSaver.dylib"
cp -R "$BIN_DIR/Aster_Aster.bundle" "$RESOURCES/Aster_Aster.bundle"

plutil -create xml1 "$INFO"
plutil -insert CFBundleDevelopmentRegion -string en "$INFO"
plutil -insert CFBundleExecutable -string Aster "$INFO"
plutil -insert CFBundleIdentifier -string app.aster.Aster "$INFO"
plutil -insert CFBundleInfoDictionaryVersion -string 6.0 "$INFO"
plutil -insert CFBundleName -string Aster "$INFO"
plutil -insert CFBundleDisplayName -string Aster "$INFO"
plutil -insert CFBundleIconFile -string Aster.icns "$INFO"
plutil -insert CFBundlePackageType -string APPL "$INFO"
plutil -insert CFBundleShortVersionString -string "$VERSION" "$INFO"
plutil -insert CFBundleVersion -string "$BUILD" "$INFO"
plutil -insert LSMinimumSystemVersion -string 14.0 "$INFO"
plutil -insert LSArchitecturePriority -json '["arm64"]' "$INFO"
plutil -insert LSMultipleInstancesProhibited -bool true "$INFO"
plutil -insert NSHighResolutionCapable -bool true "$INFO"
plutil -insert NSAppleEventsUsageDescription -string "Aster uses automation only after you enable controls for Music, Spotify, Reminders, Finder, or System Events." "$INFO"

ICONSET="$ROOT/.build/development/Aster.iconset"
ICON_SOURCE_DIR="$ROOT/.build/development/icon-source"
rm -rf "$ICONSET" "$ICON_SOURCE_DIR"
mkdir -p "$ICONSET" "$ICON_SOURCE_DIR"
ICON_SOURCE="$ICON_SOURCE_DIR/AsterIcon.png"
sips -s format png "$ROOT/Sources/LumaWall/Resources/AsterIcon.svg" --out "$ICON_SOURCE" >/dev/null
for specification in \
    "16 icon_16x16.png" "32 icon_16x16@2x.png" \
    "32 icon_32x32.png" "64 icon_32x32@2x.png" \
    "128 icon_128x128.png" "256 icon_128x128@2x.png" \
    "256 icon_256x256.png" "512 icon_256x256@2x.png" \
    "512 icon_512x512.png" "1024 icon_512x512@2x.png"; do
    size="${specification%% *}"
    filename="${specification#* }"
    sips -z "$size" "$size" "$ICON_SOURCE" --out "$ICONSET/$filename" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$RESOURCES/Aster.icns"
rm -rf "$ICONSET" "$ICON_SOURCE_DIR"

if [[ -n "$IDENTITY" ]]; then
    /usr/bin/codesign \
        --force \
        --options runtime \
        --timestamp=none \
        --sign "$IDENTITY" \
        "$FRAMEWORKS/libAsterScreenSaver.dylib"
    /usr/bin/codesign \
        --force \
        --options runtime \
        --timestamp=none \
        --entitlements "$ROOT/ReleaseTools/Aster.entitlements" \
        --sign "$IDENTITY" \
        "$APP"
else
    print -u2 "Warning: no Apple Development signing identity was found; macOS may ask for permissions again after rebuilding."
    /usr/bin/codesign --force --sign - "$FRAMEWORKS/libAsterScreenSaver.dylib"
    /usr/bin/codesign \
        --force \
        --entitlements "$ROOT/ReleaseTools/Aster.entitlements" \
        --sign - \
        "$APP"
fi

exec /usr/bin/open -n -W "$APP"

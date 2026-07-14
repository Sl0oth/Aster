#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${ASTER_VERSION:-1.0.0-beta.1}"
BUILD="${ASTER_BUILD:-1}"
FEED_URL="${ASTER_UPDATE_FEED_URL:-}"
PUBLIC_KEY="${ASTER_UPDATE_PUBLIC_KEY:-}"
SIGNING_IDENTITY="${ASTER_CODESIGN_IDENTITY:-}"
NOTARY_PROFILE="${ASTER_NOTARY_PROFILE:-}"
RELEASE_MODE="${ASTER_RELEASE_MODE:-production}"
APP="$ROOT/dist/Aster.app"
DMG="$ROOT/dist/Aster-$VERSION.dmg"
ICONSET="$ROOT/dist/Aster.iconset"
DMG_STAGE="$ROOT/dist/dmg-stage"
ENTITLEMENTS="$ROOT/ReleaseTools/Aster.entitlements"

if [[ "$RELEASE_MODE" != production && "$RELEASE_MODE" != test ]]; then
    print -u2 "ASTER_RELEASE_MODE must be 'production' or 'test'."
    exit 1
fi
if [[ -z "$FEED_URL" || "$FEED_URL" != https://* ]]; then
    print -u2 "ASTER_UPDATE_FEED_URL must be an HTTPS URL for the signed update feed."
    exit 1
fi
if [[ "$RELEASE_MODE" == production && "$FEED_URL" == *example* ||
      "$RELEASE_MODE" == production && "$FEED_URL" == *.invalid* ||
      "$RELEASE_MODE" == production && "$FEED_URL" == *localhost* ]]; then
    print -u2 "Production releases require the real published update-feed URL."
    exit 1
fi
KEY_LENGTH="$(print -rn -- "$PUBLIC_KEY" | base64 -D 2>/dev/null | wc -c | tr -d ' ')"
if [[ "$KEY_LENGTH" != 32 ]]; then
    print -u2 "ASTER_UPDATE_PUBLIC_KEY must contain the base64 Ed25519 release public key."
    exit 1
fi
if [[ "$RELEASE_MODE" == production ]]; then
    [[ -n "$SIGNING_IDENTITY" ]] || { print -u2 "Production releases require ASTER_CODESIGN_IDENTITY."; exit 1; }
    [[ -n "$NOTARY_PROFILE" ]] || { print -u2 "Production releases require ASTER_NOTARY_PROFILE."; exit 1; }
fi
if [[ "$(uname -m)" != arm64 ]]; then
    print -u2 "Aster currently ships for Apple silicon and must be built on an Apple-silicon Mac."
    exit 1
fi

NOTES_VERSION="$(/usr/bin/jq -er '.version' "$ROOT/Sources/LumaWall/Resources/ReleaseNotes.json")"
if [[ "$NOTES_VERSION" != "$VERSION" ]]; then
    print -u2 "ReleaseNotes.json is for $NOTES_VERSION, but ASTER_VERSION is $VERSION."
    exit 1
fi

cd "$ROOT"
swift build -c release

rm -rf "$APP" "$DMG" "$ICONSET" "$DMG_STAGE"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources" "$ROOT/dist"
cp "$ROOT/.build/release/Aster" "$APP/Contents/MacOS/Aster"
cp "$ROOT/.build/release/libAsterScreenSaver.dylib" "$APP/Contents/Frameworks/libAsterScreenSaver.dylib"
cp -R "$ROOT/.build/release/Aster_Aster.bundle" "$APP/Contents/Resources/Aster_Aster.bundle"

INFO="$APP/Contents/Info.plist"
plutil -create xml1 "$INFO"
plutil -insert CFBundleDevelopmentRegion -string en "$INFO"
plutil -insert CFBundleExecutable -string Aster "$INFO"
plutil -insert CFBundleIdentifier -string app.aster.Aster "$INFO"
plutil -insert CFBundleInfoDictionaryVersion -string 6.0 "$INFO"
plutil -insert CFBundleName -string Aster "$INFO"
plutil -insert CFBundleDisplayName -string Aster "$INFO"
plutil -insert CFBundleIconFile -string Aster "$INFO"
plutil -insert CFBundlePackageType -string APPL "$INFO"
plutil -insert CFBundleShortVersionString -string "$VERSION" "$INFO"
plutil -insert CFBundleVersion -string "$BUILD" "$INFO"
plutil -insert LSMinimumSystemVersion -string 14.0 "$INFO"
plutil -insert LSArchitecturePriority -json '["arm64"]' "$INFO"
plutil -insert NSHighResolutionCapable -bool true "$INFO"
plutil -insert NSAppleEventsUsageDescription -string "Aster uses automation only when you enable controls for Music, Spotify, Reminders, Finder, or System Events." "$INFO"
plutil -insert AsterUpdateFeedURL -string "$FEED_URL" "$INFO"
plutil -insert AsterUpdatePublicKey -string "$PUBLIC_KEY" "$INFO"

mkdir -p "$ICONSET" "$ROOT/dist/icon-source"
qlmanage -t -s 1024 -o "$ROOT/dist/icon-source" "$ROOT/Sources/LumaWall/Resources/AsterIcon.svg" >/dev/null 2>&1
ICON_SOURCE="$ROOT/dist/icon-source/AsterIcon.svg.png"
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
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Aster.icns"
rm -rf "$ICONSET" "$ROOT/dist/icon-source"

if [[ "$RELEASE_MODE" == production ]]; then
    codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" \
        "$APP/Contents/Frameworks/libAsterScreenSaver.dylib"
    codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS" \
        --sign "$SIGNING_IDENTITY" "$APP"
else
    print -u2 "Creating an ad-hoc test artifact; it must never be published."
    codesign --force --sign - "$APP/Contents/Frameworks/libAsterScreenSaver.dylib"
    codesign --force --entitlements "$ENTITLEMENTS" --sign - "$APP"
fi
"$ROOT/ReleaseTools/verify-release.sh" "$APP"

mkdir -p "$DMG_STAGE"
cp -R "$APP" "$DMG_STAGE/Aster.app"
ln -s /Applications "$DMG_STAGE/Applications"
hdiutil create -volname Aster -srcfolder "$DMG_STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$DMG_STAGE"

if [[ "$RELEASE_MODE" == production ]]; then
    codesign --force --timestamp --sign "$SIGNING_IDENTITY" "$DMG"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
else
    codesign --force --sign - "$DMG"
fi

HASH="$(shasum -a 256 "$DMG" | awk '{print $1}')"
print "Built: $DMG"
print "SHA-256: $HASH"
if [[ "$RELEASE_MODE" == test ]]; then
    print "TEST ARTIFACT ONLY — rebuild in production mode before publishing."
fi

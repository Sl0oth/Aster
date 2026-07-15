#!/bin/zsh
set -euo pipefail

APP="${1:?Usage: verify-release.sh /path/to/Aster.app}"
INFO="$APP/Contents/Info.plist"
MODULE="$APP/Contents/Frameworks/libAsterScreenSaver.dylib"

[[ -x "$APP/Contents/MacOS/Aster" ]] || { print -u2 "Missing Aster executable"; exit 1; }
[[ -f "$MODULE" ]] || { print -u2 "Missing Aster screen-saver module"; exit 1; }
[[ -d "$APP/Contents/Resources/Aster_Aster.bundle" ]] || { print -u2 "Missing resource bundle"; exit 1; }
[[ -f "$APP/Contents/Resources/Aster.icns" ]] || { print -u2 "Missing application icon"; exit 1; }
/usr/bin/plutil -lint "$INFO" >/dev/null
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO")" == app.aster.Aster ]] || {
    print -u2 "Unexpected application bundle identifier"
    exit 1
}
[[ "$(/usr/libexec/PlistBuddy -c 'Print :LSMultipleInstancesProhibited' "$INFO")" == true ]] || {
    print -u2 "Aster must prohibit accidental duplicate application instances"
    exit 1
}
[[ "$(/usr/libexec/PlistBuddy -c 'Print :AsterUpdateFeedURL' "$INFO")" == https://* ]] || {
    print -u2 "Missing secure update feed URL"
    exit 1
}
[[ -n "$(/usr/libexec/PlistBuddy -c 'Print :AsterUpdatePublicKey' "$INFO")" ]] || {
    print -u2 "Missing update signing public key"
    exit 1
}
[[ -n "$(/usr/libexec/PlistBuddy -c 'Print :NSAppleEventsUsageDescription' "$INFO")" ]] || {
    print -u2 "Missing Apple Events usage description"
    exit 1
}
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"
[[ "$(/usr/bin/lipo -archs "$APP/Contents/MacOS/Aster")" == arm64 ]] || {
    print -u2 "Release executable must contain only the supported arm64 architecture"
    exit 1
}
print "Verified release bundle: $APP"

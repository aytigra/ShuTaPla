#!/bin/bash
#
# release.sh — build a signed, notarized, stapled Apple-Silicon DMG of Shutapla and (optionally)
# publish it as a GitHub Release asset.
#
# Usage:
#   Scripts/release.sh                  # archive → export → verify → notarize → staple → dmg → gate
#   Scripts/release.sh --skip-notarize  # build + sign + dmg only (local verification before creds)
#   Scripts/release.sh --publish        # also upload the dmg as a GitHub Release asset (gh)
#
# Prerequisites (see doc/releasing.md):
#   - Xcode, plus "Developer ID Application: Tigran Airapetian (JU443A4L25)" in the keychain.
#   - Homebrew mpv installed — bundle-mpv.sh embeds its dylib closure at build time.
#   - Notary keychain profile "ShuTaPla-notary" — required unless --skip-notarize.
#   - gh CLI authenticated — required only for --publish.

set -euo pipefail

TEAM_ID="JU443A4L25"
SCHEME="ShuTaPla"
IDENTITY="Developer ID Application: Tigran Airapetian ($TEAM_ID)"
NOTARY_PROFILE="ShuTaPla-notary"

SKIP_NOTARIZE=0
PUBLISH=0
for arg in "$@"; do
    case "$arg" in
        --skip-notarize) SKIP_NOTARIZE=1 ;;
        --publish)       PUBLISH=1 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

cd "$(dirname "$0")/.."          # repo root
BUILD="$PWD/build"
ARCHIVE="$BUILD/ShuTaPla.xcarchive"
EXPORT_DIR="$BUILD/export"

rm -rf "$ARCHIVE" "$EXPORT_DIR"
mkdir -p "$BUILD"

echo "==> Archiving (Release)…"
xcodebuild archive \
    -project ShuTaPla.xcodeproj \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE" \
    DEVELOPMENT_TEAM="$TEAM_ID"

echo "==> Exporting Developer ID app…"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist Scripts/ExportOptions.plist

APP="$(echo "$EXPORT_DIR"/*.app)"
[ -d "$APP" ] || { echo "error: exported app not found in $EXPORT_DIR" >&2; exit 1; }
APP_NAME="$(basename "$APP" .app)"          # user-facing product name, e.g. "Shutapla"
EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="$BUILD/$APP_NAME-$VERSION.dmg"

echo "==> Verifying signature and dylib paths…"
codesign --verify --deep --strict --verbose=2 "$APP"
# The whole point of bundle-mpv.sh: nothing may still reference the Homebrew keg.
LEAKS="$(
    { otool -L "$APP/Contents/MacOS/$EXECUTABLE"; \
      for d in "$APP"/Contents/Frameworks/*.dylib; do otool -L "$d"; done; } \
    | grep -E '/opt/homebrew|/usr/local' || true )"
if [ -n "$LEAKS" ]; then
    echo "error: Homebrew paths leaked into the bundle:" >&2
    echo "$LEAKS" >&2
    exit 1
fi

if [ "$SKIP_NOTARIZE" = "0" ]; then
    echo "==> Notarizing app…"
    ZIP="$BUILD/$APP_NAME-$VERSION.zip"
    ditto -c -k --keepParent "$APP" "$ZIP"
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    rm -f "$ZIP"
    echo "==> Stapling app…"
    xcrun stapler staple "$APP"     # embeds the ticket so the app passes Gatekeeper offline
else
    echo "==> Skipping notarization (--skip-notarize)."
fi

echo "==> Building DMG…"
rm -f "$DMG"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"
codesign --force --sign "$IDENTITY" "$DMG"

if [ "$SKIP_NOTARIZE" = "0" ]; then
    echo "==> Notarizing + stapling DMG…"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"     # stapling a dmg requires it to have been notarized
    echo "==> Final gate…"
    spctl -a -vvv "$APP"
    stapler validate "$DMG"
fi

echo "==> Done: $DMG"

if [ "$PUBLISH" = "1" ]; then
    echo "==> Publishing GitHub release v$VERSION…"
    gh release create "v$VERSION" "$DMG" \
        --title "$APP_NAME $VERSION" \
        --notes "Apple-Silicon build. Requires macOS 26+." \
    || gh release upload "v$VERSION" "$DMG" --clobber
fi

#!/bin/zsh
# Builds a Release app, signs it with Developer ID, optionally notarizes it, packages a DMG and
# optionally copies it into the beardfm.app site checkout as the free download.
#
# Usage:  Tools/release.sh [--notarize] [--upload]
#   --notarize   uses the notarytool keychain profile in $NOTARY_PROFILE (default "ipodpromax-notary",
#                the team-wide profile shared with Stephen's other apps). Create one with:
#                xcrun notarytool store-credentials <name> --apple-id you@example.com --team-id J9228F689B
#   --upload     (requires --notarize) copies the DMG into the beardfm.app site as
#                downloads/Music-Touch-<version>.dmg and downloads/Music-Touch.dmg, signs it for Sparkle
#                with the EdDSA key in the keychain (account "musictouch") and adds the release to
#                site/static/music-touch/appcast.xml, with release-notes/<version>.html as the notes when
#                present. Commit and push the site afterwards; Cloudflare builds and deploys from main.
#
# Output: dist/Music Touch <version>.dmg
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
SITE="${BEARDFM_SITE:-$HOME/Movies/Apps/beardfm.app}"
NOTARIZE=0
UPLOAD=0
for arg in "$@"; do
  case "$arg" in
    --notarize) NOTARIZE=1 ;;
    --upload) UPLOAD=1 ;;
    *) echo "Unknown option: $arg"; exit 1 ;;
  esac
done
[[ $UPLOAD -eq 1 && $NOTARIZE -eq 0 ]] && { echo "--upload requires --notarize so users never get an unnotarized build."; exit 1; }
NOTARY_PROFILE="${NOTARY_PROFILE:-ipodpromax-notary}"

BUILD="$ROOT/build/release"
DIST="$ROOT/dist"
rm -rf "$BUILD"
mkdir -p "$BUILD" "$DIST"

echo "▶ Building Release…"
xcodebuild -project "Music Touch.xcodeproj" -scheme "Music Touch" -configuration Release \
  -destination 'platform=macOS' -derivedDataPath "$BUILD/DerivedData" build \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_ALLOWED=YES 2>&1 | grep -E "error:|BUILD" || true

APP="$BUILD/DerivedData/Build/Products/Release/Music Touch.app"
[[ -d "$APP" ]] || { echo "Build failed: app not found"; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
BUILDNUM=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$APP/Contents/Info.plist")
echo "▶ Version $VERSION ($BUILDNUM)"

DEVID=$(security find-identity -v -p codesigning | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"' || true)
[[ -n "$DEVID" ]] || { echo "No Developer ID Application certificate found in the keychain."; exit 1; }
echo "▶ Signing with $DEVID"
# No entitlements: the direct build is unsandboxed and needs no hardened-runtime exceptions.
# Sparkle's nested components are signed inside-out first; a Developer ID app may not contain
# anything signed by someone else, and notarization checks every executable.
sign() { codesign --force --options runtime --timestamp --sign "$DEVID" "$@"; }
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
if [[ -d "$SPARKLE" ]]; then
  sign "$SPARKLE/Versions/B/XPCServices/Installer.xpc"
  sign --preserve-metadata=entitlements "$SPARKLE/Versions/B/XPCServices/Downloader.xpc"
  sign "$SPARKLE/Versions/B/Autoupdate"
  sign "$SPARKLE/Versions/B/Updater.app"
  sign "$SPARKLE"
fi
sign "$APP"
codesign --verify --strict --deep --verbose=2 "$APP"

if [[ $NOTARIZE -eq 1 ]]; then
  echo "▶ Notarizing app…"
  ZIP="$BUILD/app.zip"
  ditto -c -k --keepParent "$APP" "$ZIP"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
fi

echo "▶ Packaging DMG…"
STAGE="$BUILD/dmg"
rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
DMG="$DIST/Music Touch $VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "Music Touch" -srcfolder "$STAGE" -ov -format UDZO -imagekey zlib-level=9 "$DMG" > /dev/null
codesign --force --timestamp --sign "$DEVID" "$DMG"
if [[ $NOTARIZE -eq 1 ]]; then
  echo "▶ Notarizing DMG…"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
fi

if [[ $UPLOAD -eq 1 ]]; then
  [[ -d "$SITE/site/static" ]] || { echo "beardfm.app site not found at $SITE (set BEARDFM_SITE)."; exit 1; }
  echo "▶ Copying into beardfm.app…"
  mkdir -p "$SITE/site/static/downloads"
  UPDATE_NAME="Music-Touch-$VERSION.dmg"
  cp "$DMG" "$SITE/site/static/downloads/$UPDATE_NAME"
  cp "$DMG" "$SITE/site/static/downloads/Music-Touch.dmg"

  echo "▶ Signing for Sparkle and updating the appcast…"
  SPARKLE_BIN=$(find "$BUILD/DerivedData/SourcePackages/artifacts" -type d -name bin -path "*parkle*" | head -1)
  [[ -n "$SPARKLE_BIN" ]] || { echo "Sparkle tools not found under DerivedData."; exit 1; }
  SIGNATURE=$("$SPARKLE_BIN/sign_update" --account musictouch "$DMG")
  MIN_MACOS=$(/usr/libexec/PlistBuddy -c "Print LSMinimumSystemVersion" "$APP/Contents/Info.plist")
  NOTES=()
  [[ -f "$ROOT/release-notes/$VERSION.html" ]] && NOTES=("$ROOT/release-notes/$VERSION.html")
  "$ROOT/Tools/update-appcast.py" "$SITE/site/static/music-touch/appcast.xml" "$VERSION" "$BUILDNUM" "$MIN_MACOS" \
    "https://beardfm.app/downloads/$UPDATE_NAME" "$SIGNATURE" "${NOTES[@]}"
  echo "▶ Copied. Commit and push the beardfm.app changes to publish."
fi

ls -la "$DMG"
echo "✔ Done: $DMG"

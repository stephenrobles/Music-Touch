#!/bin/zsh
# Archives the sandboxed Mac App Store build of Music Touch and uploads it to App Store Connect.
# Usage: Tools/archive-appstore.sh          (run only when Stephen asks for an upload)
#
# xcodebuild on this Mac cannot provision through Xcode's signed-in account, so the archive is built
# unsigned, ad-hoc signed with the App Store entitlements (App Sandbox), and exported with the
# App Store Connect API key, which handles signing and the upload.
set -euo pipefail
cd "$(dirname "$0")/.."
KEY=~/.appstoreconnect/private_keys/AuthKey_Z5YD293RLM.p8
AUTH=(-allowProvisioningUpdates -authenticationKeyPath "$KEY" -authenticationKeyID Z5YD293RLM -authenticationKeyIssuerID 69a6de84-dcf8-47e3-e053-5b8c7c11a4d1)
ARCHIVE="build/archives/MusicTouch.xcarchive"
mkdir -p build/archives
rm -rf "$ARCHIVE" build/upload

echo "== archive (sandboxed)"
xcodebuild -project "Music Touch.xcodeproj" -scheme "Music Touch" -configuration Release -destination "generic/platform=macOS" \
  -archivePath "$ARCHIVE" -derivedDataPath build/dd-archive \
  CODE_SIGNING_ALLOWED=NO ENABLE_APP_SANDBOX=YES CODE_SIGN_ENTITLEMENTS=Config/MusicTouch-AppStore.entitlements archive 2>&1 | grep -E "error:|ARCHIVE" | sort -u
codesign --force -s - --entitlements Config/MusicTouch-AppStore.entitlements "$ARCHIVE/Products/Applications/Music Touch.app"

echo "== export and upload"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist Config/ExportOptions.plist \
  -exportPath build/upload "${AUTH[@]}" 2>&1 | grep -iE "error|EXPORT|Upload succeeded|failed|invalid" | sort -u

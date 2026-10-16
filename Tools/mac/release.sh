#!/bin/bash
# Ships the macOS app: Developer ID archive → notarize → zip → appcast →
# https://www.experiments.cwandt.com/spoon/mac (Sparkle feed) + GitHub release.
# Bump MARKETING_VERSION in project.yml first; release notes = the commit subject.
set -euo pipefail
cd "$(dirname "$0")/../.."

VERSION=$(awk '/MARKETING_VERSION/ {print $2; exit}' project.yml)
OUT=build/mac-release
ZIP="Spoon-$VERSION-macOS.zip"
SITE="$OUT/site"   # ponytail: every past zip stays here so generate_appcast can emit deltas; prune by hand if it grows
BIN=build/dd/SourcePackages/artifacts/sparkle/Sparkle/bin

xcodegen generate -q
xcodebuild archive -project "Spoon Email.xcodeproj" -scheme "Spoon Email" \
  -destination 'generic/platform=macOS' -archivePath "$OUT/Spoon.xcarchive" \
  -derivedDataPath build/dd -allowProvisioningUpdates | grep -E "error:|ARCHIVE"
rm -rf "$OUT/export"
xcodebuild -exportArchive -archivePath "$OUT/Spoon.xcarchive" \
  -exportPath "$OUT/export" -exportOptionsPlist Tools/mac/exportOptions.plist \
  -allowProvisioningUpdates | grep -E "error|EXPORT"

APP="$OUT/export/Spoon Email.app"
mkdir -p "$SITE"
ditto -c -k --keepParent "$APP" "$SITE/$ZIP"
xcrun notarytool submit "$SITE/$ZIP" --keychain-profile notary --wait | grep -E "status|id:" | head -3
xcrun stapler staple "$APP" >/dev/null
rm "$SITE/$ZIP" && ditto -c -k --keepParent "$APP" "$SITE/$ZIP"   # re-zip with the ticket stapled

"$BIN/generate_appcast" --download-url-prefix https://www.experiments.cwandt.com/spoon/mac/ \
  --link https://github.com/cheewee2000/Spoon-Email/releases "$SITE"
rsync -az --delete "$SITE/" cwandt@vps52023.dreamhostps.com:~/experiments.cwandt.com/spoon/mac/

gh release create "v$VERSION" "$SITE/$ZIP" --title "Spoon $VERSION" \
  --notes "$(git log -1 --pretty=%s)"$'\n\nDownload the zip, unzip, drag to Applications. Notarized; later versions arrive through Spoon → Check for Updates…'

rm -rf "/Applications/Spoon Email.app" && ditto "$APP" "/Applications/Spoon Email.app"
echo "Released v$VERSION"

#!/bin/bash
# Builds the ad-hoc .ipa and publishes the OTA install page to
# https://www.experiments.cwandt.com/spoon
set -euo pipefail
cd "$(dirname "$0")/../.."

VERSION=$(awk '/MARKETING_VERSION/ {print $2; exit}' project.yml)

xcodebuild archive -project "Spoon Email.xcodeproj" -scheme "Spoon Email" \
  -destination 'generic/platform=iOS' -archivePath build/ota/Spoon.xcarchive \
  -allowProvisioningUpdates | grep -E "error:|ARCHIVE"
xcodebuild -exportArchive -archivePath build/ota/Spoon.xcarchive \
  -exportPath build/ota/export -exportOptionsPlist Tools/ota/exportOptions.plist \
  -allowProvisioningUpdates | grep -E "error|EXPORT"

STAGE=build/ota/stage
rm -rf "$STAGE" && mkdir -p "$STAGE"
cp Tools/ota/site/* "$STAGE/"
cp "build/ota/export/Spoon Email.ipa" "$STAGE/SpoonEmail.ipa"
cp build/ota/export/manifest.plist "$STAGE/"
# Stamp the page with the version being shipped
sed -E -i '' "s/(id=\"version\">)[0-9.]+/\1$VERSION/; s/v[0-9]+\.[0-9]+\.[0-9]+/v$VERSION/" "$STAGE/index.html"

rsync -avz "$STAGE/" cwandt@vps52023.dreamhostps.com:~/experiments.cwandt.com/spoon/
echo "Published v$VERSION to https://www.experiments.cwandt.com/spoon"

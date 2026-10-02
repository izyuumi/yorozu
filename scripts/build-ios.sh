#!/bin/sh
# Archive the iOS app and hand it to TestFlight. The Mac counterpart is
# scripts/build-mac.sh; this one is shorter because Xcode does the parts that script has
# to do by hand — signing and packaging. The pinned ASC CLI owns the upload.
#
#   VERSION=0.2.0 BUILD=12345 ./scripts/build-ios.sh
#
# Signing is automatic (see apps/ios/Project.swift): given -allowProvisioningUpdates and
# an App Store Connect key, xcodebuild issues the distribution certificate and the App
# Store provisioning profile on its own, so there is no .p12 and no .mobileprovision to
# keep anywhere. The same key authenticates the ASC CLI's public build-upload API.
set -eu
cd "$(dirname "$0")/.."
. ./scripts/build-version.sh

DIST=${DIST:-dist}
TEAM_ID=${TEAM_ID:-AN5KM8QGEF}
ASC_KEY_ID=${ASC_KEY_ID:?ASC_KEY_ID is required}
ASC_ISSUER_ID=${ASC_ISSUER_ID:?ASC_ISSUER_ID is required}

# CI carries the key base64 in ASC_KEY_P8; xcodebuild only takes a path, so write it out
# at mode 600 and remove it however the script exits.
if [ -n "${ASC_KEY_P8:-}" ]; then
  ASC_KEY_PATH="$(mktemp -t "AuthKey_$ASC_KEY_ID")"
  chmod 600 "$ASC_KEY_PATH"
  printf '%s' "$ASC_KEY_P8" | base64 --decode > "$ASC_KEY_PATH"
  trap 'rm -f "$ASC_KEY_PATH"' EXIT INT TERM
fi
ASC_KEY_PATH=${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8}
# -authenticationKeyPath rejects a relative path.
case "$ASC_KEY_PATH" in /*) ;; *) ASC_KEY_PATH="$PWD/$ASC_KEY_PATH" ;; esac
command -v asc >/dev/null || { echo 'App Store Connect CLI is required (CI pins 5.9.0)' >&2; exit 1; }

ARCHIVE="$PWD/$DIST/YorozuIOS.xcarchive"
OPTIONS="$PWD/$DIST/export-options.plist"
mkdir -p "$DIST"

tuist generate --no-open --path apps/ios

cat > "$OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>export</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>uploadSymbols</key><true/>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict>
</plist>
PLIST

# env -u SDKROOT: a SDKROOT inherited from the shell points xcodebuild at the wrong SDK.
env -u SDKROOT xcodebuild archive \
  -workspace apps/ios/Yorozu.xcworkspace -scheme YorozuIOS \
  -skipPackagePluginValidation \
  -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$ASC_KEY_PATH" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
  YOROZU_VERSION_LABEL="$VERSION_LABEL"

env -u SDKROOT xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" -exportOptionsPlist "$OPTIONS" -exportPath "$DIST/export" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$ASC_KEY_PATH" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID"

set -- "$DIST/export"/*.ipa
if [ "$#" -ne 1 ] || [ ! -f "$1" ]; then
  echo 'expected exactly one exported iOS IPA' >&2
  exit 1
fi
shasum -a 256 "$1" > "$DIST/ios-sha256.txt"
ASC_TELEMETRY_DISABLED=1 asc --version > "$DIST/asc-version.txt"
ASC_TELEMETRY_DISABLED=1 ASC_BYPASS_KEYCHAIN=1 ASC_PRIVATE_KEY_PATH="$ASC_KEY_PATH" \
  asc builds upload --app "${ASC_APP_ID:-6811274963}" --ipa "$1" \
    --version "$VERSION" --build-number "$BUILD" --checksum --output json > "$DIST/ios-upload.json"

echo "uploaded $VERSION_LABEL as App Store version $VERSION ($BUILD) to TestFlight; it appears once processing finishes"

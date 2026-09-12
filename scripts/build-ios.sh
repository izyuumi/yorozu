#!/bin/sh
# Archive the iOS app and hand it to TestFlight. The Mac counterpart is
# scripts/build-mac.sh; this one is shorter because Xcode does the parts that script has
# to do by hand — signing, packaging, and the upload itself.
#
#   VERSION=0.1.0 ./scripts/build-ios.sh
#
# Signing is automatic (see apps/ios/Project.swift): given -allowProvisioningUpdates and
# an App Store Connect key, xcodebuild issues the distribution certificate and the App
# Store provisioning profile on its own, so there is no .p12 and no .mobileprovision to
# keep anywhere. The same key authenticates the upload, which is why the export options
# below say `destination: upload` rather than writing an .ipa for a second tool to send:
# one xcodebuild invocation, one credential, nothing on disk to leak.
set -eu
cd "$(dirname "$0")/.."

VERSION=${VERSION:-0.1.0}
# The build number has to rise with every upload and never repeat. The commit count does
# both, needs no file to bump, and is the same number on any checkout of that commit.
BUILD=${BUILD:-$(git rev-list --count HEAD)}
DIST=${DIST:-dist}
TEAM_ID=${TEAM_ID:-AN5KM8QGEF}
ASC_KEY_ID=${ASC_KEY_ID:?ASC_KEY_ID is required}
ASC_ISSUER_ID=${ASC_ISSUER_ID:?ASC_ISSUER_ID is required}

# CI carries the key base64 in ASC_KEY_P8; xcodebuild only takes a path, so write it out
# at mode 600 and remove it however the script exits.
if [ -n "${ASC_KEY_P8:-}" ]; then
  ASC_KEY_PATH="$(mktemp -t AuthKey_$ASC_KEY_ID)"
  chmod 600 "$ASC_KEY_PATH"
  printf '%s' "$ASC_KEY_P8" | base64 --decode > "$ASC_KEY_PATH"
  trap 'rm -f "$ASC_KEY_PATH"' EXIT INT TERM
fi
ASC_KEY_PATH=${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8}
# -authenticationKeyPath rejects a relative path.
case "$ASC_KEY_PATH" in /*) ;; *) ASC_KEY_PATH="$PWD/$ASC_KEY_PATH" ;; esac

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
  <key>destination</key><string>upload</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>uploadSymbols</key><true/>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict>
</plist>
PLIST

# env -u SDKROOT: a SDKROOT inherited from the shell points xcodebuild at the wrong SDK.
env -u SDKROOT xcodebuild archive \
  -workspace apps/ios/Yorozu.xcworkspace -scheme YorozuIOS \
  -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$ASC_KEY_PATH" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD"

env -u SDKROOT xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" -exportOptionsPlist "$OPTIONS" -exportPath "$DIST/export" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$ASC_KEY_PATH" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID"

echo "uploaded $VERSION ($BUILD) to TestFlight; it appears once processing finishes"

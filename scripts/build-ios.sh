#!/bin/sh
# Archive the iOS app and hand it to TestFlight. The Mac counterpart is
# scripts/build-mac.sh; this one is shorter because Xcode does the parts that script has
# to do by hand — signing, packaging, and the upload itself.
#
#   VERSION=0.2.0 BUILD=12345 ./scripts/build-ios.sh
#
# Signing is automatic (see apps/ios/Project.swift): given -allowProvisioningUpdates and
# an App Store Connect key, xcodebuild issues the distribution certificate and the App
# Store provisioning profile on its own, so there is no .p12 and no .mobileprovision to
# keep anywhere. The same key authenticates the upload, which is why the export options
# below say `destination: upload` rather than writing an .ipa for a second tool to send:
# one xcodebuild invocation, one credential, nothing on disk to leak.
set -eu
cd "$(dirname "$0")/.."
. ./scripts/build-version.sh

DIST=${DIST:-dist}
INTERNAL_ONLY=${INTERNAL_ONLY:-0}
case "$INTERNAL_ONLY" in 0|1) ;; *) echo 'INTERNAL_ONLY must be 0 or 1' >&2; exit 1 ;; esac
if [ "$INTERNAL_ONLY" = 1 ]; then
  [ "$VERSION" = 0.6.0 ] || { echo 'Internal builds require VERSION=0.6.0' >&2; exit 1; }
  export YOROZU_SECRETARY_ENABLED=1
fi
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

case "$DIST" in /*) ;; *) DIST="$PWD/$DIST" ;; esac
ARCHIVE="$DIST/YorozuIOS.xcarchive"
OPTIONS="$DIST/export-options.plist"
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

if [ "$INTERNAL_ONLY" = 1 ]; then
  # The upload itself is restricted by Apple, independently of group membership.
  /usr/libexec/PlistBuddy -c 'Add :testFlightInternalTestingOnly bool true' "$OPTIONS"
fi

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

if [ "$INTERNAL_ONLY" = 1 ]; then
  # Retain a signed IPA from the same archive. Xcode's upload export does not
  # promise to retain an IPA; the upload below still uses the internal-only flag.
  cp "$OPTIONS" "$DIST/ipa-export-options.plist"
  /usr/libexec/PlistBuddy -c 'Set :destination export' "$DIST/ipa-export-options.plist"
  env -u SDKROOT xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" -exportOptionsPlist "$DIST/ipa-export-options.plist" -exportPath "$DIST/ipa" \
    -allowProvisioningUpdates \
    -authenticationKeyPath "$ASC_KEY_PATH" \
    -authenticationKeyID "$ASC_KEY_ID" \
    -authenticationKeyIssuerID "$ASC_ISSUER_ID"
  set -- "$DIST"/ipa/*.ipa
  if [ "$#" != 1 ] || [ ! -f "$1" ]; then
    echo 'Expected one retained internal IPA' >&2; exit 1
  fi
fi

env -u SDKROOT xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" -exportOptionsPlist "$OPTIONS" -exportPath "$DIST/export" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$ASC_KEY_PATH" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID"

echo "uploaded $VERSION_LABEL as App Store version $VERSION ($BUILD) to TestFlight; it appears once processing finishes"

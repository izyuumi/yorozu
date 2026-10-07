#!/bin/sh
# Archives the iOS app and uploads it to TestFlight (internal testing only, see apps/ios/ExportOptions.plist).
#   scripts/upload_ios.sh --confirm
# The build number stays low (owner, 2026-10-08): the highest iOS build App Store Connect already has for THIS version,
# plus one, starting at 1. Apple wants ascending build numbers within a version and allows reuse across versions
# (TN2420). BUILD=<n> overrides it. An upload uses that number up for good, hence --confirm.
# Needs ASC_KEY_ID and ASC_ISSUER_ID, and ~/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8 (or ASC_KEY_PATH).
# Uses only sh, openssl, curl, jq and Xcode. Prints no key or token.
set -eu
cd "$(dirname "$0")/.."
if [ "${1:-}" != "--confirm" ]; then
    echo "Refusing to upload without --confirm: it archives, signs and uploads a TestFlight build, which cannot be undone." >&2
    exit 64
fi
: "${ASC_KEY_ID:?ASC_KEY_ID is required}" "${ASC_ISSUER_ID:?ASC_ISSUER_ID is required}"
KEY=${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8}
# -authenticationKeyPath rejects a relative path.
case "$KEY" in /*) ;; *) KEY="$PWD/$KEY" ;; esac
[ -r "$KEY" ] || { echo "Cannot read the App Store Connect key at $KEY" >&2; exit 1; }
APP_ID=6811274963
API=https://api.appstoreconnect.apple.com
VERSION=$(tr -d '[:space:]' < version.txt)
ARCHIVE="$PWD/build/ios/YorozuIOS.xcarchive"

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

# ES256 JWT for the App Store Connect API, valid 20 minutes. openssl signs in DER; JWS wants r||s, 32 bytes each.
jwt() {
    now=$(date +%s)
    header=$(printf '{"alg":"ES256","kid":"%s","typ":"JWT"}' "$ASC_KEY_ID" | b64url)
    claims=$(printf '{"iss":"%s","iat":%s,"exp":%s,"aud":"appstoreconnect-v1"}' "$ASC_ISSUER_ID" "$now" $((now + 1200)) | b64url)
    signature=$(printf '%s.%s' "$header" "$claims" | openssl dgst -sha256 -sign "$KEY" | openssl asn1parse -inform DER \
        | awk -F: '/INTEGER/ { s = $NF; while (length(s) < 64) s = "0" s; printf "%s", substr(s, length(s) - 63) }' \
        | xxd -r -p | b64url)
    printf '%s.%s.%s' "$header" "$claims" "$signature"
}

# GET, with the token handed to curl on stdin rather than in its arguments, where `ps` would show it.
asc_get() {
    printf 'header = "Authorization: Bearer %s"\n' "$(jwt)" | curl -fsS --config - "$1"
}

if [ -z "${BUILD:-}" ]; then
    url="$API/v1/builds?filter%5Bapp%5D=$APP_ID&filter%5BpreReleaseVersion.platform%5D=IOS&filter%5BpreReleaseVersion.version%5D=$VERSION&fields%5Bbuilds%5D=version&limit=200"
    max=0
    while [ -n "$url" ]; do
        page=$(asc_get "$url")
        top=$(printf '%s' "$page" | jq -er '[.data[].attributes.version | tonumber] | max // 0')
        if [ "$top" -gt "$max" ]; then max=$top; fi
        url=$(printf '%s' "$page" | jq -r '.links.next // empty')
    done
    BUILD=$((max + 1))
    # Builds stay low: a version that already holds a high build can't go back down, so bump version.txt instead.
    if [ "$BUILD" -ge 10000 ]; then
        echo "Version $VERSION already has build $max; builds must ascend within a version. Bump version.txt to keep builds low." >&2
        exit 65
    fi
fi
echo "Uploading Yorozu iOS $VERSION ($BUILD)"

mkdir -p build/ios
rm -rf "$ARCHIVE" build/ios/export
tuist generate --no-open --path apps/ios
# Version and build on the command line: Tuist caches the manifest, and the build number is not in it.
env -u SDKROOT xcodebuild archive -workspace apps/ios/Yorozu.xcworkspace -scheme YorozuIOS \
    -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" \
    -derivedDataPath .build/xcode-ios -clonedSourcePackagesDirPath .build/xcode-packages \
    -skipPackagePluginValidation -allowProvisioningUpdates \
    -authenticationKeyPath "$KEY" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD"
# destination=upload in ExportOptions.plist: this step is the upload.
env -u SDKROOT xcodebuild -exportArchive -archivePath "$ARCHIVE" \
    -exportOptionsPlist apps/ios/ExportOptions.plist -exportPath "$PWD/build/ios/export" \
    -allowProvisioningUpdates \
    -authenticationKeyPath "$KEY" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID"
echo "Uploaded Yorozu iOS $VERSION ($BUILD). It reaches the Internal TestFlight group once App Store Connect has processed it."

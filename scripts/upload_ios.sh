#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
if [ "${1:-}" != "--confirm" ]; then
    echo "Refusing to upload without --confirm: it archives, signs and uploads a TestFlight build, which cannot be undone." >&2
    exit 64
fi
: "${ASC_KEY_ID:?ASC_KEY_ID is required}" "${ASC_ISSUER_ID:?ASC_ISSUER_ID is required}"
KEY=${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8}
case "$KEY" in /*) ;; *) KEY="$PWD/$KEY" ;; esac
[ -r "$KEY" ] || { echo "Cannot read the App Store Connect key at $KEY" >&2; exit 1; }
APP_ID=6811274963
API=https://api.appstoreconnect.apple.com
VERSION=${VERSION:-$(scripts/version.sh)}
BASE=$(($(scripts/build-number.sh "$VERSION" 1) - 1))
ARCHIVE="$PWD/build/ios/YorozuIOS.xcarchive"

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

jwt() {
    now=$(date +%s)
    header=$(printf '{"alg":"ES256","kid":"%s","typ":"JWT"}' "$ASC_KEY_ID" | b64url)
    claims=$(printf '{"iss":"%s","iat":%s,"exp":%s,"aud":"appstoreconnect-v1"}' "$ASC_ISSUER_ID" "$now" $((now + 1200)) | b64url)
    signature=$(printf '%s.%s' "$header" "$claims" | openssl dgst -sha256 -sign "$KEY" | openssl asn1parse -inform DER \
        | awk -F: '/INTEGER/ { s = $NF; while (length(s) < 64) s = "0" s; printf "%s", substr(s, length(s) - 63) }' \
        | xxd -r -p | b64url)
    printf '%s.%s.%s' "$header" "$claims" "$signature"
}

asc_get() {
    printf 'header = "Authorization: Bearer %s"\n' "$(jwt)" | curl -fsS --config - "$1"
}

# asc_send <method> <url> <json>
asc_send() {
    printf 'header = "Authorization: Bearer %s"\nheader = "Content-Type: application/json"\n' "$(jwt)" \
        | curl -fsS --config - -X "$1" --data "$3" "$2"
}

# Prints the uploaded build's App Store Connect id once App Store Connect lists it, polling every 30 s for up to
# LIST_WAIT seconds (default 1800). The next upload numbers its build from that list, so until then a second merge
# would reuse this build's number; release-ios.yml runs one upload at a time, so waiting here closes that gap.
wait_listed() {
    url="$API/v1/builds?filter%5Bapp%5D=$APP_ID&filter%5Bversion%5D=$BUNDLE_VERSION&filter%5BpreReleaseVersion.version%5D=$VERSION&limit=1"
    tries=$((${LIST_WAIT:-1800} / 30))
    id=
    while [ "$tries" -gt 0 ]; do
        id=$(asc_get "$url" | jq -r '.data[0].id // empty') || id=
        [ -n "$id" ] && break
        tries=$((tries - 1))
        [ "$tries" -gt 0 ] && sleep 30
    done
    [ -n "$id" ] && printf '%s' "$id"
}

# What to Test on the uploaded build: the notes of the PRs merged since the last stable tag
# (scripts/release_notes.sh --plain). It is the build's own text, so it reaches only the groups that get the
# build: TestFlight's internal group. Nothing here adds the build to a group or submits it for Beta App Review.
set_whats_new() {
    text=$({ echo "Yorozu $VERSION ($BUILD), beta."; echo; scripts/release_notes.sh --plain HEAD; } | head -c 4000)
    locales=$(asc_get "$API/v1/builds/$BUILD_ID/betaBuildLocalizations?fields%5BbetaBuildLocalizations%5D=locale&limit=50") || return 1
    existing=$(printf '%s' "$locales" | jq -r '.data[].id')
    if [ -n "$existing" ]; then
        for loc in $existing; do
            asc_send PATCH "$API/v1/betaBuildLocalizations/$loc" "$(jq -n --arg id "$loc" --arg t "$text" \
                '{data: {type: "betaBuildLocalizations", id: $id, attributes: {whatsNew: $t}}}')" >/dev/null || return 1
        done
    else
        asc_send POST "$API/v1/betaBuildLocalizations" "$(jq -n --arg id "$BUILD_ID" --arg t "$text" \
            '{data: {type: "betaBuildLocalizations", attributes: {locale: "en-US", whatsNew: $t},
              relationships: {build: {data: {type: "builds", id: $id}}}}}')" >/dev/null || return 1
    fi
    printf 'What to Test on build %s:\n%s\n' "$BUNDLE_VERSION" "$text"
}

if [ -z "${BUILD:-}" ]; then
    url="$API/v1/builds?filter%5Bapp%5D=$APP_ID&filter%5BpreReleaseVersion.platform%5D=IOS&filter%5BpreReleaseVersion.version%5D=$VERSION&fields%5Bbuilds%5D=version&limit=200"
    max=0
    while [ -n "$url" ]; do
        page=$(asc_get "$url")
        top=$(printf '%s' "$page" | jq -er --argjson base "$BASE" \
            '[.data[].attributes.version | tonumber | if . > $base then . - $base else . end] | max // 0')
        if [ "$top" -gt "$max" ]; then max=$top; fi
        url=$(printf '%s' "$page" | jq -r '.links.next // empty')
    done
    BUILD=$((max + 1))
fi
BUNDLE_VERSION=$(scripts/build-number.sh "$VERSION" "$BUILD")
echo "Uploading Yorozu iOS $VERSION ($BUILD), CFBundleVersion $BUNDLE_VERSION"
# Nothing here gives the build to an external group or to Beta App Review; such a step must pass this switch first.
scripts/external_testflight.sh 2>&1 || true

mkdir -p build/ios
rm -rf "$ARCHIVE" build/ios/export
tuist generate --no-open --path apps/ios
env -u SDKROOT xcodebuild archive -workspace apps/ios/Yorozu.xcworkspace -scheme YorozuIOS \
    -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" \
    -derivedDataPath .build/xcode-ios -clonedSourcePackagesDirPath .build/xcode-packages \
    -skipPackagePluginValidation -allowProvisioningUpdates \
    -authenticationKeyPath "$KEY" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUNDLE_VERSION" YOROZU_BUILD="$BUILD"
env -u SDKROOT xcodebuild -exportArchive -archivePath "$ARCHIVE" \
    -exportOptionsPlist apps/ios/ExportOptions.plist -exportPath "$PWD/build/ios/export" \
    -allowProvisioningUpdates \
    -authenticationKeyPath "$KEY" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID"
echo "Uploaded Yorozu iOS $VERSION ($BUILD). Once App Store Connect has processed it, TestFlight gives it to the internal group."
BUILD_ID=$(wait_listed) || {
    echo "::error::Uploaded Yorozu iOS $VERSION ($BUILD), but App Store Connect did not list build $BUNDLE_VERSION within ${LIST_WAIT:-1800} s, so the next upload could reuse build $BUILD. Wait until it is listed before rerunning or merging." >&2
    exit 1
}
set_whats_new || {
    echo "::error::Uploaded Yorozu iOS $VERSION ($BUILD), but App Store Connect refused its What to Test. Set it in App Store Connect by hand." >&2
    exit 1
}

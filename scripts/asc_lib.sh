# shellcheck shell=sh
# App Store Connect API helpers, sourced by scripts/upload_ios.sh and scripts/testflight_metadata.sh. Needs
# ASC_KEY_ID and ASC_ISSUER_ID; the key is ASC_KEY_PATH or ~/.appstoreconnect/private_keys/AuthKey_<id>.p8. The
# key and the signed token go only to openssl and curl's standard input, never into arguments or output.
: "${ASC_KEY_ID:?ASC_KEY_ID is required}" "${ASC_ISSUER_ID:?ASC_ISSUER_ID is required}"
KEY=${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8}
case "$KEY" in /*) ;; *) KEY="$PWD/$KEY" ;; esac
[ -r "$KEY" ] || { echo "Cannot read the App Store Connect key at $KEY" >&2; exit 1; }
# shellcheck disable=SC2034 # used by the scripts that source this
APP_ID=6811274963
# shellcheck disable=SC2034
API=https://api.appstoreconnect.apple.com

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

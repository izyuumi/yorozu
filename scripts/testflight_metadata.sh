#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
APPLY=0
case "${1:-}" in --apply) APPLY=1 ;; '') ;; *) echo "usage: $0 [--apply]" >&2; exit 64 ;; esac
. scripts/asc_lib.sh
DIR=apps/ios/metadata/testflight
FIELDS='feedbackEmail marketingUrl privacyPolicyUrl'

live=$(asc_get "$API/v1/apps/$APP_ID/betaAppLocalizations?limit=50")
field() { printf '%s' "$live" | jq -r --arg l "$1" --arg f "$2" '.data[] | select(.attributes.locale == $l) | .attributes[$f] // ""'; }
[ -n "$(field en-US description)" ] || { echo "en-US has no beta app description in App Store Connect; set it first." >&2; exit 1; }

change() {
    if [ "$APPLY" = 1 ]; then asc_send "$1" "$2" "$3" >/dev/null; echo "$4"; else echo "Would: $4"; fi
}

for dir in "$DIR"/*/; do
    loc=$(basename "$dir")
    file=$DIR/$loc/description.txt
    [ -r "$file" ] || { echo "$file is missing" >&2; exit 1; }
    text=$(cat "$file")
    bytes=$(printf '%s' "$text" | wc -c)
    [ "$bytes" -le 4000 ] || { echo "$file is $bytes bytes, over 4,000" >&2; exit 1; }
    id=$(printf '%s' "$live" | jq -r --arg l "$loc" '.data[] | select(.attributes.locale == $l) | .id')
    attrs=$(jq -n '{}')
    was=$(field "$loc" description)
    if [ -z "$was" ]; then
        attrs=$(printf '%s' "$attrs" | jq --arg t "$text" '. + {description: $t}')
    elif [ "$was" != "$text" ]; then
        echo "$loc: kept the description in App Store Connect, which differs from $file."
    fi
    for f in $FIELDS; do
        [ -z "$(field "$loc" "$f")" ] || continue
        value=$(field en-US "$f")
        [ -z "$value" ] || attrs=$(printf '%s' "$attrs" | jq --arg f "$f" --arg v "$value" '. + {($f): $v}')
    done
    set=$(printf '%s' "$attrs" | jq -r 'keys | join(", ")')
    if [ -z "$id" ]; then
        change POST "$API/v1/betaAppLocalizations" "$(printf '%s' "$attrs" | jq --arg l "$loc" --arg app "$APP_ID" \
            '{data: {type: "betaAppLocalizations", attributes: (. + {locale: $l}),
              relationships: {app: {data: {type: "apps", id: $app}}}}}')" "$loc: created ($set)."
    elif [ -n "$set" ]; then
        change PATCH "$API/v1/betaAppLocalizations/$id" "$(printf '%s' "$attrs" | jq --arg id "$id" \
            '{data: {type: "betaAppLocalizations", id: $id, attributes: .}}')" "$loc: set $set."
    else
        echo "$loc: up to date."
    fi
done

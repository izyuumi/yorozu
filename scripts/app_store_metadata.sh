#!/bin/sh
# The App Store listing in every locale with a folder in apps/ios/metadata/app_store. Run by hand, never in CI: it
# edits what the App Store shows once the version is released.
#
#   scripts/app_store_metadata.sh           prints what --apply would change; reads App Store Connect, writes nothing
#   scripts/app_store_metadata.sh --apply   makes those changes
#   scripts/app_store_metadata.sh --check   checks the files against App Store Connect's limits; offline, needs no key
#
# It edits only the iOS version that is still being prepared and the app info that goes with it. It never creates,
# submits or releases a version: make the version in App Store Connect first and submit it there yourself.
# A locale App Store Connect lacks is created, and an empty field is set, from <locale>/<field>.txt. The marketing,
# support and privacy policy URLs, where empty, are copied from en-US, so they live in App Store Connect alone. Text
# that differs from its file is kept and reported, since someone may have written it by hand; locales without a
# folder are left alone. Running it twice changes nothing the second time.
set -eu
cd "$(dirname "$0")/.."
DIR=apps/ios/metadata/app_store
MODE=plan
case "${1:-}" in --apply) MODE=apply ;; --check) MODE=check ;; '') ;; *) echo "usage: $0 [--apply | --check]" >&2; exit 64 ;; esac

# <file> <field>: the file's text, without its last newline
text() { cat "$DIR/$1/$2.txt"; }
chars() { printf '%s' "$1" | jq -Rrs length; }
bytes() { printf '%s' "$1" | wc -c | tr -d ' '; }
locales() { for d in "$1"/*/; do basename "$d"; done; }

# Limits from App Store Connect, counted in characters; keywords in bytes, as App Store Connect counts them.
check() {
    bad=0
    for dir in "$DIR"/*/; do
        loc=$(basename "$dir")
        for spec in name:2:30 subtitle:0:30 keywords:0:100:bytes promotional_text:0:170 description:10:4000 \
            release_notes:0:4000; do
            field=${spec%%:*} rest=${spec#*:}
            min=${rest%%:*} rest=${rest#*:}
            max=${rest%%:*} unit=chars
            case "$rest" in *:bytes) unit=bytes ;; esac
            file=$DIR/$loc/$field.txt
            if [ ! -r "$file" ]; then echo "$file is missing" >&2; bad=1; continue; fi
            t=$(text "$loc" "$field")
            n=$("$unit" "$t")
            if [ "$n" -lt "$min" ] || [ "$n" -gt "$max" ]; then
                echo "$file is $n $unit; it must be $min to $max" >&2; bad=1
            fi
            # description is at most 4,000 characters, and What's New too; keep both within 4,000 bytes as well
            case "$field" in description | release_notes) [ "$(bytes "$t")" -le 4000 ] || {
                echo "$file is over 4,000 bytes" >&2; bad=1; } ;; esac
            case "$t" in *'<'* | *'>'*) echo "$file has < or >, which App Store Connect rejects" >&2; bad=1 ;; esac
        done
    done
    # Same languages as TestFlight and the app
    [ "$(locales "$DIR")" = "$(locales apps/ios/metadata/testflight)" ] || { echo "$DIR and apps/ios/metadata/testflight have different locales" >&2; bad=1; }
    return "$bad"
}

if [ "$MODE" = check ]; then
    check
    echo "The App Store listing is within App Store Connect's limits in $(locales "$DIR" | wc -l | tr -d ' ') locales."
    exit
fi
check
# shellcheck source=scripts/asc_lib.sh
. scripts/asc_lib.sh

# change <method> <url> <json> <message>
change() {
    if [ "$MODE" = apply ]; then asc_send "$1" "$2" "$3" >/dev/null; echo "$4"; else echo "Would: $4"; fi
}

# sync <type> <parent type> <parent id> <live json> <copied URL fields> <attribute=file>...
sync() {
    type=$1 parent=$2 pid=$3 live=$4 copied=$5
    shift 5
    field() { printf '%s' "$live" | jq -r --arg l "$1" --arg f "$2" '.data[] | select(.attributes.locale == $l) | .attributes[$f] // ""'; }
    for dir in "$DIR"/*/; do
        loc=$(basename "$dir")
        id=$(printf '%s' "$live" | jq -r --arg l "$loc" '.data[] | select(.attributes.locale == $l) | .id')
        attrs='{}'
        for pair in "$@"; do
            attr=${pair%%=*} t=$(text "$loc" "${pair#*=}")
            was=$(field "$loc" "$attr")
            if [ -z "$was" ]; then
                [ -z "$t" ] || attrs=$(printf '%s' "$attrs" | jq --arg a "$attr" --arg t "$t" '. + {($a): $t}')
            elif [ "$was" != "$t" ]; then
                echo "$loc: kept $attr in App Store Connect, which differs from $DIR/$loc/${pair#*=}.txt."
            fi
        done
        for f in $copied; do
            [ -z "$(field "$loc" "$f")" ] || continue
            value=$(field en-US "$f")
            [ -z "$value" ] || attrs=$(printf '%s' "$attrs" | jq --arg f "$f" --arg v "$value" '. + {($f): $v}')
        done
        set=$(printf '%s' "$attrs" | jq -r 'keys | join(", ")')
        if [ -z "$id" ]; then
            change POST "$API/v1/$type" "$(printf '%s' "$attrs" | jq --arg t "$type" --arg l "$loc" --arg p "$parent" \
                --arg pid "$pid" '{data: {type: $t, attributes: (. + {locale: $l}),
                  relationships: {($p): {data: {type: ($p + "s"), id: $pid}}}}}')" "$loc $type: created ($set)."
        elif [ -n "$set" ]; then
            change PATCH "$API/v1/$type/$id" "$(printf '%s' "$attrs" | jq --arg t "$type" --arg id "$id" \
                '{data: {type: $t, id: $id, attributes: .}}')" "$loc $type: set $set."
        else
            echo "$loc $type: up to date."
        fi
    done
}

# The versions App Store Connect still lets you edit
EDITABLE=PREPARE_FOR_SUBMISSION,DEVELOPER_REJECTED,REJECTED,METADATA_REJECTED,INVALID_BINARY
versions=$(asc_get "$API/v1/apps/$APP_ID/appStoreVersions?filter%5Bplatform%5D=IOS&filter%5BappStoreState%5D=$EDITABLE&limit=5")
version=$(printf '%s' "$versions" | jq -r '.data[0].id // ""')
if [ -z "$version" ]; then
    echo "No iOS version is being prepared in App Store Connect; make one there first. Nothing to do." >&2
    exit 1
fi
echo "Version $(printf '%s' "$versions" | jq -r '.data[0].attributes | "\(.versionString) (\(.appStoreState))"')"

infos=$(asc_get "$API/v1/apps/$APP_ID/appInfos")
info=$(printf '%s' "$infos" | jq -r '[.data[] | select((.attributes.state // .attributes.appStoreState)
    | IN("READY_FOR_DISTRIBUTION", "READY_FOR_SALE", "REPLACED_WITH_NEW_INFO") | not)][0].id // ""')
if [ -n "$info" ]; then
    sync appInfoLocalizations appInfo "$info" "$(asc_get "$API/v1/appInfos/$info/appInfoLocalizations?limit=50")" \
        privacyPolicyUrl name=name subtitle=subtitle
else
    echo "No app info is being edited, so name and subtitle are left alone."
fi
sync appStoreVersionLocalizations appStoreVersion "$version" \
    "$(asc_get "$API/v1/appStoreVersions/$version/appStoreVersionLocalizations?limit=50")" "marketingUrl supportUrl" \
    description=description keywords=keywords promotionalText=promotional_text whatsNew=release_notes

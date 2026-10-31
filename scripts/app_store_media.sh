#!/bin/sh
# Screenshots and creative art for the App Store listing, from apps/ios/metadata/app_store, through App Store
# Connect's app asset library. Run by hand, never in CI: the media goes live with the version.
#
#   scripts/app_store_media.sh [--version <x.y.z>] [--carry-en-us]            prints the plan; only reads App Store Connect
#   scripts/app_store_media.sh [--version <x.y.z>] [--carry-en-us] --apply    uploads, places and orders
#
# Sources, in each App Store Connect locale folder (<locale>/):
#   screenshots/<device>/*.png|*.jpg   screenshots, shown in file-name order. <device> names the placement group:
#       iphone-6.9  IPHONE_DYNAMIC_ISLAND_LARGE_PROFILE     iphone-6.5  IPHONE_FACE_ID_LARGE_PROFILE
#       iphone-6.3  IPHONE_DYNAMIC_ISLAND_MEDIUM_PROFILE    ipad-13     IPAD_13_PROFILE
#       iphone-duo  IPHONE_DUO_PROFILE
#   creative/header.png                the product page header (PRODUCT_PAGE_HEADER_ASSET, DEFAULT_PROFILE)
#   creative/search.png                the search results art (APP_STORE_SEARCH_RESULTS_ASSET, DEFAULT_PROFILE)
# A localization without its own header or search art gets FALLBACK_HEADER or FALLBACK_SEARCH below.
#
# It works on one iOS version: the one being prepared, or --version, and refuses (65) one App Store Connect no longer
# lets you edit. Every file is checked first against the image specs App Store Connect lists
# (GET /v1/appAssetLibraryRefData): exact pixel size, alpha channel (via sips), file type and size, and the count
# limit per placement group. Then, with --apply:
#   1. upload: each file the library lacks is reserved (POST /v1/appAssetLibraryImages), its bytes PUT to the upload
#      operations, committed (PATCH uploaded=true) and polled until processed. The library has no checksum field, so
#      the reference name carries the file's SHA-256 ("... sha256:<16 hex>"), and a file whose checksum is in the
#      library is not uploaded again; nor is one uploaded some other way with the same byte count and pixel size.
#   2. place: each image not yet on the version localization gets a placement (POST /v1/appAssetLibraryPlacements).
#      A header or search art already placed with another image is kept and reported: there is room for one.
#   3. order: the repo's screenshots first, in file-name order, then the ones already there
#      (POST /v1/appAssetLibraryPlacementOrderingRequests).
# A localization with no screenshots for a device shows en-US's; once it has its own it shows only those. The plan
# says where that happens, and --carry-en-us also places en-US's other screenshots after the localization's own, as
# far as the limit allows. Nothing is deleted. Running it twice changes nothing the second time.
# Exit codes: 0 done or nothing blocks the plan, 64 bad arguments, 65 blocked (the reason is printed), 70 App Store
# Connect refused a write or failed to process an upload; the key handling in scripts/asc_lib.sh exits 1 without a key.
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
DIR=${APP_STORE_MEDIA_DIR:-apps/ios/metadata/app_store}
FALLBACK_HEADER=$DIR/en-US/creative/header-textless.png
FALLBACK_SEARCH=$DIR/en-US/creative/search.png
usage() { echo "usage: $0 [--version <x.y.z>] [--carry-en-us] [--apply]" >&2; exit 64; }

APPLY="" CARRY="" VERSION=""
while [ $# -gt 0 ]; do
    case "$1" in
        --apply) APPLY=1 ;;
        --carry-en-us) CARRY=1 ;;
        --version) [ $# -ge 2 ] || usage; VERSION=$2; shift ;;
        --version=*) VERSION=${1#*=} ;;
        *) usage ;;
    esac
    shift
done
[ -z "$VERSION" ] || printf '%s' "$VERSION" | grep -qE '^[0-9]+(\.[0-9]+){0,2}$' \
    || { echo "The version must look like 1.2.3, not '$VERSION'." >&2; exit 64; }
[ -d "$DIR" ] || { echo "$DIR does not exist." >&2; exit 64; }
# --apply first runs the plan, and writes nothing unless the plan passes.
if [ -n "$APPLY" ]; then
    plan=$("$PWD/scripts/app_store_media.sh" ${VERSION:+--version "$VERSION"} ${CARRY:+--carry-en-us} 2>&1) \
        || { rc=$?; printf '%s\n' "$plan"; echo "Stopped; nothing was written." >&2; exit "$rc"; }
fi

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
BLOCKED=0
block() { echo "Blocked: $*"; BLOCKED=1; }
q() { printf '%s' "$1" | jq -r "$2"; }

group_for() {
    case "$1" in
        iphone-6.9) echo IPHONE_DYNAMIC_ISLAND_LARGE_PROFILE ;;
        iphone-6.5) echo IPHONE_FACE_ID_LARGE_PROFILE ;;
        iphone-6.3) echo IPHONE_DYNAMIC_ISLAND_MEDIUM_PROFILE ;;
        ipad-13) echo IPAD_13_PROFILE ;;
        iphone-duo) echo IPHONE_DUO_PROFILE ;;
        *) return 1 ;;
    esac
}

# The repo's media, one line each: locale, placement type, group, category, path (tab-separated)
TAB=$(printf '\t')
: > "$W/items"
for dir in "$DIR"/*/; do
    loc=$(basename "$dir")
    for dev in "$dir"screenshots/*/; do
        [ -d "$dev" ] || continue
        group=$(group_for "$(basename "$dev")") || { block "${dev%/} is not a device folder this script knows; see its header."; continue; }
        for f in "$dev"*; do
            [ -f "$f" ] || continue
            case "$f" in *.png | *.jpg | *.jpeg) ;; *) block "$f is not a .png or .jpg."; continue ;; esac
            case "$f" in *"$TAB"* | *' '*) block "$f has a space or tab in its name."; continue ;; esac
            printf '%s\tAPP_SCREENSHOT\t%s\tAPP_SCREENSHOTS_AND_PREVIEWS\t%s\n' "$loc" "$group" "$f" >> "$W/items"
        done
    done
done
[ -r "$FALLBACK_HEADER" ] || block "the fallback header $FALLBACK_HEADER is missing."
[ -r "$FALLBACK_SEARCH" ] || block "the fallback search art $FALLBACK_SEARCH is missing."

# Facts per file: path, sha256 (16 hex), width, height, alpha, bytes, extension
command -v sips >/dev/null || { echo "This needs sips (macOS) to read pixel sizes and alpha." >&2; exit 65; }
facts() {
    grep -q "^$1$TAB" "$W/facts" 2>/dev/null && return
    sha=$(shasum -a 256 "$1" | cut -c1-16)
    info=$(sips -g pixelWidth -g pixelHeight -g hasAlpha "$1" 2>/dev/null) || { block "sips cannot read $1."; return; }
    w=$(printf '%s\n' "$info" | awk '/pixelWidth/ { print $2 }')
    h=$(printf '%s\n' "$info" | awk '/pixelHeight/ { print $2 }')
    a=$(printf '%s\n' "$info" | awk '/hasAlpha/ { print $2 }')
    ext=$(printf '%s' "${1##*.}" | tr '[:upper:]' '[:lower:]')
    printf '%s\t%s\t%s\t%s\t%s\t%s\t.%s\n' "$1" "$sha" "${w:-0}" "${h:-0}" "${a:-yes}" "$(wc -c < "$1" | tr -d ' ')" "$ext" >> "$W/facts"
}
fact() { awk -F '\t' -v p="$1" -v c="$2" '$1 == p { print $c; exit }' "$W/facts"; }
: > "$W/facts"
while IFS="$TAB" read -r _ _ _ _ path; do facts "$path"; done < "$W/items"
for f in "$FALLBACK_HEADER" "$FALLBACK_SEARCH"; do [ -r "$f" ] && facts "$f"; done

# shellcheck source=scripts/asc_lib.sh
. scripts/asc_lib.sh
exec 3>&1

# get_all <url> <file>: every page of a list, as one JSON array
get_all() {
    url=$1 n=0
    while [ -n "$url" ]; do
        asc_get "$url" > "$W/page.$n"
        url=$(jq -r '.links.next // ""' "$W/page.$n")
        n=$((n + 1))
    done
    i=0
    while [ "$i" -lt "$n" ]; do cat "$W/page.$i"; rm -f "$W/page.$i"; i=$((i + 1)); done | jq -s '[.[].data[]]' > "$2"
}

asc_get "$API/v1/appAssetLibraryRefData" > "$W/ref.json"
echo "Image specs: $(jq '.data[0].attributes.imageSpecs | length' "$W/ref.json") from App Store Connect (appAssetLibraryRefData)"
# check <placement type> <group> <path>: "ok" or why the file does not fit
check() {
    jq -r --arg t "$1" --arg g "$2" --argjson w "$(fact "$3" 3)" --argjson h "$(fact "$3" 4)" \
        --argjson alpha "$([ "$(fact "$3" 5)" = yes ] && echo true || echo false)" --argjson bytes "$(fact "$3" 6)" \
        --arg ext "$(fact "$3" 7)" '
        .data[0].attributes as $a
        | [$a.placementTypes[]? | select(.placementTypeId == $t) | .specMappings[]? | select(.placementGroupId == $g) | .specs[]] as $ids
        | [$a.imageSpecs[] | select(.specId as $i | $ids | index($i))] as $specs
        | def size: .dimensions | if .minWidth == .maxWidth and .minHeight == .maxHeight then "\(.minWidth)x\(.minHeight)"
            else "\(.minWidth)-\(.maxWidth) x \(.minHeight)-\(.maxHeight) (\(.aspectRatio // "any"))" end;
          def ratio_ok: (.aspectRatio // "") as $r | if (.dimensions.minWidth == .dimensions.maxWidth) or ($r | test("^[0-9]+:[0-9]+$") | not) then true
            else ($r | split(":") | map(tonumber)) as [$x, $y] | ((($w * $y) - ($h * $x)) | if . < 0 then -. else . end) <= ($h * $x * 0.01) end;
          [$specs[] | select(.dimensions.minWidth <= $w and $w <= .dimensions.maxWidth
            and .dimensions.minHeight <= $h and $h <= .dimensions.maxHeight and ratio_ok)] as $fit
        | if ($specs | length) == 0 then "App Store Connect lists no image spec for \($t) in \($g)"
          elif ($fit | length) == 0 then "is \($w)x\($h), and \($t) in \($g) takes \([$specs[] | size] | unique | join(", "))"
          elif $alpha and ([$fit[] | select(.alphaAllowed)] | length) == 0 then "has an alpha channel, which \($t) does not allow; export it without alpha"
          elif ([$fit[] | select((.fileExtensions // [$ext]) | index($ext))] | length) == 0 then "is \($ext), and \($t) takes \([$fit[].fileExtensions[]] | unique | join(", "))"
          elif ([$fit[] | select(.maxFileSize == null or $bytes <= .maxFileSize)] | length) == 0 then "is \($bytes) bytes, over the limit"
          else "ok" end' "$W/ref.json"
}
limit() {
    jq -r --arg t "$1" --arg g "$2" '[.data[0].attributes.features[]? | select(.featureId == "APP_STORE_VERSIONS")
        | .placementPolicies[]? | select(.placementType == $t) | .groupLimits[]? | select(.groupIds | index($g)) | .maxCount][0] // 10' "$W/ref.json"
}
while IFS="$TAB" read -r loc type group _ path; do
    r=$(check "$type" "$group" "$path")
    [ "$r" = ok ] || block "$path $r."
done < "$W/items"
for pair in "PRODUCT_PAGE_HEADER_ASSET $FALLBACK_HEADER" "APP_STORE_SEARCH_RESULTS_ASSET $FALLBACK_SEARCH"; do
    f=${pair#* }
    [ -r "$f" ] || continue
    r=$(check "${pair%% *}" DEFAULT_PROFILE "$f")
    [ "$r" = ok ] || block "$f $r."
done
for loc_dir in "$DIR"/*/; do
    for kind in header search; do
        f=${loc_dir}creative/$kind.png
        [ -r "$f" ] || continue
        facts "$f"
        t=PRODUCT_PAGE_HEADER_ASSET; [ "$kind" = header ] || t=APP_STORE_SEARCH_RESULTS_ASSET
        r=$(check "$t" DEFAULT_PROFILE "$f")
        [ "$r" = ok ] || block "$f $r."
    done
done

# The version
EDITABLE='["PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED", "INVALID_BINARY"]'
state() { q "$1" '.attributes.appStoreState // .attributes.appVersionState // ""'; }
editable() { printf '%s' "$EDITABLE" | jq -e --arg s "$1" 'index($s)' >/dev/null; }
all=$(asc_get "$API/v1/apps/$APP_ID/appStoreVersions?filter%5Bplatform%5D=IOS&limit=200")
if [ -n "$VERSION" ]; then
    version=$(printf '%s' "$all" | jq -c --arg v "$VERSION" '[.data[] | select(.attributes.versionString == $v)][0] // empty')
    [ -n "$version" ] || { echo "Blocked: App Store Connect has no iOS version $VERSION." >&2; exit 65; }
else
    version=$(printf '%s' "$all" | jq -c --argjson e "$EDITABLE" \
        '[.data[] | select((.attributes.appStoreState // .attributes.appVersionState // "") as $s | $e | index($s))][0] // empty')
    [ -n "$version" ] || { echo "Blocked: no iOS version is being prepared in App Store Connect; make one there first." >&2; exit 65; }
fi
VERSION_ID=$(q "$version" .id)
VSTATE=$(state "$version")
echo "Version: $(q "$version" .attributes.versionString) ($VSTATE)"
editable "$VSTATE" || { echo "Blocked: $(q "$version" .attributes.versionString) is $VSTATE, which App Store Connect does not let you edit." >&2; exit 65; }
PRIMARY=$(asc_get "$API/v1/apps/$APP_ID?fields%5Bapps%5D=primaryLocale" | jq -r '.data.attributes.primaryLocale // "en-US"')
[ "$PRIMARY" = en-US ] || echo "Note: the primary locale is $PRIMARY, not en-US; --carry-en-us still carries en-US's."
get_all "$API/v1/appStoreVersions/$VERSION_ID/appStoreVersionLocalizations?limit=50" "$W/locs.json"
loc_id() { jq -r --arg l "$1" '.[] | select(.attributes.locale == $l) | .id' "$W/locs.json"; }
# shellcheck disable=SC2013 # locale names have no spaces
for loc in $(cut -f1 "$W/items" | sort -u); do
    [ -n "$(loc_id "$loc")" ] || block "$loc has screenshots here but no localization on this version; add it first (scripts/app_store_metadata.sh)."
done

LIB=$(asc_get "$API/v1/apps/$APP_ID/assetLibrary" | jq -r '.data.id')
get_all "$API/v1/appAssetLibraries/$LIB/images?limit=200&fields%5BappAssetLibraryImages%5D=fileName,fileSize,imageAsset,referenceName,category,state" "$W/images.json"
echo "Library: $(jq length "$W/images.json") images"
# image <path> <category>: the id of a usable library image of that file: its reference name ends with the file's
# checksum, or, for one uploaded some other way, it has the file's exact byte count and pixel size
image() {
    grep "^$(fact "$1" 2)$TAB$2$TAB" "$W/uploaded" 2>/dev/null | cut -f3 | head -1 | grep . && return
    jq -r --arg s "sha256:$(fact "$1" 2)" --arg c "$2" --argjson b "$(fact "$1" 6)" --argjson w "$(fact "$1" 3)" \
        --argjson h "$(fact "$1" 4)" '[.[] | select(.attributes.category == $c
        and (.attributes.state | IN("FAILED", "AWAITING_UPLOAD", "ARCHIVED") | not))]
        | ([.[] | select((.attributes.referenceName // "") | endswith($s))] + [.[] | select(.attributes.fileSize == $b
            and .attributes.imageAsset.width == $w and .attributes.imageAsset.height == $h)]) | .[0].id // ""' "$W/images.json"
}
: > "$W/uploaded"
: > "$W/planned"
for loc in $(jq -r '.[].attributes.locale' "$W/locs.json" | sort); do
    get_all "$API/v1/appStoreVersionLocalizations/$(loc_id "$loc")/placements?limit=200&sort=placementGroupPosition&include=image&fields%5BappAssetLibraryPlacements%5D=placementType,placementGroup,state,image&fields%5BappAssetLibraryImages%5D=fileName" "$W/pl-$loc.json"
done
# placed <locale> <type> <group>: "placement-id image-id" lines, in order
placed() { jq -r --arg t "$2" --arg g "$3" '.[] | select(.attributes.placementType == $t and .attributes.placementGroup == $g)
    | "\(.id) \(.relationships.image.data.id // "-")"' "$W/pl-$1.json"; }

# write <message> <method> <url> <json>: prints the response with --apply, else only the plan line
write() {
    if [ -n "$APPLY" ]; then
        out=$(asc_send "$2" "$3" "$4") || { echo "App Store Connect refused: $1" >&2; exit 70; }
        echo "Done: $1" >&3
        printf '%s' "$out"
    else
        echo "Would: $1" >&3
    fi
}

# ensure <path> <category>: prints the image id, uploading the file first if the library lacks it ("" in the plan)
ensure() {
    sha=$(fact "$1" 2)
    id=$(image "$1" "$2")
    if [ -n "$id" ]; then printf '%s' "$id"; return; fi
    if [ -z "$APPLY" ]; then
        grep -qx "$sha" "$W/planned" || echo "Would: upload ${1#"$DIR"/} ($(fact "$1" 6) bytes) to the library as $2." >&3
        echo "$sha" >> "$W/planned"
        return
    fi
    rel=${1#"$DIR"/}
    resp=$(write "upload $rel: reserved." POST "$API/v1/appAssetLibraryImages" "$(jq -nc --arg n "$(basename "$1")" \
        --argjson s "$(fact "$1" 6)" --arg c "$2" --arg r "Yorozu $rel sha256:$sha" --arg lib "$LIB" \
        '{data: {type: "appAssetLibraryImages", attributes: {fileName: $n, fileSize: $s, category: $c, referenceName: $r},
          relationships: {assetLibrary: {data: {type: "appAssetLibraries", id: $lib}}}}}')")
    id=$(q "$resp" '.data.id // ""')
    [ -n "$id" ] || { echo "App Store Connect returned no id for $rel." >&2; exit 70; }
    n=$(q "$resp" '.data.attributes.uploadOperations | length')
    i=0
    while [ "$i" -lt "$n" ]; do
        op=$(printf '%s' "$resp" | jq -c ".data.attributes.uploadOperations[$i]")
        off=$(q "$op" .offset) len=$(q "$op" .length)
        tail -c +"$((off + 1))" "$1" | head -c "$len" > "$W/part"
        code=$(q "$op" '.requestHeaders[]? | "header = \"\(.name): \(.value)\""' \
            | curl -sS --config - -X "$(q "$op" .method)" --data-binary "@$W/part" -o /dev/null -w '%{http_code}' "$(q "$op" .url)") || code=000
        case "$code" in 2??) ;; *) echo "The upload of part $((i + 1)) of $rel got HTTP $code." >&2; exit 70 ;; esac
        i=$((i + 1))
    done
    write "upload $rel: committed." PATCH "$API/v1/appAssetLibraryImages/$id" \
        "$(jq -nc --arg id "$id" '{data: {type: "appAssetLibraryImages", id: $id, attributes: {uploaded: true}}}')" >/dev/null
    tries=0
    while :; do
        img=$(asc_get "$API/v1/appAssetLibraryImages/$id")
        st=$(q "$img" .data.attributes.state)
        case "$st" in
            PREPARE_FOR_SUBMISSION | COMPLETE | READY_FOR_REVIEW | WAITING_FOR_REVIEW | IN_REVIEW | ACCEPTED | APPROVED) break ;;
            FAILED) echo "App Store Connect failed to process $rel:" >&2
                q "$img" '.data.attributes.stateDetails[]? | "  \(.code // "?"): \(.message // .title // "")"' >&2; exit 70 ;;
        esac
        tries=$((tries + 1))
        [ "$tries" -lt 120 ] || { echo "$rel is still $st after 10 minutes; run this again later." >&2; exit 70; }
        sleep 5
    done
    echo "Done: $rel is $st ($id)." >&3
    printf '%s\t%s\t%s\n' "$sha" "$2" "$id" >> "$W/uploaded"
    printf '%s' "$id"
}

# place <locale> <type> <group> <image id> <what>
place() {
    write "$1: place $5 as $2 in $3." POST "$API/v1/appAssetLibraryPlacements" "$(jq -nc --arg t "$2" --arg g "$3" \
        --arg img "${4:-new}" --arg l "$(loc_id "$1")" '{data: {type: "appAssetLibraryPlacements",
          attributes: {placementType: $t, placementGroup: $g},
          relationships: {image: {data: {type: "appAssetLibraryImages", id: $img}},
            appStoreVersionLocalization: {data: {type: "appStoreVersionLocalizations", id: $l}}}}}')" >/dev/null
}

# The plan, per localization
screenshots() { # <locale> <group>: the repo's files for it, in order
    awk -F '\t' -v l="$1" -v g="$2" '$1 == l && $3 == g { print $5 }' "$W/items" | sort
}
# others <locale> <group> <own image ids file>: image ids placed there that are not the repo's
others() { placed "$1" APP_SCREENSHOT "$2" | while read -r _ img; do grep -qx "$img" "$3" || echo "$img"; done; }
if [ "$BLOCKED" = 1 ]; then
    echo "Plan only; nothing was written, and the blocks above stop it." >&2
    exit 65
fi
for loc in $(jq -r '.[].attributes.locale' "$W/locs.json" | sort); do
    # shellcheck disable=SC2013 # group ids have no spaces
    for group in $(awk -F '\t' -v l="$loc" '$1 == l { print $3 }' "$W/items" | sort -u); do
        max=$(limit APP_SCREENSHOT "$group")
        : > "$W/own"
        files=$(screenshots "$loc" "$group")
        for f in $files; do
            id=$(ensure "$f" APP_SCREENSHOTS_AND_PREVIEWS)
            [ -z "$id" ] || echo "$id" >> "$W/own"
        done
        others "$loc" "$group" "$W/own" > "$W/kept"
        nfiles=$(printf '%s\n' "$files" | grep -c .)
        nkept=$(grep -c . "$W/kept" || true)
        had=$(placed "$loc" APP_SCREENSHOT "$group" | grep -c . || true)
        : > "$W/carry"
        if [ "$loc" != en-US ]; then
            if [ "$had" = 0 ]; then
                from=$(placed en-US APP_SCREENSHOT "$group" | grep -c . || true)
                echo "$loc $group: shows en-US's $from screenshots now; with its own $nfiles it shows only its own."
            fi
            if [ -n "$CARRY" ]; then
                : > "$W/own-en"
                for f in $(screenshots en-US "$group"); do image "$f" APP_SCREENSHOTS_AND_PREVIEWS >> "$W/own-en"; done
                others en-US "$group" "$W/own-en" | while read -r img; do
                    placed "$loc" APP_SCREENSHOT "$group" | awk '{ print $2 }' | grep -qx "$img" || echo "$img"
                done > "$W/carry"
                room=$((max - nfiles - nkept)); [ "$room" -ge 0 ] || room=0
                ncarry=$(grep -c . "$W/carry" || true)
                if [ "$ncarry" -gt "$room" ]; then
                    echo "$loc $group: --carry-en-us has room for $room of en-US's $ncarry other screenshots (limit $max); the rest stay off."
                    head -n "$room" "$W/carry" > "$W/carry.cut"; mv "$W/carry.cut" "$W/carry"
                fi
            elif [ "$had" = 0 ] && [ -n "$(placed en-US APP_SCREENSHOT "$group" | head -1)" ]; then
                echo "$loc $group: pass --carry-en-us to place en-US's other screenshots after its own."
            fi
        fi
        total=$((nfiles + nkept + $(grep -c . "$W/carry" || true)))
        if [ $((nfiles + nkept)) -gt "$max" ]; then
            echo "Blocked: $loc $group would hold $((nfiles + nkept)) screenshots ($nfiles from the repo, $nkept already there); the limit is $max. Remove some in App Store Connect." >&2
            exit 65
        fi
        # 2: place the repo's files, then any carried ones
        changed=""
        for f in $files; do
            id=$(image "$f" APP_SCREENSHOTS_AND_PREVIEWS)
            if [ -n "$id" ] && placed "$loc" APP_SCREENSHOT "$group" | awk '{ print $2 }' | grep -qx "$id"; then continue; fi
            place "$loc" APP_SCREENSHOT "$group" "$id" "${f#"$DIR"/}"; changed=1
        done
        while read -r img; do
            [ -n "$img" ] || continue
            place "$loc" APP_SCREENSHOT "$group" "$img" "en-US's screenshot $img"; changed=1
        done < "$W/carry"
        # 3: order: the repo's files, the ones that were there, then the carried ones
        if [ -n "$APPLY" ] && [ -n "$changed" ]; then
            get_all "$API/v1/appStoreVersionLocalizations/$(loc_id "$loc")/placements?limit=200&sort=placementGroupPosition&include=image&fields%5BappAssetLibraryPlacements%5D=placementType,placementGroup,state,image&fields%5BappAssetLibraryImages%5D=fileName" "$W/pl-$loc.json"
        fi
        if [ -n "$APPLY" ]; then
            placed "$loc" APP_SCREENSHOT "$group" > "$W/now"
            { while read -r img; do awk -v i="$img" '$2 == i { print $1 }' "$W/now"; done < "$W/own"
              while read -r img; do awk -v i="$img" '$2 == i { print $1 }' "$W/now"; done < "$W/kept"
              while read -r img; do awk -v i="$img" '$2 == i { print $1 }' "$W/now"; done < "$W/carry"; } > "$W/want"
            if [ "$(cut -d' ' -f1 "$W/now")" = "$(cat "$W/want")" ]; then
                echo "$loc $group: $total screenshots, in order."
            else
                write "$loc: order $group: $nfiles from the repo, then $nkept already there$( [ -s "$W/carry" ] && echo ", then $(grep -c . "$W/carry") from en-US")." \
                    POST "$API/v1/appAssetLibraryPlacementOrderingRequests" "$(jq -Rn --arg g "$group" --arg l "$(loc_id "$loc")" \
                    '{data: {type: "appAssetLibraryPlacementOrderingRequests", attributes: {placementGroup: $g},
                      relationships: {orderedPlacements: {data: [inputs | select(length > 0) | {type: "appAssetLibraryPlacements", id: .}]},
                        appStoreVersionLocalization: {data: {type: "appStoreVersionLocalizations", id: $l}}}}}' < "$W/want")" >/dev/null
            fi
        elif [ -n "$changed" ]; then
            echo "Would: $loc: order $group: $nfiles from the repo, then $nkept already there$( [ -s "$W/carry" ] && echo ", then $(grep -c . "$W/carry") from en-US"); $total of $max."
        else
            placed "$loc" APP_SCREENSHOT "$group" | awk '{ print $2 }' > "$W/now"
            if [ "$(head -n "$nfiles" "$W/now")" = "$(cat "$W/own")" ]; then
                echo "$loc $group: $total screenshots, in order."
            else
                echo "Would: $loc: order $group: $nfiles from the repo first, then $nkept already there."
            fi
        fi
    done

    # Header and search art: the localization's own, else the fallback
    for kind in header search; do
        if [ "$kind" = header ]; then t=PRODUCT_PAGE_HEADER_ASSET fb=$FALLBACK_HEADER; else t=APP_STORE_SEARCH_RESULTS_ASSET fb=$FALLBACK_SEARCH; fi
        f=$DIR/$loc/creative/$kind.png
        [ -r "$f" ] || f=$fb
        id=$(ensure "$f" CREATIVE_ASSETS)
        there=$(placed "$loc" "$t" DEFAULT_PROFILE | awk '{ print $2 }')
        if [ -n "$id" ] && printf '%s\n' "$there" | grep -qx "$id"; then
            echo "$loc $kind: up to date (${f#"$DIR"/})."
        elif [ -n "$there" ]; then
            echo "$loc $kind: kept the one in App Store Connect, which is not ${f#"$DIR"/}; remove it there to use the file."
        else
            place "$loc" "$t" DEFAULT_PROFILE "$id" "${f#"$DIR"/}"
        fi
    done
done

if [ -z "$APPLY" ]; then
    echo "Plan only; nothing was written. Nothing blocks it: --apply makes these changes."
fi

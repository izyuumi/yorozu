#!/usr/bin/env bash
# Checks an App Store app preview file against App Store Connect's spec (apps/preview/README.md) with ffprobe,
# prints the values and exits non-zero on any failure.
# Usage: scripts/app_preview_check.sh FILE
set -euo pipefail

file=${1:?usage: scripts/app_preview_check.sh FILE}
[[ -f $file ]] || { echo "No such file: $file" >&2; exit 2; }

probe() { ffprobe -v error "$@" -of default=noprint_wrappers=1:nokey=1 "$file"; }
video() { probe -select_streams v:0 -show_entries "stream=$1"; }
audio() { probe -select_streams a:0 -show_entries "stream=$1"; }

width=$(video width)
height=$(video height)
codec=$(video codec_name)
profile=$(video profile)
level=$(video level)
rate=$(video avg_frame_rate)
vbit=$(video bit_rate)
audio_count=$(probe -select_streams a -show_entries stream=index | grep -c . || true)
acodec=$(audio codec_name)
channels=$(audio channels)
sample_rate=$(audio sample_rate)
duration=$(probe -show_entries format=duration)
size=$(probe -show_entries format=size)

failures=0
check() { # name value ok
  if [[ $3 == 1 ]]; then printf 'ok    %-14s %s\n' "$1" "$2"; else printf 'FAIL  %-14s %s\n' "$1" "$2"; failures=$((failures + 1)); fi
}
is() { [[ $1 == "$2" ]] && echo 1 || echo 0; }
within() { awk -v v="$1" -v lo="$2" -v hi="$3" 'BEGIN { print (v != "" && v + 0 >= lo && v + 0 <= hi) ? 1 : 0 }'; }

check size "${width}x${height}" "$(is "${width}x${height}" 886x1920)"
check codec "$codec" "$(is "$codec" h264)"
check profile "$profile" "$(is "$profile" High)"
check level "$level" "$(within "$level" 1 40)"
check frame_rate "$rate" "$(is "$rate" 30/1)"
check video_bitrate "$vbit b/s" "$(within "$vbit" 10000000 12000000)"
check audio_tracks "$audio_count" "$(is "$audio_count" 1)"
check audio_codec "$acodec" "$(is "$acodec" aac)"
check channels "$channels" "$(is "$channels" 2)"
check sample_rate "$sample_rate Hz" "$( [[ $sample_rate == 44100 || $sample_rate == 48000 ]] && echo 1 || echo 0)"
check duration "$duration s" "$(awk -v d="$duration" 'BEGIN { print (d != "" && d + 0 >= 15.0 && d + 0 <= 29.5 && d + 0 < 30.0) ? 1 : 0 }')"
check file_size "$size bytes" "$(within "$size" 1 499999999)"

if ((failures)); then
  echo "$failures check(s) failed: $file" >&2
  exit 1
fi
echo "All checks passed: $file"

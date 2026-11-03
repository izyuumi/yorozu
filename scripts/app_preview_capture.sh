#!/usr/bin/env bash
# Records the App Store app preview's takes (apps/preview/README.md): a throwaway iPhone 17 Pro Max simulator on the
# newest iOS runtime runs a Debug build with `--preview-scene NAME` per locale and scene, and `simctl io recordVideo`
# writes apps/preview/footage/<locale>/<scene>.mp4. The simulator is deleted at the end unless KEEP_SIM=1.
# It touches no other simulator, no pairing and no Gateway, and never launches the Mac app.
# Usage: scripts/app_preview_capture.sh [en-US] [ja] [-- SCENE...]
set -euo pipefail

command -v ffmpeg >/dev/null || { echo "Needs ffmpeg: brew install ffmpeg" >&2; exit 1; }
command -v axe >/dev/null || { echo "Needs AXe for the Lock Screen take: brew install cameroncooke/axe/axe" >&2; exit 1; }

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
bundle=to.yumi.yorozu.ios
derived=.build/xcode-preview
footage=apps/preview/footage
lead=2.5 # seconds from the app's ready mark to recording; the scenes' times count from there (PreviewScene.lead)
locked_lead=6 # the Lock Screen takes' extra wait while the app goes home and the device locks

locales=()
scenes=()
while (($#)); do
  if [[ $1 == -- ]]; then shift; scenes=("$@"); break; fi
  locales+=("$1"); shift
done
((${#locales[@]})) || locales=(en-US ja)
# The Lock Screen takes go last (they leave the device locked); each locale starts on a fresh boot.
((${#scenes[@]})) || scenes=(hook approve talk list lockscreen needs-you)

seconds() {
  case $1 in
    hook) echo 7 ;; lockscreen | needs-you) echo 9 ;; approve) echo 6 ;; talk) echo 10 ;; list) echo 6 ;;
    *) echo "Unknown scene: $1" >&2; exit 2 ;;
  esac
}

work=$(mktemp -d)
udid=
recorder=
cleanup() {
  [[ -n $recorder ]] && kill -INT "$recorder" 2>/dev/null || true
  if [[ -n $udid ]]; then
    if [[ ${KEEP_SIM:-0} == 1 ]]; then
      echo "Kept simulator $name ($udid)."
    else
      xcrun simctl shutdown "$udid" 2>/dev/null || true
      xcrun simctl delete "$udid" 2>/dev/null || true
    fi
  fi
  rm -rf "$work"
}
trap cleanup EXIT

device=com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max
# The newest installed iOS runtime that runs this device type (some runtimes, e.g. a device-specific beta, don't).
runtime=$(xcrun simctl list runtimes available -j | python3 -c '
import json, sys
device = sys.argv[1]
runtimes = [r for r in json.load(sys.stdin)["runtimes"]
            if r["platform"] == "iOS" and any(d["identifier"] == device for d in r.get("supportedDeviceTypes", []))]
runtimes.sort(key=lambda r: [int(p) for p in r["version"].split(".")])
print(runtimes[-1]["identifier"] if runtimes else "")' "$device")
[[ -n $runtime ]] || { echo "No installed iOS simulator runtime runs the iPhone 17 Pro Max." >&2; exit 1; }
name="Yorozu Preview $RANDOM"
udid=$(xcrun simctl create "$name" "$device" "$runtime")
echo "Simulator: $name ($udid) on $runtime"

# Boots in the locale's system language (the Lock Screen and the widget follow it, not the app's arguments).
boot() { # language locale
  xcrun simctl boot "$udid" 2>/dev/null || true
  xcrun simctl bootstatus "$udid" -b >/dev/null
  xcrun simctl spawn "$udid" defaults write -g AppleLanguages -array "$1"
  xcrun simctl spawn "$udid" defaults write -g AppleLocale -string "$2"
  xcrun simctl shutdown "$udid"
  xcrun simctl boot "$udid"
  xcrun simctl bootstatus "$udid" -b >/dev/null
  xcrun simctl ui "$udid" appearance light
  xcrun simctl status_bar "$udid" override --time 9:41 --dataNetwork wifi --wifiMode active --wifiBars 3 \
    --cellularMode active --cellularBars 4 --operatorName '' --batteryState charged --batteryLevel 100
}

# simctl has no lock verb, so AXe (brew install cameroncooke/axe/axe) presses the buttons, headless. The app
# goes home first (ActivityKit starts an activity only while the app is still visible), then the device locks;
# an activity can ask "Allow Live Activities from Yorozu?" on the Lock Screen, and AXe allows it.
lock() { # [rounds of looking for the prompt]
  axe button home --udid "$udid" >/dev/null
  sleep 1
  axe button lock --udid "$udid" >/dev/null
  local ui label
  for _ in $(seq "${1:-3}"); do
    sleep 0.5
    ui=$(axe describe-ui --udid "$udid" 2>/dev/null) || continue
    for label in "Always Allow" Allow 常に許可 許可; do
      if grep -q "\"AXLabel\" : \"$label\"" <<<"$ui"; then
        axe tap --label "$label" --udid "$udid" >/dev/null 2>&1 || true
        return 0
      fi
    done
  done
  return 0
}

# Wakes the Lock Screen and swipes up (the throwaway simulator has no passcode).
unlock() {
  axe button home --udid "$udid" >/dev/null
  sleep 1
  axe swipe --start-x 220 --start-y 940 --end-x 220 --end-y 300 --duration 0.3 --udid "$udid" >/dev/null
  sleep 1
}

# Sleeps until $1 (epoch seconds, fractional).
until_time() { local wait; wait=$(python3 -c "import time; print(max(0, $1 - time.time()))"); sleep "$wait"; }

record() { # file seconds
  local log=$work/record.log raw=$work/take.mp4
  rm -f "$1" "$raw" "$log"
  xcrun simctl io "$udid" recordVideo --codec=h264 --force "$raw" 2>"$log" &
  recorder=$!
  for _ in $(seq 50); do grep -q "Recording started" "$log" 2>/dev/null && break; sleep 0.1; done
  sleep "$2"
  kill -INT "$recorder"
  wait "$recorder" || true
  recorder=
  [[ -s $raw ]] || { echo "Recording failed: $1" >&2; cat "$log" >&2; exit 1; }
  # simctl writes variable frame rate and stops at the last change on screen: 30 fps constant, the last
  # frame held to the full length, so the timeline's in and out points hold.
  ffmpeg -y -v error -i "$raw" -vf "fps=30,tpad=stop_mode=clone:stop_duration=$2" -t "$2" \
    -c:v libx264 -preset fast -crf 12 -pix_fmt yuv420p -an "$1"
}

echo "Building the Debug app…"
TUIST_VOICE_INPUT=0 tuist generate --no-open --path apps/ios
xcodebuild build -workspace apps/ios/Yorozu.xcworkspace -scheme YorozuIOS -configuration Debug \
  -destination "platform=iOS Simulator,id=$udid" -derivedDataPath "$derived" \
  -clonedSourcePackagesDirPath .build/xcode-packages -skipPackagePluginValidation -quiet \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=
app=$derived/Build/Products/Debug-iphonesimulator/Yorozu.app

# The talk take's recording: fictional words, spoken by a system voice.
say -o "$work/en-US.wav" --file-format=WAVE --data-format=LEF32@16000 "Remind me to water the plants at 6"
ja_voice=$(say -v '?' | sed -n 's/^\(.*[^ ]\)  *ja_JP .*/\1/p' | head -1)
if [[ -n $ja_voice ]]; then
  say -v "$ja_voice" -o "$work/ja.wav" --file-format=WAVE --data-format=LEF32@16000 "6時に植物に水をやるようリマインドして"
else
  echo "No Japanese system voice; the ja talk take's waveform uses the English clip." >&2
  cp "$work/en-US.wav" "$work/ja.wav"
fi

for locale in "${locales[@]}"; do
  case $locale in
    en-US) system=(en-US en_US); language=(-AppleLanguages "(en)" -AppleLocale en_US) ;;
    ja) system=(ja-JP ja_JP); language=(-AppleLanguages "(ja)" -AppleLocale ja_JP) ;;
    *) echo "Unknown locale: $locale" >&2; exit 2 ;;
  esac
  boot "${system[@]}"
  xcrun simctl install "$udid" "$app"
  xcrun simctl privacy "$udid" grant microphone "$bundle" || true
  caches="$(xcrun simctl get_app_container "$udid" "$bundle" data)/Library/Caches"
  mkdir -p "$caches" "$footage/$locale"
  cp "$work/$locale.wav" "$caches/preview-voice.wav"
  epoch= # when the Lock Screen rows started, shared by both Lock Screen takes
  locked=0
  primed=0
  for scene in "${scenes[@]}"; do
    length=$(seconds "$scene")
    echo "$locale/$scene (${length}s)"
    # A fresh boot can come up locked or with the app relaunched in the background: start from the Home
    # Screen, and launch again if the app never becomes active.
    ((locked)) && unlock
    locked=0
    extra=()
    if [[ $scene == lockscreen || $scene == needs-you ]]; then
      if ((!primed)); then
        # The boot's first activity asks to be allowed, seconds after the lock: answer it before any take.
        echo "$locale: allowing Live Activities"
        xcrun simctl terminate "$udid" "$bundle" 2>/dev/null || true
        rm -f "$caches/preview-ready"
        xcrun simctl launch "$udid" "$bundle" --preview-scene needs-you "${language[@]}" >/dev/null
        for _ in $(seq 150); do [[ -e $caches/preview-ready ]] && break; sleep 0.1; done
        sleep "$lead"
        lock 12
        unlock
        primed=1
      fi
      [[ -n $epoch ]] || epoch=$(date +%s)
      extra=(--preview-epoch "$epoch")
    fi
    for attempt in 1 2 3; do
      xcrun simctl terminate "$udid" "$bundle" 2>/dev/null || true
      axe button home --udid "$udid" >/dev/null 2>&1 || true
      sleep 1
      rm -f "$caches/preview-ready"
      xcrun simctl launch "$udid" "$bundle" --preview-scene "$scene" ${extra[@]+"${extra[@]}"} "${language[@]}" >/dev/null
      for _ in $(seq 150); do [[ -e $caches/preview-ready ]] && break; sleep 0.1; done
      [[ -e $caches/preview-ready ]] && break
      echo "The app did not become active (attempt $attempt): $locale/$scene" >&2
    done
    [[ -e $caches/preview-ready ]] || { echo "The app never became ready: $locale/$scene" >&2; exit 1; }
    ready=$(python3 -c "import time; print(time.time())")
    until_time "$ready + $lead"
    if ((${#extra[@]})); then
      lock
      locked=1
      until_time "$ready + $lead + $locked_lead"
    fi
    record "$footage/$locale/$scene.mp4" "$length"
  done
  xcrun simctl terminate "$udid" "$bundle" 2>/dev/null || true
  xcrun simctl shutdown "$udid"
done
echo "Takes are in $footage/."

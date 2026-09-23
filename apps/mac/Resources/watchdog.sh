#!/bin/sh
# Opens Yorozu again if it is not running. Run once a minute by the LaunchAgent that
# apps/mac Keepalive.swift writes; see the comment there for why the supervisor has to live
# outside the app it supervises.
#
#   watchdog.sh <app-bundle> <pause-file> <log-file>
#
# Every path is an argument rather than a constant in here, so a test install supervises
# itself at its own path and the copy in /Applications is never involved.
set -u

APP=$1
PAUSE=$2
LOG=$3

# A deliberate Quit leaves a deadline behind; a crash does not. An unreadable or expired
# file is not a pause: when in doubt, supervise. (`[` failing on a non-numeric file is what
# makes the whole condition false, which is the answer we want.)
if [ -f "$PAUSE" ] && [ "$(date +%s)" -lt "$(cat "$PAUSE" 2>/dev/null)" ] 2>/dev/null; then
  exit 0
fi

# Matched on the executable's full path, not the process name: a test build and the real one
# are both called Yorozu, and each has to be able to tell that the *other* one is not itself.
# The anchor also keeps this script's own command line — /bin/sh first — from matching.
#
# The path is a regular expression to pgrep, and a path is user data: "Yumi (work)" or an
# app kept under "~/Apps+" would match something else or nothing. Every ERE metacharacter in
# it is escaped first, so the pattern means the path and only the path.
ESCAPED=$(printf '%s' "$APP" | sed -e 's/[][\.*^$+?(){}|]/\\&/g')
if pgrep -f "^$ESCAPED/Contents/MacOS/" >/dev/null 2>&1; then
  exit 0
fi

mkdir -p "$(dirname "$LOG")"
echo "$(date '+%Y-%m-%d %H:%M:%S') watchdog: $APP not running, relaunching" >>"$LOG"
open -a "$APP" ||
  echo "$(date '+%Y-%m-%d %H:%M:%S') watchdog: open -a \"$APP\" failed" >>"$LOG"

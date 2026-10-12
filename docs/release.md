# Release

How the Mac dev app is rebuilt, how iOS builds reach TestFlight and how the website ships. Credentials and signing are in [setup.md](setup.md); the steps each script runs are in its header comment.

## Version

`version.txt` holds one numeric `major.minor.patch` for both apps. Both Tuist manifests stop with a fatal error on any other format. Both scripts pass `MARKETING_VERSION` to `xcodebuild` explicitly, because Tuist caches the manifest and a `version.txt` change alone may not reach the build. Bump `version.txt` when a new version is needed, for example to bring iOS build numbers back to 1.

A minor version that breaks the relay wire also raises the peer-info protocol ([ios-relay-contract.md](ios-relay-contract.md#versioning)). 0.7.0 is protocol 2: a Mac rebuilt at 0.7.0 refuses every 0.6.x phone with "Update Yorozu on this iPhone to talk to this Mac.", so it goes with a 0.7.0 iOS upload, and the dev Mac moves to it only when the owner chooses. Pairings survive the move; nothing needs pairing again.

## Mac: rebuild the dev app

`scripts/build_native.sh` is the only way the Mac app is built. It replaces `/Applications/Yorozu.app` in place, the one Yorozu on the owner's Mac (owner, 2026-10-12: v1 removed, no second copy with the bundle id, so the login item and the v1 migration work). Run it from the main checkout.

- Without `--restart` it exits 3 while `/Applications/Yorozu.app` is running.
- It quits only the app at that path, by pid.
- `--restart` relaunches the app with `open -n` even if it was not running before. `-n` keeps LaunchServices from just focusing v1.
- Mac builds are build 1 unless `BUILD` is set.

Restarting mid-task is safe: the relaunched app re-attaches to interrupted runs and delivers their results ([architecture.md](architecture.md#restart-and-resume)).

The dev build is Developer ID signed (no `get-task-allow`) but not notarized, and has no update feed: built as build 1, it would take v1's own release as an update. Releases come from `scripts/release_mac.sh` (below).

## Mac: release and updates

The app embeds Sparkle with v1's feed (`https://yorozu.yumi.to/appcast.xml`, the latest GitHub release's `appcast.xml`) and EdDSA public key, so an installed v1 updates to this app and this app keeps updating (owner, 2026-10-11). Checks and downloads are automatic and hourly; a downloaded update installs and relaunches once no task is running, since the menu-bar host rarely quits. Settings › General has Get beta updates (v1's `YorozuBetaUpdates` default, so v1's beta users stay on beta; they read `https://yorozu.yumi.to/beta/appcast.xml`) and Check for Updates…, also in the menu-bar menu.

`BUILD=<n> scripts/release_mac.sh beta|stable` builds the release in `build/release/<version>-<build>/`: `Yorozu.dmg` (Developer ID, Sparkle's helpers re-signed with it, hardened runtime, notarized with the `yorozu-notary` profile and stapled), `appcast.xml` with one item signed with the Sparkle key in the login Keychain (`SPARKLE_ED_KEY_FILE` instead), beta items carrying the beta channel, and `candidate.json`. `BUILD` must be above every published build: v1's stable is 293 and its beta 10271, so v2 starts at 10272. Nothing is published: a GitHub release is the owner's step. Stable users get the assets of the release marked latest (`v<version>`); beta users get the newest prerelease tagged `v<version>-beta` that `apps/web/worker.mjs` on `main` accepts, which checks `candidate.json` and today requires `source_branch` `main`, so the first v2 beta needs that check widened on `main`.

## Installing over v1

The Mac app shares v1's bundle id, so it replaces v1 in place, keeping its TCC grants and preferences. On the first live launch with no other copy of the bundle installed, it handles what v1 left ([architecture.md](architecture.md#replacing-yorozu-1)): v1's watchdog LaunchAgent is booted out and deleted, v1's memory notes are imported, v1's login item becomes this app's, and one chat note says to pair client devices again. While v1 is still installed beside it (as on the owner's Mac), none of that runs. v1's chats, keys and devices stay in `~/Library/Application Support/Yorozu`. The iPhone app, installed over v1's, finds v1's pairing and says why it pairs again.

## iOS: upload to TestFlight

`scripts/upload_ios.sh --confirm`. Build-number policy: [OWNER_DECISIONS.md](../OWNER_DECISIONS.md#platform-and-release).

- Without `--confirm` it exits 64.
- It numbers the build from App Store Connect (highest build of this version plus one). If that would reach 10000 it stops with exit 65: bump `version.txt` instead. `BUILD=<n>` skips both the lookup and that check.
- `apps/ios/ExportOptions.plist` makes the export step the upload, internal testing only.
- The archive embeds the notification service extension (`to.yumi.yorozu.ios.notification-service`), which carries the app's version pair; automatic signing issues its App Store profile beside the app's ([setup.md](setup.md#push-notifications)).
- The build reaches the Internal TestFlight group once App Store Connect has processed it.

## iOS: compile check without uploading

`upload_ios.sh` is the only scripted iOS build. To compile the iOS app (including `Sources/ProjectXApp/ChatMarkdown.swift`, which it shares) without signing or uploading:

```sh
tuist generate --no-open --path apps/ios
env -u SDKROOT xcodebuild build -workspace apps/ios/Yorozu.xcworkspace -scheme YorozuIOS \
    -destination 'generic/platform=iOS' -derivedDataPath .build/xcode-ios \
    -clonedSourcePackagesDirPath .build/xcode-packages -skipPackagePluginValidation \
    CODE_SIGNING_ALLOWED=NO
```

## Website

https://yorozu.yumi.to is the Astro site in `apps/web` on `main`, not on `projectx`. `.github/workflows/deploy-web.yml` deploys it on every push to `main` that touches `apps/web/**`, so merging is deploying. `Start.md` on `main` is the guide the site's one-line prompt points agents at; it changes in the same PR as the site.

The 0.7.0 update (#321) is a PR to `main` that stays open until the release; the owner merges it at release time. v1 keeps its links: `/pair`, the AASA file, the privacy and terms pages, and the public TestFlight link, which stays on v1 until v2 is released to that group.

## Not wired

- Mac release publishing: `scripts/release_mac.sh` builds and notarizes; uploading to a GitHub release stays a manual, owner-only step.
- v1's release process on `main` (Release Please, GitHub Actions release and promote workflows, `BUILD = 10000 + run number`, Sparkle appcasts) does not apply to `projectx`, which has no CI.
- Public App Store release: not requested; iOS goes to internal TestFlight only.

# Release

How the Mac dev app is rebuilt, how iOS builds reach TestFlight and how the website ships. Credentials and signing are in [setup.md](setup.md); the steps each script runs are in its header comment.

## Version

`version.txt` holds one numeric `major.minor.patch` for both apps. Both Tuist manifests stop with a fatal error on any other format. Both scripts pass `MARKETING_VERSION` to `xcodebuild` explicitly, because Tuist caches the manifest and a `version.txt` change alone may not reach the build. Bump `version.txt` when a new version is needed, for example to bring iOS build numbers back to 1.

A minor version that breaks the relay wire also raises the peer-info protocol ([ios-relay-contract.md](ios-relay-contract.md#versioning)). 0.7.0 is protocol 2: a Mac rebuilt at 0.7.0 refuses every 0.6.x phone with "Update Yorozu on this iPhone to talk to this Mac.", so it goes with a 0.7.0 iOS upload, and the dev Mac moves to it only when the owner chooses. Pairings survive the move; nothing needs pairing again.

## Mac: rebuild the dev app

`scripts/build_native.sh` is the only way the Mac app is built. Run it from the main checkout so the one dev app stays at `build/Yorozu.app` there; a worktree's own `build/` would make a second bundle.

- Without `--restart` it exits 3 while this checkout's `build/Yorozu.app` is running.
- It quits only this checkout's dev app, by pid, because v1 shares the bundle id.
- `--restart` relaunches the app with `open -n` even if it was not running before. `-n` keeps LaunchServices from just focusing v1.
- Mac builds are build 1 unless `BUILD` is set.

Restarting mid-task is safe: the relaunched app re-attaches to interrupted runs and delivers their results ([architecture.md](architecture.md#restart-and-resume)).

The build is Developer ID signed but not notarized, and nothing in the repo notarizes it; `spctl` rejects it as "Unnotarized Developer ID". It also carries `get-task-allow`. It is a local dev build, not a distributable one.

## Installing over v1

The Mac app shares v1's bundle id, so a copy placed in `/Applications` would replace v1 in place, sharing its TCC grants and preferences. Doing that is the owner's call. v2 has no update feed, so v1 users do not receive v2.

## iOS: upload to TestFlight

`scripts/upload_ios.sh --confirm`. Build-number policy: [OWNER_DECISIONS.md](../OWNER_DECISIONS.md#platform-and-release).

- Without `--confirm` it exits 64.
- It numbers the build from App Store Connect (highest build of this version plus one). If that would reach 10000 it stops with exit 65: bump `version.txt` instead. `BUILD=<n>` skips both the lookup and that check.
- `apps/ios/ExportOptions.plist` makes the export step the upload, internal testing only.
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

- Mac distribution: no notarization, DMG or update feed.
- v1's release process on `main` (Release Please, GitHub Actions release and promote workflows, `BUILD = 10000 + run number`, Sparkle appcasts) does not apply to `projectx`, which has no CI.
- Public App Store release: not requested; iOS goes to internal TestFlight only.

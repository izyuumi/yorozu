# Release

How the client app is versioned, built for the Mac, uploaded to TestFlight for iPhone and iPad, and compile-checked. The plugin has no release step: the Gateway loads it from the linked checkout ([setup.md](setup.md#1-install-the-plugin)). Credentials and signing are in [setup.md](setup.md#signing); the steps each script runs are in its header comment.

## Version

`version.txt` holds one numeric `major.minor.patch` for the client on every platform. `apps/ios/Project.swift` stops with a fatal error on any other format. Both scripts pass `MARKETING_VERSION` to `xcodebuild` explicitly, because Tuist caches the manifest and a `version.txt` change alone may not reach the build. The visible build restarts at 1 per version. `CFBundleVersion` is that build encoded with the version, the same number on every platform: major·10⁷ + minor·10⁵ + patch·10³ + build (`scripts/build-number.sh`, and `bundleVersion` in `apps/ios/Project.swift`), so 0.9.0 build 1 is `900001`. Sparkle compares that integer and 0.5.0-beta Macs are build `10279`: it must only ever rise. The Info.plist key `YorozuBuild` carries the visible build, which the Mac's About panel shows. Builds stop at 999 and minor and patch at 99. Bump `version.txt` when a new version is needed.

A minor version that breaks the wire also raises the protocol in `peer_info` (`protocolMin` / `protocolMax`, 3 for wire v3; [contract](ios-relay-contract.md#peer_info)), on both the client and the plugin. A client and plugin without a common version stop with "Update required", so such a change ships to the plugin and the clients together.

## Mac client

`scripts/build_native.sh` builds the client's macOS destination (`apps/ios`, scheme `YorozuIOS`, Release) into `.build/xcode-native` and replaces `/Applications/Yorozu.app` in place, the one Yorozu on the owner's Mac (owner, 2026-10-12). Run it from the main checkout.

- Without `--restart` it exits 3 while `/Applications/Yorozu.app` is running.
- It quits only the app at that path, by pid: any executable in the bundle, so the old host app it replaces is matched too.
- `--restart` relaunches the app with `open -n` even if it was not running before.
- Builds are build 1 unless `BUILD` is set (the visible build; `CFBundleVersion` is encoded). The binary's SHA-256 goes to `build/native-sha256.txt`.
- The first launch on a Mac that ran 0.5 migrates it: see [Mac distribution](#mac-distribution). On the owner's Mac that runs too, once.
- Signing: Developer ID Application with hardened runtime and a timestamp when that identity is in the Keychain, else ad hoc; never with the app's entitlements ([setup.md](setup.md#signing)). Not notarized: releases come from `release_mac.sh`.

The Mac app is `to.yumi.yorozu`, 0.5's Mac id (`PRODUCT_BUNDLE_IDENTIFIER[sdk=macosx*]`), so Sparkle replaces 0.5 in place; iOS stays `to.yumi.yorozu.ios`. 0.5's data stays where it was and is only read by the migration.

## Mac distribution

`scripts/release_mac.sh` builds the beta into `dist/`: `Yorozu.dmg` (Developer ID, notarized with the `yorozu-notary` profile, stapled), `appcast.xml` (Sparkle's `generate_appcast`, channel `beta`, signed with 0.5's EdDSA key) and `candidate.json`. With `--publish` it replaces the `v<version>-beta` GitHub prerelease, the three assets yorozu.yumi.to/beta/appcast.xml serves (main's `apps/web/worker.mjs`); every Mac on the beta feed installs it within the hour. It is a prerelease, so `releases/latest` (the stable feed and `/mac`) stays 0.4.0. `.github/workflows/release.yml` runs `upload_ios.sh` and then it on every push to `main`, with no tests.

- Sparkle is linked for macOS only (`MacUpdates.swift`): hourly automatic installs, the beta feed by default; an explicit `YorozuBetaUpdates = false` left by 0.5 picks the stable feed. App menu: About (visible build) and Check for Updates.
- The OpenClaw plugin is copied into `Contents/Resources/openclaw-channel` by a build phase, the path 0.5's `openclaw plugins install --link` points to.
- First launch after 0.5 (`MacMigrateFrom0_5.swift`), once, without a click: remove 0.5's watchdog LaunchAgent; `openclaw config unset channels.yorozu.socketPath`; `openclaw plugins reload yorozu --accept-capabilities`, or `openclaw gateway restart --safe` if that fails or asks for a restart; pair this Mac with its own Gateway (`openclaw yorozu pair`, no fingerprint step); a notification to update the iPhone. The plugin imports 0.5's keys, devices, memory and chats when it loads.

## iOS and iPadOS: TestFlight

`scripts/upload_ios.sh --confirm`, only when the owner asks for that upload: each upload uses up its build number for good. Build-number policy: [OWNER_DECISIONS.md](../OWNER_DECISIONS.md#platform-and-release).

- Without `--confirm` it exits 64.
- It numbers the build from App Store Connect (highest build of this version plus one, so builds start at 1 per version). If that would reach 10000 it stops with exit 65: bump `version.txt` instead. `BUILD=<n>` skips both the lookup and that check.
- It archives `generic/platform=iOS` only (the iPhone and iPad app, with the notification service and share extensions); the Mac destination is never uploaded.
- `apps/ios/ExportOptions.plist` makes the export step the upload. Assign the processed build to the TestFlight groups when the Mac release goes live ([upgrade plan](upgrade-from-0.5.md#release-order)); turn off automatic distribution for the internal group so it waits.

## Compile checks

`upload_ios.sh` and `build_native.sh` are the only scripted client builds. To compile without signing, uploading or touching `/Applications`:

```sh
tuist generate --no-open --path apps/ios
# iPhone and iPad (one target, both device families), with both extensions
env -u SDKROOT xcodebuild build -workspace apps/ios/Yorozu.xcworkspace -scheme YorozuIOS \
    -destination 'generic/platform=iOS' -derivedDataPath .build/xcode-ios \
    -clonedSourcePackagesDirPath .build/xcode-packages -skipPackagePluginValidation \
    CODE_SIGNING_ALLOWED=NO
# Mac
env -u SDKROOT xcodebuild build -workspace apps/ios/Yorozu.xcworkspace -scheme YorozuIOS \
    -destination 'platform=macOS' -derivedDataPath .build/xcode-mac \
    -clonedSourcePackagesDirPath .build/xcode-packages -skipPackagePluginValidation \
    CODE_SIGNING_ALLOWED=NO
# The wire package alone
swift build --package-path packages/YorozuWire
```

The plugin typechecks per [its README](../plugins/openclaw-yorozu/README.md#typecheck).

- **Simulator**: build for `platform=iOS Simulator,id=<udid>` with `CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=` instead of `CODE_SIGNING_ALLOWED=NO`: an unsigned simulator build carries no Keychain entitlement, so saving the pairing fails with `-34018`. Install and launch with `xcrun simctl install <udid> <app>` and `xcrun simctl launch <udid> to.yumi.yorozu.ios`.
- **Running a Mac dev build** (`open -n .build/xcode-mac/Build/Products/Debug/YorozuIOS.app`): the linker signs it ad hoc, so it runs only on the Mac that built it, and Keychain access prompts come back after each rebuild. Give it a bundle id of its own (`PRODUCT_BUNDLE_IDENTIFIER=to.yumi.yorozu.ios.dev`, any distinct id) so it never passes for the installed app; its cache then lives apart, but its Keychain item still uses the service `to.yumi.yorozu.ios`, so pairing or unpairing in it can replace or delete the installed app's pairing.

## Website

https://yorozu.yumi.to is the Astro site in `apps/web` on `main`, not on `projectx`. `.github/workflows/deploy-web.yml` deploys it on every push to `main` that touches `apps/web/**`, so merging is deploying. The pairing QR carries `https://yorozu.yumi.to/pair#<query>`, and the site's `/pair` page and AASA file are what open the app from it, so those links stay.

## Not wired

- APNs on the Mac: the Mac client registers no push token; it notifies only while running.
- Merging `projectx` into `main` removes what `projectx` deleted, including `apps/web` and main's other workflows (`deploy-web.yml` deploys the site and the feed redirects). Keep those in the merge.
- App Store submission: by hand in App Store Connect after TestFlight, with `apps/ios/APP-REVIEW-NOTES.md`.

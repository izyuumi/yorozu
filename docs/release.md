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

`scripts/release_mac.sh` builds the release into `dist/`: `Yorozu.dmg` (Developer ID, notarized with the `yorozu-notary` profile, three tries, stapled), `appcast.xml` (Sparkle's `generate_appcast`, no channel, signed with 0.5's EdDSA key) and `candidate.json`. `.github/workflows/release-mac.yml` runs it on every push to `main` that touches the Mac app, with no tests:

- **Beta**: `--publish` publishes the prerelease `v<version>-beta.<build>`, the build one past the version's last beta tag. yorozu.yumi.to/beta and /beta/appcast.xml serve the newest release, prereleases included (`apps/web/worker.mjs`); Macs with beta updates on, 0.5 ones too, install it within the hour.
- **Stable**: when a push changes `version.txt`, the workflow first runs `--promote <old version> <beta>`, with the beta the bump PR names in a `Promotes: v<old>-beta.<n>` commit line, the one the owner checked (a later merge may have published a newer one; without the line the run fails). That beta is republished unchanged (its DMG, appcast and `candidate.json`; the appcast still points at the beta's DMG) as `v<old>`, the latest release, whose assets yorozu.yumi.to/appcast.xml and /mac serve (`releases/latest`). Every Mac installs it within the hour, 0.4 and 0.5 ones included. If `v<old>` already exists it does nothing: release tags can be neither moved nor deleted (repository ruleset), so a version has one stable release.
- Sparkle is linked for macOS only (`MacUpdates.swift`): hourly automatic installs from the stable feed, or the beta feed with Settings › Updates › Beta Updates on (`feedURLString(for:)`). App menu: About (visible build) and Check for Updates.
- The OpenClaw plugin is copied into `Contents/Resources/openclaw-channel` by a build phase, the path 0.5's `openclaw plugins install --link` points to.
- First launch after 0.5 (`MacMigrateFrom0_5.swift`), once, without a click: remove 0.5's watchdog LaunchAgent; `openclaw config unset channels.yorozu.socketPath`; `openclaw plugins reload yorozu --accept-capabilities`, or `openclaw gateway restart --safe` if that fails or asks for a restart; pair this Mac with its own Gateway (`openclaw yorozu pair`, no fingerprint step); a notification to update the iPhone. The plugin imports 0.5's keys, devices, memory and chats when it loads.

## iOS and iPadOS: TestFlight

The iOS launch screen centers the inner oval mark from the app icon, without its square icon background. The mark has light and dark asset variants; the launch background uses the system color. It appears only while iOS starts the app; there is no artificial splash delay.

`scripts/upload_ios.sh --confirm` runs from `.github/workflows/release-ios.yml` on every push to `main` that touches `apps/ios/**`, `packages/**`, `version.txt` or its scripts; plugin-only changes upload nothing, as the plugin rides only in the Mac app. Each upload uses up its build number for good. Build-number policy: [OWNER_DECISIONS.md](../OWNER_DECISIONS.md#platform-and-release).

- Without `--confirm` it exits 64.
- It numbers the build from App Store Connect (highest build of this version plus one, so builds start at 1 per version). If that would reach 10000 it stops with exit 65: bump `version.txt` instead. `BUILD=<n>` skips both the lookup and that check.
- It archives `generic/platform=iOS` only (the iPhone and iPad app, with the notification service and share extensions); the Mac destination is never uploaded.
- `apps/ios/ExportOptions.plist` makes the export step the upload. TestFlight gives each processed build to the internal group automatically: that is the iOS beta. The App Store version is submitted by hand when `version.txt` moves on.
- The app and its extensions target iPhone and iPad only, and App Store Connect does not offer the app on Apple Silicon Macs (Pricing and Availability): Macs get the Developer ID app.

## Compile checks

`upload_ios.sh`, `release_mac.sh` and `build_native.sh` are the only scripted client builds. Pull requests run the first two commands below (`.github/workflows/checks.yml`, with the relay's `pnpm --filter @yorozu/relay test`); each job runs only when its files changed. To compile without signing, uploading or touching `/Applications`:

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

https://yorozu.yumi.to is the Astro site in `apps/web`. `.github/workflows/deploy-web.yml` deploys it on every push to `main` that touches `apps/web/**`, so merging is deploying. The relay (`apps/relay`, relay.yumi.to) works the same way: `.github/workflows/deploy-relay.yml` runs its typecheck and tests, then `wrangler deploy`, on every push to `main` that touches `apps/relay/**`. The pairing QR carries `https://yorozu.yumi.to/pair#<query>`, and the site's `/pair` page and AASA file are what open the app from it, so those links stay.

## Not wired

- APNs on the Mac: the Mac client registers no push token; it notifies only while running.
- App Store submission: by hand in App Store Connect after TestFlight, with `apps/ios/APP-REVIEW-NOTES.md`.

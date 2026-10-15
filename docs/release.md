# Release

How the client app is versioned, built for the Mac, uploaded to TestFlight for iPhone and iPad, and compile-checked. The plugin has no release step: the Gateway loads it from the linked checkout ([setup.md](setup.md#1-install-the-plugin)). Credentials and signing are in [setup.md](setup.md#signing); the steps each script runs are in its header comment.

## Version

`version.txt` holds one numeric `major.minor.patch` for the client on every platform. `apps/ios/Project.swift` stops with a fatal error on any other format. Both scripts pass `MARKETING_VERSION` to `xcodebuild` explicitly, because Tuist caches the manifest and a `version.txt` change alone may not reach the build. Bump `version.txt` when a new version is needed, for example to bring iOS build numbers back to 1.

A minor version that breaks the wire also raises the protocol in `peer_info` (`protocolMin` / `protocolMax`, 3 for wire v3; [contract](ios-relay-contract.md#peer_info)), on both the client and the plugin. A client and plugin without a common version stop with "Update required", so such a change ships to the plugin and the clients together.

## Mac client

`scripts/build_native.sh` builds the client's macOS destination (`apps/ios`, scheme `YorozuIOS`, Release) into `.build/xcode-native` and replaces `/Applications/Yorozu.app` in place, the one Yorozu on the owner's Mac (owner, 2026-10-12). Run it from the main checkout.

- Without `--restart` it exits 3 while `/Applications/Yorozu.app` is running.
- It quits only the app at that path, by pid: any executable in the bundle, so the old host app it replaces is matched too.
- `--restart` relaunches the app with `open -n` even if it was not running before.
- Builds are build 1 unless `BUILD` is set. The binary's SHA-256 goes to `build/native-sha256.txt`.
- Signing: Developer ID Application with hardened runtime and a timestamp when that identity is in the Keychain, else ad hoc; never with the app's entitlements ([setup.md](setup.md#signing)). Not notarized, no update feed.

The bundle id changed with #426: `/Applications/Yorozu.app` used to be the Mac host (`to.yumi.yorozu`, v1's id) and is now the client (`to.yumi.yorozu.ios`, the same id as the iOS app). The client keeps nothing of the host's: the host's data (`~/Library/Application Support/to.yumi.yorozu/`, `~/Yorozu/`) and its Keychain items stay where they were, unused, until the owner removes them, and the Mac pairs again with `openclaw yorozu pair` like any device.

## iOS and iPadOS: TestFlight

`scripts/upload_ios.sh --confirm`, only when the owner asks for that upload: each upload uses up its build number for good. Build-number policy: [OWNER_DECISIONS.md](../OWNER_DECISIONS.md#platform-and-release).

- Without `--confirm` it exits 64.
- It numbers the build from App Store Connect (highest build of this version plus one, so builds start at 1 per version). If that would reach 10000 it stops with exit 65: bump `version.txt` instead. `BUILD=<n>` skips both the lookup and that check.
- It archives `generic/platform=iOS` only (the iPhone and iPad app, with the notification service and share extensions); the Mac destination is never uploaded.
- `apps/ios/ExportOptions.plist` makes the export step the upload, internal testing only. The build reaches the Internal TestFlight group once App Store Connect has processed it.

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

- Mac distribution: no notarization, update feed, Mac App Store or TestFlight for Mac. The old host's `release_mac.sh` and Sparkle feed went with it (#426). A distributed Mac client needs the entitlements in their macOS form and a macOS provisioning profile for `to.yumi.yorozu.ios`, then either TestFlight for Mac on the same App Store Connect app (universal purchase) or Developer ID with notarization and an update feed.
- APNs on the Mac: the Mac client registers no push token; it notifies only while running.
- v1's release process on `main` (Release Please, GitHub Actions release and promote workflows, Sparkle appcasts) does not apply to `projectx`, which has no CI.
- Public App Store release: not requested; iOS goes to internal TestFlight only.

# Release

How the client app (`apps/ios`) is versioned, built, shipped and compile-checked, and how the website and relay deploy. The plugin has no release step of its own: the Gateway loads it from a linked checkout ([setup.md](setup.md#1-install-the-plugin)), and the Mac app carries a copy. Bundle ids, team and entitlements are set in `apps/ios/Project.swift`.

## Version and build numbers

- `version.txt` holds one numeric `major.minor.patch` for every platform. `apps/ios/Project.swift` stops with a fatal error on any other format.
- The visible build restarts at 1 per version. It is stored in the Info.plist key `YorozuBuild` (build setting `YOROZU_BUILD`).
- `CFBundleVersion` encodes version and build as one integer, computed by `scripts/build-number.sh <version> <build>` (same formula as `bundleVersion` in `Project.swift`):

  ```
  major·10⁷ + minor·10⁵ + patch·10³ + build      e.g. 0.9.0 build 1 = 900001
  ```

  The script exits 64 on a non-numeric input and 65 unless minor and patch are below 100 and build is 1 to 999. Sparkle compares this integer, so it must only ever rise.
- Every script passes `MARKETING_VERSION`, `CURRENT_PROJECT_VERSION` and `YOROZU_BUILD` to `xcodebuild` explicitly: Tuist caches the manifest, so a `version.txt` change alone may not reach the build.
- A wire-breaking change raises the protocol in `peer_info` (`protocolMin` / `protocolMax`, currently 3; [contract](ios-relay-contract.md#peer_info)) on both client and plugin; a client and plugin without a common version show an update-required state, so such a change ships to both together.

## CI

| Workflow | Trigger | Does |
|---|---|---|
| `checks.yml` | every pull request | `app` job (when `apps/ios/`, `packages/`, `plugins/`, `version.txt` or the workflow changed): the iOS and Mac compile checks below. `relay` job (when `apps/relay/`, `pnpm-lock.yaml` or the workflow changed): `pnpm --filter @yorozu/relay test` (typecheck + vitest). A skipped job counts as passed. |
| `release-mac.yml` | push to `main` touching `apps/**` (except `apps/web/**`, `apps/relay/**`), `packages/**`, `plugins/**`, `scripts/**` or `version.txt`; manual | Promotes a beta if `version.txt` changed, then `scripts/release_mac.sh --publish`. |
| `release-ios.yml` | push to `main` touching `apps/ios/**`, `packages/**`, `version.txt`, `scripts/upload_ios.sh` or `scripts/build-number.sh`; manual | `scripts/upload_ios.sh --confirm`. |
| `deploy-web.yml` | push to `main` touching `apps/web/**`; manual | `pnpm --filter @yorozu/web build`, `… test`, then `wrangler deploy`. |
| `deploy-relay.yml` | push to `main` touching `apps/relay/**`; manual | `pnpm --filter @yorozu/relay test`, then `wrangler deploy`. |

The Apple jobs run on the `xcode-27` runner with Xcode 27.1 and install Tuist through mise at the version pinned in `mise.toml`, as `mise install` does locally. The release workflows run no tests. Secrets, by name: `release-mac.yml` uses `DEVELOPER_ID_P12`, `DEVELOPER_ID_PASSWORD`, `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8`, `SPARKLE_ED_KEY`; `release-ios.yml` uses `MAC_CERT_P12`, `MAC_CERT_PASSWORD` (the Apple Distribution identity, despite the name), `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8`; the deploy workflows use `CLOUDFLARE_API_TOKEN`.

Dependabot (`.github/dependabot.yml`) proposes weekly updates for the pinned GitHub Actions and the pnpm workspace (minor and patch grouped into one PR), each after a 3-day cooldown; major bumps of `vitest` and `typescript` are ignored.

## Mac: local build

`scripts/build_native.sh [--restart]` builds the macOS destination (scheme `YorozuIOS`, Release) into `.build/xcode-native` and replaces `/Applications/Yorozu.app` in place. Run it from the main checkout.

- Exits 3 if the app at that path is running, unless `--restart` is given. With `--restart` it quits that app's processes by pid after a successful build, swaps the bundle and relaunches with `open -n`.
- Visible build is 1 unless `BUILD` is set.
- Signs with "Developer ID Application" (hardened runtime, timestamp) when that identity is in the Keychain, else ad hoc; always without the app's entitlements (no macOS provisioning profile exists for the Mac bundle id).
- Writes the binary's SHA-256 to `build/native-sha256.txt`. Not notarized.

The macOS destination's bundle id differs from iOS (`PRODUCT_BUNDLE_IDENTIFIER[sdk=macosx*]` in `Project.swift`). A post-build phase copies the plugin (`index.ts`, `setup-entry.ts`, `openclaw.plugin.json`, `package.json`, `README.md`, `src`) into `Contents/Resources/openclaw-channel` on macOS.

## Mac: beta and stable releases

`scripts/release_mac.sh` builds into `dist/`:

1. Release build with the Developer ID identity, no entitlements; re-signs Sparkle's nested helpers, the framework and the app; checks the bundle id and that the bundled plugin is present.
2. `Yorozu.dmg`: signed, notarized with the notarytool keychain profile (`NOTARY_PROFILE`, default `yorozu-notary`; up to three tries), stapled.
3. `appcast.xml` from Sparkle's `generate_appcast` (EdDSA-signed; `SPARKLE_ED_KEY_FILE` or the login Keychain), download URLs pointing at the release tag.
4. `candidate.json` (tag, version, `CFBundleVersion`, source commit).

Modes:

- No flag: build only. Visible build is `BUILD`, else the build of the current `v<version>-beta` release (from its `candidate.json`) plus one (needs `gh`).
- `--publish`: refuses a dirty tree, deletes the existing `v<version>-beta` release and tag, then creates the prerelease `v<version>-beta` with the three assets and notes from `scripts/release_notes.sh` (feat, fix and perf Conventional Commits since the last stable tag, dependency bumps left out). A version has one beta release.
- `--promote <version> <build>`: if `v<version>` does not exist yet and `v<version>-beta` is still that build, downloads its assets, points the appcast at the stable release, and republishes them as `v<version>`, marked latest, with generated notes. Fails if the beta is a different build; does nothing if `v<version>` exists.

`release-mac.yml` runs the promotion first when a push changes `version.txt`: `<version>` is the previous `version.txt`, and the build comes from the last `Promotes: <old> (<build>)` line in the pushed commit messages. Without that line the promotion and the run fail (unless `v<old>` is already released). It then publishes the new version's first beta.

Feeds and downloads (`apps/web/worker.mjs`, `apps/web/public/_redirects`):

- `yorozu.yumi.to/appcast.xml` and `/mac`: the latest stable release's appcast and DMG.
- `yorozu.yumi.to/beta` and `/beta/appcast.xml`: the newest release, prereleases included.

The Mac app links Sparkle (macOS only, `MacUpdates.swift`): stable feed from `SUFeedURL`, automatic checks and installs every hour; Settings › Updates › Beta Updates switches to the beta feed (`feedURLString(for:)`).

## iOS and iPadOS: TestFlight

`scripts/upload_ios.sh --confirm` archives and uploads. Each upload uses up its build number.

- Without `--confirm` it exits 64. Needs `ASC_KEY_ID`, `ASC_ISSUER_ID` and the `.p8` key (`ASC_KEY_PATH`, else `~/.appstoreconnect/private_keys/AuthKey_<id>.p8`).
- Visible build: the highest build App Store Connect has for this version, plus one; `BUILD=<n>` skips the lookup. Either way `build-number.sh` rejects a build past 999 (exit 65): bump `version.txt` instead.
- Archives `generic/platform=iOS` only (app plus notification service and share extensions) with automatic signing and `-allowProvisioningUpdates`. The Mac destination is never uploaded.
- `apps/ios/ExportOptions.plist` (`destination` = `upload`) makes the export step the upload. TestFlight gives processed builds to the internal group.
- App Store submission is by hand in App Store Connect (review notes: `apps/ios/APP-REVIEW-NOTES.md`).

## Compile checks

The commands `checks.yml` runs, without signing, uploading or touching `/Applications` (CI adds `-quiet`):

```sh
mise install                                   # Tuist
tuist generate --no-open --path apps/ios
# iPhone and iPad, with both extensions
env -u SDKROOT xcodebuild build -workspace apps/ios/Yorozu.xcworkspace -scheme YorozuIOS \
    -destination 'generic/platform=iOS' -derivedDataPath .build/xcode-ios \
    -clonedSourcePackagesDirPath .build/xcode-packages -skipPackagePluginValidation \
    CODE_SIGNING_ALLOWED=NO
# Mac
env -u SDKROOT xcodebuild build -workspace apps/ios/Yorozu.xcworkspace -scheme YorozuIOS \
    -destination 'platform=macOS' -derivedDataPath .build/xcode-mac \
    -clonedSourcePackagesDirPath .build/xcode-packages -skipPackagePluginValidation \
    CODE_SIGNING_ALLOWED=NO
```

Not in CI:

```sh
swift build --package-path packages/YorozuWire   # the wire package alone
pnpm --filter @yorozu/web test                   # the website (deploy-web.yml runs it before deploying)
```

The plugin typechecks per [its README](../plugins/openclaw-yorozu/README.md#typecheck).

- **Simulator**: build for `platform=iOS Simulator,id=<udid>` with `CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=` instead of `CODE_SIGNING_ALLOWED=NO`; an unsigned simulator build has no Keychain entitlement, so saving a pairing fails. Install and launch with `xcrun simctl install <udid> <app>` and `xcrun simctl launch <udid> <iOS bundle id>`.
- **Mac dev build**: the Mac compile check builds Debug at `.build/xcode-mac/Build/Products/Debug/YorozuIOS.app` under the installed app's bundle id. To run one, add `PRODUCT_BUNDLE_IDENTIFIER=<an id of its own>` so it never passes for `/Applications/Yorozu.app`. It is ad hoc signed (runs only on the Mac that built it; Keychain prompts after each rebuild), and its Keychain items still use the iOS bundle id as service, so pairing or unpairing in it can replace or delete the installed app's pairing.

## Website and relay

- `apps/web`: Astro site served by a Cloudflare Worker (`worker.mjs`, `wrangler.jsonc`) at yorozu.yumi.to. `pnpm --filter @yorozu/web dev|build|test`; `pnpm --filter @yorozu/web run deploy` deploys by hand. Its `/pair` page and `.well-known/apple-app-site-association` open the app from the pairing QR's web link (`applinks:yorozu.yumi.to`), so those paths must stay.
- `apps/relay`: Cloudflare Worker with Durable Objects (`wrangler.toml`) at relay.yumi.to. `pnpm --filter @yorozu/relay test` runs its typecheck and tests.


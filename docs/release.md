# Release

How the client app (`apps/ios`) is versioned, built, shipped and compile-checked, and how the website and relay deploy. The plugin has no release step of its own: the Gateway loads it from a linked checkout ([setup.md](setup.md#1-install-the-plugin)), and the Mac app carries a copy. Bundle ids, team and entitlements are set in `apps/ios/Project.swift`.

## Version and build numbers

- The version follows SemVer and is the same on every platform. `scripts/version.sh` computes it from the Conventional Commits since the last stable tag `v<major.minor.patch>`: a breaking change (`type!:` or a `BREAKING CHANGE:` footer) bumps major (minor while below 1.0), a `feat` bumps minor, anything else patch. Nobody picks it by hand. The scripts need the tags (`fetch-depth: 0` in CI). `VERSION=<x.y.z>` overrides it. `apps/ios/Project.swift` holds only a placeholder `0.0.0`.
- The visible build restarts at 1 per version. It is stored in the Info.plist key `YorozuBuild` (build setting `YOROZU_BUILD`).
- `CFBundleVersion` encodes version and build as one integer, computed by `scripts/build-number.sh <version> <build>` (same formula as `bundleVersion` in `Project.swift`):

  ```
  major·10⁷ + minor·10⁵ + patch·10³ + build      e.g. 0.9.0 build 1 = 900001
  ```

  The script exits 64 on a non-numeric input and 65 unless minor and patch are below 100 and build is 1 to 999. Sparkle compares this integer, so it must only ever rise.
- Every script passes `MARKETING_VERSION`, `CURRENT_PROJECT_VERSION` and `YOROZU_BUILD` to `xcodebuild` explicitly: Tuist caches the manifest, and the manifest holds only a placeholder version.
- A wire-breaking change raises the protocol in `peer_info` (`protocolMin` / `protocolMax`, currently 3; [contract](ios-relay-contract.md#peer_info)) on both client and plugin; a client and plugin without a common version show an update-required state, so such a change ships to both together.

## CI

| Workflow | Trigger | Does |
|---|---|---|
| `checks.yml` | every pull request | `app` job (when `apps/ios/`, `packages/`, `plugins/` or the workflow changed): the iOS and Mac compile checks below. `relay` job (when `apps/relay/`, `pnpm-lock.yaml` or the workflow changed): `pnpm --filter @yorozu/relay test` (typecheck + vitest). A skipped job counts as passed. `release-guards` job (always): `scripts/external_testflight.sh --audit` ([TestFlight](#ios-and-ipados-testflight)). |
| `release-mac.yml` | push to `main` touching `apps/**` (except `apps/web/**`, `apps/relay/**`), `packages/**`, `plugins/**`, or `scripts/**`; manual | `scripts/release_mac.sh --publish`, which then opens or updates the release PR. |
| `promote.yml` | the release PR (branch `release`) merged | `scripts/release_mac.sh --promote <build> <sha> <digest>` with the PR's `Release-Build:`, `Release-Commit:` and `Release-Digest:` lines. |
| `release-ios.yml` | push to `main` touching `apps/ios/**`, `packages/**`, `scripts/upload_ios.sh`, `scripts/version.sh` or `scripts/build-number.sh`; manual | `scripts/upload_ios.sh --confirm`. |
| `deploy-web.yml` | push to `main` touching `apps/web/**`; manual | `pnpm --filter @yorozu/web build`, `… test`, then `wrangler deploy`. |
| `deploy-relay.yml` | push to `main` touching `apps/relay/**`; manual | `pnpm --filter @yorozu/relay test`, then `wrangler deploy`. |

The Apple jobs run on the `xcode-27` runner with Xcode 27.1 and install Tuist through mise at the version pinned in `mise.toml`, as `mise install` does locally. The release workflows run no tests. Secrets, by name: `release-mac.yml` uses `DEVELOPER_ID_P12`, `DEVELOPER_ID_PASSWORD`, `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8`, `SPARKLE_ED_KEY`; `release-ios.yml` uses `MAC_CERT_P12`, `MAC_CERT_PASSWORD` (the Apple Distribution identity, despite the name), `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8`; the deploy workflows use `CLOUDFLARE_API_TOKEN`.

Dependabot (`.github/dependabot.yml`) proposes weekly updates for the pinned GitHub Actions and the pnpm workspace (minor and patch grouped into one PR), each after a 3-day cooldown; major bumps of `vitest` and `typescript` are ignored.

## Mac: local build

`scripts/build_native.sh [--restart]` builds the macOS destination (scheme `YorozuIOS`, Release) into `.build/xcode-native` and replaces `/Applications/Yorozu.app` in place. Run it from the main checkout.

- Exits 3 if the app at that path is running, unless `--restart` is given. With `--restart` it quits that app's processes by pid after a successful build, swaps the bundle and relaunches with `open -n`.
- Visible build is 1 unless `BUILD` is set.
- Signs with "Developer ID Application" (hardened runtime, timestamp) when that identity is in the Keychain, else ad hoc; always without the app's entitlements (no macOS provisioning profile exists for the Mac bundle id), except the microphone entitlement in `apps/ios/Resources/MacHardenedRuntime.entitlements`, which needs no profile.
- Writes the binary's SHA-256 to `build/native-sha256.txt`. Not notarized.

The macOS destination's bundle id differs from iOS (`PRODUCT_BUNDLE_IDENTIFIER[sdk=macosx*]` in `Project.swift`). A post-build phase copies the plugin (`index.ts`, `setup-entry.ts`, `openclaw.plugin.json`, `package.json`, `README.md`, `src`) into `Contents/Resources/openclaw-channel` on macOS.

## Mac: beta and stable releases

`scripts/release_mac.sh` builds into `dist/`:

1. Release build with the Developer ID identity, no entitlements; re-signs Sparkle's nested helpers, the framework and the app; checks the bundle id and that the bundled plugin is present.
2. `Yorozu.dmg`: signed, notarized with the notarytool keychain profile (`NOTARY_PROFILE`, default `yorozu-notary`; up to three tries), stapled.
3. `appcast.xml` from Sparkle's `generate_appcast` (EdDSA-signed; `SPARKLE_ED_KEY_FILE` or the login Keychain), download URLs pointing at the release tag.
4. `candidate.json` (tag, version, `CFBundleVersion`, source commit).

Modes:

- No flag: build only. Visible build is `BUILD`, else the build of the current beta release of this version (from its `candidate.json`) plus one, or 1. It also goes past the highest `v<version>-beta.<n>` tag left from before the single beta, so Sparkle still sees the build rise.
- `--publish`: refuses a dirty tree, deletes the current beta release and its `v<version>-beta` tag (the `release tags` ruleset makes `v*` tags immutable but leaves `*-beta` alone; an older `v<version>-beta.<n>` tag stays, and only its release goes), then creates the prerelease `v<version>-beta` with the three assets and notes from `scripts/release_notes.sh` (feat, fix and perf Conventional Commits since the last stable tag, dependency bumps left out). A version has one beta release, which each build replaces, and there is one beta at a time; when a `feat` lands, the next beta moves to the new minor version.
- `--promote <build> <source sha> <sha256:digest>`: if `v<version>` does not exist yet and the current beta `v<version>-beta` (or an older `v<version>-beta.<n>`) is still exactly the release the release PR named, downloads its assets, points the appcast at the stable release, republishes them as `v<version>`, marked latest, with generated notes, then deletes the beta release and, for `v<version>-beta`, its tag (the beta feed falls back to the stable release until the next beta). Does nothing if `v<version>` exists. Before publishing anything it checks that `candidate.json`'s build is that build's `CFBundleVersion`, its tag is the beta's and its `source_sha` is the named commit; that the release's target commit and the commit the tag points at are the named commit (a moved tag fails); and that `Yorozu.dmg`'s digest, as GitHub reports it and as downloaded, is the named digest. Every mismatch is reported as an error, and it exits 1 without publishing or deleting anything; a missing or malformed argument exits 64.

Stable releases work like release-please. After each beta, `scripts/release_pr.sh` resets the branch `release` to the beta's commit, commits `CHANGELOG.md` with the version's notes through the contents API (so GitHub signs it, as the `main` ruleset requires), opens or updates the PR `chore: release <version>`, whose body ends with `Release-Build: <build>`, `Release-Commit: <source sha>` and `Release-Digest: sha256:<DMG digest>`, and approves the PR's `checks.yml` run, which waits for approval because a bot opened the PR (with only `CHANGELOG.md` changed, both required checks skip, which counts as passing; if the Actions token may not approve, approve it on the PR by hand). Check that beta, then merge the PR: `promote.yml` promotes the named build. A newer beta updates the PR to name it, and `--promote` refuses a beta that is not the named build, commit and DMG; then nothing is promoted, and the next beta opens a new release PR. Merging changes only `CHANGELOG.md`, so it starts no new beta; the next push does.

Feeds and downloads (`apps/web/worker.mjs`, `apps/web/public/_redirects`):

- `yorozu.yumi.to/appcast.xml` and `/mac`: the latest stable release's appcast and DMG.
- `yorozu.yumi.to/beta` and `/beta/appcast.xml`: the newest release, prereleases included.

Release notes come from `scripts/release_notes.sh [<commit>]`: the pull requests merged into `main` since the last stable tag (never a `-beta` tag), each with its number, grouped by the feat, fix and perf Conventional Commits types of their titles, with dependency bumps and other types left out. A PR is a merge `Merge pull request #N …` on `main`'s first-parent line (titled by the merge's body) or a squashed commit ending `(#N)`; a commit pushed straight to `main` counts by its subject. `<` and `>` are escaped for Markdown. Every `--publish` writes them into the beta's body again, so it always lists everything since the last stable release; the release PR, `CHANGELOG.md` and the stable release use the same notes, and `--what-to-test <locale> <version> <build>` gives a TestFlight build's What to Test in one locale ([TestFlight](#ios-and-ipados-testflight)). These notes stay in English: the release body, the release PR and `CHANGELOG.md` are read on GitHub, which has no per-language text.

The Mac app links Sparkle (macOS only, `MacUpdates.swift`): stable feed from `SUFeedURL`, automatic checks and installs every hour; Settings › About has the Sparkle switches, Check Now and the last check; its Update to: Beta Versions switches to the beta feed (`feedURLString(for:)`).

## iOS and iPadOS: TestFlight

`scripts/upload_ios.sh --confirm` archives and uploads. Each upload uses up its build number.

- Without `--confirm` it exits 64. Needs `ASC_KEY_ID`, `ASC_ISSUER_ID` and the `.p8` key (`ASC_KEY_PATH`, else `~/.appstoreconnect/private_keys/AuthKey_<id>.p8`).
- External TestFlight is off. The repository variable `YOROZU_EXTERNAL_TESTFLIGHT` is unset, and `release-ios.yml` passes it to the upload step. Nothing in CI gives a build to an external TestFlight group or submits it to Beta App Review; a step that ever does must run `scripts/external_testflight.sh` first and stop unless it exits 0, which it does only when the variable is exactly `true` (unset, empty, `false` or `TRUE` exit 1). `scripts/upload_ios.sh` prints the switch's state before it archives. The `release-guards` job in `checks.yml` runs `scripts/external_testflight.sh --audit`, which fails a pull request whose workflows or scripts name an App Store Connect group or Beta App Review call (`betaGroups`, `betaAppReviewSubmissions`, …) without running the switch.
- Visible build: the highest build App Store Connect has for this version, plus one; `BUILD=<n>` skips the lookup. A build reaches that list minutes after its upload (about 15 for 0.10.0 build 6), so after uploading the script waits up to `LIST_WAIT` seconds (default 3600) until App Store Connect lists it, and fails if it never does; `release-ios.yml` runs one upload at a time (concurrency group `release-ios`), so the next merge's upload starts only after the previous build is listed and cannot reuse its number. Either way `build-number.sh` rejects a build past 999 (exit 65): promote, so the next build starts a new version.
- Archives `generic/platform=iOS` only (app plus notification service and share extensions) with automatic signing and `-allowProvisioningUpdates`. The Mac destination is never uploaded.
- `apps/ios/ExportOptions.plist` (`destination` = `upload`) makes the export step the upload. TestFlight gives processed builds to the internal group.
- After the upload it sets the build's What to Test in every language the app ships in: one folder per App Store Connect locale in `apps/ios/metadata/testflight` (`en-US`, `ja`, `zh-Hans`, `zh-Hant`, `ko`, `es-ES`, `fr-FR`, `de-DE`, `pt-BR`), each giving `scripts/release_notes.sh --what-to-test` its intro (`Yorozu <version> (<build>), beta.` in English), a note, the section headings and the closing line. The PRs are the Mac beta's, with their titles as written: CI has no translation. Each locale's text stays within App Store Connect's 4,000 bytes (past that the list ends with `… and N more`, in that language). A locale the build lacks is created; one it has is set only while empty or still holding this script's text for this build, so What to Test written by hand stays, and locales without a folder are left alone. What to Test belongs to the build, so only the groups that get the build see it: the internal group. The script adds the build to no group and submits nothing to Beta App Review. If App Store Connect refuses the text, the job fails after the upload with an error saying so; set it in App Store Connect by hand.
- The beta app description testers see, per locale, comes from `apps/ios/metadata/testflight/<locale>/description.txt` through `scripts/testflight_metadata.sh`, run by hand and never in CI: it belongs to the app, so external testers see it too. Without `--apply` it only reads App Store Connect and prints what it would change. It creates missing locales and fills empty fields; the feedback email and the marketing and privacy policy URLs are copied from `en-US`, so they live in App Store Connect alone. A description that differs from its file is kept and reported. Running it twice changes nothing the second time.
- The App Store listing per locale (name, subtitle, keywords, promotional text, description, What's New) comes from `apps/ios/metadata/app_store/<locale>/` through `scripts/app_store_metadata.sh`, run by hand and never in CI. It only edits the iOS version already being prepared in App Store Connect and never creates or submits one; submitting stays manual. Without `--apply` it only reads and prints its plan. Like the beta description, it creates missing locales, fills empty fields, copies the URLs from `en-US`, and keeps and reports text that differs from its file. `--check` checks the files against App Store Connect's limits offline, and Checks runs it on every PR.
- App Store submission is by hand in App Store Connect (review notes: `apps/ios/APP-REVIEW-NOTES.md`).

## Voice model asset pack

On iPhone and iPad the voice model is an Apple-hosted, on-demand asset pack (ID `VoiceModel`, `VoiceModel.packID`), uploaded once and updated independently of app builds. `scripts/voice_asset_pack.sh <dir>` downloads the pinned files, checks their SHA-256 and writes `<dir>/VoiceModel.aar`; upload it with Transporter, then submit it for review in App Store Connect with a build. A new model revision needs the script, `VoiceModel.files` and the pack updated together.

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

- **Simulator**: generate with `TUIST_VOICE_INPUT=0 tuist generate --no-open --path apps/ios` (llama.cpp's xcframework has no simulator slice, so this leaves voice input out), then build for `platform=iOS Simulator,id=<udid>` with `CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=` instead of `CODE_SIGNING_ALLOWED=NO`; an unsigned simulator build has no Keychain entitlement, so saving a pairing fails. Install and launch with `xcrun simctl install <udid> <app>` and `xcrun simctl launch <udid> <iOS bundle id>`.
- **Mac dev build**: the Mac compile check builds Debug at `.build/xcode-mac/Build/Products/Debug/YorozuIOS.app` under the installed app's bundle id. To run one, add `PRODUCT_BUNDLE_IDENTIFIER=<an id of its own>` so it never passes for `/Applications/Yorozu.app`. It is ad hoc signed (runs only on the Mac that built it; Keychain prompts after each rebuild), and its Keychain items still use the iOS bundle id as service, so pairing or unpairing in it can replace or delete the installed app's pairing.

## Website and relay

- `apps/web`: Astro site served by a Cloudflare Worker (`worker.mjs`, `wrangler.jsonc`) at yorozu.yumi.to. `pnpm --filter @yorozu/web dev|build|test`; `pnpm --filter @yorozu/web run deploy` deploys by hand. Its `/pair` page and `.well-known/apple-app-site-association` open the app from the pairing QR's web link (`applinks:yorozu.yumi.to`), so those paths must stay.
- `apps/relay`: Cloudflare Worker with Durable Objects (`wrangler.toml`) at relay.yumi.to. `pnpm --filter @yorozu/relay test` runs its typecheck and tests.


# Releasing

Release Please runs on pushes to `main`, collecting Conventional Commits into a version and
changelog PR. Merging that PR creates a tagged draft release and builds the Mac app in the same
workflow. After signing, notarization and asset upload succeed, it publishes the release as
latest and deletes older published releases. Git tags and draft releases are preserved.

The workflow uses `GITHUB_TOKEN`; no personal access token is needed. Repository Actions
settings must allow GitHub Actions to create pull requests. Bot-created PRs do not trigger
`pull_request` CI automatically; close and reopen the PR as a maintainer to run those checks
before merging. Builds run in the same workflow because bot-created tags do not trigger CI.

## Versions

Neither number is typed. The marketing version is the latest `v*` tag and `CFBundleVersion` is the
commit count, which rises with every commit and never repeats. Sparkle compares `CFBundleVersion`,
so that is what makes one build newer than another, and the build number is in the DMG's name so
two builds of one tag are two files rather than one URL with two meanings. `scripts/build-ios.sh`
derives both the same way.

`apps/ios/Project.swift` and `scripts/dev-bundle.sh` read `version.txt` for development builds
and append `-beta` to the display label. Release Please maintains that file. Shipping builds
continue to use the release tag and explicit build-script overrides.

## The Mac DMG

```sh
./scripts/build-mac.sh          # prints dist/Yorozu-0.2.1-<n>.dmg
```

It builds the workspace and the Swift release binaries, then assembles `Yorozu.app` with the
runtime *inside* it — the official `node` for this platform downloaded to `Contents/Resources/node`
and the sidecar plus its production dependencies deployed next to it — so the app needs nothing
installed to run. `YOROZU_RUNTIME_CMD` defaults to that bundled pair whenever the app finds it,
and falls back to the dev checkout layout otherwise.

It is deliberately not *this machine's* `node`. A Homebrew node is a stub linked against
`@rpath/libnode.<abi>.dylib` and a dozen other Homebrew dylibs that no `.app` carries, so a bundle
built around one dies at launch with "Library not loaded" — and because the app only checks that
the bundled node *exists* before preferring it, that failure is silent: the sidecar never starts
and the menu bar sits at `starting`. The nodejs.org build links nothing but system frameworks. The
tarball is cached in `dist/`, and the build runs `node --version` once before signing so a node
that cannot start fails the build rather than the user.

The bundle is Developer ID signed with the hardened runtime and `apps/mac/Yorozu.entitlements`,
which is only the three exceptions Node needs: JIT, unsigned executable memory, and library
validation off. There is no sandbox — the agent drives the whole Mac. The DMG is signed too.

The bundled runtime is large: `@openai/codex` and `@anthropic-ai/claude-agent-sdk` vendor ~277 MB
and ~194 MB of platform binaries respectively, which is most of the DMG.

### Notarizing

Notarization needs an App Store Connect API key — the `.p8`, its key ID, and the **issuer ID**
from the Users and Access → Integrations page. Store it once as a keychain profile and
`build-mac.sh` picks it up:

```sh
xcrun notarytool store-credentials yorozu-notary \
  --key ~/.appstoreconnect/private_keys/AuthKey_<KEYID>.p8 --key-id <KEYID> --issuer <ISSUER-UUID>
```

Without one it prints `notarization skipped: no profile` and carries on, leaving the DMG Developer
ID signed but not notarized — Gatekeeper then asks on first launch instead of opening silently.

### Sparkle

The update feed is signed with an EdDSA key kept in the login keychain locally and provided
to CI through the `SPARKLE_ED_KEY` repository secret:

```sh
./apps/mac/.build/artifacts/sparkle/Sparkle/bin/generate_keys   # once, prints the public key
./scripts/appcast.sh                                            # writes dist/appcast.xml
```

The public key goes in `SU_PUBLIC_KEY` in `build-mac.sh`, which writes it into the app's
`Info.plist` beside `SUFeedURL`, along with the keys that make updates automatic
(`SUEnableAutomaticChecks`, `SUAutomaticallyUpdate`, `SUAllowsAutomaticUpdates`, and an hourly
`SUScheduledCheckInterval`). Those are only a *default*, for a Mac that has never run the app;
`Updater.swift` turns the same three on once per machine so an answer given to an older build's
"check automatically?" prompt does not keep the Mac on an old version forever.

Sparkle's scheduling is opaque from the outside — the Mac that sat three releases behind said
nothing about why — so `Updates.logStatus()` writes one line to `~/Library/Logs/Yorozu/app.log` at
launch and every hour: `canCheck`, whether automatic checks and downloads are on, the interval,
and how long ago the last check was. If it cannot check it logs why, and a check overdue by more
than two intervals is nudged with `checkForUpdatesInBackground()`. Installing does not wait for a
quit: with no chat window open Sparkle is told to install immediately, and never to postpone the
relaunch.

### Cutting a release

Use `fix:` for patch releases, `feat:` for minor releases, and `!` or `BREAKING CHANGE:` for
breaking changes (minor bumps while below 1.0). Review and merge the Release Please PR. It
updates `version.txt`, `.release-please-manifest.json`, and `CHANGELOG.md`; the shipping app
continues to derive its version from the tag and its build number from the commit count.

`scripts/release.sh` uploads the appcast's DMGs, stable `Yorozu.dmg`, `appcast.xml`, and model
catalog to the versioned release. `yorozu.yumi.to/mac`, `/appcast.xml`, and `/download/*` point to
GitHub's `releases/latest/download` URLs. Older releases are removed only after upload and
publication succeed. The catalog workflow updates the latest release without creating another.

To retry a failed build using the current workflow and the original source tag:

```sh
gh workflow run release.yml -f tag=v0.2.2
```

A failed build leaves a draft and the previous download intact. The same publication script
can run locally from the release tag with `gh` authenticated and the signing keys available.

#### The secrets, set once

Eight repository secrets, all set with `gh secret set`, which encrypts them on this machine with
the repo's public key before anything leaves it. Nothing is pasted into a browser and nothing is
committed.

```sh
# Mac releases need the Developer ID Application identity and its private key.
# Export as an encrypted .p12 from Keychain Access, then upload the base64 file:
base64 -i developer-id.p12 | gh secret set DEVELOPER_ID_P12
gh secret set DEVELOPER_ID_PASSWORD       # prompts for the export password
# TestFlight separately uses an Apple Development identity and its private key.
base64 -i apple-development.p12 | gh secret set MAC_CERT_P12
gh secret set MAC_CERT_PASSWORD
# The App Store Connect API key notarization uses — the same one as TestFlight.
gh secret set ASC_KEY_ID --body <KEYID>
gh secret set ASC_ISSUER_ID --body <ISSUER-UUID>
gh secret set ASC_KEY_P8 < <(base64 -i ~/.appstoreconnect/private_keys/AuthKey_<KEYID>.p8)
# The Sparkle private key, exported from the login keychain into a file for one moment.
KEY=$(mktemp -d)/ed && ./apps/mac/.build/artifacts/sparkle/Sparkle/bin/generate_keys -x "$KEY" \
  && gh secret set SPARKLE_ED_KEY < "$KEY"; rm -rf "$(dirname "$KEY")"
```

The runner imports the identity into a keychain of its own, stores the notary key as the
`yorozu-notary` profile `build-mac.sh` looks for, and hands the Sparkle key to `appcast.sh` as
`SPARKLE_ED_KEY_FILE`; all three are deleted at the end of the job, and the VM with them.

## TestFlight

Internal testing only: team members are added to the "Internal" beta group in App Store Connect
and install through the TestFlight app. No public link.

The `ios` job in `testflight.yml` runs this on every push to `main`, with the
`ASC_*` secrets above plus the same `.p12` (the archive step wants an Apple Development
identity on the machine; without one Xcode mints a new certificate per run until the team hits
Apple's cap). The version comes from the tag and the build number from the commit count. To
run it by hand instead:

```sh
ASC_KEY_ID=<KEYID> ASC_ISSUER_ID=<ISSUER-UUID> VERSION=0.2.1 ./scripts/build-ios.sh
```

Signing is automatic. `apps/ios/Project.swift` carries `DEVELOPMENT_TEAM` and
`CODE_SIGN_STYLE = Automatic`, and given `-allowProvisioningUpdates` plus an App Store Connect
key, `xcodebuild` issues the distribution certificate and the App Store profile on its own — so
Xcode manages the distribution profile; the development `.p12` is imported temporarily by CI. The same key authenticates the upload,
which is why the export options say `destination: upload` rather than writing an `.ipa` for a
second tool to send: one invocation, one credential, nothing on disk to leak. The key may be a
path (`ASC_KEY_PATH`, defaulting to `~/.appstoreconnect/private_keys/AuthKey_<KEYID>.p8`) or
base64 in `ASC_KEY_P8`, which is written out at mode 600 and removed on exit.

The build number is `git rev-list --count HEAD`. It has to rise with every upload and never
repeat, and the commit count does both without a file to bump and without differing between two
checkouts of the same commit.

### The app record has to be made by hand, once

Registering the bundle ID is an API call, and `scripts/asc.mjs` — a JWT signer and a `fetch`,
`node:crypto` and nothing else — is enough for it:

```sh
node scripts/asc.mjs POST /v1/bundleIds '{"data":{"type":"bundleIds","attributes":
  {"identifier":"to.yumi.yorozu.ios","name":"Yorozu iOS","platform":"IOS","seedId":"AN5KM8QGEF"}}}'
```

Creating the *app record* is not. `POST /v1/apps` answers
`The resource 'apps' does not allow 'CREATE'`, and `fastlane produce` is no way round it: with an
API key spaceship talks to that same endpoint, so it gets the same refusal. The only thing that
can create one is an Apple ID web session, which means 2FA and a person. So the first upload for a
new app needs one visit to [App Store Connect](https://appstoreconnect.apple.com/apps) → **+** →
**New App**: iOS, name **Yorozu**, primary language English (U.S.), the bundle ID above, SKU
`yorozu-ios`. Until that exists `xcodebuild -exportArchive` stops before it uploads, with
`IDEDistributionFetchAppRecordStep … missingApp(bundleId: "to.yumi.yorozu.ios")` in its
distribution log. Everything after it is automatic.

`scripts/asc-listing.mjs` writes the App Store listing idempotently from
[app-store/listing-0.2.0.md](app-store/listing-0.2.0.md).

### External testers

A public link needs a beta group with external testing on, which is two more `asc.mjs` calls once
the app record exists — `<APP-ID>` is the numeric ID from
`node scripts/asc.mjs GET '/v1/apps?filter[bundleId]=to.yumi.yorozu.ios'`:

```sh
node scripts/asc.mjs POST /v1/betaGroups '{"data":{"type":"betaGroups","attributes":
  {"name":"Public","publicLinkEnabled":true,"publicLinkLimitEnabled":false},
  "relationships":{"app":{"data":{"type":"apps","id":"<APP-ID>"}}}}}'
node scripts/asc.mjs GET '/v1/apps/<APP-ID>/betaGroups'   # publicLink is in the response
```

The link only starts working once the build passes Beta App Review, which is a separate submission
from App Review and usually a day or less.

## Hosting the relay

The Mac and the phone only ever meet through a relay, so one has to be reachable from both.
Settings → **General** carries the URL the sidecar dials; it defaults to `wss://relay.yumi.to`. The relay
is blind either way, so the only reason to move is to keep the traffic on your own network —
`ws://100.100.1.1:8787` being a Mac mini over Tailscale.

On Cloudflare, edit the `routes` block in `apps/relay/wrangler.toml` to your own hostname and
deploy:

```sh
pnpm --filter @yorozu/relay exec wrangler deploy
```

In Docker:

```sh
docker build -t yorozu-relay -f apps/relay/Dockerfile . && docker run -p 8787:8787 yorozu-relay
```

Or as a LaunchAgent on a Mac you already own:

```sh
pnpm --filter @yorozu/relay build
./scripts/install-relay-launchagent.sh   # ~/Library/LaunchAgents/to.yumi.yorozu.relay.plist
```

That binds every interface on `PORT` (8787), keeps itself alive across crashes and reboots, and
logs to `~/Library/Logs/yorozu-relay.log`. Reach it over Tailscale rather than a forwarded port:
the relay is blind, but it is still a service.
`launchctl bootout gui/$(id -u)/to.yumi.yorozu.relay` stops it.

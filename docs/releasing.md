# Release setup and local builds

[RELEASE_WORKFLOW.md](RELEASE_WORKFLOW.md) is the release runbook: source branches, candidate
builds, TestFlight, App Store review, promotion, retries, and signed Conventional Commits.
This guide covers credentials, packaging, and local tools.

CI publishes a numbered Mac prerelease and uploads the matching iOS build only after successful
CI for the exact source commit. Stable publication is a separate, explicit promotion of those
same artifacts. Release Please prepares version/changelog PRs; merging one does not publish stable.

## Versions

`release-please-config.json` holds the intended next numeric `MAJOR.MINOR.PATCH` version in
`packages["."]["release-as"]`. Edit this value per source branch; Release Please and candidate
builds both read it. A manual candidate dispatch can override its build version explicitly.
Release Please owns `version.txt` and `.release-please-manifest.json`, which record its last
prepared version. Stable promotion requires both to match the candidate at its source SHA.
Production build scripts require explicit `VERSION` and `BUILD`.

The single `Release` workflow assigns `BUILD = 10000 + github.run_number` to both platforms.
That number identifies the Mac DMG, iOS archive, and TestFlight upload. Do not upload local builds
using a number allocated by CI, or reset the counter by replacing the workflow. A failed candidate
build needs a fresh dispatch; promotion retries reuse the existing candidate.

## The Mac DMG

```sh
VERSION=0.5.0 BUILD=9999 ./scripts/build-mac.sh  # local packaging only; never upload this example
```

It builds the workspace and the Swift release binaries, then assembles `Yorozu.app` with the
runtime *inside* it — the official `node` for this platform downloaded to `Contents/Resources/node`
and the sidecar plus its production dependencies deployed next to it — so the app needs nothing
installed to run. `YOROZU_RUNTIME_CMD` defaults to that bundled pair whenever the app finds it,
and falls back to the dev checkout layout otherwise.

The installer is `dist/yorozu.dmg`. Each retained candidate tag provides a unique download URL,
so neither a second alias nor a version/build suffix is needed. Generate an appcast from a clean
output directory, without DMGs left over from earlier builds.

It is deliberately not *this machine's* `node`. A Homebrew node is a stub linked against
`@rpath/libnode.<abi>.dylib` and a dozen other Homebrew dylibs that no `.app` carries, so a bundle
built around one dies at launch with "Library not loaded" — and because the app only checks that
the bundled node *exists* before preferring it, that failure is silent: the sidecar never starts
and the menu bar sits at `starting`. The nodejs.org build links nothing but system frameworks. The
tarball is cached in `dist/`, and the build runs `node --version` once before signing so a node
that cannot start fails the build rather than the user.

The bundle is Developer ID signed with the hardened runtime, inside out and without `--deep`,
so each binary carries only the entitlements it needs. `apps/mac/Yorozu.entitlements`, for the
app and the `yorozu-native` helper, holds only the privacy usage entitlements (Apple Events,
camera, microphone, contacts, calendars, location, photos) — no hardened-runtime exceptions, so
the app and helper cannot load unsigned code or write executable memory. The bundled `node` and
the Agent SDK's vendored Bun-built `claude` are signed with `apps/mac/Node.entitlements`, which
grants the two exceptions their JITs need: JIT and unsigned executable memory, no library
validation exception and no TCC keys. Sparkle's framework, helpers and XPC services keep the
entitlements they shipped with. There is no sandbox — the agent drives the whole Mac. The DMG
is signed too.

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

A local build without a usable profile prints `notarization skipped: no profile` and leaves the
DMG signed but unnotarized. CI requires notarization and fails when credentials are unusable;
it cannot publish an unnotarized candidate.

### Sparkle

Sparkle signs each update archive with an EdDSA key kept in the login keychain locally and
provided to CI through the `SPARKLE_ED_KEY` repository secret. The appcast carries the archive
signature; the XML itself is not signed:

```sh
./apps/mac/.build/artifacts/sparkle/Sparkle/bin/generate_keys   # once, prints the public key
# Local example matching the DMG above; use the actual candidate version/build in CI.
CHANNEL=beta \
  DOWNLOAD_PREFIX=https://github.com/izyuumi/yorozu/releases/download/candidate-0.5.0-9999/ \
  ./scripts/appcast.sh                                       # writes dist/appcast.xml
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

### CI credentials

The candidate workflow imports both signing identities, notarizes the Mac DMG, generates its
Sparkle archive signature, then uploads the matching iOS build. It records the exact processed App Store
Connect build ID in the candidate manifest. Stable promotion requires the App Store Connect
key to verify that this same build was selected for the approved App Store version; it does
not rebuild, sign, or upload the iOS app again. The publication command verifies Apple
approval itself, so local promotion has the same credential and review requirements.

#### Secrets, set once

Eight repository secrets, all set with `gh secret set`, which encrypts them on this machine with
the repo's public key before anything leaves it. Nothing is pasted into a browser and nothing is
committed.

```sh
# Mac releases need the Developer ID Application identity and its private key.
# Export as an encrypted .p12 from Keychain Access, then upload the base64 file:
base64 -i developer-id.p12 | gh secret set DEVELOPER_ID_P12
gh secret set DEVELOPER_ID_PASSWORD       # prompts for the export password
# The same candidate job also needs the Apple Development identity and its private key.
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

The runner imports both identities into a temporary keychain, stores the notary key as the
`yorozu-notary` profile `build-mac.sh` looks for, and hands the Sparkle key to `appcast.sh` as
`SPARKLE_ED_KEY_FILE`. Credentials and the keychain are deleted at the end of the job.

## TestFlight

Internal testing only: team members are added to the "Internal" beta group in App Store Connect
and install through the TestFlight app. No public link.

The `Release` workflow owns both platforms. There is no separate TestFlight workflow or build
counter. The archive step needs the Apple Development identity imported from `MAC_CERT_P12`;
without one Xcode can mint a certificate per run until the team reaches Apple's limit.

Use the canonical workflow for any distributable build. `scripts/build-ios.sh` requires explicit
`VERSION` and `BUILD`, plus `ASC_KEY_ID`, `ASC_ISSUER_ID`, and the private key described below.
Running it locally performs a real upload and is not a dry run; choose an unused Apple build
number without colliding with the CI sequence.

Signing is automatic. `apps/ios/Project.swift` carries `DEVELOPMENT_TEAM` and
`CODE_SIGN_STYLE = Automatic`, and given `-allowProvisioningUpdates` plus an App Store Connect
key, `xcodebuild` issues the distribution certificate and the App Store profile on its own — so
Xcode manages the distribution profile; the development `.p12` is imported temporarily by CI. The same key authenticates the upload,
which is why the export options say `destination: upload` rather than writing an `.ipa` for a
second tool to send: one invocation, one credential, nothing on disk to leak. The key may be a
path (`ASC_KEY_PATH`, defaulting to `~/.appstoreconnect/private_keys/AuthKey_<KEYID>.p8`) or
base64 in `ASC_KEY_P8`, which is written out at mode 600 and removed on exit.

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
distribution log. Candidate uploads are automated after this setup; App Review and the
App Store release remain explicit maintainer actions.

`node scripts/asc-listing.mjs --check` validates the 0.4.0 listing and screenshots locally from
[app-store/listing-0.4.0.md](app-store/listing-0.4.0.md). Run with `--apply` to update the existing
editable listing and attach build 10. It verifies the readback, preserves existing app-wide
declarations/pricing/availability, and never submits for review. The first App Store release
cannot publish What’s New; that copy remains in the source document.

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
from App Review. Review and processing times vary.

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

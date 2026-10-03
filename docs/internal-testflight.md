# Internal 0.6 distribution

This lane is only for the approved internal 0.6 evaluation. It does not create a
GitHub Release, update a Mac feed, submit Beta App Review, or change the Public
TestFlight group. Normal `main`/`release/*` candidate behavior is unchanged.

The existing `Release` workflow is registered on `main`. GitHub can dispatch its
reviewed alternate-branch revision with `--ref`; a new workflow filename would
need default-branch registration for manual dispatch. Both the workflow revision
and source branch must resolve to the supplied reviewed SHA. Do not merge this
work into `main` simply to make internal distribution possible.

## Prerequisites

- Integrate the UI and internal build/check entrypoints into one signed source
  commit on an isolated branch. Run successful `ci.yml` checks for that exact SHA.
- Complete actual native QA and the requested Claude Code Opus 5.5 review before
  dispatch. The `reviewed_source_sha` input pins the reviewed commit; it is an
  operator attestation, not an automated claim that a review happened.
- `scripts/check-internal-alpha.sh` must implement the safe internal checks. It
  must not run the protected Rust recovery/interposer/FIFO operations or invoke
  the legacy aggregate/UI harness. This lane does not call `ui-tests.yml`.
- `scripts/build-internal-alpha.sh` receives `VERSION=0.6.0`,
  `BUILD=10000+github.run_number`, and `DIST=dist/internal/mac`. It must produce
  signed `Yorozu.app`, `Yorozu.dmg`, and its provenance under that directory,
  preserve the approved production runtime/data compatibility, and publish
  nothing. The workflow uses the existing signing secrets and `yorozu-notary`
  profile, without a Sparkle key.
- The internal iOS builder sets `TUIST_SECRETARY_ENABLED=true` before Tuist
  generates the project. `Project.swift` reads it through Tuist’s `Environment`
  API; the ordinary app defaults to the feature being disabled. CI checks the
  compiled app, and the builder refuses export or upload unless the archived
  app contains `YorozuSecretaryEnabled=true`.

After these gates, dispatch the reviewed branch itself:

```sh
gh workflow run release.yml --ref <reviewed-branch> \
  -f source_branch=<reviewed-branch> -f version=0.6.0 \
  -f internal_only=true -f reviewed_source_sha=<full-reviewed-sha>
```

Do not set `internal_only=false` to work around a failure. The ordinary lane
uploads externally and publishes Mac candidate artifacts.

## Build and recipient identity

The workflow retains the shared `candidate` concurrency group, with cancellation
disabled, so allocation and upload cannot race normal candidate uploads. Mac
builds keep the existing global workflow counter. iOS uses
`asc-candidate.mjs next-build 0.6.0`: highest already uploaded build for that
marketing version plus one, independently of Mac and 0.5 numbering. Start a fresh
dispatch after a failure; do not rerun an upload with a used version/build pair.

`build-ios.sh` still requires explicit numeric `VERSION` and `BUILD`.
`INTERNAL_ONLY=1` requires version `0.6.0`, enables the internal UI before Tuist,
and sets `testFlightInternalTestingOnly=true` for both the retained IPA export
and Xcode's upload export. Apple prevents these builds from being distributed
externally or through the App Store. The retained IPA is a signed export of the
same archive; it is not claimed to be byte-identical to Xcode's separate upload
export. See [Apple's internal testing documentation](https://developer.apple.com/help/app-store-connect/test-a-beta-version/add-internal-testers/).

The fixed App Store Connect app is `6811274963`, bundle
`to.yumi.yorozu.ios`. The only assignable group is
`954b8070-0ad9-4112-a061-2001bdc150b7`. Its display name may change; its verified
internal type, app relationship, and one-member recipient boundary may not.
Another internal group with automatic/all-build access blocks this lane. No
tester names or emails are read. `publicLinkEnabled=null` is normal for an
internal group and is accepted; `true` is rejected.

The existing `asc-candidate.mjs resolve` intentionally accepts only
`APP_STORE_ELIGIBLE` builds. This lane instead uses `asc-internal.mjs`:

```sh
node scripts/asc-internal.mjs preflight
node scripts/asc-internal.mjs resolve 0.6.0 <ios-build> dist/internal/ios.json
node scripts/asc-internal.mjs distribute dist/internal/ios.json dist/internal/availability.json
# Read-only recheck; this command never assigns a build:
node scripts/asc-internal.mjs verify dist/internal/ios.json dist/internal/availability.json
```

Only `distribute` writes to Apple, and its request boundary permits only adding
the verified build to that fixed internal group. It checks the app, version,
build, upload date, `INTERNAL_ONLY` audience, `VALID` processing, and expiration
before assignment. Automatic distribution often makes explicit assignment
unnecessary. It then waits for `internalBuildState=IN_BETA_TESTING` and the exact
build in the internal group's build relationship. An upload or `VALID` processing
alone is not availability. Polling defaults to 30 seconds and times out after
30 minutes; `ASC_PROCESSING_POLL_SECONDS` and `ASC_PROCESSING_TIMEOUT_SECONDS`
can adjust those bounds. Missing export compliance or processing failure stops
the lane rather than submitting an external review.

## Evidence and remaining device validation

The internal Mac bundles the pinned production runtime baseline plus the explicit
secretary overlay recorded in `internal-source.json`. Its dependency export uses
the baseline lockfile without resolving newer versions. Provenance records that
lockfile's SHA-256, the installed direct dependency versions, and sealed file hashes.
The temporary Node bridge remains part of this candidate; a complete Rust migration
has not shipped. The coding/review model does not select the user's runtime model.

Actions retains a ZIP of the signed Mac app, DMG, signed IPA, export options,
exact source/build metadata, Apple build ID, availability result, and SHA-256
artifact hashes for 30 days. Failed processing still retains existing build
artifacts and source evidence. Signing keys stay in runner temporary storage
and are deleted; they are never included in the artifact paths.

An `available=true` report proves Apple's internal availability state, not a
successful install. Validate installation, existing pairing/history/drafts,
streaming, Stop, reconnect, Japanese input, and the approved Mac/iOS pairing on
real devices before claiming those behaviors work. Never use the old standalone
Mac alpha's local pipe interface as evidence of iOS connectivity.

An interrupted task whose provider cessation cannot be proved is not replayed.
Its secretary queue stays held across reconnects and restarts. A crashed worker's
descendants may still run or write in `Yorozu Secretary`; reconnecting does not
prove that they stopped. This candidate has no user-facing release control for
that exceptional hold. Stop using the secretary and request an inspected recovery
before allowing new work. Do not delete the ledger, reset the profile, or edit the
stop journal to force a retry. Ordinary threads remain available. Failures proved
to occur before a provider turn starts must report a failed task without this hold.

## Focused checks

```sh
node --test scripts/asc-internal.test.mjs scripts/asc-candidate.test.mjs
python3 scripts/test-build-ios.py
```

The internal API tests own the recipient/audience/route and availability
contracts that the public-candidate tests do not cover. The command-boundary
test runs inert Tuist/Xcode substitutes and checks generated export options and
version arguments; it performs no signing or upload and is not a device test.

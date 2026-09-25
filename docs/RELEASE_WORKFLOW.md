# Release workflow

Yorozu builds a Mac DMG and iOS TestFlight candidate from one tested commit, then promotes the
same candidate to stable. `main` can advance to the next beta while an earlier version stays
available through GitHub Releases and the App Store.

## Branches and commits

| Source | Purpose | Distribution |
| --- | --- | --- |
| `main` | Next-version development | `v<version>-beta` Mac prerelease, public Mac beta feed, TestFlight |
| `release/<major>.<minor>` | Temporary stabilization or hotfix branch | Numbered Mac prerelease and TestFlight; does not replace the public main beta |
| `candidate-<version>-<build>` | Fixed release-branch candidate | Retained artifacts and manifest |
| `v<version>-beta` | Current main beta candidate | Replaced on each successful main build |
| `v<version>` | Fixed source for an approved stable release | Stable Mac download and the selected App Store build |

No permanent beta/stable branches. Create a release branch only when `main` needs to advance
while another version is being stabilized. Delete the branch when its fixes have reached `main`
and it no longer needs maintenance. Retain stable releases and release-branch candidates;
only the newest published `main` candidate remains available.

All commits must have Conventional Commit messages and cryptographic signatures, including
release preparation, backports, and merge/squash commits. Configure a signing key registered
with GitHub, enable signing locally, and verify before pushing:

```sh
git config commit.gpgsign true
git commit -S -m 'fix(updates): preserve beta version ordering'
git log -1 --show-signature
# Backports create new commits, so sign those too:
git cherry-pick -S <fix-commit>
```

Use `fix:` for fixes, `feat:` for features, and `!` or `BREAKING CHANGE:` for breaking changes.
Set PR titles to the intended Conventional Commit message when squash merging. Repository
rules should require verified signatures, pull requests, and successful CI on `main` and
`release/*`; these are repository settings, not enabled merely by adding workflow files.

## Version and build identity

| Value | Owner and meaning |
| --- | --- |
| `release-please-config.json` → `packages["."]["release-as"]` | Maintainer-selected next `MAJOR.MINOR.PATCH` version on each source branch |
| `version.txt`, `.release-please-manifest.json` | Release Please's last prepared version and changelog state |
| `VERSION` | Candidate's numeric marketing version; defaults to the configured `release-as`, or an explicit dispatch override |
| `BUILD` | `10000 + github.run_number` from the `Release` workflow; Mac/Sparkle build and candidate identity |
| iOS build | Highest App Store Connect build for that marketing version plus one; starts at 1 for a new version |
| Source SHA | Exact successful-CI commit, pinned before either app is built |

Shipping version selection never depends on whichever `v*` tag appears during a build. The
Mac build number does not depend on branch history or commit counts. Do not rename/reset the
canonical workflow or introduce another Mac uploader using its counter; a counter migration must
start above every already-published Mac build. Gaps from failed/skipped builds are harmless.
Candidate runs are serialized across branches while they read the latest iOS build and upload
the next one. An already-used version such as `0.5.0` (build `10048`) cannot restart at 1;
the first upload of a new marketing version can.

Candidate app bundles share the final numeric marketing version; each platform uses its own
build number. Beta status belongs to GitHub prerelease metadata, Sparkle's beta channel, and
TestFlight, allowing promotion without changing signed app bytes. Development bundles may still
use a beta display label.

Release Please runs separately in PR-only mode on `main` and release branches. It prepares
`CHANGELOG.md`, `version.txt`, and its manifest for the `packages["."]["release-as"]` version in
`release-please-config.json`. This config value is the shared intended-version source for both
Release Please and candidate builds; edit it independently on each source branch.
Review and merge its signed version PR before choosing the final candidate. Promotion requires
`version.txt` and the Release Please manifest at the candidate SHA to match its version.
Merging the PR does not create a stable tag or release. After successful promotion, the
workflow reconciles the merged preparation PR whose version and ancestry match the candidate,
including a PR originally merged into `main` before the release branch was cut.

Release Please uses `GITHUB_TOKEN`; allow GitHub Actions to create pull requests in repository
settings. Bot-created PR events do not automatically start CI with that token. A maintainer can
close and reopen the PR to trigger its checks; verify those checks and commit signatures before
merging.

After releasing, advance `packages["."]["release-as"]` in `release-please-config.json` with a
signed Conventional Commit before the next release cycle. If a release branch keeps `0.5.0`,
`main` can advance independently to `0.6.0`. Those betas can build while the earlier version
awaits review. Release Please waits to prepare its next version PR until promotion clears the
earlier pending PR; a subsequent push can then start that preparation.

## Automatic release notes

Candidate preparation generates notes directly from Git history through its exact source SHA.
The base is the highest earlier version with a published stable release whose commit is an
ancestor of that SHA. Drafts, prereleases, orphan tags, and releases on a divergent hotfix branch
cannot accidentally hide changes. An initial release includes all reachable history.

Every Conventional Commit type is included: features, fixes, performance, refactoring, docs,
build, CI, tests, style, maintenance, reverts, and custom types. Scopes, `!`, `BREAKING CHANGE:`,
and `BREAKING-CHANGE:` are preserved. Synthetic merge wrappers are skipped so their PR titles
do not repeat the underlying commits; actual Conventional Commit merge subjects remain.
Historical nonconventional subjects appear under **Other Changes**, never silently disappear.
Each entry links its commit, and the full-history link uses permanent SHAs.

These notes are saved in `candidate.json` and used verbatim for the candidate and its stable
release. Commits merged after Release Please's version PR are included. `CHANGELOG.md` remains
the version-PR preview, not the source of final GitHub notes; its standard commit sections are
also configured to stay visible. CI checks type coverage, breaking footers, merge duplication,
branch ancestry, and exact-note preservation through promotion.

## Build and test a candidate

1. Merge signed changes into `main` or `release/<major>.<minor>` with the intended version in
   `release-please-config.json` under `packages["."]["release-as"]`.
2. Wait for the `CI` push run for that exact SHA. Successful CI triggers `Release`; failed CI
   cannot publish a candidate. Release also rechecks the selected SHA's CI before building.
3. `Release` builds/signs/notarizes the Mac DMG, creates a Sparkle appcast with its EdDSA
   signature, uploads the same version with its per-version iOS build to TestFlight, and waits for
   App Store Connect to identify that exact processed build.
4. Download the current GitHub prerelease's DMG and install its matching TestFlight build.
   Record validation against its manifest, not a moving branch name or rolling beta URL.

To start a fresh candidate manually using trusted workflow code from `main`:

```sh
gh workflow run release.yml --ref main -f source_branch=main
# Optional explicit version; useful for an intentional release candidate:
gh workflow run release.yml --ref main -f source_branch=release/0.5 -f version=0.5.0
```

The workflow resolves the selected branch to one SHA and verifies its CI. A branch change after
selection cannot change the candidate's source. New dispatches receive new build numbers.
An explicit version override does not update Release Please metadata: before stable promotion,
the candidate SHA's `version.txt` and `.release-please-manifest.json` must both match that version.

Each candidate has one DMG (`Yorozu.dmg`), the appcast, and `candidate.json` with source SHA,
both build numbers, artifact hashes, and exact App Store Connect build ID. Main candidates use
the release tag `v<version>-beta` and title `Yorozu v<version>-beta`; the build number remains in
the app and manifest. Before replacing a main beta, the workflow checks version/build ordering
and source ancestry. It removes the previous beta release and tag, publishes the new candidate
under the same tag, then removes older main beta releases. Release-branch candidates keep numbered
tags and immutable artifacts. Only the current main beta can be promoted after replacement.

## Promote to stable

1. Finish testing the candidate on both platforms, including the compatibility matrix below.
2. In App Store Connect, prepare the matching iOS App Store version and select the exact
   TestFlight build from the candidate manifest. Complete listing/compliance information,
   choose manual release, and submit it for App Review.
3. Wait for approval. The selected version/build must be **Pending Developer Release** or
   **Ready for Distribution**. A build merely available on TestFlight is insufficient.
4. Dispatch promotion with the current candidate tag:

   ```sh
   gh workflow run promote.yml --ref main -f candidate=v0.5.0-beta
   ```

5. Release the approved iOS version manually in App Store Connect when ready, then verify both
   production downloads. Promotion verifies Apple's selected build/state; it does not submit
   App Review or release the iOS app through the API.

Promotion downloads the candidate, checks artifact hashes and source CI, requires matching
release metadata at its source SHA, and verifies the exact iOS build's approved selection with
App Store Connect. The `scripts/release.py promote` command performs this Apple verification
itself, including when invoked locally. It creates `v<version>` at the candidate SHA, uploads
the identical Mac DMG, removes the beta channel marker from the stable appcast,
and makes the release latest only after its assets are ready. The stable manifest records the
candidate identity. Sparkle signs the DMG, so changing the feed channel preserves that signature.
Promotion never recompiles either app.

Publication rejects older stable versions and candidates whose build number was overtaken by
an already-published stable build. For example, publishing `0.4.1 (10124)` after testing
`0.5.0 (10123)` requires a fresh `0.5.0` candidate before promotion. Retest that new build and
select it in App Store Connect; do not bypass the ordering check.

App Store processing and availability can lag the Mac publication. Manual release helps
coordinate timing but does not guarantee simultaneous availability. Keep adjacent versions
compatible, and decide launch timing with this overlap in mind.

## Stable and beta downloads

New candidate and stable releases have three assets:

| Asset | Purpose |
| --- | --- |
| `Yorozu.dmg` | The installer; version/build identity is in the app bundle and manifest |
| `appcast.xml` | Sparkle's update feed: eligible version/build, DMG URL, size, and EdDSA signature |
| `candidate.json` | Exact source/build identity, generated release notes, hashes, and Apple build ID needed for promotion |

`appcast.xml` is required for **Check for Updates** and automatic Mac updates. Removing it would
strand installed clients. The XML describes the signed DMG; it is not another installer.
The [Sparkle publishing guide](https://sparkle-project.org/documentation/publishing/) describes
the feed and archive-signature format.

- Stable users read `https://yorozu.yumi.to/appcast.xml`; the website's Mac download follows the
  latest stable GitHub Release.
- Opted-in beta users read `https://yorozu.yumi.to/beta/appcast.xml`, which redirects to the
  current main candidate. `https://yorozu.yumi.to/beta` downloads that candidate's DMG.
  The app rejects lower marketing
  versions even when their Mac build number is larger, preventing a later stable hotfix from
  downgrading a next-version beta.
- Turning **Receive beta updates** off waits until stable catches up to the installed marketing
  version and has an eligible build. It does not reinstall or downgrade the app.
- A new main beta replaces assets at its versioned beta tag. Clients with a cached older appcast
  may need to retry after its cache expires. Stable releases and release-branch candidates remain available.
- Pin the previously shipped `0.4.0 (293)` download redirect to `v0.4.0` before first promotion,
  preserving the legacy cached appcast during migration. It resolves to the same signed bytes
  under `v0.4.0/yorozu.dmg`; the duplicate versioned asset is no longer needed.
- The website's `/mac` route prefers `Yorozu.dmg` and supports the shipped `v0.4.0/yorozu.dmg`.
  Deploy the website Worker with `apps/relay/node_modules/.bin/wrangler deploy
  --config apps/web/wrangler.jsonc` from the repository root after updating it.
- Model lists come live from OpenClaw's `models.list`, Claude SDK's `supportedModels()`, and
  Codex's paginated `model/list`. No release `models.json` asset is needed. The dormant
  direct-provider catalog reads `main/catalog/models.json` directly with cache/bundled fallback;
  `/models.json` remains a compatibility redirect for older legacy consumers.

The website Worker discovers the published main candidate through the GitHub API and checks its
manifest belongs to `main`. Discovery is cached for five minutes and limited to 2,000 releases; beyond that ceiling, replace discovery
with a dedicated index. Missing candidates or upstream failures return 503 and retry guidance;
the static website stays available. The endpoint never points to a release-branch candidate.

The obsolete **Yorozu Beta** (`main-beta`) release/tag is removed: the project has only one
development user, so no legacy beta feed migration is required. Install a new candidate manually
to get the replacement feed URL; old beta binaries still reference the deleted feed. The unused
`v0.3.0` tag is also removed; historical references use its retained commit SHA instead.

## Parallel stabilization and hotfixes

To stabilize the current main version, branch `release/0.5` from its chosen commit, keep
`packages["."]["release-as"]` in `release-please-config.json` at `0.5.0`, then advance the same
config value on `main` to its next intended version. Both branches use the same build counter
and promotion flow.

For a `0.4.1` hotfix while `main` develops `0.5.0`:

1. Create `release/0.4` from `v0.4.0`.
2. If that tag predates this pipeline, first bring in the release tooling/workflow changes as
   signed commits. A branch needs the new CI and explicit version inputs before it can build.
3. Set `packages["."]["release-as"]` in `release-please-config.json` to `0.4.1`, apply the minimal
   fix in signed Conventional Commits, and push for CI. Bring the fix to `main` as a signed
   backport too.
4. Test and promote the resulting candidate through the same App Store and Mac process.
5. Dispatch a fresh next-version candidate from `main` after the hotfix publication:

   ```sh
   gh workflow run release.yml --ref main -f source_branch=main
   ```

   This gives the public beta a build number above the hotfix. Otherwise a stable
   `0.4.1 (10124)` user opting into beta cannot see the older `0.5.0 (10123)` build. Test that
   switching the freshly installed hotfix to beta offers and installs the refreshed candidate.

Do not merge an entire hotfix branch into `main` just to transfer its old version metadata.

## Failures and retries

| Failure | Recovery |
| --- | --- |
| CI fails | Fix source, push signed commit, wait for successful CI |
| Candidate build/upload/Apple processing fails | Start a fresh `release.yml` dispatch; rerunning the old build would reuse an Apple build number |
| Candidate published but needs code changes | Commit the fix and build a new candidate; publication replaces the previous main beta |
| Promotion fails before completion | Correct the cause and rerun `promote.yml` for the same candidate; it reuses and revalidates existing bytes |
| Newer stable version/build overtook the candidate | Build and test a fresh eligible candidate; do not move stable tags backwards |
| Production regression | Publish a forward-fix candidate/version; do not overwrite a released DMG or retarget a stable tag |

A failed beta replacement can leave the beta unavailable until a fresh build succeeds. No workflow
force-moves stable tags. Credentials and local build details
are in [releasing.md](releasing.md).

## Release validation

Exercise these installed combinations before promotion, using the current production version
and the candidate under review:

| Mac | iOS |
| --- | --- |
| Stable | Stable |
| Candidate | Stable |
| Stable | Candidate/TestFlight |
| Candidate | Candidate/TestFlight |

Check pairing/reconnection, streamed conversation, tool approval, queued updates, and persisted
data migrations. Check a stable Mac can update through the stable feed, a stable hotfix can opt
into the refreshed next-version beta, a beta Mac stays on its intended version, and a cached
older appcast still downloads its referenced DMG. These device
checks are maintainer validation; passing automated CI does not perform them.

# Release workflow

Yorozu builds a Mac DMG and iOS TestFlight candidate from one tested commit, then promotes the
same candidate to stable. `main` can advance to the next beta while an earlier version stays
available through GitHub Releases and the App Store.

## Branches and commits

| Source | Purpose | Distribution |
| --- | --- | --- |
| `main` | Next-version development | Numbered Mac prerelease, public Mac beta feed, TestFlight |
| `release/<major>.<minor>` | Temporary stabilization or hotfix branch | Numbered Mac prerelease and TestFlight; does not replace the public main beta |
| `candidate-<version>-<build>` | Fixed source for one candidate | Retained artifacts and manifest |
| `v<version>` | Fixed source for an approved stable release | Stable Mac download and the selected App Store build |

No permanent beta/stable branches. Create a release branch only when `main` needs to advance
while another version is being stabilized. Delete the branch when its fixes have reached `main`
and it no longer needs maintenance; retain candidate and stable tags/releases.

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
| `release-version.txt` | Maintainer-selected next `MAJOR.MINOR.PATCH` version on each source branch |
| `version.txt`, `.release-please-manifest.json` | Release Please's last prepared version and changelog state |
| `VERSION` | Candidate's numeric marketing version; defaults to `release-version.txt`, or an explicit dispatch override |
| `BUILD` | `10000 + github.run_number` from the single `Release` workflow; shared by Mac and iOS |
| Source SHA | Exact successful-CI commit, pinned before either app is built |

Shipping version selection never depends on whichever `v*` tag appears during a build. The
build number does not depend on branch history or commit counts. Do not rename/reset the
canonical workflow or introduce another uploader using its counter; a counter migration must
start above every already-published build. Gaps from failed/skipped builds are harmless.

Candidate app bundles use the final numeric version and build. Beta status belongs to GitHub
prerelease metadata, Sparkle's beta channel, and TestFlight, allowing promotion without changing
signed app bytes. Development bundles may still use a beta display label.

Release Please runs separately in PR-only mode on `main` and release branches. It prepares
`CHANGELOG.md`, `version.txt`, and its manifest for the version selected in `release-version.txt`.
Review and merge its signed version PR before choosing the final candidate. Promotion requires
`version.txt` and the Release Please manifest at the candidate SHA to match its version.
Merging the PR does not create a stable tag or release. After successful promotion, the
workflow reconciles matching merged release-PR labels for the promoted version/source.

Release Please uses `GITHUB_TOKEN`; allow GitHub Actions to create pull requests in repository
settings. Bot-created PR events do not automatically start CI with that token. A maintainer can
close and reopen the PR to trigger its checks; verify those checks and commit signatures before
merging.

After releasing, advance `release-version.txt` in a signed Conventional Commit before the next
release cycle. If a release branch keeps `0.5.0`, `main` can advance independently to `0.6.0`.

## Build and test a candidate

1. Merge signed changes into `main` or `release/<major>.<minor>` with the intended version in
   `release-version.txt`.
2. Wait for the `CI` push run for that exact SHA. Successful CI triggers `Release`; failed CI
   cannot publish a candidate. Release also rechecks the selected SHA's CI before building.
3. `Release` builds/signs/notarizes the Mac DMG, creates a Sparkle appcast with its EdDSA
   signature, uploads the same version/build to TestFlight, and waits for App Store Connect
   to identify that exact processed build.
4. Download the numbered GitHub prerelease's DMG and install its matching TestFlight build.
   Record validation against its manifest, not a moving branch name or rolling beta URL.

To start a fresh candidate manually using trusted workflow code from `main`:

```sh
gh workflow run release.yml --ref main -f source_branch=main
# Optional explicit version; useful for an intentional release candidate:
gh workflow run release.yml --ref main -f source_branch=release/0.5 -f version=0.5.0
```

The workflow resolves the selected branch to one SHA and verifies its CI. A branch change after
selection cannot change the candidate's source. New dispatches receive new build numbers.

Each `candidate-<version>-<build>` release retains the DMG, appcast, model-catalog snapshot,
and `candidate.json` with source SHA, version/build, artifact hashes, and exact App Store Connect
build ID. Existing published candidate artifacts are not overwritten. Only a candidate from `main`
updates `main-beta`'s mutable `Yorozu.dmg` and `appcast.xml` pointer assets. Its legacy tag stays
in place; the numbered candidate and manifest identify the actual source. Old versioned DMGs
on `main-beta` remain available for installed clients with cached feeds.

## Promote to stable

1. Finish testing the candidate on both platforms, including the compatibility matrix below.
2. In App Store Connect, prepare the matching iOS App Store version and select the exact
   TestFlight build from the candidate manifest. Complete listing/compliance information,
   choose manual release, and submit it for App Review.
3. Wait for approval. The selected version/build must be **Pending Developer Release** or
   **Ready for Distribution**. A build merely available on TestFlight is insufficient.
4. Dispatch promotion with the fixed candidate tag:

   ```sh
   gh workflow run promote.yml --ref main -f candidate=candidate-0.5.0-10123
   ```

5. Release the approved iOS version manually in App Store Connect when ready, then verify both
   production downloads. Promotion verifies Apple's selected build/state; it does not submit
   App Review or release the iOS app through the API.

Promotion downloads the candidate, checks artifact hashes and source CI, and verifies the exact
iOS build's approved selection with App Store Connect. It creates `v<version>` at the candidate
SHA, uploads the identical Mac DMG, removes the beta channel marker from the stable appcast,
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

- Stable users read `https://yorozu.yumi.to/appcast.xml`; the website's Mac download follows the
  latest stable GitHub Release.
- Opted-in beta users read the separate `main-beta` appcast. The app rejects lower marketing
  versions even when their build number is larger, preventing a later stable hotfix from
  downgrading a next-version beta.
- Turning **Receive beta updates** off waits until stable catches up to the installed marketing
  version and has an eligible build. It does not reinstall or downgrade the app.
- Appcast enclosure URLs point directly to retained numbered release assets. A later release
  does not break a cached appcast's download URL. Stable and candidate releases are preserved.
- Deploy the website redirect changes before the first promotion. They pin the previously shipped
  `0.4.0 (293)` download URL to `v0.4.0`, preserving the legacy cached appcast during migration.
- `https://yorozu.yumi.to/models.json` follows `main/catalog/models.json`. Each release also
  retains its catalog snapshot; ongoing catalog changes do not mutate release assets.

The rolling `main-beta` pointer deliberately has mutable assets. Do not enable repository-wide
GitHub release immutability without first replacing that pointer design.

## Parallel stabilization and hotfixes

To stabilize the current main version, branch `release/0.5` from its chosen commit, retain
`release-version.txt` as `0.5.0`, then advance `main` to its next intended version. Both branches
use the same build counter and promotion flow.

For a `0.4.1` hotfix while `main` develops `0.5.0`:

1. Create `release/0.4` from `v0.4.0`.
2. If that tag predates this pipeline, first bring in the release tooling/workflow changes as
   signed commits. A branch needs the new CI and explicit version inputs before it can build.
3. Set `release-version.txt` to `0.4.1`, apply the minimal fix in signed Conventional Commits,
   and push for CI. Bring the fix to `main` as a signed backport too.
4. Test and promote the resulting candidate through the same App Store and Mac process.

Do not merge an entire hotfix branch into `main` just to transfer its old version metadata.

## Failures and retries

| Failure | Recovery |
| --- | --- |
| CI fails | Fix source, push signed commit, wait for successful CI |
| Candidate build/upload/Apple processing fails | Start a fresh `release.yml` dispatch; rerunning the old build would reuse an Apple build number |
| Candidate published but needs code changes | Commit the fix and build a new candidate |
| Promotion fails before completion | Correct the cause and rerun `promote.yml` for the same candidate; it reuses and revalidates existing bytes |
| Newer stable version/build overtook the candidate | Build and test a fresh eligible candidate; do not move stable tags backwards |
| Production regression | Publish a forward-fix candidate/version; do not overwrite a released DMG or retarget a stable tag |

A failed draft upload leaves the previous stable release latest. No workflow deletes old
published releases or force-moves candidate/stable tags. Credentials and local build details
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
data migrations. Check a stable Mac can update through the stable feed, a beta Mac stays on its
intended version, and a cached older appcast still downloads its referenced DMG. These device
checks are maintainer validation; passing automated CI does not perform them.

# 0031. Release versioning, beta tags and promotion

- Status: Accepted
- Date: 2026-11-21 (recorded from code comments)

## Context

Every push to `main` that touches the app ships a beta; merging the release PR makes that beta stable ([docs/release.md](../release.md)). Versions come from Conventional Commits, and promotion must publish exactly the beta the PR names.

## Decision

- `scripts/version.sh` prints the version the next build ships as, by SemVer from the Conventional Commits since the last stable tag: a breaking change (`type!:` or a `BREAKING CHANGE:` footer) bumps major (minor below 1.0), a `feat` minor, anything else patch.
- `apps/ios/Project.swift` holds `version = "0.0.0"`; the release scripts pass the real version and build to xcodebuild.
- The app target's module stays `YorozuIOS` so module-qualified references are stable while the product and executable are named Yorozu.
- iOS build numbers: after an upload, `upload_ios.sh` waits until App Store Connect lists the build, polling every 30 s for up to `LIST_WAIT` seconds (default 3600). The next upload numbers its build from that list, so until then a second merge would reuse the number; `release-ios.yml` runs one upload at a time, so waiting closes that gap.
- Mac betas:
  - There is one beta release, `v<version>-beta`, which each build replaces (before this, `v<version>-beta.<build>`).
  - Dropping a beta deletes its release. The tag ruleset leaves `*-beta` tags alone, so `v<version>-beta` goes too; an older `v<version>-beta.<n>` tag is immutable, so only its release goes.
  - When `BUILD` is unset it is the beta's build plus one, or past the highest older `v<version>-beta.<n>` tag, so Sparkle still sees it rise.
  - In the app, Sparkle error 1001 (`SUNoUpdateError`) is already reported, so the update check ignores it.
- Release PR (`scripts/release_pr.sh`): opens or updates branch `release`, like release-please. `CHANGELOG.md` gains the notes for the version, and the body names the beta that merging makes stable by build, source commit and DMG digest.
  - It commits through the contents API, which commits as GitHub, so the commit is signed as the `main` ruleset requires.
  - The bot-authored PR's checks wait for approval, so the script approves them and the required checks run.
- Promotion: `promote.yml` passes all three identifiers to `release_mac.sh --promote`, which refuses a beta that no longer matches build, source commit and DMG digest; nothing is published then. The step's `run` is a YAML block scalar because the ": " in its sed patterns breaks a plain scalar.
- Release notes (`scripts/release_notes.sh`): the pull requests merged into `main` since the last stable tag `v<x.y.z>` (never a `-beta` tag), grouped by Conventional Commits title: feat, fix and perf, each with its PR number; other types and dependency bumps are left out.
  - A PR is a merge "Merge pull request #N from …" on main's first-parent line, titled by the merge's body, or a squashed commit ending "(#N)"; a commit pushed straight to `main` counts by its own subject.
  - `scripts/release_notes.overrides` can retitle or drop a PR a later one changed: `#<n> <title>` shows `<title>` (a Conventional Commits title that may end in its own "(#a, #b)") in place of PR #n's, and `#<n> -` drops it.
  - Default output is Markdown for the beta and stable releases, the release PR and `CHANGELOG.md`. `--what-to-test <locale> <version> <build>` prints a build's TestFlight What to Test in one App Store Connect locale as plain text within its 4,000 bytes; the intro, note, headings and closing line come from `apps/ios/metadata/testflight/<locale>/what_to_test.txt`, and PR titles stay as written.

## Consequences

- A beta can only become stable if it is byte-for-byte the build the release PR names.

## Where in the code

- `scripts/version.sh`
- `scripts/upload_ios.sh` — `wait_listed()`
- `scripts/release_mac.sh` — `beta_tag()`, `drop_beta()`, `BUILD`, `--promote`
- `scripts/release_pr.sh`
- `scripts/release_notes.sh`
- `.github/workflows/promote.yml` — `promote` job
- `apps/ios/Project.swift` — `version`, `PRODUCT_MODULE_NAME`
- `apps/ios/Sources/YorozuIOS/MacUpdates.swift` — update-check completion

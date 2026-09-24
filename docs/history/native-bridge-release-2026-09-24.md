# Native agent bridge release evidence — 2026-09-24

Release state for #12, read from `github/main`, the GitHub release, the Actions logs, App Store
Connect and a fresh download of the shipped DMG. This records what an agent could verify; it does
**not** claim #12 is complete. Nothing irreversible was done: no merge, tag, release edit, workflow
dispatch, upload, install, or PAIOS change. The running `/Applications/Yorozu.app` was not touched.
Times are UTC unless marked JST (the Mac's local logs).

## Blockers

All three blockers are closed and their closing commits are on `github/main`. The SHAs quoted in
the [2026-09-20 readiness log](native-bridge-readiness-2026-09-20.md) (`419ffc5`, `b6e9bf0`,
`83bf186`) and in the 2026-09-20 comment on #12 (`2997e69`) are no longer objects on GitHub — the
history was rewritten before `v0.2.0` — so the table names the commits that exist today. All three
are first contained in `v0.2.0`, and therefore in `v0.3.0`.

| Issue | Closed | Closing commit on `github/main` |
| --- | --- | --- |
| #5 Project folder picker and agent badge in thread list | 2026-09-20T06:04:54Z | `b87a198` feat(threads): ask who answers a new thread, and where |
| #8 Per-thread bypass toggle for native agent threads | 2026-09-20T07:52:16Z | `cb058af` feat(native): persist native thread bypass independently of global YOLO (#8) |
| #11 Codex thread parity | 2026-09-20T07:52:23Z | `f00047a` feat(codex): add native Codex interactive client parity through App Server (#11) |

Checked with `gh issue view N --json state,closedAt`, the issue timeline (GraphQL
`ReferencedEvent`), and `git merge-base --is-ancestor <sha> github/main`.

## What is released

**Source.** `github/main` = `f78492c`, the merge of Release Please PR #15 (`chore(main): release
0.3.0`). Tag `v0.3.0` points at the same commit; `git rev-list --count v0.3.0` = **282**, which is
the build number on both platforms. `v0.3.0..github/main` is empty and there is no open Release
Please PR. Open PRs #16, #26, #27 and #28 are unmerged and in no release.

**Mac.** Yorozu **0.3.0 (282)**.

| Check | Result |
| --- | --- |
| Release workflow run [35957940390](https://github.com/izyuumi/yorozu/actions/runs/35957940390) on `f78492c` | `success`; jobs `release-please` and `mac` both green; `RELEASE_TAG: v0.3.0` |
| Notarization (from the `mac` job log) | submission `457ed383-20b8-42d9-a801-19e926596d39`, `status: Accepted`; `xcrun notarytool history --keychain-profile yorozu-notary` on this Mac lists the same submission as `Accepted` |
| Staple and Gatekeeper on the runner | `The staple and validate action worked!`; `dist/Yorozu-0.3.0-282.dmg: accepted`, `source=Notarized Developer ID` |
| GitHub release [v0.3.0](https://github.com/izyuumi/yorozu/releases/tag/v0.3.0) | published 2026-09-24T05:05:38Z, `isDraft=false`, `isPrerelease=false`, marked Latest; assets `Yorozu-0.3.0-282.dmg`, `Yorozu.dmg` (same bytes), `appcast.xml`, `models.json`; DMG `sha256:97d8eb444bd8d8879c9d00109682484b37a9492384cf75d443a29a25990f69d9` |
| Superseded release | `v0.2.3` deleted by `release.sh` after publication; its tag kept |
| Live Sparkle feed `https://yorozu.yumi.to/appcast.xml` | one item, `<sparkle:version>282</sparkle:version>`, `0.3.0`, enclosure `https://yorozu.yumi.to/download/Yorozu-0.3.0-282.dmg`, length 341066188; byte-identical to the release's `appcast.xml` |
| `https://yorozu.yumi.to/mac` | 302 → `releases/latest/download/Yorozu.dmg` → 302 → `releases/download/v0.3.0/Yorozu.dmg` |
| CI ([ci.yml](https://github.com/izyuumi/yorozu/actions/runs/35957940420)) on the `f78492c` push | `success` |

Local verification of the shipped artifact, downloaded to `/tmp/yorozu-v030/` (nothing installed):

| Command | Result |
| --- | --- |
| `curl -L -o Yorozu-0.3.0-282.dmg https://github.com/izyuumi/yorozu/releases/download/v0.3.0/Yorozu-0.3.0-282.dmg && shasum -a 256 Yorozu-0.3.0-282.dmg` | `97d8eb44…9f69d9`, matches the release asset digest |
| `xcrun stapler validate Yorozu-0.3.0-282.dmg` | `The validate action worked!` |
| `spctl -a -t open --context context:primary-signature -vv Yorozu-0.3.0-282.dmg` | `accepted`, `source=Notarized Developer ID`, `origin=Developer ID Application: Yumi Izumi (AN5KM8QGEF)` |
| `hdiutil attach -nobrowse -readonly` then `defaults read …/Yorozu.app/Contents/Info.plist` | `CFBundleShortVersionString 0.3.0`, `CFBundleVersion 282`, `SUFeedURL https://yorozu.yumi.to/appcast.xml` |
| `spctl -a -vv …/Yorozu.app` (the app inside the DMG) | `accepted`, `source=Notarized Developer ID` |
| `codesign --verify --deep --strict --verbose=1 …/Yorozu.app` | `valid on disk`, `satisfies its Designated Requirement`; hardened runtime (`flags=0x10000(runtime)`), signed 2026-09-24 05:02:21Z |
| Bundled runtime | `Contents/Resources/runtime/node_modules/@anthropic-ai/claude-agent-sdk` and `@openai/codex` present |

**iOS.** Yorozu **0.3.0 (282)**.

| Check | Result |
| --- | --- |
| TestFlight workflow run [35957940423](https://github.com/izyuumi/yorozu/actions/runs/35957940423) on `f78492c` | `success`; `MARKETING_VERSION=0.3.0 CURRENT_PROJECT_VERSION=282`; `** ARCHIVE SUCCEEDED **`, `Upload succeeded.`, `** EXPORT SUCCEEDED **`; final line `uploaded 0.3.0 as App Store version 0.3.0 (282) to TestFlight` |
| `node scripts/asc.mjs GET '/v1/apps?filter[bundleId]=to.yumi.yorozu.ios'` | app `6811274963` "Yorozu" |
| `node scripts/asc.mjs GET '/v1/builds?filter[app]=6811274963&sort=-uploadedDate&limit=3&include=preReleaseVersion,betaGroups,buildBetaDetail'` | build `d5beebd6-3b34-4ba7-8337-a37e81495900`: `version 282`, `processingState VALID`, `expired false`, uploaded 2026-09-24T05:05:33Z, `preReleaseVersion 0.3.0 IOS`, `internalBuildState IN_BETA_TESTING`, `externalBuildState READY_FOR_BETA_SUBMISSION`, beta group `954b8070-…` **Internal** (`isInternalGroup true`, `hasAccessToAllBuilds true`) |

The earlier `testflight.yml` run on `b070621` shows `cancelled`: `concurrency: testflight` with
`cancel-in-progress` let the release merge supersede it, as the workflow comment says it will.

Footnote: the `pull_request` CI run on the Release Please PR head `66894a2`
([35957717920](https://github.com/izyuumi/yorozu/actions/runs/35957717920)) is recorded as
`failure` with zero jobs — the bot-PR case `docs/releasing.md` describes (close and reopen to run
checks). The push run on the merge commit succeeded, and the Mac build ran inside the release
workflow, so no shipped artifact skipped CI.

## The canonical Mac install (observed, not changed)

`/Applications/Yorozu.app` is still **0.2.3 (235)**, running since 11:47:52 JST (pid 62257). Its
signature is Developer ID with timestamp 11:46:00 JST today and no stapled ticket; `spctl -a -vv`
says `rejected`, `source=Unnotarized Developer ID`. `~/Library/Logs/Yorozu/app.log` shows the same
build 235 launched from `/private/tmp/Yorozu-repair.app` at 11:44 and 11:46 JST before moving to
`/Applications` — a locally signed build, not the notarized `Yorozu-0.2.3-235.dmg` (which
`notarytool history` shows `Accepted` on 2026-09-23T15:49Z).

Sparkle has already fetched the release: `14:22:20 updates: found 0.3.0 (build 282)` then
`14:22:52 updates: 0.3.0 held, a chat window is open`. `Sparkle.framework/…/Autoupdate` (pid 90163)
and the `Updater.app` helper (pid 90164) are waiting. Per `docs/releasing.md`, closing the chat
window or quitting lets it install and relaunch as 282. That is the user's action.

## #12 acceptance checklist against this evidence

| Criterion | Status | Evidence |
| --- | --- | --- |
| Mac build notarized, published, installed and running | **Half.** Notarized and published: yes. Installed and running: no | Notarized: submission `457ed383…` Accepted, stapled DMG, `spctl` accepted on runner and locally. Published: release v0.3.0 latest, feed at 282, `/mac` resolves to it. Installed: canonical app is 235, Sparkle holding 282 |
| iOS build VALID in Internal TestFlight | **Satisfied** | ASC build `d5beebd6…` version 282, `processingState VALID`, `internalBuildState IN_BETA_TESTING`, Internal group with `hasAccessToAllBuilds true` |
| On the physical iPhone: create a Claude Code thread, get a reply, answer one approval from the lockscreen | **Open — user only** | Needs the device |
| PAIOS project record updated with build number and evidence log | **Open — user only** | PAIOS is outside this repo |

## Cross-check of the 2026-09-20 readiness log

Every file that log names as evidence exists on `github/main`: `packages/runtime/src/native.test.ts`,
`codex-native.test.ts`, `serve.test.ts`, `threads.test.ts`, `projects.test.ts`, `legacy.ts`,
`packages/shared/src/notify.test.ts`, `scripts/benchmark-sync.mjs`, the `ChatModelTests`,
`AgentTraceTests`, `DrainTests` and `EventTests` Swift suites, `apps/mac/Yorozu.entitlements`,
`apps/mac/Node.entitlements`, and `docs/history/native-ui-performance-2026-09-20.md`. The log itself
landed in `17ef0ab`. Its "preserved local commits" (`42f431f`, `419ffc5`, `4ac5c5a`, `36ae3df`,
`0e3bdd6`, `b6e9bf0`, `8d45e93`, `8e9b098`, `83bf186`) are not objects on GitHub; see Blockers for
the commits that replaced them. `version.txt` and `.release-please-manifest.json` both read
`0.3.0`. The 2026-09-20 comment's "0.1.0 (196)" cannot be reproduced from today's history: `v0.1.0`
now names `682c948` with a commit count of 165.

Not run locally: `scripts/build-mac.sh`. The Developer ID identity and the `yorozu-notary` profile
are both present on this Mac, but the shipped DMG was already verifiable byte for byte, so a second
build would have added nothing.

## What remains, and the exact commands

1. **Install 0.3.0 (282) at the canonical path.** Close the chat window (or quit Yorozu); Sparkle
   installs the update it is holding and relaunches. Then confirm:

   ```sh
   defaults read /Applications/Yorozu.app/Contents/Info.plist CFBundleVersion   # 282
   spctl -a -vv /Applications/Yorozu.app                                         # accepted, source=Notarized Developer ID
   grep 'launch: build 282' ~/Library/Logs/Yorozu/app.log | tail -1
   pgrep -fl /Applications/Yorozu.app/Contents/MacOS/Yorozu
   ```

   If Sparkle does not take over, quit Yorozu and install by hand from the same bytes:

   ```sh
   curl -L -o /tmp/Yorozu.dmg https://yorozu.yumi.to/mac
   hdiutil attach -nobrowse -mountpoint /tmp/Yorozu-dmg /tmp/Yorozu.dmg
   rm -rf /Applications/Yorozu.app && cp -R /tmp/Yorozu-dmg/Yorozu.app /Applications/
   hdiutil detach /tmp/Yorozu-dmg && open /Applications/Yorozu.app
   ```

2. **Physical iPhone.** In TestFlight, install Yorozu 0.3.0 (282) (Internal group; `hasAccessToAllBuilds`
   is on, so it is offered without any further ASC step). With the Mac on 282 and paired: new thread
   → Claude Code → pick a project folder → send a prompt that needs a tool the thread has not been
   granted (for example "create a file called hello.txt in this folder"). Lock the phone, answer
   **Allow** from the lockscreen notification, unlock, and confirm the reply arrives in the thread.
   Bypass must be off on that thread for the approval to appear.

3. **PAIOS.** Update the Yorozu project record with: Mac 0.3.0 (282), iOS 0.3.0 (282), release URL
   `https://github.com/izyuumi/yorozu/releases/tag/v0.3.0`, ASC build `d5beebd6-3b34-4ba7-8337-a37e81495900`,
   notarization submission `457ed383-20b8-42d9-a801-19e926596d39`, and a link to this file.

4. **Close out #12.** Tick the four boxes in the issue body once steps 1–3 are done, then:

   ```sh
   gh issue comment 12 --body "Released as 0.3.0 (282) on both platforms; evidence in docs/history/native-bridge-release-2026-09-24.md. iPhone lockscreen approval verified; PAIOS updated."
   gh issue close 12 --reason completed
   ```

# Test audit — 2026-09-25

Focused audit using OpenClaw's [test-audit skill](https://github.com/openclaw/openclaw/blob/5032aed36bd370e9905eec28c22c384feadef830/.agents/skills/test-audit/SKILL.md).
Read-only discovery covered runtime, shared TypeScript, relay, Swift/apps, and release/web
tooling in parallel. This was a candidate sweep, not a complete per-test campaign ledger.

Discovery used local `3ffbf03` plus existing working changes. Publication was isolated on
`e04f67b`, the fetched remote main, with the selected files confirmed identical at both
bases. Existing user edits were excluded. Follow-up code was checked against the newer base;
the catalog's URL changed upstream, but its rejection-test weakness remains.

## Applied batch: watchdog's unused Swift mirror

| Evidence | Finding |
| --- | --- |
| Exact test | `onlyADeadlineInTheFutureIsAPause`, `apps/mac/Tests/YorozuKeepaliveTests/WatchdogTests.swift`, original lines 55–63 |
| Covered owner | Internal `Watchdog.isPaused(contents:now:)`, `apps/mac/Sources/YorozuKeepalive/Keepalive.swift`, original lines 233–239 |
| Actual failure detected | Parsing/comparison errors in an unused Swift copy of the shell pause predicate. Changing the shipped script cannot fail this test. |
| Non-test callers | None in the repository. The method is internal; its test reaches it through `@testable`. The package exposes no Keepalive library product. |
| Remaining proof | `scriptRelaunchesAnAppThatIsNotRunning`, `scriptHoldsOffWhileAQuitIsStillPaused`, `scriptResumesOnceThePauseHasExpired`, and `scriptTreatsAnUnreadablePauseAsNoPause` execute the shipped `watchdog.sh` with temporary files. |
| History | `1cc4b028` introduced the mirror and shell tests together. Its comments explicitly acknowledge that the Mac obeys the shell implementation. `1512f31a` later made deliberate quit remove the watchdog. |
| Deletion unlocked | Unused Swift function and its explanatory comment; mirror test and obsolete section heading. Corrected test-file introduction. |
| Risk | Low: no production caller or live behavior changed. The deleted empty-string case exercised only the unused Swift parser, so it provided no shell coverage. |
| Validation | `env -u SDKROOT swift test --package-path apps/mac`; unchanged shell owner and all four executable script tests remain. |

Root cause: a test kept a second implementation alive instead of checking the implementation
the application actually executes. No replacement seam, abstraction, or test was added.
The plist tests, pause-file compatibility, and launch-time cleanup remain.

Changed LOC, excluding this report: production **+0/−8**; tests **+2/−16** (net −14);
test support/tooling **0**.

## Follow-ups, deliberately outside this batch

These are separate owner-boundary changes, not approval to remove whole suites.

1. **Repair the catalog's false-negative rejection test.**
   `packages/runtime/src/catalog.test.ts`, `a Content-Length over the cap is refused before
   the body is read`, supplies a stream that throws when read. `loadCatalog` catches read
   errors and returns the same fallback/no-cache result asserted by the test. By inspection,
   deleting the declared-length guard would still pass. Keep the security contract: use a
   valid small body under an oversized header and prove the reader was not used. Demonstrate
   failure with the guard removed before accepting the repair. Origin: `c10d109`.
   **Mutation proof was not run.** Validate catalog and assignment suites.

2. **Remove inert shared event fixtures.**
   Thirteen tests in `packages/shared/src/index.test.ts` only construct typed literals and
   read those literals back or JSON-round-trip them. Vitest erases types, its installed
   default disables type checking, and the package's `tsconfig.json` excludes tests.
   The `every spec'd kind exists` case counts its own 22-entry array while the production
   union has 35 kinds. Other examples are `subagent events carry a parent`,
   `reasoning effort and YOLO settings cross the device wire`, and
   `messages carry multiple mixed attachments`. Origins include `b55192a`, `9f4f465`,
   `c5b6236`, `e7741ce`, `27365da`, `33ffe81`, and `67e3450`.
   No production behavior is exercised by these assertions. Real runtime event producers,
   persisted thread tests, phone/Mac authorization tests, and Swift Codable/interop tests
   remain. Keep the pairing parser test and the independent 5 MB attachment-cap assertion.
   Unlocked cleanup: fixture setup and type imports only, no production code.
   Validate shared build/tests; preserve actual protocol contracts.

3. **Remove runtime scaffold and redundant echo identity check.**
   `describeEvent` in `packages/runtime/src/index.ts` is used only by `describes an event`
   in `index.test.ts`. Introduced by scaffold commit `1c01233`; the private package has no
   other caller or documented contract for it. Removing both needs no replacement proof.
   In the same file, `echo is registered in the shared tool list, and a call by name reaches
   it` (origin `cc002dd`) repeats the stronger `loop dispatches a streamed tool call and
   returns final text`, which uses the real SSE/dispatch/result/history path. Keep echo
   itself: CLI, legacy runtime, and iOS E2E use it. Validate runtime build and index suite.

4. **Consolidate two narrower runtime duplicates.**
   `catalog.test.ts`'s `merging keeps base order and appends what is new` overlaps persisted
   overlay tests introduced alongside it in `78077eb`; retain `mergeById`, which production
   assignment and catalog writers call. `tools/native.test.ts`'s `input acts on an element ID
   or on coordinates` (`863ef748`) is superseded by wire-payload/output tests (`93915ef`).
   Only test/import deletions are indicated. Validate catalog/assignment and native suites
   separately before changing either owner.

5. **Review copied notification vocabulary at its owner.**
   Shared `NOTIFY_BODY`/`NOTIFY_TITLE` have no production consumers; `notify.test.ts`'s
   `no notification body can carry anything from the event` checks the unused inventory.
   Actual APNs vocabulary lives in relay `protocol.ts` and has owner tests. Origin `5127609`.
   Potential cleanup removes shared constants and inventory test, retaining relay privacy
   proofs. Validate shared and relay builds/tests. Separately, the worker preview-selection
   test checks absence of `secret reply` without supplying that string; retain its meaningful
   preview-selection and mutable-content assertions.

6. **Investigate obsolete pause-writing API separately.**
   `Watchdog.pause(for:)` and `pauseDuration` lost their application caller in `1512f31a`.
   Shell compatibility and startup cleanup still exist. Removing the feature needs its own
   compatibility decision; it was not folded into the test-only mirror removal.

## Retained false positives

- Cross-language crypto/event fixtures, replay protection, malformed envelopes, APNs privacy,
  TTL/cap defaults, and worker lifecycle tests protect independent contracts.
- Swift resource-bundle paths prevent the packaged-app launch failure fixed in `4e79a163`.
- Watchdog XML assertions protect launchd input; the ampersand case also uses Foundation's
  real property-list parser.
- Timeline tests protect cache equivalence, invalidation, and repeated-read cost; deriving
  reference rows from the uncached implementation does not make the cache contract circular.
- `tools/mail-script.test.ts` executes the extracted production expression with `osascript`;
  it catches AppleScript list-versus-text behavior rather than merely grepping source.
- Tool schemas protect the model-facing API. Release tests execute publication scripts
  against isolated commands and check ordering/failure behavior. Web copy tests execute the
  browser script and cover clipboard failure and overlapping attempts.
- Real iOS UI tests retain keyboard, pairing, focus, recovery, and accessibility coverage.
  Simulator cost alone is not a deletion reason.

## Proof and limitations

On the original dirty checkout (results apply to that snapshot, not all of remote main):

- Recursive TypeScript build passed.
- Node 26.5.0 / pnpm 11.17.0: shared **54 passed**, relay **136 passed**, runtime
  **651 passed, 1 skipped**. The opt-in real-browser test was skipped.
- Shared Swift **273 passed**; Mac baseline **8 passed**, after deletion **7 passed**.
- Release fixtures **5 passed**, beta-release fixtures **3 passed**, website **4 passed**.

The first pnpm invocation used the environment's Node 24 wrapper. Build and all Node suites
were rerun successfully through Node 26 and the repository-pinned pnpm.

On the isolated publication branch based on `e04f67b`: Mac package **9 passed**, including all
retained watchdog tests. Counts differ because remote main contains additional Mac tests.
The package build includes the current application targets. Focused whitespace/diff checks
passed. Hosted CI is reported on the associated pull request.

OpenClaw's `run-vitest.mjs`, `check-changed.mjs`, `openclaw-testing`, `crabbox`, and `autoreview`
are unavailable in this repository/install. Validation used Yorozu's CI commands and an
independent preservation review instead. iOS simulator E2E, live-browser, signed release,
and device tests were not run locally. No claim of exhaustive test-suite coverage is made.

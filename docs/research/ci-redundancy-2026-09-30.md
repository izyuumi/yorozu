# CI/CD redundancy audit — 2026-09-30

Audited `origin/main` at `60d869d05c3e501f4f6d0315cd8ddb4f96966337`.
Evidence comes from workflow code, package dependencies, and GitHub Actions logs; no
candidate dispatch, upload, rerun, or publication was started by this audit.

## Execution graph

| Trigger | Execution | Gate or output |
| --- | --- | --- |
| PR | `CI`: path selection → release checks, relay image, web, macOS, iOS | Matching jobs; release checks always run |
| Main/release push | `CI`: all jobs | Exact-source build/test result |
| Successful trusted CI push | `Release`: pin source → reusable UI tests → candidate | UI gate, CI recheck, signed/notarized Mac, uploaded iOS, external beta distribution, candidate manifest |
| Nightly main / manual | `UI tests` | Real simulator, relay, sidecar; same-source successes reused by nightly/release calls |
| Main website push / manual | `Deploy website`: build → test → deploy | Cloudflare deployment; tests run before secret-bearing deploy |
| Main/release push | `Release Please` | Version preparation PR only |
| Manual trusted main | `Promote` | Revalidate candidate/CI/Apple approval; publish existing bytes |

`CI` cancels superseded runs per ref. `Release` serializes candidates across branches,
without cancelling signing/uploads. `Promote` and website deployment have separate
non-cancelling groups. The canonical `Release` workflow and its run counter remain unchanged.

## Removed duplicate

[CI run 36612865025](https://github.com/izyuumi/yorozu/actions/runs/36612865025)
proved the same website build and all 15 website tests ran in both jobs:

- Linux `web`: build 18:33:50–18:33:51 UTC, test 18:33:51–18:33:52.
- `macos`: recursive build included `apps/web` 18:34:22–18:34:25;
  recursive test included its same `node --test tests/*.test.mjs` suite at 18:34:31.

Mac recursive build/test now exclude only `@yorozu/web`. Linux `web` remains the owner
of website build/tests. Its PR path selection already includes website and workspace
build configuration changes; main/release pushes run it unconditionally. No website
production dependency is consumed by the Mac app or Swift wire harness. Website tests
exercise static build output, browser copy behavior in Node VM, and Worker routing;
none asserts a native Mac contract. Relay, shared, runtime, and OpenClaw tests remain
in the Mac job. No test case, required job, permission, or event trigger changed.

Savings are small: one redundant Astro invocation and 15 tests per full CI. macOS
boot and Swift compilation dominate this run (~9m20s job duration). This change does
not claim substantial wall-clock improvement.

## Retained or deferred work

| Apparent repetition | Decision and reason |
| --- | --- |
| Website CI + deployment build/tests | Retained. [Deploy 36463265312](https://github.com/izyuumi/yorozu/actions/runs/36463265312) and [CI 36463265206](https://github.com/izyuumi/yorozu/actions/runs/36463265206) ran for `aa6e97a1`. Deployment took ~2s for build/tests. Removing them requires exact-SHA artifact handoff and new event/permission handling; current deploy gate fails closed independently, including manual deploys. |
| `apps/ios/e2e/ui-tests.sh` recursive website build | Deferred. Harness imports built relay/runtime/shared, not website. Filter its build to those dependency closures in a separate focused change; UI tests themselves must still run. |
| iOS CI build + UI-test build + shipping archive | Retained. They prove unsigned compile, simulator interactions, and signed device distribution respectively. A simulator artifact cannot replace a shipping archive. |
| CI TS build + UI harness build + shipping Mac build | Retained. Different isolated runners; shipping build embeds production runtime and release Swift binaries. Sharing untrusted PR build artifacts into signing would change trust guarantees. |
| Candidate CI recheck | Retained. Manual dispatch needs it; publication must bind successful canonical CI to exact SHA/branch. |
| Nightly/release UI tests | Existing same-SHA success reuse retained. [Release 36614032133](https://github.com/izyuumi/yorozu/actions/runs/36614032133) was observed running the restored UI gate; no skip/bypass added. |
| Repeated Node/pnpm/Xcode/Tuist setup | Retained. Runner isolation requires setup. Composite actions reduce YAML, not executed work; caches already cover pnpm downloads. |
| Second install in `build-mac.sh` | Retained. `pnpm deploy --prod` prunes workspace dev dependencies; script restores them intentionally. |
| Skipped Release records for unsuccessful CI | Retained. Job-level trusted push/success guards prevent uploads. Empty records do not indicate duplicate builds. |
| Stable promotion | Already reuses candidate bytes; no rebuild or second iOS upload. |

## Separate security failure

[Dependabot 36612884753](https://github.com/izyuumi/yorozu/actions/runs/36612884753)
failed with `security_update_not_possible`: installed Undici 7.29.0, minimum-safe
7.29.1, no conflicting dependencies listed. `pnpm why undici --recursive` and npm
metadata show both locked Miniflare versions pin **exactly** 7.29.0. Astro/unifont's
Undici 8.11.2 is already outside the reported affected range. Remediation belongs in
a separate dependency patch: narrow 7.29.0 → 7.29.1 override, regenerated lockfile,
relay Worker tests and website build/tests. Do not suppress the Dependabot job.

## Validation

Local proof uses Node 26.10.0 and pnpm 11.17.0:

```sh
pnpm --filter '!@yorozu/web' -r build
pnpm --filter '!@yorozu/web' -r test
pnpm --filter @yorozu/web build
pnpm --filter @yorozu/web test
go run github.com/rhysd/actionlint/cmd/actionlint@v1.7.12
python3 scripts/test-release.py
python3 scripts/test-release-notes.py
python3 scripts/test-build-version.py
node --test scripts/asc-candidate.test.mjs
```

Results: filtered build, website build/all 15 tests, actionlint, Python release tests
(24 publication, 7 notes, 4 version), and all 9 ASC tests passed. Filtered tests passed
shared 60 and OpenClaw 24; relay passed 142/143, failing the Worker rate-limit scenario
at its existing 5s timeout. A focused unchanged-baseline run reproduced the timeout.
Standalone runtime proof was interrupted at the coordinator's request after observing
extreme shared host load; its partial result also had a local Stop timeout. Integrated
GitHub CI remains required; this audit does not claim every local suite passed.

The rate-limit scenario emits 80 frames into a 60-token, 60/s bucket then awaits close.
Worker messages serialize through `this.tail`, and `handle()` samples processing-time
`Date.now()` for refill. A burst processed over ~333ms may refill enough to remain below
the limit; at 16.7ms/frame, refill can sustain each frame indefinitely. This is a real
input/timing risk requiring separate producer/accounting review, not a reason to remove
the gate or enlarge its timeout. Logs retained locally in
`/tmp/yorozu-ci-redundancy-tests.log`, `-relay-focused.log`, and `-runtime-tests.log`.

Also corrected stale `docs/releasing.md`: the canonical run counter assigns the Mac
build/candidate identity; iOS allocates the next build within its marketing version.

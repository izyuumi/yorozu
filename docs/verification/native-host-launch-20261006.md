# Native host launch acceptance — 2026-10-06

Scope: source/local Swift verification from trusted signed `4f5305b`, isolated detached
worktree. No app launch, signed app bundle, install, account access, network fetch, upload,
release, or branch change. This is **not** installed-Mac or physical-iPhone acceptance.

## Fixed source blockers

- `HostWindowMode` now defaults an **absent** preference to enabled, consistently in
  SwiftUI `AppStorage` and non-view lifecycle decisions. An explicit saved false remains
  an opt-out. Clients never inherit host-only presentation when switching roles.
- The main native chat scene uses macOS 15+ `defaultLaunchBehavior` and restoration
  policy rather than creating a window and immediately dismissing it. Configured hosts
  default to no automatic chat; unconfigured users get the existing onboarding window;
  clients and opted-out hosts retain automatic chat/restoration.
- Cold Finder/open-application events no longer eagerly request Quick Chat. Login,
  watchdog and update launches likewise remain quiet. Reopening an already-running host
  still deliberately opens Quick Chat.
- Quick Chat and Settings are explicitly excluded from automatic launch/restoration.
- `Open Yorozu` is available to hosts as well as clients and opens the same full native
  chat window. Onboarding's deliberate Open Yorozu button works in host mode too.
  Quick Chat, Settings, Finish Setup and Settings → Run Again remain native surfaces.
- Closing the last window does not terminate the app. Main-window disappearance only
  adjusts presentation and stops speech; it does not stop Sidecar. Existing explicit Quit
  confirmation/termination and watchdog policies remain unchanged.

No layout redesign, browser shell, Electron surface, alternate app identity, TypeScript
change, or iOS source change was introduced.

## iOS person registry → memory sharing mapping (source evidence)

1. `apps/ios/Sources/YorozuIOS/SettingsView.swift` embeds native shared
   `PersonAgentsView`; `RootView.swift` embeds native shared chat. The Swift registry is
   `PersonAgentRegistry` / `ChatModel.personAgents` (not a literal `person_registry` view).
   `packages/shared-swift/Sources/YorozuShared/PersonAgentsView.swift` opens each agent's
   canonical conversation and exposes its Harness requests/history routes.
2. In that native conversation, ask the worker to share its own note with a named agent.
   The host tool contract is `worker.memory` with `action: "grant"`, `toAgentId`, `key`,
   and `operationId`; the client does not issue a privileged grant by optimistic UI state.
   `packages/runtime/src/person-agent-runtime.ts` emits a `harness_action` approval with
   title `Share <key> with <agent>?`, note body, future-update/read-search-only scope,
   and choices **Grant note access** / **Do not share**. The one-shot answer approves
   a persistent-until-revoked note grant, not a one-time read.
3. Shared `ChatView.swift` places `HarnessActionPresentationView` above the native
   composer. `HarnessActionView.swift` renders the host-provided choices as SwiftUI
   buttons. `ChatModel.answerHarnessAction` sends `harness_action_answer` with exact
   request/origin identity; matching `harness_action_status` determines the outcome.
   Disconnected/stale registry, changed session or binding, duplicate answers, and
   unsupported capability must not become new authority. The card distinguishes applied,
   rejected, no-longer-needed and unknown outcomes. Host-side grant confirmation is also
   fenced to the live foreground turn and unchanged note content (25-second timeout).
4. To revoke, ask the owning agent in that same native chat to revoke access to the note
   from the recipient. `packages/runtime/src/worker-tools.ts` handles `worker.memory`
   `action: "revoke"` with the same recipient/key/operation fields, without granting new
   authority or requiring a grant card. Worker/host tool outcome is the evidence; a sent
   chat message is not proof of revocation.

**Actual UI gap:** there is no dedicated native memory-note/grant browser, share picker,
revocation list/button, or dedicated grant-revocation receipt view in this base. The current
minimal client uses chat tool requests and the generic native approval cards. These are
source-supported routes, not a claim that a live provider, paired phone, grant, or revoke
was exercised. Account activation and packaged-worker availability remain separate gates.

## Local verification

Swift toolchain: Apple Swift 6.4, arm64 macOS; package minimum macOS 15. Cached SwiftPM
checkouts/artifacts were copied into this worktree; `--skip-update` avoided remote updates.

- `swift test --package-path apps/mac --skip-update` — passes: 20 native keepalive/app
  tests (including four new launch-policy/lifecycle tests), 10 account-core fixture tests.
  This compiles the actual SwiftUI app target locally, not a signed application bundle.
- `swift test --package-path packages/shared-swift --skip-update --filter 'platform|agentEditor|agentPatch|personChats|connectedAgentEditor|previousAgentHistory|reviewNewAgent|personAgent|harness'`
  — passes: 23 native shared tests, including exact-origin action answers, person registry
  authority/current-catalog checks, and native agent editing/history routes.
- An initial filter using source filenames (`HarnessPlatformTests|PersonAgentEditingTests|PersonAgentsTests`)
  matched zero tests; it is not counted as acceptance. The named-function filter above is
  the actual regression result.
- `git diff --check` — clean.

Before release, parent still needs installed-app cold launch/login/update behavior,
deliberate Open Yorozu/Settings/onboarding and window-close-with-host-alive acceptance;
paired iPhone memory grant/deny/revoke/read-search acceptance; and separate backend,
account, signing, distribution and installation verification. No physical-device proof
is asserted here.

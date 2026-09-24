# Onboarding design

Design canvas (Claude Design, 24 artboards, version 6 after review):
<https://claude.ai/artifact/Rjd6GR67ckjDHXoiR3anUr>. Private; ask the owner for access.

## What the flow is

One setup window on the Mac, two paths. Step actions stay in the footer; pairing and
permissions content scrolls within the window.

| Path | Steps |
| --- | --- |
| Host | Role → Connect your devices → Permissions → Done |
| Client | Role → Connect to your host Mac → Done |

- **Role** — `YorozuMark` above a centred heading, two role cards. Choosing goes through
  `MacChatSession.select(_:)`, which keeps a stored client pairing. Nothing here calls
  `clearRole()`.
- **Connect your devices** — `PairingSheet` embedded (`embedded: true` drops its own title,
  width and padding; the QR, the baseline detection and the code string are unchanged).
  Before a pairing: **New code** and **Skip for now**. After the sheet detects a device that was
  not in its baseline: **Continue** only, because the sheet freezes its success state and stops
  polling.
- **Permissions** — existing `PermissionsView(scope: .onboarding)` rows inside a scroll view.
  Everything optional. The settings-wide grouped Form redesign is outside this commit.
- **Host done** — "This Mac is set up", a device count filtered to `via == .relay`, and one
  next step: set up the agent you use (OpenClaw for assistant chats, Claude Code or Codex for
  coding). No runtime state and no readiness claim.
- **Client connect** — paste field; progress while a stored pairing waits on the host handshake;
  on failure **Retry** (`retryConnection()`, same identity) or a newly pasted code. Repeated
  submission of the same pending code is disabled; a replacement code stays available.
- **Client done** — reached only once `model.state == .paired`. The host row is
  `ClientConnectionStatus`, so a previously confirmed client honestly shows "Host Mac offline".

iPhone: `PairingFlowView` keeps its scanner sheet, manual sheet, demo, inline status and
session semantics. It gains the warm canvas and vermilion tint, a three-step guide card with a
link to the Mac app, and a 360-point content column so an iPad or a landscape phone reads
well. The scanner adds one true line: "Scan a code from a Mac you trust. Pairing codes are
secret." The thread-list handoff is unchanged.

## Lifecycle

- `OnboardingWindow.isComplete` is `role != nil && onboardingCompleted`. Choosing a role and
  quitting brings the window back next launch, and the menu bar offers **Finish Setup…** until
  it is finished.
- The step for a role follows the live transport, both on opening and on choosing a role
  again: no role → role; host → connect devices; client with `model.state == .paired` (the
  host's encrypted greeting) → done; anything else → connect, showing the
  `ClientConnectionStatus` label. The saved `paired` flag only proves the relay joined, so it
  never routes to done. The state observer runs with `initial: true`.
- **Open Yorozu** finishes setup, activates the app and calls `OnboardingWindow.openChat`, a
  closure `YorozuMacApp` registers from the `MenuBarExtra` label's `.task` — the one
  `openWindow` that works for an `NSWindow` outside the scene graph. First-launch setup is
  shown from that same task, after the registration. **Close** only finishes.
- Reopening a closed setup window rebuilds its root view so no stale `@State` survives.

## Copy rules

- Paired is not ready. "It can reach this Mac now. Whether an agent answers depends on what is
  set up here."
- "Codes work once and expire; keep this one private." Minting a new code does not revoke an
  older unexpired one.

## Verification

Isolated commit checked on 2026-09-25 against GitHub `main` (`966c81a`):

- Mac build/tests: 10 passed after integrating the latest watchdog tests. iOS Simulator build passed.
- Shared Swift: 273 passed. An existing reconnect test was corrected to wait for its
  update-status event and queued-message delivery, rather than count unrelated protocol
  frames. The focused test failed before the repair and passed afterward. No shared
  production source changed.
- Five offline iOS pairing UI tests passed on 2026-09-24 in the original workspace,
  covering manual input, asynchronous failure, scanner fallback, connecting state, and
  largest Dynamic Type in landscape. Portrait screenshot inspected. Landscape accessibility
  frames passed, but the simulator screenshot was malformed, so visual QA there is limited.
- Broader settings and shared/runtime edits were excluded. Permissions use the existing
  rows in a scroll view rather than the concurrent settings Form redesign.
- Design artboards reviewed in light and dark appearance. Live relay pairing, macOS privacy
  prompts, and the installed Mac app were not exercised against the user's existing state.

Logs and simulator attachments are in `/tmp/yorozu-onboarding-design/`.

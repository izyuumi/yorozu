# Deferred native fixture — identity and scope

No native fixture run, new permission probe or permission grant is part of the ordinary-
model/CI continuation. Native capture/input behavior remains unverified. This document
records what a later coordinated approval would need; it is not an approval request now.

## Exact current helper and target app

- Test helper executable name: **textedit_fixture** (the opt-in Cargo example).
- Current compiled path:
  `/Users/yumi/Documents/Codex/2026-10-02/task-13/computer-use/packages/computer-use/target/debug/examples/textedit_fixture`.
- Source: `examples/textedit_fixture.rs`. Nothing installs or registers this helper.
- Target app: **TextEdit**, bundle ID **com.apple.TextEdit**, system app
  `/System/Applications/TextEdit.app`.
- Sole permitted target document: this task's
  `fixtures/Yorozu Computer Use Fixture.txt`, with that exact window title and the caret
  on its blank line, wholly contained on one display and already foreground.

The executable accepts only the deliberate `--coordinated` fixture opt-in. It does not
open/focus apps or save/close documents. It types only
`Hello Yorozu — こんにちは、よろず` and captures before/after PNGs under the package's
ignored `target/textedit-fixture/<attempt-id>/` directory. No live model is involved.

## Required existing permissions, later

- **Screen Recording / Screen & System Audio Recording** for the actual executing
  helper/responsible process: ScreenCaptureKit screenshot capture.
- **Accessibility** for the actual executing helper/responsible process: Enigo desktop
  input synthesis.

The last permission-only probe was the separate `permissions` example and reported
both false. `textedit_fixture` has not run. The macOS TCC entry/responsible application
for its eventual launch route has not been verified, so do not equate that probe with a
verified helper-specific permission identity. Later coordination must identify the OS's
actual helper/responsible-process entry before approving access. No blanket approval for
Cargo, a terminal, Codex or an unspecified Yorozu app is requested here.

No Yorozu computer-use helper `.app` bundle has been created, signed, installed or
registered. A distributable helper's stable bundle/signing identity and purpose strings
are future app integration work; this document does not invent an installed identity.

The adapter never grants permissions: it checks existing access and configures Enigo
with `open_prompt_to_get_permissions = false`. No security/network settings, Apple
Events automation approval, passwords, accounts or third-party actions are involved.

# Computer use: Mac-first scope

Scope update recorded on 2026-10-02 from the user's explicit instruction:

> まずはMacだけでいいよ 今あるものはキープして、今後はMacだけをとりあえず考えて

Preserve existing work; prioritize Mac only for further implementation and verification.
This supersedes the broader platform priorities in the initial computer-use plan. Do not
add Linux/Windows features, adapters or manual validation work now. Existing portable
code, tests and package CI remain intact; this is a scope record, not a platform cleanup.

## Preserved checkpoint

Branch `computer-use-alpha`, signed/verified code checkpoint
`f4b536cf403957274c39e76579117d4d5438ba37`: independent desktop executor, bounded private
worker context, ordinary-model adapter contract/loop and synthetic provider tests.
Twenty tests, formatting, Clippy and builds passed locally and in the existing
[package-only Linux/macOS/Windows CI run](https://github.com/izyuumi/yorozu/actions/runs/36986491407).
That prior cross-platform proof is retained; native Mac behavior remains unverified.

## Smallest remaining Mac integration plan

1. Connect the ordinary-model contract to the authorized BYO route and secretary
   dispatch/steer/queue/stop through approved Mac runtime/task interfaces. Preserve
   task/parent/origin/attempt IDs and keep worker images/history outside main model
   context. Use approved scheduler interfaces for durability; defer any integration
   requiring paused host-core operational files. No live provider calls under the
   current authorization.
2. Establish the Mac helper's actual launch/signing identity and host-owned single
   desktop queue. The current test executable is not an installed helper app. Build
   integration can proceed separately from installation or OS permission approval;
   neither install nor permission changes are authorized now.
3. After later user coordination resolves the blocker below, run only the disposable
   TextEdit fixture with fixed English/Japanese text and before/after image evidence.
   Verify capture, input acceptance and display transforms; label anything not actually
   observed unverified. Focus future integration proof on Mac.

## Exact native verification blocker

The current helper is **textedit_fixture**, the compiled opt-in Cargo example at
`/Users/yumi/Documents/Codex/2026-10-02/task-13/computer-use/packages/computer-use/target/debug/examples/textedit_fixture`.
Its target app is **TextEdit** (`com.apple.TextEdit`), solely the task-owned document
`Yorozu Computer Use Fixture.txt`.

Native proof is blocked because the helper has never run, its actual macOS TCC
responsible-process identity has not been established, and **Screen Recording / Screen
& System Audio Recording** plus **Accessibility** are not confirmed for that identity.
The previous separate `permissions` probe returned both false; it does not establish
helper-specific approval. No stable Yorozu computer-use helper `.app` bundle has been
created, signed, installed or registered.

Later coordination must identify that actual helper/responsible-process entry and the
required existing permissions, then foreground only the fresh fixture document with
its caret on the blank line and keep the desktop idle during fixed entry/capture.
[NATIVE_APPROVAL.md](../packages/computer-use/NATIVE_APPROVAL.md) records the exact helper,
app, document and permission scope. No grant, probe or native run is requested now.

The stopped migration/recovery work remains stopped. No paused operational files, main
or alpha merge, release, installation or security/network setting changes are included.

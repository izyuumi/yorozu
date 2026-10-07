# Current native live repair readiness

Owner-independent initial launch is **verified**, not pending. Parent observed `hi` -> failure in PID51375/window11311; see [LIVE_UI_TEST.md](LIVE_UI_TEST.md). The original running app and all history remain untouched.

Source-confirmed defect repaired: ordinary CLI agent requests have operator.write and cannot carry the previous per-turn model override. Models now selected through app-owned sessions.create; agent invocation omits override. Bounded in-memory stderr classification exposes only fixed category/exit code. Exact request/session/source-message linkage now persists before dispatch; lost raw-model calls require exact-run terminal reconciliation before replacement. The old uncorrelated hi cannot acquire a fabricated run ID retroactively.

Separate latest staged bundle: **build/PROJECTX-Live-R1-receipts.app**. Final local suite: 47 Swift tests. Parent coordinates switching only the live app window, keeps the same workspace/history and old synthetic window, then tests one fresh greeting in the repaired UI. No automatic replay, token copying, provider re-login, policy change, or restricted-launch bypass. A selected-live banner is not a response receipt. Strict steering remains separately gated.

Authoritative repair details and verification receipts: [LIVE_TRANSPORT_REPAIR.md](LIVE_TRANSPORT_REPAIR.md). This task is at patched-app verification, not waiting for the owner to perform the already-completed initial launch.

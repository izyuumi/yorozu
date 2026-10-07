# Native live UI test — 2026-10-07 19:54 JST

Owner independently opened PROJECTX-Live-R1.app and confirmed 'Opened' (message 1791370437653). Parent used CuaDriver supported native window observation: PID 51375, window 11311, title PROJECTX — Live integration unverified. Screenshot saved `build/live-ui-1954.png`.

Observed persisted user `hi` and assistant error: `Gateway refused/disconnected. Existing authentication is not disproven; inspect run status before retry.` This is a real connection-failure observation, NOT a successful live model reply. Parent did not send duplicate test messages, alter history or close the window.

Static review: GatewayRPC drops CLI stderr and maps every nonzero exit to this generic failure. CLI help confirms command flags exist. Actual failure category is not established; do not label it authentication failure. Active integration worker informed to retain sanitized error diagnostics and repair transport. Existing guard remains intact; no alternate launch performed.

Acceptance: owner launch and native UI observation verified; live greeting FAILED; substantive worker/steering testing not reached.

## Transport-fix retest — 20:06 JST
Owner independently opened replacement and sent hi. Parent read-only computer observation of new PID55084/window11339 shows new error `Gateway CLI failed [exit=1, category=unclassified-refusal-or-disconnect]`. Screenshot `build/owner-fix-opened.png`. Prior history remains visible. No parent input/retry or launch. Patched greeting still FAILED; source model-override repair did not establish success. Active app-enrollment worker informed of exact diagnostic.

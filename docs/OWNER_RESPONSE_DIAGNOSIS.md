# Owner response report — 2026-10-07 18:49 JST

Owner reported odd responses after sending messages (message 1791366598157). Parent inspected project app source and `build/uiqa-fixture-1849/operations.sqlite` using SQLite read-only URI, no history changes.

Observed user greetings hello and hi. First received synthetic fixture fixed reply; second generated a background acknowledgment followed by synthetic fixture result. `FixtureHarness.route` special-cases hello; other messages enter synthetic delegation. This is fixture behavior, not live model output or evidence of model quality failure.

Parent informed active native worker; steering accepted. Requested prominent test-only banner/window identity to prevent fixture being confused with live product. Preserve owner-entered history and do not close active owner window or switch into live mode without coordination. Live integration prohibition remains controlling. No claim of fix completion yet.

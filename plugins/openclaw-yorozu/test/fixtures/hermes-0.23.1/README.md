# Hermes 0.23.1 recordings

Source is the Hermes v0.23.1 test install at `127.0.0.1:8652`. Fixtures 01–17 came from `probe.sh` on 2026-11-19 before Codex sign-in. Fixture 307 records an approval denial after sign-in.

The recordings keep the original JSON field names, value types, and SSE event shapes. Absolute home paths use `/Users/owner`. In fixtures 01–17, host values and probe-generated identifiers use placeholders, header files use LF, and response lengths match the scrubbed bodies. Fixture 307 includes the model's reply after denial.

| Files | Values replaced |
|---|---|
| `01-caps-nokey.headers`, `01-caps-nokey.body` | Unchanged |
| `02-health.headers`, `02-health.body` | Unchanged |
| `03-health-detailed.headers`, `03-health-detailed.body` | Listener host and URL, process identifiers and start time, and disk usage values |
| `04-capabilities.headers`, `04-capabilities.body` | Unchanged |
| `05-models.headers`, `05-models.body` | Unchanged |
| `06-toolsets.headers`, `06-toolsets.body` | Unchanged |
| `07-sessions-list.headers`, `07-sessions-list.body` | Unchanged |
| `08-run-create.headers`, `08-run-create.body` | Run ID |
| `09-run-events.headers`, `09-run-events.sse` | Run ID |
| `10-run-status.headers`, `10-run-status.body` | Run, session, and admission IDs |
| `11-run-replay-same.headers`, `11-run-replay-same.body` | Run ID |
| `12-run-replay-diffbody.headers`, `12-run-replay-diffbody.body` | Unchanged |
| `13-run-next-attempt.headers`, `13-run-next-attempt.body` | Run ID |
| `14-session-get.headers`, `14-session-get.body` | Session ID |
| `15-session-messages.headers`, `15-session-messages.body` | Session ID |
| `16-run-status-unknown.headers`, `16-run-status-unknown.body` | Unchanged |
| `17-session-unknown.headers`, `17-session-unknown.body` | Session ID |
| `307-status-pending.body`, `307-deny.request`, `307-deny.body` | Unchanged |
| `307-events.sse` | Capture timestamps removed from line prefixes |
| `index.txt` | Run, session, and message IDs |

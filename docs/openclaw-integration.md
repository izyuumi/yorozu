# OpenClaw integration — working state, 2026-10-07 21:30 JST

PROJECTX live mode works against the local Gateway (OpenClaw 2026.9.6, `ws://127.0.0.1:18789`, token auth, dedicated `projectx` agent). Verified by a real-UI run (`build/live-working-2026-10-07.png`) and the opt-in live test `PROJECTX_LIVE_TEST=1 ./scripts/test_native.sh --filter LiveGatewayTests`: greeting reply, delegated worker result, same-topic follow-up on the same session, memory note saved. Test sessions are deleted afterwards.

## Why `hi` failed

`sessions.create` was sent with `idempotencyKey`. The Gateway only accepts that from a caller with an authenticated principal or device identity (`src/gateway/server-methods/session-create-idempotency.ts`). The CLI's shared-token connection has neither, so every turn was refused with `INVALID_REQUEST` before any model ran. Re-creating an existing key is already idempotent, so the key is simply not sent. A later refactor had also removed the CLI transport and left the app target uncompilable; the CLI transport is the default again and native WebSocket is opt-in (`PROJECTX_TRANSPORT=native`).

## Gateway facts the code now relies on

Verified in `~/openclaw` source (the running build) and with live probes on throwaway `projectx` sessions.

- `agent` `--expect-final` returns `status`, `result.payloads[].text` (full text) and a `terminalReply` preview capped at 4096 chars. `terminalReply` only gates visibility; text comes from payloads.
- `modelRun:true` turns are stateless: no tools, no transcript, a hidden per-run session.
- `agent.wait` keeps run snapshots in memory for 10 minutes. Unknown, rejected and evicted runs all look like bare `{status:"timeout"}`. It is never used to block new raw turns.
- The session transcript (`chat.history`) keeps each run's reply under `__openclaw.runId` and the admitted user turn under `idempotencyKey: "<run>:user"`. Text blocks are capped at 8000 chars unless `maxChars` is raised. Reconcile uses this, with `maxChars: 64000`.
- `chat.abort` returns `aborted:false` when nothing with that run ID is active, queued or pending.
- `tools.invoke sessions_send` is `not_found` because the `projectx` agent denies all tools. Changes to running work therefore become a follow-up turn of the same task and session.
- Re-creating a session with a different model needs `operator.admin`. Role model sessions are created once per app run; if the Gateway reports a different model than requested, the session is recreated once.
- CLI `gateway call` exits 1 with a JSON error envelope on stdout; the app shows its code and message.
- Timeouts: worker `timeout` 240 s (seconds) < CLI `--timeout 260000` (ms) < process kill 270 s.

## State-machine fixes found by review

- A lost or failed secretary call no longer wedges all later chat.
- Retry of a run that finished before a saved change applies that change as a follow-up on the same task.
- Work that never dispatched (no run ID) is retryable after restart.
- A stop is confirmed only when no local step can still dispatch. Lingering stop requests are settled from the Gateway's answer.
- A late steer admission cannot overwrite an amendment already taken as input.

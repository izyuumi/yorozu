# Issue 283: read-only scheduling contract checkpoint

Checked against the installed official OpenClaw package **2026.9.6** on 1 October 2026.
No live personal schedule, configuration, credential, token, device grant or gateway connection
was read or changed during this investigation. No schedule was created, edited, paused or run.

## Verified gateway contracts

The authoritative installed sources are `packages/gateway-protocol/src/schema/cron.ts`,
`src/gateway/server-methods/cron.ts`, `src/gateway/method-scopes.ts` and the public CLI implementation
in `src/cli/cron-cli/register.cron-add.ts` and `register.cron-runs.ts`.

| Method | Read request | Useful returned data |
| --- | --- | --- |
| `cron.list` | `includeDisabled: true`, bounded `limit` (1–200), `offset`; supported filters include agent, enabled state, schedule kind and last outcome | Jobs with stable `id`, `name`/optional `displayName`, `enabled`, schedule, state and optional configuration revision; paginated metadata. |
| `cron.status` | Empty object | Scheduler readiness/status. Project only the user-facing enabled/next-wake facts; do not relay local storage paths. |
| `cron.runs` | Stable job `id`, bounded `limit` (1–200), `offset`, `sortDir: "desc"` | Finished entries with job ID, timestamp, optional run ID, outcome, duration and delivery outcome; optional summaries/errors are personal content and should not enter logs. |

All three methods require **operator.read**. Read APIs apply caller and session visibility scopes;
an empty authorized page does not establish that the entire host has no jobs. Validate response
shape and pagination before replacing the client's last successful snapshot. Never coerce a failed
or malformed response into an empty list.

Schedules can be one-time (`at`), interval (`every`), cron with optional timezone (`cron`), or
event/stream driven (`on-exit`, `stream`). Missing timezone must remain explicit as the host default,
not be invented from the phone's timezone. Do not turn unknown/event schedule kinds into daily jobs.
Job payloads can describe agent turns or system events and command/script work. User schedules and
system maintenance need distinct presentation; payload kind alone does not prove user ownership.
Do not expose command paths, private session keys, raw payloads or local gateway configuration.

## Authorization blocker

The public plugin runtime has `api.runtime.gateway.request`, but
`src/gateway/server-plugins.ts::dispatchTrustedPluginGatewayMethod` rejects callers unless their
plugin origin is bundled or their install has trusted official provenance. The policy is enforced
by `src/gateway/server-plugin-subagent-runtime.ts::canTrustedOfficialPluginRequestScopes`.
Being present in a user's plugin allowlist does not confer that provenance. Yorozu's custom channel
plugin must not claim this surface as an available schedule backend.

Yorozu's existing production integration uses the owner-only `channel.sock` connection. Its current
model and message responders do not hold an authenticated operator gateway RPC session. The host's
`agent_status` request does not create one either. No existing gateway read integration was found
that can be reused to satisfy the requested bridge under the current authorization constraints.

The SDK's `callGatewayFromCli` is a separate authentication path. Default client construction can
load/create identities and persist returned device authentication; it must not be used as an
implicit workaround. Installed code also has a `sharedStateMode: "read-only"` lifecycle, but local
read-only storage alone is not evidence that a connection cannot create a server-side pairing
request or grant. Reusing that SDK requires an explicit integration decision and verification of
the no-new-grants/no-identity-creation policy with synthetic authentication fixtures first.

## Actionable next implementation

Resolve one supported operator read path before shipping a schedules tab: either reuse an existing
authorized gateway client exposed through a documented adapter API, or authorize a dedicated
read-only SDK client that fails closed when already-granted read authority is absent. Do not mark
the custom plugin official, edit trust policy, enroll a device, request additional scopes or export
credentials to Yorozu clients. The bridge must whitelist exactly the three read methods.

Once the path is resolved:

1. Normalize bounded list/status/history responses inside the host adapter. Negotiate an explicit
   `schedule-read-v1` protocol capability; version transport events in TypeScript and Swift.
2. Bind requests and responses to the owning paired host and stable request/job IDs. Use deadlines,
   cancellation and generation checks so a late response cannot replace another host's snapshot.
3. Persist successful minimal snapshots in the existing per-host encrypted cache, with fetch time.
   An offline/error/unsupported state must preserve but label the last snapshot stale. A successful
   empty result must be distinguished from unavailable data and incomplete pagination.
4. Add native list/detail/run-history views with host identity, schedule/timezone, enabled state,
   next run and last outcome. Keep refresh/cancel/navigation only; no unsupported mutation buttons.
   Retain existing chat drafts, recovery, Settings and split-view navigation while adding tabs.
5. Test adapter projection/auth denial, duplicate IDs, bad pages, timeouts, host isolation, late
   refreshes, cancellation, repeat refresh and encrypted snapshot relaunch using synthetic jobs.
   Then exercise the existing relay transport and native iPhone/iPad builds. Claim provider access
   only after an authorized real read succeeds; never infer it from fixture UI.

This checkpoint contains no schedule implementation or fake scheduler. The completed composer
slice is preserved separately in signed local commit `ba7dcfd`; its 447 shared tests, 16 macOS
tests, 210 runtime serve tests and three native relay-backed UI checks are unaffected.

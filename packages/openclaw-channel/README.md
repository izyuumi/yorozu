# Yorozu channel for OpenClaw

Adds [Yorozu](https://yorozu.yumi.to) as an [OpenClaw](https://openclaw.ai) chat channel, like
Signal or Telegram. Each Yorozu thread is its own OpenClaw conversation, and OpenClaw's cron,
heartbeat and `message` tool can post into Yorozu (target `yorozu:<threadId>`).

The plugin runs inside the OpenClaw Gateway and connects to the Yorozu host on the same Mac
through its owner-only socket, `~/Library/Application Support/Yorozu/channel.sock`. It needs no
credentials; the socket's `0600` mode is the access control.

## Install

The plugin ships inside Yorozu.app. On the Mac that hosts Yorozu:

```sh
openclaw plugins install --link --accept-capabilities /Applications/Yorozu.app/Contents/Resources/openclaw-channel
openclaw config set channels.yorozu.enabled true
openclaw agents bind --bind yorozu
openclaw gateway restart
```

`--link` points OpenClaw at the copy inside the app, so every app update updates the plugin;
restart the Gateway after one. OpenClaw asks you to confirm a source outside ClawHub; in a
non-interactive shell, add `--force` to the install line (it also replaces an older git install). `agents bind` routes Yorozu to OpenClaw's default agent; add `--agent <id>` to pick another.
With several agents and no binding, OpenClaw rejects every Yorozu message.

### Update

Install the latest Yorozu beta through the app's updater, then run `openclaw gateway restart`
on the host when you are ready to end active Gateway runs. Updating the app replaces the linked
plugin files; the restart loads them into OpenClaw. A socket reconnect alone keeps the loaded
plugin code. If you installed from a checkout or copied directory instead of linking the app's
bundle, use the install command above to link the updated bundle first.

The plugin reads OpenClaw's current activated configuration for every model request and when
each queued message begins dispatch. Settings reloads affect subsequent requests without
restarting this channel; an in-flight request retains the configuration it started with.

`openclaw channels status` then lists **Yorozu** as connected while Yorozu is running.

To work on it from a checkout, link `packages/openclaw-channel` instead and run
`pnpm --filter @yorozu/openclaw-channel test`.

## Config

| Key | Default |
| --- | --- |
| `channels.yorozu.enabled` | `true` |
| `channels.yorozu.socketPath` | `~/Library/Application Support/Yorozu/channel.sock` |

## Protocol

Newline-delimited JSON over the socket. Both directions are at least once and acked by id.

| Frame | Direction | Meaning |
| --- | --- | --- |
| `inbound` | Yorozu → plugin | A user message, with `attachments` (`{ name, mime, data }`, base64) when it has any and `text` empty when it is only attachments (`media-v1`). Each is saved to OpenClaw's media store and passed as one media fact, in order. Acked once OpenClaw has dispatched it; resent on every connect until then. |
| `deliver` | plugin → Yorozu | An OpenClaw reply. An unknown thread id opens a new thread. |
| `ack` / `error` | both | Receipt by id. |
| `hello` | plugin → Yorozu | First frame on every connection: `{ capabilities: ["run-boundary-v1", "progress-v1", "model-select-v1", "media-v1", "reply-stream-v1"] }`. |
| `run_started` / `run_finished` | plugin → Yorozu | `run-boundary-v1`: one run per `inbound`, from OpenClaw starting on it to its end (`completed`, `failed` or `aborted`), however many replies or none. Runs are serialized per thread, and an unfinished run is re-announced after a reconnect. |
| `abort` | Yorozu → plugin | Cancels exactly that run's OpenClaw turn; the real outcome comes back in `run_finished`. |
| `tool_started` / `tool_finished` | plugin → Yorozu | `progress-v1`: the tool calls of the running message, from OpenClaw's `before_tool_call` / `after_tool_call` hooks for `yorozu` requesters only. The hooks only observe; frames are best effort and not acked. |
| `model_catalog_request` / `model_selection_request` / `model_select` | Yorozu → plugin | `model-select-v1`. Answered with `model_catalog`, `model_selection` and `model_select_result`; every request gets a reply. |

### Reply streaming

New hosts send `hello` with `reply-stream-v1`. Only after this negotiation does the plugin use
OpenClaw's official `onPartialReply` / `onAssistantMessageStart` callbacks and
`disableBlockStreaming: true`. Older hosts retain ordinary individual text deliveries.

A `reply_preview` carries `{ id, messageId, threadId, text }`: a complete Markdown snapshot,
with one stable identity per inbound run. New assistant segments accumulate in source order;
rapid updates coalesce to one pending snapshot per 100 ms. The host keeps the first snapshot's
timestamp and broadcasts previews without logging or push notifications. Tool events keep their
own chronological records.

SDK `tool`/`block` deliveries go out immediately: an interactive prompt can await its answer
before dispatch ends. These auxiliary messages do not seal the live answer draft or end the turn.
After dispatch settles, authoritative SDK `final` text payloads join in order with blank lines into
one native answer when they fit the relay frame. Larger answers split into ordered messages at
Unicode boundaries, preserving every character; subsequent IDs derive from the first. Each
negotiated message is bounded to 256 KiB of JSON-encoded text so encryption/base64 overhead
stays below the relay's 1 MiB frame limit. Oversized previews stop updating until final delivery;
finals are never truncated. Markdown syntax spanning a large-message split renders separately
on either side because the current relay has no whole-message chunk protocol. Its `deliver` uses the preview's `id` and triggering `messageId`, plus optional
`failed` / `interrupted` flags. Repeated identical text payloads are preserved. Final delivery
retries with the same identity until acked; reconnect re-announces the run before retrying.
The transcript logs each final part once. `run_finished` remains the turn-completion authority.
The host persists the triggering message as `MessageData.replyTo`, so terminal replay after
restart recognizes an already durable answer, including failed replies whose receipt was lost.
Duplicate unfinished inbound messages remain unacked, keeping the host's durable outbox and run
association across restart. Completed run boundaries remain replayable for the Gateway lifetime:
a successful socket write alone does not prove the host received its terminal state.
A successful suppressed reply clears the draft with an empty final; failures/cancellation keep
accepted SDK final text when present, otherwise unfinished preview text. Successfully suppressed
SDK blocks are never promoted from a draft. Timers and callbacks seal at dispatch completion.

Preview callback contract inspected against installed OpenClaw `2026.9.6`. This extension still
requires SDK `2026.9.1` or newer; optional callbacks/options are consumed by supported SDKs.
Outbound media delivery remains outside this text-only adapter. Inbound attachments are unchanged.
In-flight delivery retries survive socket reconnect within the Gateway process, not a Gateway
process crash; acknowledged finals are durable in Yorozu's thread log.
Transient draft timestamps/revisions survive device reconnect, but reset after host process
restart. The same stable final ID seals the previous draft; phones recover durable finals by sync.

### Model selection

The plugin announces `model-select-v1`, so Yorozu shows a per-thread model picker, including on a
draft before its first message. It uses the OpenClaw plugin SDK:

- Catalog: `buildPreparedModelsProviderData` for the thread's agent, in OpenClaw's order.
- Current model: the thread's session `providerOverride`/`modelOverride`, or none (default).
- Change: `applySessionModelSelection` on that thread's session only; `null` clears the override.
  Agent and global defaults never change. A draft's selection creates its session entry, and the
  first message resolves the same route and session key, so the first run uses the chosen model.

Limitation: only models the agent may use are listed. The SDK's plugin-facing catalog omits the
others, so Yorozu cannot show an unavailable model with its reason. The full catalog with reasons
(`models.list`) is reachable only through `api.runtime.gateway.request`, which OpenClaw 2026.9.1
limits to bundled or trusted official plugins.

Text only for now. The Yorozu side lives in
[`packages/runtime/src/channel.ts`](https://github.com/izyuumi/yorozu/blob/main/packages/runtime/src/channel.ts).

## Develop

```sh
npm test
```

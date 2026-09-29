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
| `inbound` | Yorozu → plugin | A user message. Acked once OpenClaw has dispatched it; resent on every connect until then. |
| `deliver` | plugin → Yorozu | An OpenClaw reply. An unknown thread id opens a new thread. |
| `ack` / `error` | both | Receipt by id. |
| `hello` | plugin → Yorozu | First frame on every connection: `{ capabilities: ["run-boundary-v1", "model-select-v1"] }`. |
| `run_started` / `run_finished` | plugin → Yorozu | `run-boundary-v1`: one run per `inbound`, from OpenClaw starting on it to its end (`completed`, `failed` or `aborted`), however many replies or none. Runs are serialized per thread, and an unfinished run is re-announced after a reconnect. |
| `abort` | Yorozu → plugin | Cancels exactly that run's OpenClaw turn; the real outcome comes back in `run_finished`. |
| `model_catalog_request` / `model_selection_request` / `model_select` | Yorozu → plugin | `model-select-v1`. Answered with `model_catalog`, `model_selection` and `model_select_result`; every request gets a reply. |

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

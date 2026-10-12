# Spike results for continuous chat v0.1

Status: results, 2026-10-12. Answers the spikes listed in
[v0.1](continuous-chat-memory-v0.1.md#next-step-spikes). No product code changed.

## Setup

- An isolated OpenClaw profile (`openclaw --profile yorozu-spike`, port 19089) running the
  `~/openclaw` source build. The live Gateway was not touched.
- A minimal channel plugin, plus a fake channel socket standing in for Yorozu's `channel.sock`.
- A local OpenAI-compatible mock model that logs every prompt it receives. This makes the
  history and leakage checks exact, but no real model was used.
- Synthetic data only.

Line references are to `~/openclaw/src` at commit `245b7f6fb2a`.

## Spike 1: detached runs from the plugin

**Verdict: works.** Yorozu can own context.

| Question | Result |
| --- | --- |
| Callable from socket callbacks? | Yes. Calls succeeded from a timer armed at registration and from a socket `'data'` handler, including 3 runs in parallel. `api.runtime.agent.runEmbeddedAgent` re-enters the plugin's scope on every call (`plugins/registry-runtime.ts:237-264`). The "no active scope" error comes only from the raw runtime, which plugins don't import. Use the `api` captured in `registerFull`. |
| Supplied transcript drives the answer? | Yes. Runs with three different histories (`SessionManager.fromEntries`) and `extraSystemPrompt`s ran side by side, and each answered only from its own history. |
| Anything durable written? | No session rows, transcripts, compaction, or memory. Run text appears nowhere in the state directory. The only trace is content-free `audit_events` rows (run started/finished). Exception: a run that spawns a child (spike 2). |
| Streaming | `onPartialReply` gives the cumulative text, `onBlockReply` gives each finished block, and the final reply is `result.payloads[].text` plus `meta`. |

Context OpenClaw still adds on its own:

- Workspace files (AGENTS, SOUL, IDENTITY, USER, BOOTSTRAP) go into the system prompt.
  `bootstrapContextMode: "lightweight"` removes them; `promptMode: "minimal"` does not.
- A `Runtime: … session=<key>` line is prepended to the first user message.
- History messages get timestamp prefixes.
- About 40 deferred tools (including `sessions_spawn` and `message`) stay reachable through
  `tool_call`.

Gotcha: do not pass `sessionFile`. It fails the session ownership check
(`plugins/registry-runtime-session-ownership.ts:441-448`).

## Spike 2: delegated-result routing

**Verdict: works with hooks. The default behavior loses the result.**

By default the child runs normally, but on completion OpenClaw starts an extra "announce" turn on
the throwaway run key. That turn creates a stored session, has none of Yorozu's context, and is
delivered nowhere.

| Option | Result |
| --- | --- |
| Route the run | Pass `messageChannel`, `messageTo: "<channel>:<thread>"`, `agentAccountId`, and `messageThreadId: <originating message id>` (`agents/subagent-spawn-child-plan.ts:67-74`). The completion reaches the channel's `outbound.sendText` with `threadId` set to the message id, so it can be anchored. The announce turn and its stored session remain. |
| Hooks only (recommended) | In `before_tool_call`, rewrite the spawn to `expectsCompletionMessage: false`. Then `subagent_spawned` maps the run to its child, the child's `agent_end` carries the result text, and `subagent_ended` carries the outcome. No announce turn, and nothing is stored at the run key. Requires `plugins.entries.<plugin>.hooks.allowConversationAccess: true`. |

Notes:

- Session keys arrive lowercased in hooks, so use lowercase run keys.
- `runtime.subagent.getSessionMessages` called from inside a hook failed
  ("sessions.get completed without a response"). Take the text from `agent_end` instead.
- ACP coding agents (Claude Code, Codex) use the same routing in code
  (`agents/acp-spawn.ts:409-416, 650-671`). This is untested live.

## Recommended shape

1. Each run gets a unique lowercase key, `bootstrapContextMode: "lightweight"`, and a route plus
   `messageThreadId` as a safety net.
2. Primary path: suppress the announce turn, collect the child's result from hooks, then post it
   through a new detached run that has Yorozu's assembled context, anchored to the originating
   message.

## Still open

- Live ACP delegation with real Claude Code or Codex credentials.
- Behavior with a real model: whether it calls the `message` tool during an announce turn, and
  how it handles the timestamped history.
- Cleanup of the sessions that the routing option leaves behind.
- The Jev spike. It needs a TypeSafe API key. Also, the stock `@openclaw/typesafe` plugin accepts
  a custom `baseUrl` only for a local Kev server on loopback; the hosted Jev endpoint is fixed. A
  plugin would call it through `api.runtime.decisions.evaluate` (`decisions/types.ts:140`).

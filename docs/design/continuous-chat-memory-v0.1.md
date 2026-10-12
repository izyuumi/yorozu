# Secretary chat, rooms, and PAIOS memory: design v0.1

Status: decisions from owner review, 2026-10-12. **Design only; nothing here is implemented by
this change.** It revises [v0.0](continuous-chat-memory-v0.0.md). Where the two disagree, this
document wins; everything v0.0 says about correlation, task state, corrections, idempotency,
recovery, provenance, and trust boundaries still applies.

## What changed from v0.0

| Topic | v0.0 | v0.1 |
| --- | --- | --- |
| User-visible chats | One continuous chat, no thread management | One secretary per host plus user-created rooms |
| Stage 1 execution | Serialized execution acceptable | Asynchronous and concurrent from the start |
| Hosts | Single owning host for the MVP; federation deferred | One primary host permanently; every other device is a client |
| Storage | SQLite a candidate | SQLite selected for operational records; PAIOS Markdown for long-term memory |
| Retrieval | Scoped lexical first | Lexical plus a link graph, a decision-model pre-pass, and scheduled extraction |

## Conversations

- **Secretary.** Exactly one per host. It is the home and the inbox and cannot be deleted. Users
  change subjects freely; topics are internal metadata used only for context selection and never
  shown in the UI.
- **Rooms.** Created empty from "New chat". A room runs the same Yorozu agent with the same
  memory but its own conversation. There is no scratch or incognito mode for now.
- **No promotion.** The secretary never forks a topic into a room, automatically or manually.
- **Coding agents.** Claude Code and Codex are reached only through the Yorozu agent's delegation,
  not as thread types. Direct integrations stay in v0.0's future-removal scope.
- **Proactive messages.** Reminders, scheduled briefs, and other agent-initiated messages post to
  the secretary. A result for work requested in a room posts in that room, plus a short pointer in
  the secretary. A push notification opens the conversation the message belongs to.

Secretary and rooms share one store and one pipeline, so everything below applies to both.

## Hosts and clients

One primary host runs the store, the Yorozu runtime, and OpenClaw. Every other device (other
Macs, iPhone, iPad, Watch, the share extension) is a pure client: UI over the host protocol, with
no background runtime. The host Mac's own window is also a client over the same protocol.
Host administration (OpenClaw setup, decision-model provider, pairing) lives in a separate host
settings area, not in the chat UI.

Multi-host merging (`MultiHostModel`) is removed: a client pairs with exactly one host.

The thread list opens first on every client. A setting to choose the start screen comes later.

## Per-turn context

Yorozu owns context; OpenClaw executes. The Yorozu OpenClaw plugin calls
`api.runtime.agent.runEmbeddedAgent` per run instead of `dispatchChannelInboundTurn`, with:

- `sessionManager: SessionManager.fromEntries(...)` holding exactly the selected messages;
- `sessionPersistence: "detached"`, so OpenClaw writes no transcript, compaction, or memory flush;
- the assembled context in `extraSystemPrompt`;
- a unique run session key, and reply delivery built by the plugin.

Each turn runs a pre-pass:

1. **Candidates, no model.** Recent turns, active tasks, existing topics, full-text hits, and
   link-graph neighbors (see Memory) from every conversation, current conversation ranked first.
2. **Decision model chooses.** It assigns topics, resolves which task a reference like "change it
   to Friday" means, and keeps or drops candidate memories. "Unclear" or low confidence makes the
   agent ask a plain question before acting, as in v0.0.
3. Yorozu assembles the package and starts the run.

The decision model is **TypeSafe Jev** through OpenClaw's `@openclaw/typesafe` Decision Model
role. It is its own provider: a Jev-compatible base URL and an API key, separate from the chat
model's Claude or Codex credentials. Without it configured, step 2 is skipped and the candidate
recipe alone builds the context; a local decision model may be added later.

## Concurrency

Everything is asynchronous. The agent acknowledges a request immediately ("Started on the bug
fix") and posts the result later, anchored to the originating message, while the user keeps
talking. A delegated Claude Code or Codex result must route back to Yorozu even though the
parent run was detached.

A message sent while a run is in progress:

- related to that run's topic or task (decided by the pre-pass) steers that run, as a correction;
- unrelated starts a new parallel run.

Without a decision model, every message starts a parallel run. Parallel runs are capped by a
config value, initially about 3.

## Storage

SQLite on the host (`node:sqlite`) holds messages, `reply_to`, topic tags, tasks and attempts,
the inbox/outbox, and extraction change logs. Existing `threads/<id>.jsonl` threads are imported
once as rooms; the Yorozu record becomes the source of truth and OpenClaw-side session history is
dropped. Threads bound directly to `claude-code` or `codex` import as read-only rooms.

## Memory

Long-term memory is **PAIOS**: Markdown files in the vault are the truth, readable and editable
in Obsidian. SQLite holds only a derived index, rebuilt from the files when missing or stale (the
pattern in the dormant `packages/runtime/src/memory.ts`).

- **Writes during chat.** The agent saves facts through a `remember`-style tool into PAIOS files,
  with provenance (source message, time) and `[[wikilinks]]` to the entities involved.
- **Index.** FTS5 over the files plus an edge table parsed from `[[wikilinks]]` and frontmatter.
  Retrieval expands search hits by one hop, so "mom gift" reaches `[[Mom]]` and what that note
  says, with no model involved in indexing.
- **Scheduled extraction.** On a user-chosen schedule (daily, weekly, …), a detached run on the
  main chat model reads recent chats and notes, extracts entities and relations in the style of
  graphify, and writes them straight into the PAIOS files with provenance markers. Each run's
  changes are logged in SQLite so a run can be inspected. The vault need not be a git repository.

All conversations can retrieve from all memory and history.

## Next step: spikes

Only these are committed. The rest of the plan is decided after their results.

| Spike | Question to answer |
| --- | --- |
| Detached runs from the plugin | Does `runEmbeddedAgent` work from Yorozu's socket callbacks? It throws unless a plugin runtime scope is active. Does a supplied transcript run with no hidden session history? |
| Delegated-result routing | When a detached run spawns a Claude Code or Codex child, how does the child's completion reach Yorozu instead of an unread run session key? |
| Jev | Can the plugin call the Decision Model role through `@openclaw/typesafe` with a configured base URL and key, within an acceptable per-turn latency? |

Use synthetic data only, as v0.0 requires.

> Preserved Python-prototype implementation evidence. A newer approved Swift-native implementation landed during this work and is now canonical; see [NATIVE_R1.md](NATIVE_R1.md). This document and its Python probe do not establish native-app or live-harness acceptance.

# Worker-directed memory-file editing — bounded delivery

Implements the 2026-10-07 17:16 decision that workers may edit memory files. This is not an exclusive app/extractor-managed writer: a worker selects a relative file path and complete Markdown content, and its valid operation executes immediately without a suggestion queue.

## Implemented capability

- `memory.search`: global selective discovery, topic only a ranking hint.
- `memory.read`: exact canonical Markdown and SHA-256 version.
- `memory.write`: create with explicit null precondition, or replace with the exact prior SHA-256. Worker-supplied Markdown body is written directly; protected ID/audit/attribution fields are validated and previous correction lineage retained.
- Immediate derived summary/path index refresh; Markdown remains the sole truth. If the file is saved but indexing fails, the receipt explicitly says saved/indexed=false rather than implying no write happened.
- Only the bound project's memory directory and derived index are writable through this capability. No generic shell, SQL, other filesystem root, directory management or delete API is exposed. The existing owner Forget action remains separate.

## Boundary / consistency evidence

Path handling uses a held directory descriptor and no-follow opens for every parent and final component. Absolute/traversal/backslash/control paths, symlinks and multiply-linked files are refused. Unicode subdirectories are supported. New files require a valid UUID filename matching their metadata and an existing parent directory.

All cooperating app and tool writers use one small reentrant POSIX directory lock. A complete-file hash is checked under that lock and again before replacement. Writes use an exclusive same-directory temporary file, fsync and atomic rename, with cleanup on failure. Two independent process writers starting from the same version have one winner; the other receives an explicit conflict. No force-write option exists. The model must reread and reconcile.

Automatic extraction snapshots now include the actual source file hash. A delayed extractor proposal cannot overwrite a worker edit made while the model was thinking. This closes the app-writer/worker-writer lost-update race without adding a coordination service.

Worker services attach operational conversation state using SQLite `mode=ro`; it is available only for provenance checks. Tests confirm that even an accidental internal UPDATE through this worker store is rejected. Original chat rows remain unchanged by file creation/editing/indexing. Existing history-preserving Forget/no-replay tests still pass.

Known credential-shaped values are refused/withheld at worker-facing search/read/write and automatic memory-input boundaries. This is pattern-based, not exhaustive. Personal attribution needs a real supporting user quote; quoted/generated/tentative claims cannot simply acquire a verified or personal-fact label. Ordinary token-budget knowledge is not treated as a credential. These are conservative provenance checks, not formal semantic entailment.

## What is—and is not—exposed to the harness

The configured Gateway adapter now binds `MemoryTools` and supplies an explicit application-mediated tool contract in the worker input. A returned `memory_call` is dispatched to the real scoped service; its real result is then supplied in the **same existing Gateway worker session**, not a replacement task/session. Inputs/receipts are recorded for inspection. Up to six memory operations are allowed per invocation; initial input is bounded separately from <=26 KB tool-result inputs. No full history resend or custom compaction was added.

This is **not native Tool Search/MCP registration**. Public inspection found `chat.send.toolBindings` documented as opaque plugin bindings and session overrides as toggles for existing tool surfaces; no arbitrary registrar was assumed or invoked. Native Gateway tool permissions remain read-only. The owner-authorized memory broker is a separate, explicit narrow application capability, not a broad native filesystem grant or an attempt to bypass a rejected native write.

Tests drive the actual adapter/tool loop with a **mocked RPC transport** while executing real disk writes, readback and index updates. They verify model-visible contract supply, real receipts, same-session continuity, refusal when no capability is bound, and no raw Markdown tool arguments in the progress stream. These tests are stronger than a standalone CLI smoke, but **do not prove live model/harness access**.

The explicit Gateway agent-exec attribution prohibition is unchanged and was not bypassed. No live Gateway/session invocation was attempted during this delivery. A fresh ordinary-owner-terminal probe is prepared:

```sh
python3 probe_gateway.py --memory
```

It binds the real worker tool protocol to an isolated synthetic `.data/probes/<id>/memory` directory, never production memory. It verifies actual worker-requested write/read receipts plus canonical file content and derived discovery. It requires no credential copying or global configuration change. Only `--help` was run here, not the live probe.

## Remaining limits / gates

- Live worker use of this application-mediated capability still needs that authorized operator-terminal verification; native Tool Search registration is not claimed.
- Native sessions can be idle between application-mediated tool rounds. Strict live steering may be refused in that interval; existing pending-amendment/stale-result safeguards remain, without falsely claiming delivery.
- Advisory locking coordinates app/tool clients, not arbitrary external editors that ignore locks. Hash rechecks catch stale versions but are not a sandbox against a hostile same-user filesystem actor.
- Canonical format, size, credential and provenance checks can refuse malformed, oversized or conservatively flagged notes. Read/create/replace is implemented; arbitrary rename/mkdir/delete is not.
- Other newly recorded topic-navigation/persistent-topic-session decisions are not silently claimed complete by this memory-file change.

## Tests actually run

`python3 -m unittest discover -s tests -q` → **60 tests passed**. Coverage added in this delivery includes real file create/read/edit, full hash receipts, stale write/create conflicts, two-process contention, atomic failure cleanup, root/intermediate/file symlink and hardlink refusal, Unicode folders, read-only history enforcement, cache-refresh failure reporting, attribution/credential guards, stale extractor protection and a real-filesystem/mock-transport same-session worker roundtrip. Python compilation and JS syntax checks are rerun before delivery. No publishing/global Gateway change.

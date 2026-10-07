> Historical Python-prototype record. Current approved Swift-native architecture and consolidated evidence: [NATIVE_R1.md](NATIVE_R1.md). Preserve the evidence below; it is not the final app runtime.

# Worker memory file tools

Workers may directly choose a memory file and its Markdown contents. Valid writes execute immediately through a scoped capability—**not a suggestion queue or an exclusive extractor-managed writer**. The host enforces the directory boundary, version precondition, protected identity/provenance and index refresh.

## Exact contract

Standalone JSON-lines interface (fixed project data root, not caller-selected):

```sh
python3 memory_tool.py
```

One JSON request per line, <=24 KB. Available operations:

```json
{"tool":"memory.search","arguments":{"query":"spacing","topic_id":"optional-ranking-hint"}}
{"tool":"memory.read","arguments":{"path":"folder/memory-uuid.md"}}
{"tool":"memory.write","arguments":{"path":"folder/memory-uuid.md","markdown":"COMPLETE CANONICAL MARKDOWN","expected_sha256":"SHA256_FROM_READ"}}
```

`expected_sha256` is mandatory. Use explicit `null` **only to create an absent file**; it never means overwrite blindly. Parents must already exist; no mkdir/rename/delete/shell/SQL/generic filesystem operation is exposed. Owner Forget remains a separate memory-only action.

Read returns `path`, `sha256` and exact `markdown`. Write returns the actual saved hash, `changed`, and `indexed`. Conflict returns `ok:false,error_code:conflict`; reread and reconcile, never force. A successful canonical write followed by failed cache refresh returns `ok:true,changed:true,indexed:false` with an explicit rebuild warning—do not replay the write as if it failed.

Creation example (use a fresh UUID matching the filename):

```markdown
{"id":"11111111-1111-4111-8111-111111111111","title":"Study synthesis"}

Spaced practice and recall form a useful study plan.
```

The worker controls the entire body, including Markdown formatting. Canonical metadata is validated/normalized: stable filename/ID, timestamps, last_editor=worker, previous correction lineage and current attribution are protected. New authored notes default to assistant/generated_analysis/unverified. Personal claims require actual user-message provenance and an exact supporting quote; model edits cannot invent a verified status or turn known quoted/tentative material into an asserted user belief. These checks are not formal semantic entailment.

Markdown <=12 KB total, body <=8 KB, including preserved lineage. No arbitrary binary files. Relative paths only; Unicode subdirectories work. Absolute/traversal/backslash/control paths, root/intermediate/file symlinks and multiply-linked files are refused. Existing parents are opened relative to a held directory descriptor with no-follow flags. Replacement is same-directory temp + file fsync + atomic rename. App and tool writers share one small POSIX directory lock; full-file SHA-256 preconditions detect stale versions across processes. Delayed extractor proposals also carry a source-file hash and cannot silently overwrite intervening worker edits.

Worker operations attach operational conversation state **read-only** for provenance checks. Only canonical memory files and the derived index are writable through this capability. Original chat rows cannot be updated even by an accidental internal SQL write through the worker store.

## Global discovery, Markdown truth

Memory is independent of conversation topics. Topic IDs only rank/tie-break relevance; they never filter retrieval. Search ranks title/summary metadata, reads selected canonical Markdown paths, and returns at most eight notes / 10 KB. Query max 200 characters. Actual body/attribution comes from Markdown, not cached authoritative DB text. The index remains summary/path discovery metadata; no vectors or watcher.

Retrieval includes knowledge_type, attribution, epistemic_status, origin_role, source_kind, source IDs and current SHA-256. Stored is not verified. Known credential-shaped content is withheld from worker search/read/write and automatic model memory context; this is conservative pattern checking, not exhaustive secret detection. A secret already present through an external edit is not silently erased from canonical files or chat.

## Honest harness exposure

`GatewayWorkerAdapter` now supplies an explicit **application-mediated tool protocol** when the app binds `MemoryTools`. The worker may return:

```json
{"memory_call":{"tool":"memory.read","arguments":{"path":"memory-uuid.md"}}}
```

The adapter executes that real scoped operation and supplies its real result in the **same existing Gateway worker session**. At most six memory operations per invocation; individual tool-result inputs are capped at 26 KB. Initial context remains bounded separately. All supplied inputs and tool receipts are inspectable; progress exposes names/status only, not raw file arguments. Native Gateway tools remain read-only; no broader filesystem/shell grant or global config change is made.

This is **not native OpenClaw Tool Search/MCP registration**. Public `toolBindings` is an opaque plugin-binding surface, not a documented arbitrary local-tool registrar; no such registration was assumed. Actual live worker use is still unverified because this coding run's Gateway exec-attribution prohibition is controlling. Tests execute real file operations through the adapter with a mocked RPC transport; they are not live-model proof.

An owner-terminal probe is prepared, not run by this child:

```sh
python3 probe_gateway.py --memory
```

It binds tools to a fresh isolated synthetic directory under `.data/probes/`, asks the real worker to write/read a note, and independently verifies the file, index and operation receipts. It never uses production memory for the probe. See WORKER_MEMORY_WRITES.md for evidence and remaining gates.

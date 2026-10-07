> Latest bounded worker-file evidence: 60 tests pass. See [WORKER_MEMORY_WRITES.md](WORKER_MEMORY_WRITES.md); standalone live integration remains unverified.

> Historical Python-prototype record. Current approved Swift-native architecture and consolidated evidence: [NATIVE_R1.md](NATIVE_R1.md). Preserve the evidence below; it is not the final app runtime.

> Historical first-pass report. Its configured-auth inference was corrected: native configured Astra/Sol probes succeeded. Current evidence and remaining attribution gate: [GATEWAY_REVIEW.md](GATEWAY_REVIEW.md). Current suite: 42 tests; see [TOPIC_KNOWLEDGE.md](TOPIC_KNOWLEDGE.md) for the later bounded memory review.

# Test and integration evidence — 2026-10-07

## Automated checks actually run

`python3 -m unittest discover -s tests -v` → **15 tests passed**, final run 0.163 seconds.

Coverage:
- SQLite restart/persistence; unchanged message originals; linked exchange routing correction.
- Topic-isolated worker history/memory; 12,000-byte context budget.
- Explicit Markdown memory, rebuild, path/symlink safety, atomic index retention on invalid source.
- Automatic literal memory provenance, stable-ID correction lineage, restart, separate index file, direct Markdown edit retrieval and explicit reindex.
- Tentative/obvious-secret/assistant claims not promoted by automatic extractor.
- Invalid OpenClaw envelope, nonzero exit, empty text and malformed JSON errors; no offline fake assistant reply.
- Validated secretary → worker pipeline with test doubles.
- New conversational reply and another worker result while the first worker remains blocked; out-of-order result attribution; worker failure does not block main conversation.
- Follow-up steering retains same task, no duplicate worker dispatch, amendment marked pending, old result stale and not emitted as current answer.
- Browser Origin/Host guard.

`python3 -m py_compile core.py adapter.py orchestrator.py server.py memory_tool.py` → passed.

`node --check web/app.js` → passed (Node is not needed to run app).

Actual local server smoke, then stopped:
- `GET http://127.0.0.1:8765/` → 200.
- Cross-origin JSON `POST /api/send` with Origin `http://evil.test` → 403.
- `GET /api/state` → empty persistent state and explicit offline secretary/worker label.

No visual browser/screenshot test performed. Unit orchestration/steering tests are synthetic doubles, **not successful live model tests**.

## Supported OpenClaw interface investigated

Installed `openclaw --help`, `openclaw agent --help`, `openclaw agent exec --help`; public installed documentation `/Users/yumi/openclaw/docs/cli/agent.md` and public configuration/runtime schema source. CLI version shown: 2026.9.6 (c1fb7e8).

Documented real interface used:

```text
openclaw agent exec --config <credential-free-project-config> \
  --cwd <fresh-project-local-temp-dir> --model <provider/model> \
  --timeout 80 --json --message-file -
```

JSON envelope requires exit 0, `ok: true`, `status: ok` and nonempty `final`. Errors never produce a fabricated assistant response. Child process groups are killed at app timeout. Pinned config disables tools/plugins; the adapter generates exact per-model built-in `openclaw` runtime selection.

## Synthetic integration probes actually attempted

Only project-owned synthetic prompts; no existing private session selected, no credentials copied, no Gateway setting edited.

1. Isolated `--auth-env-only` run, model `openai/gpt-6-astra`, 20-second agent deadline, asking only for `PROJECTX_PROBE_OK`: **failed 401 missing authentication**. CLI also reported uncertain runtime cleanup/temporary-state retention. No retry using private-session credentials; no outside-project cleanup performed.
2. Initial pinned config using retired `agents.defaults.agentRuntime`: **rejected by schema**. Corrected using supported per-model runtime configuration.
3. Corrected pinned config, same synthetic model/prompt/deadline: **failed Unknown model: openai/gpt-6-astra**. CLI emitted plugin-discovery warnings despite pinning/disabling plugins; no private configuration read to investigate. CLI returned an error envelope and exit 1.

Consequently: **no successful real secretary or worker turn, no verified small-model selection, no usable-live-chat claim**. Default run is visibly offline. Live auth/model setup must be resolved with owner-authorized settings, then a synthetic two-model roundtrip verified before calling this live usable.

One-shot `agent exec` public interface exposes no in-flight steering method. Same-task amendment persistence is implemented, but applying an amendment to a running real model is **not**. Do not mistake accepted/pending for applied.

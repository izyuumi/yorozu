# The legacy runtime

`packages/runtime` carries a complete in-house agent loop — providers, tools, memory, scheduling
and an approval engine — that **a shipped Yorozu never runs**. It predates the move to the
OpenClaw Gateway. It is still built, still tested, and still the backend the end-to-end harness
drives, which is why it has not been deleted.

This page exists so that nobody reads that code, or its tests, as a description of what the app
does.

## How it activates

`packages/runtime/src/legacy.ts` is loaded by a *dynamic* import guarded on `ServeOptions.provider`
being set. Two things set it:

```sh
node dist/serve.js --direct-provider   # builds a chain from YOROZU_MODEL_CHAIN
```

or an embedding caller passing `serve({ provider })` — which in this repo means
`apps/ios/e2e/run.sh`, pointing the runtime at a fake OpenAI-compatible provider.

The Mac app spawns `node .../serve.js` with no argument, so the branch is never taken. `serve.ts`
imports `index.ts` (the loop, `runAgent`, `defaultTools`) as a **type-only** import, which
TypeScript erases — on a normal launch that module is not even loaded.

## What is dormant

Everything below is reachable only through the legacy path or through a `serve.js` subcommand with
no remaining caller:

| Subsystem | Files |
| --- | --- |
| Provider adapters and the fallback chain | `claude.ts`, `codex.ts`, `providers.ts`, `chain.ts`, `probe.ts`, `mcp-bridge.ts` |
| PAIOS memory indexing and the `remember` tool | `memory.ts` (except `stateDir()`, which is live) |
| Scheduler, cron and the `schedule` tools | `scheduler.ts`, `cron.ts` |
| Agent markdown files, delegation, skills | `agents.ts`, `delegate.ts`, `skills.ts`, `agents/*.md` |
| Native tools as *runtime tools* | `tools/native.ts`, `shell.ts`, `fs.ts`, `apple.ts` |
| Browser over CDP | `tools/browser.ts` |
| `fetch` and `web_search` | `tools/fetch.ts`, `tools/search.ts` |
| Model catalog and auto-assign | `catalog.ts`, `assign.ts`, `catalog/models.json` |
| Rolling thread summaries | `summary.ts` |
| The approval gate, task grants, rule proposals | `checkApproval`/`verifyApproved` in `index.ts` |
| `ask_user` / `report_progress` tools | `tools/cards.ts` |

The environment variables `YOROZU_MODEL_CHAIN`, `YOROZU_BASE_URL`, `YOROZU_API_KEY`,
`YOROZU_MODEL`, `YOROZU_PAIOS_DIR`, `YOROZU_MEMORY_DIR`, `YOROZU_BROWSER`, `YOROZU_NATIVE_CMD` and
`YOROZU_CATALOG_URL` are read only from these files. None of them affect a shipped launch. (The
Mac app sets `YOROZU_NATIVE_CMD` and uses the `yorozu-native` helper directly from Swift for its
permission checks — the helper is live, the runtime's tool wrappers around it are not.)

`.github/workflows/catalog.yml` still publishes `catalog/models.json` to a rolling `catalog`
release on every push that touches it. That feed only has a consumer inside this dormant code.

## Two things that look live and are not

**Approval rules.** `approval.ts` implements the full engine described in the spec: a floor that
no rule can reach, structured action scopes, rules with `always`/`never` precedence, batches,
`lastUsed`/`useCount`, and rule proposals after repeated approvals. The wire protocol carries
`rule_list`, `rule_update` and `rule_delete`, the runtime serves them, and `RuleEditorView` exists
in `packages/shared-swift`. But the engine is only consulted by `checkApproval` inside the legacy
loop, and neither app currently links to the editor. **Rules can be stored and are never
enforced.** The `yolo` setting *is* live — it is passed to native coding agents as a bypass.

What does raise real approval and question cards on a shipped build is `native-cards.ts`,
translating a `claude-code` or `codex` SDK prompt. That path has no rules, floors or task grants
by design; the SDK is asking, and the card is how the question reaches a phone.

**Agent markdown files.** `packages/runtime/agents/` holds six prompts (`main`, `general`,
`calendar`, `email`, `browser`, `reservation`). They are installed into the state directory only
by `legacy.ts`, so a normal launch neither copies nor reads them. Agent definitions for `yorozu`
threads belong to OpenClaw.

## Removing it

The loop is self-contained behind `legacy.ts` and the `--direct-provider` flag. Deleting it would
mean replacing the end-to-end harness's fake backend with something that speaks the Gateway
protocol, and dropping the `probe`, `models`, `assign`, `assign-revert` and `assign-cron`
subcommands along with `catalog.yml`. Until then, treat anything on the table above as historical.

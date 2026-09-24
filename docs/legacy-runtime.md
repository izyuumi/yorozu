# The legacy runtime

`packages/runtime` carries a complete in-house agent loop — tools, memory, scheduling
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

## Provider code that remains live

Normal `serve.js` launches pass `chainFromEnv()` as the automatic thread titler. `title.ts`
uses that provider to name new conversations, with a first-words fallback if it fails or times
out. `chain.ts`, `providers.ts`, `provider.ts`, `claude.ts`, `codex.ts`, and the automatic
`probe.ts` discovery path therefore remain production dependencies even though the old agent
loop is dormant.

`YOROZU_MODEL_CHAIN`, `YOROZU_BASE_URL`, `YOROZU_API_KEY`, and `YOROZU_MODEL` can affect title
generation. They do not replace OpenClaw or the native coding-agent backends for chat replies.

## What is dormant

Everything below is reachable only through the legacy path or through a `serve.js` subcommand with
no remaining caller:

| Subsystem | Files |
| --- | --- |
| Legacy MCP tool bridge | `mcp-bridge.ts` |
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

`YOROZU_PAIOS_DIR`, `YOROZU_MEMORY_DIR`, `YOROZU_BROWSER`, and `YOROZU_CATALOG_URL` configure
these legacy features. The Mac app also sets `YOROZU_NATIVE_CMD` and uses the `yorozu-native`
helper directly from Swift for permission checks: the helper is live, while the runtime's
legacy tool wrappers around it are not.

The legacy catalog reads `catalog/models.json` directly from the repository's `main` branch,
with cached and bundled copies as offline fallbacks. Releases no longer carry this catalog,
and there is no catalog-publishing workflow. Shipped model pickers instead use OpenClaw's
`models.list`, Claude SDK's `supportedModels()`, and Codex's paginated `model/list`.

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
subcommands. Preserve the provider chain used by automatic thread
titles, or migrate titling first. Until then, treat the dormant subsystems above as historical.

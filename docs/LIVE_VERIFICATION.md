> **20:00 superseding update:** owner launched Live-R1; greeting failed. Source-confirmed CLI model-override defect repaired; 45 tests pass; separate `PROJECTX-Live-R1-transport-fix.app` staged. Waiting coordinated patched-app test, not initial owner launch. See [transport repair](LIVE_TRANSPORT_REPAIR.md). Prior evidence below retained.

# R1 live-connection repair — final worker receipt

Parent correction, 2026-10-07 19:54 JST: **Owner independently launched at 19:53; actual native greeting failed with Gateway refused/disconnected.** See `LIVE_UI_TEST.md`. The worker's waiting-for-launch handoff below was overtaken by direct UI evidence. Same-worker transport repair requested; no success claim. Parent owns desktop and Obsidian note; history preserved.

## Earlier worker launch handoff (superseded by owner launch and failed UI test)

Owner independently opens **`/Users/yumi/Projects/PROJECTX/build/PROJECTX-Live-R1.app`** from Finder in the normal owner environment. No provider login, token copying, terminal command, environment-marker removal, or global policy change is requested. Default mode selects the live configured-credential CLI adapter and only the dedicated `projectx` agent. The banner says acceptance is unverified; it is not a connection receipt.

The current agent-exec attribution restriction remains enforced. Neither this worker nor parent should launch a new process through shell/desktop as a workaround. After the legitimate owner launch, parent identifies the new native window and tests: natural greeting, substantive knowledge request, follow-up/reuse of the same topic, and inspect-only progress. Preserve the old synthetic window separately. No app UI roundtrip has been observed yet.

## Implemented

- Live default and explicit rejection of personal-agent backend selection; app-owned topic sessions now use `agent:projectx:projectx:<UUID>`. Existing private sessions are not imported or read. Finder PATH includes ordinary Homebrew executable locations without changing attribution/auth homes.
- Secretary has an explicit model-facing camelCase JSON decision contract outside the encoded context, greeting example behavior, required fields/action semantics, topic reuse and active-task steering instructions. Existing engine validation remains authoritative. Earlier input already contained a policy field; this strengthens actual model delivery rather than claiming there was no policy whatsoever.
- Correct installed-protocol parsing: committed history IDs from `__openclaw.id`; a nonvisible authoritative terminal reply cannot leak an earlier payload; `agent.wait` reads its actual top-level `terminalReply`, with exact owned run ID, terminal timestamp, visible disposition and validated worker output. It no longer expects the different `agent` result envelope.
- Optional direct Swift `URLSessionWebSocketTask` transport (`PROJECTX_TRANSPORT=native`): protocol-4 nonce challenge, timestamp validation, v3 Ed25519 signed device proof, dedicated generated identity and app-issued token in Keychain, negotiated role/grants/methods/frame limits, multiplexed response IDs, accepted-versus-final handling, bounded request deadlines, cancellation/disconnect uncertainty, connection event sequencing, public exact-run lifecycle/tool-name projection, and no automatic mutation replay. Committed-message polling remains the backfill path. No native credential/network access was exercised by this restricted worker.
- Native enrollment UI uses a SecureField; no token is read from OpenClaw config/device files or persisted in project/vault logs. Only the independently generated app key and issued app device token are Keychain records. No node role/admin/pairing scope is requested.

## Real model evidence (not app transport proof)

Both probes used the supported attributed native `sessions_spawn` tool with `agentId=projectx`, `context=isolated`, synthetic prompts, no tools/files/private sessions, and parent-only completion. Only those newly created sessions were read through native `sessions_history`.

1. **Astra secretary:** run `39771cca-f9a4-4594-86bb-50ea164305b5`, session `agent:projectx:subagent:f3abf2c7-3dde-450c-9f40-01bd08464766`. Final observed JSON: `{"action":"reply","reply":"Hello! How can I help?"}`. Actual response metadata: provider `openai-pool`, model `gpt-6-astra`, `stopReason=stop`, terminal response completed.
2. **Sol substantive worker:** run `65685e40-c734-4d0b-be2c-7c18378291c3`, session `agent:projectx:subagent:33fdb175-d7fb-4a87-90b5-70286c9fdd27`. Final valid `text`/`appliedRevision:0` JSON recommended Markdown canonical truth with a rebuildable database index, explained portability, versioned correction provenance and indexed search, identified index drift risk, and explicitly labeled the recommendation rather than a fact about an actual system. Actual metadata: `openai-pool` / `gpt-6-sol`, normal stop and completed response.

Native subagent status reported both done, no active descendants. These prove the dedicated agent's real model access and the tested JSON contracts. They do **not** establish app WS/CLI roundtrip, a formal tool-confinement audit, actual topic-session continuation, or live steering.

## Build and tests

- **44 Swift tests pass**, zero failures; final receipt `build/native-live-tests.log`, 19:18:18 JST. Prior 33-case baseline plus separate topic-binding tests preserved; new protocol, signature, target restriction, refusal sanitization, model-contract, terminal visibility, public-event filtering, metadata identity, dedicated-agent and exact-run recovery cases included.
- `build/PROJECTX-Live-R1.app` staged, not launched. Production build passed, plist lint and local ad-hoc `codesign --verify --strict` passed. Receipt `build/native-live-build.log`; executable checksum `build/native-live-sha256.txt`. Old `.app` artifacts and fixture workspace remain untouched.
- Native signature/protocol tests use generated in-memory keys and synthetic frames. Full WS lifecycle/enrollment and Keychain behavior still require legitimate device-level live validation. Passing local tests is not live app acceptance.

## Enrollment facts and steering gate

Installed public docs require a new third-party operator device to bootstrap with the Gateway's shared token/password in token mode, then obtain a scoped device token through pairing. There is no verified token-free generic app enrollment flow. Built-in setup-code flow is documented for a mobile node+bounded-operator handoff; it was not repurposed. Generic registered `webchat`/`ui` with PROJECTX display name is used, not reserved internal backend impersonation. The optional native route requires private owner bootstrap entry; if Gateway returns `PAIRING_REQUIRED`, review and approve its exact PROJECTX request, then reconnect. Existing configured-credential default avoids that extra enrollment step for the immediate owner launch.

**Active steering is not accepted as working.** Parent's isolated `projectx` agent configuration denies all native tools. That also blocks current strict `tools.invoke → sessions_send(mode=steer)` attribution through its controller session. This is a policy-derived blocker, not a newly observed live refusal in the app. Installed public `sessions.steer` forwards interrupt-mode chat and can start a turn; it is not equivalent to the strict active-only contract and was deliberately not substituted. App keeps unsupported amendments pending and suppresses obsolete completions; no false incorporation claim or duplicate worker fallback. A separately authorized narrow controller capability/product API decision remains necessary. No tool-policy/role weakening was done.

## Handoff correction

The worker's urgent readiness acknowledgment was emitted through `sessions_yield` because its direct session-send tool was unavailable, but was not surfaced promptly to the parent. That left work incorrectly appearing active. This final receipt and the single project queue row now explicitly say **waiting owner launch**; no indefinite external wait remains.

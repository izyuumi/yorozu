# Upgrade from 0.5.0-beta to 0.9

The plan for moving Yorozu 0.5.0-beta installs (`main`) to 0.9.0 (`projectx`), agreed with the owner on 2026-10-17. Decisions in force are in [OWNER_DECISIONS.md](../OWNER_DECISIONS.md#upgrade-from-050-beta); this file holds the how. Nothing here ships until the owner says so.

## Scope

- Only 0.5.0-beta installs upgrade: the owner's family. The owner confirms each migration by hand.
- The stable feed (`yorozu.yumi.to/appcast.xml`) stays frozen at 0.4.0. 0.4.0 installs are not upgraded.
- Once every family install has migrated, all migration code is deleted and 0.9 data is assumed everywhere.
- Rollback: fix forward only.

## Version and build numbers

- Version `0.9.0`, released as `v0.9.0-beta`.
- The visible build number restarts at 1 for each version and is shown as "0.9.0 (1)".
- `CFBundleVersion` on every platform is `major·10⁷ + minor·10⁵ + patch·10³ + build`, for example `900001` for 0.9.0 build 1. The live 0.5.0-beta is build `10279`.
- Why the encoding: Sparkle's default comparator compares the integer `CFBundleVersion`, and TN2420 requires macOS builds to rise across versions. Dotted forms such as `0.9.0.1` sort below `10279`, and four parts are invalid.
- In the appcast, `sparkle:version` is the same integer and `sparkle:shortVersionString` is `0.9.0`.
- Never ship a `CFBundleVersion` with a smaller leading number: every installed Mac would stop seeing updates.

## Mac distribution

- The Mac destination of the shared client target builds as `to.yumi.yorozu`, the 0.5.0-beta bundle id, so Sparkle replaces it in place. It is signed with Developer ID, team `AN5KM8QGEF`, and notarized.
- Sparkle is linked for macOS only.
  - It uses the same EdDSA public key as 0.5 (`SUPublicEDKey` `pD6gPv1C…`) and the CI secret `SPARKLE_ED_KEY`.
  - The default feed is the beta feed `yorozu.yumi.to/beta/appcast.xml`. `YorozuBetaUpdates` is still read, so an explicit choice survives the update.
- Releases: `projectx` merges into `main`. `main`'s `release.yml` and appcast step are ported to the Tuist layout. A green `main` publishes `v0.9.0-beta`, as in 0.5's `docs/RELEASE_WORKFLOW.md`. Only the release job is lifted from the no-CI rule, with no test jobs.
- The website download link points at 0.9.0.

## iOS distribution

- The first public App Store release, under `to.yumi.yorozu.ios`.
- Released manually after approval, with no phased release.
- The build lists for internal and external TestFlight testers first (see [Release order](#release-order)).
- The `testFlightInternalTestingOnly` flag is removed from `apps/ios/ExportOptions.plist`.

### App Review

Modelled on OpenClaw's iOS app (`~/openclaw/apps/ios`).

- **Main path: a live review host.**
  - The owner keeps a Mac online during review, with OpenClaw, the plugin and a dedicated review agent.
  - The review notes carry its pairing code and a scripted checklist of prompts with expected results.
  - The notes stay under 4000 bytes and live in `apps/ios/APP-REVIEW-NOTES.md`.
- **Fallback: a fixture demo behind a code.**
  - Enter `YOROZU-DEMO` in the pairing field, or scan a QR containing that exact text. Surrounding whitespace is ignored; the code is case-sensitive. There is no visible entry button.
  - The on-device demo has seeded conversations, tool rows, Automations and delayed, scripted whole replies. It runs no model and connects to no host.
  - A Demo label identifies it. Sample changes stay in memory and vanish on **Exit Demo** in Settings; existing pairings are preserved. Files, uploads and real host or account actions are unavailable.
  - Developers can launch with `--demo` to skip pairing, Keychain, networking, Mac migration and the updater. Use an isolated Mac developer bundle id ([setup](setup.md#try-demo-data-without-a-host)).
  - The code and limitations are explicitly disclosed in [review notes](../apps/ios/APP-REVIEW-NOTES.md): this mode substitutes for a demo account. It does not establish that the live review host has been configured or checked.

### Update notice

- Once a day, iOS checks `itunes.apple.com/lookup?bundleId=to.yumi.yorozu.ios`. When a newer version exists, it shows a small dismissible "Update available" row above the conversation list, linking to the App Store.
- The row is dismissed per version. Nothing is ever forced: protocol `update_required` covers the hard case.
- TestFlight builds skip the check.

## Release order

- The iOS build is uploaded and through Beta App Review but not assigned to testers. The Mac appcast item and the TestFlight assignment go live together.
- Every family device pairs again once (owner, 2026-10-23: re-pair instead of carrying 0.5's keys over). The Mac pairs itself on first launch; each iPhone and iPad then pairs from the Mac's Settings › Add a Device…, with the owner there.
  - **iOS 0.9 before the Mac:** the phone shows the pairing screen until the Mac has updated.
  - **A 0.5 iPhone against a 0.9 Mac:** shows 0.5's own "update required". That can't be changed.

## Mac first launch: migration, automatic

This runs once, guarded by a marker, and every step is idempotent. It never writes to 0.5's data folder. It is an exception, for this one migration, to the rule that assisted writes happen only after a click.

1. **Plugin swap.** 0.5 users installed the channel plugin with `openclaw plugins install --link --accept-capabilities /Applications/Yorozu.app/Contents/Resources/openclaw-channel`. Both plugins have the id `yorozu`.
   - The app bundles the full 0.9 plugin tree at that path: `index.ts`, `setup-entry.ts`, `src/**`, `openclaw.plugin.json` and `package.json`. OpenClaw runs TypeScript directly, so no `dist` or `node_modules` is needed.
   - The gateway does not watch plugin folders. Until a reload it keeps running 0.5 from memory.
2. **Config.** The app runs `openclaw config unset channels.yorozu.socketPath`. The 0.9 channel schema is closed, and this key would stop the gateway from starting.
3. **Reload.** The app runs `openclaw plugins reload yorozu --accept-capabilities` (0.9 adds `cliCommands: ["yorozu"]`), and `openclaw gateway restart --safe` if that fails or reports `restartRequired`. The CLI has the admin scope the app lacks.
4. **No keys or devices carry over.** The plugin makes new host keys, so the room is new and every device pairs again.
5. **Memory.** 0.5's memory notes (`~/Library/Application Support/Yorozu/memory`, or the `PAIOS/Workspace/Yorozu Memory` folder in `~/Documents` or `~/My vault`) are copied into the agent's workspace, `memory/yorozu-0.5/`, each ending "Imported from Yorozu 0.5, unverified." A note already there is left alone.
6. **Chats.** Every 0.5 thread with messages is converted, oldest activity first so the newest lands on top.
   - For each thread in 0.5's `threads.json`: `sessions.create` with key `agent:<agent>:yorozu:direct:owner:thread:<lowercased id>` (`channels.yorozu.agent`, default `main`; a non-UUID id such as `home` gets a UUID derived from it) and its title as `displayName`, then one `chat.inject` holding a plain assistant message: `Earlier conversation from Yorozu 0.5 (N messages):` followed by the last 40 `message` events from `threads/<id>.jsonl` as `You: …` / `Yorozu: …` paragraphs, each cut at 4000 characters. An archived thread is archived with `sessions.patch`.
   - It carries no tool calls, thinking, cards, pinned state or timestamps. Attachments appear as their names.
   - `claude-code` and `codex` threads become ordinary conversations that continue on the 0.9 agent.
   - Done thread ids are kept in user defaults, so a run cut short carries on without injecting twice. It runs apart from steps 1–3 and 7–9, so a Mac that migrated before the import existed (the owner's) imports too.
7. **Cleanup.** Remove 0.5's watchdog LaunchAgent `to.yumi.yorozu.watchdog`.
8. **Pair this Mac.** 0.5's Mac was the host, never a client. The app runs `openclaw yorozu pair` against its own Gateway and pairs with the printed link, skipping the fingerprint step: the code comes from the same Mac.
9. **Nudge.** A notification: update Yorozu on the iPhone and iPad.

All of it is `apps/ios/Sources/YorozuIOS/MacMigrateFrom0_5.swift`, through the `openclaw` CLI (`gateway call` for the session methods), which holds the admin scope the app and the plugin lack.

## iOS first launch

- Nothing is migrated: 0.9 keeps its pairing under its own Keychain account, `pairing-v3`, and shows the pairing screen. 0.5's `pairings` item is left as it is.

## Groundwork for future versions

All of this lands in 0.9.0, so later versions migrate without friction:

1. **Schema versions.** Every stored record carries one: the plugin's keyed stores, `pairing-v3`, the client cache and config. Ordered migrations `n → n+1` run at launch, each one idempotent.
2. **Protocol range.** `peer_info` carries `protocolMin`/`protocolMax` and both sides pick the highest version they share. Each side supports one version back. Outside that range: `update_required`.
3. **Additive by default.** New fields are optional, and unknown fields are ignored, not rejected. Schemas are not closed against future keys.
4. **Stable contracts.** They are listed in [OWNER_DECISIONS.md](../OWNER_DECISIONS.md#stable-contracts) and never change.
5. **Breaking jumps.** A future breaking Mac update sets Sparkle `sparkle:minimumAutoupdateVersion`, so it is never installed silently.

## Unverified, check during implementation

- **Feed reach.** 0.5.0-beta Macs read the beta feed only if beta updates were switched on (`YorozuBetaUpdates`; 0.5 defaults to the stable feed, which stays at 0.4.0). A family Mac without it never sees 0.9.0.
- 0.5's host data path is `~/Library/Application Support/Yorozu` (runtime `serve.ts`, `DEFAULT_STATE_DIR`).
- Whether `peerDependencies: openclaw` in the plugin affects OpenClaw's dependency status.

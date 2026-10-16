# Upgrade from 0.5.0-beta to 0.9.0-beta

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
  - Entering `YOROZU-DEMO` in the pairing field, or scanning it as a QR, opens it. There is no visible button.
  - It needs a `Transport` protocol seam in `V3Model`, which today holds a concrete `V3Connection`.
  - `DemoTransport` runs on the device: a demo host, seeded conversations and scripted streamed replies.
  - It stays isolated from real data: a Demo badge, real pairings hidden, nothing persisted, and Mac-only features disabled.
  - Unlike OpenClaw, the code is documented in the review notes (guideline 2.3.1). The notes also state that demo mode stands in for a demo account (guideline 2.1(a)).

### Update notice

- Once a day, iOS checks `itunes.apple.com/lookup?bundleId=to.yumi.yorozu.ios`. When a newer version exists, it shows a small dismissible "Update available" row above the conversation list, linking to the App Store.
- The row is dismissed per version. Nothing is ever forced: protocol `update_required` covers the hard case.
- TestFlight builds skip the check.

## Release order

- iOS 0.9.0 is uploaded and processed but not assigned to testers. The Mac appcast item and the TestFlight assignment go live together.
- For the gap until both sides have updated:
  - **iOS 0.9.0 before the Mac:** it finds the old 0.5 pairing, shows "Your Mac is updating to Yorozu 0.9" and keeps retrying. Because the keys and room carry over, it reconnects by itself once the Mac switches.
  - **Mac 0.9.0 before the iPhone:** the Mac's first-launch screen says "Update Yorozu on your iPhone".
  - **A 0.5 iPhone against a 0.9 Mac:** shows 0.5's own "update required". That can't be changed.

## Mac first launch: migration, automatic

This runs once, guarded by a marker, and every step is idempotent. It never writes to 0.5's data folder. It is an exception, for this one migration, to the rule that assisted writes happen only after a click.

1. **Plugin swap.** 0.5 users installed the channel plugin with `openclaw plugins install --link --accept-capabilities /Applications/Yorozu.app/Contents/Resources/openclaw-channel`. Both plugins have the id `yorozu`.
   - The app bundles the full 0.9 plugin tree at that path: `index.ts`, `setup-entry.ts`, `src/**`, `openclaw.plugin.json` and `package.json`. OpenClaw runs TypeScript directly, so no `dist` or `node_modules` is needed.
   - The gateway does not watch plugin folders. Until a reload it keeps running 0.5 from memory.
2. **Config.** The app removes `channels.yorozu.socketPath` if it is present, with `config.patch`. The 0.9 channel schema is closed, and this key would stop the gateway from starting.
3. **Reload.** The app calls `plugins.reload` for `yorozu`, then again with `acknowledgeCapabilities.reviewToken`, because 0.9 adds `cliCommands: ["yorozu"]`. It follows with `gateway.restart.request` when `restartRequired` is set. Both calls need `operator.admin`. If the app lacks that scope, it shows `openclaw plugins reload yorozu --accept-capabilities` to copy.
4. **Host keys and devices.** The plugin imports 0.5's `keys.json` (`session` and `signing` keys) into `credentials/yorozu/host-keys.json`, and `devices.json` (`pub`→`staticPub`, `signingPub`) into its allowlist. The room id stays the same (sha256 of the host Ed25519 key), and the relay already knows the devices. Devices without a `signingPub` re-pair.
5. **Memory.** 0.5's memory notes are imported as unverified notes ending "Imported from Yorozu 0.5".
6. **Chats.** All 0.5 threads are converted (273 on the owner's Mac): 169 `yorozu`, 82 `claude-code`, 24 `codex` and 1 `harness`.
   - For each thread in 0.5's `threads/threads.json`: `sessions.create` with key `agent:main:yorozu:direct:owner:thread:<lowercased id>`, then one `chat.inject` holding a plain assistant message. It reads `Earlier conversation from Yorozu 0.5 (N messages):` followed by the last 40 `message` events from `threads/<id>.jsonl` as `You: …` / `Yorozu: …` lines.
   - It carries no extra fields, tool calls, thinking or cards. Title, archived and pinned state, and timestamps carry over through `sessions.patch` where they map.
   - Attachments appear as text.
   - `claude-code` and `codex` threads become ordinary conversations that continue on the 0.9 agent.
7. **Cleanup.** Remove 0.5's watchdog LaunchAgent `to.yumi.yorozu.watchdog`.

## iOS first launch

- Copy the keychain account `pairings` (service `to.yumi.yorozu.ios`): the record whose `roomId` matches becomes `pairing-v3` with `v: 3`, `relayKnows: true` and `paired: true`. No QR scan is needed.
- Fall back to the QR flow when there is no record, no match, or the handshake fails. A phone paired with several 0.5 hosts keeps one.
- Never delete `pairings`.

## Groundwork for future versions

All of this lands in 0.9.0, so later versions migrate without friction:

1. **Schema versions.** Every stored record carries one: the plugin's keyed stores, `pairing-v3`, the client cache and config. Ordered migrations `n → n+1` run at launch, each one idempotent.
2. **Protocol range.** `peer_info` carries `protocolMin`/`protocolMax` and both sides pick the highest version they share. Each side supports one version back. Outside that range: `update_required`.
3. **Additive by default.** New fields are optional, and unknown fields are ignored, not rejected. Schemas are not closed against future keys.
4. **Stable contracts.** They are listed in [OWNER_DECISIONS.md](../OWNER_DECISIONS.md#stable-contracts) and never change.
5. **Breaking jumps.** A future breaking Mac update sets Sparkle `sparkle:minimumAutoupdateVersion`, so it is never installed silently.

## Unverified, check during implementation

- Whether the new iOS build can read 0.5's keychain item. 0.5's only access group was the notifications group, and the client has both.
- Whether Noise IK accepts carried-over device keys without `helloProof` (`relay.ts:357`).
- Whether the Mac client has `operator.admin` for `plugins.reload` and `gateway.restart.request`.
- 0.5's host data path: `~/Library/Application Support/Yorozu` (runtime `memory.ts:65`) versus `~/Library/Application Support/to.yumi.yorozu/` ([release.md](release.md#mac-client)).
- Whether `peerDependencies: openclaw` in the plugin affects OpenClaw's dependency status.

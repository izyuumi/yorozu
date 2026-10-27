# Upgrade from 0.5.0-beta

What the client does on a device that ran Yorozu 0.5.0-beta. Decisions are in
[OWNER_DECISIONS.md](../OWNER_DECISIONS.md#upgrade-from-050-beta).

## How 0.5 Macs get 0.9

- The Mac build uses 0.5's bundle id, `to.yumi.yorozu` (`PRODUCT_BUNDLE_IDENTIFIER[sdk=macosx*]`
  in `apps/ios/Project.swift`), 0.5's Sparkle EdDSA key and the feed
  `https://yorozu.yumi.to/appcast.xml`, so Sparkle replaces 0.5 in place. Sparkle is linked
  for macOS only.
- `CFBundleVersion` must stay above 0.5's `10279`; see [release.md](release.md) for the
  encoding and for which feed serves what.
- A build phase copies the plugin (`index.ts`, `setup-entry.ts`, `openclaw.plugin.json`,
  `package.json`, `README.md`, `src`) into `Yorozu.app/Contents/Resources/openclaw-channel`,
  the path 0.5's `openclaw plugins install --link` points to. The Gateway keeps running the
  old plugin from memory until it reloads.

## Mac first launch

`apps/ios/Sources/YorozuIOS/MacMigrateFrom0_5.swift`, macOS only. It starts from the main
window's task on every launch, not in demo mode, until it has succeeded; every step can run
again. Progress is kept in user defaults: `migratedFrom0_5`, `importedChatsFrom0_5`, and
`importedThreadsFrom0_5` (the 0.5 thread ids already imported). It only reads 0.5's data
folder, `~/Library/Application Support/Yorozu`.

It calls the `openclaw` CLI, which has the admin scope the app lacks, looked up in
`/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin`, `/usr/bin`, `/bin` and then `PATH`.
Without it, nothing happens and the next launch tries again.

### Migration

A Mac counts as a 0.5 install when 0.5's watchdog LaunchAgent plist exists, the
`onboardingCompleted` user default is set, or `~/Library/Application Support/Yorozu/threads`
exists. Otherwise it is marked done with no changes.

1. Remove 0.5's watchdog LaunchAgent, `to.yumi.yorozu.watchdog` (`launchctl bootout`, then
   delete its plist).
2. `openclaw config unset channels.yorozu.socketPath`: the 0.9 channel schema rejects it.
   A failure (the key is usually unset) is ignored.
3. `openclaw plugins reload yorozu --accept-capabilities --json`. If that fails or reports
   `"restartRequired": true`: `openclaw gateway restart --safe`. If the restart fails, stop
   here.
4. If this Mac is not paired: `openclaw yorozu pair`, up to 10 tries 6 seconds apart; the
   printed `yorozu://pair…` link is submitted and confirmed without the fingerprint step,
   since it comes from this Mac's own Gateway.
5. Mark done and post a notification: update Yorozu on the iPhone and iPad, then pair them
   again with Settings › Add a Device….

### Import

Runs after the migration is done and is marked separately, so a Mac migrated before the
import existed imports too. The agent is `openclaw config get channels.yorozu.agent`, or
`main` when unset.

1. Memory. Every `.md` file under `~/Library/Application Support/Yorozu/memory`,
   `~/Documents/PAIOS/Workspace/Yorozu Memory` and `~/My vault/PAIOS/Workspace/Yorozu Memory`
   is copied to `memory/yorozu-0.5/` in the agent's workspace (from
   `openclaw agents list --json`), ending "Imported from Yorozu 0.5, unverified." A file
   already there is left alone.
2. Chats. Each thread in `threads.json`, oldest log modification first so the newest ends up
   on top, through `openclaw gateway call`:
   - `sessions.create` with key `agent:<agent>:yorozu:direct:owner:thread:<id>` (a 0.5 UUID
     lowercased; any other id, such as `home`, maps to a UUID derived from it by SHA-256) and
     `displayName` the thread's title, else the first line of its first user message, else
     "Yorozu 0.5", cut to 60 characters.
   - One `chat.inject`: "Earlier conversation from Yorozu 0.5 (N messages):" followed by
     the last 40 user and agent `message` events of `threads/<id>.jsonl` as `You: …` /
     `Yorozu: …` paragraphs, each cut at 4000 characters. Attachments appear as `[name]`;
     tool calls, cards, pins and timestamps are not carried.
   - `sessions.patch` with `archived: true` for an archived thread.
   - `yorozu.conversations.time` with the thread's newest message `ts`. The plugin
     (`plugins/openclaw-yorozu/src/activity.ts`) lists the conversation by that time until a
     new message arrives.
   - A thread without user or agent messages is skipped. Each finished id is saved at once,
     so an interrupted run carries on without injecting twice.

No keys or devices carry over: the plugin has no 0.5 import, so its host keys are new and
every device pairs again.

## iPhone and iPad first launch

Nothing is migrated. 0.9 keeps its pairing in the Keychain account `pairing-v3`
(`apps/ios/Sources/Client/Store.swift`) and never reads or deletes 0.5's Keychain items. The
app opens on the pairing screen; pair it from the Mac's Settings › Add a Device….

## Owner decision pending review

Kept verbatim from the earlier version of this file until the owner reviews it against OWNER_DECISIONS.md:

> Every 0.5 device pairs again once (owner, 2026-10-23: re-pair instead of carrying 0.5's keys over). The Mac pairs itself on first launch; each iPhone and iPad then pairs from the Mac's Settings › Add a Device…, with the owner there.

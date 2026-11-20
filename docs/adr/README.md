# Architecture decision records

An ADR records one decision area: the context that forced it, what was decided and why, and what follows from it. Yorozu's code carries no comments, so the reasons behind non-obvious code (measured constants, platform and SDK behaviour, invariants, compatibility rules) live here instead. Each ADR names the files and symbols it covers under "Where in the code", without line numbers, so it survives edits. When code changes a decision, update its ADR in the same pull request; when a new decision area appears, add the next number and a row below. Product decisions stay in [OWNER_DECISIONS.md](../../OWNER_DECISIONS.md).

## Template (MADR-lite)

```
# NNNN. Title
- Status: Accepted | Superseded by NNNN | Deprecated
- Date: YYYY-MM-DD
## Context
## Decision
## Consequences
## Where in the code
```

"Decision" is a bullet list. Keep each reason, constraint, measured number and invariant; say "the owner" for the owner.

## Index

| No. | Title | Status |
|---|---|---|
| [0001](0001-wire-format-and-tolerant-readers.md) | Wire format, wire migration and tolerant readers | Accepted |
| [0002](0002-capabilities-and-feature-flags.md) | Capabilities and feature flags | Accepted |
| [0003](0003-relay-rooms-retention-and-roster.md) | Relay rooms: retention, storage migrations and device roster | Accepted |
| [0004](0004-pairing-codes-sessions-and-allowlist.md) | Pairing codes, sessions and the allowlist | Accepted |
| [0005](0005-local-mac-pairing.md) | Local Mac pairing | Accepted |
| [0006](0006-direct-path-and-connection-race.md) | Direct path and the connection race | Accepted |
| [0007](0007-local-network-explainer.md) | Local Network explainer | Accepted |
| [0008](0008-live-activity-on-device.md) | The Live Activity on the device | Accepted |
| [0009](0009-live-activity-host-pushes.md) | Live Activity pushes from the host | Accepted |
| [0010](0010-widgets-and-notification-service.md) | Widgets, the App Group snapshot and the notification service | Accepted |
| [0011](0011-sync-uploads-and-share-extension.md) | History sync, resumable uploads and the share extension | Accepted |
| [0012](0012-app-lifecycle-and-stored-names.md) | App lifecycle, status and stored-names migration | Accepted |
| [0013](0013-home-routing-and-split-panes.md) | Home routing, split panes, row actions and settings structure | Accepted |
| [0014](0014-composer-focus-caret-and-layout.md) | Composer: focus, dictation caret, keys and layout | Accepted |
| [0015](0015-chat-scroll-to-end.md) | Chat scroll-to-end | Accepted |
| [0016](0016-mac-prose-accessibility-and-zoom.md) | Mac prose rendering, accessibility workarounds and zoom | Accepted |
| [0017](0017-presentation-cards-in-the-client.md) | Read-only presentation cards in the client | Accepted |
| [0018](0018-plugin-card-pipeline-and-sanitizer.md) | Plugin card pipeline, prompt guidance and sanitizer | Accepted |
| [0019](0019-plugin-card-store-and-history.md) | Plugin card store and history | Accepted |
| [0020](0020-plugin-turns-delivery-and-targeting.md) | Plugin turns, outbound delivery, message-tool targeting and update notices | Accepted |
| [0021](0021-privacy-in-logs-diagnostics-and-previews.md) | Privacy in logs, diagnostics and push previews | Accepted |
| [0022](0022-cron-schedule-text.md) | Cron schedule text | Accepted |
| [0023](0023-voice-input-in-the-app.md) | Voice input in the app | Accepted |
| [0024](0024-voice-engines-catalogue-and-dictionary.md) | Voice engines, model catalogue, dictionary and asset packs | Accepted |
| [0025](0025-lfm3-audio-long-clip-transcription.md) | LFM3-Audio long-clip transcription and its measured constants | Accepted |
| [0026](0026-windows-client-core.md) | Windows client core: keys, state machines and trust boundaries | Accepted |
| [0027](0027-windows-app-shell-and-web-view.md) | Windows app shell, web view lock-down and smoke run | Accepted |
| [0028](0028-windows-build-versioning-and-ci.md) | Windows build, versioning and commit types | Accepted |
| [0029](0029-website.md) | Website: worker, languages, pairing links and hero demo | Accepted |
| [0030](0030-help-mcp-server.md) | Help MCP server and its content bundle | Accepted |
| [0031](0031-release-versioning-and-promotion.md) | Release versioning, beta tags and promotion | Accepted |
| [0032](0032-app-store-connect-and-testflight-tooling.md) | App Store Connect and TestFlight tooling | Accepted |
| [0033](0033-app-preview-capture-and-video.md) | App preview capture and video | Accepted |
| [0034](0034-test-conventions-and-fixtures.md) | Test conventions, harnesses and cross-language fixtures | Accepted |
| [0035](0035-ci-workflows.md) | CI workflows: concurrency, allowed actions and plugin checks | Accepted |
| [0036](0036-paios-example.md) | PAIOS example: installer safety, env names and checks | Accepted |

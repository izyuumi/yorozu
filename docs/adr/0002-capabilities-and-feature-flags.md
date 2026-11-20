# 0002. Capabilities and feature flags

- Status: Accepted
- Date: 2026-11-21 (recorded from code comments)

## Context

Client and plugin exchange `peer_info` with a list of capabilities. A feature is used only when both sides list it, and some capabilities depend on what the relay can do at the moment.

## Decision

- `direct` (#532): the plugin lists it only while its direct listener is listening. The probe and the race live in `Direct.swift`. `direct_hints` is plugin → client only, sent only to a client listing `direct`.
- `push-proxy` / `pushProxy` (#532): listed only while the relay's `registered` said `pushProxy: true`. A client on the direct path then sends its APNs token (hex) in the session as `push_token`, only over a direct session and only to a plugin listing it. The plugin forwards it to the relay as `push {device, token}` and registers it there for that device.
- `liveActivityPush`: counts-only Live Activity pushes through the relay, listed only while the relay can send them.
- `liveActivityHostWriter`: a lifetime host writer. It requires durable reservations and both relay ActivityKit flags. It stays reserved: do not advertise it.
- `presentation`: read-only cards on a `reply` and on `agent` history items, only for a client that lists it too. A sanitized card rides on a reply's last chunk.
- `reactions`: one emoji per person per message, both ways. The plugin sets `by`; a `by` from a device is ignored, so any string passes validation.
  - One slot per person: adding replaces, and removing clears the slot only when it holds that emoji. The change goes to every device and is returned, or nothing when nothing changed.
  - In the app, picking the reaction a message already has removes it.
  - The user's reaction reaches the agent as a system line at the start of its next turn. It never wakes the agent.
- `resume`: the plugin reports the chunks it already holds as sorted half-open index ranges (see [0011](0011-sync-uploads-and-share-extension.md)).
- When a capability is missing, the plugin downgrades events. JSON drops the keys `downgrade` sets to `undefined`, which is how the client reads them.

## Consequences

- A capability can appear and disappear during a session as the listener or relay changes.
- Mixed-version fleets keep working: an old client never receives fields it cannot read.

## Where in the code

- `plugins/openclaw-yorozu/src/envelope.ts` — `LIVE_ACTIVITY_PUSH`, `LIVE_ACTIVITY_HOST_WRITER`, `DIRECT`, `PUSH_PROXY`, `PRESENTATION`, `Reaction`, `Reply`, `UploadStatus`, `PushToken`, `DirectHints`, `reaction` validator
- `plugins/openclaw-yorozu/src/relay.ts` — `peerInfo` capabilities list
- `plugins/openclaw-yorozu/src/reactions.ts` — `apply`, `userReaction`
- `plugins/openclaw-yorozu/test/hub-events.test.ts` — `sent`
- `packages/YorozuWire/Sources/YorozuWire/WireEvent.swift` — `Direct`, `PushProxy`, `PushToken`, `DirectHints`, `ActivityReport`
- `apps/ios/Sources/Client/AppModel.swift` — `AppModel.react(_:to:in:)`
- `apps/relay/src/protocol.ts` — `parseHostPush`

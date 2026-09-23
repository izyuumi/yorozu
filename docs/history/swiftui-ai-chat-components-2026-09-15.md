# SwiftUI chat components for Yorozu

Research date: 2026-09-15. Sources are project repositories, package manifests, licenses, and releases.

## Recommendation

**Keep Yorozu's existing chat timeline. Do not replace it with a third-party chat framework.**

No maintained open-source component reviewed supplies the AI-specific timeline Yorozu needs across both iOS and macOS: streaming assistant text, thinking state, live tool calls/results, delegation traces, progress, approvals, questions, and arbitrary event order. The closest SwiftUI library, Exyte Chat, is iOS-only and would still require custom rows for every AI event. The only reviewed SwiftUI package declaring both iOS and macOS support, Stream Chat SwiftUI, is tied to Stream's backend and uses a proprietary source-code license.

Yorozu already has the deeper, more suitable abstraction: a shared event model and `ChatRow` projection, with dedicated SwiftUI views for tool activity, delegation, progress, approvals, and questions. The smallest reliable change is to make OpenClaw emit/translate incremental lifecycle events into that model and verify relay delivery. A generic chat UI would replace presentation code while leaving that actual problem untouched.

If a dependency is still desired for an iOS-only redesign, **Exyte Chat is the least-bad prototype candidate**, using its `messageBuilder` for custom Yorozu rows. Do not adopt it for production until macOS support and dependency weight are resolved.

## Comparison

| Project | Maintenance snapshot | License | Native fit / platforms | AI streaming, thinking, tools | Yorozu fit |
|---|---|---|---|---|---|
| [Exyte Chat](https://github.com/exyte/Chat) | 1,865 stars; repository pushed 2026-09-07; latest tagged release 2.1.4 (2025-01-23) | [MIT](https://github.com/exyte/Chat/blob/main/LICENSE) | SwiftUI-native, but current package manifest declares **iOS 17 only**. Four direct package dependencies: MediaPicker, Giphy, Kingfisher, AnchoredPopup. | No first-class AI lifecycle. Mutable message array can display growing text; `messageBuilder` and custom dictionaries can adapt bespoke rows. | Reject for shared Mac+iPhone surface. Adds model translation and dependencies while omitting macOS. |
| [Stream Chat SwiftUI](https://github.com/GetStream/stream-chat-swiftui) | 493 stars; pushed and released 5.11.0 on 2026-09-10 | [Proprietary Stream source-code agreement](https://github.com/GetStream/stream-chat-swiftui/blob/main/LICENSE), not an OSI open-source license | Completely SwiftUI; manifest declares iOS 14 and macOS 11. Depends on StreamChat and is designed on top of Stream's framework/service. | Typing/read indicators and customizable/stateless components; no documented AI thinking/tool-call/result timeline. Custom attachments/views could imitate one. | Reject. License and backend coupling conflict with Yorozu's encrypted relay/OpenClaw architecture. |
| [ChatLayout](https://github.com/ekazaev/ChatLayout) | 1,046 stars; pushed and released 2.4.3 on 2026-08-18 | [MIT](https://github.com/ekazaev/ChatLayout/blob/master/LICENSE) | UIKit `UICollectionViewLayout`, iOS 15 only; intentionally supplies neither data model nor input control. Strong low-level scrolling/layout control. | No AI semantics. Arbitrary dynamic cells make custom tool/thinking rows possible, but Yorozu would implement them all and bridge UIKit. | Reject. Yorozu already has a native iOS timeline and needs macOS parity. Useful only if a measured iOS scrolling defect defeats native APIs. |
| [MessageKit](https://github.com/MessageKit/MessageKit) | 6,269 stars; pushed 2026-09-03; 80 open issues at snapshot | [MIT](https://github.com/MessageKit/MessageKit/blob/main/LICENSE.md) | UIKit, iOS 14 only. SPM package depends on InputBarAccessoryView. Mature conventional message cells and custom cell escape hatch. | Typing indicator and `.custom` message kind, but no AI lifecycle or macOS support. Tool traces would be fully custom UIKit cells. | Reject. Largest adoption surface and mature, but wrong framework/platform boundary. |

GitHub counts and push dates above came from each repository's GitHub repository API record on the research date; they are volatile health indicators, not quality guarantees.

## Why Yorozu's existing design is ahead

Current local source already models the requested client experience:

- `Events.swift` defines `thought`, `tool_call`, `tool_result`, and `progress_card` payloads.
- `AgentTrace.swift` preserves arrival order, pairs tool calls with results, groups tool runs, and separates delegated-agent traces.
- `ChatView.swift` renders `ThinkingRow`, `ToolGroupView`, `DelegationCardView`, `ProgressCardView`, approval cards, question cards, and streaming message state on the shared surface.
- `TraceViews.swift` describes trace lists as live and redraws their input as thread events change.
- `Package.swift` supports macOS 15 and iOS 18 from one dependency-free shared Swift target.

Therefore UI-library adoption cannot make activity appear unless the Mac runtime sends incremental events through the relay and both clients merge/re-render them. Correct implementation boundary:

1. OpenClaw Gateway events -> Yorozu `thought` / `tool_call` / `tool_result` / streaming `message` mappings.
2. Persist and relay each event immediately, preserving stable IDs and order.
3. Show a thinking row from request start until first visible event.
4. Keep in-flight tool calls visible until matching results arrive; show success/failure and duration afterward.
5. Exercise the same fixture stream against macOS and iOS, including reconnect during a tool call and a delegated completion.

This reuses production code that already exists and keeps relay encryption, offline replay, trace grouping, and cross-platform visual parity intact.

## Primary sources

### Exyte Chat

- Repository and README (message array, custom `messageBuilder`, content model): <https://github.com/exyte/Chat>
- Package manifest (iOS 17 and dependencies): <https://github.com/exyte/Chat/blob/main/Package.swift>
- Releases: <https://github.com/exyte/Chat/releases>
- License: <https://github.com/exyte/Chat/blob/main/LICENSE>

### Stream Chat SwiftUI

- Repository and README (SwiftUI architecture, StreamChat foundation, stateful/stateless customization): <https://github.com/GetStream/stream-chat-swiftui>
- Package manifest (iOS/macOS and StreamChat dependency): <https://github.com/GetStream/stream-chat-swiftui/blob/main/Package.swift>
- Release 5.11.0: <https://github.com/GetStream/stream-chat-swiftui/releases/tag/5.11.0>
- License: <https://github.com/GetStream/stream-chat-swiftui/blob/main/LICENSE>

### ChatLayout

- Repository and README (UICollectionViewLayout scope, dynamic cells, no model/input): <https://github.com/ekazaev/ChatLayout>
- Package manifest (iOS 15): <https://github.com/ekazaev/ChatLayout/blob/main/Package.swift>
- Release 2.4.3: <https://github.com/ekazaev/ChatLayout/releases/tag/2.4.3>
- License: <https://github.com/ekazaev/ChatLayout/blob/master/LICENSE>

### MessageKit

- Repository and README (supported cells, typing indicator, custom cell API): <https://github.com/MessageKit/MessageKit>
- Package manifest (iOS 14 and InputBarAccessoryView dependency): <https://github.com/MessageKit/MessageKit/blob/main/Package.swift>
- License: <https://github.com/MessageKit/MessageKit/blob/main/LICENSE.md>

### Yorozu source reviewed

- `packages/shared-swift/Package.swift`
- `packages/shared-swift/Sources/YorozuShared/Events.swift`
- `packages/shared-swift/Sources/YorozuShared/AgentTrace.swift`
- `packages/shared-swift/Sources/YorozuShared/TraceViews.swift`
- `packages/shared-swift/Sources/YorozuShared/ChatView.swift`

# Archive-first swipe; Delete only on archived chats (PR1)

- Status: approved for PR1 (v3 + v3.1 amendment, 2026-11-11). Scope: PR1 only. Undo is not part of this spec.
- Author: Yorozu (the product agent). Implementer: Coder (the coding agent).
- Code read at origin/main 9f0f6420 (2026-11-11). Paths are repository-relative, and line numbers are that commit's.
- History in one sentence: v1 and v2 also specified undo, and their reviews found that a deferred delete can either remove a chat days later (v1) or wait for nothing on background and quit (v2), so undo moved to its own PR.

The owner's request (2026-11-11, verbatim): "Make the default thread item swipe to be archive first instead of delete. Deletion can only happen to archived chats. Also, implement shake to undo for both archive and delete." This spec covers the first two sentences.

## 1. Problem

On every chat in the list, the trailing swipe shows Delete first. SwiftUI enables full swipe on a trailing edge by default, so a long swipe triggers the Delete button (`apps/ios/Sources/YorozuIOS/Conversations.swift:204-207`). A full swipe opens the confirmation dialog; it does not itself delete. Delete is also in every chat's context menu (`Conversations.swift:222`). A confirmed Delete removes the session entry on the host and archives the transcript there; the chat leaves every paired device, and the wire has no message that restores it.

## 2. Goals

- G1. On a chat that is not archived, the trailing swipe offers Archive only, and a full swipe archives.
- G2. This build offers Delete, and sends `conv_patch {deleted: true}`, only for archived chats.
- G3. On an archived chat, the trailing swipe offers Delete and Unarchive, and the context menu offers Delete….

## 3. Non-goals

- Undo of any kind (shake, Cmd-Z, toast).
- Any change to what Delete does once confirmed, or to the dialog and its copy.
- Any change to the leading swipe (Mark Read/Unread, Pin), Rename, Pin rules or Open Beside.
- Any change to the wire, the relay, the plugin or the host. Shipped 0.13.x apps still delete active chats, and the host still accepts that.
- New strings.

## 4. Background

- One SwiftUI app target builds for iPhone, iPad and the Mac (`apps/ios/Project.swift:43`), so the list change applies on all three.
- The host (OpenClaw with the Yorozu plugin) owns each chat's archived flag. The app sends `conv_patch`; the host answers every device with `conv_update`, and `conv_list` answers the device that asked (`docs/ios-relay-contract.md`, section "Titles: `conv_patch` and `conv_update`", lines 348-353; `conv_list` at line 323). `conv_update` carries the full chat state, not a diff, so an absent `archived` means not archived.
- The local `archived` flag is set when the app's own `conv_patch` is sent, then corrected by the host's `conv_update` or `conv_list`.
- Archive already works end to end: `Conversation.archived` (`apps/ios/Sources/Client/Store.swift:16`), `AppModel.list` and `archivedList` (`apps/ios/Sources/Client/AppModel.swift:161-163`), the collapsible Archived section (`Conversations.swift:97-119`), and `AppModel.setArchived` (`AppModel.swift:1157-1162`). Archiving unpins (`OWNER_DECISIONS.md:82`).
- Delete today: the row's Delete sets `deleting`, the dialog's Delete calls `model.delete` (`Conversations.swift:132-141`), which sends `ConvPatch(deleted: true)` through `patch()` (`AppModel.swift:1168-1170, 1174-1184`) and forgets the chat once the send returns true.
- Entry points to Delete, checked with `git grep -nE 'onDelete|EditButton|editMode|onDeleteCommand|keyboardShortcut\(\.delete|model\.delete\(|deleted: true' -- apps/ios/Sources`: only the dialog's call at `Conversations.swift:137` and `AppModel.swift:1169`. There is no multi-select, no keyboard delete and no Siri or Shortcuts delete. The Delete at `Chat.swift:402` and `VoiceInput.swift:206` discards one unsent message and is out of scope.

## 5. Behaviour

### 5.1 Chat states in PR1

A chat is **archived** when `Conversation.archived == true`, and **active** otherwise. The local flag is set on send, then corrected by `conv_update` or `conv_list` (§4). PR1 adds no state and stores nothing new. **Removed** means forgotten locally after a successful send, as today.

| From | Event | To | Notes |
| --- | --- | --- | --- |
| active | Archive (swipe, full swipe, context menu) | archived | today's `setArchived(_, true)`; the open chat is deselected (`Conversations.swift:178`, unchanged). Archiving unpins, and Unarchive does not restore the pin (`OWNER_DECISIONS.md:82`) |
| archived | Unarchive (swipe, context menu) | active | today's `setArchived(_, false)` |
| archived | Delete, confirmed in today's dialog | removed | today's `delete`: send `ConvPatch(deleted: true)`, forget when the send returns true. `forget()` stays inside `patch()` at `AppModel.swift:1179`; only the guard and the return value are new |
| active | Delete | active | new: refused by the guard in `AppModel.delete(_:)` (§6); nothing is sent; no UI offers it |
| any | remote `conv_update` or `conv_list` | as the host says | unchanged sync (`AppModel.swift:836-866, 1186-1195`) |

The dialog's confirm handler clears `selection` only after `model.delete` returns true. A refused delete (for example, another device unarchived the chat while the dialog was open) leaves the selection and the open chat untouched, and the dialog closes with no change. The rule is the pure helper `ConversationActions.selectionAfterConfirmedDelete(selection:deletedId:succeeded:)`, which the handler calls and `ConversationActionsTests` covers (§6, §8).

### 5.2 Row actions

| Chat | Trailing swipe (first button = full swipe) | Context menu (archive and delete items only; the other items are unchanged) |
| --- | --- | --- |
| active | Archive (full swipe, no dialog) | Archive; no Delete… and no divider before it |
| archived | Delete (full swipe opens today's dialog), Unarchive | Unarchive, divider, Delete… |

Buttons keep today's titles, icons, tints and `.disabled(!model.canPatch)`.

**D3 (open with the owner).** Question: what does a full trailing swipe do on an archived row?

- Option A: Delete, opening today's confirmation dialog. This is the default used here.
- Option B: nothing; `allowsFullSwipe: false` on archived rows, so Delete and Unarchive are reached only by tapping a revealed button.

If the owner later picks option B, the change is `allowsFullSwipe: false` on archived rows, and these change with it: the archived swipe cell in the table above, the `trailingSwipe` doc comment (§6), the fifth screenshot (§8) and the D3 risk row (§10).

### 5.3 Strings

None added or changed. Every string used already exists in `apps/ios/Resources/Localizable.xcstrings` with English as source and translations for de, es, fr, ja, ko, pt-BR, zh-Hans and zh-Hant: "Archive", "Unarchive", "Delete", "Delete…", "Delete this conversation?", "It is deleted on the host and on every device, with its history." (checked with a script over the file at 9f0f6420).

## 6. Types, signatures and hook points

- New `apps/ios/Sources/Client/ConversationActions.swift`, Foundation only, so the Mac-only test target can compile it:

```swift
enum ConversationRowAction: Equatable, Hashable { case archive, unarchive, delete }

enum ConversationActions {
    /// Trailing swipe buttons in order; the first one is the full-swipe action.
    static func trailingSwipe(archived: Bool) -> [ConversationRowAction]  // false: [.archive]; true: [.delete, .unarchive]
    /// The archive and delete items of the context menu, in order.
    static func menu(archived: Bool) -> [ConversationRowAction]           // false: [.archive]; true: [.unarchive, .delete]
    /// After a confirmed Delete: clear selection only when that delete was accepted for the selected chat.
    static func selectionAfterConfirmedDelete(selection: String?, deletedId: String, succeeded: Bool) -> String?
}
```

- `Conversations.swift` `row(_:)` (lines 174-226): build the trailing `.swipeActions(edge: .trailing, allowsFullSwipe: true)` and the archive/delete part of `.contextMenu` from `ConversationActions` with `archived = conversation.archived == true`, mapping `.archive`/`.unarchive` to today's `archive` button and `.delete` to today's `delete(_:)` button (the divider goes before `.delete` only).
- `Conversations.swift` confirm handler (line 136-137): call `model.delete` first, then set `selection` from `selectionAfterConfirmedDelete` with the result (§5.1). The rest of the dialog is unchanged.
- `AppModel.swift:1168-1170`: change `func delete(_ convId: String)` to

```swift
@discardableResult
func delete(_ convId: String) -> Bool {
    guard conversations[convId]?.archived == true else { return false }
    patch(ConvPatch(convId: convId, deleted: true)) { _ in }
    return true
}
```

  `true` means the patch was handed to `patch()`, not that the host applied it.
- `apps/ios/Project.swift`: add `"Sources/Client/ConversationActions.swift"` to the `YorozuTests` sources list (lines 244-256). The app target already picks it up through `"Sources/Client/**"` (`Project.swift:92`).

## 7. Files

| Path | Action | Change |
| --- | --- | --- |
| `apps/ios/Sources/Client/ConversationActions.swift` | create | §6 |
| `apps/ios/Sources/YorozuIOS/Conversations.swift` | modify | `row(_:)` per §5.2 and §6; the Delete confirm handler per §5.1 and §6 |
| `apps/ios/Sources/Client/AppModel.swift` | modify | `delete(_:)` guard per §6 |
| `apps/ios/Project.swift` | modify | test sources entry |
| `apps/ios/Tests/Support/Transports.swift` | create | `IdleTransport` and `ScriptedTransport` moved from `AppModelPairingTests.swift`, made internal; §8 |
| `apps/ios/Tests/Support/ModelHarness.swift` | create | the model setup from `AppModelPairingTests.swift` moved here; §8 |
| `apps/ios/Tests/AppModelPairingTests.swift` | modify | use the moved types; no assertion changes |
| `apps/ios/Tests/ConversationActionsTests.swift` | create | §8 |
| `apps/ios/Tests/ConversationDeleteTests.swift` | create | §8 |
| `docs/history/decisions-log.md` | modify | append "## 2026-11-11 — Archive-first swipe; Delete only on archived chats" with the owner's quote and what this change covers |
| `docs/designs/archive-first-swipe.md` | create | this spec |

No other path changes. In particular nothing under `apps/relay/`, `packages/`, `plugins/`, `apps/web/`, `apps/mcp/`, and no change to `Localizable.xcstrings`, `Crons.swift`, `Root.swift`, `Push.swift` or the widgets.

## 8. Tests

Harness (the fakes in `apps/ios/Tests/AppModelPairingTests.swift:5-40` are `private` and their `send` returns false):

- `Tests/Support/Transports.swift`: `IdleTransport` and `ScriptedTransport` become internal. `ScriptedTransport` records every `send(_ event: WireEvent)` in `private(set) var sent: [WireEvent]`, and returns `sendResult`, a stored `Bool` defaulting to `false` and set with `func setSendResult(_:)`. The default keeps the pairing tests' behaviour.
- `Tests/Support/ModelHarness.swift`: a `@MainActor final class ModelHarness` holding what `AppModelPairingTests` builds today (the `init` checks of HOME and bundle id, `MemoryPairingStorage`, `PairingMigration.State`, the per-test `ConversationCache`, `store(paired:)`, `makeModel()`, `settled(_:)` and `openFirstSession()` from lines 62-148). `seed(_ conversations: [Conversation])` saves to the cache before `makeModel()`, and `scripted` is the `ScriptedTransport` that `openFirstSession()` uses. `AppModelPairingTests` uses it; its tests and assertions stay as they are.
- The `YorozuTests` scheme runs on the Mac with `--demo` and passes `demo: false` explicitly through `makeModel()`, as today.

`ConversationActionsTests` (pure):

- `trailingSwipe(archived: false) == [.archive]`.
- `trailingSwipe(archived: true) == [.delete, .unarchive]`.
- `menu(archived: false) == [.archive]`.
- `menu(archived: true) == [.unarchive, .delete]`.
- `selectionAfterConfirmedDelete`: a refused delete keeps the current selection, including when it is the deleted id; an accepted delete of the selected chat clears it; an accepted delete of a different chat leaves it unchanged.

`ConversationDeleteTests` (a ready model over `ScriptedTransport`, from `openFirstSession()`, with seeded chats; assertions on `sent` filter for `.convPatch`, and wait for the recorded send because `patch()` sends inside a `Task`):

- Delete on an active chat returns false, sends no `conv_patch`, and the chat stays in `model.conversations`.
- Delete on an unknown id returns false and sends nothing.
- Delete on an archived chat with `sendResult = true` returns true, sends exactly one `ConvPatch(convId:, deleted: true)`, and the chat leaves `model.conversations` (within `settled`).
- Delete on an archived chat with `sendResult = false` returns true, the send is attempted once, and the chat stays (today's behaviour).
- A seeded archived chat that receives `conv_update` without `archived` (emitted through `ScriptedTransport.emit(.event(.convUpdate(...)))`) is active, and Delete on it then returns false and sends nothing.

Not covered by unit tests, because `YorozuTests` does not compile the views: the rendered swipe and menu. They are covered by `ConversationActionsTests` (the order the view renders) and by the screenshots.

Commands: `tuist generate --no-open --path apps/ios`, then the iOS build, the Mac build and `xcodebuild test -workspace apps/ios/Yorozu.xcworkspace -scheme YorozuTests -destination 'platform=macOS'` exactly as in `.github/workflows/checks.yml:53-71`.

Screenshots (iPhone simulator in demo mode, and the Mac build in demo mode): the trailing swipe on an active chat; the trailing swipe on an archived chat; the context menu of an active chat; the context menu of an archived chat; today's dialog after a full swipe on an archived chat.

## 9. Alternatives

- Keep Delete on active chats behind the dialog and only reorder the buttons: a full swipe would still reach Delete on active chats, which the request rules out.
- Enforce "delete only archived" on the host: it would break Delete in shipped apps, which offer it on active chats, and needs a plugin release.
- Ship PR1 together with undo: the undo design is not settled (two failed reviews) and needs a device spike; the swipe fix does not depend on it.

## 10. Risks

| Risk | Mitigation |
| --- | --- |
| A full swipe on an archived chat still lands on Delete | It opens today's dialog; D3 is with the owner, and the alternative is `allowsFullSwipe: false` on archived rows (§5.2). |
| Archived chats pile up now that deleting takes more steps. Deleting an active chat now takes: archive, expand the collapsed Archived section, find the row, swipe or open the menu, confirm. `conv_list` returns at most 2000 chats including archived ones (`docs/ios-relay-contract.md:323`); that cap is the limit pile-up moves toward, not a mitigation | None. Accepted for PR1. |
| "Delete only archived" holds in this build only: shipped 0.13.x apps still delete active chats, and the host still accepts that. The guard reads the local `archived` flag, which is set on send and then corrected by `conv_update` or `conv_list`, so it can briefly differ from the host's | Accepted: the host stays the authority, and enforcing the rule there would break shipped apps (§9). |
| Existing behaviour, unchanged: a `conv_patch` for a chat the host does not have is answered with `conv_update {deleted: true}`, and the client forgets the chat. So Archive on a host-unknown chat removes it locally | None added: no extra gating on pinned or host-unknown chats. |
| Moving the private fakes changes the pairing tests | The move keeps their defaults; their assertions are unchanged and must still pass. |
| Merging `apps/ios/**` starts Release iOS (TestFlight internal) and Release Mac | Merge only on the owner's go. |

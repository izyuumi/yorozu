# 0013. Home routing, split panes, row actions and settings structure

- Status: Accepted
- Date: 2026-11-21 (recorded from code comments)

## Context

The home screen is a split view on iPad and Mac. Opening a conversation from outside the app must always bring it on screen, and impossible layouts should not be representable.

## Decision

- `HomeRoute` holds the section, the selected conversation and the split view's columns, changed together so that opening a conversation always brings it on screen.
  - `openRequested`: a conversation the app was asked to open (notification, widget, control, intent, link) is shown, and the sidebar never covers it.
  - `open`: a conversation opened from inside the app (in-app notice, automation) is shown, and the columns stay as they are. The Mac keeps its columns as they are when a cron row opens a conversation.
- `LaunchColumns`: the sidebar shows on a cold launch, and a requested conversation is never covered by it. After a requested open, a sidebar shown by `initial` hands over to the system, which keeps it beside the conversation where the width allows and hides it where it would overlay. Other states stay as they are.
- `ChatPair.Panes` has one case per layout, so a picker beside a split, a split without a second conversation, or a second pane showing the focused conversation can't be stored. `settle` ensures the second pane never shows the focused conversation.
- Conversation row actions depend on whether the chat is archived. Delete is for archived chats only. Trailing swipe buttons are in order; the first is the full-swipe action.
- Settings: iOS uses the same groups as the Mac's tabs, each on a page of its own. A row that opens a page of its own is pushed on iPhone and iPad and shown as a sheet in the Mac's settings window, which has no navigation stack.

## Consequences

- External opens behave the same from every entry point.

## Where in the code

- `apps/ios/Sources/YorozuIOS/HomeRoute.swift` — `HomeRoute`, `openRequested(_:)`, `open(_:)`
- `apps/ios/Sources/YorozuIOS/LaunchColumns.swift` — `LaunchColumns`, `afterRequestedOpen(_:)`
- `apps/ios/Sources/YorozuIOS/Crons.swift` — cron row open
- `apps/ios/Sources/YorozuIOS/ChatPair.swift` — `ChatPair.Panes`, `ChatPair.settle(_:)`
- `apps/ios/Sources/Client/ConversationActions.swift` — `ConversationActions`, `trailingSwipe(archived:)`
- `apps/ios/Sources/YorozuIOS/Settings.swift` — iOS settings `Form`
- `apps/ios/Sources/YorozuIOS/VoiceSettings.swift` — `VoiceSubpage`

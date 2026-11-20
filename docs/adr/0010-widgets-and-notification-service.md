# 0010. Widgets, the App Group snapshot and the notification service

- Status: Accepted
- Date: 2026-11-21 (recorded from code comments)

## Context

Widgets, Lock Screen accessories, Control Center controls and the notification service extension (NSE) all run outside the app. They share data through an App Group and must stay small, private and free of agent logic.

## Decision

- `WidgetSnapshot` is what the widgets, the Lock Screen and the controls may know. The app and the NSE write it to the App Group. Titles and counts only, plus one reply preview when the owner turned it on.
  - The NSE remembers `seenLimit` push events so a redelivered push counts once.
  - `live`: the app is in front and owns the counts; the NSE leaves them alone.
  - "Show message previews in widgets" is stored in the App Group so the NSE reads it too.
- The app's snapshot holds titles, pins and `Conversation.unreadCount`, and the latest reply's first line only when previews are on. Archived conversations stay out of the rows but count toward the total, as on the app badge.
- The app writes the snapshot only when its bytes changed, comparing against the file, not a copy in memory, because the NSE may have counted a reply the app has since loaded. Then it asks WidgetKit to redraw. iPhone and iPad only: the Mac app is signed without the App Group.
- The NSE decides only whether a decrypted push updates the widget snapshot. A reply does. The Live Activity and its labels are left to the host and the app.
  - The NSE must not compile or link ActivityKit: its sources exclude `YorozuActivityAttributes.swift`, and `check-nse-no-activitykit.py` enforces it, scanning generated Tuist bundles under `Derived/` too when present.
  - Its entitlements include the App Group because a reply's notification updates the widgets' snapshot.
- The widget extension shows Home and Lock Screen widgets, Control Center controls and the Live Activity's views. It reads only the App Group snapshot; it never pairs, connects or runs the agent.
  - A conversation in the widget's configuration is read from the snapshot, never from the app's store, so picking one works without launching the app.
  - Timelines hold an entry every quarter hour to keep relative times fresh; the app and the NSE reload the timeline whenever the snapshot changes. Relative times ("5 min. ago") are computed against the entry's date so each entry reads right.
  - The Lock Screen launcher opens a fresh conversation with the keyboard up and reads no data; its provider has one entry that never changes.
  - Widget views take an optional `size: WidgetFamily?`, set only to draw a family outside WidgetKit for screenshots; otherwise the system's family applies.
- Links: the widget intents open the app when run, so `perform` runs in the app, where the app delegate installed `handler`; the widget extension never handles a link itself. `AppModel.open(_ link:)` opens what a widget, control or accessory asked for. Without a pairing the app just comes forward. Demo mode opens only new conversations: it writes no snapshot, so no link names one of its conversations.

## Consequences

- Extensions cannot leak conversation content beyond what the owner allowed.
- The NSE stays small and cannot drift into Live Activity work.

## Where in the code

- `apps/ios/Sources/WidgetShared/Model/WidgetSnapshot.swift` — `WidgetSnapshot`, `seenLimit`, `live`, `WidgetStore.previewsKey`
- `apps/ios/Sources/WidgetShared/Model/NotificationEffects.swift` — `NotificationEffects`
- `apps/ios/Sources/Client/WidgetPublisher.swift` — `WidgetPublisher`
- `apps/ios/Sources/Client/AppModel.swift` — `open(_ link: WidgetLink)`
- `apps/ios/Sources/WidgetShared/Interface/Launcher.swift` — `Launcher`
- `apps/ios/Sources/WidgetShared/Interface/WidgetLink.swift` — link handler
- `apps/ios/Sources/YorozuWidgets/ConversationTimeline.swift` — `WidgetConversationEntity`, `quarterHourTimeline(_:)`
- `apps/ios/Sources/YorozuWidgets/LauncherWidgets.swift` — `LauncherProvider`
- `apps/ios/Sources/YorozuWidgets/WidgetStyle.swift` — `relative(_:to:)`
- `apps/ios/Sources/YorozuWidgets/UnreadAccessoryWidget.swift`, `ConversationsWidget.swift` — `size`
- `apps/ios/Project.swift` — `YorozuNotificationService` and `YorozuWidgets` targets
- `apps/ios/scripts/check-nse-no-activitykit.py` — `main()`

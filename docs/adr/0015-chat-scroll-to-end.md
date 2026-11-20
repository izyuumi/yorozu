# 0015. Chat scroll-to-end

- Status: Accepted
- Date: 2026-11-21 (recorded from code comments)

## Context

A chat should open at its newest message and follow new messages, but SwiftUI's scroll APIs misplace the end when the keyboard, the composer or lazy row heights change (measured on iOS 26 and 27).

## Decision

- `ChatScrollEdge` reads `ScrollGeometry`: `offset` is `contentOffset.y`, `minOffset` is `-contentInsets.top` (the offset at the top), and `maxOffset` is `contentSize.height - containerSize.height - contentInsets.top` (the offset at the end). `containerSize` is the bounds less the insets, bars and keyboard included.
- A settle is needed when the view is past the end over empty space by more than 1 pt or, while following, short of it by more than 1 pt. Content shorter than the container never needs one: the view cannot scroll.
- `.defaultScrollAnchor(.bottom, for: .initialOffset)`: only the first layout starts at the bottom; later size changes are left to the follow rule and the settle.
- Opening a chat starts at its newest message. The geometry for the first content can land before the `items.last?.id` change (already not at bottom), and a scroll issued in the same update as the first content can be dropped, so the settle keeps following until the chat rests at its end or the user drags.
- `scrollToEnd` scrolls to the end row, not the scroll position's bottom edge. The bottom edge ignores the keyboard's inset and trusts estimated lazy row heights, so it came to rest past the real end until a drag clamped it; a row id is resolved against the laid-out content.
- `settle` runs only at rest, never mid-gesture, so a bounce at the bottom is not fought.
- `scheduleSettle` waits until the geometry has held still for a moment: the keyboard and the composer move the insets in animations the scroll phase does not report, and correcting every frame would fight them.

## Consequences

- The chat rests exactly at its end after keyboard and composer changes.

## Where in the code

- `apps/ios/Sources/YorozuIOS/ChatScrollEdge.swift` — `ChatScrollEdge`, `needsSettle(following:)`
- `apps/ios/Sources/YorozuIOS/Chat.swift` — scroll geometry reader, `defaultScrollAnchor`, `onChange(of: items.last?.id)`, `scrollToEnd()`, `settle()`, `scheduleSettle()`

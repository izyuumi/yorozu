# 0014. Composer: focus, dictation caret, keys and layout

- Status: Accepted
- Date: 2026-11-21 (recorded from code comments)

## Context

The composer sits at the bottom of every chat on iPhone, iPad and Mac. It must not raise the keyboard unasked, must keep dictated text where the caret was, and must line its controls up on one axis.

## Decision

- Focus:
  - On iOS only a conversation the user explicitly started raises the keyboard. `newConversationId()` allocates an id and requests text (not voice) composer focus.
  - On the Mac an opened conversation focuses its composer; elsewhere the keyboard stays down until tapped.
  - The unfocused split pane must not steal the keyboard.
  - `requestedFocus` is one-shot and cleared when voice starts: the text view is rebuilt when the voice bar leaves and would otherwise refocus.
- Caret (`ComposerCursor`): the caret is kept outside the text view so dictated text lands where the caret was, even though the voice bar replaced the text view meanwhile. A second dictation goes after the first. `insert` puts the piece at the caret (the end if none; after any selection, so nothing typed is replaced), spaces it from a neighbouring Latin word, and moves the caret after it.
- Mac keys: Return sends a one-line message unless the owner opted into ⌘Return; Shift-Return always adds a line.
- Layout:
  - `rowHeight` is one line of the row: every control and a single line of text share it, so they center on one axis.
  - `inset` is the same space above, below and beside the row's ends, so the send circle sits concentric in the capsule.
  - The row behaves like a flex row aligned to the end: controls stay on the last line while the text grows.
- Reply actions: pointer platforms keep the row's space and reveal the actions on hover; iPhone shows them on the latest reply only. On the Mac, icons sit close together in narrow targets as tall as a control, and a leading pull lines the first icon up with the reply text.

## Consequences

- See [docs/ui-layout.md](../ui-layout.md) for the general sizing rules these constants live within.

## Where in the code

- `apps/ios/Sources/Client/ComposerFocus.swift` — `ComposerFocus`
- `apps/ios/Sources/Client/AppModel.swift` — `newConversationId()`
- `apps/ios/Sources/YorozuIOS/Chat.swift` — `focusKey(_:focus:)`, compose request handling, voice phase change, reply actions, composer `rowHeight`, `inset`, `row`
- `apps/ios/Sources/YorozuIOS/ComposerCursor.swift` — `ComposerCursor`, `insert(_:into:)`
- `apps/ios/Sources/YorozuIOS/ComposerTextView.swift` — macOS key handling

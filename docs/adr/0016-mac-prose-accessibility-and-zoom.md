# 0016. Mac prose rendering, accessibility workarounds and zoom

- Status: Accepted
- Date: 2026-11-21 (recorded from code comments)

## Context

SwiftUI `Text` selects one view at a time and has no hanging indent, and the Mac has no Dynamic Type. Bridging to AppKit brought accessibility bugs that need explicit workarounds.

## Decision

- Prose on the Mac: consecutive prose blocks of one message are drawn as one read-only `NSTextView`, so a selection can run across paragraphs, headings, lists and quotes.
- The SwiftUI node over the `NSTextView` gets an accessibility label of its own (`plainText`). Without one, the node asks the view for a label, the view asks the node back, and an accessibility client reading it overflows the stack (#584).
- `ComposerScrollView` is a plain container: the text view inside is the field. Without this, accessibility clients meet "Message" twice, on the scroll area and on the text area.
- Zoom: ⌘+ / ⌘− / ⌘0 on the Mac and iPad, one app-wide step per device.
  - The iPad shifts the system's Dynamic Type size by the step. `UIFont.preferred` gives UIKit text views a text-style font at the environment's Dynamic Type size, which carries the iPad's zoom.
  - The Mac has no Dynamic Type, so its text styles read `textZoom` through `textStyle(_:)`. `textZoom` is always 1 on iPhone and iPad.
  - The iPhone follows the system text size only.
  - `zoomedFont` sets a style at the Mac's zoom only while zoomed, for views that otherwise keep the system's font: a scene's default text, sidebar rows, and `ContentUnavailableView`'s label and description.
  - A menu item has one shortcut, so ⌘= (⌘+ without Shift) lives on a hidden button.
  - The conversation list sets `.font(nil)`: a Mac sidebar drops a row font equal to the one the list inherits; with none inherited, the rows' zoomed fonts stand.

## Consequences

- VoiceOver and other accessibility clients work on Mac prose and the composer.

## Where in the code

- `apps/ios/Sources/YorozuIOS/ProseText.swift` — `ProseText`, `plainText(_:)`
- `apps/ios/Sources/YorozuIOS/ChatMarkdown.swift` — prose segment rendering
- `apps/ios/Sources/YorozuIOS/ComposerTextView.swift` — `ComposerScrollView`
- `apps/ios/Sources/YorozuIOS/Zoom.swift` — `Zoom`, `EnvironmentValues.textZoom`, `View.zoomedFont(_:)`, zoom commands, `UIFont.preferred(_:size:)`
- `apps/ios/Sources/YorozuIOS/Conversations.swift` — conversation list font

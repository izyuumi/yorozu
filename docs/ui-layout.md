# UI layout

Let the platform decide sizes. Do not pick a number for how wide, tall, or far apart
something should be when the system can work it out; a number chosen on one device is
wrong on the next.

## Rule

Use the native mechanism first, in this order:

1. The container's proposal. A navigation bar, toolbar, list row, or stack already offers a
   view the room it has. Take it: `frame(maxWidth: .infinity)`, `lineLimit`, `truncationMode`.
2. Adaptive layout views. `ViewThatFits`, `Layout`, `containerRelativeFrame`, size classes,
   `dynamicTypeSize`, `safeAreaInset`, `scrollTargetLayout`.
3. Measuring. `onGeometryChange(for:of:)` or `GeometryReader` when a view must react to
   the size it was actually given — compare, do not assume.

Hard-coded points, `fixedSize` on something that lives inside a system container, or a
`frame(width:)`/`frame(maxWidth:)` picked by eye are all guesses about a bar the system
draws. They break on a narrower device, a larger type size, a split view, or the next OS.

## Exception

A custom component owns its own geometry. Fixed sizes belong there when they are the
design: a 20-point agent mark, a 5-point presence dot, spacing inside a card. Keep them as
one named constant in the component, not spread over call sites, and still let the
component's outer size come from its container.

## Example

The chat title in `ChatView`'s `.principal` toolbar item once had
`.fixedSize(horizontal: true)`, so a long title took its ideal width and ran under the
trailing buttons. A `frame(maxWidth: 160)` cap hid that on one phone. The fix that holds is
[`MarqueeText`](../packages/shared-swift/Sources/YorozuShared/MarqueeText.swift): take
the width the bar proposes, measure the text against it with `onGeometryChange`, and
scroll only when it overflows.

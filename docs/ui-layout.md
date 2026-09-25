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

## Check the proposal exists

Native sizing only works when the container actually proposes a size. Some do not: from
iOS 26 the navigation bar lays a custom `.principal` view out at its ideal width and never
tells it how much room there is, on every iPhone and in iPhone Duo's side bar. Before
building on a proposal, confirm it on the target device — `onGeometryChange` and a `print`
of the frame take a minute and settle it. Where the platform withholds the width, use the
platform view that has it (the system title) rather than inventing one.

## Example

The chat title in `ChatView` was a custom `.principal` item. It ran under the toolbar
buttons on iOS 26 because the bar gave it 565 points on a 402-point screen; a
`frame(maxWidth: 160)` cap hid that on one phone, and a marquee measured against its
container never scrolled because the container was the text's own width. The fix that
holds is `navigationTitle` and `navigationSubtitle`, which the bar truncates on every
device, with the custom item kept only for the older bars that clamp it.

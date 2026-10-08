# UI layout

Let the platform decide sizes. Take widths, heights and spacing from the container or the
system; a number chosen on one device is wrong on the next.

## Rule

Use the native mechanism first, in this order:

1. The container's proposal. A navigation bar, toolbar, list row, or stack already offers a
   view the room it has. Take it: `frame(maxWidth: .infinity)`, `lineLimit`, `truncationMode`.
2. Adaptive layout views. `ViewThatFits`, `Layout`, `containerRelativeFrame`, size classes,
   `dynamicTypeSize`, `safeAreaInset`, `scrollTargetLayout`.
3. Measuring. `onGeometryChange(for:of:)` or `GeometryReader` when a view must react to
   the size it was actually given; compare against that size.

Hard-coded points, `fixedSize` on something that lives inside a system container, or a
`frame(width:)`/`frame(maxWidth:)` picked by eye are all guesses about a bar the system
draws. They break on a narrower device, a larger type size, a split view, or the next OS.

## Exception

A custom component owns its own geometry. Fixed sizes belong there when they are the
design: a 20-point agent mark, a 5-point presence dot, spacing inside a card. Keep each as
one named constant inside the component, and still let the component's outer size come
from its container.

## Check the proposal exists

Native sizing only works when the container actually proposes a size. Some do not: from
iOS 26 the navigation bar lays a custom `.principal` view out at its ideal width and never
tells it how much room there is. Before building on a proposal, confirm it on the target
device: `onGeometryChange` and a `print` of the frame take a minute and settle it. Where
the platform withholds the width, use the platform view that has it (the system title).

## Examples

- The iOS chat title is the system title, `.navigationTitle("Yorozu")` in
  `apps/ios/Sources/YorozuIOS/ChatScreen.swift`, which the bar truncates on every device.
  v1's chat on `main` used a custom `.principal` title instead; on iOS 26 the bar gave it
  565 points on a 402-point screen and it ran under the toolbar buttons, and a
  `frame(maxWidth: 160)` cap hid that on one phone only.
- The Mac's Pair iPhone sheet draws its QR code from one constant, `qrSide` in
  `Sources/ProjectXApp/Relay/PairPhoneView.swift`, which sizes both the code and its
  placeholder: a custom component owning its geometry.
- The Mac's chat popover is 420×640 points from one constant, `MenuBarHost.popoverSize` in
  `Sources/ProjectXApp/MenuBarHost.swift`: nothing proposes a size to an `NSPopover`, so the
  host that owns it sets it. Everything inside sizes from it; the composer takes a fifth of
  the height through `containerRelativeFrame(.vertical)` rather than a fixed `minHeight`.
  The Settings window's width is likewise one constant in `SettingsView`.

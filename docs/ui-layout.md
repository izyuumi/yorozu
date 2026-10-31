# UI layout

Let the platform decide sizes. Take widths, heights and spacing from the container or the
system; a number chosen on one device is wrong on the next. The client in `apps/ios` is one
SwiftUI app for iPhone, iPad and Mac (native macOS, not Catalyst), so every layout runs on
all three.

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
design: spacing inside a card, a corner radius, a send button's circle. Keep each as one
named constant, and still let the component's outer size come from its container.

## Check the proposal exists

Native sizing only works when the container actually proposes a size. Some do not: a
Mac window proposes no size, and a custom `.principal` toolbar view is laid
out at its ideal width rather than the room left in the bar. Before building on a proposal,
confirm it on each target device: `onGeometryChange` and a `print` of the frame settle it.
Where the platform withholds the width, use the platform view that has it (the system title).

## Text

Fonts are text styles only, set with `textStyle(_:weight:monospaced:)` from `Zoom.swift` rather than `font(_:)`:
on the Mac it applies the app's zoom (⌘+ / ⌘−), which `dynamicTypeSize` does not reach there. A size that
grows with text uses `@ScaledMetric` times the `textZoom` environment value. A view that keeps a
system font (a sidebar row, `ContentUnavailableView`) takes `zoomedFont(_:)`.

## Where the constants live

All paths are under `apps/ios/Sources/YorozuIOS/`.

- `LayoutMetrics` in `Metrics.swift` is the shared scale: spacing (`hair` 2 … `section` 24),
  the caps `readingWidth` (700) and `composerWidth` (640), which only an iPad or a Mac window
  reaches, and the corner radii (10 on the Mac, 14 and 16 on iPhone and iPad).
  Mac only: the sidebar column widths and the window's least size (`windowMinWidth`,
  `windowMinHeight`), set in `YorozuApp.swift` because a window proposes no size.
- `controlTarget` in `Metrics.swift` is the one size that differs by input: 44 points on
  iPhone and iPad, 28 on the Mac. Chat controls take their size from it, not from literals.
- `MarkdownMetrics` in `ChatMarkdown.swift` holds the message renderer's spacing, insets and
  radius; its width always comes from the row. A code block scrolls sideways, a table's cells
  wrap to the width given, and an image scales down to it (`ViewThatFits`).

## Examples

- Titles are system titles (`.navigationTitle`), never a custom `.principal` view: the bar
  truncates them on every device.
- iPhone vs. iPad: `HomeView` in `Crons.swift` picks tabs for a compact horizontal size
  class (an iPhone in portrait, an iPad in a narrow multitasking width) and a split view for
  a regular one; the Mac always uses the split view. Nothing branches on the device model.
- iPhone and iPad split view only (`#if os(iOS)`): when two conversations open side by side,
  `ChatPairView` in `Pair.swift` measures its width with `onGeometryChange` and hides the
  sidebar when each pane would get less than `comfortablePane` (360 points).
- The pairing QR code (`QRCode` in `AddDeviceSheet.swift`) owns its compact size,
  `compactSide` (180 points), snapped to whole pixels per module so it stays sharp; clicked or
  tapped, it fills the sheet in an overlay. On the Mac, `AddDeviceSheet` measures its content
  with `onGeometryChange` and gives the scroll view that ideal height, so the sheet opens tall
  enough to show everything without scrolling.
- The composer grows with its text up to five lines (`ComposerTextView.maxLines`), then
  scrolls, rather than taking a fixed height.
- A user bubble leaves `2 × section` of space at the far edge (`Spacer(minLength:)` in
  `Chat.swift`) instead of a fixed width.


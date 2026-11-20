# 0017. Read-only presentation cards in the client

- Status: Accepted
- Date: 2026-11-21 (recorded from code comments)

## Context

With capability `presentation`, an agent reply or history item can carry a read-only card: a title, a tone and blocks such as tables and charts. The client must render what it can, fall back to text for the rest, and agree byte for byte with the plugin on fallback text.

## Decision

- A card shows after its reply's text bubble, or alone for a card-only reply: title and tone, then each block. A block the reader couldn't check draws as its `alt`.
- `Presentation.parts`: an agent reply shows its text bubble, then its card. A card never hides text, except the card's own fallback text (a card-only reply); a card that doesn't render leaves the text alone.
- Card geometry lives in `CardMetrics`; the card's width always comes from the row.
- Tables: a grid that scrolls sideways when wider than the card. VoiceOver reads the caption, the header row and the row-header column as headers, and each other cell with its row header and column header.
- Charts: Swift Charts. VoiceOver reads the block's `alt` (its title and data as text) and offers the data as an audio graph through the chart descriptor. The decoder has already checked that every series has one value per category.
- Parity with the plugin:
  - A table cell's text is written as the plugin's `alt` writes it, JavaScript's `String(n)`: no locale grouping, every digit sent. It is ECMAScript `Number::toString` applied to Swift's shortest round-trip digits; the value is finite (the table check ensures it).
  - `fallbackText` is the text the plugin sends with a card-only reply (its `fallback()`): the title and each block's non-empty `alt`, joined by blank lines, cut by Unicode scalar to `maxFallbackBytes` of UTF-8 with the marker last.
  - `LossyPresentation`: a card over `Presentation.maxBytes`, or one that isn't a card, decodes as nil. The decoder hands over no bytes, so the size is the card's compact JSON, which is how the plugin sends it.
- Diagnostics count cards since launch as counts only: cards drawn, blocks that fell back to their `alt` or were skipped, and cards with nothing to draw whose bubble showed the text.

## Consequences

- Old or partial cards degrade to text; they never hide a reply.
- Fixtures shared with the plugin pin the parity ([0034](0034-test-conventions-and-fixtures.md)).

## Where in the code

- `apps/ios/Sources/YorozuIOS/PresentationView.swift` — `CardMetrics`, `PresentationView`, `CardTable`, `CardChart`, `CardChart.points`
- `apps/ios/Sources/YorozuIOS/Diagnostics.swift` — `presentationShown` and sibling counters
- `packages/YorozuWire/Sources/YorozuWire/WireEvent.swift` — `Presentation.Cell.text`, `Presentation.Cell.javaScript`, `Presentation.fallbackText`, `Presentation.parts`, `LossyPresentation`

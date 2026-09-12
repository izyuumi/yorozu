import CoreGraphics

/// The two sizes that differ because a finger and a pointer are not the same instrument.
///
/// A phone control has to be 44 points before it can be hit reliably, and everything in the
/// chat is sized from that. A pointer lands where it is aimed, so the same 44 points on a Mac
/// buys nothing and costs the composer a third of its height — it reads as a phone app blown
/// up. These two constants are the whole of the difference; every control in the chat takes
/// its size from them rather than from a literal, so the two platforms cannot drift apart.

/// The smallest a control may be and still be easy to hit.
#if os(macOS)
    public let controlTarget: CGFloat = 28
#else
    public let controlTarget: CGFloat = 44
#endif

/// What the composer's text field pads itself by, above and below. Enough to centre one line
/// of body text in a ``controlTarget``-tall row on either platform.
#if os(macOS)
    public let composerPadding: CGFloat = 5
#else
    public let composerPadding: CGFloat = 11
#endif

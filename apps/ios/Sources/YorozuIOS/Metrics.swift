import CoreGraphics

/// Compact Quiet's shared rhythm. A four-point scale keeps related content tight while
/// preserving clear turn and section boundaries on both platforms.
public enum LayoutMetrics {
    public static let hair: CGFloat = 2
    public static let tight: CGFloat = 4
    public static let inner: CGFloat = 8
    public static let stack: CGFloat = 12
    public static let gutter: CGFloat = 16
    public static let section: CGFloat = 24
    /// The widest a line of prose may run, on any platform: a 13" iPad in landscape is as wide
    /// as a Mac window, and a line that long is not readable. A phone never reaches either cap.
    public static let readingWidth: CGFloat = 700
    public static let composerWidth: CGFloat = 640

    #if os(macOS)
        public static let cardPadding: CGFloat = 12
        public static let controlRadius: CGFloat = 6
        public static let cardRadius: CGFloat = 10
        public static let bubbleRadius: CGFloat = 10
        public static let sidebarMinWidth: CGFloat = 220
        public static let sidebarIdealWidth: CGFloat = 270
        public static let sidebarMaxWidth: CGFloat = 340
        public static let windowMinWidth: CGFloat = 640
        public static let windowMinHeight: CGFloat = 420
    #else
        public static let cardPadding: CGFloat = 14
        public static let controlRadius: CGFloat = 10
        public static let cardRadius: CGFloat = 14
        public static let bubbleRadius: CGFloat = 16
    #endif
}

/// The two sizes that differ because a finger and a pointer are not the same instrument.
///
/// A phone control has to be 44 points before it can be hit reliably, and everything in the
/// shared chat is sized from that. A pointer lands where it is aimed, so the same 44 points on a Mac
/// buys nothing and costs the composer a third of its height — it reads as a phone app blown
/// up. These two constants are the whole of the difference; every control in the chat takes
/// its size from them rather than from a literal, so shared chat controls cannot drift apart.

/// The smallest a control may be and still be easy to hit.
#if os(macOS)
    public let controlTarget: CGFloat = 28
#else
    public let controlTarget: CGFloat = 44
#endif

/// What the composer's text field pads itself by, above and below. Four points beyond the
/// control-centering minimum gives typed text room to breathe on both platforms.
#if os(macOS)
    public let composerPadding: CGFloat = 9
#else
    public let composerPadding: CGFloat = 15
#endif

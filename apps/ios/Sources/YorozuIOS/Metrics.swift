import CoreGraphics

public enum LayoutMetrics {
    public static let hair: CGFloat = 2
    public static let tight: CGFloat = 4
    public static let inner: CGFloat = 8
    public static let stack: CGFloat = 12
    public static let gutter: CGFloat = 16
    public static let section: CGFloat = 24
    public static let readingWidth: CGFloat = 700
    public static let composerWidth: CGFloat = 640
    public static let controlCircle: CGFloat = 32

    #if os(macOS)
        public static let cardRadius: CGFloat = 10
        public static let bubbleRadius: CGFloat = 10
        public static let noticeRadius: CGFloat = 12
        public static let sidebarMinWidth: CGFloat = 220
        public static let sidebarIdealWidth: CGFloat = 270
        public static let sidebarMaxWidth: CGFloat = 340
        public static let windowMinWidth: CGFloat = 640
        public static let windowMinHeight: CGFloat = 420
        public static let settingsWidth: CGFloat = 520
    #else
        public static let cardRadius: CGFloat = 14
        public static let bubbleRadius: CGFloat = 16
        public static let noticeRadius: CGFloat = 18
    #endif
}

#if os(macOS)
    public let controlTarget: CGFloat = 28
#else
    public let controlTarget: CGFloat = 44
#endif

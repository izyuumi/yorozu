#if os(macOS)
import AppKit
import SwiftUI

// The Mac client (#419) runs the phone's screens as they are. The few iOS-only names they use mean this on a Mac, so
// the screens carry no `#if` for them.

/// A Mac window has no navigation bar: the title is the window's or the column's, never large.
enum NavigationBarItem {
    enum TitleDisplayMode { case automatic, inline, large }
}

extension View {
    func navigationBarTitleDisplayMode(_: NavigationBarItem.TitleDisplayMode) -> some View { self }
}

extension ToolbarItemPlacement {
    /// The phone's bar edges, as the Mac toolbar's leading and trailing places.
    static var topBarLeading: Self { .navigation }
    static var topBarTrailing: Self { .primaryAction }
}

/// The phone's system backgrounds, as the Mac's.
extension NSColor {
    static var systemBackground: NSColor { .windowBackgroundColor }
    static var secondarySystemBackground: NSColor { .controlBackgroundColor }
}

/// The phone's Copy, as the Mac's general pasteboard.
@MainActor final class UIPasteboard {
    static let general = UIPasteboard()

    var string: String? {
        get { NSPasteboard.general.string(forType: .string) }
        set {
            NSPasteboard.general.clearContents()
            if let newValue { NSPasteboard.general.setString(newValue, forType: .string) }
        }
    }
}
#endif

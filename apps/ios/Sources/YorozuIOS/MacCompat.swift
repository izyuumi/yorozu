#if os(macOS)
import AppKit
import SwiftUI

enum NavigationBarItem {
    enum TitleDisplayMode { case automatic, inline, large }
}

extension View {
    func navigationBarTitleDisplayMode(_: NavigationBarItem.TitleDisplayMode) -> some View { self }
}

extension ToolbarItemPlacement {
    static var topBarLeading: Self { .navigation }
    static var topBarTrailing: Self { .primaryAction }
}

extension NSColor {
    static var systemBackground: NSColor { .windowBackgroundColor }
    static var secondarySystemBackground: NSColor { .controlBackgroundColor }
}

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

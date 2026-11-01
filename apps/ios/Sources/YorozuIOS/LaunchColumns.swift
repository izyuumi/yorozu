import SwiftUI

/// The split view's column visibility around a launch: the sidebar shows on a cold launch, and a requested
/// conversation (link, widget, notification, intent) is never covered by it.
enum LaunchColumns {
    static let initial = NavigationSplitViewVisibility.all

    /// After a requested open: a sidebar shown by `initial` hands over to the system, which keeps it beside the
    /// conversation where the width allows and hides it where it would overlay it. Other states stay as they are.
    static func afterRequestedOpen(_ columns: NavigationSplitViewVisibility) -> NavigationSplitViewVisibility {
        columns == .all ? .automatic : columns
    }
}

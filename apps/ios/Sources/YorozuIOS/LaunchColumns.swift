import SwiftUI

enum LaunchColumns {
    static let initial = NavigationSplitViewVisibility.all

    static func afterRequestedOpen(_ columns: NavigationSplitViewVisibility) -> NavigationSplitViewVisibility {
        columns == .all ? .automatic : columns
    }
}

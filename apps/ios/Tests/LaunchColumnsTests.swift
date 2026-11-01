import SwiftUI
import Testing

@Suite struct LaunchColumnsTests {
    @Test func coldLaunchShowsTheSidebar() {
        #expect(LaunchColumns.initial == .all)
    }

    @Test func requestedOpenHandsAShownSidebarToTheSystem() {
        #expect(LaunchColumns.afterRequestedOpen(.all) == .automatic)
    }

    @Test(arguments: [NavigationSplitViewVisibility.detailOnly, .automatic])
    func requestedOpenKeepsOtherStates(_ columns: NavigationSplitViewVisibility) {
        #expect(LaunchColumns.afterRequestedOpen(columns) == columns)
    }
}

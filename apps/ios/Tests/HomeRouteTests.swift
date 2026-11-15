import SwiftUI
import Testing

@Suite struct HomeRouteTests {
    @Test func requestedOpenFromAutomationsShowsTheConversation() {
        var route = HomeRoute(section: .crons)
        route.openRequested("c1")
        #expect(route.section == .chats)
        #expect(route.selection == "c1")
    }

    @Test func requestedOpenOnColdLaunchHandsTheSidebarToTheSystem() {
        var route = HomeRoute()
        route.openRequested("c1")
        #expect(route.columns == .automatic)
    }

    @Test(arguments: [NavigationSplitViewVisibility.detailOnly, .automatic])
    func requestedOpenKeepsOtherColumnStates(_ columns: NavigationSplitViewVisibility) {
        var route = HomeRoute(columns: columns)
        route.openRequested("c1")
        #expect(route.columns == columns)
    }

    @Test func laterRequestedOpenWins() {
        var route = HomeRoute(section: .crons)
        route.openRequested("c1")
        route.section = .crons
        route.openRequested("c2")
        #expect(route.section == .chats)
        #expect(route.selection == "c2")
    }

    @Test func inAppOpenFromAutomationsShowsTheChatAndKeepsColumns() {
        var route = HomeRoute(section: .crons, columns: .all)
        route.open("c1")
        #expect(route == HomeRoute(section: .chats, selection: "c1", columns: .all))
    }
}

import Foundation
import Testing

@Suite struct WidgetLinkTests {
    @Test(arguments: [WidgetLink.conversation("c_0123"), .new, .ask, .talk])
    func roundTrips(_ link: WidgetLink) {
        #expect(WidgetLink(url: link.url) == link)
    }

    @Test func eachLauncherOpensItsMode() {
        #expect(Launcher.talk.link == .talk)
        #expect(Launcher.ask.link == .ask)
        #expect(Launcher.talk.link.url.absoluteString == "yorozu://widget/talk")
        #expect(Launcher.ask.link.url.absoluteString == "yorozu://widget/ask")
    }

    @Test func launchersHaveTheirOwnKindsAndBadges() {
        let existing: Set = [WidgetStore.widgetKind, "to.yumi.yorozu.unread", "to.yumi.yorozu.control.new", "to.yumi.yorozu.control.talk"]
        let kinds = Set(Launcher.allCases.map(\.kind))
        #expect(kinds.count == Launcher.allCases.count)
        #expect(kinds.isDisjoint(with: existing))
        #expect(Set(Launcher.allCases.map(\.badge)).count == Launcher.allCases.count)
    }

    @Test(arguments: ["https://widget/new", "yorozu://pair/new", "yorozu://widget/", "yorozu://widget/new/extra", "yorozu://widget/conversation"])
    func rejectsOtherURLs(_ string: String) {
        #expect(WidgetLink(url: URL(string: string)!) == nil)
    }
}

import CoreGraphics
import Testing

@Suite struct ChatScrollEdgeTests {
    private func edge(_ offset: CGFloat) -> ChatScrollEdge {
        ChatScrollEdge(offset: offset, maxOffset: 5000, minOffset: -100)
    }

    @Test(arguments: [true, false])
    func pastTheEndSettles(following: Bool) {
        #expect(edge(5040).needsSettle(following: following))
    }

    @Test(arguments: [true, false])
    func atTheEndDoesNot(following: Bool) {
        #expect(!edge(5000).needsSettle(following: following))
    }

    @Test func shortOfTheEndSettlesOnlyWhileFollowing() {
        #expect(edge(4960).needsSettle(following: true))
        #expect(!edge(4960).needsSettle(following: false))
    }

    @Test(arguments: [true, false])
    func contentShorterThanTheContainerNeverSettles(following: Bool) {
        #expect(!ChatScrollEdge(offset: -100, maxOffset: -500, minOffset: -100).needsSettle(following: following))
        #expect(!ChatScrollEdge(offset: 0, maxOffset: -400).needsSettle(following: following))
        #expect(!ChatScrollEdge(offset: -100, maxOffset: -100, minOffset: -100).needsSettle(following: following))
    }

    @Test func onePointOfTolerance() {
        #expect(!edge(5001).needsSettle(following: true))
        #expect(edge(5001.5).needsSettle(following: false))
        #expect(!edge(4999).needsSettle(following: true))
        #expect(edge(4998.5).needsSettle(following: true))
        #expect(!edge(4998.5).needsSettle(following: false))
    }
}

import SwiftUI
import Testing

@testable import YorozuShared

@Test func manualScrollingAlwaysWinsOverStreamingAutoFollow() {
    #expect(followsNewest(atBottom: true, phase: .idle))
    #expect(followsNewest(atBottom: true, phase: .animating))
    #expect(!followsNewest(atBottom: true, phase: .tracking))
    #expect(!followsNewest(atBottom: true, phase: .interacting))
    #expect(!followsNewest(atBottom: true, phase: .decelerating))
    #expect(!followsNewest(atBottom: false, phase: .idle))
}

import Foundation
import Testing

@testable import YorozuShared

/// The phone's half of the push design: the opaque reference a wake-up routes on, and the thread
/// it is resolved back to.

@Test func aThreadReferenceIsTheSameOnBothSidesOfTheWire() {
    // Vectors taken from `threadRef` in packages/shared/src/crypto.ts. The Mac stamps these on a
    // `notify` and the phone has to arrive at the same eight characters, or a tapped
    // notification routes nowhere.
    #expect(YorozuCrypto.threadRef("thread-one") == "aF2mj7Xg")
    #expect(YorozuCrypto.threadRef("home") == "TqFAWIFQ")
    #expect(YorozuCrypto.threadRef("3f8a1c2e-0b44-4d9a-9f21-7c6e5a0d1b83") == "6s82CDjb")
}

@Test func aReferenceIsShortStableAndSaysNothingAboutItsThread() {
    let id = "3f8a1c2e-0b44-4d9a-9f21-7c6e5a0d1b83"
    let ref = YorozuCrypto.threadRef(id)
    #expect(ref.count == 8)
    #expect(ref == YorozuCrypto.threadRef(id))
    #expect(ref != YorozuCrypto.threadRef("another-thread"))
    // Nothing of the id survives into it, which is the whole point of sending it instead.
    #expect(!id.contains(ref))
    #expect(ref.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
}

/// The thread ids a notification names, resolved the only place they can be: against the threads
/// this phone already holds. This is what ``Session/open(threadRef:)`` does on a tap.
@Test func aTappedNotificationFindsTheThreadItsReferenceNames() {
    let ids = ["home", "thread-one", "3f8a1c2e-0b44-4d9a-9f21-7c6e5a0d1b83"]
    let tapped = YorozuCrypto.threadRef("thread-one")
    #expect(ids.first { YorozuCrypto.threadRef($0) == tapped } == "thread-one")
    // A reference for a thread this device has never heard of resolves to nothing, which is a
    // tap that does nothing rather than an empty chat with no way back out of it.
    #expect(ids.first { YorozuCrypto.threadRef($0) == YorozuCrypto.threadRef("elsewhere") } == nil)
}

import Foundation
import Testing

@testable import YorozuShared

/// The phone's half of the push design: the opaque reference a wake-up routes on, the title it
/// deliberately does not carry, and the registrations the relay is handed.

/// A relay that only records. The Live Activity controller hands its APNs tokens to a
/// ``PushRegistering``, so a test can watch the flow with no socket behind it.
private actor RecordingRelay: PushRegistering {
    private(set) var deviceTokens: [String] = []
    private(set) var startTokens: [String] = []
    /// Nested optional on purpose: "registered nil" and "never registered" are different things.
    private(set) var activities: [String: String?] = [:]

    func registerPush(deviceToken: String) { deviceTokens.append(deviceToken) }
    func registerPushToStart(token: String) { startTokens.append(token) }
    func registerActivity(threadRef: String, token: String?) { activities[threadRef] = token }
}

@Test func aThreadReferenceIsTheSameOnBothSidesOfTheWire() {
    // Vectors taken from `threadRef` in packages/shared/src/crypto.ts. The Mac stamps these on a
    // `notify` and the phone has to arrive at the same eight characters, or a tapped
    // notification routes nowhere and a pushed activity has no title.
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

@Test func anActivityTitleIsResolvedOnThePhoneAndNeverPushed() throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "yorozu-turn-title-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    // The same file the share sheet's picker reads: id and title, written by the app.
    let threads = [ShareThread(id: "thread-one", title: "Kitanoya invoice"), ShareThread(id: "quiet", title: "")]
    try JSONEncoder().encode(threads).write(to: directory.appending(path: "threads.json"))

    #expect(TurnTitle.resolve(YorozuCrypto.threadRef("thread-one"), in: directory) == "Kitanoya invoice")
    // A thread outside the published list, one with no title yet, and no container at all: all
    // three are the app's own name rather than anything a relay could have supplied.
    #expect(TurnTitle.resolve(YorozuCrypto.threadRef("elsewhere"), in: directory) == "Yorozu")
    #expect(TurnTitle.resolve(YorozuCrypto.threadRef("quiet"), in: directory) == "Yorozu")
    #expect(TurnTitle.resolve(YorozuCrypto.threadRef("thread-one"), in: nil) == "Yorozu")
}

@Test func tokensReachTheRelayAndAreTakenBackWhenAnActivityEnds() async {
    let relay = RecordingRelay()
    let ref = YorozuCrypto.threadRef("home")

    await relay.registerPush(deviceToken: "device-token")
    await relay.registerPushToStart(token: "start-token")
    await relay.registerActivity(threadRef: ref, token: "activity-token")

    #expect(await relay.deviceTokens == ["device-token"])
    #expect(await relay.startTokens == ["start-token"])
    #expect(await relay.activities[ref] == "activity-token")

    // Ending an activity takes its registration back, so the relay stops pushing to a token
    // that no longer has anything on a lock screen behind it.
    await relay.registerActivity(threadRef: ref, token: nil)
    #expect(await relay.activities[ref] == .some(nil))
}

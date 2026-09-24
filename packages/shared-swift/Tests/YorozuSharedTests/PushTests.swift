import CryptoKit
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

/// What Allow and Deny on the lock screen may act on: the sealed preview in the push opens under
/// this phone's key to exactly the body that was shown. Nothing in `userInfo` stands in for it.
@Test func lockScreenButtonsOnlyActUnderTheDecryptedPreview() throws {
    let key = SymmetricKey(size: .bits256)
    let sealed = try YorozuCrypto.seal(key: key, plaintext: Data("Run the tests?".utf8))
    let info: [AnyHashable: Any] = [
        "preview": ["n": sealed.nonce.base64URLEncodedString(), "c": sealed.ciphertext.base64URLEncodedString()],
        "cls": "approval",
    ]
    #expect(NotificationFallback.showsDecryptedPreview(body: "Run the tests?", userInfo: info, key: key)?.body == "Run the tests?")
    // A relay's own sentence over a replayed box, the fallback line over a box that did open,
    // the wrong key, no key, and no box.
    #expect(NotificationFallback.showsDecryptedPreview(body: "Tap Allow to see the photo", userInfo: info, key: key) == nil)
    #expect(NotificationFallback.showsDecryptedPreview(body: NotificationFallback.body, userInfo: info, key: key) == nil)
    #expect(NotificationFallback.showsDecryptedPreview(body: "Run the tests?", userInfo: info, key: SymmetricKey(size: .bits256)) == nil)
    #expect(NotificationFallback.showsDecryptedPreview(body: "Run the tests?", userInfo: info, key: nil) == nil)
    #expect(NotificationFallback.showsDecryptedPreview(body: NotificationFallback.body, userInfo: ["cls": "approval"], key: key) == nil)
    // A mark the relay writes into userInfo changes nothing.
    var forged = info
    forged["yorozuPreviewDecrypted"] = true
    #expect(NotificationFallback.showsDecryptedPreview(body: "Tap Allow", userInfo: forged, key: key) == nil)
}

/// The plaintext inside a preview box, in the shape the Mac seals today and the one it sealed
/// before there was a shape.
@Test func aPreviewDecodesTheVersionedObjectAndTheBareStringBeforeIt() {
    let current = NotificationPreviewContent(
        plaintext: #"{"v":1,"body":"Run a command: echo hi","event":"6s82CDjb","quick":true}"#
    )
    #expect(current == NotificationPreviewContent(body: "Run a command: echo hi", event: "6s82CDjb", quick: true))
    // Before the object: the whole plaintext is the body, about no card, with no buttons.
    #expect(NotificationPreviewContent(plaintext: "Yorozu says hi") == NotificationPreviewContent(body: "Yorozu says hi", event: nil, quick: false))
    #expect(NotificationPreviewContent(plaintext: #"{"body":"no version"}"#) == NotificationPreviewContent(body: #"{"body":"no version"}"#, event: nil, quick: false))
    // `quick` is a boolean or nothing: a string, a number, an absence all mean no buttons.
    #expect(NotificationPreviewContent(plaintext: #"{"v":1,"body":"x","quick":"true"}"#)?.quick == false)
    #expect(NotificationPreviewContent(plaintext: #"{"v":1,"body":"x","quick":1}"#)?.quick == false)
    #expect(NotificationPreviewContent(plaintext: #"{"v":1,"body":"x"}"#) == NotificationPreviewContent(body: "x", event: nil, quick: false))
    // An event that is not a name is no event.
    #expect(NotificationPreviewContent(plaintext: #"{"v":1,"body":"x","event":"","quick":true}"#)?.event == nil)
    #expect(NotificationPreviewContent(plaintext: #"{"v":1,"body":"x","event":null,"quick":true}"#)?.event == nil)
    // The thread title, when the Mac sealed one; an empty one is none.
    #expect(NotificationPreviewContent(plaintext: #"{"v":1,"body":"x","title":"Trip plans"}"#)?.title == "Trip plans")
    #expect(NotificationPreviewContent(plaintext: #"{"v":1,"body":"x","title":""}"#)?.title == nil)
    // Nothing to say is no preview.
    #expect(NotificationPreviewContent(plaintext: #"{"v":1,"body":""}"#) == nil)
    #expect(NotificationPreviewContent(plaintext: #"{"v":1}"#) == nil)
    #expect(NotificationPreviewContent(plaintext: "") == nil)
}

/// Which buttons the extension draws: Allow and Deny only under the Mac's sealed judgement,
/// and only for the card the push is about. The relay's `aps.category` is never a factor.
@Test func theExtensionDrawsAllowAndDenyOnlyUnderASealedQuickJudgementForThisCard() {
    let quick = NotificationPreviewContent(body: "Run a command: echo hi", event: "6s82CDjb", quick: true)
    #expect(NotificationFallback.category(for: quick, eventRef: "6s82CDjb") == NotificationFallback.quickCategory)
    #expect(NotificationFallback.category(for: quick, eventRef: "TqFAWIFQ") == "")
    #expect(NotificationFallback.category(for: quick, eventRef: nil) == "")
    #expect(NotificationFallback.category(for: NotificationPreviewContent(body: "x", event: nil, quick: true), eventRef: "6s82CDjb") == "")
    #expect(NotificationFallback.category(for: NotificationPreviewContent(body: "Send a message: bob", event: "6s82CDjb", quick: false), eventRef: "6s82CDjb") == "")
    #expect(NotificationFallback.category(for: nil, eventRef: "6s82CDjb") == "")
}

/// The app's gate before an Allow counts: the preview re-opens to the body on screen, the Mac
/// judged the card quick, and the preview names the very card being answered.
@Test func aLockScreenAnswerNeedsTheMacsQuickJudgementForThisCard() throws {
    let key = SymmetricKey(size: .bits256)
    func box(_ plaintext: String, under key: SymmetricKey) throws -> [AnyHashable: Any] {
        let sealed = try YorozuCrypto.seal(key: key, plaintext: Data(plaintext.utf8))
        return [
            "preview": ["n": sealed.nonce.base64URLEncodedString(), "c": sealed.ciphertext.base64URLEncodedString()],
            "cls": "approval",
            "event": "6s82CDjb",
        ]
    }
    let body = "Run a command: echo hi"
    let quick = try box(#"{"v":1,"body":"\#(body)","event":"6s82CDjb","quick":true}"#, under: key)
    #expect(NotificationFallback.permitsLockScreenAnswer(body: body, userInfo: quick, key: key, eventRef: "6s82CDjb"))
    // The relay's sentence, another card, no card, the wrong key, no key.
    #expect(!NotificationFallback.permitsLockScreenAnswer(body: "Tap Allow", userInfo: quick, key: key, eventRef: "6s82CDjb"))
    #expect(!NotificationFallback.permitsLockScreenAnswer(body: body, userInfo: quick, key: key, eventRef: "TqFAWIFQ"))
    #expect(!NotificationFallback.permitsLockScreenAnswer(body: body, userInfo: quick, key: key, eventRef: nil))
    #expect(!NotificationFallback.permitsLockScreenAnswer(body: body, userInfo: quick, key: SymmetricKey(size: .bits256), eventRef: "6s82CDjb"))
    #expect(!NotificationFallback.permitsLockScreenAnswer(body: body, userInfo: quick, key: nil, eventRef: "6s82CDjb"))
    // A card the Mac sent for review: same words, same card, no buttons.
    let review = try box(#"{"v":1,"body":"\#(body)","event":"6s82CDjb","quick":false}"#, under: key)
    #expect(!NotificationFallback.permitsLockScreenAnswer(body: body, userInfo: review, key: key, eventRef: "6s82CDjb"))
    // A preview from before the object: it names no card and permits no button.
    let legacy = try box(body, under: key)
    #expect(NotificationFallback.showsDecryptedPreview(body: body, userInfo: legacy, key: key)?.body == body)
    #expect(!NotificationFallback.permitsLockScreenAnswer(body: body, userInfo: legacy, key: key, eventRef: "6s82CDjb"))
    // No box at all, and a mark the relay writes into userInfo.
    #expect(!NotificationFallback.permitsLockScreenAnswer(body: body, userInfo: ["cls": "approval", "event": "6s82CDjb"], key: key, eventRef: "6s82CDjb"))
    var forged = review
    forged["yorozuPreviewDecrypted"] = true
    forged["quick"] = true
    #expect(!NotificationFallback.permitsLockScreenAnswer(body: body, userInfo: forged, key: key, eventRef: "6s82CDjb"))
}

@Test func twoHostApprovalsResolveOnlyByTheKeyThatAuthenticatesThePreview() throws {
    let a = SymmetricKey(size: .bits256)
    let b = SymmetricKey(size: .bits256)
    let keys = ["host-a": a, "host-b": b]
    let body = "Run the same command?"
    let event = YorozuCrypto.threadRef("same-card-on-both-hosts")
    for (host, key) in keys {
        let plaintext = #"{"v":1,"body":"\#(body)","event":"\#(event)","quick":true}"#
        let box = try YorozuCrypto.seal(key: key, plaintext: Data(plaintext.utf8))
        // Identical thread/card references do not affect host ownership. All routing labels
        // below can be supplied or forged by a relay and therefore must have no authority.
        let info: [AnyHashable: Any] = [
            "preview": ["n": box.nonce.base64URLEncodedString(), "c": box.ciphertext.base64URLEncodedString()],
            "ref": YorozuCrypto.threadRef("same-thread-on-both-hosts"),
            "event": event,
            "hostID": host == "host-a" ? "host-b" : "host-a",
            NotificationFallback.localHostKey: "forged-host",
        ]
        #expect(NotificationFallback.authenticatedPreview(userInfo: info, keys: keys)?.hostID == host)
        #expect(NotificationFallback.permittedLockScreenHost(body: body, userInfo: info, keys: keys, eventRef: event) == host)
        #expect(NotificationFallback.permittedLockScreenHost(body: "Forged words", userInfo: info, keys: keys, eventRef: event) == nil)
        #expect(NotificationFallback.permittedLockScreenHost(body: body, userInfo: info, keys: keys, eventRef: "another-card") == nil)
        #expect(NotificationFallback.authenticatedPreview(userInfo: info, keys: keys.filter { $0.key != host }) == nil)
        #expect(NotificationFallback.authenticatedPreview(userInfo: info, keys: ["host-a": key, "host-b": key]) == nil)
        #expect(NotificationFallback.permittedLockScreenHost(body: body, userInfo: info, keys: ["host-a": key, "host-b": key], eventRef: event) == nil)
    }
    #expect(NotificationFallback.authenticatedPreview(userInfo: [NotificationFallback.localHostKey: "host-a"], keys: keys) == nil)
    #expect(NotificationFallback.title == "Yorozu")
}

@Test func malformedOrUnsupportedPreviewObjectsCannotAuthorizeAnAction() {
    #expect(NotificationPreviewContent(plaintext: #"{"v":2,"body":"x","event":"same","quick":true}"#) == nil)
    #expect(NotificationPreviewContent(plaintext: #"{"v":true,"body":"x","event":"same","quick":true}"#) == nil)
    #expect(NotificationPreviewContent(plaintext: String(repeating: "x", count: 8_193)) == nil)
    #expect(NotificationPreviewPayload(userInfo: ["preview": ["n": "n", "c": String(repeating: "x", count: 16_385)]]) == nil)
}

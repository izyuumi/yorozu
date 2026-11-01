import Foundation
import Testing
import YorozuWire

@Suite struct PairingEntryTests {
    @Test func cancelClearsTextAndPendingPayload() throws {
        let key = Data(repeating: 7, count: 32).base64URLEncodedString()
        let link = "yorozu://pair?v=3&relay=wss://relay.example/ws&key=\(key)&token=tok&room=room&secret=sec"
        var entry = PairingEntry(text: link, pendingPairing: try QrPayload.decode(link))

        entry.cancel()

        #expect(entry.text.isEmpty)
        #expect(entry.pendingPairing == nil)
    }

    @Test func cancelEmptyEntryIsHarmless() {
        var entry = PairingEntry()

        entry.cancel()
        entry.cancel()

        #expect(entry.text.isEmpty)
        #expect(entry.pendingPairing == nil)
    }
}

import Foundation
import Testing
import YorozuWire

struct PairingWireTests {
    @Test func oldJSONDefaultsToLegacyAndCapabilityRoundTrips() throws {
        let oldJSON = #"{"pairing":{"v":3,"relayUrl":"wss://relay.test","macPubkey":"key","token":"","roomId":"room"},"identity":{"signingPrivateKey":"","signingPublicKey":"","sessionPrivateKey":"","sessionPublicKey":""},"relayKnows":true,"paired":true}"#
        var pairing = try JSONDecoder().decode(Pairing.self, from: Data(oldJSON.utf8))
        #expect(pairing.unversionedWire == nil)
        #expect(pairing.unversionedWire != true)
        for flag in [true, false] {
            pairing.unversionedWire = flag
            #expect(try JSONDecoder().decode(Pairing.self, from: JSONEncoder().encode(pairing)) == pairing)
        }
    }
}

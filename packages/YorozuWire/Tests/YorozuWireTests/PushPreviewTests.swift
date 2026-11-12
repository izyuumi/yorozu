import CryptoKit
import Foundation
import Testing
@testable import YorozuWire

struct PushPreviewTests {
    struct Fixture: Decodable {
        struct Preview: Decodable { let b, c, e, t, v: String }
        let hostStaticPub, deviceStaticPriv, key, n, c: String
        let preview: Preview
    }

    /// The box in the fixture is sealed by the plugin's `sealPreview` (push-preview.test.ts pins it).
    @Test func opensPluginSealedPreview() throws {
        let url = try #require(Bundle.module.url(forResource: "push-preview", withExtension: "json", subdirectory: "Fixtures"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        let key = try PushPreview.key(
            myPriv: try #require(Data(base64URLEncoded: fixture.deviceStaticPriv)),
            theirPub: try #require(Data(base64URLEncoded: fixture.hostStaticPub)))
        #expect(key.withUnsafeBytes { Data($0) } == Data(base64URLEncoded: fixture.key))

        let userInfo: [AnyHashable: Any] = ["aps": ["mutable-content": 1], "preview": ["n": fixture.n, "c": fixture.c]]
        let preview = try #require(PushPreview.open(userInfo: userInfo, key: key))
        #expect(preview == PushPreview(cls: fixture.preview.c, event: fixture.preview.e, body: fixture.preview.b,
                                       title: fixture.preview.t, convId: fixture.preview.v))
        #expect(preview.cls == "reply")
        #expect(preview.body == "今日の予定は a/b です")

        #expect(PushPreview.open(userInfo: userInfo, key: SymmetricKey(data: Data(repeating: 9, count: 32))) == nil)
    }
}

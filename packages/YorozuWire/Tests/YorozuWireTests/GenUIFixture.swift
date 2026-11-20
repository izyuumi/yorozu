import Foundation
import Testing
@testable import YorozuWire

enum GenUIFixture {
    static func event(_ name: String, file: String = #filePath) throws -> WireEvent {
        let repo = (0..<5).reduce(URL(fileURLWithPath: file)) { url, _ in url.deletingLastPathComponent() }
        let url = repo.appending(path: "plugins/openclaw-yorozu/test/fixtures/genui-wire.json")
        let fixture = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
        return try JSONDecoder().decode(WireEvent.self, from: Data(try #require(fixture[name]).utf8))
    }
}

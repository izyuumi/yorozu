import Foundation
import Testing
@testable import YorozuWire

/// The plugin's card events as it puts them in a sealed box: one copy, in the plugin's tree
/// (`plugins/openclaw-yorozu/test/fixtures/genui-wire.json`, pinned by `test/presentations.test.ts`).
enum GenUIFixture {
    static func event(_ name: String, file: String = #filePath) throws -> WireEvent {
        let repo = (0..<5).reduce(URL(fileURLWithPath: file)) { url, _ in url.deletingLastPathComponent() }
        let url = repo.appending(path: "plugins/openclaw-yorozu/test/fixtures/genui-wire.json")
        let fixture = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
        return try JSONDecoder().decode(WireEvent.self, from: Data(try #require(fixture[name]).utf8))
    }
}

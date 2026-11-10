import Foundation
import Testing
@testable import YorozuWire

/// A known kind whose data breaks a limit decodes as `.unknown`, never as the event and never as a thrown error.
struct WireEventLimitTests {
    let conv = "6f1c2a3b-4d5e-4f60-8a7b-9c0d1e2f3a4b"
    let msg = "0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d"
    let file = "1b2c3d4e-5f60-4a7b-8c9d-0e1f2a3b4c5d"

    func decode(_ json: String) throws -> WireEvent {
        try JSONDecoder().decode(WireEvent.self, from: Data(json.utf8))
    }

    func isUnknown(_ event: WireEvent, _ kind: String) -> Bool {
        if case .unknown(let found, let data) = event { return found == kind && data != nil }
        return false
    }

    func reaction(_ emoji: String) throws -> WireEvent {
        let text = String(decoding: try JSONEncoder().encode(emoji), as: UTF8.self)
        return try decode("""
            {"kind":"reaction","data":{"convId":"\(conv)","messageId":"\(msg)","emoji":\(text)}}
            """)
    }

    func upload(index: Int, count: Int, id: String? = nil) throws -> WireEvent {
        try decode("""
            {"kind":"upload","data":{"attachmentId":"\(id ?? file)","name":"a.txt","mime":"text/plain","size":3,
             "index":\(index),"count":\(count),"data":"YWJj"}}
            """)
    }

    func chunk(id: String, index: Int = 0, count: Int = 1) throws -> WireEvent {
        try decode("""
            {"kind":"chunk","data":{"attachmentId":"\(id)","index":\(index),"count":\(count),"data":"YWJj"}}
            """)
    }

    @Test func reactionEmojiLength() throws {
        #expect(isUnknown(try reaction(""), "reaction"))
        // The limit counts UTF-16 units, so 👍 is two.
        let longest = String(repeating: "👍", count: Reaction.maxEmoji / 2)
        #expect(longest.utf16.count == Reaction.maxEmoji)
        #expect(try reaction(longest) == .reaction(Reaction(convId: conv, messageId: msg, emoji: longest)))
        #expect(isUnknown(try reaction(longest + "a"), "reaction"))
        #expect(isUnknown(try reaction(longest + "👍"), "reaction"))
        #expect(isUnknown(try reaction(String(repeating: "a", count: Reaction.maxEmoji + 1)), "reaction"))
    }

    @Test func uploadIndexMustBeBelowCount() throws {
        #expect(try upload(index: 1, count: 2)
            == .upload(Upload(attachmentId: file, name: "a.txt", mime: "text/plain", size: 3, index: 1, count: 2, data: "YWJj")))
        #expect(isUnknown(try upload(index: 2, count: 2), "upload"))
        #expect(isUnknown(try upload(index: 3, count: 2), "upload"))
        #expect(isUnknown(try upload(index: 0, count: 0), "upload"))
        #expect(isUnknown(try upload(index: -1, count: 2), "upload"))
        #expect(isUnknown(try upload(index: 0, count: 1, id: "not-a-uuid"), "upload"))
    }

    @Test func chunkIdMustBeAUUID() throws {
        #expect(try chunk(id: file) == .chunk(Chunk(attachmentId: file, index: 0, count: 1, data: "YWJj")))
        let bad = ["", "not-a-uuid", file.uppercased(), String(file.dropLast()), file + "0",
            file.replacingOccurrences(of: "-", with: "_"), "../" + String(file.dropFirst(3))]
        for id in bad {
            #expect(isUnknown(try chunk(id: id), "chunk"), "\(id)")
        }
        #expect(isUnknown(try chunk(id: file, index: 1, count: 1), "chunk"))
    }

    @Test func refusedEventKeepsItsData() throws {
        let event = try reaction("")
        #expect(event == .unknown(kind: "reaction",
            data: .object(["convId": .string(conv), "messageId": .string(msg), "emoji": .string("")])))
        #expect(event.kind == "reaction")
    }
}

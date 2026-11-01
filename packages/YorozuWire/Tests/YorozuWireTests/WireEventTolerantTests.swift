import Foundation
import Testing
@testable import YorozuWire

/// Tolerant readers (OWNER_DECISIONS.md, Versioning rules): unknown kinds, fields and enum values never fail a decode.
struct WireEventTolerantTests {
    let conv = "6f1c2a3b-4d5e-4f60-8a7b-9c0d1e2f3a4b"
    let msg = "0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d"

    func decode(_ json: String) throws -> WireEvent {
        try JSONDecoder().decode(WireEvent.self, from: Data(json.utf8))
    }

    @Test func unknownFieldsAreIgnored() throws {
        let event = try decode("""
            {"kind":"reply","extra":1,"data":{"convId":"\(conv)","messageId":"\(msg)","text":"hi","ts":1,"future":{"a":[1]}}}
            """)
        #expect(event == .reply(Reply(convId: conv, messageId: msg, text: "hi", ts: 1)))
        let peer = try decode("""
            {"kind":"peer_info","data":{"protocolMin":3,"protocolMax":3,"app":"yorozu","capabilities":["resume","someday"],"x":true}}
            """)
        guard case .peerInfo(let info) = peer else { Issue.record("not peer_info: \(peer)"); return }
        #expect(info.capabilities == ["resume", "someday"])
    }

    @Test func unknownKindIsUnknown() throws {
        let event = try decode(#"{"kind":"someday","data":{"a":1}}"#)
        guard case .unknown(let kind, let data) = event else { Issue.record("not unknown: \(event)"); return }
        #expect(kind == "someday")
        #expect(data != nil)
        #expect(try decode(#"{"kind":"someday"}"#) == .unknown(kind: "someday", data: nil))
    }

    @Test func unknownReactionAuthorReadsAsAbsent() throws {
        let event = try decode("""
            {"kind":"reaction","data":{"convId":"\(conv)","messageId":"\(msg)","emoji":"👍","by":"someone"}}
            """)
        #expect(event == .reaction(Reaction(convId: conv, messageId: msg, emoji: "👍")))
        let known = try decode("""
            {"kind":"reaction","data":{"convId":"\(conv)","messageId":"\(msg)","emoji":"👍","by":"agent","remove":true}}
            """)
        guard case .reaction(let reaction) = known else { Issue.record("not reaction: \(known)"); return }
        #expect(reaction.by == .agent && reaction.remove == true)
    }

    @Test func unknownHistoryValuesDropOnlyTheirItem() throws {
        let event = try decode("""
            {"kind":"history","data":{"convId":"\(conv)","more":false,"rev":1,"items":[
              {"kind":"someday","id":"\(msg)","seq":1,"ts":1},
              {"kind":"tools","id":"\(msg)","seq":2,"ts":2,"tools":[
                {"callId":"a","name":"n","status":"paused"},
                {"callId":"b","name":"n","status":"done","extra":1}]},
              {"kind":"agent","id":"\(msg)","seq":3,"ts":3,"text":"hi","future":true}]}}
            """)
        guard case .history(let page) = event else { Issue.record("not history: \(event)"); return }
        #expect(page.items.map(\.kind) == [.tools, .agent])
        #expect(page.items[0].tools?.map(\.callId) == ["b"])
        #expect(page.items[1].text == "hi")
    }

    @Test func unknownJobKindsAndErrorCodesStillDecode() throws {
        let error = try decode(#"{"kind":"error","data":{"code":"someday","message":"m"}}"#)
        #expect(error == .error(ErrorInfo(code: "someday", message: "m")))
        let summary = try decode("""
            {"kind":"conv_list","data":{"conversations":[{"convId":"\(conv)","updatedAt":1,"rev":1,"mood":"new"},{"convId":1}]}}
            """)
        #expect(summary == .convList(ConvList(conversations: [ConvSummary(convId: conv, updatedAt: 1, rev: 1)])))
    }

    @Test func directCapabilityIsNamed() {
        #expect(Direct.capability == "direct")
    }
}

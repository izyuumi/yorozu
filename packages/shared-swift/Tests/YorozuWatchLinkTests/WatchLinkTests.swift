import Foundation
import Testing

@testable import YorozuWatchLink

@Test func aRequestSurvivesTheDictionaryItTravelsIn() throws {
    let request = WatchRequest(kind: .send, host: "h", thread: "t", text: "meet at noon")

    #expect(WatchLink.decode(WatchRequest.self, from: try WatchLink.encode(request)) == request)
    #expect(WatchLink.decode(WatchRequest.self, from: [:]) == nil)
    #expect(WatchLink.decode(WatchRequest.self, from: [WatchLink.payloadKey: Data("{}".utf8)]) == nil)
    #expect(WatchLink.decode(WatchRequest.self, from: [WatchLink.payloadKey: "not data"]) == nil)
}

@Test func thePhoneRefusesEmptyAndOversizedReplies() {
    func send(_ text: String?) -> WatchRequest {
        WatchRequest(kind: .send, host: "h", thread: "t", text: text)
    }
    #expect(send("  hello \n").sendableText == "hello")
    #expect(send(nil).sendableText == nil)
    #expect(send(" \n ").sendableText == nil)
    #expect(send(String(repeating: "a", count: WatchLink.maxTextLength + 1)).sendableText == nil)
    #expect(WatchRequest(kind: .messages, host: "h", thread: "t", text: "hi").sendableText == nil)
}

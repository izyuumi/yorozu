import Foundation
import Testing
@testable import YorozuWire

struct JSONValueTests {
    func decode(_ json: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    }

    @Test func nestedValuesRoundTrip() throws {
        let value: JSONValue = .object([
            "null": .null,
            "yes": .bool(true),
            "no": .bool(false),
            "one": .number(1),
            "zero": .number(0),
            "half": .number(-0.5),
            "text": .string("1"),
            "empty": .object([:]),
            "list": .array([.null, .bool(false), .number(2), .string(""), .array([]), .object(["deep": .array([.object(["x": .null])])])]),
        ])
        let data = try JSONEncoder().encode(value)
        #expect(try JSONDecoder().decode(JSONValue.self, from: data) == value)
        #expect(try decode("""
            {"null":null,"yes":true,"no":false,"one":1,"zero":0,"half":-0.5,"text":"1","empty":{},
             "list":[null,false,2,"",[],{"deep":[{"x":null}]}]}
            """) == value)
    }

    @Test func boolsAndNumbersStayApart() throws {
        #expect(try decode("[true,1,false,0,1.0]") == .array([.bool(true), .number(1), .bool(false), .number(0), .number(1)]))
        #expect(try decode("true") == .bool(true))
        #expect(try decode("1") == .number(1))
        #expect(try decode("0") == .number(0))
        #expect(JSONValue.bool(true) != .number(1))
        // And they are written back as what they were.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let value = JSONValue.object(["b": .bool(true), "f": .bool(false), "n": .number(1), "z": .number(0)])
        #expect(String(decoding: try encoder.encode(value), as: UTF8.self) == #"{"b":true,"f":false,"n":1,"z":0}"#)
    }

    @Test func scalarsDecodeAsTheirOwnCase() throws {
        #expect(try decode("null") == .null)
        #expect(try decode(#""true""#) == .string("true"))
        #expect(try decode("[]") == .array([]))
        #expect(try decode("{}") == .object([:]))
    }

    /// An unknown event keeps its data as a `JSONValue`, with the same split.
    @Test func unknownEventDataKeepsBoolsAndNumbers() throws {
        let json = #"{"kind":"someday","data":{"on":true,"n":1,"list":[0,false]}}"#
        let event = try JSONDecoder().decode(WireEvent.self, from: Data(json.utf8))
        #expect(event == .unknown(kind: "someday",
            data: .object(["on": .bool(true), "n": .number(1), "list": .array([.number(0), .bool(false)])])))
    }
}

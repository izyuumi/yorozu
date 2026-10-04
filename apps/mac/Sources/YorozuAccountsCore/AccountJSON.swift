import Foundation

public enum AccountError: String, Error, Codable, Sendable {
    case invalid, unsupported, conflict, unknown
}

public enum AccountJSON: Codable, Equatable, Sendable {
    case object([String: AccountJSON]), array([AccountJSON]), string(String), number(Double), bool(Bool), null

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let v = try? value.decode(Bool.self) { self = .bool(v) }
        else if let v = try? value.decode(String.self) { self = .string(v) }
        else if let v = try? value.decode(Double.self) { self = .number(v) }
        else if let v = try? value.decode([AccountJSON].self) { self = .array(v) }
        else { self = .object(try value.decode([String: AccountJSON].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .object(let v): try value.encode(v)
        case .array(let v): try value.encode(v)
        case .string(let v): try value.encode(v)
        case .number(let v): try value.encode(v)
        case .bool(let v): try value.encode(v)
        case .null: try value.encodeNil()
        }
    }
    public var object: [String: AccountJSON]? { if case .object(let v) = self { v } else { nil } }
    public var string: String? { if case .string(let v) = self { v } else { nil } }
    public var array: [AccountJSON]? { if case .array(let v) = self { v } else { nil } }
    public var integer: Int? {
        guard case .number(let v) = self, v.isFinite, v >= 0, v <= 9_007_199_254_740_991, v.rounded() == v else { return nil }
        return Int(v)
    }
    public func encoded() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
    public static func decode(_ data: Data, limit: Int) throws -> AccountJSON {
        guard !data.isEmpty, data.count <= limit else { throw AccountError.invalid }
        // Foundation decoders collapse duplicate object keys. Refuse them before decoding.
        var scanner = JSONKeyScanner(bytes: Array(data))
        do {
            try scanner.value(depth: 0); scanner.space()
            guard scanner.index == scanner.bytes.count else { throw AccountError.invalid }
            return try JSONDecoder().decode(AccountJSON.self, from: data)
        } catch { throw AccountError.invalid }
    }
}

private struct JSONKeyScanner {
    let bytes: [UInt8]
    var index = 0
    var tokens = 0
    mutating func space() { while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 } }
    mutating func consume(_ byte: UInt8) throws {
        space(); guard index < bytes.count, bytes[index] == byte else { throw AccountError.invalid }; index += 1
    }
    mutating func string() throws -> String {
        space(); let start = index; try consume(34)
        while index < bytes.count {
            let byte = bytes[index]; index += 1
            if byte == 34 { return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index])) }
            if byte == 92 { guard index < bytes.count else { throw AccountError.invalid }; index += 1 }
        }
        throw AccountError.invalid
    }
    mutating func value(depth: Int) throws {
        tokens += 1; guard depth <= 16, tokens <= 65_536 else { throw AccountError.invalid }
        space(); guard index < bytes.count else { throw AccountError.invalid }
        switch bytes[index] {
        case 123:
            index += 1; space(); if index < bytes.count, bytes[index] == 125 { index += 1; return }
            var keys = Set<String>()
            while true {
                let key = try string(); guard keys.insert(key).inserted else { throw AccountError.invalid }
                try consume(58); try value(depth: depth + 1); space()
                guard index < bytes.count else { throw AccountError.invalid }
                if bytes[index] == 125 { index += 1; return }; try consume(44)
            }
        case 91:
            index += 1; space(); if index < bytes.count, bytes[index] == 93 { index += 1; return }
            while true {
                try value(depth: depth + 1); space(); guard index < bytes.count else { throw AccountError.invalid }
                if bytes[index] == 93 { index += 1; return }; try consume(44)
            }
        case 34: _ = try string()
        default:
            let start = index
            while index < bytes.count && ![9, 10, 13, 32, 44, 93, 125].contains(bytes[index]) { index += 1 }
            guard index > start else { throw AccountError.invalid }
        }
    }
}

func accountFields(_ object: [String: AccountJSON], required: Set<String>, optional: Set<String> = []) -> Bool {
    required.isSubset(of: Set(object.keys)) && Set(object.keys).isSubset(of: required.union(optional))
        && !object.values.contains(.null)
}
func accountPattern(_ value: String?, _ pattern: String) -> Bool {
    guard let value else { return false }
    return value.range(of: pattern, options: .regularExpression) == value.startIndex..<value.endIndex
}
func accountBinding(_ value: String?) -> Bool { accountPattern(value, #"^[A-Za-z0-9_.:-]{1,128}$"#) }
func accountClient(_ value: String?) -> Bool { accountPattern(value, #"^oaiapp_[A-Za-z0-9_-]{1,128}$"#) }
func accountSecret(_ value: String?) -> Bool { accountPattern(value, #"^[A-Za-z0-9._~-]{16,32768}$"#) }

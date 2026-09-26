import Foundation

/// Claims authenticated by this host's encrypted channel. Versions are diagnostic only.
public struct PeerInfoData: Codable, Equatable, Sendable {
    public var appVersion: String
    public var protocolMin: Int
    public var protocolMax: Int
    public var capabilities: [String]
    public var requiredCapabilities: [String]
    public var computerName: String?

    public init(appVersion: String, protocolMin: Int = 1, protocolMax: Int = 1,
        capabilities: [String] = ["peer-info", "host-name", "channel-sequence", "admission-status-v1", "admission-expiry-v1", "exact-stop-v1", "offline-approval-v1"],
        requiredCapabilities: [String] = ["channel-sequence"], computerName: String? = nil) {
        self.appVersion = appVersion
        self.protocolMin = protocolMin
        self.protocolMax = protocolMax
        self.capabilities = capabilities
        self.requiredCapabilities = requiredCapabilities
        self.computerName = computerName
    }

    public static var local: PeerInfoData {
        let version = Bundle.main.object(forInfoDictionaryKey: "YorozuVersionLabel") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        return PeerInfoData(appVersion: boundedText(version, maxBytes: 64) ? version : "unknown",
            capabilities: ["peer-info", "host-name", "channel-sequence", "admission-status-v1", "admission-expiry-v1", "exact-stop-v1", "offline-approval-v1"],
            requiredCapabilities: ["channel-sequence", "admission-status-v1", "admission-expiry-v1", "exact-stop-v1", "offline-approval-v1"])
    }

    private enum CodingKeys: String, CodingKey {
        case appVersion, protocolMin, protocolMax, capabilities, requiredCapabilities, computerName
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        appVersion = try c.decode(String.self, forKey: .appVersion)
        protocolMin = try c.decode(Int.self, forKey: .protocolMin)
        protocolMax = try c.decode(Int.self, forKey: .protocolMax)
        capabilities = try c.decode([String].self, forKey: .capabilities)
        requiredCapabilities = try c.decode([String].self, forKey: .requiredCapabilities)
        computerName = c.contains(.computerName) ? try c.decode(String.self, forKey: .computerName) : nil
        guard isValid else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid peer information")) }
    }

    public var isValid: Bool {
        Self.boundedText(appVersion, maxBytes: 64) && protocolMin >= 1 && protocolMax <= 65_535 && protocolMin <= protocolMax
            && Self.validCapabilities(capabilities) && Self.validCapabilities(requiredCapabilities)
            && Set(requiredCapabilities).isSubset(of: Set(capabilities))
            && (computerName.map { Self.boundedText($0, maxBytes: 256) } ?? true)
    }

    private static func boundedText(_ value: String, maxBytes: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maxBytes && !value.unicodeScalars.contains { $0.value < 32 || $0.value == 127 }
    }

    private static func validCapabilities(_ value: [String]) -> Bool {
        value.count <= 32 && Set(value).count == value.count && value.allSatisfy {
            boundedText($0, maxBytes: 48) && $0.range(of: "^[a-z][a-z0-9-]{0,47}$", options: .regularExpression) != nil
        }
    }

    public func compatibility(with peer: PeerInfoData?) -> PeerCompatibility {
        guard let peer else { return .legacy }
        guard isValid, peer.isValid else { return .updateRequired("Invalid peer information. Update Yorozu on this device and its host Mac.") }
        let version = min(protocolMax, peer.protocolMax)
        guard version >= max(protocolMin, peer.protocolMin) else {
            return .updateRequired("Update Yorozu on this device and its host Mac: protocol versions do not overlap.")
        }
        guard Set(requiredCapabilities).isSubset(of: Set(peer.capabilities)),
            Set(peer.requiredCapabilities).isSubset(of: Set(capabilities)) else {
            return .updateRequired("Update Yorozu on this device and its host Mac: a required security or protocol capability is unavailable.")
        }
        return .compatible(version: version, capabilities: capabilities.filter { peer.capabilities.contains($0) })
    }
}

public enum PeerCompatibility: Equatable, Sendable {
    case legacy
    case compatible(version: Int, capabilities: [String])
    case updateRequired(String)
}

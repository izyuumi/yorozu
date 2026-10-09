import Foundation
import Network

/// Claims authenticated by this host's encrypted channel. Versions are diagnostic only.
public struct PeerInfoData: Codable, Equatable, Sendable {
    public var appVersion: String
    public var protocolMin: Int
    public var protocolMax: Int
    public var capabilities: [String]
    public var requiredCapabilities: [String]
    public var computerName: String?
    /// Host only: where the phone may dial the Mac directly (`direct-v1`). Absent from a phone's claim
    /// and from a host with its listener off; see docs/ios-relay-contract.md, "Direct path".
    public var directCandidates: [DirectCandidate]?

    public init(appVersion: String, protocolMin: Int = 1, protocolMax: Int = 1,
        capabilities: [String] = ["peer-info", "host-name", "channel-sequence", "admission-status-v1", "admission-expiry-v1", "exact-stop-v1", "turn-state-v1", "steer-v1", "model-select-v1", "thread-rewind-v1", "offline-approval-v1", "thread-search-v1", "attachment-chunks-v1", "update-drain-v1", "open-agents-v1"],
        requiredCapabilities: [String] = ["channel-sequence"], computerName: String? = nil,
        directCandidates: [DirectCandidate]? = nil) {
        self.appVersion = appVersion
        self.protocolMin = protocolMin
        self.protocolMax = protocolMax
        self.capabilities = capabilities
        self.requiredCapabilities = requiredCapabilities
        self.computerName = computerName
        self.directCandidates = directCandidates
    }

    public static var local: PeerInfoData {
        let version = Bundle.main.object(forInfoDictionaryKey: "YorozuVersionLabel") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        // Protocol 2 = contract 0.7: a 0.6.x peer (protocol 1) no longer overlaps. A feature added within 0.7
        // adds a capability here; a breaking change raises the protocol (docs/ios-relay-contract.md, "Versioning").
        return PeerInfoData(appVersion: boundedText(version, maxBytes: 64) ? version : "unknown",
            protocolMin: 2, protocolMax: 2, capabilities: ["peer-info", "host-name", "channel-sequence", "yorozu-v2", DirectCandidate.capability],
            requiredCapabilities: ["channel-sequence", "yorozu-v2"])
    }

    private enum CodingKeys: String, CodingKey {
        case appVersion, protocolMin, protocolMax, capabilities, requiredCapabilities, computerName, directCandidates
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        appVersion = try c.decode(String.self, forKey: .appVersion)
        protocolMin = try c.decode(Int.self, forKey: .protocolMin)
        protocolMax = try c.decode(Int.self, forKey: .protocolMax)
        capabilities = try c.decode([String].self, forKey: .capabilities)
        requiredCapabilities = try c.decode([String].self, forKey: .requiredCapabilities)
        computerName = c.contains(.computerName) ? try c.decode(String.self, forKey: .computerName) : nil
        directCandidates = c.contains(.directCandidates) ? try c.decode([DirectCandidate].self, forKey: .directCandidates) : nil
        guard isValid else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid peer information")) }
    }

    public var isValid: Bool {
        Self.boundedText(appVersion, maxBytes: 64) && protocolMin >= 1 && protocolMax <= 65_535 && protocolMin <= protocolMax
            && Self.validCapabilities(capabilities) && Self.validCapabilities(requiredCapabilities)
            && Set(requiredCapabilities).isSubset(of: Set(capabilities))
            && (computerName.map { Self.boundedText($0, maxBytes: 256) } ?? true)
            && (directCandidates.map { $0.count <= DirectCandidate.maxCount && $0.allSatisfy(\.isValid) } ?? true)
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
        guard isValid, peer.isValid else { return .updateRequired(String(localized: "Invalid peer information. Update Yorozu on this device and its host Mac.")) }
        let version = min(protocolMax, peer.protocolMax)
        guard version >= max(protocolMin, peer.protocolMin) else {
            // Reasons are read on the phone: the Mac sends its own as `peerInfoError`.
            #if os(macOS)
            let phoneOutdated = peer.protocolMax < protocolMin
            #else
            let phoneOutdated = protocolMax < peer.protocolMin
            #endif
            return .updateRequired(phoneOutdated
                ? String(localized: "Update Yorozu on this iPhone to talk to this Mac.")
                : String(localized: "Update Yorozu on the Mac to talk to this iPhone."))
        }
        guard Set(requiredCapabilities).isSubset(of: Set(peer.capabilities)),
            Set(peer.requiredCapabilities).isSubset(of: Set(capabilities)) else {
            return .updateRequired(String(localized: "Update Yorozu on this device and its host Mac: a required security or protocol capability is unavailable."))
        }
        return .compatible(version: version, capabilities: capabilities.filter { peer.capabilities.contains($0) })
    }
}

public enum PeerCompatibility: Equatable, Sendable {
    case legacy
    case compatible(version: Int, capabilities: [String])
    case updateRequired(String)
}

/// One address the Mac's direct listener answers on, as the host advertises it inside its sealed peer
/// info. `lan`: a private Wi-Fi/Ethernet address; `vpn`: a private address on a `utun` interface
/// (Tailscale, WireGuard). The host is an IP literal, never a name.
public struct DirectCandidate: Codable, Sendable, Equatable, Hashable {
    public enum Kind: String, Codable, Sendable { case lan, vpn }

    public var host: String
    public var port: Int
    public var kind: Kind

    public init(host: String, port: Int, kind: Kind) {
        self.host = host
        self.port = port
        self.kind = kind
    }

    /// The peer-info capability that says a side speaks the direct path.
    public static let capability = "direct-v1"
    /// The most candidates one peer info may carry.
    public static let maxCount = 8

    /// An IPv4 or IPv6 literal without a zone, and a port in 1–65535.
    public var isValid: Bool {
        (1...65_535).contains(port) && host.utf8.count <= 45 && !host.contains("%")
            && (IPv4Address(host) != nil || IPv6Address(host) != nil)
    }

    /// Tailscale's ranges (100.64.0.0/10, fd7a:115c:a1e0::/48): the only addresses diagnostics call "Tailscale".
    public var isTailscale: Bool {
        if let v4 = IPv4Address(host) {
            let b = [UInt8](v4.rawValue)
            return b[0] == 100 && (b[1] & 0xC0) == 64
        }
        if let v6 = IPv6Address(host) {
            let b = [UInt8](v6.rawValue)
            return b[0] == 0xfd && b[1] == 0x7a && b[2] == 0x11 && b[3] == 0x5c && b[4] == 0xa1 && b[5] == 0xe0
        }
        return false
    }
}

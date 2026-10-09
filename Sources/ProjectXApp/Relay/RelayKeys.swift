import Foundation
import ProjectXCore
import Security
import YorozuWire

/// The Mac's relay identity: Ed25519 (the relay room and frame signatures) and X25519 (the channel
/// keys). The same four keys a phone holds, so `PhoneIdentity` carries them. Kept in its own
/// Keychain service, never v1's keys: the relay pins a room to the first key that registers and drops
/// an older Mac socket on a newer register, so sharing a room with the v1 sidecar would be a fight.
enum RelayKeys {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "to.yumi.yorozu.relay", kSecAttrAccount as String: "host"]
    }
    /// Losing these means a new room: every phone has to pair again. So a Keychain that cannot be read
    /// stops the host rather than minting keys over the old ones.
    static func loadOrCreate() throws -> PhoneIdentity {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?; let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data { return try JSONDecoder().decode(PhoneIdentity.self, from: data) }
        guard status == errSecItemNotFound else { throw ProjectError.blocked("Yorozu could not read its relay keys from the Keychain. Unlock the login Keychain; Yorozu tries again every 30 seconds.") }
        let keys = PhoneIdentity.generate()
        q = query; q[kSecValueData as String] = try JSONEncoder().encode(keys); q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { throw ProjectError.blocked("Yorozu could not save its relay keys in the Keychain.") }
        return keys
    }
}

/// One paired phone, as `relay-devices.json` keeps it. The counter lives next to the keys it counts
/// for: a device forgotten here takes its counter with it, and one kept keeps counting.
struct RelayDevice: Codable, Sendable, Identifiable, Equatable {
    /// X25519, base64url: what its boxes are sealed for, and its identity here.
    var pub: String
    /// Ed25519, base64url: what the relay knows it by, and what `devices` and `revoke` name.
    var signingPub: String
    var pairedAt: Date
    var counter = ChannelCounter()
    /// The phone's model ("iPhone 17 Pro"), from the `computerName` of its peer-info claim.
    var name: String?
    /// What the user renamed it to on this Mac; wins over `name`.
    var label: String?
    /// When its last authenticated frame arrived.
    var lastSeen: Date?
    /// Its last `.compatible` peer-info result, so a known phone is served from its first frame after a
    /// relaunch or a `hello`, before it claims again. A new claim replaces it; nil when none is on file.
    var compatible: Compatible?
    var id: String { pub }

    struct Compatible: Codable, Sendable, Equatable {
        var version: Int
        var capabilities: [String]
        /// `PeerInfoData.local.protocolMax` when it was computed; a host on another version ignores it.
        var hostProtocol: Int
    }

    /// The stored result as the host serves it, or nil when there is none for this host's protocol.
    var served: PeerCompatibility? {
        guard let compatible, compatible.hostProtocol == PeerInfoData.local.protocolMax else { return nil }
        return .compatible(version: compatible.version, capabilities: compatible.capabilities)
    }
}

/// One paired phone as Settings shows it.
struct RelayDeviceStatus: Sendable, Identifiable, Equatable {
    var pub: String
    var name: String?
    var label: String?
    var pairedAt: Date
    /// Has an authenticated session on the host's current relay connection.
    var online: Bool
    var lastSeen: Date?
    /// How its direct link reaches this Mac; nil while it is on the relay route.
    var route: DirectKind?
    /// Its last direct-path problem on this run.
    var directError: String?
    var id: String { pub }
    var displayName: String { label ?? name ?? "iPhone" }
}

/// `relay-devices.json`: written 0600 to a temp file, flushed, then renamed over the old one (v1's
/// `writeFileAtomic`), so a crash leaves the old list or the new one and never half of either.
enum RelayDeviceFile {
    static func load(_ url: URL) throws -> [RelayDevice] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        // Something on disk that cannot be read is not "no devices": counters starting over would make
        // every box a replay to the phone, so the host stops instead.
        do { return try JSONDecoder().decode([RelayDevice].self, from: Data(contentsOf: url)) }
        catch { throw ProjectError.blocked("relay-devices.json is unreadable; the relay host was not started.") }
    }
    static func save(_ devices: [RelayDevice], to url: URL) throws {
        let data = try JSONEncoder().encode(devices); let tmp = url.path + ".tmp"
        let fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else { throw ProjectError.blocked("Could not write relay-devices.json.") }
        let written = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) == $0.count } && fsync(fd) == 0
        close(fd)
        guard written, rename(tmp, url.path) == 0 else { unlink(tmp); throw ProjectError.blocked("Could not write relay-devices.json.") }
    }
}

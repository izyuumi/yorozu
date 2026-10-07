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
        guard status == errSecItemNotFound else { throw ProjectError.blocked("Yorozu could not read its relay keys from the Keychain. Unlock the login Keychain and restart.") }
        let keys = PhoneIdentity.generate()
        q = query; q[kSecValueData as String] = try JSONEncoder().encode(keys); q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { throw ProjectError.blocked("Yorozu could not save its relay keys in the Keychain.") }
        return keys
    }
}

/// One paired phone, as `relay-devices.json` keeps it. The counter lives next to the keys it counts
/// for: a device forgotten here takes its counter with it, and one kept keeps counting.
struct RelayDevice: Codable, Sendable, Identifiable {
    /// X25519, base64url: what its boxes are sealed for, and its identity here.
    var pub: String
    /// Ed25519, base64url: what the relay knows it by, and what `devices` and `revoke` name.
    var signingPub: String
    var pairedAt: Date
    var counter = ChannelCounter()
    var id: String { pub }
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

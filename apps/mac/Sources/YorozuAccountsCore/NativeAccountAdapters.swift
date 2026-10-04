import AppKit
import CryptoKit
import Darwin
import Foundation
import LocalAuthentication
import Security

/// One fixed Data Protection Keychain item. No migration, legacy lookup, UI, or file fallback.
@MainActor public final class KeychainAccountBackend: AccountProtectedBackend {
    public static let service = "to.yumi.yorozu.accounts.snapshot.v1"
    public static let account = "Yorozu"
    public init() {}
    private func query(reading: Bool) -> [CFString: Any] {
        let context = LAContext(); context.interactionNotAllowed = true
        var query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: Self.service,
            kSecAttrAccount: Self.account, kSecUseDataProtectionKeychain: true, kSecAttrSynchronizable: false,
            kSecUseAuthenticationContext: context]
        // The SDK permits UI-Skip only for CopyMatching. Writes use the non-interactive context.
        if reading { query[kSecUseAuthenticationUI] = kSecUseAuthenticationUISkip }
        return query
    }
    public func available() -> Bool {
        var query = query(reading: true); query[kSecMatchLimit] = kSecMatchLimitOne
        query[kSecReturnAttributes] = true
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess || status == errSecItemNotFound
    }
    public func read() throws -> Data? {
        var query = query(reading: true); query[kSecMatchLimit] = kSecMatchLimitOne; query[kSecReturnData] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data, data.count <= AccountSnapshot.maximumBytes else { throw AccountError.unknown }; return data
    }
    public func create(_ data: Data) throws {
        guard data.count <= AccountSnapshot.maximumBytes else { throw AccountError.invalid }
        var attributes = query(reading: false); attributes[kSecValueData] = data
        attributes[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem { throw AccountError.conflict }; try check(status)
    }
    public func replace(_ data: Data) throws {
        guard data.count <= AccountSnapshot.maximumBytes else { throw AccountError.invalid }
        let attributes: [CFString: Any] = [kSecValueData: data]
        try check(SecItemUpdate(query(reading: false) as CFDictionary, attributes as CFDictionary))
    }
    private func check(_ status: OSStatus) throws {
        guard status != errSecSuccess else { return }
        switch status {
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecMissingEntitlement, errSecNotAvailable: throw AccountError.unsupported
        default: throw AccountError.unknown
        }
    }
}

/// Lock files contain no snapshot or token data. Held descriptors release on close/EOF/process exit.
@MainActor public final class POSIXAccountLocks: AccountLockBackend {
    public init() {}
    public func acquireGlobal() throws -> () -> Void { try acquire("snapshot-cas.lock") }
    public func acquireAccount(_ binding: String) throws -> () -> Void {
        guard accountBinding(binding) else { throw AccountError.invalid }
        let digest = SHA256.hash(data: Data(binding.utf8)).map { String(format: "%02x", $0) }.joined()
        return try acquire("account-\(digest).lock")
    }
    private func directory() throws -> Int32 {
        // No environment variable or RPC input can select the lock root.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var parent = Darwin.open(home, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw AccountError.unsupported }
        do {
            try validateDirectory(parent, privateMode: false)
            for (component, privateMode) in [("Library", false), ("Application Support", false), ("Yorozu", false), ("ProtectedAccounts", true), ("locks", true)] {
                if mkdirat(parent, component, 0o700) != 0 && errno != EEXIST { throw AccountError.unsupported }
                let child = openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else { throw AccountError.unsupported }
                do { try validateDirectory(child, privateMode: privateMode) }
                catch { Darwin.close(child); throw error }
                Darwin.close(parent); parent = child
            }
            return parent
        } catch { Darwin.close(parent); throw error }
    }
    private func validateDirectory(_ fd: Int32, privateMode: Bool) throws {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFDIR,
            info.st_mode & 0o022 == 0, !privateMode || info.st_mode & 0o7777 == 0o700 else { throw AccountError.unsupported }
    }
    private func acquire(_ name: String) throws -> () -> Void {
        let parent = try directory(); defer { Darwin.close(parent) }
        let fd = openat(parent, name, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw AccountError.unsupported }
        do {
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
                info.st_mode & 0o7777 == 0o600, info.st_nlink == 1, info.st_size == 0 else { throw AccountError.unsupported }
            if flock(fd, LOCK_EX | LOCK_NB) != 0 {
                if errno == EWOULDBLOCK || errno == EAGAIN { throw AccountError.conflict }; throw AccountError.unknown
            }
            var linked = stat()
            guard fstatat(parent, name, &linked, AT_SYMLINK_NOFOLLOW) == 0, linked.st_ino == info.st_ino,
                linked.st_dev == info.st_dev, linked.st_nlink == 1, linked.st_uid == getuid(), linked.st_mode & 0o7777 == 0o600 else { throw AccountError.unsupported }
            var released = false
            return { if !released { released = true; _ = flock(fd, LOCK_UN); Darwin.close(fd) } }
        } catch { Darwin.close(fd); throw error }
    }
}

@MainActor public final class WorkspaceAccountBrowser: AccountBrowser {
    public init() {}
    public func open(_ url: URL) -> Bool { NSWorkspace.shared.open(url) }
}

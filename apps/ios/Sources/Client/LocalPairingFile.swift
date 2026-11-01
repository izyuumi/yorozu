#if os(macOS)
import Darwin
import Foundation
import YorozuWire

/// The plugin's local pairing file (#532 `local-pair`), read only when it is this user's private regular file and names
/// the room the loopback probe proved. The trust boundary is "can read this user's files".
enum LocalPairingFile {
    static let maxBytes = 4096

    enum Failure: Error, Equatable {
        case notAbsolute, unreadable, notPrivate, tooLarge, malformed, wrongHost
    }

    /// The pairing in the file at `path`, for the host whose probe proved `room`.
    static func read(path: String, room: String) throws -> QrPayload {
        guard path.hasPrefix("/") else { throw Failure.notAbsolute }
        var named = stat()
        guard lstat(path, &named) == 0 else { throw Failure.unreadable }
        guard named.st_mode & S_IFMT == S_IFREG else { throw Failure.notPrivate }
        // O_NOFOLLOW and the same inode: nothing swapped in a symlink or another file since the lstat.
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.unreadable }
        defer { close(fd) }
        var opened = stat()
        guard fstat(fd, &opened) == 0 else { throw Failure.unreadable }
        guard opened.st_mode & S_IFMT == S_IFREG, opened.st_dev == named.st_dev, opened.st_ino == named.st_ino,
              opened.st_uid == getuid(), opened.st_mode & 0o077 == 0 else { throw Failure.notPrivate }
        guard opened.st_size <= maxBytes else { throw Failure.tooLarge }
        var buffer = [UInt8](repeating: 0, count: maxBytes + 1)
        let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        guard count >= 0 else { throw Failure.unreadable }
        guard count <= maxBytes else { throw Failure.tooLarge }
        guard let text = String(bytes: buffer.prefix(count), encoding: .utf8),
              let payload = try? QrPayload.decode(text), payload.v == 3, payload.secret != nil,
              Data(base64URLEncoded: payload.macPubkey)?.count == 32 else { throw Failure.malformed }
        guard payload.roomId == room else { throw Failure.wrongHost }
        return payload
    }
}
#endif

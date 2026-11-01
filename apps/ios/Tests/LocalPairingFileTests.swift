import CryptoKit
import Foundation
import Testing
import YorozuWire

/// The local pairing file (#532 `local-pair`): read only when it is this user's private regular file for the proven room.
@Suite struct LocalPairingFileTests {
    let dir: URL
    let room = Data(SHA256.hash(data: Data(repeating: 7, count: 32))).base64URLEncodedString()

    init() throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "yorozu-localpair-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func link(room: String) throws -> String {
        try QrPayload(v: 3, relayUrl: "wss://relay.example/ws", macPubkey: Data(repeating: 1, count: 32).base64URLEncodedString(),
            token: "tok", roomId: room, secret: Data(repeating: 2, count: 32).base64URLEncodedString()).encoded()
    }

    func file(_ contents: String, mode: Int = 0o600, name: String = "local-pairing") throws -> String {
        let path = dir.appending(path: name).path
        #expect(FileManager.default.createFile(atPath: path, contents: Data(contents.utf8), attributes: [.posixPermissions: mode]))
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
        return path
    }

    func failure(_ path: String, room: String? = nil) -> LocalPairingFile.Failure? {
        do {
            _ = try LocalPairingFile.read(path: path, room: room ?? self.room)
            return nil
        } catch {
            return error as? LocalPairingFile.Failure
        }
    }

    @Test func aPrivateFileForTheProvenRoomReads() throws {
        let payload = try LocalPairingFile.read(path: try file(link(room: room) + "\n"), room: room)
        #expect(payload.roomId == room)
        #expect(payload.secret == Data(repeating: 2, count: 32).base64URLEncodedString())
    }

    @Test func anotherRoomIsRefused() throws {
        let other = Data(SHA256.hash(data: Data(repeating: 8, count: 32))).base64URLEncodedString()
        #expect(failure(try file(link(room: other))) == .wrongHost)
    }

    @Test func groupOrOtherBitsAreRefused() throws {
        for (index, mode) in [0o644, 0o640, 0o604, 0o660].enumerated() {
            #expect(failure(try file(link(room: room), mode: mode, name: "f\(index)")) == .notPrivate, "\(String(mode, radix: 8))")
        }
    }

    @Test func aSymlinkIsRefusedEvenToAGoodFile() throws {
        let target = try file(link(room: room), name: "target")
        let path = dir.appending(path: "local-pairing").path
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: target)
        #expect(failure(path) == .notPrivate)
    }

    @Test func aDirectoryIsRefused() throws {
        let path = dir.appending(path: "sub").path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        #expect(failure(path) == .notPrivate)
    }

    @Test func garbageAnEmptyFileAndOtherLinksAreRefused() throws {
        #expect(failure(try file("not a link", name: "a")) == .malformed)
        #expect(failure(try file("", name: "b")) == .malformed)
        #expect(failure(try file("https://yorozu.yumi.to/add#v=1&box=x", name: "c")) == .malformed)
        let noSecret = try QrPayload(v: 3, relayUrl: "wss://relay.example/ws", macPubkey: Data(repeating: 1, count: 32).base64URLEncodedString(),
            token: "tok", roomId: room).encoded()
        #expect(failure(try file(noSecret, name: "d")) == .malformed)
    }

    @Test func aLargeFileIsRefused() throws {
        #expect(failure(try file(String(repeating: "x", count: LocalPairingFile.maxBytes + 1))) == .tooLarge)
    }

    @Test func aRelativeOrMissingPathIsRefused() {
        #expect(failure("local-pairing") == .notAbsolute)
        #expect(failure(dir.appending(path: "missing").path) == .unreadable)
    }
}

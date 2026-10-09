import Foundation
import Network
import YorozuWire

/// How a direct link or an advertised address reaches this Mac, for diagnostics.
enum DirectKind: Sendable, Equatable {
    case lan, vpn, tailscale
    var wire: DirectCandidate.Kind { self == .lan ? .lan : .vpn }
}

/// The Mac's interface addresses, read with `getifaddrs`.
enum DirectInterfaces {
    struct Address { var name: String; var bytes: [UInt8]; var text: String }

    static func addresses() -> [Address] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var out: [Address] = []
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0, let sa = entry.pointee.ifa_addr else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            var bytes: [UInt8]
            switch Int32(sa.pointee.sa_family) {
            case AF_INET: bytes = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { withUnsafeBytes(of: $0.pointee.sin_addr) { Array($0) } }
            case AF_INET6: bytes = sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { withUnsafeBytes(of: $0.pointee.sin6_addr) { Array($0) } }
            default: continue
            }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length = socklen_t(sa.pointee.sa_family == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
            guard getnameinfo(sa, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            // A scoped IPv6 literal ("fe80::1%en0") is never advertised; the scope is dropped for the rest.
            let text = String(cString: host).split(separator: "%").first.map(String.init) ?? ""
            out.append(Address(name: name, bytes: bytes, text: text))
        }
        return out
    }

    /// Wi-Fi/Ethernet (`en*`) is LAN and `utun*` is VPN; loopback, `awdl`, `llw`, `bridge` and the rest are nil.
    static func kind(interface name: String, bytes: [UInt8]) -> DirectKind? {
        if name.hasPrefix("en") { return .lan }
        if name.hasPrefix("utun") { return isTailscale(bytes) ? .tailscale : .vpn }
        return nil
    }

    /// The candidates `hostInfo` advertises: private Wi-Fi/Ethernet addresses as `lan`, private `utun` addresses
    /// (RFC 1918, 100.64.0.0/10, ULA) as `vpn`; never loopback or link-local. LAN first, IPv4 first, at most 8.
    static func candidates(port: Int) -> [(candidate: DirectCandidate, kind: DirectKind)] {
        var seen = Set<String>()
        return addresses().compactMap { address -> (DirectCandidate, DirectKind, Int)? in
            guard let kind = kind(interface: address.name, bytes: address.bytes), !isLinkLocal(address.bytes),
                  kind == .lan ? isPrivate(address.bytes, cgnat: false) : isPrivate(address.bytes, cgnat: true),
                  seen.insert(address.text).inserted else { return nil }
            return (DirectCandidate(host: address.text, port: port, kind: kind.wire), kind, (kind == .lan ? 0 : 2) + (address.bytes.count == 4 ? 0 : 1))
        }.sorted { $0.2 < $1.2 }.prefix(DirectCandidate.maxCount).map { ($0.0, $0.1) }
    }

    /// The interface a connection arrived on, from its local address; nil when it is none of the Mac's
    /// addresses or not on an allowed interface. IPv4-mapped IPv6 counts as the IPv4 address.
    static func kind(local endpoint: NWEndpoint?) -> DirectKind? {
        guard case .hostPort(let host, _)? = endpoint else { return nil }
        let bytes: [UInt8]
        switch host {
        case .ipv4(let a): bytes = Array(a.rawValue)
        case .ipv6(let a): bytes = a.asIPv4.map { Array($0.rawValue) } ?? Array(a.rawValue)
        default: return nil
        }
        guard !isLoopback(bytes), let address = addresses().first(where: { $0.bytes == bytes }) else { return nil }
        return kind(interface: address.name, bytes: bytes)
    }

    static func isLoopback(_ b: [UInt8]) -> Bool { b.count == 4 ? b[0] == 127 : b == [UInt8](repeating: 0, count: 15) + [1] }
    static func isLinkLocal(_ b: [UInt8]) -> Bool { b.count == 4 ? b[0] == 169 && b[1] == 254 : b[0] == 0xfe && b[1] & 0xc0 == 0x80 }
    /// RFC 1918 (and 100.64.0.0/10 when `cgnat`) for IPv4; ULA fc00::/7 for IPv6.
    static func isPrivate(_ b: [UInt8], cgnat: Bool) -> Bool {
        guard b.count == 4 else { return b[0] & 0xfe == 0xfc }
        return b[0] == 10 || (b[0] == 172 && b[1] & 0xf0 == 16) || (b[0] == 192 && b[1] == 168) || (cgnat && b[0] == 100 && b[1] & 0xc0 == 64)
    }
    /// Tailscale's ranges: 100.64.0.0/10 and fd7a:115c:a1e0::/48.
    static func isTailscale(_ b: [UInt8]) -> Bool {
        b.count == 4 ? b[0] == 100 && b[1] & 0xc0 == 64 : Array(b.prefix(6)) == [0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0]
    }
}

extension NWConnection {
    /// One whole WebSocket message: its bytes, or nil once the peer closed. Throws on a failed connection.
    func receiveText() async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            receiveMessage { data, context, _, error in
                if let error { return continuation.resume(throwing: error) }
                let ws = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
                if ws?.opcode == .close || (data == nil && context?.isFinal == true) { return continuation.resume(returning: nil) }
                continuation.resume(returning: data ?? Data())
            }
        }
    }

    func sendText(_ data: Data) {
        let context = NWConnection.ContentContext(identifier: "text", metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
        send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }

    /// A close frame with `code`, then the connection is cancelled.
    func close(_ code: DirectCloseCode) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
        metadata.closeCode = .privateCode(UInt16(code.rawValue))
        let context = NWConnection.ContentContext(identifier: "close", metadata: [metadata])
        send(content: nil, contentContext: context, isComplete: true, completion: .contentProcessed { [weak self] _ in self?.cancel() })
        // A peer that never takes the close frame is cut off anyway.
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in self?.cancel() }
    }
}

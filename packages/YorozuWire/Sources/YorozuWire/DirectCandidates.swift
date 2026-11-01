import CryptoKit
import Darwin
import Foundation
import Network
import os
import dnssd

/// Addresses, URLs and the Bonjour tag of the direct path (#532).
extension Direct {
    /// The 4 or 16 bytes of an IPv4 or IPv6 literal; nil for anything else, a zone (`%en0`) included.
    static func ipBytes(_ text: String) -> [UInt8]? {
        guard !text.contains("%") else { return nil }
        var v4 = in_addr()
        if inet_pton(AF_INET, text, &v4) == 1 { return withUnsafeBytes(of: &v4) { Array($0) } }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, text, &v6) == 1 { return withUnsafeBytes(of: &v6) { Array($0) } }
        return nil
    }

    /// Whether `address` lies in `network`/`prefix`; both of one family.
    static func contains(_ network: [UInt8], prefix: Int, _ address: [UInt8]) -> Bool {
        guard network.count == address.count, (0...network.count * 8).contains(prefix) else { return false }
        let whole = prefix / 8, bits = prefix % 8
        guard network.prefix(whole) == address.prefix(whole) else { return false }
        guard bits > 0 else { return true }
        let mask = UInt8(truncatingIfNeeded: 0xFF << (8 - bits))
        return network[whole] & mask == address[whole] & mask
    }

    /// A DNS name of letters, digits and hyphens, without a trailing dot; nil if it is not one.
    static func hostName(_ text: String) -> String? {
        let name = text.hasSuffix(".") ? String(text.dropLast()) : text
        guard !name.isEmpty, name.utf8.count <= 253,
              name.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ label in
                  !label.isEmpty && label.count <= 63 && label.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-") }
              }) else { return nil }
        return name
    }

    /// `ws://host:port`, an IPv6 literal bracketed.
    static func url(host: String, port: Int) -> URL? {
        URL(string: "ws://\(host.contains(":") ? "[\(host)]" : host):\(port)")
    }

    public static func bonjourEpoch(_ date: Date) -> Int64 {
        Int64(floor(date.timeIntervalSince1970 / 3600))
    }

    /// Rotates the instance name and TXT `t` hourly to limit discovery tracking.
    public static func bonjourTag(hostKey: Data, epoch: Int64) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data("yorozu-bonjour:\(epoch)".utf8), using: SymmetricKey(data: hostKey))
        return Data(mac).prefix(9).base64URLEncodedString()
    }

    static func bonjourTags(hostKey: Data, at date: Date) -> Set<String> {
        let epoch = bonjourEpoch(date)
        return Set((epoch - 1...epoch + 1).map { bonjourTag(hostKey: hostKey, epoch: $0) })
    }
}

public enum DirectRoute: String, Sendable, Equatable, CaseIterable {
    case wifi, localNetwork, tailscale, thisMac, relay

    public static func of(_ url: URL?, network: String) -> DirectRoute {
        guard let url else { return .relay }
        let host = (url.host ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        if ["127.0.0.1", "::1", "localhost"].contains(host) { return .thisMac }
        if DirectCandidates.isTailscale(host) || host.hasSuffix(".ts.net") { return .tailscale }
        return network == "wifi" ? .wifi : .localNetwork
    }
}

/// One address of a local network interface, from `getifaddrs`.
struct LocalInterface: Equatable, Sendable {
    var name: String
    /// Without a zone.
    var address: String
    var prefix: Int
    /// Up and running.
    var up: Bool

    init(name: String, address: String, prefix: Int, up: Bool = true) {
        self.name = name
        self.address = address
        self.prefix = prefix
        self.up = up
    }

    /// A VPN's tunnel: where Tailscale's addresses live.
    var isVPN: Bool { ["utun", "ipsec", "ppp"].contains { name.hasPrefix($0) } }

    static func current() -> [LocalInterface] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        return sequence(first: first, next: { $0.pointee.ifa_next }).compactMap { pointer in
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, let text = numeric(address) else { return nil }
            let flags = Int32(entry.ifa_flags)
            let mask = entry.ifa_netmask.flatMap { maskBytes($0, family: address.pointee.sa_family) } ?? []
            return LocalInterface(name: String(cString: entry.ifa_name), address: text,
                prefix: mask.reduce(0) { $0 + $1.nonzeroBitCount }, up: flags & IFF_UP != 0 && flags & IFF_RUNNING != 0)
        }
    }

    private static func numeric(_ address: UnsafeMutablePointer<sockaddr>) -> String? {
        let family = Int32(address.pointee.sa_family)
        guard family == AF_INET || family == AF_INET6 else { return nil }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0
        else { return nil }
        let text = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return text.split(separator: "%", maxSplits: 1).first.map(String.init)
    }

    /// The mask's address bytes; Darwin may hand a netmask sockaddr shorter than its type, so only `sa_len` bytes are read.
    private static func maskBytes(_ mask: UnsafeMutablePointer<sockaddr>, family: sa_family_t) -> [UInt8]? {
        let length = Int(mask.pointee.sa_len)
        let raw = UnsafeRawPointer(mask)
        switch Int32(family) {
        case AF_INET:
            let offset = MemoryLayout<sockaddr_in>.offset(of: \.sin_addr)!
            return (0..<4).map { offset + $0 < length ? raw.load(fromByteOffset: offset + $0, as: UInt8.self) : 0 }
        case AF_INET6:
            let offset = MemoryLayout<sockaddr_in6>.offset(of: \.sin6_addr)!
            return (0..<16).map { offset + $0 < length ? raw.load(fromByteOffset: offset + $0, as: UInt8.self) : 0 }
        default:
            return nil
        }
    }
}

/// The owner's go-ahead for LAN candidates and Bonjour (#532); the Local Network explainer sets it. Loopback and
/// Tailscale do not need it.
public enum LocalNetwork {
    public static let key = "yorozu.localNetwork.allowed"

    public static var allowed: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    public static var denied: Bool {
        get { UserDefaults.standard.bool(forKey: "yorozu.localNetwork.denied") }
        set { UserDefaults.standard.set(newValue, forKey: "yorozu.localNetwork.denied") }
    }

    public static var explained: Bool {
        get { UserDefaults.standard.bool(forKey: "yorozu.localNetwork.explained") }
        set { UserDefaults.standard.set(newValue, forKey: "yorozu.localNetwork.explained") }
    }

    public static var usable: Bool { allowed && !denied }

    static func policyDenied(_ error: NWError) -> Bool {
        if case .dns(let code) = error { return code == Int32(kDNSServiceErr_PolicyDenied) }
        return false
    }

    /// Waits past ready: a policy denial can arrive after the browser starts.
    public static func refresh(timeout: Duration = .seconds(3)) async -> Bool {
        let browser = NWBrowser(for: .bonjour(type: Bonjour.type, domain: "local."), using: .tcp)
        let (states, continuation) = AsyncStream<NWBrowser.State>.makeStream()
        browser.stateUpdateHandler = { continuation.yield($0) }
        continuation.onTermination = { _ in browser.cancel() }
        let timer = Task {
            try? await Task.sleep(for: timeout)
            continuation.finish()
        }
        defer { timer.cancel(); continuation.finish(); browser.cancel() }
        browser.start(queue: DispatchQueue(label: "to.yumi.yorozu.localNetwork"))
        var ready = false
        for await state in states {
            switch state {
            case .ready: ready = true
            case .waiting(let error), .failed(let error):
                if policyDenied(error) { denied = true; return true }
                ready = false
                if case .failed = state { return denied }
            default: break
            }
        }
        if ready && !Task.isCancelled { denied = false }
        return denied
    }
}

/// The latest `direct_hints` per pairing room, as JSON in user defaults.
public struct DirectHintStore: Sendable {
    /// nil: the standard defaults; tests name a suite of their own.
    private let suite: String?
    private var defaults: UserDefaults { suite.flatMap(UserDefaults.init(suiteName:)) ?? .standard }

    public init(suite: String? = nil) { self.suite = suite }

    static func key(_ room: String) -> String { "yorozu.directHints.\(room)" }

    public func load(room: String) -> DirectHints? {
        defaults.data(forKey: Self.key(room)).flatMap { try? JSONDecoder().decode(DirectHints.self, from: $0) }
    }

    public func save(_ hints: DirectHints, room: String) {
        guard let data = try? JSONEncoder().encode(hints) else { return }
        defaults.set(data, forKey: Self.key(room))
    }

    public func forget(room: String) { defaults.removeObject(forKey: Self.key(room)) }
}

/// Which direct candidates a race dials (#532 item 4). Pure: the interfaces and the Local Network gate come in.
enum DirectCandidates {
    static let tailscaleV4 = (network: Direct.ipBytes("100.64.0.0")!, prefix: 10)
    static let tailscaleV6 = (network: Direct.ipBytes("fd7a:115c:a1e0::")!, prefix: 48)

    /// Loopback on the Mac (the default port), always, since stored hints can be stale; LAN addresses on a subnet of an
    /// up, non-VPN interface, once Local Network is allowed; Tailscale IPs and then the MagicDNS name while an up VPN
    /// interface holds a Tailscale address. `skipped` names each left-out hint and why, for the log.
    static func plan(hints: DirectHints?, interfaces: [LocalInterface], isMac: Bool, lanAllowed: Bool, lanDenied: Bool = false, port: Int = Direct.port)
        -> (candidates: [URL], skipped: [(String, String)]) {
        var candidates: [URL] = []
        var skipped: [(String, String)] = []
        func add(_ host: String, _ port: Int) {
            if let url = Direct.url(host: host, port: port), !candidates.contains(url) { candidates.append(url) }
        }
        if isMac {
            add("127.0.0.1", port)
            add("::1", port)
        }
        guard let hints else { return (candidates, skipped) }
        for hint in hints.lan {
            if lanDenied {
                skipped.append((hint.address, "Local Network denied"))
            } else if !lanAllowed {
                skipped.append((hint.address, "Local Network not allowed yet"))
            } else if let network = Direct.ipBytes(hint.address),
                      interfaces.contains(where: { $0.up && !$0.isVPN && Direct.ipBytes($0.address).map { Direct.contains(network, prefix: hint.prefix, $0) } == true }) {
                add(hint.address, hints.port)
            } else {
                skipped.append((hint.address, "not on this subnet"))
            }
        }
        let tailnet = interfaces.contains { $0.up && $0.isVPN && isTailscale($0.address) }
        for hint in hints.tailscale {
            if tailnet { add(hint.address, hints.port) } else { skipped.append((hint.address, "no Tailscale interface up")) }
        }
        if let name = hints.magicDNS {
            if tailnet { add(name, hints.port) } else { skipped.append(("the MagicDNS name", "no Tailscale interface up")) }
        }
        return (candidates, skipped)
    }

    /// No address hints, or a hint matching any local interface: loopback may reach the host.
    static func hostMayBeLocal(_ hints: DirectHints?, _ interfaces: [LocalInterface]) -> Bool {
        guard let hints else { return true }
        let addresses = hints.lan.map(\.address) + hints.tailscale.map(\.address)
        return addresses.isEmpty || addresses.contains { address in
            guard let bytes = Direct.ipBytes(address) else { return false }
            return interfaces.contains { Direct.ipBytes($0.address) == bytes }
        }
    }

    static func isTailscale(_ address: String) -> Bool {
        guard let bytes = Direct.ipBytes(address) else { return false }
        return [tailscaleV4, tailscaleV6].contains { Direct.contains($0.network, prefix: $0.prefix, bytes) }
    }

    /// An address on the subnet of an up, non-VPN interface: where a Bonjour result must be.
    static func onLAN(_ address: String, _ interfaces: [LocalInterface]) -> Bool {
        guard let bytes = Direct.ipBytes(address) else { return false }
        return interfaces.contains { local in
            guard local.up, !local.isVPN, local.prefix > 0, let network = Direct.ipBytes(local.address) else { return false }
            return Direct.contains(network, prefix: local.prefix, bytes)
        }
    }
}

/// Browses `_yorozu._tcp` for the pairing's tag (#532 item 7) and yields each match's IPv4 address and port on this
/// subnet as a direct URL. Ends when the consumer stops iterating.
enum Bonjour {
    static let type = "_yorozu._tcp"

    static func browse(hostKey: Data) -> AsyncStream<URL> {
        AsyncStream { continuation in
            let resolver = Resolver()
            let browser = NWBrowser(for: .bonjourWithTXTRecord(type: type, domain: "local."), using: .tcp)
            browser.browseResultsChangedHandler = { _, changes in
                for change in changes {
                    let result: NWBrowser.Result
                    switch change {
                    case .added(let added): result = added
                    case .changed(_, let new, _): result = new
                    default: continue
                    }
                    guard case .bonjour(let txt) = result.metadata, let tag = txt["t"],
                          Direct.bonjourTags(hostKey: hostKey, at: Date()).contains(tag) else { continue }
                    resolver.resolve(result.endpoint) { continuation.yield($0) }
                }
            }
            browser.stateUpdateHandler = { state in
                switch state {
                case .waiting(let error), .failed(let error):
                    if LocalNetwork.policyDenied(error) {
                        LocalNetwork.denied = true
                        connectionLog.info("Bonjour: Local Network denied")
                        continuation.finish()
                        return
                    }
                default: break
                }
                if case .failed(let error) = state {
                    connectionLog.error("Bonjour browse failed: \(String(describing: error), privacy: .public)")
                    continuation.finish()
                }
            }
            browser.start(queue: resolver.queue)
            continuation.onTermination = { _ in resolver.queue.async { browser.cancel(); resolver.cancel() } }
        }
    }

    /// Resolves a service to the address it answers on: a TCP connection's remote endpoint, closed at once. Touched only
    /// on `queue`.
    private final class Resolver: @unchecked Sendable {
        let queue = DispatchQueue(label: "to.yumi.yorozu.bonjour")
        private var connections: [NWConnection] = []

        func resolve(_ endpoint: NWEndpoint, found: @escaping @Sendable (URL) -> Void) {
            let connection = NWConnection(to: endpoint, using: .tcp)
            connections.append(connection)
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if case .hostPort(.ipv4(let address), let port) = connection.currentPath?.remoteEndpoint {
                        let host = String("\(address)".prefix { $0 != "%" })
                        if DirectCandidates.onLAN(host, LocalInterface.current()),
                           let url = Direct.url(host: host, port: Int(port.rawValue)) {
                            found(url)
                        } else {
                            connectionLog.info("Bonjour: \(host, privacy: .public) is not on this subnet")
                        }
                    }
                    connection.cancel()
                case .failed, .waiting:
                    connection.cancel()
                case .cancelled:
                    connection.stateUpdateHandler = nil
                    self?.connections.removeAll { $0 === connection }
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }

        func cancel() {
            for connection in connections { connection.cancel() }
        }
    }
}

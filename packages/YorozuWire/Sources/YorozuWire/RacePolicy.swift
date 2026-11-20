import Foundation
import Network

enum RacePolicy {
    static let relayKey = "relay"
    static let stagger = Duration.milliseconds(50)
    static let headStart = Duration.milliseconds(300)
    static let directHandshakeTimeout = Duration.seconds(3)
    static let directFailureLifetime: TimeInterval = 10 * 60
    static let quickSession = Duration.seconds(10)
    static let maxPause = Duration.seconds(30)

    struct Start: Equatable, Sendable {
        var index: Int
        var delay: Duration
    }

    struct Plan: Equatable, Sendable {
        var direct: [Start]
        var relay: Duration
    }

    static func plan(direct: [String], lastWinner: String?) -> Plan {
        var order = Array(direct.indices)
        let won = lastWinner.flatMap { direct.firstIndex(of: $0) }
        if let won {
            order.remove(at: won)
            order.insert(won, at: 0)
        }
        return Plan(direct: order.enumerated().map { Start(index: $1, delay: stagger * $0) }, relay: won == nil ? .zero : headStart)
    }

    static func quickLosses(after previous: Int, lived: Duration) -> Int {
        lived < quickSession ? previous + 1 : 0
    }

    static func pause(quickLosses: Int) -> Duration {
        guard quickLosses >= 2 else { return .zero }
        return min(maxPause, .seconds(1 << min(quickLosses - 2, 5)))
    }

    static func networkKind(_ path: NWPath) -> String {
        guard path.status == .satisfied else { return "none" }
        if path.usesInterfaceType(.wifi) { return "wifi" }
        if path.usesInterfaceType(.wiredEthernet) { return "wired" }
        if path.usesInterfaceType(.cellular) { return "cellular" }
        return "other"
    }
}

protocol RaceWinners: Sendable {
    func winner(room: String, network: String) -> String?
    func record(_ key: String, room: String, network: String)
}

struct DefaultsRaceWinners: RaceWinners {
    static func prefix(_ room: String) -> String { "yorozu.raceWinner.\(room)." }

    func winner(room: String, network: String) -> String? {
        UserDefaults.standard.string(forKey: Self.prefix(room) + network)
    }

    func record(_ key: String, room: String, network: String) {
        UserDefaults.standard.set(key, forKey: Self.prefix(room) + network)
    }

    static func forget(room: String) {
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix(room)) { defaults.removeObject(forKey: key) }
    }
}

protocol RaceFailures: Sendable {
    func failedAt(_ key: String, room: String, network: String) -> Date?
    func record(_ key: String, room: String, network: String, at: Date)
    func clear(_ key: String, room: String, network: String)
    func forget(room: String)
}

struct DefaultsRaceFailures: RaceFailures {
    private static let lock = NSLock()
    private static func prefix(_ room: String) -> String { "yorozu.raceFailures.\(room)." }

    private func entries(room: String, network: String) -> [String: Date] {
        UserDefaults.standard.dictionary(forKey: Self.prefix(room) + network) as? [String: Date] ?? [:]
    }

    func failedAt(_ key: String, room: String, network: String) -> Date? {
        entries(room: room, network: network)[key]
    }

    func record(_ key: String, room: String, network: String, at: Date) {
        Self.lock.withLock {
            var stored = entries(room: room, network: network).filter { at.timeIntervalSince($0.value) < RacePolicy.directFailureLifetime }
            stored[key] = at
            UserDefaults.standard.set(stored, forKey: Self.prefix(room) + network)
        }
    }

    func clear(_ key: String, room: String, network: String) {
        Self.lock.withLock {
            var stored = entries(room: room, network: network)
            stored[key] = nil
            UserDefaults.standard.set(stored, forKey: Self.prefix(room) + network)
        }
    }

    func forget(room: String) {
        Self.lock.withLock {
            let defaults = UserDefaults.standard
            for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(Self.prefix(room)) {
                defaults.removeObject(forKey: key)
            }
        }
    }
}

final class NetworkKind: @unchecked Sendable {
    static let shared = NetworkKind()

    private let lock = NSLock()
    private var latest: String?
    private var waiters: [CheckedContinuation<String, Never>] = []
    private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in self?.update(RacePolicy.networkKind(path)) }
        monitor.start(queue: DispatchQueue(label: "to.yumi.yorozu.network-kind"))
    }

    private func update(_ kind: String) {
        lock.lock()
        latest = kind
        let waiting = waiters
        waiters = []
        lock.unlock()
        for waiter in waiting { waiter.resume(returning: kind) }
    }

    func current() async -> String {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let latest {
                lock.unlock()
                continuation.resume(returning: latest)
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }
}

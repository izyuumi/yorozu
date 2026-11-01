import Foundation
import Network

/// When each leg of a race starts and how long to wait before the next race (#532 items 5 and 6). Pure: no sockets, no clocks.
enum RacePolicy {
    /// The key the store holds when the relay won; a direct candidate's key is its URL string.
    static let relayKey = "relay"
    /// Happy Eyeballs: each further direct candidate starts this long after the one before.
    static let stagger = Duration.milliseconds(50)
    /// The relay's wait when a direct candidate won last time on this network kind.
    static let headStart = Duration.milliseconds(300)
    /// A session that lived less than this counts as a quick loss.
    static let quickSession = Duration.seconds(10)
    static let maxPause = Duration.seconds(30)

    struct Start: Equatable, Sendable {
        /// The candidate's index in the list given to `plan`.
        var index: Int
        var delay: Duration
    }

    struct Plan: Equatable, Sendable {
        /// The direct candidates in dial order.
        var direct: [Start]
        var relay: Duration
    }

    /// The last winner first if it is a direct candidate, the others after it in their order, 50 ms apart from 0. The relay
    /// waits 300 ms only behind a direct candidate that won last; after a relay win, no win or a stale key it starts at 0.
    static func plan(direct: [String], lastWinner: String?) -> Plan {
        var order = Array(direct.indices)
        let won = lastWinner.flatMap { direct.firstIndex(of: $0) }
        if let won {
            order.remove(at: won)
            order.insert(won, at: 0)
        }
        return Plan(direct: order.enumerated().map { Start(index: $1, delay: stagger * $0) }, relay: won == nil ? .zero : headStart)
    }

    /// The count of consecutive quick losses once a session that lived `lived` is lost. A long session resets it.
    static func quickLosses(after previous: Int, lived: Duration) -> Int {
        lived < quickSession ? previous + 1 : 0
    }

    /// No pause for the first quick loss; then 1 s, 2 s, 4 s and so on, capped at 30 s.
    static func pause(quickLosses: Int) -> Duration {
        guard quickLosses >= 2 else { return .zero }
        return min(maxPause, .seconds(1 << min(quickLosses - 2, 5)))
    }

    /// "wifi", "wired", "cellular", "other", or "none" without a usable path.
    static func networkKind(_ path: NWPath) -> String {
        guard path.status == .satisfied else { return "none" }
        if path.usesInterfaceType(.wifi) { return "wifi" }
        if path.usesInterfaceType(.wiredEthernet) { return "wired" }
        if path.usesInterfaceType(.cellular) { return "cellular" }
        return "other"
    }
}

/// The candidate that won the last race, per pairing room and network kind.
protocol RaceWinners: Sendable {
    func winner(room: String, network: String) -> String?
    func record(_ key: String, room: String, network: String)
}

/// The production store, in the standard user defaults.
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

/// The latest network path's kind, from one monitor shared by the app. The first path arrives asynchronously, so a race
/// started at launch waits for it rather than racing as "none".
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

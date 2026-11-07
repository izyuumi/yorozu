struct SceneLifecycle: Equatable {
    struct Visit: Equatable {
        fileprivate let number: UInt64
    }

    enum Phase: Equatable {
        case foreground, leaving, background(Visit), suspended(Visit)
    }

    private var generation: UInt64 = 0
    private(set) var phase: Phase = .leaving

    var isActive: Bool { phase == .foreground }

    mutating func enterBackground() -> Visit {
        generation += 1
        let visit = Visit(number: generation)
        phase = .background(visit)
        return visit
    }

    mutating func becomeActive() {
        guard phase != .foreground else { return }
        // A return also invalidates background-wake snapshots.
        generation += 1
        phase = .foreground
    }

    mutating func becomeInactive() {
        phase = .leaving
    }

    mutating func suspend(visit: Visit) -> Bool {
        guard phase == .background(visit) else { return false }
        phase = .suspended(visit)
        return true
    }

    func stillSuspended(visit: Visit) -> Bool {
        phase == .suspended(visit)
    }
}

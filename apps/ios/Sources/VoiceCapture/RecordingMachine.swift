import Foundation

enum RecordingLimits {
    static let maxSeconds: Double = 600
}

enum RecordingPhase: Equatable, Sendable {
    case idle
    case recording
    case interrupted(resumable: Bool?)
    case finished(StopReason)
}

enum StopReason: Equatable, Sendable {
    case user, liveActivity, capReached, engineFailed, cancelled
}

enum RecordingEvent: Equatable, Sendable {
    case start
    case captured(seconds: Double)
    case interruptionBegan
    case interruptionEnded(shouldResume: Bool)
    case routeChanged(inputLost: Bool)
    case engineRestartFailed
    case resumeRequested
    case stop(StopReason)
    case cancel
}

enum RecordingEffect: Equatable, Sendable {
    case startEngine, pauseEngine, resumeEngine, restartEngine, stopEngine
    case persistClip, discardClip, announceCap, updateActivity
}

struct RecordingMachine: Equatable, Sendable {
    private(set) var phase: RecordingPhase = .idle
    private(set) var captured: Double = 0

    mutating func handle(_ event: RecordingEvent) -> [RecordingEffect] {
        switch (phase, event) {
        case (.idle, .start), (.finished, .start):
            captured = 0
            phase = .recording
            return [.startEngine, .updateActivity]
        case (.recording, .captured(let seconds)):
            guard seconds.isFinite, seconds > captured else { return [] }
            captured = seconds
            if captured >= RecordingLimits.maxSeconds {
                phase = .finished(.capReached)
                return [.stopEngine, .persistClip, .announceCap, .updateActivity]
            }
            return []
        case (.recording, .interruptionBegan):
            phase = .interrupted(resumable: nil)
            return [.pauseEngine, .updateActivity]
        case (.interrupted(resumable: nil), .interruptionEnded(let shouldResume)):
            if shouldResume {
                phase = .recording
                return [.resumeEngine, .updateActivity]
            }
            phase = .interrupted(resumable: false)
            return [.updateActivity]
        case (.interrupted(resumable: false), .resumeRequested):
            phase = .recording
            return [.resumeEngine, .updateActivity]
        case (.recording, .routeChanged(inputLost: true)):
            return [.restartEngine]
        case (.recording, .engineRestartFailed), (.interrupted, .engineRestartFailed):
            return finish(.engineFailed)
        case (.recording, .stop(let reason)), (.interrupted, .stop(let reason)):
            guard reason == .user || reason == .liveActivity else { return [] }
            return finish(reason)
        case (.recording, .cancel), (.interrupted, .cancel):
            phase = .finished(.cancelled)
            return [.stopEngine, .discardClip, .updateActivity]
        default:
            return []
        }
    }

    private mutating func finish(_ reason: StopReason) -> [RecordingEffect] {
        phase = .finished(reason)
        return [.stopEngine, captured > 0 ? .persistClip : .discardClip, .updateActivity]
    }
}

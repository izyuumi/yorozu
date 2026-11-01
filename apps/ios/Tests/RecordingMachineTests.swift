import Testing

struct RecordingMachineTests {
    @Test func startRecording() {
        var machine = RecordingMachine()
        #expect(machine.phase == .idle)
        #expect(machine.captured == 0)
        #expect(machine.handle(.start) == [.startEngine, .updateActivity])
        #expect(machine.phase == .recording)
    }
}

extension RecordingMachineTests {
    @Test(arguments: [true, false])
    func interruptedRecordingCanContinue(shouldResume: Bool) {
        var recorder = FakeRecorder()
        recorder.play([.start, .captured(seconds: 12), .captured(seconds: 4), .interruptionBegan])
        #expect(recorder.machine.phase == .interrupted(resumable: nil))
        #expect(recorder.machine.captured == 12)
        #expect(recorder.effects == [.startEngine, .updateActivity, .pauseEngine, .updateActivity])
        recorder.play([.interruptionEnded(shouldResume: shouldResume)])
        if !shouldResume {
            #expect(recorder.machine.phase == .interrupted(resumable: false))
            #expect(recorder.effects.last == .updateActivity)
            recorder.play([.resumeRequested])
        }
        #expect(recorder.machine.phase == .recording)
        #expect(Array(recorder.effects.suffix(2)) == [.resumeEngine, .updateActivity])
        recorder.play([.captured(seconds: 20), .stop(.user)])
        #expect(recorder.machine.captured == 20)
        #expect(recorder.machine.phase == .finished(.user))
        #expect(Array(recorder.effects.suffix(3)) == [.stopEngine, .persistClip, .updateActivity])
    }
}

private struct FakeRecorder {
    var machine = RecordingMachine()
    var effects: [RecordingEffect] = []

    mutating func play(_ events: [RecordingEvent]) {
        for event in events {
            effects.append(contentsOf: machine.handle(event))
        }
    }
}

extension RecordingMachineTests {
    @Test(arguments: [600.0, 601.0])
    func capStopsAtOrAboveLimit(seconds: Double) {
        var machine = RecordingMachine()
        _ = machine.handle(.start)
        #expect(RecordingLimits.maxSeconds == 600)
        #expect(machine.handle(.captured(seconds: 599.99)).isEmpty)
        #expect(machine.phase == .recording)
        #expect(machine.handle(.captured(seconds: seconds)) == [.stopEngine, .persistClip, .announceCap, .updateActivity])
        #expect(machine.phase == .finished(.capReached))
        #expect(machine.handle(.captured(seconds: 700)).isEmpty)
        #expect(machine.captured == seconds)
        #expect(machine.handle(.start) == [.startEngine, .updateActivity])
        #expect(machine.captured == 0)
    }

    @Test func routeRestartKeepsSamples() {
        var machine = RecordingMachine()
        _ = machine.handle(.start)
        _ = machine.handle(.captured(seconds: 8))
        #expect(machine.handle(.routeChanged(inputLost: true)) == [.restartEngine])
        #expect(machine.phase == .recording)
        #expect(machine.captured == 8)
        #expect(machine.handle(.captured(seconds: 7)).isEmpty)
        #expect(machine.captured == 8)
    }

    @Test(arguments: [(0, 0.0), (1, 0.0), (2, 0.0), (0, 9.0), (1, 9.0), (2, 9.0)], [StopReason.user, .liveActivity, .engineFailed])
    func finishingKeepsOnlyNonemptyClips(state: (Int, Double), reason: StopReason) {
        let (interruptionState, seconds) = state
        var machine = RecordingMachine()
        _ = machine.handle(.start)
        _ = machine.handle(.captured(seconds: seconds))
        if interruptionState > 0 { _ = machine.handle(.interruptionBegan) }
        if interruptionState == 2 { _ = machine.handle(.interruptionEnded(shouldResume: false)) }
        let event: RecordingEvent = reason == .engineFailed ? .engineRestartFailed : .stop(reason)
        #expect(machine.handle(event) == [.stopEngine, seconds > 0 ? .persistClip : .discardClip, .updateActivity])
        #expect(machine.phase == .finished(reason))
        #expect(machine.captured == seconds)
        #expect(machine.handle(event).isEmpty)
    }

    @Test(arguments: [false, true])
    func cancellationDiscardsSamples(interrupted: Bool) {
        var machine = RecordingMachine()
        _ = machine.handle(.start)
        _ = machine.handle(.captured(seconds: 10))
        if interrupted { _ = machine.handle(.interruptionBegan) }
        #expect(machine.handle(.cancel) == [.stopEngine, .discardClip, .updateActivity])
        #expect(machine.phase == .finished(.cancelled))
        #expect(machine.handle(.cancel).isEmpty)
    }

    @Test func strayEventsAreNoOps() {
        let cases: [([RecordingEvent], [RecordingEvent])] = [
            ([], [.captured(seconds: 20), .interruptionBegan, .interruptionEnded(shouldResume: true), .interruptionEnded(shouldResume: false), .resumeRequested, .routeChanged(inputLost: true), .engineRestartFailed, .stop(.user), .cancel]),
            ([.start], [.start, .interruptionEnded(shouldResume: true), .interruptionEnded(shouldResume: false), .resumeRequested, .routeChanged(inputLost: false), .stop(.capReached), .stop(.cancelled), .stop(.engineFailed)]),
            ([.start, .interruptionBegan], [.start, .interruptionBegan, .captured(seconds: 50), .resumeRequested, .routeChanged(inputLost: true)]),
            ([.start, .interruptionBegan, .interruptionEnded(shouldResume: false)], [.start, .interruptionBegan, .captured(seconds: 50), .interruptionEnded(shouldResume: true), .interruptionEnded(shouldResume: false), .routeChanged(inputLost: true)]),
            ([.start, .stop(.user)], [.captured(seconds: 20), .interruptionBegan, .interruptionEnded(shouldResume: true), .resumeRequested, .routeChanged(inputLost: true), .engineRestartFailed, .stop(.liveActivity), .cancel]),
        ]
        for (setup, events) in cases {
            var machine = RecordingMachine()
            for event in setup { _ = machine.handle(event) }
            let before = machine
            for event in events {
                #expect(machine.handle(event).isEmpty)
                #expect(machine == before)
            }
        }
    }

    @Test func invalidDurationsDoNotCorruptCapturedTime() {
        var machine = RecordingMachine()
        _ = machine.handle(.start)
        _ = machine.handle(.captured(seconds: 3))
        for seconds in [-1, Double.nan, .infinity, -.infinity] {
            #expect(machine.handle(.captured(seconds: seconds)).isEmpty)
            #expect(machine.captured == 3)
        }
    }
}

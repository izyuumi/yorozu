import AVFoundation
import Speech
import SwiftUI

/// The two directions voice goes in a chat: dictating into the composer, and hearing a reply
/// read back. Both are the system's own frameworks — `SFSpeechRecognizer` on the way in,
/// `AVSpeechSynthesizer` on the way out — so there is no model to ship and, where the device
/// supports it, nothing leaves the phone.

// MARK: - Dictation

/// Live dictation into the composer. Holds the audio engine and the recognition task, and
/// publishes what a composer needs to draw: whether it is listening, and how loud the room is.
@MainActor
@Observable
public final class Dictation {
    public private(set) var listening = false
    /// The last couple of seconds of input level, newest last, for the waveform.
    public private(set) var levels: [Double] = []
    /// Set when the mic or speech recognition was refused, so the composer can say so once.
    public var denied = false

    /// Whether the device recognises speech in this locale at all. It does not, for a few, and
    /// there the composer simply has no mic button rather than one that never works.
    public let available = SFSpeechRecognizer(locale: .current) != nil

    private let recognizer = SFSpeechRecognizer(locale: .current)
    private let engine = AVAudioEngine()
    private var task: SFSpeechRecognitionTask?
    /// Silence ends dictation by itself: nobody wants to reach back for the mic button after
    /// they have finished the sentence.
    private var silence: Task<Void, Never>?
    /// What was already typed when dictation started. The transcript is appended to it, so
    /// dictating into a half-written message adds to it rather than wiping it.
    private var typed = ""
    private var onText: ((String) -> Void)?
    /// Everything the audio thread touches, in one box off to the side. The tap runs on a
    /// real-time thread that cannot hop to the main actor to hand a buffer over, and this class
    /// is `@MainActor` — so the shared state lives somewhere that is neither.
    private let tap = Tap()

    /// The recognition request the audio tap feeds, and the count that thins the level updates:
    /// one in three buffers is plenty for a waveform, and a third of forty-odd view updates a
    /// second is the difference between a decoration and a cost.
    private final class Tap: @unchecked Sendable {
        var request: SFSpeechAudioBufferRecognitionRequest?
        var tick = 0
    }

    public init() {}

    public static let silenceTimeout = Duration.seconds(2)

    /// Starts listening, asking for the microphone and for speech recognition the first time.
    /// `existing` is the composer's text; `onText` is called with the whole field on every
    /// partial result.
    public func start(existing: String, onText: @escaping (String) -> Void) async {
        guard !listening, let recognizer else { return }
        guard await authorized() else {
            denied = true
            return
        }
        typed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        self.onText = onText

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // On-device wherever the locale supports it: dictation into a private thread has no
        // business going to a server just because that is the default.
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        tap.request = request

        do {
            try configureSession()
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                self?.feed(buffer)
            }
            engine.prepare()
            try engine.start()
        } catch {
            tap.request = nil
            return
        }

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let ended = error != nil || result?.isFinal == true
            Task { @MainActor [weak self] in self?.heard(text, ended: ended) }
        }
        listening = true
        arm()
    }

    /// Ends dictation and tears the audio down. Safe to call when not listening.
    public func stop() {
        silence?.cancel()
        silence = nil
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        tap.request?.endAudio()
        tap.request = nil
        task?.cancel()
        task = nil
        listening = false
        levels = []
        deactivateSession()
    }

    public func toggle(existing: String, onText: @escaping (String) -> Void) {
        if listening {
            stop()
        } else {
            Task { await start(existing: existing, onText: onText) }
        }
    }

    /// Test-only: the listening state with a fixed level trace behind it. A simulator has no
    /// microphone, so this is the only way the composer's listening state can be screenshotted.
    public func preview(levels: [Double]) {
        listening = true
        self.levels = levels
    }

    // MARK: Plumbing

    /// Called on the audio thread for every buffer: the recogniser wants it, and the waveform
    /// wants how loud it was.
    private nonisolated func feed(_ buffer: AVAudioPCMBuffer) {
        tap.request?.append(buffer)
        tap.tick += 1
        guard tap.tick % 3 == 0, let samples = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }
        var sum: Float = 0
        for index in 0..<count { sum += samples[index] * samples[index] }
        // RMS is tiny for ordinary speech; the gain is what turns it into a bar worth drawing.
        let level = min(1, Double((sum / Float(count)).squareRoot()) * 14)
        Task { @MainActor [weak self] in self?.push(level) }
    }

    private func push(_ level: Double) {
        guard listening else { return }
        levels.append(level)
        if levels.count > 24 { levels.removeFirst(levels.count - 24) }
    }

    private func heard(_ text: String?, ended: Bool) {
        if let text, !text.isEmpty {
            onText?(typed.isEmpty ? text : "\(typed) \(text)")
            arm()
        }
        if ended { stop() }
    }

    /// Restarts the silence countdown. Every partial result pushes it back, so it only fires
    /// once the talking has actually stopped.
    private func arm() {
        silence?.cancel()
        silence = Task { [weak self] in
            try? await Task.sleep(for: Self.silenceTimeout)
            guard !Task.isCancelled else { return }
            self?.stop()
        }
    }

    private func authorized() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard speech == .authorized else { return false }
        #if os(iOS)
            return await AVAudioApplication.requestRecordPermission()
        #else
            return await AVCaptureDevice.requestAccess(for: .audio)
        #endif
    }

    /// The audio session is the one part of this the Mac does not have: there, the engine's
    /// input node is the default device and there is nothing to configure.
    private func configureSession() throws {
        #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        #endif
    }

    private func deactivateSession() {
        #if os(iOS)
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}

/// The composer's microphone. Filled and tinted while it is listening, so the button itself is
/// the "recording" light rather than needing one next to it.
public struct MicButton: View {
    private let dictation: Dictation
    @Binding var draft: String

    public init(dictation: Dictation, draft: Binding<String>) {
        self.dictation = dictation
        self._draft = draft
    }

    public var body: some View {
        Button {
            dictation.toggle(existing: draft) { draft = $0 }
        } label: {
            Image(systemName: dictation.listening ? "mic.fill" : "mic")
                .font(.body)
                .foregroundStyle(dictation.listening ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 44, height: 44)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(dictation.listening ? "Stop dictation" : "Dictate")
        .sensoryFeedback(.selection, trigger: dictation.listening)
    }
}

/// What the field says while it is listening: the last second or two of input level, in place of
/// the placeholder. Reduce Motion still gets the bars — they are the level, not a decoration —
/// but without the spring settling them.
public struct LevelMeter: View {
    let levels: [Double]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(levels: [Double]) { self.levels = levels }

    public var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(Array(levels.suffix(16).enumerated()), id: \.offset) { _, level in
                Capsule()
                    .frame(width: 2.5, height: max(3, level * 20))
            }
            if levels.isEmpty {
                Text("Listening…").font(.body).foregroundStyle(.secondary)
            }
        }
        .frame(height: 20)
        .foregroundStyle(.tint)
        .animation(reduceMotion ? nil : .snappy(duration: 0.12), value: levels)
        .accessibilityLabel("Listening")
    }
}

// MARK: - Listen

/// Reads a reply aloud. One utterance at a time, app-wide: a second Listen replaces the first
/// rather than talking over it.
@MainActor
@Observable
public final class Speaker {
    public static let shared = Speaker()

    /// The id of the message being read, or nil. What draws the chip on the bubble.
    public private(set) var speakingId: String?

    private let synthesizer = AVSpeechSynthesizer()
    private let relay = Relay()

    private init() {
        synthesizer.delegate = relay
        relay.onEnd = { [weak self] in self?.speakingId = nil }
    }

    public func speak(_ text: String, id: String) {
        stop()
        let utterance = AVSpeechUtterance(string: spoken(text))
        // The system voice for whatever the reader reads in, which is the one they have already
        // chosen in Settings and the only one guaranteed to be installed.
        utterance.voice = AVSpeechSynthesisVoice(
            language: Locale.preferredLanguages.first ?? Locale.current.identifier
        )
        #if os(iOS)
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        speakingId = id
        synthesizer.speak(utterance)
    }

    public func stop() {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        speakingId = nil
    }

    /// Markdown read aloud is a stream of asterisks and backticks, so the markers come out
    /// before it is spoken. The words are all the synthesiser was ever going to use.
    private func spoken(_ text: String) -> String {
        String(text.unicodeScalars.filter { !"*_`#>|~".unicodeScalars.contains($0) })
    }

    /// `AVSpeechSynthesizer` wants an `NSObject` delegate, which an `@Observable` class is not.
    /// Kept here rather than exposed: it exists only to say "it stopped".
    @MainActor
    private final class Relay: NSObject, AVSpeechSynthesizerDelegate {
        var onEnd: (() -> Void)?

        nonisolated func speechSynthesizer(
            _: AVSpeechSynthesizer, didFinish _: AVSpeechUtterance
        ) {
            Task { @MainActor in self.onEnd?() }
        }

        nonisolated func speechSynthesizer(
            _: AVSpeechSynthesizer, didCancel _: AVSpeechUtterance
        ) {
            Task { @MainActor in self.onEnd?() }
        }
    }
}

/// The chip on a bubble that is being read aloud: what is happening, and the way to stop it.
public struct SpeakingChip: View {
    public init() {}

    public var body: some View {
        Button {
            Speaker.shared.stop()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "waveform")
                    .symbolEffect(.variableColor.iterative, options: .repeating)
                Text("Speaking")
                Image(systemName: "stop.fill")
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(minHeight: 28)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
        .background(.tint.opacity(0.12), in: Capsule())
        .accessibilityLabel("Stop reading aloud")
    }
}

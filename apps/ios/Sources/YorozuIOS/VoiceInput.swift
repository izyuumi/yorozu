import AVFoundation
import SpeechEngines
import SwiftUI
import VoiceText

/// One dictation in the composer: record, then transcribe into the field or straight into a message.
/// The clip is kept until a transcript is delivered or the owner cancels, so a failure can be retried.
@MainActor @Observable
final class VoiceSession {
    enum Phase: Equatable {
        case idle, recording, transcribing
        case failed(String)
    }

    private(set) var phase = Phase.idle
    var micDenied = false
    let recorder = VoiceRecorder()
    private var clip: [Float] = []
    private var loading: Task<any SpeechEngine, Error>?
    private var job: Task<Void, Never>?
    private var deliver: ((String) -> Void)?

    func start() async {
        guard phase == .idle else { return }
        switch AVAudioApplication.shared.recordPermission {
        case .granted: break
        case .undetermined:
            guard await AVAudioApplication.requestRecordPermission() else { return }
        default:
            micDenied = true
            return
        }
        do {
            try recorder.start()
            phase = .recording
            // Load while the owner speaks, so only the transcription itself is left after ✓.
            loading = VoiceSetup.shared.load()
        } catch {
            _ = recorder.stop()
            phase = .failed(error.localizedDescription)
        }
    }

    /// Stops recording and transcribes; `deliver` gets the text on success.
    func finish(_ deliver: @escaping (String) -> Void) {
        guard phase == .recording else { return }
        clip = recorder.stop()
        self.deliver = deliver
        retry()
    }

    /// Stops recording and hands the clip over, leaving the composer free; nil unless recording.
    func handOff() -> VoiceClip? {
        guard phase == .recording else { return nil }
        let handed = VoiceClip(samples: recorder.stop(), loading: loading)
        loading = nil
        reset()
        return handed.samples.isEmpty ? nil : handed
    }

    func retry() {
        guard let deliver, !clip.isEmpty else { return cancel() }
        phase = .transcribing
        let clip = VoiceClip(samples: clip, loading: loading)
        loading = nil
        job = Task {
            switch await clip.transcribe() {
            case .success(let text):
                reset()
                deliver(text)
            case .failure(let error):
                guard !Task.isCancelled else { return }
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        if phase == .recording { _ = recorder.stop() }
        loading?.cancel()
        reset()
    }

    private func reset() {
        job?.cancel()
        job = nil
        loading = nil
        clip = []
        deliver = nil
        phase = .idle
    }
}

/// A finished recording and the engine load started while it was spoken.
struct VoiceClip {
    let samples: [Float]
    var loading: Task<any SpeechEngine, Error>?

    /// The transcript in the chosen language with the voice dictionary applied; an empty one counts as a failure.
    @MainActor func transcribe() async -> Result<String, Error> {
        let language = VoiceLanguage(rawValue: UserDefaults.standard.string(forKey: VoiceModel.languageKey) ?? "") ?? .automatic
        let dictionary = VoiceDictionary.stored
        let loading = loading ?? VoiceSetup.shared.load()
        let samples = samples
        let work = Task.detached(priority: .userInitiated) { () -> Result<String, Error> in
            do {
                let text = try await loading.value.transcribe(samples, language: language.code, hints: dictionary.hints)
                return .success(dictionary.apply(to: text))
            } catch {
                return .failure(error)
            }
        }
        let result = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
        if case .success(let text) = result, text.isEmpty { return .failure(VoiceModel.Failure(String(localized: "No speech was recognized."))) }
        return result
    }
}

/// Voice messages sent straight from the composer: each shows as a "Transcribing…" bubble in its conversation
/// until the transcript goes out as a message. A failure keeps the clip on the bubble for Retry.
@MainActor @Observable
final class VoiceSends {
    static let shared = VoiceSends()

    struct Pending: Identifiable {
        let id = UUID()
        var failure: String?
    }

    private(set) var pending: [String: [Pending]] = [:]
    @ObservationIgnored private var work: [UUID: (clip: VoiceClip, send: (String) -> Void)] = [:]

    func add(_ clip: VoiceClip, in convId: String, send: @escaping (String) -> Void) {
        let item = Pending()
        pending[convId, default: []].append(item)
        work[item.id] = (clip, send)
        run(item.id, in: convId)
    }

    func retry(_ id: UUID, in convId: String) {
        set(id, in: convId, failure: nil)
        run(id, in: convId)
    }

    func discard(_ id: UUID, in convId: String) {
        work[id] = nil
        pending[convId]?.removeAll { $0.id == id }
    }

    private func run(_ id: UUID, in convId: String) {
        guard let (clip, send) = work[id] else { return }
        work[id]?.clip.loading = nil
        Task {
            switch await clip.transcribe() {
            case .success(let text):
                discard(id, in: convId)
                send(text)
            case .failure(let error):
                set(id, in: convId, failure: error.localizedDescription)
            }
        }
    }

    private func set(_ id: UUID, in convId: String, failure: String?) {
        guard let index = pending[convId]?.firstIndex(where: { $0.id == id }) else { return }
        pending[convId]?[index].failure = failure
    }
}

/// A voice message on its way: the sender's bubble with "Transcribing…", or the error with Retry and Delete.
struct PendingVoiceBubble: View {
    let item: VoiceSends.Pending
    let convId: String
    @Environment(\.accent) private var accent

    var body: some View {
        VStack(alignment: .trailing, spacing: LayoutMetrics.tight) {
            HStack(spacing: LayoutMetrics.inner) {
                if item.failure == nil {
                    ProgressView().controlSize(.small).tint(.white)
                    Text("Transcribing…")
                } else {
                    Image(systemName: "waveform")
                    Text("Voice message")
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, LayoutMetrics.stack)
            .padding(.vertical, LayoutMetrics.inner)
            .background(accent.bubble.opacity(item.failure == nil ? 0.7 : 0.5),
                in: RoundedRectangle(cornerRadius: LayoutMetrics.bubbleRadius, style: .continuous))
            if let failure = item.failure {
                HStack(spacing: LayoutMetrics.inner) {
                    Text(failure).foregroundStyle(YorozuPalette.warning)
                    Button(String(localized: "Retry")) { VoiceSends.shared.retry(item.id, in: convId) }
                    Button(String(localized: "Delete"), role: .destructive) { VoiceSends.shared.discard(item.id, in: convId) }
                }
                .textStyle(.caption)
                .buttonStyle(.borderless)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .contain)
    }
}

/// Replaces the composer's row while dictating: ✕, a waveform and timer (or progress, or an error with Retry),
/// stop to put the text in the field, and send to post it as a message that transcribes in the chat.
struct VoiceBar: View {
    let session: VoiceSession
    let onInsert: (String) -> Void
    let onSend: () -> Void
    @Environment(\.accent) private var accent

    private let sendCircle = LayoutMetrics.controlCircle

    var body: some View {
        HStack(spacing: 0) {
            icon("xmark", label: String(localized: "Cancel")) { session.cancel() }
                .keyboardShortcut(.cancelAction)
            Group {
                switch session.phase {
                case .recording, .idle:
                    HStack(spacing: LayoutMetrics.inner) {
                        Waveform(levels: session.recorder.levels)
                        Text(Duration.seconds(session.recorder.seconds).formatted(.time(pattern: .minuteSecond)))
                            .textStyle(.body)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(Text("Recording"))
                case .transcribing:
                    HStack(spacing: LayoutMetrics.inner) {
                        ProgressView().controlSize(.small)
                        Text("Transcribing…").textStyle(.body).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                case .failed(let message):
                    HStack(spacing: LayoutMetrics.inner) {
                        Text(message).textStyle(.callout).foregroundStyle(YorozuPalette.warning).lineLimit(2)
                        Spacer(minLength: 0)
                        icon("arrow.clockwise", label: String(localized: "Retry")) { session.retry() }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            if session.phase == .recording {
                icon("stop.fill", label: String(localized: "Insert Transcript")) { session.finish(onInsert) }
                    .keyboardShortcut(.defaultAction)
                Button(action: onSend) {
                    Image(systemName: "arrow.up")
                        .textStyle(.body, weight: .bold)
                        .foregroundStyle(Color.white)
                        .frame(width: sendCircle, height: sendCircle)
                        .background(accent.bubble, in: Circle())
                }
                .buttonStyle(.plain)
                .frame(width: controlTarget, height: controlTarget)
                .keyboardShortcut(.return, modifiers: .command)
                .help(String(localized: "Transcribe and Send"))
                .accessibilityLabel(Text("Transcribe and Send"))
            }
        }
        .frame(minHeight: controlTarget)
        .padding(.vertical, LayoutMetrics.tight)
        .padding(.horizontal, LayoutMetrics.tight)
    }

    private func icon(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).textStyle(.body, weight: .semibold).composerControl()
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(Text(label))
    }
}

struct VoiceSetupSheet: View {
    @Environment(\.dismiss) private var dismiss
    private let setup = VoiceSetup.shared

    var body: some View {
        NavigationStack {
            Form { VoiceInputSection() }
                .formStyle(.grouped)
                .navigationTitle(String(localized: "Voice Input"))
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(String(localized: "Done")) { dismiss() }
                    }
                }
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #else
        .frame(width: LayoutMetrics.settingsWidth, height: 480)
        #endif
        .onChange(of: setup.ready) { _, ready in if ready { dismiss() } }
    }
}

/// The recording's loudness as bars, newest at the trailing edge; as many as fit.
private struct Waveform: View {
    let levels: [Float]
    @Environment(\.accent) private var accent
    private let bar: CGFloat = 3
    private let gap: CGFloat = 2

    var body: some View {
        Canvas { context, size in
            let fit = Int(size.width / (bar + gap))
            for (index, level) in levels.suffix(fit).reversed().enumerated() {
                let height = max(bar, size.height * CGFloat(level))
                let rect = CGRect(x: size.width - CGFloat(index + 1) * (bar + gap), y: (size.height - height) / 2, width: bar, height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: bar / 2), with: .color(accent.tint))
            }
        }
        .frame(height: controlTarget / 2)
        .accessibilityHidden(true)
    }
}

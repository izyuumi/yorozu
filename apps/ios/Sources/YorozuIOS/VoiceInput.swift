import AVFoundation
import SwiftUI

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
    private var loading: Task<Transcriber, Error>?
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
            let model = VoiceModel.shared
            let (modelURL, projector) = (model.modelURL, model.projectorURL)
            // Load while the owner speaks, so only the transcription itself is left after ✓.
            loading = Task.detached(priority: .userInitiated) { try Transcriber(model: modelURL, projector: projector) }
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

/// A finished recording and the model load started while it was spoken.
struct VoiceClip {
    let samples: [Float]
    var loading: Task<Transcriber, Error>?

    /// The transcript in the chosen language; an empty one counts as a failure.
    @MainActor func transcribe() async -> Result<String, Error> {
        let language = Transcriber.Language(rawValue: UserDefaults.standard.string(forKey: VoiceModel.languageKey) ?? "") ?? .automatic
        let model = VoiceModel.shared
        let (modelURL, projector) = (model.modelURL, model.projectorURL)
        let loading = loading ?? Task.detached(priority: .userInitiated) { try Transcriber(model: modelURL, projector: projector) }
        let samples = samples
        let work = Task.detached(priority: .userInitiated) { () -> Result<String, Error> in
            do { return .success(try await loading.value.transcribe(samples, language: language)) } catch { return .failure(error) }
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

    private let sendCircle: CGFloat = 32

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
                icon("stop.circle.fill", label: String(localized: "Insert Transcript")) { session.finish(onInsert) }
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
            Image(systemName: symbol).textStyle(.body, weight: .semibold).frame(width: controlTarget, height: controlTarget)
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(Text(label))
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

/// Settings › Voice Input: the opt-in switch, the model download, the language and the model's license.
struct VoiceInputSection: View {
    @AppStorage(VoiceModel.enabledKey) private var enabled = false
    @AppStorage(VoiceModel.languageKey) private var language = Transcriber.Language.automatic
    @State private var deleting = false
    @State private var confirmingCellular = false
    private let model = VoiceModel.shared

    var body: some View {
        Section {
            Toggle(String(localized: "Voice Input"), isOn: $enabled)
                .disabled(!VoiceModel.supported)
                .onChange(of: enabled) { _, on in on ? model.start() : model.pause() }
            if enabled, VoiceModel.supported {
                status
                Picker(String(localized: "Language"), selection: $language) {
                    Text("Automatic").tag(Transcriber.Language.automatic)
                    ForEach(Transcriber.Language.allCases.dropFirst()) { Text(verbatim: $0.name).tag($0) }
                }
            }
            if model.hasFiles {
                Button(String(localized: "Delete Model"), role: .destructive) { deleting = true }
            }
        } header: {
            Text("Voice Input")
        } footer: {
            VStack(alignment: .leading, spacing: LayoutMetrics.tight) {
                if VoiceModel.supported {
                    Text("Speak a message instead of typing it. Speech is transcribed on this device; turning this on downloads the \(Self.size(VoiceModel.totalBytes)) model from Hugging Face.")
                } else {
                    Text("This device needs more memory for voice input.")
                }
                Text("The model is LFM3-Audio-2B by Liquid AI, under the [LFM Open License v1.0](https://huggingface.co/LiquidAI/LFM3-Audio-2B-GGUF/blob/main/LICENSE).")
            }
        }
        .task { if enabled, VoiceModel.supported { model.start() } }
        .confirmationDialog(String(localized: "Delete the voice model?"), isPresented: $deleting, titleVisibility: .visible) {
            Button(String(localized: "Delete Model"), role: .destructive) {
                enabled = false
                model.delete()
            }
        } message: {
            Text("Voice input turns off. Turning it on again downloads the model again.")
        }
        .confirmationDialog(String(localized: "Download using cellular data?"), isPresented: $confirmingCellular, titleVisibility: .visible) {
            Button(String(localized: "Download Using Cellular")) { model.start(cellular: true) }
        } message: {
            Text("Up to \(Self.size(VoiceModel.totalBytes - model.received)) more will be downloaded over cellular or a personal hotspot. Charges may apply.")
        }
    }

    @ViewBuilder private var status: some View {
        switch model.state {
        case .ready:
            LabeledContent(String(localized: "Model"), value: Self.size(VoiceModel.totalBytes))
        case .downloading:
            ProgressView(value: Double(model.received), total: Double(VoiceModel.totalBytes)) {
                Text("Downloading the model…")
            } currentValueLabel: {
                Text("\(Self.size(model.received)) of \(Self.size(VoiceModel.totalBytes))")
            }
            if model.waitingForWiFi {
                Text("Waiting for Wi-Fi. The model downloads on Wi-Fi so it doesn’t use cellular data.")
                    .foregroundStyle(.secondary)
                Button(String(localized: "Download Using Cellular…")) { confirmingCellular = true }
            }
        case .absent:
            Button(String(localized: "Download the Model")) { model.start() }
        case .failed(let message):
            Text(message).foregroundStyle(YorozuPalette.warning)
            Button(String(localized: "Try Again")) { model.start() }
        }
    }

    private static func size(_ bytes: Int64) -> String { bytes.formatted(.byteCount(style: .file)) }
}

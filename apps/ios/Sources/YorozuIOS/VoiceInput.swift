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

    func retry() {
        guard let deliver, !clip.isEmpty else { return cancel() }
        phase = .transcribing
        let clip = clip
        let language = Transcriber.Language(rawValue: UserDefaults.standard.string(forKey: VoiceModel.languageKey) ?? "") ?? .automatic
        let model = VoiceModel.shared
        let (modelURL, projector) = (model.modelURL, model.projectorURL)
        let loading = loading ?? Task.detached(priority: .userInitiated) { try Transcriber(model: modelURL, projector: projector) }
        self.loading = nil
        job = Task {
            let work = Task.detached(priority: .userInitiated) { () -> Result<String, Error> in
                do { return .success(try await loading.value.transcribe(clip, language: language)) } catch { return .failure(error) }
            }
            let result = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            guard !Task.isCancelled else { return }
            switch result {
            case .success(let text) where !text.isEmpty:
                reset()
                deliver(text)
            case .success:
                phase = .failed(String(localized: "No speech was recognized."))
            case .failure(let error):
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

/// Replaces the composer's row while dictating: ✕, a waveform and timer (or progress, or an error with Retry),
/// ✓ to put the text in the field, and send to post it at once.
struct VoiceBar: View {
    let session: VoiceSession
    let onInsert: (String) -> Void
    let onSend: (String) -> Void
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
                icon("checkmark", label: String(localized: "Insert Transcript")) { session.finish(onInsert) }
                    .keyboardShortcut(.defaultAction)
                Button { session.finish(onSend) } label: {
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
                    Text(verbatim: "日本語").tag(Transcriber.Language.japanese)
                    Text(verbatim: "English").tag(Transcriber.Language.english)
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
        case .absent:
            Button(String(localized: "Download the Model")) { model.start() }
        case .failed(let message):
            Text(message).foregroundStyle(YorozuPalette.warning)
            Button(String(localized: "Try Again")) { model.start() }
        }
    }

    private static func size(_ bytes: Int64) -> String { bytes.formatted(.byteCount(style: .file)) }
}

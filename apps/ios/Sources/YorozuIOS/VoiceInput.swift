import AVFoundation
import SpeechEngines
import SwiftUI
import VoiceText

/// One conversation's dictation: record, then transcribe into its composer or straight into a message. `Dictation`
/// owns it app-wide, so the composer, the Live Activity's Stop and Cancel and the Talk control drive the same one,
/// in front or in the background. The clip stays on disk (`ClipStore`) until its text reaches the composer or the
/// owner cancels, so neither a failure nor the app closing loses it. Its Live Activity row carries no content.
@MainActor @Observable
final class VoiceSession {
    enum Phase: Equatable {
        case idle, recording, transcribing
        case failed(String)
    }

    let convId: String
    private(set) var phase = Phase.idle
    var micDenied = false
    /// Text for the composer to take (`delivered()`); it puts it at the cursor.
    private(set) var transcript: String?
    /// Why the last recording stopped on its own.
    var notice: String?
    var recorder: VoiceRecorder { Dictation.shared.recorder }
    /// Transcribing waits for the app to come forward: the engine needs the GPU, or the background time ran out.
    @ObservationIgnored private(set) var queued = false
    @ObservationIgnored private var clip: [Float] = []
    @ObservationIgnored private var clipID: UUID?
    /// Clips whose text waits in `transcript`.
    @ObservationIgnored private var awaiting: [UUID] = []
    @ObservationIgnored private var loading: Task<any SpeechEngine, Error>?
    @ObservationIgnored private var job: Task<Void, Never>?
    @ObservationIgnored private var row: YorozuJob?
    @ObservationIgnored private var capped = false
    @ObservationIgnored private var handingOff = false
    @ObservationIgnored private var handed: VoiceClip?

    init(convId: String) { self.convId = convId }

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
        guard phase == .idle else { return }
        Dictation.shared.willRecord(self)
        let id = UUID()
        let writer = Dictation.shared.beginClip(id, convId: convId)
        do {
            try recorder.start(writer: writer)
        } catch {
            if writer != nil {
                Task { await recorder.closeClip(); Dictation.shared.delete(id) }
            }
            phase = .failed(error.localizedDescription)
            return
        }
        clipID = writer == nil ? nil : id
        capped = false
        notice = nil
        phase = .recording
        showRow(.recording)
        // Load while the owner speaks, so only the transcription itself is left after ✓.
        loading = VoiceSetup.shared.load()
    }

    /// Stops recording and transcribes into the composer; never sends.
    func stop(_ reason: StopReason = .user) {
        guard phase == .recording else { return }
        recorder.send(.stop(reason))
    }

    /// Picks up after an interruption that ended without letting the recording resume by itself.
    func resume() { recorder.send(.resumeRequested) }

    /// Stops recording and hands the clip over, leaving the composer free; nil unless recording.
    func handOff() -> VoiceClip? {
        guard phase == .recording else { return nil }
        handingOff = true
        recorder.send(.stop(.user))
        handingOff = false
        defer { handed = nil }
        return handed
    }

    /// What the recorder's machine asks for once it moved on.
    func handle(_ effect: RecordingEffect) {
        switch effect {
        case .updateActivity:
            if phase == .recording { showRow(.recording) }
        case .announceCap:
            capped = true
            notice = String(localized: "Recording stopped at the 5-minute limit.")
            Dictation.shared.notify(.cap, convId: convId)
        case .discardClip:
            let id = clipID
            Task { await recorder.closeClip(); if let id { Dictation.shared.delete(id) } }
            loading?.cancel()
            removeRow()
            reset()
        case .persistClip:
            clip = recorder.samples()
            let id = clipID
            Task { await recorder.closeClip(); if let id { Dictation.shared.seal(id) } }
            guard handingOff else { return retry() }
            handed = clip.isEmpty ? nil : VoiceClip(samples: clip, loading: loading, id: id)
            if handed == nil, let id { Dictation.shared.delete(id) }
            loading = nil
            clipID = nil
            removeRow()
            reset()
        case .startEngine, .pauseEngine, .resumeEngine, .restartEngine, .stopEngine:
            break
        }
    }

    /// A clip an earlier run of the app left on disk.
    func recover(_ samples: [Float], id: UUID) -> Bool {
        guard phase == .idle else { return false }
        clip = samples
        clipID = id
        retry()
        return true
    }

    func retry() {
        guard !clip.isEmpty else { return cancel() }
        phase = .transcribing
        queued = false
        showRow(.transcribing)
        let voice = VoiceClip(samples: clip, loading: loading, id: clipID)
        loading = nil
        job = Task {
            guard let result = await Dictation.transcribe(voice) else { return queued = true }
            guard !Task.isCancelled else { return }
            switch result {
            case .success(let text):
                land(text)
            case .failure(let error):
                phase = .failed(error is CancellationError ? String(localized: "Transcription was stopped.") : error.localizedDescription)
                finishRow(.failed, alert: .localFailure)
            }
        }
    }

    /// The composer took `transcript`: its clips can go.
    func delivered() {
        transcript = nil
        for id in awaiting { Dictation.shared.delete(id) }
        awaiting = []
    }

    func cancel() {
        guard phase != .recording else { return recorder.send(.cancel) }
        if let clipID { Dictation.shared.delete(clipID) }
        loading?.cancel()
        removeRow()
        reset()
    }

    private func land(_ text: String) {
        let background = Dictation.inBackground
        transcript = transcript.map { $0 + " " + text } ?? text
        if let clipID { awaiting.append(clipID) }
        clipID = nil
        finishRow(.done, alert: background ? (capped ? .recordingCap : .transcriptReady) : nil)
        if background { Dictation.shared.notify(.transcriptReady, convId: convId) }
        reset()
    }

    private func reset() {
        job?.cancel()
        job = nil
        loading = nil
        clip = []
        clipID = nil
        queued = false
        capped = false
        row = nil
        phase = .idle
    }

    // MARK: The Live Activity row

    private func showRow(_ kind: YorozuJob.Kind) {
        #if os(iOS)
        var job = row ?? YorozuJob(kind: kind, startedAt: Date())
        if job.kind != kind || job.finished { job.startedAt = Date() }
        job.kind = kind
        job.state = .running
        row = job
        YorozuActivities.shared?.upsert(job, convId: convId, title: Dictation.shared.title(convId))
        #endif
    }

    private func finishRow(_ state: YorozuJob.State, alert: JobEvent.Alert?) {
        #if os(iOS)
        if let row { YorozuActivities.shared?.finish(id: row.token, state: state, alert: alert) }
        #endif
        if state != .failed { row = nil }
    }

    private func removeRow() {
        #if os(iOS)
        if let row { YorozuActivities.shared?.remove(id: row.token) }
        #endif
        row = nil
    }
}

/// A finished recording, the engine load started while it was spoken, and its clip on disk, if any.
struct VoiceClip {
    let samples: [Float]
    var loading: Task<any SpeechEngine, Error>?
    var id: UUID?

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

    /// Also once its message went out: the clip's file goes with it.
    func discard(_ id: UUID, in convId: String) {
        if let clip = work[id]?.clip.id { Dictation.shared.delete(clip) }
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

/// Replaces the composer's row while dictating: ✕, a waveform and timer (or Paused during a call, or progress, or
/// an error with Retry), stop to put the text in the field, and send to post it as a message that transcribes in the chat.
struct VoiceBar: View {
    let session: VoiceSession
    let onSend: () -> Void
    @Environment(\.accent) private var accent

    private let sendCircle = LayoutMetrics.controlCircle

    var body: some View {
        HStack(spacing: 0) {
            icon("xmark", label: String(localized: "Cancel")) { session.cancel() }
                .keyboardShortcut(.cancelAction)
            Group {
                switch session.phase {
                case .recording where session.recorder.phase != .recording:
                    HStack(spacing: LayoutMetrics.inner) {
                        Image(systemName: "pause.fill").foregroundStyle(.secondary)
                        Text("Paused").textStyle(.body).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        if session.recorder.phase == .interrupted(resumable: false) {
                            icon("mic.fill", label: String(localized: "Resume")) { session.resume() }
                        }
                    }
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
                        Text(session.notice ?? String(localized: "Transcribing…")).textStyle(.body).foregroundStyle(.secondary).lineLimit(2)
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
                icon("stop.fill", label: String(localized: "Insert Transcript")) { session.stop() }
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

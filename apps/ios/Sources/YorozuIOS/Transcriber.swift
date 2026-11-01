import Foundation
import SpeechEngines
import VoiceText
#if canImport(llama)
import llama
#endif

/// Speech to text on this device: LFM3-Audio-2B through llama.cpp's multimodal library (`mtmd`).
/// Blocking and not thread-safe: create and use it inside one background task.
final class Transcriber: @unchecked Sendable {
    static let sampleRate = 16_000
    /// Positions per decode: the audio, the prompt and the transcript. A clip that doesn't fit is transcribed
    /// in windows (`AudioWindowPlan`).
    static let contextTokens: UInt32 = 8_192

    /// LFM3-Audio's instruction: transcribe, in the language if one is set, spelling the hints as given.
    static func prompt(language: VoiceLanguage, hints: [String]) -> String {
        var prompt = language == .automatic ? "Perform ASR." : "Perform ASR in \(language.rawValue.capitalized)."
        if !hints.isEmpty { prompt += " Vocabulary: " + hints.joined(separator: ", ") + "." }
        return prompt
    }

    /// One decode: its text, and whether it was still writing when its token budget or the context ran out,
    /// which speech never needs (`TranscriptBudget`).
    struct Decoded: Equatable {
        let text: String
        let reachedLimit: Bool
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    #if canImport(llama)
    static let available = true
    private static let backend: Void = llama_backend_init()
    private let model: OpaquePointer
    private let media: OpaquePointer

    init(model modelURL: URL, projector: URL) throws {
        _ = Self.backend
        guard let model = llama_model_load_from_file(modelURL.path, llama_model_default_params()) else {
            throw Failure(String(localized: "The voice model could not be loaded."))
        }
        var params = mtmd_context_params_default()
        params.print_timings = false
        params.warmup = false
        guard let media = mtmd_init_from_file(projector.path, model, params) else {
            llama_model_free(model)
            throw Failure(String(localized: "The voice model could not be loaded."))
        }
        guard mtmd_support_audio(media), mtmd_get_audio_sample_rate(media) == Int32(Self.sampleRate) else {
            mtmd_free(media)
            llama_model_free(model)
            throw Failure(String(localized: "The voice model could not be loaded."))
        }
        self.model = model
        self.media = media
    }

    deinit {
        mtmd_free(media)
        llama_model_free(model)
    }

    /// Transcribes 16 kHz mono PCM with greedy decoding, generating at most `maxTokens` tokens. Stops early when
    /// the calling task is cancelled. Audio that leaves no room for `maxTokens` in the context is not decoded
    /// and reported as `reachedLimit`, never truncated silently.
    func decode(_ samples: ArraySlice<Float>, language: VoiceLanguage, hints: [String], maxTokens: Int) throws -> Decoded {
        var params = llama_context_default_params()
        params.n_ctx = Self.contextTokens
        guard let context = llama_init_from_model(model, params) else { throw Failure(String(localized: "Not enough memory to transcribe.")) }
        defer { llama_free(context) }

        let prompt = try chatPrompt(system: Self.prompt(language: language, hints: hints), user: String(cString: mtmd_default_marker()))
        guard let chunks = mtmd_input_chunks_init() else { throw Failure(String(localized: "Transcription failed.")) }
        defer { mtmd_input_chunks_free(chunks) }
        guard let audio = samples.withUnsafeBufferPointer({ mtmd_bitmap_init_from_audio($0.count, $0.baseAddress) }) else {
            throw Failure(String(localized: "Transcription failed."))
        }
        defer { mtmd_bitmap_free(audio) }
        let tokenized = prompt.withCString { text in
            var input = mtmd_input_text(text: text, text_len: strlen(text), add_special: true, parse_special: true)
            var bitmaps: [OpaquePointer?] = [audio]
            return mtmd_tokenize(media, chunks, &input, &bitmaps, 1)
        }
        guard tokenized == 0 else { throw Failure(String(localized: "Transcription failed.")) }
        // The window plan keeps the audio, the prompt and the budget inside the context; one that doesn't fit
        // (a long hint list) is not decoded but counts as cut short, so `transcribe` retries or fails.
        guard Int(mtmd_helper_get_n_pos(chunks)) + maxTokens <= Int(Self.contextTokens) else {
            return Decoded(text: "", reachedLimit: true)
        }
        try Task.checkCancellation()

        var position: llama_pos = 0
        guard mtmd_helper_eval_chunks(media, context, chunks, 0, 0, Int32(llama_n_batch(context)), true, &position) == 0 else {
            throw Failure(String(localized: "Transcription failed."))
        }

        let vocab = llama_model_get_vocab(model)
        guard let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params()) else {
            throw Failure(String(localized: "Transcription failed."))
        }
        defer { llama_sampler_free(sampler) }
        llama_sampler_chain_add(sampler, llama_sampler_init_greedy())

        var bytes: [CChar] = []
        var piece = [CChar](repeating: 0, count: 256)
        var generated = 0
        var reachedLimit = true
        while generated < maxTokens, position < Int32(Self.contextTokens) {
            try Task.checkCancellation()
            var token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocab, token) {
                reachedLimit = false
                break
            }
            let count = llama_token_to_piece(vocab, token, &piece, Int32(piece.count), 0, false)
            if count > 0 { bytes.append(contentsOf: piece[0..<Int(count)]) }
            guard llama_decode(context, llama_batch_get_one(&token, 1)) == 0 else { throw Failure(String(localized: "Transcription failed.")) }
            position += 1
            generated += 1
        }
        let text = String(decoding: bytes.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return Decoded(text: text.trimmingCharacters(in: .whitespacesAndNewlines), reachedLimit: reachedLimit)
    }

    private func chatPrompt(system: String, user: String) throws -> String {
        let template = llama_model_chat_template(model, nil)
        return try system.withCString { system in
            try user.withCString { user in
                let roles = (strdup("system"), strdup("user"))
                defer { free(roles.0); free(roles.1) }
                let messages = [llama_chat_message(role: roles.0, content: system), llama_chat_message(role: roles.1, content: user)]
                var buffer = [CChar](repeating: 0, count: 1_024)
                var length = llama_chat_apply_template(template, messages, messages.count, true, &buffer, Int32(buffer.count))
                if length > Int32(buffer.count) {
                    buffer = [CChar](repeating: 0, count: Int(length))
                    length = llama_chat_apply_template(template, messages, messages.count, true, &buffer, Int32(buffer.count))
                }
                guard length > 0 else { throw Failure(String(localized: "Transcription failed.")) }
                return String(decoding: buffer[0..<Int(length)].map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
        }
    }
    #else
    // llama.cpp's xcframework has no iOS Simulator slice, so a simulator build (generated with
    // TUIST_VOICE_INPUT=0) leaves it out and has no voice input.
    static let available = false
    init(model: URL, projector: URL) throws { throw Failure(String(localized: "The voice model could not be loaded.")) }
    func decode(_ samples: ArraySlice<Float>, language: VoiceLanguage, hints: [String], maxTokens: Int) throws -> Decoded {
        Decoded(text: "", reachedLimit: false)
    }
    #endif
}

extension Transcriber: SpeechEngine {
    func transcribe(_ samples: [Float], language: String?, hints: [String]) async throws -> String {
        try await transcribe(samples, language: language, hints: hints, progress: nil)
    }

    /// How many times a failed window is halved again (`AudioWindowPlan.split`) before the clip fails.
    static let splitDepth = 2
    /// Speech in a window of a longer clip that must come back as some text; LFM3-Audio sometimes ends a
    /// window early without a word.
    static let emptySpeechSeconds = 3.0

    /// A clip too long for one decode is transcribed window by window (`AudioWindowPlan`), skipping silent
    /// ones, and the windows' transcripts joined (`TranscriptSeam`). A window whose transcript is sparse
    /// beside the others' (`TranscriptDensity`) is decoded again in halves, once, and their transcript kept
    /// only if it says clearly more; a half that fails keeps the window's own. `progress` hears each window
    /// before it is decoded: its index, the window count and the window, or the part of it a retry decodes.
    func transcribe(
        _ samples: [Float], language: String?, hints: [String],
        progress: ((Int, Int, AudioWindow) -> Void)?
    ) async throws -> String {
        let language = language.map(VoiceLanguage.init(code:)) ?? .automatic
        let activity = VoiceActivity(samples: samples, sampleRate: Self.sampleRate)
        let windows = AudioWindowPlan.windows(
            sampleCount: samples.count, sampleRate: Self.sampleRate, activity: activity, contextTokens: Int(Self.contextTokens)
        )
        var parts: [(index: Int, text: String, speechSeconds: Double)] = []
        for (index, window) in windows.enumerated() {
            try Task.checkCancellation()
            // A clip decoded whole is decoded even when it seems silent, as before windows existed.
            guard window.voiced || windows.count == 1 else { continue }
            let text = try transcribe(
                window, of: samples, activity: activity, language: language, hints: hints,
                alone: windows.count == 1, depth: 0, progress: { progress?(index, windows.count, $0) }
            )
            parts.append((index, text, window.speechSeconds))
        }
        for part in TranscriptDensity.sparse(parts.map { ($0.text, $0.speechSeconds) }) {
            let index = parts[part].index
            guard let halves = AudioWindowPlan.split(windows[index], sampleRate: Self.sampleRate, activity: activity)
            else { continue }
            var texts: [String] = []
            for half in halves {
                try Task.checkCancellation()
                progress?(index, windows.count, half)
                guard let text = try? transcript(samples[half.range], language: language, hints: hints) else { break }
                texts.append(text)
            }
            guard texts.count == halves.count else { continue }
            let joined = TranscriptSeam.join(texts, overlapSpeechSeconds: Self.seams(halves, activity: activity))
            if TranscriptDensity.isBetter(joined, than: parts[part].text) {
                parts[part].text = joined
            }
        }
        // A half's decode stops on cancellation without throwing (`try?` above).
        try Task.checkCancellation()
        // Only consecutive windows share audio; one skipped as silent between two parts leaves none.
        let seams = zip(parts, parts.dropFirst()).map { previous, next in
            next.index == previous.index + 1
                ? AudioWindowPlan.overlapSpeechSeconds(windows[previous.index], windows[next.index], activity: activity) : 0
        }
        return TranscriptSeam.join(parts.map(\.text), overlapSpeechSeconds: seams)
    }

    /// The speech each pair of consecutive `windows` both hear, for `TranscriptSeam.join`.
    static func seams(_ windows: [AudioWindow], activity: VoiceActivity) -> [Double] {
        zip(windows, windows.dropFirst()).map { AudioWindowPlan.overlapSpeechSeconds($0, $1, activity: activity) }
    }

    /// One window, or part of one. A window with speech that fails (`transcript`), or one of a longer clip
    /// that comes back empty despite `emptySpeechSeconds` of speech or stops before its end (`reachesEnd`),
    /// is decoded again in two halves (`AudioWindowPlan.split`), up to `splitDepth` times; LFM3-Audio's
    /// misses are occasional, and a part decoded on its own usually comes out whole. Only a part that can't
    /// be split further fails the clip, rather than leave a hole in it; a silent window recognized nothing.
    private func transcribe(
        _ window: AudioWindow, of samples: [Float], activity: VoiceActivity, language: VoiceLanguage, hints: [String],
        alone: Bool, depth: Int, progress: (AudioWindow) -> Void
    ) throws -> String {
        progress(window)
        let text = try transcript(samples[window.range], language: language, hints: hints)
        let missing = text?.isEmpty == true && !alone && window.speechSeconds >= Self.emptySpeechSeconds
        if let text, !missing,
           try reachesEnd(text, of: window, samples: samples, activity: activity, language: language, hints: hints) {
            return text
        }
        guard window.voiced else { return text ?? "" }
        if depth < Self.splitDepth,
           let halves = AudioWindowPlan.split(window, sampleRate: Self.sampleRate, activity: activity) {
            var parts: [String] = []
            for half in halves {
                try Task.checkCancellation()
                parts.append(try transcribe(half, of: samples, activity: activity, language: language, hints: hints,
                                            alone: false, depth: depth + 1, progress: progress))
            }
            return TranscriptSeam.join(parts, overlapSpeechSeconds: Self.seams(halves, activity: activity))
        }
        throw Failure(String(localized: "Part of the recording couldn’t be transcribed. Try again."))
    }

    /// Whether `text` ends with what the window's last seconds, decoded on their own, say (`TranscriptTail`);
    /// true when the window isn't probed or the probe's decode fails.
    private func reachesEnd(
        _ text: String, of window: AudioWindow, samples: [Float], activity: VoiceActivity, language: VoiceLanguage,
        hints: [String]
    ) throws -> Bool {
        guard let probe = TranscriptTail.probe(of: window, sampleRate: Self.sampleRate, activity: activity) else { return true }
        try Task.checkCancellation()
        guard let tail = try transcript(samples[probe.range], language: language, hints: hints) else { return true }
        return TranscriptTail.covers(text, tail: tail)
    }

    /// One decode's transcript, nil when it failed. With hints, LFM3-Audio can loop or read the vocabulary
    /// back on audio it can't make out; such a transcript is replaced by one decoded without hints. A decode
    /// that outruns the window's token budget is a loop too, cut short. If the transcript without hints is
    /// no better, the decode failed.
    private func transcript(_ samples: ArraySlice<Float>, language: VoiceLanguage, hints: [String]) throws -> String? {
        let budget = TranscriptBudget.maxTokens(seconds: Double(samples.count) / Double(Self.sampleRate))
        let first = try decode(samples, language: language, hints: hints, maxTokens: budget)
        if !first.reachedLimit, hints.isEmpty || TranscriptDegeneration.detect(in: first.text, hints: hints) == nil {
            return first.text
        }
        var retry = first
        if !hints.isEmpty {
            try Task.checkCancellation()
            retry = try decode(samples, language: language, hints: [], maxTokens: budget)
        }
        guard retry.reachedLimit || TranscriptDegeneration.detect(in: retry.text, hints: []) != nil else { return retry.text }
        return nil
    }
}

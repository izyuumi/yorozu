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
    private static let contextTokens: UInt32 = 8_192
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
    /// the calling task is cancelled.
    func decode(_ samples: [Float], language: VoiceLanguage, hints: [String], maxTokens: Int) throws -> Decoded {
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
    func decode(_ samples: [Float], language: VoiceLanguage, hints: [String], maxTokens: Int) throws -> Decoded {
        Decoded(text: "", reachedLimit: false)
    }
    #endif
}

extension Transcriber: SpeechEngine {
    /// With hints, LFM3-Audio can loop or read the vocabulary back on audio it can't make out; such a
    /// transcript is replaced by one decoded without hints. A decode that outruns the clip's token budget is
    /// a loop too, cut short. If the transcript without hints is no better, nothing was recognized.
    func transcribe(_ samples: [Float], language: String?, hints: [String]) async throws -> String {
        let language = language.map(VoiceLanguage.init(code:)) ?? .automatic
        let budget = TranscriptBudget.maxTokens(seconds: Double(samples.count) / Double(Self.sampleRate))
        let first = try decode(samples, language: language, hints: hints, maxTokens: budget)
        if !first.reachedLimit, hints.isEmpty || TranscriptDegeneration.detect(in: first.text, hints: hints) == nil {
            return first.text
        }
        guard !hints.isEmpty else { return "" }
        let retry = try decode(samples, language: language, hints: [], maxTokens: budget)
        return retry.reachedLimit || TranscriptDegeneration.detect(in: retry.text, hints: []) != nil ? "" : retry.text
    }
}

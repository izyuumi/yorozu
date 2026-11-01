import Foundation
import WhisperKit

/// Whisper (CoreML, through WhisperKit) from a folder holding the model and its tokenizer; never downloads.
public actor WhisperSpeechEngine: SpeechEngine {
    private let kit: WhisperKit

    public init(folder: URL) async throws {
        let config = WhisperKitConfig(
            modelFolder: folder.path, tokenizerFolder: folder, verbose: false, logLevel: .error,
            prewarm: false, load: true, download: false)
        do {
            kit = try await WhisperKit(config)
        } catch {
            throw SpeechEngineError.modelUnavailable
        }
    }

    public func transcribe(_ samples: [Float], language: String?, hints: [String]) async throws -> String {
        var options = DecodingOptions(
            task: .transcribe, language: language, usePrefillPrompt: true, detectLanguage: language == nil,
            skipSpecialTokens: true, withoutTimestamps: true, chunkingStrategy: .vad)
        // Whisper's "initial prompt": earlier text the decoder continues from, which steers spelling.
        if !hints.isEmpty, let tokenizer = kit.tokenizer {
            options.promptTokens = tokenizer.encode(text: " " + hints.joined(separator: ", "))
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
        }
        let results = try await kit.transcribe(audioArray: samples, decodeOptions: options)
        try Task.checkCancellation()
        return results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

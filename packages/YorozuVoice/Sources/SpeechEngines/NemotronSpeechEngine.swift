import FluidAudio
import Foundation

/// Nemotron 3.5 ASR Streaming (CoreML, through FluidAudio) from a folder holding the encoder, the fused
/// decoder, `metadata.json` and `tokenizer.json`. Apple silicon only.
public actor NemotronSpeechEngine: SpeechEngine {
    private let manager: StreamingNemotronMultilingualAsrManager

    public init(folder: URL) async throws {
        #if arch(arm64)
        manager = StreamingNemotronMultilingualAsrManager()
        do {
            try await manager.loadModels(from: folder)
        } catch {
            throw SpeechEngineError.modelUnavailable
        }
        #else
        throw SpeechEngineError.unsupportedHardware
        #endif
    }

    public func transcribe(_ samples: [Float], language: String?, hints: [String]) async throws -> String {
        await manager.reset()
        await manager.setLanguage(Self.prompt(for: language))
        await manager.setCustomVocabulary(hints.map { CustomVocabularyTerm(text: $0) })
        _ = try await manager.process(samples: samples)
        try Task.checkCancellation()
        return try await manager.finish().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The model's prompt keys are mostly region-qualified; nil picks its automatic prompt.
    static func prompt(for language: String?) -> String? {
        switch language {
        case nil: nil
        case "zh": "zh-CN"
        case "ja": "ja-JP"
        case "he": "he-IL"
        case let code?: code
        }
    }
}

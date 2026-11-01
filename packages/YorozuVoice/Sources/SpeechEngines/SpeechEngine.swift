import Foundation

/// One speech-to-text engine with its model loaded. Voice input records 16 kHz mono and hands the whole clip
/// over; each engine turns it into text with its own runtime.
public protocol SpeechEngine: Sendable {
    /// Transcribes 16 kHz mono PCM. `language` is an ISO 639-1 code, nil to let the engine tell; `hints` are
    /// words the owner expects (their voice dictionary), for engines that can be steered with them.
    func transcribe(_ samples: [Float], language: String?, hints: [String]) async throws -> String
}

public enum SpeechEngineError: Error, Equatable, Sendable {
    /// The model files are missing or could not be loaded.
    case modelUnavailable
    /// The system has no speech model for the language (Apple's), or it is not installed yet.
    case languageUnavailable
    /// The engine needs Apple silicon (Nemotron on an Intel Mac).
    case unsupportedHardware
}

public let speechSampleRate = 16_000

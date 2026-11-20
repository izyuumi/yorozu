import Foundation

public protocol SpeechEngine: Sendable {
    func transcribe(_ samples: [Float], language: String?, hints: [String]) async throws -> String
}

public enum SpeechEngineError: Error, Equatable, Sendable {
    case modelUnavailable
    case languageUnavailable
    case unsupportedHardware
}

public let speechSampleRate = 16_000

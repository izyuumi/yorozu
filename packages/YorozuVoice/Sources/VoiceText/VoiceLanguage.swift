import Foundation

/// The languages voice input can be told to expect; the raw value is stored in settings and is the English
/// name LFM3-Audio's prompt takes.
public enum VoiceLanguage: String, CaseIterable, Identifiable, Sendable {
    case automatic, arabic, chinese, danish, dutch, english, finnish, french, german, greek, hebrew, italian,
        japanese, korean, polish, portuguese, spanish, swedish, turkish

    public var id: Self { self }

    /// The ISO 639-1 code; nil for automatic.
    public var code: String? {
        switch self {
        case .automatic: nil
        case .arabic: "ar"
        case .chinese: "zh"
        case .danish: "da"
        case .dutch: "nl"
        case .english: "en"
        case .finnish: "fi"
        case .french: "fr"
        case .german: "de"
        case .greek: "el"
        case .hebrew: "he"
        case .italian: "it"
        case .japanese: "ja"
        case .korean: "ko"
        case .polish: "pl"
        case .portuguese: "pt"
        case .spanish: "es"
        case .swedish: "sv"
        case .turkish: "tr"
        }
    }

    /// The language's name in itself, as the system writes it; empty for automatic.
    public var name: String {
        guard let code else { return "" }
        let locale = Locale(identifier: code)
        return locale.localizedString(forLanguageCode: code)?.capitalized(with: locale) ?? rawValue.capitalized
    }

    public init(code: String) {
        self = Self.allCases.first { $0.code == code } ?? .automatic
    }
}

extension VoiceEngineID {
    /// The languages the picker offers for the engine; nil when the system decides (Apple's).
    public var languages: [VoiceLanguage]? {
        switch self {
        case .apple: nil
        case .lfm, .whisperTurbo, .whisperSmall: VoiceLanguage.allCases
        // The languages NVIDIA lists as supported; the model takes more prompts, unevaluated.
        case .nemotron: [.automatic, .chinese, .english, .french, .german, .italian, .japanese, .portuguese, .spanish]
        }
    }

    /// The device RAM the engine needs, as devices are sold (GB); nil for Apple's.
    public var memoryGB: Int? {
        switch self {
        case .apple: nil
        case .lfm, .whisperTurbo: 6
        case .whisperSmall, .nemotron: 4
        }
    }
}

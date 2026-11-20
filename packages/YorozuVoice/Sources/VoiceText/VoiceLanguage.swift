import Foundation

public enum VoiceLanguage: String, CaseIterable, Identifiable, Sendable {
    case automatic, arabic, chinese, danish, dutch, english, finnish, french, german, greek, hebrew, italian,
        japanese, korean, polish, portuguese, spanish, swedish, turkish

    public var id: Self { self }

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
    public var languages: [VoiceLanguage]? {
        switch self {
        case .apple: nil
        case .lfm, .whisperTurbo, .whisperSmall: VoiceLanguage.allCases
        case .nemotron: [.automatic, .chinese, .english, .french, .german, .italian, .japanese, .portuguese, .spanish]
        }
    }

    public var memoryGB: Int? {
        switch self {
        case .apple: nil
        case .lfm, .whisperTurbo: 6
        case .whisperSmall, .nemotron: 4
        }
    }
}

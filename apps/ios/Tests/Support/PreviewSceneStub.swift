// Preview playback is off in tests (no --preview-scene), so the stub keeps AppModel's real lifecycle path.
#if DEBUG
import YorozuWire

enum PreviewScene {
    static let current: PreviewScene? = nil

    var pauses: [Duration] { [] }

    static let tidyID = ""
    static var tidyTitle: String { "" }
    static var tidy: [(HistoryItem.Kind, String)] { [] }

    static let cardID = ""
    static var cardTitle: String? { nil }
    static func card(at ts: Int64) -> [HistoryItem]? { nil }

    static func reply(to text: String) -> String? { nil }

    @MainActor func play(model: AppModel) {}
}
#endif

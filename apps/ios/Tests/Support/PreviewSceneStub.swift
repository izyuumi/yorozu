// Preview playback is off in tests (no --preview-scene), so the stub keeps AppModel's real lifecycle path.
#if DEBUG
import Foundation
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

    /// Set by voice tests: the recorder plays `voiceClip()` and transcription returns this.
    nonisolated(unsafe) static var transcript: String?

    /// One second of a quiet 440 Hz tone at 16 kHz.
    static func voiceClip() -> [Float] {
        (0..<16_000).map { 0.1 * Float(sin(2 * Double.pi * 440 * Double($0) / 16_000)) }
    }

    @MainActor func play(model: AppModel) {}
}
#endif

#if os(iOS)
import AppIntents

/// Stop and Cancel on the Live Activity's recording row. A `LiveActivityIntent` runs in the app's process, where the
/// app installed `handler` at launch; the widget extension only draws the buttons and never links the app's code.
@MainActor
enum RecordingControl {
    enum Action: Sendable { case stop, cancel }

    static var handler: ((Action) -> Void)?
}

/// Stops voice input and transcribes it into the message field; never sends.
struct StopRecordingIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop Recording"
    static let description = IntentDescription("Stops voice input and puts the transcript in the message field.")
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        await RecordingControl.handler?(.stop)
        return .result()
    }
}

/// Stops voice input and throws the recording away.
struct CancelRecordingIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Cancel Recording"
    static let description = IntentDescription("Stops voice input and discards the recording.")
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        await RecordingControl.handler?(.cancel)
        return .result()
    }
}
#endif

/// The Lock Screen launcher opens a fresh conversation with the keyboard up and reads no data.
enum Launcher: CaseIterable, Sendable {
    /// The composer focused.
    case ask

    var kind: String {
        switch self {
        case .ask: "to.yumi.yorozu.launcher.ask"
        }
    }

    var link: WidgetLink {
        switch self {
        case .ask: .ask
        }
    }
}

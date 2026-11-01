/// The Lock Screen launchers: each opens a fresh conversation in one input mode and reads no data.
enum Launcher: CaseIterable, Sendable {
    /// Voice input started.
    case talk
    /// The composer focused.
    case ask

    var kind: String {
        switch self {
        case .talk: "to.yumi.yorozu.launcher.talk"
        case .ask: "to.yumi.yorozu.launcher.ask"
        }
    }

    var link: WidgetLink {
        switch self {
        case .talk: .talk
        case .ask: .ask
        }
    }

    /// The SF Symbol in the badge on the mark.
    var badge: String {
        switch self {
        case .talk: "mic.fill"
        case .ask: "keyboard.fill"
        }
    }
}

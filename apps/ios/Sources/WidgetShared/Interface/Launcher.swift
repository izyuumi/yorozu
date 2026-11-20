enum Launcher: CaseIterable, Sendable {
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

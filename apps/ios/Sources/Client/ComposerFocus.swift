/// Which opens raise the iOS keyboard: only a conversation the user explicitly started.
enum ComposerFocus {
    enum Kind { case explicitNew, autoBlank, existing }

    static func iosShouldFocus(_ kind: Kind) -> Bool { kind == .explicitNew }
}

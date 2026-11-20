enum ComposerFocus {
    enum Kind { case explicitNew, autoBlank, existing }

    static func iosShouldFocus(_ kind: Kind) -> Bool { kind == .explicitNew }
}

#if os(macOS)
    import AppKit
    import Testing

    @testable import YorozuShared

    @Test func enterSendsOnlyWithTheChosenModifiers() {
        #expect(isSendKey(keyCode: 36, flags: [], sendModifiers: [], composing: false))
        #expect(isSendKey(keyCode: 76, flags: [.numericPad, .function], sendModifiers: [], composing: false))
        #expect(!isSendKey(keyCode: 36, flags: .shift, sendModifiers: [], composing: false))
        #expect(!isSendKey(keyCode: 36, flags: [], sendModifiers: .command, composing: false))
        #expect(isSendKey(keyCode: 36, flags: .command, sendModifiers: .command, composing: false))
        #expect(!isSendKey(keyCode: 36, flags: [], sendModifiers: [], composing: true))
        #expect(!isSendKey(keyCode: 49, flags: [], sendModifiers: [], composing: false))
    }
#endif

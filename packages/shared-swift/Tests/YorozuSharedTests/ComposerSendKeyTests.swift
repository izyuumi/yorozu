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

    @Test func modEnterFlipsDeliveryWithoutChangingTheChosenSendKey() {
        #expect(composerSendAction(keyCode: 36, flags: [], sendModifiers: [], composing: false) == .send(alternate: false))
        #expect(composerSendAction(keyCode: 36, flags: .command, sendModifiers: [], composing: false) == .send(alternate: true))
        // ⌘ Enter as the send key still sends normally; the flip moves to ⌥ ⌘ Enter.
        #expect(composerSendAction(keyCode: 36, flags: .command, sendModifiers: .command, composing: false) == .send(alternate: false))
        #expect(composerSendAction(keyCode: 36, flags: [.command, .option], sendModifiers: .command, composing: false) == .send(alternate: true))
        #expect(composerSendAction(keyCode: 36, flags: [.command, .shift], sendModifiers: [], composing: false) == .sendNextQueued)
        #expect(composerSendAction(keyCode: 36, flags: .shift, sendModifiers: [], composing: false) == nil)
        #expect(composerSendAction(keyCode: 36, flags: .command, sendModifiers: [], composing: true) == nil)
    }
#endif

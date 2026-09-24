import SwiftTerm
import Testing

private final class TerminalSink: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
}

/// Exact bytes emitted by @xterm/addon-serialize 0.14.0 in terminal.test.ts.
@Test func xtermSnapshotRestoresAlternateScreenInSwiftTerm() {
    let sink = TerminalSink()
    let terminal = Terminal(delegate: sink, options: TerminalOptions(cols: 20, rows: 4))
    terminal.feed(text: "one\r\ntwo\u{1B}[1B\u{1B}[3D\u{1B}[?1049h\u{1B}[H\u{1B}[31mVIM\u{1B}[0m")
    #expect(terminal.isCurrentBufferAlternate)
    #expect(terminal.bufferLine(atRow: 0)?.translateToString(trimRight: true) == "VIM")
    terminal.feed(text: "\u{1B}[?1049l")
    #expect(!terminal.isCurrentBufferAlternate)
    #expect(terminal.bufferLine(atRow: 0)?.translateToString(trimRight: true) == "one")
    #expect(terminal.bufferLine(atRow: 1)?.translateToString(trimRight: true) == "two")
}

import SwiftUI
import SwiftTerm

#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Terminal is a host session viewed from this chat. Nothing it prints becomes chat content.
public struct TerminalSheet: View {
    public let model: ChatModel
    public let thread: ThreadSummary
    @Environment(\.dismiss) private var dismiss
    @State private var selected: String?
    @State private var creating = false
    @State private var confirmingClose = false
    @State private var bridge = TerminalBridge()

    public init(model: ChatModel, thread: ThreadSummary) {
        self.model = model
        self.thread = thread
    }

    private var session: TerminalSessionData? { model.terminalSessions.first { $0.id == selected } }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Menu {
                    ForEach(model.terminalSessions) { item in
                        Button(item.title) { selected = item.id }
                    }
                } label: {
                    Label(session?.title ?? "Terminals", systemImage: "terminal")
                        .lineLimit(1)
                }
                .disabled(model.terminalSessions.isEmpty)
                Spacer(minLength: 0)
                if let session, !session.writable {
                    Button("Take Control") {
                        model.terminal(.takeover, sessionId: session.id, cols: bridge.cols, rows: bridge.rows)
                    }
                    .disabled(!model.canDeliver)
                }
                Button("New terminal", systemImage: "plus") {
                    creating = true
                    model.terminal(.create, in: thread.id, cols: bridge.cols, rows: bridge.rows)
                }
                .disabled(!model.canDeliver || creating)
                if let session, session.writable || model.terminalCanHostClose {
                    Button("Close session", systemImage: "xmark", role: .destructive) { confirmingClose = true }
                }
                Button("Done") { dismiss() }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            if selected != nil {
                TerminalSurface(bridge: bridge)
                    .id(selected)
                    .background(.black)
                    .accessibilityLabel("Host terminal")
            } else {
                ContentUnavailableView("No open terminals", systemImage: "terminal",
                    description: Text("Start one in this chat's folder."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            #if os(iOS)
            if selected != nil { keyRow }
            #endif

            if !model.canDeliver {
                Text("Host disconnected. Terminal input is paused until reconnection.")
                    .font(.caption).foregroundStyle(.secondary).padding(6)
            } else if let error = model.terminalError {
                Text(error).font(.caption).foregroundStyle(.red).padding(6)
            }
        }
        .onAppear {
            bridge.onInput = { bytes in
                guard let selected, model.canDeliver else { return }
                model.terminal(.input, sessionId: selected, data: Data(bytes))
            }
            bridge.onResize = { cols, rows in
                guard let session, session.writable, model.canDeliver else { return }
                model.terminal(.resize, sessionId: session.id, cols: cols, rows: rows)
            }
            model.onTerminalFrame = { frame in
                if frame.action == .created, creating, let id = frame.sessionId {
                    creating = false
                    selected = id
                } else {
                    bridge.receive(frame)
                }
            }
            selected = model.terminalSessions.last?.id
            bridge.select(selected)
            bridge.writable = session?.writable == true
            bridge.syncSize(session)
            model.requestTerminalStatus()
        }
        .onChange(of: selected) { old, new in
            if let old { model.terminal(.detach, sessionId: old) }
            bridge.select(new)
            bridge.writable = session?.writable == true
            bridge.syncSize(session)
        }
        .onChange(of: model.terminalSessions) { _, sessions in
            if let selected, !sessions.contains(where: { $0.id == selected }) {
                self.selected = sessions.last?.id
            } else if selected == nil && !creating {
                selected = sessions.last?.id
            }
            bridge.writable = sessions.first(where: { $0.id == selected })?.writable == true
            bridge.syncSize(sessions.first(where: { $0.id == selected }))
        }
        .task(id: "\(selected ?? ""):\(model.terminalEpoch ?? "")") {
            if let selected { model.terminal(.attach, sessionId: selected) }
        }
        .onDisappear {
            if let selected { model.terminal(.detach, sessionId: selected) }
            model.onTerminalFrame = nil
            bridge.select(nil)
        }
        .onChange(of: model.terminalError) { _, error in
            if error != nil { creating = false }
        }
        .alert("Close terminal session?", isPresented: $confirmingClose) {
            Button("Close session", role: .destructive) {
                if let selected { model.terminal(.close, sessionId: selected) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The shell and its running jobs will end. Terminal output will be discarded.")
        }
    }

    #if os(iOS)
    private var keyRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                key("Esc", [0x1b])
                key("Tab", [0x09])
                key("←", [0x1b, 0x5b, 0x44])
                key("↓", [0x1b, 0x5b, 0x42])
                key("↑", [0x1b, 0x5b, 0x41])
                key("→", [0x1b, 0x5b, 0x43])
                Menu("Ctrl") {
                    ForEach(["C", "D", "R", "A", "E", "Z"], id: \.self) { letter in
                        Button("Ctrl-\(letter)") {
                            bridge.send([UInt8(letter.utf8.first!) & 0x1f])
                        }
                    }
                }
                .buttonStyle(.bordered)
                Button("Paste") {
                    if let value = UIPasteboard.general.string { bridge.send(Array(value.utf8)) }
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .disabled(session?.writable != true || !model.canDeliver)
    }

    private func key(_ title: String, _ bytes: [UInt8]) -> some View {
        Button(title) { bridge.send(bytes) }.buttonStyle(.bordered)
    }
    #endif
}

/// Same delegate and parser view on UIKit and AppKit; only platform wrapping differs.
@MainActor private final class TerminalBridge: NSObject, @preconcurrency TerminalViewDelegate {
    weak var view: TerminalView?
    var onInput: (([UInt8]) -> Void)?
    var onResize: ((Int, Int) -> Void)?
    var writable = false
    private(set) var cols = 80
    private(set) var rows = 24
    private var sessionId: String?
    private var snapshotId: String?
    private var snapshot = ""
    private var snapshotSequence = 0
    fileprivate var remoteSize: (Int, Int)?
    private var pendingScreen: String?

    func install(_ terminalView: TerminalView) {
        view = terminalView
        if let size = remoteSize {
            terminalView.getTerminal().resize(cols: size.0, rows: size.1)
        }
        if let pendingScreen {
            terminalView.getTerminal().resetToInitialState()
            terminalView.feed(text: pendingScreen)
        }
    }

    func syncSize(_ session: TerminalSessionData?) {
        guard let session, !session.writable else { remoteSize = nil; return }
        remoteSize = (session.cols, session.rows)
        view?.getTerminal().resize(cols: session.cols, rows: session.rows)
    }

    func select(_ id: String?) {
        sessionId = id
        snapshotId = nil
        snapshot = ""
        snapshotSequence = 0
        pendingScreen = nil
        view?.getTerminal().resetToInitialState()
        if id == nil { view = nil }
    }

    func receive(_ frame: TerminalData) {
        guard frame.sessionId == sessionId else { return }
        switch frame.action {
        case .snapshot:
            if snapshotId != frame.snapshotId {
                snapshotId = frame.snapshotId
                snapshot = ""
            }
            snapshot += frame.data ?? ""
            if frame.last == true {
                snapshotSequence = frame.sequence ?? 0
                pendingScreen = snapshot
                if let view {
                    view.getTerminal().resetToInitialState()
                    view.feed(text: snapshot)
                }
                snapshot = ""
            }
        case .output:
            if (frame.sequence ?? 0) > snapshotSequence {
                if let view { view.feed(text: frame.data ?? "") }
                else if pendingScreen != nil { pendingScreen! += frame.data ?? "" }
            }
        default: break
        }
    }

    func send(_ bytes: [UInt8]) {
        guard writable else { return }
        for start in stride(from: 0, to: bytes.count, by: 12_000) {
            onInput?(Array(bytes[start..<min(start + 12_000, bytes.count)]))
        }
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        guard newCols > 0, newRows > 0 else { return }
        cols = newCols
        rows = newRows
        if writable { onResize?(newCols, newRows) }
        else if let remoteSize { source.getTerminal().resize(cols: remoteSize.0, rows: remoteSize.1) }
    }
    func send(source: TerminalView, data: ArraySlice<UInt8>) { send(Array(data)) }
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    func bell(source: TerminalView) {}
    // OSC 52 is deliberately inert. Only explicit user copy/paste touches the clipboard.
    func clipboardCopy(source: TerminalView, content: Data) {}
    func clipboardRead(source: TerminalView) -> Data? { nil }
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

#if os(iOS)
private struct TerminalSurface: UIViewRepresentable {
    let bridge: TerminalBridge
    func makeUIView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero, options: TerminalOptions(scrollback: 1000))
        view.terminalDelegate = bridge
        bridge.install(view)
        DispatchQueue.main.async { _ = view.becomeFirstResponder() }
        return view
    }
    func updateUIView(_ view: TerminalView, context: Context) { bridge.view = view }
}
#else
private struct TerminalSurface: NSViewRepresentable {
    let bridge: TerminalBridge
    func makeNSView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero, options: TerminalOptions(scrollback: 1000))
        view.terminalDelegate = bridge
        bridge.install(view)
        return view
    }
    func updateNSView(_ view: TerminalView, context: Context) { bridge.view = view }
}
#endif

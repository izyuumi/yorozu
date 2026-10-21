import SwiftUI
import UniformTypeIdentifiers
import YorozuWire

/// A side of the conversation area when two conversations are open side by side.
enum PaneSide { case left, right }

/// Two conversations side by side on iPad and iPhone Duo's inner display (owner, 2026-10-21). `selection` stays the
/// focused conversation, the one the composer types into and the list highlights; this holds the other one and where it sits.
struct ChatPair {
    /// The other pane's conversation; nil with one conversation open.
    var partner: String?
    var partnerOnLeft = false
    /// The right pane is choosing a conversation to open beside the focused one.
    var choosing = false
    /// The left pane's share of the width.
    var fraction: CGFloat = 0.5

    var isOpen: Bool { partner != nil || choosing }
    var focusedSide: PaneSide { partnerOnLeft ? .right : .left }

    /// `convId` beside the focused conversation, focused itself: the focus moves to the other side.
    mutating func openBeside(_ convId: String, selection: inout String?) {
        choosing = false
        guard let current = selection, current != convId else { selection = convId; return }
        if partner == convId { return focus(focusedSide == .left ? .right : .left, selection: &selection) }
        partner = current
        selection = convId
        partnerOnLeft = focusedSide == .left
    }

    mutating func focus(_ side: PaneSide, selection: inout String?) {
        guard side != focusedSide, let partner else { return }
        self.partner = selection
        selection = partner
        partnerOnLeft.toggle()
    }

    /// The conversations trade sides; the focus stays with its conversation.
    mutating func swapSides() { partnerOnLeft.toggle() }

    mutating func close(_ side: PaneSide, selection: inout String?) {
        if choosing { choosing = false; return }
        if side == focusedSide { selection = partner }
        partner = nil
        partnerOnLeft = false
        fraction = 0.5
    }

    /// Shows `convId` on `side`, focused there. A conversation already open only takes the focus, so none is ever shown twice.
    mutating func show(_ convId: String, on side: PaneSide, selection: inout String?) {
        if convId == selection { return }
        if convId == partner { return focus(focusedSide == .left ? .right : .left, selection: &selection) }
        if side == focusedSide {
            selection = convId
        } else {
            partner = convId
            focus(side, selection: &selection)
        }
    }

    /// The list, a notice or a deletion moved the selection from `old` to `new`.
    mutating func selectionChanged(from old: String?, to new: String?, compact: Bool, selection: inout String?) {
        if choosing, let old, let new, old != new {
            choosing = false
            partner = old
            partnerOnLeft = true
        } else if let new, new == partner {
            // The list picked the other pane's conversation: it takes the focus where it is.
            partner = old
            partnerOnLeft.toggle()
            if old == nil { partnerOnLeft = false }
        } else if new == nil, !compact, let partner {
            // The focused conversation was deleted or archived: the other one fills the area. A phone's Back keeps the pair.
            self.partner = nil
            partnerOnLeft = false
            selection = partner
        }
    }

    func side(of convId: String, selection: String?) -> PaneSide? {
        guard partner != nil else { return nil }
        if convId == selection { return focusedSide }
        return convId == partner ? (focusedSide == .left ? .right : .left) : nil
    }
}

extension UTType {
    /// A conversation dragged from the list onto a side of the conversation area; it never leaves the app.
    static let yorozuConversation = UTType(exportedAs: "to.yumi.yorozu.conversation")
}

#if os(iOS)
extension View {
    /// A row the list lets go of as a conversation, for a side of the conversation area to take.
    func conversationDrag(_ convId: String, started: @escaping () -> Void) -> some View {
        onDrag {
            started()
            let provider = NSItemProvider()
            provider.registerDataRepresentation(forTypeIdentifier: UTType.yorozuConversation.identifier, visibility: .ownProcess) { done in
                done(Data(convId.utf8), nil)
                return nil
            }
            return provider
        }
    }
}

/// The detail of the split view: one conversation with Open Beside, or two side by side, each in its own navigation
/// stack with its own bar, and a divider between them.
struct ChatPairView: View {
    let model: AppModel
    @Binding var selection: String?
    @Binding var pair: ChatPair
    @Binding var columns: NavigationSplitViewVisibility
    /// A conversation is being dragged from the list.
    @Binding var dragging: Bool
    /// The whole window's width: the sidebar is beside the conversations when they are narrower.
    let windowWidth: CGFloat

    /// Each conversation needs this much to read comfortably; narrower, opening a pair puts the sidebar away.
    private static let comfortablePane: CGFloat = 360
    @State private var width: CGFloat = 0
    @State private var dropSide: PaneSide?

    var body: some View {
        Group {
            if pair.isOpen {
                panes.toolbar(.hidden, for: .navigationBar)
            } else if let selection {
                ChatView(model: model, convId: selection)
                    .id(selection)
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) {
                            Button(String(localized: "Open Beside"), systemImage: "rectangle.split.2x1") { withAnimation(.snappy) { pair.choosing = true } }
                                .keyboardShortcut("\\", modifiers: .command)
                                .accessibilityIdentifier("pair.openBeside")
                        }
                    }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .onChange(of: pair.isOpen) { _, open in
            if open {
                let sidebarBeside = width < windowWidth - 1
                columns = !sidebarBeside || width < Self.comfortablePane * 2 ? .detailOnly : .all
            } else {
                columns = .automatic
            }
        }
        // While a conversation is dragged, a layer over the panes takes it: under it, the chat's own drop (files) would
        // refuse it. A sidebar that covers the conversation steps aside so there is somewhere to drop.
        .overlay {
            if dragging {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { finishDrag() }
                    .onDrop(of: [.yorozuConversation], delegate: PaneDrop(width: width, side: $dropSide, drop: drop, done: finishDrag))
                    .overlay { if let dropSide { dropHint(dropSide) } }
            }
        }
        .onChange(of: dragging) { _, dragging in
            if dragging, width >= windowWidth - 1 { withAnimation { columns = .detailOnly } }
        }
    }

    private func drop(_ convId: String, on side: PaneSide) {
        withAnimation(.snappy) {
            if pair.isOpen {
                pair.show(convId, on: side, selection: &selection)
            } else if side == .right {
                pair.openBeside(convId, selection: &selection)
            } else {
                selection = convId
            }
        }
    }

    private func finishDrag() {
        dragging = false
        dropSide = nil
        if !pair.isOpen, columns == .detailOnly { withAnimation { columns = .automatic } }
    }

    private var panes: some View {
        let focused = pair.focusedSide
        let other = pair.choosing ? nil : pair.partner
        let left = pair.partnerOnLeft ? other : selection
        let right = pair.partnerOnLeft ? selection : other
        let leftWidth = max(0, (width - 1) * pair.fraction)
        return HStack(spacing: 0) {
            pane(left, side: .left, focused: focused == .left)
                .frame(width: leftWidth)
            PaneDivider(fraction: $pair.fraction, width: width) { side in
                withAnimation(.snappy) { pair.close(side, selection: &selection) }
            }
            .zIndex(1)
            pane(right, side: .right, focused: focused == .right)
                .frame(maxWidth: .infinity)
        }
        .coordinateSpace(.named(PaneDivider.space))
    }

    @ViewBuilder private func pane(_ convId: String?, side: PaneSide, focused: Bool) -> some View {
        NavigationStack {
            Group {
                if let convId {
                    ChatView(model: model, convId: convId, focus: pair.choosing ? .only : focused ? .focused : .unfocused)
                } else {
                    BesidePicker(model: model, excluding: selection) { convId in
                        withAnimation(.snappy) { pair.openBeside(convId, selection: &selection) }
                    } cancel: {
                        withAnimation(.snappy) { pair.choosing = false }
                    }
                }
            }
            .toolbar { paneToolbar(side: side, isChat: convId != nil) }
        }
        .id(convId ?? "beside")
        // A tap anywhere in a pane, its composer included, moves the focus there.
        .simultaneousGesture(TapGesture().onEnded {
            guard !pair.choosing, side != pair.focusedSide else { return }
            withAnimation(.snappy) { pair.focus(side, selection: &selection) }
        })
        .accessibilityElement(children: .contain)
        .accessibilityLabel(side == .left ? Text("Left pane") : Text("Right pane"))
    }

    @ToolbarContentBuilder private func paneToolbar(side: PaneSide, isChat: Bool) -> some ToolbarContent {
        if side == .left {
            ToolbarItem(placement: .topBarLeading) {
                Button(columns == .detailOnly ? String(localized: "Show Sidebar") : String(localized: "Hide Sidebar"), systemImage: "sidebar.left") {
                    withAnimation { columns = columns == .detailOnly ? .all : .detailOnly }
                }
            }
        }
        if isChat {
            ToolbarItem(placement: .primaryAction) {
                Menu(String(localized: "Pane Options"), systemImage: "ellipsis") {
                    if !pair.choosing {
                        Button(String(localized: "Swap Sides"), systemImage: "arrow.left.arrow.right") { withAnimation(.snappy) { pair.swapSides() } }
                        Button(String(localized: "Full Screen"), systemImage: "arrow.up.left.and.arrow.down.right") {
                            withAnimation(.snappy) { pair.close(side == .left ? .right : .left, selection: &selection) }
                        }
                    }
                    Button(String(localized: "Close"), systemImage: "xmark") { withAnimation(.snappy) { pair.close(side, selection: &selection) } }
                }
                .accessibilityIdentifier("pair.options")
            }
        }
    }

    /// The side a dragged conversation would land on: Open Beside or Replace with one open, Open Here with two.
    private func dropHint(_ side: PaneSide) -> some View {
        let label = pair.isOpen ? String(localized: "Open Here")
            : side == .right ? String(localized: "Open Beside") : String(localized: "Replace")
        return HStack(spacing: 0) {
            if side == .right { Color.clear }
            RoundedRectangle(cornerRadius: LayoutMetrics.cardRadius, style: .continuous)
                .fill(.tint.opacity(0.12))
                .strokeBorder(.tint, lineWidth: 2)
                .overlay {
                    Label(label, systemImage: side == .right ? "rectangle.righthalf.filled" : "rectangle.lefthalf.filled")
                        .font(.headline)
                        .padding(.horizontal, LayoutMetrics.gutter)
                        .padding(.vertical, LayoutMetrics.inner)
                        .yorozuGlass(in: Capsule())
                }
                .padding(LayoutMetrics.inner)
            if side == .left { Color.clear }
        }
        .allowsHitTesting(false)
        .transition(.opacity)
    }
}

/// Where a dragged conversation is over the conversation area, and what to do when it is let go.
private struct PaneDrop: DropDelegate {
    let width: CGFloat
    @Binding var side: PaneSide?
    let drop: (String, PaneSide) -> Void
    let done: () -> Void

    private func side(_ info: DropInfo) -> PaneSide { info.location.x < width / 2 ? .left : .right }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let next = side(info)
        if side != next { withAnimation(.snappy) { side = next } }
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) { withAnimation(.snappy) { side = nil } }

    func performDrop(info: DropInfo) -> Bool {
        let target = side(info)
        done()
        guard let provider = info.itemProviders(for: [.yorozuConversation]).first else { return false }
        _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.yorozuConversation.identifier) { data, _ in
            guard let data, let convId = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in drop(convId, target) }
        }
        return true
    }
}

/// The line between the panes and its grabber: drag to resize, snapping to a third, a half or two thirds; fling to an
/// edge to close the pane there; double-tap for equal halves. Its sizes are its own geometry.
private struct PaneDivider: View {
    static let space = "pair"
    private static let stops: [CGFloat] = [1.0 / 3, 0.5, 2.0 / 3]
    private static let grabber = CGSize(width: 5, height: 36)

    @Binding var fraction: CGFloat
    let width: CGFloat
    let close: (PaneSide) -> Void
    @GestureState private var dragging = false

    var body: some View {
        Rectangle()
            .fill(.separator)
            .frame(width: 1)
            .overlay {
                Capsule()
                    .fill(dragging ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                    .frame(width: Self.grabber.width, height: Self.grabber.height)
                    .frame(width: controlTarget, height: controlTarget * 2)
                    .contentShape(Rectangle())
                    .gesture(drag)
                    .onTapGesture(count: 2) { withAnimation(.snappy) { fraction = 0.5 } }
                    #if os(iOS)
                    .hoverEffect(.highlight)
                    #endif
            }
            .accessibilityElement()
            .accessibilityLabel(Text("Divider"))
            .accessibilityValue(Text(Double(fraction), format: .percent.precision(.fractionLength(0))))
            .accessibilityAdjustableAction { direction in
                let index = Self.stops.firstIndex { abs($0 - fraction) < 0.01 } ?? 1
                let next = direction == .increment ? min(index + 1, Self.stops.count - 1) : max(index - 1, 0)
                withAnimation(.snappy) { fraction = Self.stops[next] }
            }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
            .updating($dragging) { _, state, _ in state = true }
            .onChanged { value in
                guard width > 0 else { return }
                fraction = min(max(value.location.x / width, 0.2), 0.8)
            }
            .onEnded { value in
                guard width > 0 else { return }
                let landing = value.predictedEndLocation.x / width
                if landing < 0.1 { return close(.left) }
                if landing > 0.9 { return close(.right) }
                let nearest = Self.stops.min { abs($0 - fraction) < abs($1 - fraction) } ?? 0.5
                withAnimation(.snappy) { fraction = nearest }
            }
    }
}

/// The right pane before it holds a conversation: the recent ones to open beside the focused one, or a new one.
private struct BesidePicker: View {
    let model: AppModel
    let excluding: String?
    let pick: (String) -> Void
    let cancel: () -> Void
    @State private var query = ""

    var body: some View {
        let matches = model.list.filter { $0.id != excluding && (query.isEmpty || $0.displayTitle.localizedCaseInsensitiveContains(query)) }
        List {
            Section {
                Button(String(localized: "New Conversation"), systemImage: "square.and.pencil") { pick(V3Event.newId()) }
            }
            Section(String(localized: "Recent")) {
                ForEach(matches) { conversation in
                    Button { pick(conversation.id) } label: {
                        VStack(alignment: .leading, spacing: LayoutMetrics.hair) {
                            Text(conversation.displayTitle).lineLimit(1)
                            Text(conversation.lastText).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .foregroundStyle(.primary)
                }
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: Text("Search"))
        .navigationTitle("Open Beside")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(String(localized: "Cancel"), systemImage: "xmark", action: cancel)
            }
        }
        .safeAreaInset(edge: .bottom) {
            Text("Or drag a conversation from the list onto this side.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(LayoutMetrics.inner)
        }
    }
}

/// On a phone, or iPhone Duo closed, the pair stays: the two conversations' titles at the top switch between them.
struct PairSwitcher: View {
    let model: AppModel
    @Binding var selection: String?
    @Binding var pair: ChatPair

    var body: some View {
        if let partner = pair.partner, let current = selection {
            let order = pair.partnerOnLeft ? [partner, current] : [current, partner]
            Picker(String(localized: "Conversation"), selection: Binding(get: { current }, set: { picked in
                guard picked != current else { return }
                pair.focus(pair.focusedSide == .left ? .right : .left, selection: &selection)
            })) {
                ForEach(order, id: \.self) { convId in
                    Text(model.conversations[convId]?.displayTitle ?? String(localized: "New Conversation")).tag(convId)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, LayoutMetrics.gutter)
            .padding(.vertical, LayoutMetrics.tight)
            .accessibilityIdentifier("pair.switcher")
        }
    }
}
#endif

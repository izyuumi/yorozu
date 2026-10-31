import CoreImage.CIFilterBuiltins
import SwiftUI
import YorozuWire

struct AddDeviceSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var scanning = false
    @State private var scanned: String?
    @State private var known: Set<String>?
    @State private var paired: DeviceInfo?
    @State private var enlarged = false
    #if os(macOS)
    @State private var contentHeight: CGFloat?
    #endif
    private static let pollInterval: Duration = .seconds(2)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: LayoutMetrics.section) {
                    #if os(iOS)
                    scanMac
                    #endif
                    content
                }
                .padding(LayoutMetrics.gutter)
                .frame(maxWidth: .infinity)
                .accessibilityHidden(enlarged)
                #if os(macOS)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                #endif
            }
            #if os(macOS)
            .frame(idealHeight: contentHeight)
            #endif
            .overlay {
                if enlarged, paired == nil, let webLink = model.invite?.webLink {
                    enlargedCode(webLink)
                }
            }
            .navigationTitle(String(localized: "Add a Device"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(String(localized: "Done")) { dismiss() } }
            }
        }
        .task { model.requestInvite() }
        .task(id: paired == nil) {
            guard paired == nil else { return }
            while !Task.isCancelled {
                model.refreshDevices()
                try? await Task.sleep(for: Self.pollInterval)
                guard let devices = model.devices else { continue }
                guard let known else {
                    self.known = Set(devices.map(\.id))
                    continue
                }
                if let added = devices.first(where: { !known.contains($0.id) }) {
                    withAnimation(.snappy) { paired = added }
                    return
                }
            }
        }
        #if os(iOS)
        .sheet(isPresented: $scanning, onDismiss: {
            if let text = scanned { model.pairingError = model.submit(text) }
            scanned = nil
        }) {
            ScannerView(prompt: "Scan the code on the new Mac’s pairing screen.", onScan: { text in
                guard DeviceCode.decode(text) != nil else {
                    return String(localized: "This isn’t a Mac’s pairing code. Open Yorozu on the new Mac and scan the code it shows.")
                }
                scanned = text
                scanning = false
                return nil
            }, onManualEntry: { scanning = false })
            .yorozuTint()
        }
        #endif
        .deviceAddingAlerts(model)
        #if os(macOS)
        .frame(minWidth: LayoutMetrics.windowMinWidth, minHeight: LayoutMetrics.windowMinHeight)
        #endif
    }

    #if os(iOS)
    private var scanMac: some View {
        VStack(spacing: LayoutMetrics.tight) {
            Button(String(localized: "Scan a Mac’s Code"), systemImage: "qrcode.viewfinder") { scanning = true }
                .buttonStyle(.borderedProminent)
            if case .asking? = model.deviceAdding {
                ProgressView(String(localized: "Sending the code to the Mac…"))
            }
        }
    }
    #endif


    @ViewBuilder private var content: some View {
        if let paired {
            success(paired)
        } else if let invite = model.invite, let webLink = invite.webLink, let url = URL(string: webLink),
           let expiresAt = invite.expiresAt {
            let expiry = Date(timeIntervalSince1970: TimeInterval(expiresAt) / 1000)
            Text("On the new iPhone, iPad or Mac, scan this code with the camera or in Yorozu, or open the link there.")
                .multilineTextAlignment(.center)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                if context.date < expiry {
                    VStack(spacing: LayoutMetrics.stack) {
                        Button { withAnimation(.snappy) { enlarged = true } } label: { QRCode(text: webLink) }
                            .buttonStyle(.plain)
                            .pointingHand()
                            .accessibilityLabel(Text("Pairing code"))
                            .accessibilityHint(Text("Enlarges the code."))
                        Text(Self.enlargeHint).textStyle(.footnote).foregroundStyle(.secondary).accessibilityHidden(true)
                        Text("Valid for \(Text(timerInterval: Date.now...expiry, countsDown: true)), for one device.")
                            .textStyle(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    VStack(spacing: LayoutMetrics.stack) {
                        Text("This code has expired.").foregroundStyle(.secondary)
                            .onAppear { enlarged = false }
                        Button(String(localized: "New Code")) { model.requestInvite() }
                    }
                }
            }
            ShareLink(item: url) { Label(String(localized: "Send the Link"), systemImage: "square.and.arrow.up") }
            if let fingerprint = invite.fingerprint {
                VStack(spacing: LayoutMetrics.tight) {
                    Text("Host fingerprint").textStyle(.footnote).foregroundStyle(.secondary)
                    Text(fingerprint).textStyle(.body, monospaced: true).textSelection(.enabled)
                    Text("The new device shows it before pairing. Pair only if they match.")
                        .textStyle(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            }
        } else if let error = model.invite?.error {
            ContentUnavailableView {
                Label(String(localized: "Couldn’t make a code"), systemImage: "exclamationmark.triangle").zoomedFont(.title3)
            } description: {
                Text(error).zoomedFont()
            } actions: {
                Button(String(localized: "Try Again")) { model.requestInvite() }
            }
        } else {
            ProgressView(String(localized: "Asking the host for a code…"))
        }
    }
}

extension AddDeviceSheet {
    #if os(macOS)
    private static var enlargeHint: String { String(localized: "Click the code to enlarge it.") }
    private static var shrinkHint: String { String(localized: "Click the code or press Esc to shrink it.") }
    #else
    private static var enlargeHint: String { String(localized: "Tap the code to enlarge it.") }
    private static var shrinkHint: String { String(localized: "Tap the code to shrink it.") }
    #endif

    private func enlargedCode(_ webLink: String) -> some View {
        VStack(spacing: LayoutMetrics.stack) {
            Button { shrink() } label: { QRCode(text: webLink, enlarged: true) }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .pointingHand()
                .accessibilityLabel(Text("Pairing code"))
                .accessibilityHint(Text("Shrinks the code."))
            Text(Self.shrinkHint).textStyle(.footnote).foregroundStyle(.secondary).accessibilityHidden(true)
        }
        .padding(LayoutMetrics.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .contentShape(.rect)
        .onTapGesture { shrink() }
        .accessibilityAddTraits(.isModal)
        .transition(.opacity)
    }

    private func shrink() {
        withAnimation(.snappy) { enlarged = false }
    }

    private func success(_ device: DeviceInfo) -> some View {
        VStack(spacing: LayoutMetrics.stack) {
            Image(systemName: "checkmark.circle.fill")
                .textStyle(.largeTitle)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("\(device.name ?? String(localized: "The new device")) is paired")
                .textStyle(.headline)
                .multilineTextAlignment(.center)
            Text("It sees every conversation. You can manage it in Paired Devices.")
                .textStyle(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(String(localized: "Add Another")) {
                known = Set(model.devices?.map(\.id) ?? [])
                withAnimation(.snappy) { paired = nil }
                model.requestInvite()
            }
        }
    }
}

struct QRCode: View {
    static let compactSide: CGFloat = 180
    let text: String
    var enlarged = false
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        if let image = Self.image(text) {
            let code = Image(decorative: image, scale: 1)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
            Group {
                if enlarged {
                    code
                } else {
                    code.frame(width: side(image), height: side(image))
                }
            }
            .padding(LayoutMetrics.stack)
            .background(.white, in: RoundedRectangle(cornerRadius: LayoutMetrics.cardRadius, style: .continuous))
        }
    }

    private func side(_ image: CGImage) -> CGFloat {
        let modules = CGFloat(image.width)
        let pixelsPerModule = max(1, (Self.compactSide * displayScale / modules).rounded())
        return pixelsPerModule * modules / displayScale
    }

    private static func image(_ text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
}

private struct DeviceAddingAlerts: ViewModifier {
    let model: AppModel

    func body(content: Content) -> some View {
        content
            .alert(String(localized: "Add \(model.pendingDevice?.name ?? "")?"),
                isPresented: Binding(get: { model.pendingDevice != nil }, set: { if !$0 { model.pendingDevice = nil } }),
                presenting: model.pendingDevice) { code in
                Button(String(localized: "Add")) { model.addDevice(code) }
                Button(String(localized: "Cancel"), role: .cancel) { model.pendingDevice = nil }
            } message: { _ in
                Text("It pairs with your host and sees every conversation. Next, the Mac shows a host key: pair it only if the key is\n\n\(model.fingerprint ?? "")")
            }
            .alert(title, isPresented: Binding(get: { done }, set: { if !$0 { model.deviceAdding = nil } })) {
                Button(String(localized: "OK")) { model.deviceAdding = nil }
            } message: {
                switch model.deviceAdding {
                case .sent(let code, let fingerprint)?:
                    Text("On \(code.name), check that the host key is \(fingerprint), then click Pair.")
                case .failed(let reason)?: Text(reason)
                default: EmptyView()
                }
            }
    }

    private var done: Bool {
        switch model.deviceAdding {
        case .sent?, .failed?: true
        default: false
        }
    }

    private var title: String {
        if case .failed? = model.deviceAdding { return String(localized: "Couldn’t add the Mac") }
        return String(localized: "Finish on the Mac")
    }
}

extension View {
    @ViewBuilder fileprivate func pointingHand() -> some View {
        #if os(macOS)
        pointerStyle(.link)
        #else
        hoverEffect()
        #endif
    }
}

extension View {
    func deviceAddingAlerts(_ model: AppModel) -> some View { modifier(DeviceAddingAlerts(model: model)) }
}

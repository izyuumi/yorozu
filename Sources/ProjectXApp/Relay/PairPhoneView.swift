import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

/// Pair an iPhone: a fresh one-time code as a QR and a link, and the phones already paired.
struct PairPhoneView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var removing: RelayDevice?
    /// A code is minted only on request: each stays valid until a phone pairs, so opening Settings must not make one.
    @State private var pairing = false
    /// The QR's side, the one size this sheet owns.
    private let qrSide: CGFloat = 220

    var body: some View {
        VStack(spacing: 16) {
            Text("Pair iPhone").font(.headline)
            if let link = model.relayStatus.link, let qr = Self.qr(link) {
                Image(nsImage: qr).interpolation(.none).resizable().frame(width: qrSide, height: qrSide)
                    .accessibilityLabel("Pairing QR code")
                Text("Scan with Yorozu on your iPhone. Each code works once.").font(.caption).foregroundStyle(.secondary)
                Button("Copy link") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(link, forType: .string) }
            } else if !pairing {
                Button("Show pairing code") { pairing = true }.disabled(model.relay == nil).frame(height: qrSide)
            } else {
                VStack(spacing: 8) {
                    if model.relay != nil { ProgressView() }
                    Text(model.relayStatus.state).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.frame(height: qrSide)
            }
            if !model.relayStatus.devices.isEmpty {
                Divider()
                ForEach(model.relayStatus.devices) { device in
                    HStack {
                        Label("iPhone · \(device.pub.prefix(8))", systemImage: "iphone")
                        Spacer()
                        Text("Paired \(device.pairedAt.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary)
                        Button("Remove…", role: .destructive) { removing = device }.accessibilityLabel("Remove iPhone \(device.pub.prefix(8))")
                    }
                }
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding()
        // Keyed on the host so a sheet opened while the app is still starting asks once it exists.
        .task(id: pairing && model.relay != nil) { if pairing { await model.relay?.mintPairing() } }
        .onDisappear { Task { await model.relay?.endPairing() } }
        .confirmationDialog("Remove this iPhone?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { device in
            Button("Remove", role: .destructive) { Task { await model.relay?.removeDevice(device.pub) } }
        } message: { _ in
            Text("It loses access to this Mac and has to pair again.")
        }
    }

    private static func qr(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        // The generator emits one pixel per module; scale up before rasterising.
        guard let image = filter.outputImage?.transformed(by: .init(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: image)
        let result = NSImage(size: rep.size)
        result.addRepresentation(rep)
        return result
    }
}

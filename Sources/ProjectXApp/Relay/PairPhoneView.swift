import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

/// The Pair iPhone sheet from Settings › Devices: a fresh one-time code as a QR and a link. It mints only once shown,
/// which only the Pair iPhone… button does, so opening Settings never makes a code.
struct PairPhoneView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
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
            } else {
                VStack(spacing: 8) {
                    if model.relay != nil { ProgressView() }
                    Text(model.relayStatus.state).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.frame(height: qrSide)
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding()
        // Keyed on the host so a sheet opened while the relay restarts asks once it exists.
        .task(id: model.relay != nil) { await model.relay?.mintPairing() }
        .onDisappear { Task { await model.relay?.endPairing() } }
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

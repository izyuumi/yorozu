import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI
import YorozuWire

/// The Pair iPhone sheet from Settings › Devices: a fresh one-time code as a QR, the code as text and the Mac key the phone
/// asks to compare. It mints only once shown, which only the Pair iPhone… button does, so opening Settings never makes a code.
/// The code is the pairing link itself, the one string the phone's manual entry takes.
struct PairPhoneView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    /// The QR's side and the text column's width, the sizes this sheet owns.
    private let qrSide: CGFloat = 220, textWidth: CGFloat = 300

    var body: some View {
        VStack(alignment: .trailing, spacing: 16) {
            HStack(alignment: .top, spacing: 20) {
                if let link = model.relayStatus.link, let qr = Self.qr(link) {
                    Image(nsImage: qr).interpolation(.none).resizable().frame(width: qrSide, height: qrSide)
                        .accessibilityLabel("Pairing QR code")
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Scan with the iPhone Camera").font(.headline)
                        Text("Or open Yorozu on the iPhone, tap Enter code manually, and paste the code. Check that the Mac key matches what the phone shows.")
                            .foregroundStyle(.secondary)
                        field("Mac key", (try? QrPayload.decode(link))?.fingerprint ?? "")
                        field("Code", link)
                    }
                    .frame(width: textWidth, alignment: .leading)
                } else {
                    VStack(spacing: 8) {
                        if model.relay != nil { ProgressView() }
                        Text(model.relayStatus.state).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }.frame(width: qrSide + 20 + textWidth, height: qrSide)
                }
            }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Copy Link") {
                    guard let link = model.relayStatus.link else { return }
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(link, forType: .string)
                }.disabled(model.relayStatus.link == nil)
            }
        }
        .padding()
        // Keyed on the host so a sheet opened while the relay restarts asks once it exists.
        .task(id: model.relay != nil) { await model.relay?.mintPairing() }
        .onDisappear { Task { await model.relay?.endPairing() } }
    }

    private func field(_ label: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.monospaced()).textSelection(.enabled)
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

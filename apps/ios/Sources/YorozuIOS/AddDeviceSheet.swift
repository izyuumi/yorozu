import CoreImage.CIFilterBuiltins
import SwiftUI
import YorozuWire

/// Adding a device from this one, away from the host (owner, 2026-10-17): the host makes the same one-time code as
/// `openclaw yorozu pair`, sent over the relay, shown here as a QR for the new device to scan, or a link to send it.
/// One device, ten minutes; the new device shows the host fingerprint too, and they must match.
struct AddDeviceSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: LayoutMetrics.section) {
                    content
                }
                .padding(LayoutMetrics.gutter)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle(String(localized: "Add a Device"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(String(localized: "Done")) { dismiss() } }
            }
        }
        .task { model.requestInvite() }
        #if os(macOS)
        .frame(minWidth: LayoutMetrics.windowMinWidth, minHeight: LayoutMetrics.windowMinHeight)
        #endif
    }

    @ViewBuilder private var content: some View {
        if let invite = model.invite, let webLink = invite.webLink, let url = URL(string: webLink),
           let expiresAt = invite.expiresAt {
            let expiry = Date(timeIntervalSince1970: TimeInterval(expiresAt) / 1000)
            Text("On the new iPhone, iPad or Mac, scan this code with the camera or in Yorozu, or open the link there.")
                .multilineTextAlignment(.center)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                if context.date < expiry {
                    VStack(spacing: LayoutMetrics.stack) {
                        QRCode(text: webLink)
                        Text("Valid for \(Text(timerInterval: Date.now...expiry, countsDown: true)), for one device.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    VStack(spacing: LayoutMetrics.stack) {
                        Text("This code has expired.").foregroundStyle(.secondary)
                        Button(String(localized: "New Code")) { model.requestInvite() }
                    }
                }
            }
            ShareLink(item: url) { Label(String(localized: "Send the Link"), systemImage: "square.and.arrow.up") }
            if let fingerprint = invite.fingerprint {
                VStack(spacing: LayoutMetrics.tight) {
                    Text("Host fingerprint").font(.footnote).foregroundStyle(.secondary)
                    Text(fingerprint).font(.body.monospaced()).textSelection(.enabled)
                    Text("The new device shows it before pairing. Pair only if they match.")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            }
        } else if let error = model.invite?.error {
            ContentUnavailableView {
                Label(String(localized: "Couldn’t make a code"), systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button(String(localized: "Try Again")) { model.requestInvite() }
            }
        } else {
            ProgressView(String(localized: "Asking the host for a code…"))
        }
    }
}

/// The pairing link as a QR code, as wide as it may be up to a size that still scans from across a desk.
private struct QRCode: View {
    let text: String

    var body: some View {
        if let image = Self.image(text) {
            Image(decorative: image, scale: 1)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .containerRelativeFrame(.horizontal) { width, _ in min(width * 0.7, LayoutMetrics.readingWidth / 2) }
                .padding(LayoutMetrics.stack)
                .background(.white, in: RoundedRectangle(cornerRadius: LayoutMetrics.cardRadius, style: .continuous))
                .accessibilityLabel(Text("Pairing code"))
        }
    }

    private static func image(_ text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
}

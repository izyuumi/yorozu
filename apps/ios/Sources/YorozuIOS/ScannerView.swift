import SwiftUI
import VisionKit

/// Pairing screen: scans the QR the Mac menu bar shows. `DataScannerViewController` does the
/// camera, framing and recognition, so there is no AVCaptureSession to own here.
struct ScannerView: View {
    /// Called with the raw QR string; returns an error message when it is not a Yorozu payload.
    let onScan: (String) -> String?

    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Text("Scan the QR code in your Mac's menu bar.")
                    .font(.headline)
                    .multilineTextAlignment(.center)

                if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                    Scanner { text in
                        error = onScan(text)
                        return error == nil
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                } else {
                    ContentUnavailableView(
                        "No camera",
                        systemImage: "qrcode.viewfinder",
                        description: Text("This device cannot scan QR codes.")
                    )
                }

                if let error {
                    Label { Text(error) } icon: {
                        Image(systemName: "exclamationmark.circle").foregroundStyle(.red)
                    }
                    .font(.footnote)
                }
            }
            .padding(16)
            .navigationTitle("Scan pairing code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

private struct Scanner: UIViewControllerRepresentable {
    let onScan: (String) -> Bool

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: true
        )
        controller.delegate = context.coordinator
        try? controller.startScanning()
        return controller
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let onScan: (String) -> Bool
        /// One QR is enough; the scanner keeps reporting the same code every frame.
        private var done = false

        init(onScan: @escaping (String) -> Bool) { self.onScan = onScan }

        func dataScanner(
            _ scanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            guard !done, case .barcode(let code) = addedItems.first,
                let text = code.payloadStringValue
            else { return }
            if onScan(text) {
                done = true
                scanner.stopScanning()
            }
        }
    }
}

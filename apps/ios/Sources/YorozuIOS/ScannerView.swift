import SwiftUI
import VisionKit

/// Pairing screen: scans the QR the Mac menu bar shows. `DataScannerViewController` does the
/// camera, framing and recognition, so there is no AVCaptureSession to own here.
struct ScannerView: View {
    /// Called with the raw QR string; returns an error message when it is not a Yorozu payload.
    let onScan: (String) -> String?

    @State private var error: String?

    var body: some View {
        VStack(spacing: 16) {
            Text("Scan the QR code in your Mac's menu bar.")
                .font(.headline)
                .multilineTextAlignment(.center)

            if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                Scanner { error = onScan($0) }
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            } else {
                ContentUnavailableView(
                    "No camera",
                    systemImage: "qrcode.viewfinder",
                    description: Text("This device cannot scan QR codes.")
                )
            }

            if let error {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
        }
        .padding()
    }
}

private struct Scanner: UIViewControllerRepresentable {
    let onScan: (String) -> Void

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
        private let onScan: (String) -> Void
        /// One QR is enough; the scanner keeps reporting the same code every frame.
        private var done = false

        init(onScan: @escaping (String) -> Void) { self.onScan = onScan }

        func dataScanner(
            _ scanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            guard !done, case .barcode(let code) = addedItems.first,
                let text = code.payloadStringValue
            else { return }
            done = true
            scanner.stopScanning()
            onScan(text)
        }
    }
}

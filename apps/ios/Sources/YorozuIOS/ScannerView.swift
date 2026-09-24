import AVFoundation
import SwiftUI
import VisionKit

/// Pairing screen: scans the QR in the Mac's Devices settings. `DataScannerViewController` does the
/// camera, framing and recognition, so there is no AVCaptureSession to own here.
struct ScannerView: View {
    /// Called with the raw QR string; returns an error message when it is not a Yorozu payload.
    let onScan: (String) -> String?
    let onManualEntry: () -> Void

    @State private var error: String?
    @State private var authorization = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var available = DataScannerViewController.isAvailable
    @State private var scannerFailed = false
    @State private var scannerGeneration = 0
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Text("On your host Mac, open Yorozu, then choose Settings › Devices › Pair Another Device.")
                        .font(.headline)
                        .multilineTextAlignment(.center)

                    if authorization == .denied {
                        unavailable("Camera access is off", detail: "Allow camera access in Settings to scan, or enter the pairing code manually.")
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                        }
                        .buttonStyle(.borderedProminent)
                    } else if authorization == .restricted {
                        unavailable("Camera access is restricted", detail: "This device does not allow camera access. Enter the pairing code manually.")
                    } else if !DataScannerViewController.isSupported {
                        unavailable("Scanning unavailable", detail: "This device cannot scan pairing codes. You can enter the code manually instead.")
                    } else if authorization == .notDetermined {
                        ProgressView("Waiting for camera access…")
                    } else if available && !scannerFailed {
                        Scanner(onScan: { text in
                            error = onScan(text)
                            return error == nil
                        }, onFailure: { scannerFailed = true })
                        .id(scannerGeneration)
                        .frame(height: 300)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    } else {
                        unavailable("Camera unavailable", detail: "Try the camera again, or enter the pairing code manually.")
                        Button("Try camera again") {
                            scannerFailed = false
                            scannerGeneration += 1
                            refreshAvailability()
                        }
                        .buttonStyle(.bordered)
                    }

                    if let error {
                        Label { Text(error) } icon: {
                            Image(systemName: "exclamationmark.circle").foregroundStyle(.red)
                        }
                        .font(.footnote)
                    }
                    Button("Enter code manually", action: onManualEntry)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("pairing.scanner.manual")
                }
                .padding(16)
            }
            .navigationTitle("Scan pairing code")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                if DataScannerViewController.isSupported && authorization == .notDetermined {
                    _ = await AVCaptureDevice.requestAccess(for: .video)
                }
                refreshAvailability()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { refreshAvailability() }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func refreshAvailability() {
        authorization = AVCaptureDevice.authorizationStatus(for: .video)
        available = DataScannerViewController.isAvailable
    }

    private func unavailable(_ title: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "qrcode.viewfinder")
                .font(.largeTitle)
                .accessibilityHidden(true)
            Text(title).font(.headline)
            Text(detail).foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 24)
    }
}

private struct Scanner: UIViewControllerRepresentable {
    let onScan: (String) -> Bool
    let onFailure: () -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: true
        )
        controller.delegate = context.coordinator
        do {
            try controller.startScanning()
        } catch {
            Task { @MainActor in onFailure() }
        }
        return controller
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan, onFailure: onFailure) }

    static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) {
        controller.stopScanning()
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let onScan: (String) -> Bool
        private let onFailure: () -> Void
        /// One QR is enough; the scanner keeps reporting the same code every frame.
        private var done = false

        init(onScan: @escaping (String) -> Bool, onFailure: @escaping () -> Void) {
            self.onScan = onScan
            self.onFailure = onFailure
        }

        func dataScanner(_ scanner: DataScannerViewController,
                         becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) {
            scanner.stopScanning()
            onFailure()
        }

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

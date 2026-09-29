import Foundation
import Testing

@testable import YorozuMac

/// The sidecar's `STATE` lines, as the pairing sheet reads them. Only a failure asks the user
/// to act; a stop or a restart comes back with a new code on its own.
@Test(arguments: [
    ("starting", PairingAvailability.available),
    ("open", .available),
    ("paired", .available),
    ("stopped", .restarting),
    ("closed", .restarting),
    ("restarting in 4s", .restarting),
    ("failed: no runtime found", .failed),
    ("failed: The file couldn’t be opened.", .failed),
])
func pairingAvailabilityFollowsTheSidecarState(state: String, expected: PairingAvailability) {
    #expect(PairingAvailability(sidecarState: state) == expected)
}

/// Protocol diagnostics remain copyable in any language, including states from a newer host.
@MainActor @Test func localizedServiceStatusPreservesDiagnosticDetails() {
    #expect(Sidecar.statusLabel("restarting in 4s") == String(localized: "Restarting in \(4) seconds"))
    for state in ["restarting in 4x", "future-state: 接続待ち"] {
        #expect(Sidecar.statusLabel(state).contains(state))
    }
    #expect(Sidecar.statusLabel("failed: ファイルを開けませんでした").contains("ファイルを開けませんでした"))
}

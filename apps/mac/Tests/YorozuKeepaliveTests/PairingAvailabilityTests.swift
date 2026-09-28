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

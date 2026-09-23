/// Tracks one pairing attempt from the device list captured before its code is shown.
/// A redraw or a second list must never absorb a newly paired device into that baseline.
public struct DevicePairingProgress: Equatable, Sendable {
    public private(set) var baseline: Set<String>?

    public init() {}

    public mutating func establishBaseline(_ devices: [DeviceInfo]) {
        guard baseline == nil else { return }
        baseline = Set(devices.filter { $0.via == .relay }.map(\.pub))
    }

    public func newlyPaired(in devices: [DeviceInfo]) -> Bool {
        guard let baseline else { return false }
        return devices.contains { $0.via == .relay && !baseline.contains($0.pub) }
    }
}

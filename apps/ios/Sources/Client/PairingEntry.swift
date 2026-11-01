import YorozuWire

struct PairingEntry {
    var text = ""
    var pendingPairing: QrPayload?

    mutating func cancel() {
        text = ""
        pendingPairing = nil
    }
}

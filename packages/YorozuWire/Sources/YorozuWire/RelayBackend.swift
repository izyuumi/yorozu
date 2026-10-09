/// What the Mac host hands every decrypted phone event to; the returned events go back to that phone.
/// `device` is the sender's X25519 public key (base64url), which keys its attachment staging; it never reaches the Engine.
public protocol RelayBackend: Sendable {
    func handle(_ e: YorozuEvent, from device: String) async -> [YorozuEvent]
}

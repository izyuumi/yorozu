/// Which engine voice input uses.
public enum VoiceEngineChoice {
    /// The engine the owner picked while this device can run it. Otherwise: LFM3-Audio when its model is
    /// already downloaded (an owner from before engines could be picked keeps it, with no new download),
    /// then Apple's, then a downloaded model, then any engine the device can run; nil when it can run none.
    /// `usable` is in display order.
    public static func resolve(stored: VoiceEngineID?, usable: [VoiceEngineID], downloaded: Set<VoiceEngineID>) -> VoiceEngineID? {
        if let stored, usable.contains(stored) { return stored }
        if usable.contains(.lfm), downloaded.contains(.lfm) { return .lfm }
        if usable.contains(.apple) { return .apple }
        return usable.first(where: downloaded.contains) ?? usable.first
    }
}

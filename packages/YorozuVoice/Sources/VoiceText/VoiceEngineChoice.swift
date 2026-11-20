public enum VoiceEngineChoice {
    public static func resolve(stored: VoiceEngineID?, usable: [VoiceEngineID], downloaded: Set<VoiceEngineID>) -> VoiceEngineID? {
        if let stored, usable.contains(stored) { return stored }
        if usable.contains(.lfm), downloaded.contains(.lfm) { return .lfm }
        if usable.contains(.apple) { return .apple }
        return usable.first(where: downloaded.contains) ?? usable.first
    }
}

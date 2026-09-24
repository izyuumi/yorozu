/// Sparkle orders builds globally; a later hotfix build must not downgrade a newer beta.
public enum ReleaseVersion {
    public static func allowsUpdate(from installed: String?, to offered: String) -> Bool {
        guard let installed, let current = components(installed), let next = components(offered) else {
            return false
        }
        return !next.lexicographicallyPrecedes(current)
    }

    private static func components(_ version: String) -> [UInt]? {
        // Older appcasts used this display suffix. No other suffix is a release version.
        let numeric = version.hasSuffix(" Beta") ? version.dropLast(5) : version[...]
        let parts = numeric.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } })
        else { return nil }
        let numbers = parts.compactMap { UInt($0) }
        return numbers.count == 3 ? numbers : nil
    }
}

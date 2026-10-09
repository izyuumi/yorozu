// NOTICE: stand-in for the shared `NoticeText` (owned by another package). It returns the Mac's
// English fallback. Delete this file once the shared `NoticeText` is in the iOS target's sources.
enum NoticeText {
    static func text(code: String, params: [String: String], fallback: String) -> String { fallback }
}

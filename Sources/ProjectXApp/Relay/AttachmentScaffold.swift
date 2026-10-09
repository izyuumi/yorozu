import Foundation
import ProjectXCore

// #316 scaffold: the store package (branch at-store) adds `Engine.attachmentURL(_:)`. Delete this file when merging it;
// the two declarations are ambiguous together, so the build says when.
extension Engine {
    func attachmentURL(_ id: String) async -> URL? { nil }
}

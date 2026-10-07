import ProjectDescription

/// Marks `apps/ios` as the generation root. Without it Tuist walks up looking for a `.git`
/// *directory*, which a git worktree does not have (there `.git` is a file).
let tuist = Tuist()

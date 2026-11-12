// The installer name uses the workspace version.
#[test]
fn version_is_the_workspace_version() {
    assert_eq!(yorozu_core::VERSION, "0.1.0");
}

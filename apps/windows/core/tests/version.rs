// The installer name and the smoke line use the same version: tauri.conf.json's and the workspace's.
#[test]
fn version_is_the_tauri_version() {
    let conf: serde_json::Value =
        serde_json::from_str(include_str!("../../app/src-tauri/tauri.conf.json")).unwrap();
    assert_eq!(conf["version"].as_str(), Some(yorozu_core::VERSION));
}

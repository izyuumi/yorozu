fn main() {
    println!("cargo:rerun-if-env-changed=GITHUB_SHA");
    let sha = std::env::var("GITHUB_SHA").unwrap_or_default();
    let build = sha.get(..7).unwrap_or("dev");
    println!("cargo:rustc-env=YOROZU_BUILD_SHA={build}");

    // Declaring the app's commands makes each one need an `allow-<command>` permission
    // in capabilities/default.json (spec section 9).
    let manifest = tauri_build::AppManifest::new().commands(&[
        "snapshot",
        "submit_link",
        "confirm_pairing",
        "cancel_pairing",
        "forget_pairing",
        "pair_again",
        "retry_connection",
        "open_conversation",
        "new_conversation",
        "load_older",
        "send_message",
        "retry_message",
    ]);
    tauri_build::try_build(tauri_build::Attributes::new().app_manifest(manifest))
        .expect("tauri-build failed");
}

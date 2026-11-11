//! The Tauri shell of Yorozu for Windows: one window that renders the core's `Snapshot`.

mod commands;
mod smoke;

use tauri::Manager;

/// The web view may only navigate within the app's own origin (spec section 9).
/// Windows serves it from `tauri.localhost`; macOS and Linux use the `tauri` scheme.
pub fn allowed_navigation(url: &tauri::Url) -> bool {
    matches!(
        (url.scheme(), url.host_str(), url.port()),
        ("http", Some("tauri.localhost"), None) | ("tauri", Some("localhost"), None)
    )
}

pub fn run() {
    let smoke = smoke::from_args(std::env::args());

    let mut builder = tauri::Builder::default();
    // Not under `--smoke`: the smoke run must not hand off to, or be blocked by, an
    // installed instance that is already running.
    if smoke.is_none() {
        // A second launch focuses the first one's window and exits.
        builder = builder.plugin(tauri_plugin_single_instance::init(|app, _argv, _cwd| {
            if let Some(window) = app.get_webview_window("main") {
                let _ = window.unminimize();
                let _ = window.show();
                let _ = window.set_focus();
            }
        }));
    }

    let nav = tauri::plugin::Builder::<tauri::Wry>::new("nav")
        .on_navigation(|_, url| allowed_navigation(url))
        .build();

    builder
        .plugin(nav)
        .manage(smoke)
        .invoke_handler(tauri::generate_handler![commands::snapshot])
        .run(tauri::generate_context!())
        .expect("failed to run Yorozu");
}

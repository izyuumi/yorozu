//! The Tauri shell of Yorozu for Windows: one window that renders the core's `Snapshot`.

mod commands;
mod smoke;

use std::sync::Arc;
use tauri::{Emitter, Manager};
use yorozu_core::{
    driver::{Driver, Notification, Options},
    platform::SystemPlatform,
    store::Protector,
};

// The distributed client uses Windows DPAPI. Other targets compile for shell checks.
#[cfg(not(windows))]
struct UnsupportedProtector;
#[cfg(not(windows))]
impl Protector for UnsupportedProtector {
    fn protect(&self, _: &[u8]) -> std::io::Result<Vec<u8>> {
        Err(std::io::Error::other("DPAPI requires Windows"))
    }
    fn unprotect(&self, _: &[u8]) -> std::io::Result<Vec<u8>> {
        Err(std::io::Error::other("DPAPI requires Windows"))
    }
}

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
        .setup(move |app| {
            let core = if smoke.is_none() {
                let dir = app.path().app_local_data_dir()?;
                #[cfg(windows)]
                let protector: Box<dyn Protector> = Box::new(yorozu_core::store::DpapiProtector);
                #[cfg(not(windows))]
                let protector: Box<dyn Protector> = Box::new(UnsupportedProtector);
                let events = app.handle().clone();
                let (handle, driver) = Driver::new(
                    Arc::new(SystemPlatform { dir }),
                    protector,
                    Options::default(),
                    env!("YOROZU_BUILD_SHA"),
                    move |event| match event {
                        Notification::Changed(scope) => {
                            let _ = events.emit("changed", serde_json::json!({"scope":scope}));
                        }
                        Notification::Notice { text, .. } => {
                            let _ = events.emit("notice", serde_json::json!({"text":text}));
                        }
                        _ => {}
                    },
                );
                let focused = app
                    .get_webview_window("main")
                    .and_then(|w| w.is_focused().ok())
                    .unwrap_or(false);
                let _ = handle.command(yorozu_core::driver::Command::Focus(focused));
                tauri::async_runtime::spawn(driver.run());
                Some(handle)
            } else {
                None
            };
            app.manage(commands::Core(core));
            app.manage(smoke);
            Ok(())
        })
        .on_window_event(|window, event| {
            if let tauri::WindowEvent::Focused(focused) = event {
                if let Some(core) = window.try_state::<commands::Core>() {
                    if let Some(handle) = &core.0 {
                        let _ = handle.command(yorozu_core::driver::Command::Focus(*focused));
                    }
                }
            }
        })
        .invoke_handler(tauri::generate_handler![
            commands::snapshot,
            commands::submit_link,
            commands::confirm_pairing,
            commands::cancel_pairing,
            commands::forget_pairing,
            commands::pair_again,
            commands::retry_connection,
            commands::open_conversation,
            commands::new_conversation,
            commands::load_older,
            commands::send_message,
            commands::retry_message
        ])
        .run(tauri::generate_context!())
        .expect("failed to run Yorozu");
}

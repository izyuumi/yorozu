//! `--smoke <file>`: CI's proof that the built app starts and its web view reaches the core.
//! The run writes `ready <version>` to the file on the web view's first `snapshot` call and
//! exits 0, exits 1 at once if it can't write the file, or exits 1 after 60 seconds.

use std::path::PathBuf;
use std::time::Duration;

use tauri::AppHandle;

pub struct Smoke {
    path: PathBuf,
}

/// Returns the smoke run if the arguments ask for one, after preparing the process for it.
/// Call before anything else starts a thread: it sets an environment variable.
pub fn from_args(args: impl Iterator<Item = String>) -> Option<Smoke> {
    let mut args = args.skip_while(|arg| arg != "--smoke").skip(1);
    let path = PathBuf::from(args.next()?);

    // WebView2 reads this variable in preference to the folder Tauri passes it, so this
    // points WebView2's profile at a temporary folder and not at the real app data folder.
    let folder = format!("yorozu-smoke-{}", std::process::id());
    std::env::set_var(
        "WEBVIEW2_USER_DATA_FOLDER",
        std::env::temp_dir().join(folder),
    );

    std::thread::spawn(|| {
        std::thread::sleep(Duration::from_secs(60));
        std::process::exit(1);
    });

    Some(Smoke { path })
}

impl Smoke {
    /// The web view called `snapshot`: record it and end the run.
    pub fn ready(&self, app: &AppHandle) {
        let line = format!("ready {}\n", yorozu_core::VERSION);
        let written = std::fs::write(&self.path, line).is_ok();
        app.exit(i32::from(!written));
    }
}

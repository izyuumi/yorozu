use std::path::PathBuf;
use std::time::Duration;

use tauri::AppHandle;

pub struct Smoke {
    path: PathBuf,
}

pub fn from_args(args: impl Iterator<Item = String>) -> Option<Smoke> {
    let mut args = args.skip_while(|arg| arg != "--smoke").skip(1);
    let path = PathBuf::from(args.next()?);

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
    pub fn ready(&self, app: &AppHandle) {
        let line = format!("ready {}\n", yorozu_core::VERSION);
        let written = std::fs::write(&self.path, line).is_ok();
        app.exit(i32::from(!written));
    }
}

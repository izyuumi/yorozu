//! Every command the web view may invoke. Each one is also declared in `build.rs` and
//! granted in `capabilities/default.json`.
//!
//! | command    | does                                                          |
//! |------------|---------------------------------------------------------------|
//! | `snapshot` | returns the state to render; in smoke mode it also ends the run |

use tauri::{AppHandle, State};
use yorozu_core::Snapshot;

use crate::smoke::Smoke;

#[tauri::command]
pub fn snapshot(app: AppHandle, smoke: State<'_, Option<Smoke>>) -> Snapshot {
    if let Some(smoke) = smoke.inner() {
        smoke.ready(&app);
    }
    Snapshot::initial(yorozu_core::VERSION, env!("YOROZU_BUILD_SHA"))
}

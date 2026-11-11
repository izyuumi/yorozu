//! Every command the web view may invoke. A command is declared in four places: here, in
//! `lib.rs` (`invoke_handler`), in `build.rs` (`AppManifest`) and in
//! `capabilities/default.json`, which grants it. Every command but `snapshot` goes to the
//! core's driver.
//!
//! | command            | does                                                              |
//! |--------------------|-------------------------------------------------------------------|
//! | `snapshot`         | returns the state to render; in smoke mode it also ends the run   |
//! | `submit_link`      | hands the pasted pairing link to the core, which asks to confirm  |
//! | `confirm_pairing`  | creates this PC's keys, saves the pairing and starts connecting   |
//! | `cancel_pairing`   | leaves the confirm screen, or stops and wipes a pairing under way |
//! | `forget_pairing`   | stops the connection and wipes the pairing from this PC           |
//! | `pair_again`       | wipes a removed or unreadable pairing; back to the pairing screen |
//! | `retry_connection` | redials after "Update required"                                   |
use crate::smoke::Smoke;
use tauri::{AppHandle, State};
use yorozu_core::{
    driver::{Command, Handle},
    Snapshot,
};

pub struct Core(pub Option<Handle>);
#[tauri::command]
pub fn snapshot(
    app: AppHandle,
    smoke: State<'_, Option<Smoke>>,
    core: State<'_, Core>,
) -> Snapshot {
    if let Some(smoke) = smoke.inner() {
        smoke.ready(&app);
    }
    core.0
        .as_ref()
        .map(Handle::snapshot)
        .unwrap_or_else(|| Snapshot::initial(yorozu_core::VERSION, env!("YOROZU_BUILD_SHA")))
}
fn send(core: State<'_, Core>, cmd: Command) -> Result<(), String> {
    core.0
        .as_ref()
        .ok_or("connection driver unavailable")?
        .command(cmd)
}
#[tauri::command]
pub fn submit_link(core: State<'_, Core>, link: String) -> Result<(), String> {
    send(core, Command::SubmitLink(link))
}
#[tauri::command]
pub fn confirm_pairing(core: State<'_, Core>) -> Result<(), String> {
    send(core, Command::Confirm)
}
#[tauri::command]
pub fn cancel_pairing(core: State<'_, Core>) -> Result<(), String> {
    send(core, Command::Cancel)
}
#[tauri::command]
pub fn forget_pairing(core: State<'_, Core>) -> Result<(), String> {
    send(core, Command::Forget)
}
#[tauri::command]
pub fn pair_again(core: State<'_, Core>) -> Result<(), String> {
    send(core, Command::PairAgain)
}
#[tauri::command]
pub fn retry_connection(core: State<'_, Core>) -> Result<(), String> {
    send(core, Command::Retry)
}

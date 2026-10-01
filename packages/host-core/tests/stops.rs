use serde_json::{Value, json};
use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use yorozu_host_core::{now_ms, stops::Stops};
static ID: AtomicU64 = AtomicU64::new(0);
struct Temp(PathBuf);
impl Temp {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!(
            "yorozu-stops-{}-{}-{}",
            std::process::id(),
            now_ms(),
            ID.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&path).unwrap();
        Self(path)
    }
}
impl Drop for Temp {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}
fn record(status: &str) -> Value {
    json!({"targetEventId":"operation","threadId":"thread","status":status,"requestIds":["stop-one"]})
}
fn save(store: &mut Stops, value: Value) -> Value {
    store.request(&json!({"op":"stop_save","record":value}))
}
#[test]
fn legacy_bytes_unknown_fields_and_duplicate_intents_are_retained() {
    let temp = Temp::new();
    let mut old = record("requested");
    old["future"] = json!({"kept":true});
    let bytes = format!(
        "{}\n",
        serde_json::to_string_pretty(&old)
            .unwrap()
            .replace('\n', " ")
    );
    fs::write(temp.0.join("stopped-turns.jsonl"), &bytes).unwrap();
    let mut store = Stops::open(&temp.0).unwrap();
    assert_eq!(save(&mut store, record("requested"))["record"], old);
    assert_eq!(
        fs::read_to_string(temp.0.join("stopped-turns.jsonl")).unwrap(),
        bytes
    );
    let mut changed = record("unconfirmed");
    changed["requestIds"] = json!(["stop-two"]);
    let result = save(&mut store, changed);
    assert_eq!(
        result["record"]["requestIds"],
        json!(["stop-one", "stop-two"])
    );
    assert_eq!(result["record"]["future"], json!({"kept":true}));
}
#[test]
fn ownership_conflicts_and_terminal_downgrades_cannot_replace_committed_proof() {
    for status in ["stopped", "completed", "withdrawn"] {
        let temp = Temp::new();
        let mut store = Stops::open(&temp.0).unwrap();
        assert_eq!(save(&mut store, record(status))["record"]["status"], status);
        let bytes = fs::read(temp.0.join("stopped-turns.jsonl")).unwrap();
        let mut other = record(status);
        other["threadId"] = json!("other");
        assert_eq!(
            save(&mut store, other),
            json!({"error":"conflicting-stop-owner"})
        );
        assert_eq!(
            save(&mut store, record("requested")),
            json!({"error":"conflicting-stop-transition"})
        );
        assert_eq!(fs::read(temp.0.join("stopped-turns.jsonl")).unwrap(), bytes);
        drop(store);
        let mut reopened = Stops::open(&temp.0).unwrap();
        assert_eq!(
            reopened.request(&json!({"op":"stop_get","targetEventId":"operation"}))["record"]["status"],
            status
        );
    }
}
#[test]
fn interrupted_tail_recovery_preserves_original_and_all_complete_intents() {
    let temp = Temp::new();
    let original = format!("{}\n{{unfinished", record("requested"));
    fs::write(temp.0.join("stopped-turns.jsonl"), &original).unwrap();
    let mut store = Stops::open(&temp.0).unwrap();
    assert_eq!(
        fs::read_to_string(temp.0.join("stopped-turns.jsonl")).unwrap(),
        original
    );
    assert_eq!(
        save(&mut store, record("stopped"))["record"]["status"],
        "stopped"
    );
    let backup = fs::read_dir(&temp.0)
        .unwrap()
        .map(|p| p.unwrap().path())
        .find(|p| {
            p.file_name()
                .unwrap()
                .to_string_lossy()
                .starts_with(".stopped-turns-recovery.")
        })
        .unwrap();
    assert_eq!(fs::read_to_string(backup).unwrap(), original);
    drop(store);
    let mut reopened = Stops::open(&temp.0).unwrap();
    assert_eq!(
        reopened.request(&json!({"op":"stop_get","targetEventId":"operation"}))["record"]["status"],
        "stopped"
    );
}
#[test]
fn malformed_or_conflicting_legacy_owners_are_retained_and_second_writer_is_excluded() {
    for bytes in [
        "malformed\n".to_owned(),
        format!(
            "{}\n{}\n",
            record("requested"),
            json!({"targetEventId":"operation","threadId":"other","status":"requested","requestIds":["two"]})
        ),
    ] {
        let temp = Temp::new();
        fs::write(temp.0.join("stopped-turns.jsonl"), &bytes).unwrap();
        assert!(Stops::open(&temp.0).is_err());
        assert_eq!(
            fs::read_to_string(temp.0.join("stopped-turns.jsonl")).unwrap(),
            bytes
        );
    }
    let temp = Temp::new();
    let first = Stops::open(&temp.0).unwrap();
    assert!(Stops::open(&temp.0).is_err());
    drop(first);
    assert!(Stops::open(&temp.0).is_ok());
}
#[test]
fn acknowledged_stop_survives_actual_worker_termination() {
    let temp = Temp::new();
    let mut child = Command::new(env!("CARGO_BIN_EXE_yorozu-host-core"))
        .args(["attachments", temp.0.to_str().unwrap()])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    writeln!(
        child.stdin.as_mut().unwrap(),
        "{}",
        json!({"id":"rpc","op":"stop_save","record":record("requested")})
    )
    .unwrap();
    let mut response = String::new();
    BufReader::new(child.stdout.take().unwrap())
        .read_line(&mut response)
        .unwrap();
    assert_eq!(
        serde_json::from_str::<Value>(&response).unwrap()["result"]["record"]["status"],
        "requested"
    );
    child.kill().unwrap();
    child.wait().unwrap();
    let mut reopened = Stops::open(&temp.0).unwrap();
    assert_eq!(
        reopened.request(&json!({"op":"stop_get","targetEventId":"operation"}))["record"],
        record("requested")
    );
}
#[cfg(unix)]
#[test]
fn replaced_journal_fails_closed_without_touching_the_new_path() {
    use yorozu_host_core::admission::Admissions;
    for stop in [false, true] {
        let temp = Temp::new();
        let (name, entry, mut store_stop, mut store_admission) = if stop {
            (
                "stopped-turns.jsonl",
                record("requested"),
                Some(Stops::open(&temp.0).unwrap()),
                None,
            )
        } else {
            (
                "expired-admissions.jsonl",
                json!({"id":"operation","threadId":"thread","identity":"a".repeat(64),"deadline":1}),
                None,
                Some(Admissions::open(&temp.0).unwrap()),
            )
        };
        let write = |stops: &mut Option<Stops>, admissions: &mut Option<Admissions>| {
            if let Some(store) = stops {
                save(store, entry.clone())
            } else {
                admissions
                    .as_mut()
                    .unwrap()
                    .request(&json!({"op":"admission_expire","entry":entry,"now":2}))
            }
        };
        assert!(
            write(&mut store_stop, &mut store_admission)
                .get("error")
                .is_none()
        );
        let original = fs::read(temp.0.join(name)).unwrap();
        fs::rename(temp.0.join(name), temp.0.join("original")).unwrap();
        fs::write(temp.0.join(name), &original).unwrap();
        // Force a new transition so an identical retry cannot bypass append-path validation.
        let result = if let Some(store) = &mut store_stop {
            save(store, record("stopped"))
        } else {
            store_admission.as_mut().unwrap().request(&json!({"op":"admission_expire","entry":{"id":"different","threadId":"thread","identity":"a".repeat(64),"deadline":1},"now":2}))
        };
        assert!(result.get("error").is_some());
        assert_eq!(fs::read(temp.0.join(name)).unwrap(), original);
        assert_eq!(fs::read(temp.0.join("original")).unwrap(), original);
    }
}
